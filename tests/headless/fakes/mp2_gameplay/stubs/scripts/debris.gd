extends RigidBody3D
## Headless stand-in for res://scripts/debris.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/debris_ext.gd compile
## and be exercised headless.


var pool_id = "debris_chunk"
var current_variant: String = ""
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

func _apply_variant(variant_group: String) -> void:
	_stub("_apply_variant")

func _on_body_entered(body: Node3D) -> void:
	_stub("_on_body_entered")

func _destroy_tool(tool: Node3D) -> void:
	_stub("_destroy_tool")

func _respawn_tool_via_tube(tool_pool_id: String) -> void:
	_stub("_respawn_tool_via_tube")

func _spawn_destruction_effect(at_transform: Transform3D) -> void:
	_stub("_spawn_destruction_effect")

func _apply_landing_shake(force: float) -> void:
	_stub("_apply_landing_shake")

func object_name():
	_stub("object_name")

func on_pool_spawn() -> void:
	_stub("on_pool_spawn")

func on_pool_recycle() -> void:
	_stub("on_pool_recycle")
