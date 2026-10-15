extends RefCounted
## GameBridge: turns game signals and polled state into PittEvents.
## ✓ = real signal, ~ = derived by polling/diffing (see docs/API-DESIGN.md 6.2).

const Serial = preload("serial.gd")

const WORLD_SCENE := "res://scenes/world.tscn"
const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"
const SPLASH_SCENE := "res://scenes/splash_screen.tscn"
const ENDING_SCENES := ["res://scenes/test_black_hole.tscn"]
const ITEM_CATEGORIES := ["upgrades", "tools", "toys", "products", "combos"]

var _core: Object = null
var _connected := false

# money
var _money_prev := "0"
var money_reason := ""          # set by core commands around their game call
var _money_poll_t := 0.0
# phase
var _phase_prev := -1
var _ending_prev := false
# session
var _scene_path := ""
var _scene_kind := "other"
var _game_started_prev := false
var in_world := false
var world_count := 0
var _loaded_since_scene := false
# saves
var _last_save_tick_prev := 0
var _awaiting_applied := false
# items
var _items_prev: Dictionary = {}
var _items_dirty := false
# stats throttle
var _stat_last_emit: Dictionary = {}
var _stat_pending: Dictionary = {}
const STAT_MIN_INTERVAL_MS := 100
# menu
var _menu_prev := "<init>"
var _paused_prev := false
# player
var _player_ref: WeakRef = null
var _held_prev := 0
var _equipped_prev := 0
var _held_node_prev: WeakRef = null
# connected per-world nodes (instance ids)
var _connected_nodes: Dictionary = {}


func _init(core: Object) -> void:
	_core = core


var _conns: Array = []   # [object, signal name, callable], undone by disconnect_all()


func g(name: String) -> Object:
	if not is_instance_valid(_core):
		return null
	return _core.g(name)


func ok(feature: String) -> bool:
	return is_instance_valid(_core) and _core.feature_ok(feature)


func _conn(obj: Object, sig: String, c: Callable, flags: int = 0) -> void:
	if obj == null or not obj.has_signal(sig) or obj.is_connected(sig, c):
		return
	obj.connect(sig, c, flags)
	_conns.append([weakref(obj), sig, c])


## Undoes every connection (PittAPI._exit_tree), so a freed core is never called.
func disconnect_all() -> void:
	for e in _conns:
		var obj = e[0].get_ref()
		if obj != null and is_instance_valid(obj) and obj.is_connected(e[1], e[2]):
			obj.disconnect(e[1], e[2])
	_conns.clear()
	_connected = false


func connect_all() -> void:
	if _connected:
		return
	_connected = true
	var tree: SceneTree = _core.get_tree()
	if tree != null:
		if tree.has_signal("scene_changed"):
			_conn(tree, "scene_changed", _on_scene_changed)
		_conn(tree, "node_added", _on_node_added)
	var gs = g("GameState")
	if gs != null and ok("economy"):
		_conn(gs, "money_updated", _on_money_updated)
		_conn(gs, "stat_changed", _on_stat_changed)
		_money_prev = _money_string()
	if gs != null and ok("bank"):
		_conn(gs, "bank_updated", _on_bank_updated)
	var gp = g("GameProgression")
	if gp != null and ok("phase"):
		_conn(gp, "phase_changed", _on_phase_changed)
		_phase_prev = int(gp.current_phase)
		_ending_prev = bool(gp.ending_active)
	var cs = g("ComboSystem")
	if cs != null and ok("combo"):
		_conn(cs, "combo_started", func(level): _emit("combo.started", {"level": level}))
		# declared with 3 args but emitted with 2 (combo_system.gd:104, :211)
		_conn(cs, "combo_updated", func(level, progress): _emit("combo.updated", {"level": level, "progress": progress}))
		_conn(cs, "combo_ended", func(level, bonus): _emit("combo.ended", {"level": level, "bonus": bonus}))
		_conn(cs, "combo_broken", func(): _emit("combo.broken", {}))
		_conn(cs, "mega_combo_activated", func(mult): _emit("combo.mega", {"multiplier": mult}))
	var um = g("UnlockManager")
	if um != null and ok("unlocks"):
		_conn(um, "milestone_unlocked", _on_milestone_unlocked)
	var sm = g("SaveManager")
	if sm != null and ok("saves"):
		_conn(sm, "save_loaded", _on_save_loaded)
		_last_save_tick_prev = int(sm._last_save_tick)
	if ok("items"):
		_items_prev = _item_levels()
	_update_scene()


# ------------------------------------------------------------------ per frame

func process(delta: float) -> void:
	_poll_phase()
	_poll_session()
	_poll_saves()
	_poll_menu()
	_money_poll_t += delta
	if _money_poll_t >= 0.5:
		_money_poll_t = 0.0
		_poll_money()
	if _items_dirty:
		_items_dirty = false
		_diff_items()
	_flush_stats(false)


func physics_process(_delta: float) -> void:
	_poll_player()


# ------------------------------------------------------------------ scene / session

func scene_kind_for(path: String) -> String:
	if path == WORLD_SCENE:
		return "world"
	if path == MAIN_MENU_SCENE:
		return "main_menu"
	if path == SPLASH_SCENE:
		return "splash"
	if path in ENDING_SCENES:
		return "ending"
	return "other"


func current_scene_kind() -> String:
	return _scene_kind


func _update_scene() -> void:
	var tree: SceneTree = _core.get_tree()
	if tree == null:
		return
	var cs := tree.current_scene
	_scene_path = cs.scene_file_path if cs != null else ""
	_scene_kind = scene_kind_for(_scene_path)


func _on_scene_changed() -> void:
	var was_world := in_world
	_update_scene()
	_loaded_since_scene = false
	_connected_nodes.clear()
	if was_world and _scene_kind != "world":
		_world_exited()
	_emit("scene.changed", {"path": _scene_path, "kind": _scene_kind}, "game")


func _poll_session() -> void:
	var tree: SceneTree = _core.get_tree()
	if tree == null:
		return
	# fallback when scene_changed is missing: compare paths
	var cs := tree.current_scene
	var path := cs.scene_file_path if cs != null else ""
	if path != _scene_path and not tree.has_signal("scene_changed"):
		_on_scene_changed()
	if not ok("session"):
		return
	var gs = g("GameState")
	if gs == null:
		return
	var started := bool(gs.is_game_started)
	if started and not _game_started_prev and _scene_kind == "world" and not in_world:
		in_world = true
		world_count += 1
		var sm = g("SaveManager")
		var key := ""
		if sm != null and ok("saves"):
			key = String(sm.active_save_path).get_file().get_basename()
		_scan_world_nodes()
		_core.on_world_ready()
		_emit("world.ready", {"new_game": not _loaded_since_scene, "save_key": key,
			"sandbox": bool(gs.sandbox_mode)}, "game")
	elif not started and _game_started_prev and in_world:
		_world_exited()
	_game_started_prev = started


func _world_exited() -> void:
	if not in_world:
		return
	in_world = false
	_player_ref = null
	_held_prev = 0
	_equipped_prev = 0
	_core.on_world_exited()
	_emit("world.exited", {}, "game")


func _on_node_added(node: Node) -> void:
	# groups declared in .tscn are already assigned when node_added fires
	if node.is_in_group("player"):
		if not node.is_node_ready():
			_conn(node, "ready", _on_player_ready.bind(node), CONNECT_ONE_SHOT)
		else:
			_on_player_ready(node)
	elif node.is_in_group("BottomMaw"):
		_connect_maw(node)
	elif node.is_in_group("MainMenu") or node.name == "MainMenu":
		_core.contract_check_node(node)


func _on_player_ready(node: Node) -> void:
	if not is_instance_valid(node) or not is_instance_valid(_core):
		return
	_player_ref = weakref(node)
	_core.contract_check_node(node)
	var cam = _camera()
	if cam != null:
		_core.contract_check_node(cam)
		var ray = cam.get_node_or_null("InteractRay")
		if ray != null:
			_core.contract_check_node(ray)
	# players use the reserved 1..999 range (slot of the local peer)
	var peer: int = _core.authority.local_peer_id() if _core.authority != null else 1
	var pid: int = _core.entities.register_player(node, peer)
	_emit("player.ready", {"entity_id": pid}, "game")


func _connect_maw(node: Node) -> void:
	var iid := node.get_instance_id()
	if _connected_nodes.has(iid):
		return
	_core.contract_check_node(node)
	if not ok("maw") or not node.has_signal("product_consumed"):
		return
	_connected_nodes[iid] = true
	_conn(node, "product_consumed", _on_product_consumed)


## Called on world.ready: connects nodes whose groups are added in _ready.
func _scan_world_nodes() -> void:
	var tree: SceneTree = _core.get_tree()
	for gate in tree.get_nodes_in_group("vertical_gate"):
		var iid: int = gate.get_instance_id()
		if _connected_nodes.has(iid):
			continue
		_core.contract_check_node(gate)
		if ok("gates") and gate.has_signal("gate_opened"):
			_connected_nodes[iid] = true
			_conn(gate, "gate_opened", func(gate_id): _emit("gate.opened", {"gate_id": gate_id}, "game"))
	for maw in tree.get_nodes_in_group("BottomMaw"):
		_connect_maw(maw)
	var hud = tree.get_first_node_in_group("HUD")
	if hud != null:
		_core.contract_check_node(hud)
	var hole = tree.get_first_node_in_group("saveable_hole")
	if hole != null:
		_core.contract_check_node(hole)
	var ui = tree.get_first_node_in_group("UpgradeUI")
	if ui != null:
		_core.contract_check_node(ui)
	# register static fixtures with deterministic keys
	var cs := tree.current_scene
	if cs != null:
		for path in ["BottomMaw", "Floor", "ManualDuckWorkbench", "UpgradeTerminal"]:
			var n = cs.get_node_or_null(path)
			if n != null and _core.entities.id_of(n) == 0:
				_core.entities.track(n, "static:/root/World/%s" % path, "PittAPI")
	var ws = g("WorkbenchSpawning")
	if ws != null:
		for table in ["manual_workbenches", "auto_workbenches"]:
			if not (table in ws):
				continue
			var t = ws.get(table)
			if typeof(t) != TYPE_DICTIONARY:
				continue
			for k in t:
				var entry = t[k]
				if typeof(entry) == TYPE_DICTIONARY and entry.get("instance", null) is Node:
					var inst: Node = entry.instance
					if is_instance_valid(inst) and _core.entities.id_of(inst) == 0:
						_core.entities.track(inst, "workbench:%s:%s" % ["manual" if table == "manual_workbenches" else "auto", k], "PittAPI")
	for gate in tree.get_nodes_in_group("vertical_gate"):
		if "gate_id" in gate and _core.entities.id_of(gate) == 0:
			_core.entities.track(gate, "gate:%s" % gate.gate_id, "PittAPI")


# ------------------------------------------------------------------ money / stats

func _money_string() -> String:
	var gs = g("GameState")
	if gs == null or not ok("economy"):
		return "0"
	return Serial.to_digits(gs.money)


func _on_money_updated(_amount) -> void:
	_check_money("signal")
	_items_dirty = true


func _poll_money() -> void:
	_check_money("poll")


func _check_money(via: String) -> void:
	var now := _money_string()
	if now == _money_prev:
		return
	var d := Serial.digits_diff(now, _money_prev)
	_money_prev = now
	var reason := money_reason
	if reason == "" and _applying():
		reason = "net"
	if reason == "":
		if via == "poll" or via == "stat":
			reason = "direct"
		else:
			reason = "add" if d.sign > 0 else "spend"
	_emit("money.changed", {"money": now, "delta": d.delta, "sign": d.sign, "reason": reason}, "game")


func _on_bank_updated(amount) -> void:
	_emit("bank.changed", {"bank": float(amount)}, "game")


func _on_stat_changed(stat_name: String, value) -> void:
	_items_dirty = true
	if stat_name == "money":
		# golden statue bypass: money changed without money_updated
		_check_money("stat")
	if stat_name.begins_with("products_crafted.") or stat_name.begins_with("products_autocrafted."):
		var auto := stat_name.begins_with("products_autocrafted.")
		_emit("product.crafted", {"key": stat_name.get_slice(".", 1), "auto": auto}, "game")
	_stat_pending[stat_name] = value
	_flush_stats(false)


func _flush_stats(force: bool) -> void:
	if _stat_pending.is_empty():
		return
	var now := Time.get_ticks_msec()
	for stat in _stat_pending.keys():
		var last := int(_stat_last_emit.get(stat, -100000))
		if force or now - last >= STAT_MIN_INTERVAL_MS:
			var v = _stat_pending[stat]
			_stat_pending.erase(stat)
			_stat_last_emit[stat] = now
			_emit("stat.changed", {"stat": stat, "value": Serial.to_json_safe(v)}, "game")


# ------------------------------------------------------------------ items

func _item_levels() -> Dictionary:
	var out := {}
	var gs = g("GameState")
	if gs == null:
		return out
	for cat in ITEM_CATEGORIES:
		var table = gs.get(cat)
		if typeof(table) != TYPE_DICTIONARY:
			continue
		for key in table:
			var item = table[key]
			if typeof(item) != TYPE_DICTIONARY:
				continue
			if item.has("level"):
				out["%s|%s|" % [cat, key]] = [int(item.level), bool(item.get("enabled", false))]
			else:
				for sub in item:
					var s = item[sub]
					if typeof(s) == TYPE_DICTIONARY and s.has("level"):
						out["%s|%s|%s" % [cat, key, sub]] = [int(s.level), bool(s.get("enabled", false))]
	return out


func _diff_items() -> void:
	if not ok("items"):
		return
	var now := _item_levels()
	for k in now:
		var prev = _items_prev.get(k, null)
		if prev == null or prev[0] != now[k][0] or prev[1] != now[k][1]:
			var p: PackedStringArray = k.split("|")
			var payload := {"category": p[0], "key": p[1], "level": now[k][0], "enabled": now[k][1]}
			if p[2] != "":
				payload["subkey"] = p[2]
			if prev != null:
				payload["prev_level"] = prev[0]
			_emit("item.level_changed", payload, "game")
	_items_prev = now


func mark_items_dirty() -> void:
	_items_dirty = true


# ------------------------------------------------------------------ phase

func _poll_phase() -> void:
	if not ok("phase"):
		return
	var gp = g("GameProgression")
	if gp == null:
		return
	var p := int(gp.current_phase)
	if p != _phase_prev:
		var from := _phase_prev
		_phase_prev = p
		var src := "transition"
		var sm = g("SaveManager")
		if sm != null and ok("saves") and bool(sm.is_loading):
			src = "load"
		elif not in_world:
			src = "poll"
		_emit("phase.changed", {"from": from, "to": p, "source": src}, "game")
	var ending := bool(gp.ending_active)
	if ending and not _ending_prev:
		_emit("ending.started", {"secret": false}, "game")
	_ending_prev = ending


func _on_phase_changed(new_phase) -> void:
	_poll_phase()
	_emit("phase.settled", {"phase": int(new_phase)}, "game")


# ------------------------------------------------------------------ unlocks

func _on_milestone_unlocked(id: String, data: Dictionary) -> void:
	var sm = g("SaveManager")
	var replay := sm != null and ok("saves") and bool(sm.is_loading)
	_emit("unlock.milestone", {"id": id, "category": String(data.get("category", "")), "replay": replay}, "game")
	_items_dirty = true


# ------------------------------------------------------------------ saves

func _save_key() -> String:
	var sm = g("SaveManager")
	if sm == null or not ok("saves"):
		return ""
	return String(sm.active_save_path).get_file().get_basename()


func _slot() -> int:
	var sm = g("SaveManager")
	if sm == null or not ok("saves"):
		return -1
	return int(sm.slot_from_path(sm.active_save_path)) if sm.has_method("slot_from_path") else -1


func _on_save_loaded() -> void:
	_loaded_since_scene = true
	_awaiting_applied = true
	_emit("save.loaded", {"save_key": _save_key(), "slot": _slot()}, "game")
	_core.on_save_loaded(_save_key())


func _poll_saves() -> void:
	if not ok("saves"):
		return
	var sm = g("SaveManager")
	if sm == null:
		return
	var tick := int(sm._last_save_tick)
	if tick != _last_save_tick_prev:
		_last_save_tick_prev = tick
		_emit("save.saved", {"save_key": _save_key(), "slot": _slot()}, "game")
		_core.on_save_saved(_save_key())
	if _awaiting_applied:
		var pending = sm.pending_pool_data
		if (typeof(pending) != TYPE_DICTIONARY or pending.is_empty()) and not bool(sm.is_loading):
			_awaiting_applied = false
			_emit("save.applied", {"save_key": _save_key(), "slot": _slot()}, "game")


# ------------------------------------------------------------------ menu

func _poll_menu() -> void:
	if not ok("menu"):
		return
	var mm = g("MenuManager")
	if mm == null:
		return
	var m = mm.current_menu
	var name = String(m.name) if m != null and is_instance_valid(m) else null
	var key := str(name)
	var paused := bool(mm.game_paused)
	if key != _menu_prev or paused != _paused_prev:
		_menu_prev = key
		_paused_prev = paused
		_emit("ui.menu_changed", {"menu": name, "paused": paused}, "game")


# ------------------------------------------------------------------ player

func get_player() -> Node:
	if _player_ref != null:
		var p = _player_ref.get_ref()
		if p != null and is_instance_valid(p) and p.is_inside_tree():
			return p
	var tree: SceneTree = _core.get_tree()
	if tree == null:
		return null
	var n = tree.get_first_node_in_group("player")
	if n != null:
		_player_ref = weakref(n)
	return n


func _camera() -> Node:
	var tree: SceneTree = _core.get_tree()
	return tree.get_first_node_in_group("main_camera") if tree != null else null


func _poll_player() -> void:
	if not in_world or not ok("camera"):
		return
	var cam = _camera()
	if cam == null:
		return
	var held = cam.picked_object
	var eq = cam.equipped_item
	var held_id := _id_for(held)
	var eq_id := _id_for(eq)
	if held_id != _held_prev:
		var thrown := false
		if held_id == 0 and _held_prev != 0:
			thrown = Input.is_action_pressed("rMouse") if InputMap.has_action("rMouse") else false
		_emit("player.held_changed", {"entity_id": held_id if held_id != 0 else null,
			"prev": _held_prev if _held_prev != 0 else null, "thrown": thrown}, "game")
		_held_prev = held_id
	if eq_id != _equipped_prev:
		_emit("player.equipped_changed", {"entity_id": eq_id if eq_id != 0 else null,
			"prev": _equipped_prev if _equipped_prev != 0 else null, "thrown": false}, "game")
		_equipped_prev = eq_id


var _forced_iid := 0


func _id_for(node) -> int:
	if node == null or not is_instance_valid(node):
		return 0
	var id: int = _core.entities.id_of(node)
	if id == 0 and node.get_instance_id() != _forced_iid:
		# maybe spawned this frame: one forced diff per object (fixtures stay 0)
		_forced_iid = node.get_instance_id()
		_core.entities.reconcile(0.0, true)
		id = _core.entities.id_of(node)
	return id


# ------------------------------------------------------------------ helpers

func _on_product_consumed(product_type: String, nutrition_value: int, body_id: int) -> void:
	if _scene_kind != "world":
		return   # the main menu has a decorative BottomMaw too
	var eid := 0
	var value = null
	var body = instance_from_id(body_id) if body_id != 0 else null
	if body != null and is_instance_valid(body):
		eid = _core.entities.id_of(body)
		if "value" in body:
			value = body.get("value")
	if product_type == "recycle":
		# bottom_maw.gd:137-141 pays recycle_value but emits nutrition 0: not a sale
		var rv = 0
		if body != null and is_instance_valid(body):
			rv = body.get_meta("recycle_value", body.get("recycle_value") if "recycle_value" in body else 0)
		_emit("product.recycled", {"value": int(rv) if typeof(rv) in [TYPE_INT, TYPE_FLOAT] else 0,
			"entity_id": eid if eid != 0 else null}, "game")
		return
	_emit("product.sold", {"product_type": product_type, "lucky": product_type.begins_with("lucky_"),
		"value": nutrition_value, "body_value": value, "entity_id": eid if eid != 0 else null}, "game")


func _emit(name: String, payload: Dictionary, source: String = "game") -> void:
	if is_instance_valid(_core) and _core.events != null:
		_core.events.emit_internal(name, payload, source)


func reset_money_baseline() -> void:
	_money_prev = _money_string()


func _applying() -> bool:
	return is_instance_valid(_core) and "_net_apply_origin" in _core and int(_core._net_apply_origin) > 0


## L3: called by api.net.end_apply() before the apply window closes, so money,
## item and phase changes made by the applied state are emitted tagged "net".
func flush_for_apply() -> void:
	_check_money("signal")
	_poll_phase()
	if ok("items"):
		_items_dirty = false
		_diff_items()
	_flush_stats(true)
