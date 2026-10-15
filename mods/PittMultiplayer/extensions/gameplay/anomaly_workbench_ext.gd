extends "res://scripts/anomaly_workbench.gd"
## MP2 4.4: the cauldron's intake, rituals and products run on the host (holder set
## for hold-to-craft, tuning through the host). Counts, purity and the black sphere
## replay on clients from meta. Ingredients being pulled into a ritual cannot be
## grabbed (deny rule) and a remote owner loses them.

const G = preload("../../gameplay/mp_gate.gd")


var _mp_ritual: Array = []


func interact() -> void:
	if G.input(self, "interact"):
		return
	super()


func start_crafting() -> void:
	if G.bench_start(self):
		return
	super()


func stop_crafting() -> void:
	if G.bench_stop(self):
		return
	if not G.bench_release(self):
		return
	await super()


func scroll_tune_up() -> void:
	if G.input(self, "scroll_tune_up"):
		return
	super()


func scroll_tune_down() -> void:
	if G.input(self, "scroll_tune_down"):
		return
	super()


func _on_body_entered(body: Node) -> void:
	if G.sink(self):
		return
	super(body)


func _register_ingredient(body: Node) -> void:
	if G.sink(self):
		return
	super(body)


func _on_body_exited(body: Node) -> void:
	if G.sink(self):
		return
	super(body)


func _rescan_intake() -> void:
	if G.sink(self):
		return
	super()


func _start_ritual() -> void:
	if G.sink(self):
		return
	super()
	G.host_after(self)


func _complete_ritual() -> void:
	if G.sink(self):
		return
	super()
	_mp_clear_ritual()
	G.host_after(self)


func _abort_ritual() -> void:
	if G.sink(self):
		return
	super()
	_mp_clear_ritual()
	G.host_after(self)


func _refuse_ingredient(body: Node) -> void:
	if G.sink(self):
		return
	super(body)


func _spiral_suction_ingredient(body: RigidBody3D, center: Vector3, start_angle: float) -> void:
	if G.sink(self):
		return
	if is_instance_valid(body):
		body.set_meta("pitt_mp_ritual", true)
		_mp_ritual.append(body)
		G.consumed(body, "ritual")
	super(body, center, start_angle)


func _spawn_effigy(lucky_ingredient_count: int, grade: int = GRADE_PURE, from_gambled: bool = false, crude_source: int = 0) -> void:
	if G.sink(self):
		return
	super(lucky_ingredient_count, grade, from_gambled, crude_source)


func _spawn_keycard() -> void:
	if G.sink(self):
		return
	super()


func _eject_pickaxe() -> void:
	if G.sink(self):
		return
	super()


func _freeze_pickaxe_catalyst() -> void:
	if G.sink(self):
		return
	super()


func _mp_clear_ritual() -> void:
	for b in _mp_ritual:
		if is_instance_valid(b) and b.has_meta("pitt_mp_ritual"):
			b.remove_meta("pitt_mp_ritual")
	_mp_ritual.clear()
