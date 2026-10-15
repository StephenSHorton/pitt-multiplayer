extends RefCounted
## Shared helpers for the host / client scenarios. Wall-clock waits only
## (Engine.time_scale changes during phase 3).

const Report = preload("report.gd")

var node: Node = null       # PittMPTests main (in the tree, PROCESS_MODE_ALWAYS)
var api = null
var mp = null               # PittMultiplayer main node (get_public_api)
var session: Node = null
var lobby: Node = null
var report = null
var flag: Dictionary = {}
var peer_report_path := ""


func setup(p_node: Node, p_api, p_mp, p_report, p_flag: Dictionary) -> void:
	node = p_node
	api = p_api
	mp = p_mp
	session = mp.session
	lobby = mp.lobby
	report = p_report
	flag = p_flag
	peer_report_path = String(flag.get("peer_report", ""))


func tree() -> SceneTree:
	return node.get_tree()


func g(n: String) -> Object:
	return tree().root.get_node_or_null(NodePath(n))


func frame() -> void:
	await tree().process_frame


func sleep_ms(ms: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		await tree().process_frame


## Polls cond() every frame (wall clock). Returns cond() at the end.
func wait_for(cond: Callable, timeout_s: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while not bool(cond.call()):
		if Time.get_ticks_msec() - t0 > int(timeout_s * 1000.0):
			return false
		await tree().process_frame
	return true


func peer() -> Dictionary:
	return Report.read(peer_report_path)


## Waits until the other instance wrote mark `name`. -> its values dict or {} on timeout.
func wait_peer_mark(name: String, timeout_s: float) -> Dictionary:
	return await wait_mark_in(peer_report_path, name, timeout_s)


## The same for any instance's report file (3-instance runs: flag.peer2_report).
func wait_mark_in(path: String, name: String, timeout_s: float) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var last_poll := 0
	while true:
		if Time.get_ticks_msec() - last_poll >= 100:
			last_poll = Time.get_ticks_msec()
			var p := Report.read(path)
			if p.has("marks") and p.marks.has(name):
				# every value of the peer, plus the mark's own value dict flattened on top
				# (so both v[name][key] and v[key] work)
				var vals: Dictionary = p.get("values", {}).duplicate()
				var own = vals.get(name, null)
				if typeof(own) == TYPE_DICTIONARY:
					vals.merge(own, true)
				vals["_mark_ms"] = int(p.marks[name])
				return vals
			if p.get("finished", false) and not p.get("marks", {}).has(name):
				report.info("peer_finished_early", "waiting for %s, peer finished (fatal: %s)" % [name, p.get("fatal", "")])
				return {}
		if Time.get_ticks_msec() - t0 > int(timeout_s * 1000.0):
			return {}
		await tree().process_frame
	return {}


func cmd(name: String, args: Dictionary = {}) -> Object:
	var r = api.commands.execute(name, args)
	if not r.done:
		await r.completed
	return r


func money() -> String:
	var gs = g("GameState")
	return String(gs.money.to_plain_string()) if gs != null else ""


func phase() -> int:
	var gp = g("GameProgression")
	return int(gp.current_phase) if gp != null else -1


func in_world() -> bool:
	return api.state.is_in_world()


func on_main_menu() -> bool:
	var cs := tree().current_scene
	return cs != null and cs.scene_file_path == "res://scenes/main_menu.tscn"


func player() -> Node3D:
	return tree().get_first_node_in_group("player") as Node3D


## Same-Steam-account rule: never grant achievements or change presence.
func suppress_steam() -> void:
	await cmd("achievements.suppress", {})
	await cmd("presence.suppress", {"enabled": true})


func puppet_count() -> int:
	return int(session.avatars.puppet_count())


func puppet(slot: int) -> Node3D:
	return session.avatars.get_puppet(slot)


## Screenshot to <flag.screens_dir>/loop-<role>-<name>.png (windowed runs only).
func shot(name: String) -> void:
	var dir := String(flag.get("screens_dir", ""))
	if dir == "" or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var img := tree().root.get_texture().get_image()
	if img == null:
		return
	DirAccess.make_dir_recursive_absolute(dir)
	var who := String(flag.get("side", "")) if String(flag.get("role", "")) == "mp2" else String(flag.get("role", "x"))
	if bool(flag.get("host_live", false)) and who == "host":
		who = "livehost"
	elif bool(flag.get("client_live", false)) and who == "client":
		who = "liveclient"
	var p := dir.path_join("loop-%s-%s.png" % [who, name])
	var err := img.save_png(p)
	report.value("shot_" + name, p if err == OK else "error %d" % err)


## Turns the local player (yaw) and camera (pitch) toward a world point, the
## same nodes the game's mouse look rotates. Pitch is aimed from the camera.
func face(target: Vector3) -> void:
	var p := player()
	if p == null:
		return
	var d := target - p.global_position
	if Vector2(d.x, d.z).length() < 0.01:
		return
	p.rotation.y = atan2(-d.x, -d.z)
	var cam = p.get("main_camera")
	if cam is Camera3D:
		var e: Vector3 = target + Vector3(0, 0.2, 0) - (cam as Camera3D).global_position
		cam.rotation.x = clamp(atan2(e.y, Vector2(e.x, e.z).length()), -0.6, 0.6)


func local_camera_pos() -> Vector3:
	var vp := tree().root.get_viewport()
	var cam := vp.get_camera_3d() if vp != null else null
	if cam != null:
		return cam.global_position
	var p := player()
	return p.global_position + Vector3(0, 0.65, 0) if p != null else Vector3.ZERO


## Distance from the local camera to the nearest visible puppet's capsule axis.
func nearest_puppet_m() -> float:
	return float(session.avatars.nearest_puppet_distance(local_camera_pos()))


## A standing spot `dist` m from `from` toward `dir` (tries the given distances
## and small side angles), on the floor level of `from`, in sight of `from` and
## with room for the capsule. Vector3.INF when none.
func open_spot(from: Vector3, dir: Vector3, dists: Array, why: Array = []) -> Vector3:
	var p := player()
	if p == null or dir.length() < 0.01:
		return Vector3.INF
	var space := p.get_world_3d().direct_space_state
	var mask := int(p.get("respawn_clear_mask")) if p.get("respawn_clear_mask") != null else 15
	var ex: Array[RID] = [(p as CollisionObject3D).get_rid()]
	var flat := Vector3(dir.x, 0, dir.z).normalized()
	for dd in dists:
		for ang in [0.0, 0.35, -0.35, 0.7, -0.7]:
			var c: Vector3 = from + flat.rotated(Vector3.UP, ang) * float(dd)
			var sq := PhysicsRayQueryParameters3D.create(from + Vector3(0, 0.65, 0), c + Vector3(0, 0.65, 0), mask, ex)
			var sh := space.intersect_ray(sq)
			if not sh.is_empty():
				why.append("sight %s" % str(sh.get("collider")))
				continue
			var fq := PhysicsRayQueryParameters3D.create(c + Vector3(0, 0.3, 0), c + Vector3(0, -2.5, 0), mask, ex)
			var hit := space.intersect_ray(fq)
			if hit.is_empty() or absf(float(hit.position.y) - (from.y - 0.975)) > 0.6:
				why.append("floor %s" % (str(hit.position.y) if not hit.is_empty() else "none"))
				continue
			var spot := Vector3(c.x, float(hit.position.y) + 0.975, c.z)
			var shape := CapsuleShape3D.new()
			shape.radius = 0.32
			shape.height = 1.9
			var q := PhysicsShapeQueryParameters3D.new()
			q.shape = shape
			q.collision_mask = mask
			q.exclude = ex
			q.transform = Transform3D(Basis(), spot + Vector3(0, 0.05, 0))
			var oh := space.intersect_shape(q, 1)
			if not oh.is_empty():
				why.append("blocked %s" % str(oh[0].get("collider")))
				continue
			return spot
	return Vector3.INF


func run() -> void:
	pass
