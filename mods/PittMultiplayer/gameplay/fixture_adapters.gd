extends RefCounted
## GAMEPLAY meta adapters for static fixtures (MP2-DESIGN 3.5, 4.4, 4.6),
## registered with bodies.register_meta. The host reads a small JSON-safe
## dictionary per fixture; clients apply it in apply scope with the game's own
## setters and replays. apply() always sees the merged state (previous fields +
## the changed ones) and the previous merged state, so rising/falling edges are
## detected against what was last applied, not against local game state (a
## client's local copy may finish an animation on its own).
##
## Kinds: gp_bench_manual, gp_bench_auto, gp_cauldron, gp_terminal, gp_block,
## gp_erasable, gp_camera, gp_gate, gp_shutters, gp_generator, gp_plate,
## gp_keypad, gp_loop, gp_bowling.

const SCRIPTS_DIR := "res://scripts/"
const PIN_KEY := "bowling:pin:%d:%d"

var gp = null


func _init(p_gp) -> void:
	gp = p_gp


## True when node runs res://scripts/<name>.gd (directly, through our extension,
## or as a subclass of it).
static func is_script(node: Object, names: Array) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	var s: Script = node.get_script()
	while s != null:
		var p := s.resource_path
		if p.begins_with(SCRIPTS_DIR) and p.get_file().get_basename() in names:
			return true
		s = s.get_base_script()
	return false


func reg(kind: String, names: Array, read: Callable, apply: Callable, hz: float = 4.0) -> void:
	var b = gp.get_bodies()
	if b == null or not b.has_method("register_meta"):
		return
	var matcher := func(n) -> bool: return is_script(n, names)
	var ap := func(n, d: Dictionary) -> void: apply_merged(kind, n, d, apply)
	b.register_meta(kind, matcher, read, ap, hz)


static func apply_merged(kind: String, n: Object, d: Dictionary, apply: Callable) -> void:
	if n == null or not is_instance_valid(n):
		return
	var key := "pitt_mp_gp_" + kind
	var prev: Dictionary = n.get_meta(key, {})
	var merged := prev.duplicate()
	merged.merge(d, true)
	n.set_meta(key, merged)
	apply.call(n, merged, prev)


static func _edge(cur: Dictionary, prev: Dictionary, k: String) -> int:
	var now := bool(cur.get(k, false))
	var was := bool(prev.get(k, false))
	if now and not was:
		return 1
	if was and not now:
		return -1
	return 0


func register_all() -> void:
	reg("gp_bench_manual", ["workbench", "manual_cash_workbench", "manual_pinata_workbench"],
		read_bench, apply_bench_manual, 10.0)
	reg("gp_bench_auto", ["automatic_duck_workbench", "automatic_cash_workbench", "automatic_pinata_workbench"],
		read_bench, apply_bench_auto, 10.0)
	reg("gp_cauldron", ["anomaly_workbench"], read_cauldron, apply_cauldron, 4.0)
	reg("gp_terminal", ["gambling_terminal"], read_terminal, apply_terminal, 10.0)
	reg("gp_block", ["minable_block"], read_block, apply_block, 4.0)
	reg("gp_erasable", ["erasable_text"], read_erasable, apply_erasable, 1.0)
	reg("gp_camera", ["camera_pivot"], read_camera, apply_camera, 2.0)
	reg("gp_gate", ["vertical_gate"], read_gate, apply_gate, 1.0)
	reg("gp_shutters", ["gate_shutters"], read_shutters, apply_shutters, 1.0)
	reg("gp_generator", ["gate_power_generator"], read_generator, apply_generator, 2.0)
	reg("gp_plate", ["gate_weight_plate"], read_plate, apply_plate, 4.0)
	reg("gp_keypad", ["security_keypad"], read_keypad, apply_keypad, 4.0)
	reg("gp_loop", ["loop_puzzle"], read_loop, apply_loop, 1.0)
	reg("gp_bowling", ["bowling_pin_set"], read_bowling, apply_bowling, 2.0)


# ------------------------------------------------------------------ benches (4.4)

static func read_bench(n: Object) -> Dictionary:
	var d := {"c": bool(n.get("is_crafting")), "p": snappedf(float(n.get("craft_progress")), 0.05)}
	if "is_turned_on" in n:
		d["on"] = bool(n.get("is_turned_on"))
	return d


static func apply_bench_manual(n: Object, cur: Dictionary, prev: Dictionary) -> void:
	match _edge(cur, prev, "c"):
		1:
			if n.has_method("start_crafting"):
				n.start_crafting()
		-1:
			if n.has_method("stop_crafting"):
				n.stop_crafting()
	_correct_progress(n, cur)


static func apply_bench_auto(n: Object, cur: Dictionary, prev: Dictionary) -> void:
	match _edge(cur, prev, "on"):
		1:
			if n.has_method("turn_on"):
				n.turn_on()
		-1:
			if n.has_method("turn_off"):
				n.turn_off()
	match _edge(cur, prev, "c"):
		1:
			if n.has_method("start_crafting") and not bool(n.get("is_crafting")):
				n.start_crafting()
		-1:
			if n.has_method("stop_crafting") and bool(n.get("is_crafting")):
				n.stop_crafting()
	_correct_progress(n, cur)


static func _correct_progress(n: Object, cur: Dictionary) -> void:
	if bool(cur.get("c", false)) and bool(n.get("is_crafting")):
		var p := float(cur.get("p", 0.0))
		if absf(float(n.get("craft_progress")) - p) > 0.25:
			n.set("craft_progress", p)


# ------------------------------------------------------------------ cauldron

static func read_cauldron(n: Object) -> Dictionary:
	return {"d": int(n.get("duck_count")), "cr": int(n.get("crown_count")), "b": int(n.get("bear_count")),
		"r": bool(n.get("is_ritualizing")), "mp": int(n.get("min_purity")), "c": bool(n.get("is_crafting"))}


static func apply_cauldron(n: Object, cur: Dictionary, prev: Dictionary) -> void:
	n.set("duck_count", int(cur.get("d", 0)))
	n.set("crown_count", int(cur.get("cr", 0)))
	n.set("bear_count", int(cur.get("b", 0)))
	n.set("min_purity", int(cur.get("mp", n.get("min_purity"))))
	if n.has_method("_update_indicator"):
		n._update_indicator()
	match _edge(cur, prev, "r"):
		1:
			n.set("is_ritualizing", true)
			n.set("ritual_elapsed", 0.0)
			if n.has_method("_reveal_black_sphere"):
				n._reveal_black_sphere()
			# the ritual's bar is the operator's (the host shows its own in _start_ritual)
			if n.has_method("show_progress_bar"):
				n.show_progress_bar(true)
				n.update_progress_bar(0.0)
		-1:
			n.set("is_ritualizing", false)
			if n.has_method("_collapse_black_sphere"):
				n._collapse_black_sphere()
			if n.has_method("show_progress_bar"):
				n.show_progress_bar(false)


# ------------------------------------------------------------------ trading terminal

static func read_terminal(n: Object) -> Dictionary:
	return {"r": bool(n.get("_rolling")), "rem": snappedf(float(n.get("_remaining")), 0.01)}


static func apply_terminal(n: Object, cur: Dictionary, prev: Dictionary) -> void:
	var e := _edge(cur, prev, "r")
	n.set("_rolling", bool(cur.get("r", false)))
	if bool(cur.get("r", false)):
		var rem := float(cur.get("rem", 0.0))
		if e == 1 or absf(float(n.get("_remaining")) - rem) > 0.15:
			n.set("_remaining", rem)
		if e == 1 and n.has_method("_reset_roll_labels"):
			n._reset_roll_labels()
	if e != 0 and n.has_method("_update_button_label"):
		n._update_button_label()


# ------------------------------------------------------------------ mining blocks, erasable texts, cameras

static func read_block(n: Object) -> Dictionary:
	return {"dmg": snappedf(float(n.get("damage")), 0.1), "br": bool(n.get("broken"))}


static func apply_block(n: Object, cur: Dictionary, _prev: Dictionary) -> void:
	if bool(cur.get("br", false)):
		if not bool(n.get("broken")) and n.has_method("apply_saved_state"):
			n.apply_saved_state(true)
		return
	n.set("damage", float(cur.get("dmg", 0.0)))
	if n.has_method("_update_crack_visuals"):
		n._update_crack_visuals()


static func read_erasable(n: Object) -> Dictionary:
	return {"e": bool(n.get("_fully_erased"))}


static func apply_erasable(n: Object, cur: Dictionary, _prev: Dictionary) -> void:
	if bool(cur.get("e", false)) and not bool(n.get("_fully_erased")) and n.has_method("_apply_fully_erased"):
		n._apply_fully_erased()


static func read_camera(n: Object) -> Dictionary:
	return {"d": bool(n.get("is_destroyed"))}


static func apply_camera(n: Object, cur: Dictionary, _prev: Dictionary) -> void:
	if bool(cur.get("d", false)) and not bool(n.get("is_destroyed")) and n.has_method("apply_saved_state"):
		n.apply_saved_state(true)


# ------------------------------------------------------------------ gates and puzzles (4.6)

static func read_gate(n: Object) -> Dictionary:
	return {"s": bool(n.get("is_solved"))}


static func apply_gate(n: Object, cur: Dictionary, _prev: Dictionary) -> void:
	if bool(cur.get("s", false)) and not bool(n.get("is_solved")) and n.has_method("solve"):
		n.solve()


static func read_shutters(n: Object) -> Dictionary:
	var m = n.get("_slot_fuse_map")
	var out := {}
	if typeof(m) == TYPE_DICTIONARY:
		for k in m:
			out[str(k)] = String(m[k])
	return {"m": out}


static func apply_shutters(n: Object, cur: Dictionary, prev: Dictionary) -> void:
	if cur.get("m", {}) == prev.get("m", null):
		return
	if n.has_method("apply_shutters_saved_state"):
		n.apply_shutters_saved_state({"slot_fuse_map": cur.get("m", {})})


static func read_generator(n: Object) -> Dictionary:
	return {"v": snappedf(float(n.get("accumulated_value")), 0.01), "a": bool(n.get("_activated"))}


static func apply_generator(n: Object, cur: Dictionary, _prev: Dictionary) -> void:
	if n.has_method("apply_generator_saved_state"):
		n.apply_generator_saved_state({"accumulated_value": float(cur.get("v", 0.0)), "activated": bool(cur.get("a", false))})


static func read_plate(n: Object) -> Dictionary:
	return {"m": snappedf(float(n.get("current_mass")), 0.1), "a": bool(n.get("_activated"))}


static func apply_plate(n: Object, cur: Dictionary, _prev: Dictionary) -> void:
	n.set("current_mass", float(cur.get("m", 0.0)))
	if bool(cur.get("a", false)):
		n.set("_activated", true)
	if n.has_method("_update_gauge"):
		n._update_gauge()


static func read_keypad(n: Object) -> Dictionary:
	return {"e": String(n.get("entry"))}


static func apply_keypad(n: Object, cur: Dictionary, _prev: Dictionary) -> void:
	n.set("entry", String(cur.get("e", "")))
	if n.has_method("_refresh_label"):
		n._refresh_label()


## loop_puzzle.get_save_state() split so the (large) best path is only re-applied
## when it changed: energy/levels refresh the labels, best/solved go through
## apply_save_state (which restarts the clone train).
static func read_loop(n: Object) -> Dictionary:
	if not n.has_method("get_save_state"):
		return {}
	var s: Dictionary = n.get_save_state()
	return {"en": snappedf(float(s.get("energy", 0.0)), 0.1), "cc": int(s.get("clone_count", 0)),
		"sl": int(s.get("speed_level", 0)), "el": int(s.get("energy_level", 0)),
		"bt": float(s.get("best_time", -1.0)), "bp": s.get("best_path", []), "so": bool(s.get("is_solved", false))}


static func apply_loop(n: Object, cur: Dictionary, prev: Dictionary) -> void:
	var full: bool = prev.is_empty() or cur.get("bt") != prev.get("bt") or cur.get("so") != prev.get("so") \
		or cur.get("cc") != prev.get("cc") or cur.get("sl") != prev.get("sl")
	if full and n.has_method("apply_save_state"):
		n.apply_save_state({"energy": float(cur.get("en", 0.0)), "clone_count": int(cur.get("cc", 0)),
			"speed_level": int(cur.get("sl", 0)), "energy_level": int(cur.get("el", 0)),
			"best_time": float(cur.get("bt", -1.0)), "best_path": cur.get("bp", []),
			"is_solved": bool(cur.get("so", false))})
		return
	n.set("energy", float(cur.get("en", 0.0)))
	n.set("energy_level", int(cur.get("el", 0)))
	if n.has_method("_refresh_labels"):
		n._refresh_labels()


# ------------------------------------------------------------------ bowling (pins are fixture bodies)

static func read_bowling(n: Object) -> Dictionary:
	return {"g": int(n.get_meta("pitt_mp_pin_gen", 0))}


func apply_bowling(n: Object, cur: Dictionary, prev: Dictionary) -> void:
	var g := int(cur.get("g", 0))
	if g <= 0 or g == int(prev.get("g", 0)) and int(n.get_meta("pitt_mp_pin_gen", 0)) == g:
		return
	n.set_meta("pitt_mp_pin_gen_next", g)
	if n.has_method("_spawn_pins"):
		n._spawn_pins()


## Host after _spawn_pins: a new generation of pin keys. Client (apply scope):
## the generation the host announced. Old keys are unregistered first.
func pins_spawned(set_node: Object) -> void:
	var b = gp.get_bodies()
	if b == null or set_node == null:
		return
	pins_despawned(set_node)
	var gen := 0
	if gp.role == "host":
		gen = int(set_node.get_meta("pitt_mp_pin_gen", 0)) + 1
	else:
		gen = int(set_node.get_meta("pitt_mp_pin_gen_next", 0))
		if gen <= 0:
			return
	set_node.set_meta("pitt_mp_pin_gen", gen)
	var keys: Array = []
	var pins = set_node.get("_pins")
	if typeof(pins) == TYPE_ARRAY:
		for i in pins.size():
			var pin = pins[i]
			if pin != null and is_instance_valid(pin):
				var key := PIN_KEY % [gen, i]
				b.register_fixture(key, pin)
				keys.append(key)
	set_node.set_meta("pitt_mp_pin_keys", keys)
	if gp.role == "host":
		gp.host_after(set_node)


func pins_despawned(set_node: Object) -> void:
	var b = gp.get_bodies()
	if b == null or set_node == null:
		return
	for key in set_node.get_meta("pitt_mp_pin_keys", []):
		b.unregister_fixture(String(key))
	set_node.set_meta("pitt_mp_pin_keys", [])
