extends Node
## Fixture: well-behaved; counts test.boom events.
var api
var calls := 0


func _mod_init(p) -> void:
	api = p
	api.events.on("test.boom", _on_boom)


func _on_boom(_ev) -> void:
	calls += 1
