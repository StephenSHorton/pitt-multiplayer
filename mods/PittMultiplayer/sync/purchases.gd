extends RefCounted
## Purchases (MP-DESIGN 6.5, MP2-DESIGN 6.1).
## Client: extensions/upgrade_ui_ext.gd hands every terminal row here. The row's
## pressed connections are removed and replaced by one that sends a command to
## the host; if the game's wiring is not the single lambda we expect, the row
## fails closed (R12). Recall rows keep the original callable (MP2: the
## extension's _recall_tool sends PittMultiplayer.recall to the host). On the
## reply the extension plays the game's own feedback.
## Host: PittMultiplayer.buy_item / buy_tool / buy_toy re-check everything
## against HOST state (R11) - GameState.buy checks neither enabled nor
## enabled_levels (game_state.gd:1062) - then charge.
## MP2 (shared world, session.mp2_active()): the bought tool/toy is spawned ONCE,
## by the host's own terminal (_spawn_tool_instance / _spawn_toy_instance), and
## appears for everyone as an entity (fixtures through fixture_spawn); the
## client spawns nothing and on_grant is a no-op. Without the MP2 modules the MP1
## behaviour stays: the item spawns in the buyer's private world.

const ContractNet = preload("../net/contract_net.gd")

const CMD_ITEM := "PittMultiplayer.buy_item"
const CMD_TOOL := "PittMultiplayer.buy_tool"
const CMD_TOY := "PittMultiplayer.buy_toy"
const META_PENDING := "pittmp_pending"
const META_REWIRED := "pittmp_rewired"
const META_DISABLED := "disabled"   # the meta the terminal itself sets on a disabled row
const ITEM_CATEGORIES := ["upgrades", "products", "combos", "toys"]

var session = null
var adapter = null
var sent := 0
var fail_closed := 0
var late_grants := 0
var host_spawns := 0
const HOST_FIXTURE_TOOLS := ["press", "trading"]
var _waiting: Dictionary = {}    # client: cmd id -> true while its result is pending
var _late: Dictionary = {}       # client: cmd id -> {kind, args}: result timed out, item may still come
const LATE_MAX := 64


func _init(p_session = null, p_adapter = null) -> void:
	session = p_session
	adapter = p_adapter


# ================================================================== host handlers

## {ok: true, value} or {error, code} (the Session turns it into ctx.fail).
func host_buy_item(args: Dictionary) -> Dictionary:
	var cat := String(args.get("category", ""))
	var key := String(args.get("key", ""))
	var sub := String(args.get("subkey", ""))
	if not (cat in ITEM_CATEGORIES):
		return _err("unsupported category '%s'" % cat, "ERR_INVALID")
	var owner: Dictionary = adapter.item(cat, key)
	if owner.is_empty():
		return _err("unknown item %s/%s" % [cat, key], "ERR_INVALID")
	var it: Dictionary = owner
	if cat == "products":
		if sub == "":
			return _err("products need a subkey", "ERR_INVALID")
		it = adapter.item(cat, key, sub)
		if it.is_empty():
			return _err("unknown item %s/%s/%s" % [cat, key, sub], "ERR_INVALID")
	elif sub != "":
		it = adapter.item(cat, key, sub)
		if it.is_empty():
			return _err("unknown item %s/%s/%s" % [cat, key, sub], "ERR_INVALID")
	if not bool(owner.get("enabled", false)):
		return _err("item is locked", "ERR_DENIED")
	if not it.has("level") or not it.has("prices") or typeof(it.prices) != TYPE_ARRAY:
		return _err("item has no level/prices", "ERR_INVALID")
	var lvl := int(it.level)
	if lvl >= it.prices.size():
		return _err("already at max level", "ERR_FAILED")
	var el = it.get("enabled_levels", [])
	if typeof(el) == TYPE_ARRAY and not el.is_empty() and lvl < el.size() and not bool(el[lvl]):
		return _err("level %d is locked" % (lvl + 1), "ERR_DENIED")
	# affordability FIRST: GameState.buy spawns the auto workbench before its own check
	if not adapter.can_afford_digits(_digits(it.prices[lvl])):
		return _err("insufficient funds", "ERR_FAILED")
	if not adapter.buy(cat, key, sub):
		return _err("purchase refused by the game", "ERR_FAILED")
	return {"ok": true, "value": {"bought": true, "level": int(it.level)}}


func host_buy_tool(args: Dictionary) -> Dictionary:
	var tool := String(args.get("tool", ""))
	var level := int(args.get("level", -1))
	var it: Dictionary = adapter.item("tools", tool)
	if it.is_empty():
		return _err("unknown tool '%s'" % tool, "ERR_INVALID")
	if not bool(it.get("enabled", false)):
		return _err("tool is locked", "ERR_DENIED")
	var el = it.get("enabled_levels", [])
	if typeof(el) == TYPE_ARRAY and level >= 0 and level < el.size() and not bool(el[level]):
		return _err("tool level %d is locked" % (level + 1), "ERR_DENIED")
	var bp = it.get("buy_prices", [])
	if typeof(bp) != TYPE_ARRAY or level < 0 or level >= bp.size():
		return _err("max level", "ERR_FAILED")
	var cost = bp[level]
	if not adapter.can_afford_digits(_digits(cost)):
		return _err("insufficient funds", "ERR_FAILED")
	var ui = null
	if _mp2():
		ui = adapter.upgrade_ui()
		if ui == null or not ui.has_method("_spawn_tool_instance"):
			return _err("no terminal in the host's world", "ERR_UNAVAILABLE")
		if not (tool in HOST_FIXTURE_TOOLS) and tool != "pickaxe" and adapter.pool_full(tool_pool_id(tool, level)):
			return _err("no room for another one", "ERR_FAILED")
	adapter.spend_int(int(cost))
	adapter.mark_purchased_once(tool)
	adapter.check_consumerism()
	if ui != null:
		# MP2: one shared copy, spawned by the host's terminal (fixtures reach clients as fixture_spawn)
		ui._spawn_tool_instance(tool, level)
		host_spawns += 1
	# MP1: the tool spawns only in the buyer's world (private physics)
	return {"ok": true, "value": {"bought": true, "tool": tool, "level": level, "cost": cost}}


func host_buy_toy(args: Dictionary) -> Dictionary:
	var toy := String(args.get("toy", ""))
	var it: Dictionary = adapter.item("toys", toy)
	if it.is_empty():
		return _err("unknown toy '%s'" % toy, "ERR_INVALID")
	if not bool(it.get("enabled", false)):
		return _err("toy is locked", "ERR_DENIED")
	var bp = it.get("buy_prices", [])
	if typeof(bp) != TYPE_ARRAY or bp.is_empty():
		return _err("toy has no price", "ERR_FAILED")
	var cost = bp[0]
	if not adapter.can_afford_digits(_digits(cost)):
		return _err("insufficient funds", "ERR_FAILED")
	var ui = null
	if _mp2():
		ui = adapter.upgrade_ui()
		if ui == null or not ui.has_method("_spawn_toy_instance"):
			return _err("no terminal in the host's world", "ERR_UNAVAILABLE")
		if toy != "bowling_pin_set" and adapter.pool_full("toy_%s" % toy):
			return _err("no room for another one", "ERR_FAILED")
	adapter.spend_int(int(cost))
	adapter.mark_purchased_once(toy)
	adapter.check_consumerism()
	if ContractNet.CRATE_PRICE_STEP.has(toy):
		adapter.set_toy_price0(toy, bp[0] + ContractNet.CRATE_PRICE_STEP[toy])
	if ui != null:
		ui._spawn_toy_instance(toy)
		host_spawns += 1
	if toy == "bowling_pin_set":
		# the game disables the set after one purchase (upgradeUI.gd:1874)
		adapter.set_item_enabled("toys", toy, false)
	return {"ok": true, "value": {"bought": true, "toy": toy, "cost": cost}}


## MP2 shared world: the session has the BODIES module (session.mp2_active()).
func _mp2() -> bool:
	return session != null and session.has_method("mp2_active") and bool(session.mp2_active())


## The pool a bought tool spawns from (upgradeUI._spawn_tool_instance:1840).
static func tool_pool_id(tool: String, level: int) -> String:
	if tool == "scheduler" or tool == "remote":
		return "tool_%s" % tool
	return ("tool_%s_%d" % [tool, level + 1]) if level > 0 else "tool_%s" % tool


static func _err(msg: String, code: String) -> Dictionary:
	return {"ok": false, "error": msg, "code": code}


static func _digits(v) -> String:
	if typeof(v) == TYPE_INT:
		return str(maxi(v, 0))
	if typeof(v) == TYPE_FLOAT:
		return str(int(maxf(v, 0.0)))
	return String(v)


# ================================================================== client rewire

## kind: "item" (args {category, key, subkey}), "tool" ({tool, level}), "toy" ({toy}).
## Returns true when the row now buys through the host.
func rewire(ui: Object, row: Object, kind: String, args: Dictionary) -> bool:
	if row == null or not is_instance_valid(row) or not row.has_meta("button"):
		return false
	var button = row.get_meta("button")
	if not (button is BaseButton):
		return false
	var originals: Array = []
	for c in button.pressed.get_connections():
		originals.append(c.callable)
	for cb in originals:
		if button.pressed.is_connected(cb):
			button.pressed.disconnect(cb)
	if button.pressed.get_connections().size() != 0 or originals.size() != 1:
		# fail closed: the game's wiring is not what we expect, never buy locally
		for c in button.pressed.get_connections():
			button.pressed.disconnect(c.callable)
		_shop_unavailable(ui, row, button)
		fail_closed += 1
		return false
	row.set_meta(META_REWIRED, true)
	button.pressed.connect(_on_pressed.bind(ui, row, kind, args, originals[0]))
	return true


func _shop_unavailable(ui: Object, row: Object, button) -> void:
	button.disabled = true
	button.text = _tr(ui, "MP_SHOP_UNAVAILABLE")
	button.tooltip_text = _tr(ui, "MP_SHOP_UNAVAILABLE")
	row.set_meta(META_DISABLED, true)


static func _tr(o: Object, key: String) -> String:
	return o.tr(key) if o != null and o.has_method("tr") else key


func _on_pressed(ui: Object, row: Object, kind: String, args: Dictionary, original: Callable) -> void:
	if ui == null or not is_instance_valid(ui) or row == null or not is_instance_valid(row):
		return
	var label = row.get_meta("label") if row.has_meta("label") else null
	if label == null or not is_instance_valid(label) or label.is_queued_for_deletion():
		return
	if kind == "tool" and bool(row.get_meta("recall_mode", false)):
		original.call()   # recall is local to the private world
		return
	if bool(row.get_meta(META_PENDING, false)):
		return            # one request per press
	if ui.has_method("_acknowledge_row"):
		ui._acknowledge_row(row)
	if kind == "tool" and adapter != null and not (String(args.tool) in HOST_FIXTURE_TOOLS):
		var pool_id := tool_pool_id(String(args.tool), int(args.get("level", 0)))
		if adapter.pool_full(pool_id):
			_feedback(ui, row, kind, false, "ERR_FAILED", args)
			return
	var cmd := CMD_ITEM if kind == "item" else (CMD_TOOL if kind == "tool" else CMD_TOY)
	row.set_meta(META_PENDING, true)
	sent += 1
	var r = session.execute_command(cmd, args) if session != null else null
	if r == null:
		row.set_meta(META_PENDING, false)
		return
	var cid := int(r.id)
	if not r.done:
		_waiting[cid] = true
		await r.completed
	_waiting.erase(cid)
	if not r.ok and String(r.code) == "ERR_UNAVAILABLE" and kind in ["tool", "toy"]:
		# no answer in time: the host may still have charged; its "grant" brings the item
		if _late.size() >= LATE_MAX:
			_late.erase(_late.keys()[0])
		_late[cid] = {"kind": kind, "args": args.duplicate()}
	if row != null and is_instance_valid(row):
		row.set_meta(META_PENDING, false)
	if ui == null or not is_instance_valid(ui):
		return
	if r.ok and not _mp2():
		match kind:
			"tool":
				ui._spawn_tool_instance(String(args.tool), int(args.level))
				adapter.check_consumerism()
			"toy":
				ui._spawn_toy_instance(String(args.toy))
				adapter.check_consumerism()
	_feedback(ui, row, kind, r.ok, String(r.code), args)


## Client: the host charged a tool/toy purchase (session "grant" message, sent
## before the result on the same ordered stream). Normally the result spawns
## the item; this spawns it when that result had already timed out.
func on_grant(msg: Dictionary) -> bool:
	if _mp2():
		return false    # MP2: the host spawned it in the shared world
	var id := int(msg.get("id", 0))
	if id <= 0 or _waiting.has(id) or not _late.has(id):
		return false
	var e: Dictionary = _late[id]
	_late.erase(id)
	var ui = adapter.upgrade_ui() if adapter != null else null
	if ui == null or not is_instance_valid(ui):
		return false
	match String(e.kind):
		"tool":
			if ui.has_method("_spawn_tool_instance"):
				ui._spawn_tool_instance(String(e.args.tool), int(e.args.level))
		"toy":
			if ui.has_method("_spawn_toy_instance"):
				ui._spawn_toy_instance(String(e.args.toy))
	if adapter.has_method("check_consumerism"):
		adapter.check_consumerism()
	late_grants += 1
	return true


func _feedback(ui: Object, row: Object, kind: String, ok: bool, code: String, args: Dictionary) -> void:
	if ui.has_method("_mp_purchase_feedback"):
		ui._mp_purchase_feedback(row, kind, ok, code, args)
