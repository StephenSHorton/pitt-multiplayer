extends "res://scripts/vacuum_2.gd"
## MP2 4.5: tuning and the filter go to the host. Intake, bag and equipped input
## are vacuum_ext's (applied first, so this script's base is the extended vacuum.gd).

const G = preload("../../gameplay/mp_gate.gd")


## P12 force guard: vacuum_2.gd's filter replaces vacuum.gd's (no super), so
## vacuum_ext's space check is repeated here, ahead of the filter group check.
func _suction_accepts(body: RigidBody3D) -> bool:
	if not PhysicsServer3D.body_get_space(body.get_rid()).is_valid():
		return false
	return super(body)


func scroll_tune_up() -> void:
	if G.input(self, "scroll_tune_up"):
		return
	super()


func scroll_tune_down() -> void:
	if G.input(self, "scroll_tune_down"):
		return
	super()


func cycle_filter(direction: int) -> void:
	if G.input(self, "cycle_filter", [direction]):
		return
	super(direction)


func remote_toggle(on: bool) -> void:
	if G.replay(self):
		return
	super(on)
