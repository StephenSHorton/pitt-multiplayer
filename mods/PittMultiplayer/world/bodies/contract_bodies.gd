extends RefCounted
## BODIES game contract (MP2-DESIGN 10.7): features mp2.bodies, mp2.wsnap.
## Same format as loader/core/contract.gd ("feature|target|kind|member");
## checked at boot with api.contract_check (main.gd) and by
## tools/contract_check.py against decomp/. Any missing member disables
## multiplayer as a whole (MP1 11). RigidBody3D members are engine API.
## GREPS: literal snippets that must still exist in a decomp script.

const ENTRIES := [
	# object pools (3.3, 3.4, 3.7)
	"mp2.bodies|ObjectPoolManager|prop|_pools",
	"mp2.bodies|ObjectPoolManager|prop|_initialized",
	"mp2.bodies|ObjectPoolManager|method|spawn",
	"mp2.bodies|ObjectPoolManager|method|recycle",
	"mp2.bodies|ObjectPoolManager|const|POOL_CONFIG",
	"mp2.bodies|ObjectPoolManager|const|STARTER_CRATE_META",
	"mp2.bodies|ObjectPoolManager|method|_activate",
	"mp2.bodies|ObjectPoolManager|method|_deactivate",
	"mp2.bodies|PerformanceMonitor|prop|current_state",
	# shared banks (3.8, D14)
	"mp2.bodies|GameState|prop|bank",
	"mp2.bodies|GameState|prop|mining_bank",
	"mp2.bodies|GameState|signal|bank_updated",
	"mp2.bodies|GameState|prop|total_money_gained",
	"mp2.bodies|GameState|prop|total_money_spent",
	"mp2.bodies|GameState|prop|total_products",
	"mp2.bodies|GameState|prop|max_combo",
	"mp2.bodies|GameState|prop|total_combos",
	"mp2.bodies|GameState|prop|combo_bonus_total",
	"mp2.bodies|GameState|prop|safety_violations",
	"mp2.bodies|GameState|prop|long_range_feeds",
	"mp2.bodies|GameState|prop|panel_ricochet_feeds",
	"mp2.bodies|GameState|prop|cameras_destroyed",
	"mp2.bodies|GameState|prop|total_wodden_gambling_crates",
	"mp2.bodies|GameState|prop|max_simultaneous_toggle_tools",
	"mp2.bodies|GameState|prop|peak_production_rate",
	# world snapshot / strip table (3.7, 3.8)
	"mp2.wsnap|SaveManager|prop|is_loading",
	"mp2.wsnap|SaveManager|method|_save_object_pools",
	"mp2.wsnap|SaveManager|method|_load_object_pools",
	"mp2.wsnap|SaveManager|method|_is_press_in_scene",
	"mp2.wsnap|SaveManager|method|_is_terminal_in_scene",
	"mp2.wsnap|SaveManager|method|_is_bowling_set_in_scene",
	"mp2.wsnap|SaveManager|method|_save_pickaxe",
	# the setters the client meta apply calls (3.5), as _load_object_pools does
	"mp2.bodies|res://scripts/fan.gd|method|remote_toggle",
	"mp2.bodies|res://scripts/fan.gd|method|update_fan_state",
	"mp2.bodies|res://scripts/fan.gd|prop|is_active",
	"mp2.bodies|res://scripts/candy.gd|method|_apply_tint",
	"mp2.bodies|res://scripts/anomaly.gd|method|set_crude_source",
	"mp2.bodies|res://scripts/anomaly.gd|method|set_grade",
	"mp2.bodies|res://scripts/anomaly.gd|prop|grade",
	"mp2.bodies|res://scripts/debris.gd|method|_apply_variant",
	"mp2.bodies|res://scripts/feed_camera.gd|method|apply_placed_state",
	"mp2.bodies|res://scripts/feed_camera.gd|prop|camera_id",
	"mp2.bodies|res://scripts/feed_screen.gd|prop|watched_camera_id",
	"mp2.bodies|res://scripts/piston.gd|method|apply_piston_save_data",
	"mp2.bodies|res://scripts/piston.gd|method|get_piston_save_data",
	"mp2.bodies|res://scripts/piston_2.gd|method|set_preset",
	"mp2.bodies|res://scripts/piston_2.gd|prop|_current_preset_index",
	"mp2.bodies|res://scripts/cash_register.gd|method|_update_value_label",
	"mp2.bodies|res://scripts/shift_scheduler.gd|method|_update_screen",
	"mp2.bodies|res://scripts/shift_scheduler.gd|prop|scheduler_mode",
	"mp2.bodies|res://scripts/stat_sign.gd|method|_refresh",
	"mp2.bodies|res://scripts/stat_sign.gd|prop|stat_index",
	"mp2.bodies|res://scripts/remote.gd|method|_update_screen",
	"mp2.bodies|res://scripts/remote.gd|prop|current_channel",
	"mp2.bodies|res://scripts/magnet.gd|method|_is_repell",
	"mp2.bodies|res://scripts/magnet_2.gd|method|flip_mode",
	"mp2.bodies|res://scripts/flat_duck.gd|method|flatten_mesh_world_y",
	"mp2.bodies|res://scripts/flat_duck.gd|method|restore_mesh",
	"mp2.bodies|res://scripts/flat_duck.gd|prop|is_flattened",
	"mp2.bodies|res://scripts/slick_panel.gd|method|_rebuild_merge_group",
	"mp2.bodies|res://scripts/panel.gd|prop|state",
	"mp2.bodies|res://scripts/vacuum.gd|method|get_bag_save_data",
	"mp2.bodies|res://scripts/vacuum.gd|prop|_bag_items",
	"mp2.bodies|res://scripts/cannon.gd|method|get_queue_save_data",
	"mp2.bodies|res://scripts/cannon.gd|prop|_queue",
	# hole (MP1 hole_ext, BODIES)
	"mp2.bodies|res://scripts/hole.gd|method|_check_phase_completion",
	"mp2.bodies|res://scripts/hole.gd|method|_trigger_ending",
]

const GREPS := [
	"res://scripts/panel.gd|enum PanelState",
	"res://scripts/object_pool_manager.gd|obj.visible = true",
	"res://scripts/object_pool_manager.gd|obj.visible = false",
	"res://scripts/save_manager.gd|obj.has_meta(\"in_cannon_barrel\")",
	"res://scripts/save_manager.gd|obj.has_meta(\"in_vacuum_bag\")",
]
