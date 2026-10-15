extends RefCounted
## Core commands. Every API mutation is one of these (the facades call them).
## Handlers run on the authority: func(args: Dictionary, ctx) -> JSON-safe value.

const Serial = preload("serial.gd")

const TEST_SAVE_PREFIX := "user://pittapi/"
const MAX_PHYSICS_STEPS := 8   # catch-up cap while physics is pinned
const DEFAULT_ISOLATED_SAVE := "user://pittapi/test/isolated.save"
const MILESTONE_TYPES := ["stat_threshold", "combined_stat_threshold", "phase_reached",
	"floor_product_count", "group_all_flagged", "group_flagged_count", "state_flag"]

var _core: Object = null
var _cheat_toast_shown := false


func _init(core: Object) -> void:
	_core = core


func register_all(cmds: Object) -> void:
	var NUM := [TYPE_STRING, TYPE_INT, TYPE_FLOAT]
	var VEC := TYPE_ARRAY
	cmds.register("money.add", _money_add, {"feature": "economy", "replicate": "events",
		"schema": {"amount": NUM, "reason?": TYPE_STRING},
		"description": "Add money (counts toward total_money_gained and milestones). reason: add|bonus"})
	cmds.register("money.spend", _money_spend, {"feature": "economy",
		"schema": {"amount": NUM}, "description": "Spend money; fails instead of flooring at 0"})
	cmds.register("money.set", _money_set, {"feature": "economy", "cheat": true,
		"schema": {"amount": NUM}, "description": "Set money exactly (load-path semantics, no stats)"})
	cmds.register("bank.set", _bank_set, {"feature": "bank", "cheat": true,
		"schema": {"amount": [TYPE_FLOAT, TYPE_INT]}, "description": "Set the gambling bank"})
	cmds.register("item.buy", _item_buy, {"feature": "items",
		"schema": {"category": TYPE_STRING, "key": TYPE_STRING, "subkey?": TYPE_STRING},
		"description": "GameState.buy for upgrades/products/combos"})
	cmds.register("phase.set", _phase_set, {"feature": "phase", "cheat": true,
		"schema": {"phase": TYPE_INT, "allow_ending?": TYPE_BOOL},
		"description": "GameProgression.change_phase (refuses 5 unless allow_ending)"})
	cmds.register("unlock.force", _unlock_force, {"feature": "unlocks", "cheat": true,
		"schema": {"id": TYPE_STRING}, "description": "UnlockManager.force_unlock"})
	cmds.register("unlock.register_milestone", _unlock_register, {"feature": "unlocks",
		"schema": {"id": TYPE_STRING, "def": TYPE_DICTIONARY},
		"description": "Add a namespaced milestone mod.<mod>.<id> (before the first world load)"})
	cmds.register("entity.spawn", _entity_spawn, {"feature": "spawn",
		"schema": {"pool_id": TYPE_STRING, "position": VEC, "rotation?": VEC, "velocity?": VEC, "meta?": TYPE_DICTIONARY},
		"description": "ObjectPoolManager.spawn -> {entity_id}"})
	cmds.register("entity.despawn", _entity_despawn, {"feature": "spawn",
		"schema": {"entity_id": TYPE_INT}, "description": "ObjectPoolManager.recycle (pooled entities only)"})
	cmds.register("entity.set_transform", _entity_set_transform, {
		"schema": {"entity_id": TYPE_INT, "position?": VEC, "rotation?": VEC}, "description": "Move an entity"})
	cmds.register("entity.impulse", _entity_impulse, {
		"schema": {"entity_id": TYPE_INT, "impulse": VEC}, "description": "apply_central_impulse on a RigidBody3D"})
	cmds.register("player.teleport", _player_teleport, {"feature": "player", "scope": "local",
		"schema": {"position?": VEC, "transform?": VEC}, "description": "teleport_to / teleport_to_transform"})
	cmds.register("player.impulse", _player_impulse, {"feature": "player", "scope": "local",
		"schema": {"impulse": VEC}, "description": "apply_external_impulse"})
	cmds.register("achievements.suppress", _achievements_suppress, {"feature": "achievements", "scope": "local",
		"replicate": "none", "schema": {}, "description": "Mark every achievement as granted for this session"})
	cmds.register("perf.pin_physics", _perf_pin, {"replicate": "none", "scope": "local",
		"schema": {"hz?": TYPE_INT}, "description": "Stop PerformanceMonitor and pin the physics tick rate"})
	cmds.register("save.isolate", _save_isolate, {"feature": "saves", "replicate": "none", "scope": "local",
		"schema": {"enabled": TYPE_BOOL, "path?": TYPE_STRING},
		"description": "Redirect saves to a non-slot path under user://pittapi/ (default %s) and keep save_locked/autosave off; disable restores the previous path and flags. The ending still writes profile.cfg, so phase.set 5 is refused while on" % DEFAULT_ISOLATED_SAVE})
	cmds.register("presence.suppress", _presence_suppress, {"feature": "presence", "replicate": "none", "scope": "local",
		"schema": {"enabled": TYPE_BOOL}, "description": "Stop (and clear) Steam rich presence updates for this session"})


# ------------------------------------------------------------------ helpers

func g(n: String) -> Object:
	return _core.g(n)


func _bigint_script() -> Object:
	var gs = g("GameState")
	if gs != null and Serial.is_bigint(gs.money):
		return gs.money.get_script()
	for c in ProjectSettings.get_global_class_list():
		if c.get("class", "") == "BigInt":
			return load(c.path)
	return null


func _big(digits: String) -> Object:
	var s = _bigint_script()
	return s.from_string(digits) if s != null else null


func _with_reason(reason: String, f: Callable) -> Variant:
	_core.bridge.money_reason = reason
	var r = f.call()
	_core.bridge._check_money("signal")
	_core.bridge.money_reason = ""
	return r


# ------------------------------------------------------------------ economy

func _money_add(args: Dictionary, ctx) -> Variant:
	var digits := Serial.to_digits(args.amount)
	if digits == "":
		return ctx.fail("amount must be a non-negative integer (int or digit string)", "ERR_INVALID")
	var reason := String(args.get("reason", "add"))
	if not (reason in ["add", "bonus"]):
		return ctx.fail("reason must be add or bonus", "ERR_INVALID")
	var gs = g("GameState")
	if digits == "0":
		return {"money": Serial.to_digits(gs.money)}
	if Serial.digits_fit_int64(digits) and digits.length() <= 18:
		var amt := int(digits)
		_with_reason(reason, func():
			if reason == "bonus":
				gs.add_bonus(amt)
			else:
				gs.add_money(amt))
	else:
		var b = _big(digits)
		if b == null:
			return ctx.fail("BigInt is unavailable", "ERR_UNAVAILABLE")
		_with_reason(reason, func():
			gs.money.add_big(b)
			gs.total_money_gained.add_big(_big(digits))
			gs.money_updated.emit(gs.money)
			gs.stat_changed.emit("total_money_gained", gs.total_money_gained))
	return {"money": Serial.to_digits(gs.money)}


func _money_spend(args: Dictionary, ctx) -> Variant:
	var digits := Serial.to_digits(args.amount)
	if digits == "":
		return ctx.fail("amount must be a non-negative integer", "ERR_INVALID")
	var gs = g("GameState")
	var have := Serial.to_digits(gs.money)
	if Serial.digits_compare(have, digits) < 0:
		return ctx.fail("insufficient funds (have %s, need %s)" % [have, digits], "ERR_FAILED")
	if Serial.digits_fit_int64(digits) and digits.length() <= 18:
		var amt := int(digits)
		_with_reason("spend", func(): gs.spend(amt))
	else:
		_with_reason("spend", func():
			gs.money.sub_big(_big(digits))
			gs.total_money_spent.add_big(_big(digits))
			gs.money_updated.emit(gs.money))
	return {"ok": true, "money": Serial.to_digits(gs.money)}


func _money_set(args: Dictionary, ctx) -> Variant:
	var digits := Serial.to_digits(args.amount)
	if digits == "":
		return ctx.fail("amount must be a non-negative integer", "ERR_INVALID")
	var gs = g("GameState")
	var b = _big(digits)
	if b == null:
		return ctx.fail("BigInt is unavailable", "ERR_UNAVAILABLE")
	_with_reason("set", func():
		gs.money = b
		gs.money_updated.emit(gs.money))
	return {"money": Serial.to_digits(gs.money)}


func _bank_set(args: Dictionary, ctx) -> Variant:
	var x := float(args.amount)
	if x < 0.0 or is_nan(x) or is_inf(x):
		return ctx.fail("amount must be >= 0", "ERR_INVALID")
	var gs = g("GameState")
	gs.bank = x
	gs.bank_updated.emit(x)
	return {"bank": x}


func _item_buy(args: Dictionary, ctx) -> Variant:
	var cat := String(args.category)
	var key := String(args.key)
	var sub := String(args.get("subkey", ""))
	if not (cat in ["upgrades", "products", "combos"]):
		return ctx.fail("item.buy supports upgrades, products and combos (tools/toys are bought at the terminal)", "ERR_INVALID")
	var gs = g("GameState")
	var table = gs.get(cat)
	if typeof(table) != TYPE_DICTIONARY or not table.has(key):
		return ctx.fail("unknown item %s/%s" % [cat, key], "ERR_INVALID")
	var item = table[key]
	if cat == "products":
		if sub == "" or typeof(item) != TYPE_DICTIONARY or not item.has(sub) or typeof(item[sub]) != TYPE_DICTIONARY:
			return ctx.fail("products need a valid subkey (craft_speed, craft_value, auto_machine)", "ERR_INVALID")
		item = item[sub]
	if typeof(item) != TYPE_DICTIONARY or not item.has("level") or not item.has("prices"):
		return ctx.fail("item %s/%s has no level/prices" % [cat, key], "ERR_INVALID")
	var lvl := int(item.level)
	var prices = item.prices
	if lvl >= prices.size():
		return ctx.fail("already at max level", "ERR_FAILED")
	# check affordability first: GameState.buy spawns the auto workbench before
	# its own affordability check (game bug, game_state.gd:1083)
	if not gs.can_afford(prices[lvl]):
		return ctx.fail("cannot afford %s" % str(prices[lvl]), "ERR_FAILED")
	var bought = _with_reason("spend", func(): return gs.buy(cat, key, sub))
	_core.bridge.mark_items_dirty()
	if not bool(bought):
		return ctx.fail("purchase refused by the game", "ERR_FAILED")
	return {"bought": true, "level": int(item.level)}


# ------------------------------------------------------------------ progression

func _phase_set(args: Dictionary, ctx) -> Variant:
	var p := int(args.phase)
	if p < 0 or p > 5:
		return ctx.fail("phase must be 0..5", "ERR_INVALID")
	if p == 5 and not bool(args.get("allow_ending", false)):
		return ctx.fail("phase 5 starts the irreversible ending; pass allow_ending=true", "ERR_DENIED")
	if p == 5 and _core.save_isolation:
		return ctx.fail("phase 5 is refused while save.isolate is on (the ending writes profile.cfg and force-saves)", "ERR_DENIED")
	if not _core.bridge.in_world:
		return ctx.fail("phase.set needs a running world", "ERR_UNAVAILABLE")
	g("GameProgression").change_phase(p)
	return {"phase": int(g("GameProgression").current_phase)}


func _unlock_force(args: Dictionary, ctx) -> Variant:
	var um = g("UnlockManager")
	var id := String(args.id)
	if not um.milestones.has(id):
		return ctx.fail("unknown milestone '%s'" % id, "ERR_INVALID")
	if um.is_unlocked(id):
		return {"id": id, "already": true}
	um.force_unlock(id)
	var ui = _core.get_tree().get_first_node_in_group("UpgradeUI")
	if ui != null and ui.has_method("update_ui") and _core.feature_ok("upgrade_ui"):
		ui.update_ui()
	_core.bridge.mark_items_dirty()
	return {"id": id, "already": false}


func _unlock_register(args: Dictionary, ctx) -> Variant:
	if _core.bridge.world_count > 0:
		return ctx.fail("milestones must be registered before the first world load (in _mod_init)", "ERR_DENIED")
	var name := String(args.id)
	var re := RegEx.new()
	re.compile("^[A-Za-z0-9_]{1,64}$")
	if re.search(name) == null:
		return ctx.fail("id must be [A-Za-z0-9_]{1,64}; it is namespaced as mod.<mod>.<id>", "ERR_INVALID")
	if ctx.is_remote:
		return ctx.fail("milestones can only be registered by local mods", "ERR_DENIED")
	var owner: String = ctx.mod_id if ctx.mod_id != "" else "PittAPI"
	var full := "mod.%s.%s" % [owner, name]
	var def: Dictionary = args.def
	var derr := validate_milestone_def(def)
	if derr != "":
		return ctx.fail(derr, "ERR_INVALID")
	var um = g("UnlockManager")
	if um.milestones.has(full):
		return ctx.fail("milestone %s already exists" % full, "ERR_INVALID")
	um.milestones[full] = def.duplicate(true)
	return {"id": full}


## Checks the keys UnlockManager.check_milestones() reads without .get() for each
## type (unlock_manager.gd:1654-1720), so a bad def fails here and not every
## check inside game code. Returns "" when valid.
static func validate_milestone_def(def: Dictionary) -> String:
	var type := String(def.get("type", ""))
	if not (type in MILESTONE_TYPES):
		return "def.type must be one of %s" % str(MILESTONE_TYPES)
	if typeof(def.get("action", null)) != TYPE_DICTIONARY:
		return "def.action must be a Dictionary (see UnlockManager._execute_action)"
	var num := func(k: String) -> String:
		if not def.has(k) or not (typeof(def[k]) in [TYPE_INT, TYPE_FLOAT]):
			return "def.%s must be a number for type %s" % [k, type]
		return ""
	var text := func(k: String) -> String:
		if typeof(def.get(k, null)) != TYPE_STRING or String(def[k]) == "":
			return "def.%s must be a non-empty String for type %s" % [k, type]
		return ""
	var e := ""
	match type:
		"stat_threshold":
			e = text.call("stat")
			if e == "":
				e = num.call("threshold")
		"combined_stat_threshold":  # weighted sum of several stats
			e = num.call("threshold")
			if e == "":
				var stats = def.get("stats", null)
				if typeof(stats) != TYPE_ARRAY or (stats as Array).is_empty():
					e = "def.stats must be a non-empty Array of {stat, weight?}"
				else:
					for entry in stats:
						if typeof(entry) != TYPE_DICTIONARY or typeof(entry.get("stat", null)) != TYPE_STRING:
							e = "every def.stats entry must be a Dictionary with a String 'stat'"
							break
						if entry.has("weight") and not (typeof(entry.weight) in [TYPE_INT, TYPE_FLOAT]):
							e = "def.stats[].weight must be a number"
							break
		"phase_reached":
			e = num.call("phase")
		"group_all_flagged":
			e = text.call("group")
		"group_flagged_count":
			e = text.call("group")
			if e == "":
				e = num.call("threshold")
		"floor_product_count":
			e = num.call("threshold")
		"state_flag":
			e = text.call("flag")
	if e != "":
		return e
	for k in ["require_min", "min_phase"]:
		if def.has(k) and not (typeof(def[k]) in [TYPE_INT, TYPE_FLOAT]):
			return "def.%s must be a number" % k
	if def.has("flag") and typeof(def.flag) != TYPE_STRING:
		return "def.flag must be a String"
	if def.has("requires"):
		if typeof(def.requires) != TYPE_ARRAY:
			return "def.requires must be an Array of milestone ids"
		for r in def.requires:
			if typeof(r) != TYPE_STRING:
				return "def.requires must contain only Strings"
	return ""


# ------------------------------------------------------------------ entities

func _entity_spawn(args: Dictionary, ctx) -> Variant:
	var pm = g("ObjectPoolManager")
	if not bool(pm._initialized):
		return ctx.fail("object pools are not initialized yet (press Play first)", "ERR_UNAVAILABLE")
	var pool_id := String(args.pool_id)
	if not pm._pools.has(pool_id):
		return ctx.fail("unknown pool '%s'" % pool_id, "ERR_INVALID")
	var pos = Serial.vec3_from(args.position)
	if pos == null:
		return ctx.fail("position must be [x,y,z]", "ERR_INVALID")
	var rot = Vector3.ZERO
	if args.has("rotation"):
		rot = Serial.vec3_from(args.rotation)
		if rot == null:
			return ctx.fail("rotation must be [x,y,z] (radians)", "ERR_INVALID")
	var vel = null
	if args.has("velocity"):
		vel = Serial.vec3_from(args.velocity)
		if vel == null:
			return ctx.fail("velocity must be [x,y,z]", "ERR_INVALID")
	var pool = pm._pools[pool_id]
	if pool.available.is_empty() and pool.available.size() + pool.active.size() >= int(pool.max_size):
		return ctx.fail("pool '%s' is exhausted" % pool_id, "ERR_FAILED")
	var node = pm.spawn(pool_id, pos, rot)
	if node == null:
		return ctx.fail("ObjectPoolManager.spawn returned null", "ERR_FAILED")
	if vel != null and node is RigidBody3D:
		node.linear_velocity = vel
	if args.has("meta"):
		for k in args.meta:
			node.set_meta(String(k), args.meta[k])
	var eid: int = _core.entities.register_pooled(node, pool_id, "api")
	return {"entity_id": eid, "pool_id": pool_id}


func _entity_despawn(args: Dictionary, ctx) -> Variant:
	var id := int(args.entity_id)
	var node = _core.entities.get_node(id)
	if node == null:
		return ctx.fail("unknown entity %d" % id, "ERR_INVALID")
	if _core.entities.kind_of(id) != "pooled":
		return ctx.fail("only pooled entities can be despawned", "ERR_DENIED")
	g("ObjectPoolManager").recycle(node)
	_core.entities.despawned(id, "api")
	return {"entity_id": id}


func _entity_set_transform(args: Dictionary, ctx) -> Variant:
	var node = _core.entities.get_node(int(args.entity_id))
	if node == null or not (node is Node3D):
		return ctx.fail("unknown 3D entity %d" % int(args.entity_id), "ERR_INVALID")
	if args.has("position"):
		var p = Serial.vec3_from(args.position)
		if p == null:
			return ctx.fail("position must be [x,y,z]", "ERR_INVALID")
		node.global_position = p
	if args.has("rotation"):
		var r = Serial.vec3_from(args.rotation)
		if r == null:
			return ctx.fail("rotation must be [x,y,z]", "ERR_INVALID")
		node.global_rotation = r
	return {"entity_id": int(args.entity_id)}


func _entity_impulse(args: Dictionary, ctx) -> Variant:
	var node = _core.entities.get_node(int(args.entity_id))
	if node == null or not (node is RigidBody3D):
		return ctx.fail("entity %d is not a RigidBody3D" % int(args.entity_id), "ERR_INVALID")
	var imp = Serial.vec3_from(args.impulse)
	if imp == null:
		return ctx.fail("impulse must be [x,y,z]", "ERR_INVALID")
	node.sleeping = false
	node.apply_central_impulse(imp)
	return {"entity_id": int(args.entity_id)}


func _player_teleport(args: Dictionary, ctx) -> Variant:
	var p = _core.bridge.get_player()
	if p == null:
		return ctx.fail("no player in the world", "ERR_UNAVAILABLE")
	if args.has("transform"):
		var t = Serial.transform_from(args.transform)
		if t == null:
			return ctx.fail("transform must be 12 numbers", "ERR_INVALID")
		p.teleport_to_transform(t)
	elif args.has("position"):
		var v = Serial.vec3_from(args.position)
		if v == null:
			return ctx.fail("position must be [x,y,z]", "ERR_INVALID")
		p.teleport_to(v)
	else:
		return ctx.fail("pass position or transform", "ERR_INVALID")
	return {"position": p.global_position}


func _player_impulse(args: Dictionary, ctx) -> Variant:
	var p = _core.bridge.get_player()
	if p == null:
		return ctx.fail("no player in the world", "ERR_UNAVAILABLE")
	var imp = Serial.vec3_from(args.impulse)
	if imp == null:
		return ctx.fail("impulse must be [x,y,z]", "ERR_INVALID")
	p.apply_external_impulse(imp)
	return {}


# ------------------------------------------------------------------ utility

func _achievements_suppress(_args: Dictionary, _ctx) -> Variant:
	var st = g("Steamworks")
	var n := 0
	for id in st._probe_ids:
		st._granted[id] = true
		n += 1
	_core.achievements_suppressed = true
	return {"suppressed": n}


func _perf_pin(args: Dictionary, ctx) -> Variant:
	var hz := int(args.get("hz", 60))
	if hz < 10 or hz > 240:
		return ctx.fail("hz must be 10..240", "ERR_INVALID")
	var pm = g("PerformanceMonitor")
	if pm != null:
		pm.set_process(false)
		pm.set_physics_process(false)
	Engine.physics_ticks_per_second = hz
	Engine.max_physics_steps_per_frame = MAX_PHYSICS_STEPS
	return {"hz": Engine.physics_ticks_per_second}


func _save_isolate(args: Dictionary, ctx) -> Variant:
	var sm = g("SaveManager")
	var enabled := bool(args.enabled)
	if not enabled:
		if args.has("path"):
			return ctx.fail("path is only valid with enabled=true", "ERR_INVALID")
		_core.set_save_isolation(false, "")
		return {"enabled": false, "path": String(sm.active_save_path)}
	# the prefix follows the PittAPI user root (user://pittapi-<name>/ with --pittapi-instance)
	var prefix := isolate_prefix()
	var p := String(args.get("path", prefix + DEFAULT_ISOLATED_SAVE.trim_prefix(TEST_SAVE_PREFIX)))
	if not p.begins_with(prefix) or p.contains("..") or not p.ends_with(".save"):
		return ctx.fail("path must be a .save file under %s" % prefix, "ERR_DENIED")
	if sm.has_method("slot_from_path") and int(sm.slot_from_path(p)) >= 0:
		return ctx.fail("path must not be a save slot", "ERR_DENIED")
	var fname := p.get_file().to_lower()
	if fname.begins_with("savegame") or fname.begins_with("sandbox"):
		return ctx.fail("path must not look like a save slot (savegame*/sandbox*)", "ERR_DENIED")
	_core.set_save_isolation(true, p)
	return {"enabled": true, "path": String(sm.active_save_path)}


## "user://pittapi/" normally; "user://pittapi-<name>/" for an editor instance
## started with --pittapi-instance=<name>.
func isolate_prefix() -> String:
	if _core != null and "user_root" in _core and String(_core.user_root) != "":
		return String(_core.user_root).trim_suffix("/") + "/"
	return TEST_SAVE_PREFIX


func _presence_suppress(args: Dictionary, _ctx) -> Variant:
	var st = g("Steamworks")
	var on := bool(args.enabled)
	_core.presence_suppressed = on
	if on:
		st._presence_accum = -1.0e9
		st.clear_presence()
	else:
		st._presence_accum = 0.0
	return {"suppressed": on}
