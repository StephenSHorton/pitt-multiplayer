extends "res://scripts/main_camera.gd"
## PittMultiplayer GRAB (MP2-DESIGN 5.2-5.6): the local player's carry in a
## shared world. Inert unless a session world is live (first line of every
## override is the vanilla path). Overrides only _begin_carry, drop_object and
## release_held_object; everything else of the carry (joint, gravity, inertia,
## throw) is the game's own code.
##   client: a replicated body is predicted (local sim + own_req), or refused
##           locally when another player holds it or a machine owns it
##   host  : the host player cannot take what a client holds; its own grabs
##           enter the same ownership table


func _mp_grab() -> Object:
	if not Engine.has_meta("pitt_mp"):
		return null
	var mp = Engine.get_meta("pitt_mp", null)
	if mp == null or not is_instance_valid(mp) or not mp.has_method("get_module"):
		return null
	var g = mp.get_module("grab")
	if g == null or not g.has_method("ext_live") or not g.ext_live():
		return null
	return g


func _begin_carry(obj: RigidBody3D, keep_hands: bool = false) -> void:
	var g := _mp_grab()
	if g == null:
		super(obj, keep_hands)
		return
	if not g.ext_begin_carry(self, obj, keep_hands):
		return
	super(obj, keep_hands)
	g.ext_carry_started(self, obj)


func drop_object(force: bool = false):
	var g := _mp_grab()
	if g == null:
		super(force)
		return
	var held: RigidBody3D = picked_object
	g.ext_drop(self, held, force)
	super(force)
	g.ext_drop_done(self, held)


func release_held_object() -> void:
	var g := _mp_grab()
	if g != null:
		g.ext_release(self)
	super()
