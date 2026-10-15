extends StaticBody3D
## Headless stand-in for res://scripts/anomaly_workbench.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/anomaly_workbench_ext.gd compile
## and be exercised headless.

const GRADE_PURE = 2
var duck_count: int = 0
var crown_count: int = 0
var bear_count: int = 0
var is_ritualizing: bool = false
var ritual_elapsed: float = 0.0
var min_purity: int = 0
var is_crafting: bool = false
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready() -> void:
	pass

func _process(delta: float) -> void:
	pass

func _physics_process(delta: float) -> void:
	pass

func object_name() -> String:
	_stub("object_name")
	return ""

func interact() -> void:
	_stub("interact")

func start_crafting() -> void:
	_stub("start_crafting")

func stop_crafting() -> void:
	_stub("stop_crafting")

func _complete_ritual() -> void:
	_stub("_complete_ritual")

func _abort_ritual() -> void:
	_stub("_abort_ritual")

func _refuse_ingredient(body: Node) -> void:
	_stub("_refuse_ingredient")

func _rescan_intake() -> void:
	_stub("_rescan_intake")

func _on_body_entered(body: Node) -> void:
	_stub("_on_body_entered")

func _register_ingredient(body: Node) -> void:
	_stub("_register_ingredient")

func _on_body_exited(body: Node) -> void:
	_stub("_on_body_exited")

func _start_ritual() -> void:
	_stub("_start_ritual")

func _spiral_suction_ingredient(body: RigidBody3D, center: Vector3, start_angle: float) -> void:
	_stub("_spiral_suction_ingredient")

func _reveal_black_sphere() -> void:
	_stub("_reveal_black_sphere")

func _collapse_black_sphere() -> void:
	_stub("_collapse_black_sphere")

func _update_indicator() -> void:
	_stub("_update_indicator")

func _spawn_effigy(lucky_ingredient_count: int, grade: int = GRADE_PURE, from_gambled: bool = false, crude_source: int = 0) -> void:
	_stub("_spawn_effigy")

func _spawn_keycard() -> void:
	_stub("_spawn_keycard")

func _eject_pickaxe() -> void:
	_stub("_eject_pickaxe")

func _calculate_launch_impulse(start: Vector3, target: Vector3, mass: float) -> Vector3:
	_stub("_calculate_launch_impulse")
	return Vector3.ZERO

func set_highlight(active: bool, _grabbed: bool = false) -> void:
	_stub("set_highlight")

func _resolve_outlines() -> void:
	_stub("_resolve_outlines")

func _collect_outlines_recursive(node: Node) -> void:
	_stub("_collect_outlines_recursive")

func update_crafting_sound_pitch(progress: float):
	_stub("update_crafting_sound_pitch")

func show_progress_bar(visible_: bool) -> void:
	_stub("show_progress_bar")

func update_progress_bar(value: float) -> void:
	_stub("update_progress_bar")

func _freeze_pickaxe_catalyst() -> void:
	_stub("_freeze_pickaxe_catalyst")

func _driven_by_proxy() -> bool:
	_stub("_driven_by_proxy")
	return false

func scroll_tune_up() -> void:
	_stub("scroll_tune_up")

func scroll_tune_down() -> void:
	_stub("scroll_tune_down")
