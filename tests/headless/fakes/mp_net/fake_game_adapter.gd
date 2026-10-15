extends "res://gamedir/mods/PittMultiplayer/game/game_adapter.gd"
## Per-peer FakeGameAdapter (MP-DESIGN 10.1). It EXTENDS the production
## GameAdapter and only swaps where the game lives: g(name) returns this peer's
## own fake autoloads and _group(name) its own fake world nodes, so the real
## adapter code (mirror, post-hooks, stats, unlock detach, snapshot collectors,
## money chunks) runs in tests. Everything process-global (the tree pause,
## InputMap, the current scene) is simulated per peer instead.
## Our own minimal stand-ins; no game code.

const UpgradeUIStub = preload("res://scripts/upgradeUI.gd")
const HoleStub = preload("res://scripts/hole.gd")
const PauseMenuStub = preload("res://scripts/pause_menu.gd")


class FGameState extends Node:
	signal stat_changed(stat_name: String, new_value)
	signal money_updated(new_amount)
	var money = BigInt.from_int(0)
	var total_money_gained = BigInt.from_int(0)
	var total_money_spent = BigInt.from_int(0)
	var total_bonus_earned = BigInt.from_int(0)
	var is_game_started := false
	var sandbox_mode := false
	var purchased_once: Dictionary = {}
	var products_consumed := {"duck": 0, "cash_register": 0}
	var products_crafted := {"duck": 0}
	var products_autocrafted := {"duck": 0}
	var money_per_product := {"duck": BigInt.from_int(0)}
	var total_products_consumed := 0
	var remote_tier_applied := 0
	var upgrades := {
		"sprint": {"level": 0, "prices": [50, 100], "enabled": true},
		"crouch": {"level": 0, "prices": [60], "enabled": true},
		"slide": {"level": 0, "prices": [70], "enabled": false},
		"luck": {"level": 0, "prices": [100, 200, 400], "enabled": false},
		"gated": {"level": 0, "prices": [10, 20], "enabled": true, "enabled_levels": [true, false]},
		"remote_tier": {"level": 0, "prices": [500], "enabled": true},
	}
	var tools := {
		"broom": {"level": 0, "prices": [99999], "buy_prices": [500, 900], "enabled": true, "enabled_levels": [true, false]},
		"fan": {"level": 0, "prices": [1], "buy_prices": [300], "enabled": false, "enabled_levels": [true]},
	}
	var toys := {
		"gambling_wodden_crate": {"level": 0, "buy_prices": [5], "enabled": true},
		"bumper": {"level": 0, "buy_prices": [1000], "enabled": false},
		"bowling_pin_set": {"level": 0, "buy_prices": [50], "enabled": true},
		"spinner": {"level": 0, "prices": [40, 80], "enabled": true},
	}
	var products := {"duck": {"enabled": true,
		"craft_speed": {"level": 0, "prices": [10, 20]},
		"auto_machine": {"level": 0, "prices": [1000]}},
		"crown": {"enabled": false, "craft_speed": {"level": 0, "prices": [10]}}}
	var combos := {"time_extension": {"level": 0, "prices": [500], "enabled": true}}
	var buy_calls: Array = []
	var ws = null   # FWorkbench, for the auto_machine side effect of buy()

	func add_money(amount, _product_type: String = "") -> void:
		var n := roundi(float(amount))
		for counter in [money, total_money_gained]:
			counter.add_int(n)
		emit_signal("money_updated", money)
		emit_signal("stat_changed", "total_money_gained", total_money_gained)

	func can_afford(amount) -> bool:
		return money.compare_int(roundi(float(amount))) != -1

	func spend(amount) -> void:
		var n := roundi(float(amount))
		money.sub_int(n)
		total_money_spent.add_int(n)
		emit_signal("money_updated", money)

	func apply_remote_tier(_t: int = -1) -> void:
		remote_tier_applied += 1

	## A leveled buy. Like the game, an auto_machine purchase tells the workbench
	## BEFORE the affordability check, so the host-side guard is tested.
	func buy(category: String, key: String, subkey := "") -> bool:
		buy_calls.append([category, key, subkey])
		var entry: Dictionary = get(category)[key]
		if subkey != "":
			entry = entry[subkey]
		var lvl: int = entry["level"]
		var prices: Array = entry["prices"]
		if lvl >= prices.size():
			return false
		if subkey == "auto_machine" and category == "products" and ws != null:
			ws.auto_machine_purchased(key, lvl)
		if not can_afford(prices[lvl]):
			return false
		spend(prices[lvl])
		entry["level"] = lvl + 1
		if key == "remote_tier" and category == "upgrades":
			apply_remote_tier()
		return true

	func set_money_int(v: int) -> void:
		money = BigInt.from_int(v)
		emit_signal("money_updated", money)


class FProgression extends Node:
	signal phase_changed(new_phase: int)
	var current_phase := 0
	var elevator_exited := false
	var ending_active := false
	var change_calls: Array = []
	## true: change_phase only moves current_phase (a transition "in progress");
	## settle() emits phase_changed like the end of the game's cinematic.
	var async_transitions := false

	func change_phase(p: int) -> void:
		change_calls.append(p)
		if p == current_phase:
			return
		current_phase = p
		if p >= 5:
			ending_active = true
		if not async_transitions or p == 1:
			phase_changed.emit(p)

	func settle() -> void:
		phase_changed.emit(current_phase)

	func reset_run_state() -> void:
		ending_active = false
		elevator_exited = false


class FUnlocks extends Node:
	signal milestone_unlocked(milestone_id: String, milestone_data: Dictionary)
	var unlocked_milestones: Array[String] = []
	var milestones := {
		"unlock_luck": {"type": "stat_threshold", "stat": "total_money_gained", "threshold": 100,
			"action": {"unlock_upgrade": "luck"}},
		"unlock_fan": {"type": "phase_reached", "phase": 2, "action": {"unlock_tool": "fan"}},
		"unlock_bumper": {"type": "phase_reached", "phase": 2, "action": {"unlock_toy": "bumper"}},
	}
	var gs = null
	var forced: Array = []
	var checks := 0

	func force_unlock(id: String) -> void:
		if not milestones.has(id) or unlocked_milestones.has(id):
			return
		forced.append(id)
		unlocked_milestones.push_back(id)
		var a: Dictionary = milestones[id].action
		if gs != null:
			if a.has("unlock_upgrade"):
				gs.upgrades[a.unlock_upgrade].enabled = true
			elif a.has("unlock_tool"):
				gs.tools[a.unlock_tool].enabled = true
			elif a.has("unlock_toy"):
				gs.toys[a.unlock_toy].enabled = true
		milestone_unlocked.emit(id, milestones[id])

	func is_unlocked(id: String) -> bool:
		return unlocked_milestones.has(id)

	## a locked milestone whose "requires" are all unlocked unlocks once its stat
	## threshold is met (only stat_threshold is modeled)
	func check_milestones() -> void:
		var is_open := func(r): return unlocked_milestones.has(r)
		for id in milestones:
			var m: Dictionary = milestones[id]
			if unlocked_milestones.has(id) or not Array(m.get("requires", [])).all(is_open):
				continue
			if String(m.type) == "stat_threshold" and gs != null and gs.total_money_gained.compare_int(int(m.threshold)) != -1:
				force_unlock(id)

	func get_save_data() -> Array:
		return unlocked_milestones.slice(0)

	## the real one judges milestones on LOCAL stats: clients must never run it
	func _on_stat_changed(stat_name: String, _v) -> void:
		checks += 1
		if gs != null and stat_name == "total_money_gained" and gs.total_money_gained.compare_int(100) >= 0:
			force_unlock("unlock_luck")

	func _on_phase_changed(_p: int) -> void:
		checks += 1


class FSaveManager extends Node:
	const SAVE_PASSWORD := "test_password_not_the_game"
	var should_load_on_ready := false
	var is_loading := false
	var active_save_path := "user://savegame.save"
	var gs = null
	var hole = null

	func set_active_save_path(p: String) -> void:
		active_save_path = p

	func peek_saved_phase() -> int:
		return 0

	func _save_game_state() -> Dictionary:
		var st := {"money": gs.money.to_plain_string(), "total_money_gained": gs.total_money_gained.to_plain_string(),
			"bank": 123.0, "mining_bank": 7, "panel_stack": ["tool_panel"], "upgrades": {}, "tools": {}, "toys": {},
			"products": {}, "combos": {}}
		for k in gs.upgrades:
			st.upgrades[k] = {"level": gs.upgrades[k].level, "enabled": gs.upgrades[k].enabled}
		for k in gs.tools:
			st.tools[k] = {"level": gs.tools[k].level, "enabled": gs.tools[k].enabled}
		for k in gs.toys:
			st.toys[k] = {"level": gs.toys[k].level, "enabled": gs.toys[k].enabled,
				"buy_prices": gs.toys[k].get("buy_prices", [])}
		for k in gs.products:
			st.products[k] = {"enabled": gs.products[k].enabled}
			for s in gs.products[k]:
				if typeof(gs.products[k][s]) == TYPE_DICTIONARY:
					st.products[k][s] = {"level": gs.products[k][s].level}
		for k in gs.combos:
			st.combos[k] = {"level": gs.combos[k].level, "enabled": gs.combos[k].enabled}
		return st

	func _save_game_statistics() -> Dictionary:
		var mpp := {}
		for k in gs.money_per_product:
			mpp[k] = gs.money_per_product[k].to_plain_string()
		return {"is_game_started": true, "purchased_once": gs.purchased_once.duplicate(),
			"products_consumed": gs.products_consumed.duplicate(), "products_crafted": gs.products_crafted.duplicate(),
			"products_autocrafted": gs.products_autocrafted.duplicate(), "money_per_product": mpp,
			"total_products_consumed": gs.total_products_consumed}

	func _save_hole() -> Dictionary:
		if hole == null:
			return {}
		return {"current_radius": hole.current_radius, "target_radius": hole.target_radius,
			"phase_nutrition_total": hole.phase_nutrition_total}

	func _save_vertical_gates() -> Dictionary:
		return {"gate_a": {"gate_id": "gate_a", "is_solved": true}}

	func _save_cameras() -> Dictionary:
		return {}

	func _save_minable_blocks() -> Dictionary:
		return {}

	func _save_loop_puzzle() -> Dictionary:
		return {}


class FWorkbench extends Node:
	var auto_calls: Array = []
	var spawned: Dictionary = {}

	func auto_machine_purchased(k: String, level: int) -> void:
		auto_calls.append([k, level])
		if level == 0:
			spawned[k] = true

	func get_save_data() -> Dictionary:
		return {"auto": spawned.duplicate()}


class FSteamworks extends Node:
	const ACH_STAT := {"RICH": {"stat": "total_money_gained", "threshold": 1000},
		"FEEDER": {"stat": "total_products_consumed", "threshold": 10}}
	const ACH_PHASE := {2: "PHASE_2", 3: "PHASE_3"}
	const ACH_GATE := {"gate_a": "GATE_A"}
	var _granted: Dictionary = {}
	var _probe_ids: Array = ["RICH", "FEEDER", "PHASE_2", "PHASE_3", "GATE_A", "CONSUMERISM"]
	var unlock_calls: Array = []
	var consumerism_checks := 0
	var gs = null

	func unlock_achievement(api_name: String) -> void:
		if _granted.get(api_name) == true:
			return
		_granted.merge({api_name: true}, true)
		unlock_calls.append(api_name)

	func check_consumerism() -> void:
		consumerism_checks += 1

	func consumerism_remaining() -> int:
		return 5

	func evaluate_all() -> void:
		pass

	func _meets(value, threshold: int) -> bool:
		if typeof(value) == TYPE_OBJECT and value != null and value.has_method("compare_int"):
			return value.compare_int(threshold) != -1
		return float(threshold) <= float(value)

	func _get_stat(path: String):
		return gs.get(path) if gs != null else null

	## like the game: stat crossings grant achievements (presence policy tests)
	func on_stat(stat_name: String, value) -> void:
		for api_name in ACH_STAT:
			var rule: Dictionary = ACH_STAT[api_name]
			if rule.stat == stat_name and _granted.get(api_name) != true and _meets(value, rule.threshold):
				unlock_achievement(api_name)


class FMenu extends Node:
	var current_menu = null
	var game_paused := false


class FInput extends Node:
	signal bindings_changed
	var applies := 0

	func apply_bindings() -> void:
		applies += 1
		bindings_changed.emit()


class FPools extends Node:
	var full: Dictionary = {}

	func is_pool_full(pool_id: String) -> bool:
		return bool(full.get(pool_id, false))


class FPlayer extends CharacterBody3D:
	var last_safe_position := Vector3(3, 1, 4)
	var is_crouching := false
	var is_sprinting := false


class FMainMenu extends Node:
	var _pending_new_game := true
	var launches: Array = []

	func _launch_game(scene_path: String) -> void:
		launches.append(scene_path)


# ------------------------------------------------------------------ per-peer world

var peer_name := ""
var nodes: Dictionary = {}       # autoload name -> fake node
var world_nodes: Dictionary = {} # group -> node
var world: Node3D = null
var in_world_flag := false
var paused := false
var menu_is_open := false
var movement_locked := false
var camera_frozen := false
var erased: Dictionary = {}      # action -> true
var avatar: Dictionary = {}
var returns_to_menu := 0
var launches: Array = []
var restrict_messages: Array = []
var ui_refreshes := 0
var simulate_load := true
var load_delay_frames := 2
var loaded_snapshot: Dictionary = {}
var _tree_ref: SceneTree = null


func _init(p_name: String = "peer", tree: SceneTree = null) -> void:
	peer_name = p_name
	_tree_ref = tree
	var gs := FGameState.new()
	var gp := FProgression.new()
	var um := FUnlocks.new()
	var sm := FSaveManager.new()
	var ws := FWorkbench.new()
	var st := FSteamworks.new()
	gs.ws = ws
	um.gs = gs
	sm.gs = gs
	st.gs = gs
	nodes = {"GameState": gs, "GameProgression": gp, "UnlockManager": um, "SaveManager": sm,
		"WorkbenchSpawning": ws, "Steamworks": st, "MenuManager": FMenu.new(), "InputManager": FInput.new(),
		"ObjectPoolManager": FPools.new()}
	# the game wires these in its own _ready()s
	gs.stat_changed.connect(um._on_stat_changed)
	gp.phase_changed.connect(um._on_phase_changed)
	gs.stat_changed.connect(st.on_stat)
	# the real adapter re-emits PittAPI's phase.settled (GameProgression.phase_changed)
	gp.phase_changed.connect(func(p): phase_settled.emit(int(p)))
	world_nodes["MainMenu"] = FMainMenu.new()


func free_all() -> void:
	for n in nodes.values():
		if is_instance_valid(n):
			n.free()
	for k in world_nodes:
		var n = world_nodes[k]
		if n != null and is_instance_valid(n) and not n.is_inside_tree():
			n.free()
	if world != null and is_instance_valid(world):
		world.queue_free()
	world_nodes.clear()
	nodes.clear()


func g(n: String) -> Object:
	return nodes.get(n, null)


func _group(n: String) -> Node:
	var node = world_nodes.get(n, null)
	if node != null and not is_instance_valid(node):
		return null
	if n in ["player", "main_camera", "saveable_hole", "UpgradeUI", "PauseMenu", "HUD"] and not in_world_flag:
		return null
	return node


func _tree() -> SceneTree:
	return _tree_ref if _tree_ref != null else Engine.get_main_loop() as SceneTree


func kind() -> String:
	return "fake"


# shortcuts for tests
func fgs() -> Object:
	return nodes.GameState


func fgp() -> Object:
	return nodes.GameProgression


func fum() -> Object:
	return nodes.UnlockManager


func fst() -> Object:
	return nodes.Steamworks


func ui() -> Node:
	return world_nodes.get("UpgradeUI", null)


func hole() -> Node:
	return world_nodes.get("saveable_hole", null)


## The host (or a test) enters a running world at phase p.
func enter_world(p: int = 1, parent: Node = null) -> void:
	_build_world(parent)
	fgp().current_phase = p
	fgp().elevator_exited = p >= 1
	fgs().is_game_started = true
	in_world_flag = true
	world_ready.emit({"new_game": false, "save_key": "fake"})
	save_applied.emit()


func leave_world() -> void:
	in_world_flag = false
	fgs().is_game_started = false
	world_exited.emit()


func _build_world(parent: Node) -> void:
	if world != null and is_instance_valid(world):
		return
	world = Node3D.new()
	world.name = "World_%s" % peer_name
	var p := FPlayer.new()
	p.name = "FakePlayer"
	world.add_child(p)
	var cam := Camera3D.new()
	cam.name = "Cam"
	p.add_child(cam)
	var h = HoleStub.new()
	h.name = "Hole"
	world.add_child(h)
	nodes.SaveManager.hole = h
	var ui_node = UpgradeUIStub.new()
	ui_node.name = "UpgradeUI"
	ui_node.buy_func = func(c, k, s): return fgs().buy(c, k, s)
	world.add_child(ui_node)
	var pm = PauseMenuStub.new()
	pm.name = "PauseMenu"
	world.add_child(pm)
	world_nodes["player"] = p
	world_nodes["main_camera"] = cam
	world_nodes["saveable_hole"] = h
	world_nodes["UpgradeUI"] = ui_node
	world_nodes["PauseMenu"] = pm
	var root: Node = parent if parent != null else _tree().root
	root.add_child(world)


# ------------------------------------------------------------------ overrides of process-global things

func in_world() -> bool:
	return in_world_flag


func scene_kind() -> String:
	return "world" if in_world_flag else "main_menu"


func on_main_menu() -> bool:
	return not in_world_flag


func world_root() -> Node:
	return world if in_world_flag else null


func local_avatar_state() -> Dictionary:
	return avatar.duplicate() if in_world_flag else {}


func tree_paused() -> bool:
	return paused


func unpause_tree() -> void:
	paused = false


func physics_frame_signal() -> Signal:
	return _tree().physics_frame


func menu_open() -> bool:
	return menu_is_open


func set_movement_locked(on: bool) -> void:
	movement_locked = on


func set_camera_frozen(on: bool) -> void:
	camera_frozen = on


func erase_action_events(actions: Array) -> void:
	for a in actions:
		erased[a] = true


func restore_bindings() -> void:
	erased.clear()
	nodes.InputManager.apply_bindings()


func action_has_events(action: String) -> bool:
	return not erased.has(action)


func return_to_main_menu() -> bool:
	returns_to_menu += 1
	if in_world_flag:
		in_world_flag = false
		fgs().is_game_started = false
		world_exited.emit.call_deferred()
	return true


func show_restrict(text: String) -> void:
	restrict_messages.append(text)


func refresh_upgrade_ui() -> void:
	ui_refreshes += 1


func upgrade_ui() -> Node:
	return ui()


## Simulates the game's load path (LoadingScreen -> player _ready ->
## load_game -> apply_deferred_load) from the isolated session file.
func launch_snapshot_world(phase: int) -> Error:
	var menu = world_nodes.get("MainMenu", null)
	if menu == null or in_world_flag:
		return ERR_UNAVAILABLE
	fgp().reset_run_state()
	fgp().current_phase = phase
	fgs().sandbox_mode = false
	nodes.SaveManager.should_load_on_ready = true
	menu._pending_new_game = false
	menu._launch_game(WORLD_SCENE)
	launches.append(phase)
	if simulate_load:
		_simulate_load()
	return OK


func _simulate_load() -> void:
	for i in load_delay_frames:
		await _tree().process_frame
	var path: String = api.isolate_path if api != null and "isolate_path" in api else ""
	var text := ""
	var f := FileAccess.open_encrypted_with_pass(path, FileAccess.READ, save_password())
	if f != null:
		text = f.get_as_text()
		f.close()
	if not text.begins_with("{"):
		var f2 := FileAccess.open(path, FileAccess.READ)
		if f2 != null:
			text = f2.get_as_text()
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return
	loaded_snapshot = data
	_build_world(null)
	var g_state = fgs()
	var st: Dictionary = data.get("game_state", {})
	g_state.money = BigInt.from_string(str(st.get("money", "0")))
	for cat in ["upgrades", "tools", "toys", "combos"]:
		var t: Dictionary = st.get(cat, {})
		for k in t:
			if g_state.get(cat).has(k):
				g_state.get(cat)[k].level = int(t[k].level)
				g_state.get(cat)[k].enabled = bool(t[k].enabled)
				if cat == "toys" and t[k].has("buy_prices") and not t[k].buy_prices.is_empty():
					g_state.toys[k].buy_prices = t[k].buy_prices.duplicate()
	for k in st.get("products", {}):
		if g_state.products.has(k):
			g_state.products[k].enabled = bool(st.products[k].enabled)
			for s in st.products[k]:
				if s != "enabled" and g_state.products[k].has(s):
					g_state.products[k][s].level = int(st.products[k][s].level)
	var stats: Dictionary = data.get("game_statistics", {})
	g_state.purchased_once = stats.get("purchased_once", {}).duplicate()
	for k in stats.get("products_consumed", {}):
		g_state.products_consumed[k] = int(stats.products_consumed[k])
	g_state.total_products_consumed = int(stats.get("total_products_consumed", 0))
	for id in data.get("unlocked_milestones", []):
		if not (String(id) in fum().unlocked_milestones):
			fum().unlocked_milestones.append(String(id))
	fgp().current_phase = int(data.get("phase", 1))
	fgp().elevator_exited = true
	var hd: Dictionary = data.get("hole", {})
	if hole() != null and not hd.is_empty():
		hole().target_radius = float(hd.get("target_radius", 1.0))
		hole().phase_nutrition_total = float(hd.get("phase_nutrition_total", 0.0))
	g_state.is_game_started = true
	in_world_flag = true
	world_ready.emit({"new_game": false, "save_key": path.get_file().get_basename()})
	await _tree().process_frame
	save_applied.emit()
