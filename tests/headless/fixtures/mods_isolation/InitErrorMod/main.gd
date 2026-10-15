extends Node
## Fixture: _mod_init raises an error, so the mod must be quarantined.
var api


func _mod_init(p) -> void:
	api = p
	api.events.on("test.boom", func(_e): pass)
	var nothing = null
	nothing.explode()
