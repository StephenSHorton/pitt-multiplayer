extends RefCounted
## PittState: reads are direct; every change goes through a command.

const Serial = preload("../core/serial.gd")

const PHASE_NAMES := ["elevator", "duck", "crown", "bear", "effigy", "ending"]

var _core: Object = null
var _mod := ""


func _init(core: Object, mod_id: String) -> void:
	_core = core
	_mod = mod_id


func _gs() -> Object:
	return _core.g("GameState") if _core.feature_ok("economy") else null


func get_money() -> String:
	var gs = _gs()
	return Serial.to_digits(gs.money) if gs != null else "0"


func get_money_float() -> float:
	var gs = _gs()
	return float(gs.money.to_float()) if gs != null else 0.0


## -1 / 0 / 1 comparing current money with amount (int or digit string).
func money_compare(amount: Variant) -> int:
	var d := Serial.to_digits(amount)
	if d == "":
		return 1
	return Serial.digits_compare(get_money(), d)


func can_afford(amount: Variant) -> bool:
	var d := Serial.to_digits(amount)
	return d != "" and Serial.digits_compare(get_money(), d) >= 0


func add_money(amount: Variant, reason: String = "add") -> RefCounted:
	return _core.commands.execute("money.add", {"amount": _amount_arg(amount), "reason": reason}, _mod)


func spend(amount: Variant) -> RefCounted:
	return _core.commands.execute("money.spend", {"amount": _amount_arg(amount)}, _mod)


func set_money(amount: Variant) -> RefCounted:
	return _core.commands.execute("money.set", {"amount": _amount_arg(amount)}, _mod)


func set_bank(amount: float) -> RefCounted:
	return _core.commands.execute("bank.set", {"amount": amount}, _mod)


func buy(category: String, key: String, subkey: String = "") -> RefCounted:
	var args := {"category": category, "key": key}
	if subkey != "":
		args["subkey"] = subkey
	return _core.commands.execute("item.buy", args, _mod)


func get_bank() -> float:
	var gs = _core.g("GameState") if _core.feature_ok("bank") else null
	return float(gs.bank) if gs != null else 0.0


func get_phase() -> int:
	var gp = _core.g("GameProgression") if _core.feature_ok("phase") else null
	return int(gp.current_phase) if gp != null else -1


func get_phase_name(p: int = -1) -> String:
	if p < 0:
		p = get_phase()
	return PHASE_NAMES[p] if p >= 0 and p < PHASE_NAMES.size() else ""


## Hole progress toward the next phase 0..1, or -1 outside the world.
func get_phase_progress() -> float:
	if not is_in_world() or not _core.feature_ok("hole"):
		return -1.0
	var hole = _core.get_tree().get_first_node_in_group("saveable_hole")
	if hole == null or not hole.has_method("get_phase_progress"):
		return -1.0
	return float(hole.get_phase_progress())


func set_phase(p: int, allow_ending: bool = false) -> RefCounted:
	return _core.commands.execute("phase.set", {"phase": p, "allow_ending": allow_ending}, _mod)


func is_in_world() -> bool:
	return _core.bridge.in_world


func is_sandbox() -> bool:
	var gs = _core.g("GameState") if _core.feature_ok("session") else null
	return gs != null and bool(gs.sandbox_mode)


func is_unlocked(milestone_id: String) -> bool:
	var um = _core.g("UnlockManager") if _core.feature_ok("unlocks") else null
	return um != null and bool(um.is_unlocked(milestone_id))


func get_unlocked() -> Array[String]:
	var out: Array[String] = []
	var um = _core.g("UnlockManager") if _core.feature_ok("unlocks") else null
	if um != null:
		for id in um.unlocked_milestones:
			out.append(String(id))
	return out


func force_unlock(milestone_id: String) -> RefCounted:
	return _core.commands.execute("unlock.force", {"id": milestone_id}, _mod)


## Registers mod.<mod>.<name>. Call in _mod_init (before the first world load).
func register_milestone(name: String, def: Dictionary) -> RefCounted:
	return _core.commands.execute("unlock.register_milestone", {"id": name, "def": def}, _mod)


## Deep copy of a GameState item dict, JSON-safe ({} if unknown).
func get_item(category: String, key: String) -> Dictionary:
	var gs = _core.g("GameState") if _core.feature_ok("items") else null
	if gs == null or not (category in ["upgrades", "tools", "toys", "products", "combos"]):
		return {}
	var table = gs.get(category)
	if typeof(table) != TYPE_DICTIONARY or not table.has(key):
		return {}
	var safe = Serial.to_json_safe(table[key].duplicate(true))
	return safe if typeof(safe) == TYPE_DICTIONARY else {}


func get_item_keys(category: String) -> Array:
	var gs = _core.g("GameState") if _core.feature_ok("items") else null
	if gs == null:
		return []
	var table = gs.get(category)
	return table.keys() if typeof(table) == TYPE_DICTIONARY else []


## Same paths as UnlockManager._get_stat ("products_consumed.duck").
func get_stat(path: String) -> Variant:
	var gs = _core.g("GameState")
	if gs == null:
		return null
	var parts := path.split(".")
	if parts.is_empty() or not (parts[0] in gs):
		return null
	var v = gs.get(parts[0])
	for key in parts.slice(1):
		if not (v is Dictionary and v.has(key)):
			return null
		v = v[key]
	return Serial.to_json_safe(v)


## JSON-safe summary; later the late-join seed for multiplayer.
func snapshot() -> Dictionary:
	var items := {}
	for cat in ["upgrades", "tools", "toys", "combos"]:
		var c := {}
		for key in get_item_keys(cat):
			var it := get_item(cat, key)
			c[key] = {"level": it.get("level", 0), "enabled": it.get("enabled", false)}
		items[cat] = c
	var prods := {}
	for key in get_item_keys("products"):
		var it := get_item("products", key)
		var p := {"enabled": it.get("enabled", false)}
		for sub in it:
			if typeof(it[sub]) == TYPE_DICTIONARY and it[sub].has("level"):
				p[sub] = {"level": it[sub].level, "enabled": it[sub].get("enabled", false)}
		prods[key] = p
	items["products"] = prods
	return {
		"api_version": _core.api_version,
		"money": get_money(),
		"bank": get_bank(),
		"phase": get_phase(),
		"in_world": is_in_world(),
		"sandbox": is_sandbox(),
		"unlocked": get_unlocked(),
		"items": items,
	}


## int | String | BigInt -> a new BigInt (always a copy), or null.
func bigint_from(v: Variant) -> Object:
	var d := Serial.to_digits(v)
	if d == "":
		return null
	var gs = _core.g("GameState")
	if gs == null or not Serial.is_bigint(gs.money):
		return null
	return gs.money.get_script().from_string(d)


func _amount_arg(amount: Variant) -> Variant:
	if Serial.is_bigint(amount):
		return amount.to_plain_string()
	return amount
