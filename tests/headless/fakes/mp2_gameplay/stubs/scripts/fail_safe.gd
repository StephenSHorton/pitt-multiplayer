extends Area3D
## Headless stand-in for res://scripts/fail_safe.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/fail_safe_ext.gd compile
## and be exercised headless.


var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _on_body_entered(body: Node) -> void:
	_stub("_on_body_entered")
