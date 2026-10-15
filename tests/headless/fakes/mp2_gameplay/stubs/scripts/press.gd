extends StaticBody3D
## Headless stand-in for res://scripts/press.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/press_ext.gd compile
## and be exercised headless.


var is_pressing: bool = false
var items_to_crush: Array = []
var is_player_in: bool = false
var player: Node3D = null
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready():
	pass

func object_name() -> String:
	_stub("object_name")
	return ""

func interact():
	_stub("interact")

func start_pressing():
	_stub("start_pressing")

func process_crushed_items():
	_stub("process_crushed_items")

func _spawn_pending_anomalies() -> void:
	_stub("_spawn_pending_anomalies")

func replace_with_flat_product(product: RigidBody3D):
	_stub("replace_with_flat_product")

func set_highlight(active: bool, grabbed: bool = false) -> void:
	_stub("set_highlight")
