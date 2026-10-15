extends RayCast3D
## Headless stand-in for res://scripts/interact_ray.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/interact_ray_ext.gd compile
## and be exercised headless.


var interact_ray: RayCast3D = null
var camera: Camera3D = null
var last_collider: Node3D = null
var _lmb_edge: bool = false
var _toggle_frame: int = 0
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready() -> void:
	pass

## Headless double of the LMB toggle the extension wraps: a press (InputEventAction
## "lMouse", no InputMap headless) flips the automated workbench under the ray.
func _input(event: InputEvent) -> void:
	var act := event as InputEventAction
	if act == null or act.action != "lMouse" or act.pressed == _lmb_edge:
		return
	_lmb_edge = act.pressed
	var bench := last_collider
	if not act.pressed or bench == null or not bench.is_in_group("automated_workbench"):
		return
	var verb := "turn_off" if bench.get("is_turned_on") else "turn_on"
	if bench.has_method(verb):
		bench.call(verb)
	_toggle_frame = int(Engine.get_process_frames())

func _process(_delta: float) -> void:
	pass

func handle_workbench_interaction():
	_stub("handle_workbench_interaction")

func _stop_crafting_if_manual(bench: Node) -> void:
	_stub("_stop_crafting_if_manual")

func handle_automated_workbench_interaction():
	_stub("handle_automated_workbench_interaction")

func handle_terminal_interaction(delta: float) -> void:
	_stub("handle_terminal_interaction")

func handle_button_interaction():
	_stub("handle_button_interaction")

func refresh_controls() -> void:
	_stub("refresh_controls")
