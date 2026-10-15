extends Node
## Fixture: every handler call raises a runtime error.
var api
var calls := 0


func _mod_init(p) -> void:
	api = p
	api.events.on("test.boom", _on_boom)
	api.commands.register("ThrowerMod.noop", func(_a, _c): return 1)
	api.console.register("throw", func(_a): return "x")


func _on_boom(_ev) -> void:
	calls += 1
	var nothing = null
	nothing.explode()
