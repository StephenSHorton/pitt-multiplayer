extends Node
## Deliberately broken: this file must fail to compile (the boot suite
## expects this mod to be FAILED while every other mod still loads).

func _mod_init(api) -> void:
	var x = 
