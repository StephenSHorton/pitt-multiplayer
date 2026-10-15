extends Node3D
## A remote player's puppet (MP-DESIGN 8.1): capsule body tinted per slot, a small
## face plate pitched with the camera and a billboard name label. No physics body,
## no groups and never named PlayerController, so every
## get_first_node_in_group("player") / is_in_group("player") keeps meaning "me" (R1).
## The transmitted position is the PlayerController origin, which is the centre
## of the player's capsule (standing height 1.95, camera pivot +0.65), so the
## body is centred on the origin and the face plate sits at eye height.
## Interpolation: rendered at host_now - 100 ms from a buffer of frames (position
## lerped, yaw/pitch lerp_angle); up to 250 ms of velocity extrapolation, then
## hold; snap on `teleported` or a jump over 5 m; hidden after 3 s without frames.
## Near-camera fade: body and face plate fade out from FADE_FAR to NEAR_HIDE
## metres (camera to the capsule axis) and are hidden inside NEAR_HIDE, so a
## puppet never fills the local view; the name label always stays.

const PALETTE := [Color(0.95, 0.75, 0.15), Color(0.25, 0.65, 0.95), Color(0.9, 0.3, 0.3), Color(0.35, 0.85, 0.4),
	Color(0.75, 0.45, 0.95), Color(0.95, 0.55, 0.2), Color(0.3, 0.9, 0.85), Color(0.95, 0.45, 0.7),
	Color(0.6, 0.6, 0.65), Color(0.55, 0.75, 0.3)]
const GOLD := Color(0.969, 0.729, 0.078)
const FONT_PATH := "res://assets/PublicPixel-rv0pA.ttf"
const INTERP_DELAY_MS := 100
const MAX_EXTRAP_MS := 250
const SNAP_DISTANCE := 5.0
const HIDE_AFTER_MS := 3000
const BUFFER_MAX := 32
const CAPSULE_RADIUS := 0.32
const CAPSULE_HEIGHT := 1.95       # player_controller.gd standing_height
const VISOR_Y := 0.65              # CameraPivot height above the origin
const VISOR_SIZE := Vector3(0.26, 0.07, 0.04)
const NEAR_HIDE := 0.9
const FADE_FAR := 1.25
const EMISSION_ENERGY := 0.3
const LABEL_Y := CAPSULE_HEIGHT * 0.5 + 0.3

var slot := 0
var peer := 0
var player_name := ""
var is_host := false
## Callable() -> int: the host clock as seen here (set by avatars.gd)
var clock: Callable = Callable()
var _buf: Array = []         # frames sorted by t_ms: {t_ms, pos, yaw, pitch, vel, flags, seq}
var _last_rx_ms := 0
var _last_seq := -1
var _snap_next := true
var body: MeshInstance3D = null
var visor: MeshInstance3D = null
var label: Label3D = null
var pitch := 0.0
var frames_rx := 0


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func setup(p_slot: int, p_peer: int, p_name: String, p_is_host: bool) -> void:
	slot = p_slot
	peer = p_peer
	player_name = p_name
	is_host = p_is_host
	name = "PittMP_Avatar_%d" % slot
	_build()


func _build() -> void:
	if body != null:
		return
	var col: Color = PALETTE[(maxi(slot, 1) - 1) % PALETTE.size()]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.6
	# readable in the dark mine: a soft self-glow in the slot colour plus a rim
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = EMISSION_ENERGY
	mat.rim_enabled = true
	mat.rim = 0.6
	mat.rim_tint = 0.4
	body = MeshInstance3D.new()
	body.name = "Body"
	var cap := CapsuleMesh.new()
	cap.radius = CAPSULE_RADIUS
	cap.height = CAPSULE_HEIGHT
	body.mesh = cap
	body.material_override = mat
	add_child(body)
	# a small light face plate on the front of the head (-Z = look direction):
	# shows where the player looks, too small to ever cover the screen
	visor = MeshInstance3D.new()
	visor.name = "Visor"
	var box := BoxMesh.new()
	box.size = VISOR_SIZE
	visor.mesh = box
	var vmat := StandardMaterial3D.new()
	vmat.albedo_color = Color(0.85, 0.95, 1.0)
	vmat.emission_enabled = true
	vmat.emission = Color(0.85, 0.95, 1.0)
	vmat.emission_energy_multiplier = 0.8
	vmat.roughness = 0.3
	visor.material_override = vmat
	visor.position = Vector3(0, VISOR_Y, -(CAPSULE_RADIUS - VISOR_SIZE.z * 0.25))
	add_child(visor)
	label = Label3D.new()
	label.name = "Name"
	label.text = player_name
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = false
	# constant on-screen size: readable at 30 m, never huge up close
	label.fixed_size = true
	label.pixel_size = 0.0011
	label.font_size = 32
	label.outline_size = 10
	label.outline_modulate = Color(0, 0, 0, 0.9)
	label.modulate = GOLD if is_host else Color.WHITE
	label.visibility_range_end = 80.0
	label.position = Vector3(0, LABEL_Y, 0)
	if ResourceLoader.exists(FONT_PATH):
		var f = load(FONT_PATH)
		if f is Font:
			label.font = f
	add_child(label)


func set_player_name(n: String) -> void:
	player_name = n
	if label != null:
		label.text = n


## A frame from the network (host-clock t_ms). Old seqs are ignored.
func push(f: Dictionary, now_local_ms: int) -> void:
	var seq := int(f.get("seq", 0))
	if seq <= _last_seq and _last_seq - seq < 1000000:
		return
	_last_seq = seq
	_last_rx_ms = now_local_ms
	frames_rx += 1
	var teleported := (int(f.get("flags", 0)) & 32) != 0
	if not _buf.is_empty():
		var lastp: Vector3 = _buf.back().pos
		if teleported or lastp.distance_to(f.pos) > SNAP_DISTANCE:
			_buf.clear()
			_snap_next = true
	_buf.append(f)
	_buf.sort_custom(func(a, b): return int(a.t_ms) < int(b.t_ms))
	while _buf.size() > BUFFER_MAX:
		_buf.pop_front()


func _now_host() -> int:
	if clock.is_valid():
		return int(clock.call())
	return Time.get_ticks_msec()


func _process(_delta: float) -> void:
	update_pose(_now_host(), Time.get_ticks_msec())
	if visible and is_inside_tree():
		var cam := get_viewport().get_camera_3d()
		if cam != null:
			apply_camera(cam.global_position)


## 1.0 = fully drawn, 0.0 = hidden, for a camera `dist` metres from the capsule
## axis. Pure.
static func near_alpha(dist: float) -> float:
	if dist <= NEAR_HIDE:
		return 0.0
	if dist >= FADE_FAR:
		return 1.0
	return (dist - NEAR_HIDE) / (FADE_FAR - NEAR_HIDE)


## Distance from a world point to this puppet's capsule axis (the segment the
## capsule is swept along), using the current global position.
func axis_distance(p: Vector3) -> float:
	var c := global_position if is_inside_tree() else position
	var half := CAPSULE_HEIGHT * 0.5 - CAPSULE_RADIUS
	var y := clampf(p.y, c.y - half, c.y + half)
	return p.distance_to(Vector3(c.x, y, c.z))


## Fades/hides the body and face plate for a local camera at `cam_pos`; the
## name label is left alone. Public for tests.
func apply_camera(cam_pos: Vector3) -> float:
	var a := near_alpha(axis_distance(cam_pos))
	for m in [body, visor]:
		if m == null:
			continue
		m.visible = a > 0.01
		m.transparency = 1.0 - a
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if a >= 0.99 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return a


## Interpolates the pose for host time `host_now`. Public for tests.
func update_pose(host_now: int, local_now: int) -> void:
	if _buf.is_empty():
		visible = false
		return
	visible = local_now - _last_rx_ms <= HIDE_AFTER_MS
	var rt := host_now - INTERP_DELAY_MS
	var pose := sample(rt)
	if _snap_next:
		_snap_next = false
	position = pose.pos
	rotation = Vector3(0, float(pose.yaw), 0)
	pitch = float(pose.pitch)
	if visor != null:
		visor.rotation = Vector3(pitch, 0, 0)


## {pos, yaw, pitch} at render time rt (host clock).
func sample(rt: int) -> Dictionary:
	var first: Dictionary = _buf[0]
	var last: Dictionary = _buf.back()
	if _buf.size() == 1 or rt <= int(first.t_ms):
		var f := first if rt <= int(first.t_ms) else last
		return {"pos": f.pos, "yaw": f.yaw, "pitch": f.pitch}
	if rt >= int(last.t_ms):
		var dt := float(mini(rt - int(last.t_ms), MAX_EXTRAP_MS)) / 1000.0
		var v: Vector3 = last.vel
		return {"pos": last.pos + v * dt, "yaw": last.yaw, "pitch": last.pitch}
	for i in range(_buf.size() - 1):
		var a: Dictionary = _buf[i]
		var b: Dictionary = _buf[i + 1]
		if rt >= int(a.t_ms) and rt <= int(b.t_ms):
			var span := float(maxi(int(b.t_ms) - int(a.t_ms), 1))
			var w := clampf(float(rt - int(a.t_ms)) / span, 0.0, 1.0)
			return {"pos": (a.pos as Vector3).lerp(b.pos, w), "yaw": lerp_angle(float(a.yaw), float(b.yaw), w),
				"pitch": lerp_angle(float(a.pitch), float(b.pitch), w)}
	return {"pos": last.pos, "yaw": last.yaw, "pitch": last.pitch}


func buffer_size() -> int:
	return _buf.size()
