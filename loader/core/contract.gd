extends RefCounted
## Game contract: every game member the bridge, facades and core commands touch.
## Format of each entry: "feature|target|kind|member"
##   target: an autoload name (checked at boot) or a res:// scene script path
##           (checked when a node using that script appears).
##   kind:   method | signal | prop | const
## If any member of a feature is missing, that feature is disabled: its commands
## return ERR_UNAVAILABLE and its events stop. tools/contract_check.py checks the
## same list against the decompiled sources (keep this format parseable).

const ENTRIES := [
	"economy|GameState|prop|money",
	"economy|GameState|prop|total_money_gained",
	"economy|GameState|prop|total_money_spent",
	"economy|GameState|method|add_money",
	"economy|GameState|method|add_bonus",
	"economy|GameState|method|spend",
	"economy|GameState|method|can_afford",
	"economy|GameState|signal|money_updated",
	"economy|GameState|signal|stat_changed",
	"bank|GameState|prop|bank",
	"bank|GameState|signal|bank_updated",
	"items|GameState|prop|upgrades",
	"items|GameState|prop|tools",
	"items|GameState|prop|toys",
	"items|GameState|prop|products",
	"items|GameState|prop|combos",
	"items|GameState|method|buy",
	"session|GameState|prop|is_game_started",
	"session|GameState|prop|sandbox_mode",
	"phase|GameProgression|prop|current_phase",
	"phase|GameProgression|prop|ending_active",
	"phase|GameProgression|signal|phase_changed",
	"phase|GameProgression|method|change_phase",
	"newgame|GameProgression|method|reset_run_state",
	"combo|ComboSystem|signal|combo_started",
	"combo|ComboSystem|signal|combo_updated",
	"combo|ComboSystem|signal|combo_ended",
	"combo|ComboSystem|signal|combo_broken",
	"combo|ComboSystem|signal|mega_combo_activated",
	"unlocks|UnlockManager|prop|milestones",
	"unlocks|UnlockManager|prop|unlocked_milestones",
	"unlocks|UnlockManager|signal|milestone_unlocked",
	"unlocks|UnlockManager|method|force_unlock",
	"unlocks|UnlockManager|method|is_unlocked",
	"unlocks|UnlockManager|method|_get_stat",
	"saves|SaveManager|prop|save_locked",
	"saves|SaveManager|prop|autosave_enabled",
	"saves|SaveManager|prop|active_save_path",
	"saves|SaveManager|prop|_last_save_tick",
	"saves|SaveManager|prop|is_loading",
	"saves|SaveManager|prop|pending_pool_data",
	"saves|SaveManager|signal|save_loaded",
	"saves|SaveManager|method|set_active_save_path",
	"saves|SaveManager|method|slot_path",
	"saves|SaveManager|const|MAX_SAVE_SLOTS",
	"newgame|SaveManager|prop|should_load_on_ready",
	"newgame|SaveManager|prop|pending_camera_data",
	"spawn|ObjectPoolManager|prop|_pools",
	"spawn|ObjectPoolManager|prop|_initialized",
	"spawn|ObjectPoolManager|method|spawn",
	"spawn|ObjectPoolManager|method|recycle",
	"spawn|ObjectPoolManager|method|pool_headroom",
	"input|InputManager|prop|current_bindings",
	"input|InputManager|signal|bindings_changed",
	"input|InputManager|method|get_key_name",
	"input|InputManager|method|get_action_for_key",
	"menu|MenuManager|prop|current_menu",
	"menu|MenuManager|prop|game_paused",
	"achievements|Steamworks|prop|_granted",
	"achievements|Steamworks|prop|_probe_ids",
	"achievements|Steamworks|method|unlock_achievement",
	"presence|Steamworks|prop|_presence_accum",
	"presence|Steamworks|method|clear_presence",
	"perf|PerformanceMonitor|method|get_current_tick_rate",
	"newgame|res://scripts/main_menu.gd|method|_launch_game",
	"newgame|res://scripts/main_menu.gd|prop|_pending_new_game",
	"player|res://scripts/player_controller.gd|method|teleport_to",
	"player|res://scripts/player_controller.gd|method|teleport_to_transform",
	"player|res://scripts/player_controller.gd|method|apply_external_impulse",
	"camera|res://scripts/main_camera.gd|prop|picked_object",
	"camera|res://scripts/main_camera.gd|prop|equipped_item",
	"camera|res://scripts/interact_ray.gd|prop|last_collider",
	"hud|res://scripts/hud.gd|method|show_notification_message",
	"hud|res://scripts/hud.gd|method|_spawn_special_bonus_text",
	"maw|res://scripts/bottom_maw.gd|signal|product_consumed",
	"gates|res://scripts/vertical_gate.gd|signal|gate_opened",
	"gates|res://scripts/vertical_gate.gd|prop|gate_id",
	"hole|res://scripts/hole.gd|method|get_phase_progress",
	"upgrade_ui|res://scripts/upgradeUI.gd|method|update_ui",
]

var _entries: Array = []
var _missing: Dictionary = {}      # feature -> Array[String]
var _checked_targets: Dictionary = {}
var features: Dictionary = {}      # feature -> true/false


## include_core = false: a checker for only extra_entries (api.contract_check, L4).
func _init(extra_entries: Array = [], include_core: bool = true) -> void:
	for e in (ENTRIES + extra_entries if include_core else extra_entries):
		var p: PackedStringArray = String(e).split("|")
		if p.size() != 4:
			continue
		_entries.append({"feature": p[0], "target": p[1], "kind": p[2], "member": p[3]})
		features[p[0]] = true


## Checks every autoload-targeted entry. lookup: Callable(name) -> Object or null.
func check_autoloads(lookup: Callable) -> void:
	for e in _entries:
		if e.target.begins_with("res://"):
			continue
		var obj = lookup.call(e.target)
		_check_one(e, obj)


## Checks scene-script entries against a live node (first time a node of that
## script is seen). Returns the features that were (re)evaluated.
func check_node(node: Object) -> Array:
	if node == null or not is_instance_valid(node):
		return []
	var s = node.get_script()
	var paths: Array = []
	while s != null:
		if s.resource_path != "":
			paths.append(s.resource_path)
		s = s.get_base_script()
	var touched: Array = []
	for e in _entries:
		if not e.target.begins_with("res://"):
			continue
		if not (e.target in paths):
			continue
		_check_one(e, node)
		if not (e.feature in touched):
			touched.append(e.feature)
		_checked_targets[e.target] = true
	return touched


## Checks every res:// script target by introspection of the script resource
## and its base scripts (no node needed). A missing script fails all of its entries.
func check_script_targets() -> void:
	var cache: Dictionary = {}
	for e in _entries:
		if not e.target.begins_with("res://"):
			continue
		if not cache.has(e.target):
			cache[e.target] = load(e.target) if ResourceLoader.exists(e.target) else null
		_check_script_one(e, cache[e.target])
		_checked_targets[e.target] = true


func _check_script_one(e: Dictionary, script: Variant) -> void:
	var ok := false
	var s: Script = script as Script
	while s != null and not ok:
		match e.kind:
			"method":
				for m in s.get_script_method_list():
					if m.name == e.member:
						ok = true
						break
			"signal":
				for sg in s.get_script_signal_list():
					if sg.name == e.member:
						ok = true
						break
			"prop":
				for p in s.get_script_property_list():
					if p.name == e.member:
						ok = true
						break
			"const":
				ok = s.get_script_constant_map().has(e.member)
		s = s.get_base_script()
	if not ok:
		var label := "%s.%s (%s)" % [e.target, e.member, e.kind]
		if not _missing.has(e.feature):
			_missing[e.feature] = []
		if not (label in _missing[e.feature]):
			_missing[e.feature].append(label)
		features[e.feature] = false


func is_target_checked(target: String) -> bool:
	return _checked_targets.has(target)


func _check_one(e: Dictionary, obj: Object) -> void:
	var ok := false
	if obj != null and is_instance_valid(obj):
		match e.kind:
			"method": ok = obj.has_method(e.member)
			"signal": ok = obj.has_signal(e.member)
			"prop": ok = e.member in obj
			"const":
				var sc = obj.get_script()
				ok = sc != null and sc.get_script_constant_map().has(e.member)
	var label := "%s.%s (%s)" % [e.target, e.member, e.kind]
	if not ok:
		if not _missing.has(e.feature):
			_missing[e.feature] = []
		if not (label in _missing[e.feature]):
			_missing[e.feature].append(label)
		features[e.feature] = false


func is_available(feature: String) -> bool:
	return bool(features.get(feature, true))


func disabled_features() -> Array:
	var out: Array = []
	for f in features:
		if not features[f]:
			out.append(f)
	out.sort()
	return out


func missing() -> Dictionary:
	return _missing.duplicate(true)


func entries() -> Array:
	return _entries.duplicate(true)


func report() -> Dictionary:
	return {"features": features.duplicate(), "disabled": disabled_features(), "missing": missing()}
