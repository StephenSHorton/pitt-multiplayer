extends RefCounted
## Ghost colliders for remote players (MP2-DESIGN 6.5), host only. One
## AnimatableBody3D per remote in-game peer, moved every physics frame to the
## peer's newest avatar pose (capsule centre, extrapolated at most EXTRAP_MAX_S),
## so host bodies are pushed by remote players. On the player layer, mask 0,
## groups pitt_mp_ghost + maw_inert, meta pitt_mp_ghost_peer, never in group
## "player" (every is_in_group("player") branch of the game ignores it, D10), and a
## collision exception with the host's own player (players pass through each
## other, D22). Explicit users: qa_arm whack, the weight plate (D18).

const RADIUS := 0.35
const HEIGHT := 1.95
const PLAYER_LAYER := 2
const EXTRAP_MAX_S := 0.15

var gp = null
var _ghosts: Dictionary = {}       # peer -> AnimatableBody3D
var _root: Node3D = null


func _init(p_gp) -> void:
	gp = p_gp


func ghost_of(peer: int) -> Node3D:
	var g = _ghosts.get(peer, null)
	return g if g != null and is_instance_valid(g) else null


func peers() -> Array:
	return _ghosts.keys()


func add_peer(peer: int) -> Node3D:
	var existing := ghost_of(peer)
	if existing != null:
		return existing
	var root := _ensure_root()
	if root == null:
		return null
	var body := AnimatableBody3D.new()
	body.name = "Ghost_%d" % peer
	body.sync_to_physics = true
	body.collision_layer = PLAYER_LAYER
	body.collision_mask = 0
	body.add_to_group("pitt_mp_ghost")
	body.add_to_group("maw_inert")
	body.set_meta("pitt_mp_ghost_peer", peer)
	var shape := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = RADIUS
	cap.height = HEIGHT
	shape.shape = cap
	body.add_child(shape)
	root.add_child(body)
	var p = gp.adapter.local_player() if gp.adapter != null else null
	if p != null and p is PhysicsBody3D:
		body.add_collision_exception_with(p)
	_ghosts[peer] = body
	_place(peer, body)
	return body


func remove_peer(peer: int) -> void:
	var g := ghost_of(peer)
	_ghosts.erase(peer)
	if g != null:
		g.queue_free()


func clear() -> void:
	for p in _ghosts.keys():
		var g := ghost_of(int(p))
		if g != null:
			g.queue_free()
	_ghosts.clear()
	if _root != null and is_instance_valid(_root):
		_root.queue_free()
	_root = null


func physics(_delta: float) -> void:
	for p in _ghosts.keys():
		var g := ghost_of(int(p))
		if g != null:
			_place(int(p), g)


func _place(peer: int, g: Node3D) -> void:
	if not g.is_inside_tree():
		return
	var pose: Dictionary = gp.avatar_pose(peer)
	if not bool(pose.get("ok", false)):
		return
	var age_s := clampf(float(gp.host_now() - int(pose.get("t_ms", 0))) / 1000.0, 0.0, EXTRAP_MAX_S)
	var vel: Vector3 = pose.get("vel", Vector3.ZERO)
	var pos: Vector3 = pose.get("pos", Vector3.ZERO)
	g.global_transform = Transform3D(Basis(Vector3.UP, float(pose.get("yaw", 0.0))), pos + vel * age_s)


func _ensure_root() -> Node3D:
	if _root != null and is_instance_valid(_root) and _root.is_inside_tree():
		return _root
	var parent: Node = gp.world_parent()
	if parent == null:
		return null
	_root = Node3D.new()
	_root.name = "PittMP_Ghosts"
	parent.add_child(_root)
	return _root
