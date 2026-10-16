extends RefCounted
## GameAdapter: the ONLY file of the NET stream that reads or writes game
## autoloads and world nodes (MP-DESIGN 1, rule 2). Everything else talks to
## this interface, so a host and several clients can run in one headless
## process with FakeGameAdapters (tests/headless/fakes/mp_net/fake_game_adapter.gd
## implements the same members). Every game member used here is listed in
## net/contract_net.gd and checked at boot; a missing one disables multiplayer.
##
## Lifecycle comes from PittAPI's bridge events (world.ready, world.exited,
## save.applied, phase.settled, scene.changed) and is re-emitted as signals.

signal world_ready(info: Dictionary)
signal world_exited()
signal save_applied()
signal phase_settled(phase: int)
signal scene_changed(kind: String)

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"
const WORLD_SCENE := "res://scenes/world.tscn"
const MIRROR_CATEGORIES := ["upgrades", "tools", "toys", "products", "combos"]
## Contributed counters (6.1): forwarded by clients, merged on the host.
const STAT_PREFIXES := ["products_consumed.", "products_crafted.", "products_autocrafted.", "money_per_product."]
const STAT_SCALARS := ["total_products_consumed", "total_bonus_earned"]
const ACTION_QUICK_SAVE := "quick_save"
const ACTION_QUICK_LOAD := "quick_load"

var api = null
var _subs: Array = []
var _um_detached := false
var _cam_frozen: WeakRef = null
var _cam_prev_mode := Node.PROCESS_MODE_INHERIT
var _movement_locked := false


func setup(p_api) -> void:
	api = p_api
	if api == null or not ("events" in api) or api.events == null:
		return
	_subs.append(api.events.on("world.ready", func(ev): world_ready.emit(ev.payload)))
	_subs.append(api.events.on("world.exited", func(_ev): world_exited.emit()))
	_subs.append(api.events.on("save.applied", func(_ev): save_applied.emit()))
	_subs.append(api.events.on("phase.settled", func(ev): phase_settled.emit(int(ev.payload.get("phase", 0)))))
	_subs.append(api.events.on("scene.changed", func(ev): scene_changed.emit(String(ev.payload.get("kind", "")))))


func g(n: String) -> Object:
	var tree := _tree()
	return tree.root.get_node_or_null(NodePath(n)) if tree != null else null


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _group(name: String) -> Node:
	var tree := _tree()
	return tree.get_first_node_in_group(name) if tree != null else null


func kind() -> String:
	return "game"


# ------------------------------------------------------------------ session / world

func in_world() -> bool:
	if api != null and "state" in api and api.state != null and api.state.has_method("is_in_world"):
		return bool(api.state.is_in_world())
	var gs = g("GameState")
	return gs != null and bool(gs.is_game_started) and scene_kind() == "world"


func scene_kind() -> String:
	var tree := _tree()
	var scene: Node = tree.current_scene if tree != null else null
	if scene == null:
		return "other"
	match scene.scene_file_path:
		WORLD_SCENE:
			return "world"
		MAIN_MENU_SCENE:
			return "main_menu"
	return "other"


func on_main_menu() -> bool:
	return scene_kind() == "main_menu" and _group("MainMenu") != null


func get_phase() -> int:
	var gp = g("GameProgression")
	return int(gp.current_phase) if gp != null else 0


func elevator_exited() -> bool:
	var gp = g("GameProgression")
	return gp != null and bool(gp.elevator_exited)


func ending_active() -> bool:
	var gp = g("GameProgression")
	return gp != null and bool(gp.ending_active)


## An end-of-game screen is up. The secret ending (security_room.gd:435 ->
## MenuManager.open_end_game_menu(true)) pauses the tree for it without setting
## GameProgression.ending_active.
func end_screen_open() -> bool:
	var mm = g("MenuManager")
	if mm == null:
		return false
	var m = mm.get("current_menu")
	return m != null and is_instance_valid(m) and m.has_method("show_end_game") and bool(m.visible)


func is_sandbox() -> bool:
	var gs = g("GameState")
	return gs != null and bool(gs.sandbox_mode)


func is_loading() -> bool:
	var sm = g("SaveManager")
	return sm != null and bool(sm.is_loading)


## Replicated phase on clients: the game's own transition (cinematic, music, time scale).
func change_phase(p: int) -> void:
	var gp = g("GameProgression")
	if gp != null:
		gp.change_phase(p)


func game_version() -> String:
	return String(ProjectSettings.get_setting("application/config/version", ""))


# ------------------------------------------------------------------ money (decimal strings)

func get_money() -> String:
	var gs = g("GameState")
	if gs == null or gs.money == null:
		return "0"
	return String(gs.money.to_plain_string())


## Load-path semantics (save_manager.gd:824): money = BigInt.from_string, then
## money_updated; no stat side effects.
func set_money(digits: String) -> void:
	var gs = g("GameState")
	if gs == null or gs.money == null:
		return
	if String(gs.money.to_plain_string()) == digits:
		return
	var script = gs.money.get_script()
	gs.money = script.from_string(digits)
	gs.money_updated.emit(gs.money)


## Largest amount that goes through the game's own int paths (add_money/spend
## take ints and record rate events); anything bigger is applied as one BigInt
## operation, like the loader's money.add (builtin_commands.gd). The cost never
## depends on the size of the amount.
const INT_PATH_MAX_DIGITS := 18


## Host: a client's positive delta.
func add_money_digits(digits: String) -> void:
	var gs = g("GameState")
	if gs == null or gs.money == null:
		return
	var d := digits.strip_edges().lstrip("0")
	if d == "" or not _all_digits(d):
		return
	if d.length() <= INT_PATH_MAX_DIGITS:
		gs.add_money(int(d))
		return
	var script = gs.money.get_script()
	gs.money.add_big(script.from_string(d))
	if gs.total_money_gained != null:
		gs.total_money_gained.add_big(script.from_string(d))
	gs.money_updated.emit(gs.money)
	gs.stat_changed.emit("total_money_gained", gs.total_money_gained)


## Host: a client's negative delta with the game's floor-at-0 semantics:
## spend(min(|d|, money)). Returns the digits actually spent.
func spend_floor_digits(digits: String) -> String:
	var gs = g("GameState")
	if gs == null or gs.money == null:
		return "0"
	var d := digits.strip_edges().lstrip("0")
	if d == "" or not _all_digits(d):
		return "0"
	var have := get_money()
	var amount := d if _dcmp(d, have) <= 0 else have
	amount = amount.lstrip("0")
	if amount == "":
		return "0"
	if amount.length() <= INT_PATH_MAX_DIGITS:
		gs.spend(int(amount))
		return amount
	var script = gs.money.get_script()
	gs.money.sub_big(script.from_string(amount))
	if gs.total_money_spent != null:
		gs.total_money_spent.add_big(script.from_string(amount))
	gs.money_updated.emit(gs.money)
	return amount


func can_afford_digits(digits: String) -> bool:
	return _dcmp(get_money(), digits) >= 0


static func _all_digits(d: String) -> bool:
	for c in d:
		if c < "0" or c > "9":
			return false
	return true


static func _dcmp(a: String, b: String) -> int:
	a = a.lstrip("0")
	b = b.lstrip("0")
	if a.length() != b.length():
		return 1 if a.length() > b.length() else -1
	if a == b:
		return 0
	return 1 if a > b else -1


# ------------------------------------------------------------------ mirrored items (6.1)

## Flat "cat/key/sub" -> {level?, enabled?, price0?} of every mirrored field.
## products: "products/<k>/" carries enabled, "products/<k>/<sub>" the level.
func mirror_items() -> Dictionary:
	var out := {}
	var gs = g("GameState")
	if gs == null:
		return out
	for cat in MIRROR_CATEGORIES:
		var table = gs.get(cat)
		if typeof(table) != TYPE_DICTIONARY:
			continue
		for key in table:
			var item = table[key]
			if typeof(item) != TYPE_DICTIONARY:
				continue
			if cat == "products":
				out["products/%s/" % key] = {"enabled": bool(item.get("enabled", false))}
				for sub in item:
					var s = item[sub]
					if typeof(s) == TYPE_DICTIONARY and s.has("level"):
						out["products/%s/%s" % [key, sub]] = {"level": int(s.level)}
				continue
			var e := {"level": int(item.get("level", 0)), "enabled": bool(item.get("enabled", false))}
			if cat == "toys" and item.has("buy_prices") and typeof(item.buy_prices) == TYPE_ARRAY and not item.buy_prices.is_empty():
				e["price0"] = item.buy_prices[0]
			out["%s/%s/" % [cat, key]] = e
	return out


## Client: writes host values, then the post-hooks GameState.buy would have run
## in this world (6.3). Returns {"changed": bool}.
func apply_mirror_items(items: Dictionary) -> Dictionary:
	var gs = g("GameState")
	if gs == null:
		return {"changed": false}
	var changed := false
	var remote_tier_changed := false
	var auto_new: Array = []
	for path in items:
		var parts: PackedStringArray = String(path).split("/")
		if parts.size() != 3 or not (parts[0] in MIRROR_CATEGORIES):
			continue
		var v = items[path]
		if typeof(v) != TYPE_DICTIONARY:
			continue
		var table = gs.get(parts[0])
		if typeof(table) != TYPE_DICTIONARY or not table.has(parts[1]):
			continue
		var item = table[parts[1]]
		if parts[2] != "":
			if typeof(item) != TYPE_DICTIONARY or not item.has(parts[2]) or typeof(item[parts[2]]) != TYPE_DICTIONARY:
				continue
			item = item[parts[2]]
		if typeof(item) != TYPE_DICTIONARY:
			continue
		if v.has("level") and item.has("level") and int(item.level) != int(v.level):
			var before := int(item.level)
			item.level = int(v.level)
			changed = true
			if parts[0] == "upgrades" and parts[1] == "remote_tier":
				remote_tier_changed = true
			if parts[0] == "products" and parts[2] == "auto_machine" and before == 0 and int(v.level) > 0:
				auto_new.append(parts[1])
		if v.has("enabled") and item.has("enabled") and bool(item.enabled) != bool(v.enabled):
			item.enabled = bool(v.enabled)
			changed = true
		if v.has("price0") and item.has("buy_prices") and typeof(item.buy_prices) == TYPE_ARRAY and not item.buy_prices.is_empty():
			if item.buy_prices[0] != v.price0:
				item.buy_prices[0] = v.price0
				changed = true
	if remote_tier_changed and gs.has_method("apply_remote_tier"):
		gs.apply_remote_tier()
	var ws = g("WorkbenchSpawning")
	for k in auto_new:
		if ws != null and ws.has_method("auto_machine_purchased"):
			ws.auto_machine_purchased(k, 0)
	return {"changed": changed}


func purchased_once() -> Dictionary:
	var gs = g("GameState")
	if gs == null or typeof(gs.purchased_once) != TYPE_DICTIONARY:
		return {}
	var out := {}
	for k in gs.purchased_once:
		out[String(k)] = bool(gs.purchased_once[k])
	return out


func set_purchased_once(d: Dictionary, full: bool) -> void:
	var gs = g("GameState")
	if gs == null or typeof(gs.purchased_once) != TYPE_DICTIONARY:
		return
	if full:
		gs.purchased_once.clear()
	for k in d:
		gs.purchased_once[String(k)] = bool(d[k])


func mark_purchased_once(key: String) -> void:
	var gs = g("GameState")
	if gs != null and typeof(gs.purchased_once) == TYPE_DICTIONARY:
		gs.purchased_once[key] = true


## The live item dict (read-only use): category upgrades/tools/toys/products/combos.
func item(category: String, key: String, subkey: String = "") -> Dictionary:
	var gs = g("GameState")
	if gs == null or not (category in MIRROR_CATEGORIES):
		return {}
	var table = gs.get(category)
	if typeof(table) != TYPE_DICTIONARY or not table.has(key) or typeof(table[key]) != TYPE_DICTIONARY:
		return {}
	var it: Dictionary = table[key]
	if subkey != "":
		if not it.has(subkey) or typeof(it[subkey]) != TYPE_DICTIONARY:
			return {}
		return it[subkey]
	return it


func buy(category: String, key: String, subkey: String = "") -> bool:
	var gs = g("GameState")
	return gs != null and bool(gs.buy(category, key, subkey))


func spend_int(amount: int) -> void:
	var gs = g("GameState")
	if gs != null:
		gs.spend(amount)


func set_toy_price0(toy: String, value) -> void:
	var it := item("toys", toy)
	if it.has("buy_prices") and typeof(it.buy_prices) == TYPE_ARRAY and not it.buy_prices.is_empty():
		it.buy_prices[0] = value


func set_item_enabled(category: String, key: String, on: bool) -> void:
	var it := item(category, key)
	if it.has("enabled"):
		it.enabled = on


func check_consumerism() -> void:
	var st = g("Steamworks")
	if st != null and st.has_method("check_consumerism"):
		st.check_consumerism()


func pool_full(pool_id: String) -> bool:
	var pm = g("ObjectPoolManager")
	if pm == null or not pm.has_method("is_pool_full"):
		return false
	return bool(pm.is_pool_full(pool_id))


func refresh_upgrade_ui() -> void:
	request_upgrade_ui_refresh(true)


## An open upgrade menu shows replicated changes live (upgrade_ui_ext, coalesced
## per frame; 0.2.2). structural = levels / prices / unlocks; false = money only.
func request_upgrade_ui_refresh(structural: bool) -> void:
	var ui = _group("UpgradeUI")
	if ui == null or ui.has_meta("is_mirror"):
		return
	if ui.has_method("mp_request_refresh"):
		ui.mp_request_refresh(structural)
	elif structural and ui.has_method("update_ui"):
		ui.update_ui()


func upgrade_ui() -> Node:
	return _group("UpgradeUI")


# ------------------------------------------------------------------ contributed stats (6.4)

## {path: value} of every contributed counter; ints, or decimal strings for BigInts.
func stat_counters() -> Dictionary:
	var out := {}
	var gs = g("GameState")
	if gs == null:
		return out
	for pre in STAT_PREFIXES:
		var table = gs.get(pre.trim_suffix("."))
		if typeof(table) != TYPE_DICTIONARY:
			continue
		for k in table:
			out[pre + String(k)] = _stat_value(table[k])
	for s in STAT_SCALARS:
		var v = gs.get(s)
		if v != null:
			out[s] = _stat_value(v)
	return out


static func _stat_value(v) -> Variant:
	if typeof(v) == TYPE_OBJECT and v != null and v.has_method("to_plain_string"):
		return String(v.to_plain_string())
	if typeof(v) == TYPE_FLOAT:
		return int(v)
	return v


static func is_contributed_stat(path: String) -> bool:
	if path in STAT_SCALARS:
		return true
	for pre in STAT_PREFIXES:
		if path.begins_with(pre) and path.length() > pre.length():
			return true
	return false


## Host: counter += n, then stat_changed so the host's UnlockManager and
## Steamworks react. n: int, or a decimal string for BigInt counters.
func add_stat(path: String, n) -> bool:
	var gs = g("GameState")
	if gs == null or not is_contributed_stat(path):
		return false
	var name := path
	var key := ""
	if not (path in STAT_SCALARS):
		name = path.get_slice(".", 0)
		key = path.substr(name.length() + 1)
	var holder = gs.get(name)
	var cur = holder
	if key != "":
		if typeof(holder) != TYPE_DICTIONARY or not holder.has(key):
			return false
		cur = holder[key]
	var newv = null
	if typeof(cur) == TYPE_OBJECT and cur != null and cur.has_method("add_big"):
		var script = cur.get_script()
		cur.add_big(script.from_string(str(n)))
		newv = cur
	elif typeof(cur) == TYPE_INT or typeof(cur) == TYPE_FLOAT:
		newv = cur + int(str(n).to_int())
		if key != "":
			holder[key] = newv
		else:
			gs.set(name, newv)
	else:
		return false
	gs.stat_changed.emit(path, newv)
	return true


# ------------------------------------------------------------------ MP2 mirrors (3.8, D14, D24)

## Scalar counters mirrored host -> clients (with the STAT_PREFIXES tables).
const MIRROR_STAT_SCALARS := ["total_products_consumed", "total_bonus_earned", "total_money_gained",
	"total_money_spent", "total_products", "max_combo", "total_combos", "combo_bonus_total", "safety_violations",
	"long_range_feeds", "panel_ricochet_feeds", "cameras_destroyed", "total_wodden_gambling_crates",
	"max_simultaneous_toggle_tools", "peak_production_rate"]


## {path: value} of every mirrored statistic (BigInt -> decimal string, int, float).
func mirror_stats() -> Dictionary:
	var out := {}
	var gs = g("GameState")
	if gs == null:
		return out
	for pre in STAT_PREFIXES:
		var table = gs.get(pre.trim_suffix("."))
		if typeof(table) != TYPE_DICTIONARY:
			continue
		for k in table:
			out[pre + String(k)] = _mirror_value(table[k])
	for s in MIRROR_STAT_SCALARS:
		if s in gs:
			var v = gs.get(s)
			if v != null:
				out[s] = _mirror_value(v)
	return out


static func _mirror_value(v) -> Variant:
	if typeof(v) == TYPE_OBJECT and v != null and v.has_method("to_plain_string"):
		return String(v.to_plain_string())
	return v


## Client (apply scope): writes every changed value and emits stat_changed once
## per change, so crossing-based achievements fire (D24). Returns the count.
func apply_mirror_stats(d: Dictionary) -> int:
	var gs = g("GameState")
	if gs == null:
		return 0
	var n := 0
	for path in d:
		var p := String(path)
		var name := p
		var key := ""
		if not (p in MIRROR_STAT_SCALARS):
			var ok := false
			for pre in STAT_PREFIXES:
				if p.begins_with(pre) and p.length() > pre.length():
					ok = true
			if not ok:
				continue
			name = p.get_slice(".", 0)
			key = p.substr(name.length() + 1)
		if not (name in gs):
			continue
		var holder = gs.get(name)
		var cur = holder
		if key != "":
			if typeof(holder) != TYPE_DICTIONARY:
				continue
			cur = holder.get(key, null)
		var want = d[path]
		if cur != null and _mirror_value(cur) == want:
			continue
		var newv = null
		if typeof(cur) == TYPE_OBJECT and cur != null and cur.has_method("to_plain_string"):
			newv = cur.get_script().from_string(str(want))
		elif typeof(cur) == TYPE_FLOAT:
			newv = float(want)
		elif typeof(cur) == TYPE_INT or cur == null:
			if typeof(want) == TYPE_STRING:
				if key == "" or not String(want).is_valid_int():
					continue
				# a new BigInt table entry the client lacks
				var proto_v = holder.values()[0] if typeof(holder) == TYPE_DICTIONARY and not holder.is_empty() else null
				if not (typeof(proto_v) == TYPE_OBJECT and proto_v != null and proto_v.has_method("to_plain_string")):
					continue
				newv = proto_v.get_script().from_string(String(want))
			else:
				newv = int(want) if typeof(want) == TYPE_INT else want
		else:
			continue
		if key != "":
			holder[key] = newv
		else:
			gs.set(name, newv)
		gs.stat_changed.emit(p, newv)
		n += 1
	return n


## Shared gambling bank (D14). -1 when the game has none.
func get_bank() -> float:
	var gs = g("GameState")
	return float(gs.bank) if gs != null and "bank" in gs else -1.0


## Client (apply scope): bank + bank_updated (the terminal label listens).
func set_bank(v: float) -> void:
	var gs = g("GameState")
	if gs == null or not ("bank" in gs) or is_equal_approx(float(gs.bank), v):
		return
	gs.bank = v
	if gs.has_signal("bank_updated"):
		gs.bank_updated.emit(gs.bank)


func get_mining_bank() -> int:
	var gs = g("GameState")
	return int(gs.mining_bank) if gs != null and "mining_bank" in gs else -1


func set_mining_bank(v: int) -> void:
	var gs = g("GameState")
	if gs != null and "mining_bank" in gs and int(gs.mining_bank) != v:
		gs.mining_bank = v


# ------------------------------------------------------------------ unlocks (6.3)

func unlocked_list() -> Array:
	var um = g("UnlockManager")
	if um == null:
		return []
	var out: Array = []
	for id in um.unlocked_milestones:
		out.append(String(id))
	return out


func has_milestone(id: String) -> bool:
	var um = g("UnlockManager")
	return um != null and um.milestones.has(id)


func is_unlocked(id: String) -> bool:
	var um = g("UnlockManager")
	return um != null and um.is_unlocked(id)


## The game's live unlock path: actions, milestone_unlocked, the notification.
func force_unlock(id: String) -> void:
	var um = g("UnlockManager")
	if um != null:
		um.force_unlock(id)


## Clients judge no milestones themselves during a session: stat_changed /
## phase_changed disconnected and processing off. The game also calls
## check_milestones() directly (camera_pivot.gd:101, pickaxe.gd:257,
## save_manager.gd:1480 after the snapshot load); for those every milestone gets
## an unmet requirement (only check_milestones reads "requires", and
## force_unlock - the path the host's unlocks take - ignores it).
## restore_unlock_manager() undoes it (before PauseMenu._return_to_main_menu
## runs UnlockManager.reset()).
const UM_BLOCK_REQ := "__pitt_mp_host_decides__"
var _um_saved_requires: Dictionary = {}   # id -> original "requires" (null = none)


func detach_unlock_manager() -> void:
	var um = g("UnlockManager")
	var gs = g("GameState")
	var gp = g("GameProgression")
	if um == null or _um_detached:
		return
	_um_detached = true
	_block_milestones(um)
	var c1 := Callable(um, "_on_stat_changed")
	if gs != null and gs.stat_changed.is_connected(c1):
		gs.stat_changed.disconnect(c1)
	var c2 := Callable(um, "_on_phase_changed")
	if gp != null and gp.phase_changed.is_connected(c2):
		gp.phase_changed.disconnect(c2)
	um.set_process(false)


func restore_unlock_manager() -> void:
	var um = g("UnlockManager")
	var gs = g("GameState")
	var gp = g("GameProgression")
	if um == null or not _um_detached:
		return
	_um_detached = false
	_unblock_milestones(um)
	var c1 := Callable(um, "_on_stat_changed")
	if gs != null and not gs.stat_changed.is_connected(c1):
		gs.stat_changed.connect(c1)
	var c2 := Callable(um, "_on_phase_changed")
	if gp != null and not gp.phase_changed.is_connected(c2):
		gp.phase_changed.connect(c2)
	um.set_process(true)


func unlock_manager_detached() -> bool:
	return _um_detached


func _block_milestones(um: Object) -> void:
	_um_saved_requires.clear()
	var ms = um.get("milestones")
	if typeof(ms) != TYPE_DICTIONARY or ms.is_read_only():
		return
	for id in ms:
		var m = ms[id]
		if typeof(m) != TYPE_DICTIONARY or m.is_read_only():
			continue
		var prev = m.get("requires", null)
		_um_saved_requires[id] = prev
		var req: Array = []
		if typeof(prev) == TYPE_ARRAY:
			req.append_array(prev)
		req.append(UM_BLOCK_REQ)
		m["requires"] = req


func _unblock_milestones(um: Object) -> void:
	var ms = um.get("milestones")
	if typeof(ms) == TYPE_DICTIONARY:
		for id in _um_saved_requires:
			if not ms.has(id) or typeof(ms[id]) != TYPE_DICTIONARY:
				continue
			var prev = _um_saved_requires[id]
			if prev == null:
				ms[id].erase("requires")
			else:
				ms[id]["requires"] = prev
	_um_saved_requires.clear()


## True while every milestone carries the block requirement.
func milestones_blocked() -> bool:
	return not _um_saved_requires.is_empty()


# ------------------------------------------------------------------ hole

func _hole() -> Node:
	return _group("saveable_hole")


func hole_state() -> Dictionary:
	var h = _hole()
	if h == null:
		return {}
	return {"target_radius": float(h.target_radius), "phase_nutrition_total": float(h.phase_nutrition_total)}


func set_hole_state(d: Dictionary) -> void:
	var h = _hole()
	if h == null:
		return
	if d.has("target_radius"):
		h.target_radius = float(d.target_radius)
	if d.has("phase_nutrition_total"):
		h.phase_nutrition_total = float(d.phase_nutrition_total)


## Host: a client's maw feeding goes into the HOST's hole (phase scaling from the host phase).
## Host: nutrition the current phase needs from its minimum to its maximum
## radius (hole.gd: radius_growth = nutrition / NUTRITION_PER_RADIUS_UNIT * 0.1).
## 0 when unknown (no hole, phase 0 or 5).
func phase_nutrition_needed() -> float:
	var h = _hole()
	if h == null or h.get_script() == null:
		return 0.0
	var consts: Dictionary = {}
	var sc = h.get_script()
	while sc != null:
		for k in sc.get_script_constant_map():
			if not consts.has(k):
				consts[k] = sc.get_script_constant_map()[k]
		sc = sc.get_base_script()
	var ranges = consts.get("PHASE_RADIUS_RANGES", {})
	var per_unit = consts.get("NUTRITION_PER_RADIUS_UNIT", {})
	var p := get_phase()
	if typeof(ranges) != TYPE_DICTIONARY or typeof(per_unit) != TYPE_DICTIONARY \
			or not ranges.has(p) or not per_unit.has(p):
		return 0.0
	var r: Dictionary = ranges[p]
	return (float(r.get("max", 0.0)) - float(r.get("min", 0.0))) / 0.1 * float(per_unit[p])


func host_feed(product_type: String, base_value: int) -> void:
	var h = _hole()
	if h != null and h.has_method("_on_product_consumed"):
		h._on_product_consumed(product_type, base_value, -1)


# ------------------------------------------------------------------ snapshot (9)

## The game's pure save collectors into a FRESH dictionary: never touches
## SaveManager.save_data, never writes a file, never pauses.
func build_snapshot() -> Dictionary:
	var sm = g("SaveManager")
	var um = g("UnlockManager")
	var gp = g("GameProgression")
	var ws = g("WorkbenchSpawning")
	if sm == null:
		return {}
	var d := {}
	d["version"] = game_version()
	d["timestamp"] = int(Time.get_unix_time_from_system())
	d["game_state"] = sm._save_game_state()
	d["game_statistics"] = sm._save_game_statistics()
	d["unlocked_milestones"] = um.get_save_data() if um != null else []
	d["phase"] = int(gp.current_phase) if gp != null else 1
	d["hole"] = sm._save_hole()
	d["workbenches"] = ws.get_save_data() if ws != null else {}
	d["vertical_gates"] = sm._save_vertical_gates()
	d["cameras"] = sm._save_cameras()
	d["minable_blocks"] = sm._save_minable_blocks()
	d["loop_puzzle"] = sm._save_loop_puzzle()
	# MP2 3.8: the shared fixtures are kept from the host (save_manager.gd:290-296)
	d["press_spawned"] = bool(sm._is_press_in_scene()) if sm.has_method("_is_press_in_scene") else false
	d["trading_terminal_spawned"] = bool(sm._is_terminal_in_scene()) if sm.has_method("_is_terminal_in_scene") else false
	d["bowling_set_spawned"] = bool(sm._is_bowling_set_in_scene()) if sm.has_method("_is_bowling_set_in_scene") else false
	d["pickaxe"] = sm._save_pickaxe() if sm.has_method("_save_pickaxe") else {}
	return d


func host_player_position() -> Vector3:
	var p = _group("player")
	if p != null and "last_safe_position" in p:
		var v: Vector3 = p.last_safe_position
		if v.is_finite() and v != Vector3.ZERO:
			return v
	if p is Node3D:
		return p.global_position
	return Vector3(0, 6, 18)


func save_password() -> String:
	var sm = g("SaveManager")
	if sm == null:
		return ""
	var c = sm.get_script().get_script_constant_map().get("SAVE_PASSWORD", "")
	return String(c)


## Writes the session file encrypted with the runtime SaveManager.SAVE_PASSWORD
## (read from the live autoload, never copied into the repo), so the game's
## reader takes its normal path; plaintext is the fallback (save_manager.gd:456).
func write_session_file(path: String, text: String) -> Error:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var pw := save_password()
	var f: FileAccess = null
	if pw != "":
		f = FileAccess.open_encrypted_with_pass(path, FileAccess.WRITE, pw)
	if f == null:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(text)
	f.close()
	return OK


func delete_file(path: String) -> void:
	for p in [path, path + ".bak", path + ".tmp", path + ".corrupt"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


## What main_menu._on_load_pressed does, minus set_active_slot (9.2 step 4).
## The active save path is already the isolated session file (save.isolate).
func launch_snapshot_world(phase: int) -> Error:
	var menu = _group("MainMenu")
	var gp = g("GameProgression")
	var gs = g("GameState")
	var sm = g("SaveManager")
	if menu == null or gp == null or sm == null or not menu.has_method("_launch_game"):
		return ERR_UNAVAILABLE
	gp.reset_run_state()
	if phase > 0:
		gp.current_phase = phase
	if gs != null:
		gs.sandbox_mode = false
	sm.should_load_on_ready = true
	menu._pending_new_game = false
	menu._launch_game(WORLD_SCENE)
	return OK


# ------------------------------------------------------------------ player / avatars

func world_root() -> Node:
	var tree := _tree()
	return tree.current_scene if tree != null and scene_kind() == "world" else null


## {pos, yaw, pitch, vel, crouch, sprint, airborne, torch} of the local player, {} if none.
func local_avatar_state() -> Dictionary:
	var p = _group("player")
	if not (p is CharacterBody3D) or not p.is_inside_tree():
		return {}
	var cam = _group("main_camera")
	var pitch := 0.0
	if cam is Node3D:
		pitch = cam.rotation.x
	return {"pos": p.global_position, "yaw": p.rotation.y, "pitch": pitch, "vel": p.velocity,
		"crouch": bool(p.get("is_crouching")), "sprint": bool(p.get("is_sprinting")),
		"airborne": not p.is_on_floor(), "torch": int(p.get("torch_mode") if p.get("torch_mode") != null else 0) != 0}


# ------------------------------------------------------------------ pause / menus (8.2)

func tree_paused() -> bool:
	var tree := _tree()
	return tree != null and tree.paused


func unpause_tree() -> void:
	var tree := _tree()
	if tree != null and tree.paused:
		tree.paused = false


func physics_frame_signal() -> Signal:
	return _tree().physics_frame


func menu_open() -> bool:
	var mm = g("MenuManager")
	if mm == null:
		return false
	return mm.current_menu != null or bool(mm.game_paused)


func set_movement_locked(on: bool) -> void:
	if _movement_locked == on:
		return
	_movement_locked = on
	if api != null and "player" in api and api.player != null:
		api.player.set_movement_locked(on)


## Local freeze while a menu is open: drop what is held, stop the camera script.
func set_camera_frozen(on: bool) -> void:
	if on:
		if _cam_frozen != null and _cam_frozen.get_ref() != null:
			return
		var cam = _group("main_camera")
		if cam == null:
			return
		if cam.has_method("release_held_object"):
			cam.call("release_held_object")
		_cam_prev_mode = cam.process_mode
		cam.process_mode = Node.PROCESS_MODE_DISABLED
		_cam_frozen = weakref(cam)
	else:
		if _cam_frozen == null:
			return
		var cam = _cam_frozen.get_ref()
		_cam_frozen = null
		if cam != null and is_instance_valid(cam):
			cam.process_mode = _cam_prev_mode


# ------------------------------------------------------------------ input (8.3)

func bindings_changed_signal() -> Signal:
	var im = g("InputManager")
	return im.bindings_changed if im != null else Signal()


func erase_action_events(actions: Array) -> void:
	for a in actions:
		if InputMap.has_action(a):
			InputMap.action_erase_events(a)


## InputManager.apply_bindings() re-adds every binding from current_bindings
## (keybindings.cfg is never written).
func restore_bindings() -> void:
	var im = g("InputManager")
	if im != null and im.has_method("apply_bindings"):
		im.apply_bindings()


func action_has_events(action: String) -> bool:
	return InputMap.has_action(action) and not InputMap.action_get_events(action).is_empty()


# ------------------------------------------------------------------ menu return / messages

## The game's full reset back to the main menu (pause_menu.gd:104).
func return_to_main_menu() -> bool:
	var pm = _group("PauseMenu")
	if pm != null and pm.has_method("_return_to_main_menu"):
		pm._return_to_main_menu()
		return true
	return false


## Fallback when no PauseMenu is around: the core of
## PauseMenu._return_to_main_menu (pause_menu.gd:104), then the scene change.
func force_main_menu() -> void:
	var gs = g("GameState")
	var um = g("UnlockManager")
	var gp = g("GameProgression")
	var sm = g("SaveManager")
	if gs != null and gs.has_method("reset_all"):
		gs.reset_all()
	if um != null and um.has_method("reset"):
		um.reset()
	if gp != null:
		if gp.has_method("reset_run_state"):
			gp.reset_run_state()
		gp.set("current_phase", 0)
		gp.set("elevator_exited", false)
	if sm != null:
		sm.set("should_load_on_ready", false)
	var tree := _tree()
	if tree != null:
		tree.paused = false
		Engine.time_scale = 1.0
		tree.change_scene_to_file(MAIN_MENU_SCENE)


func show_restrict(text: String) -> void:
	var hud = _group("HUD")
	if hud != null and hud.has_method("show_restrict_message"):
		hud.show_restrict_message(text)


# ------------------------------------------------------------------ achievements (8.4)

func ach_granted() -> Dictionary:
	var st = g("Steamworks")
	if st == null or typeof(st._granted) != TYPE_DICTIONARY:
		return {}
	return st._granted.duplicate()


func ach_set_granted(d: Dictionary) -> void:
	var st = g("Steamworks")
	if st == null:
		return
	st._granted.clear()
	for k in d:
		st._granted[k] = d[k]


func ach_probe_ids() -> Array:
	var st = g("Steamworks")
	return st._probe_ids.duplicate() if st != null else []


## Achievements already met by the loaded state, judged with the game's own
## helpers and rule tables (the same checks evaluate_all makes).
func ach_baseline() -> Array:
	var st = g("Steamworks")
	if st == null:
		return []
	var consts: Dictionary = st.get_script().get_script_constant_map()
	var out: Array = []
	var ach_stat: Dictionary = consts.get("ACH_STAT", {})
	for api_name in ach_stat:
		var rule: Dictionary = ach_stat[api_name]
		var v = st._get_stat(String(rule.get("stat", "")))
		if v != null and st._meets(v, int(rule.get("threshold", 0))):
			out.append(api_name)
	var ach_phase: Dictionary = consts.get("ACH_PHASE", {})
	var phase := get_phase()
	for p in ach_phase:
		if phase >= int(p):
			out.append(ach_phase[p])
	var ach_gate: Dictionary = consts.get("ACH_GATE", {})
	var tree := _tree()
	if tree != null:
		for gate in tree.get_nodes_in_group("vertical_gate"):
			if is_instance_valid(gate) and gate.get("is_solved") == true and ach_gate.has(String(gate.get("gate_id"))):
				out.append(ach_gate[String(gate.get("gate_id"))])
		for cam in tree.get_nodes_in_group("saveable_camera"):
			if is_instance_valid(cam) and cam.get("is_destroyed") == true:
				out.append("BAD")
				break
		var puzzle = tree.get_first_node_in_group("loop_puzzle")
		if is_instance_valid(puzzle) and puzzle.get("is_solved") == true:
			out.append("LOOP")
	var gs = g("GameState")
	if gs != null:
		if gs.get("uv_unlocked") == true:
			out.append("INVISIBLE")
		if gs.get("keypad_revealed") == true:
			out.append("SECRET")
	if st.has_method("consumerism_remaining") and int(st.consumerism_remaining()) == 0:
		out.append("CONSUMERISM")
	return out


## Session over: undo every per-session change made through the adapter.
func session_teardown() -> void:
	set_camera_frozen(false)
	set_movement_locked(false)
	restore_unlock_manager()


## The mod is going away: drop the event subscriptions too.
func dispose() -> void:
	session_teardown()
	if api != null and "events" in api and api.events != null:
		for id in _subs:
			api.events.off(id)
	_subs.clear()
