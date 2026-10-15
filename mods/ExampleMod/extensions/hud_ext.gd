extends "res://scripts/hud.gd"
## Thin script extension of the World HUD (applied by PittAPI with take_over_path
## before the world loads). It keeps the game's behaviour (super) and only
## forwards a hook; the logic lives in ExampleMod/main.gd where errors are isolated.
## No class_name, extends by path.


func show_result(combo_level, total_bonus):
	super.show_result(combo_level, total_bonus)
	var core = get_node_or_null("/root/PittAPI")
	if core != null and core.has_method("ext_hook"):
		core.ext_hook("ExampleMod", "hud_result", {"level": combo_level, "bonus": total_bonus})
