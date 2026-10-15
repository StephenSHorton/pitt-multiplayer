extends RigidBody3D
## Headless stand-in for res://scripts/anomaly.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/anomaly_ext.gd compile
## and be exercised headless.


var pool_id = "effigy"
var base_value: int = 0
var grade: int = 0
var value: int = 0
var crude_source: int = 0
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready() -> void:
	pass

func _physics_process(_delta: float) -> void:
	pass

func _process(delta: float) -> void:
	pass

func _on_body_entered(body: Node) -> void:
	_stub("_on_body_entered")

func _process_impact_deferred(body: Node, impact_force: float, is_tool: bool) -> void:
	_stub("_process_impact_deferred")

func _calculate_collision_volume(impact_force: float) -> float:
	_stub("_calculate_collision_volume")
	return 0.0

func _is_held() -> bool:
	_stub("_is_held")
	return false

func _is_on_cushion() -> bool:
	_stub("_is_on_cushion")
	return false

func set_highlight(active: bool, grabbed: bool = false) -> void:
	_stub("set_highlight")

func object_name() -> String:
	_stub("object_name")
	return ""

func on_pool_spawn() -> void:
	_stub("on_pool_spawn")

func on_pool_recycle() -> void:
	_stub("on_pool_recycle")

func set_grade(g: int) -> void:
	_stub("set_grade")

func set_crude_source(src: int) -> void:
	_stub("set_crude_source")
