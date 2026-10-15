extends RefCounted
## PittConsole: optional dev console (enabled with dev_console=true in
## user://pittapi/config/pittapi.cfg). run() also works without the panel.

var _core: Object = null
var _mod := ""


func _init(core: Object, mod_id: String) -> void:
	_core = core
	_mod = mod_id


## handler(args: PackedStringArray) -> String
func register(name: String, handler: Callable, help: String = "") -> Error:
	return _core.console_registry.register(name, handler, help, _mod)


func run(line: String) -> String:
	return _core.console_registry.run(line)


class Registry extends RefCounted:
	const Serial = preload("../core/serial.gd")
	var _core: Object = null
	var _cmds: Dictionary = {}   # name -> {handler, help, owner}
	var _builtins: Array = ["help", "mods", "cmd", "events", "state", "spawn", "money", "phase", "ents", "log"]
	var tail_filter := ""
	var tail_enabled := false

	func _init(core: Object) -> void:
		_core = core

	func register(name: String, handler: Callable, help: String, owner: String) -> Error:
		if name in _builtins:
			return ERR_ALREADY_EXISTS
		if _cmds.has(name) and _cmds[name].owner != owner:
			return ERR_ALREADY_EXISTS
		if not handler.is_valid() or name.is_empty() or name.contains(" "):
			return ERR_INVALID_PARAMETER
		_cmds[name] = {"handler": handler, "help": help, "owner": owner}
		return OK

	func remove_owner(owner: String) -> void:
		for n in _cmds.keys():
			if _cmds[n].owner == owner:
				_cmds.erase(n)

	func names() -> Array:
		var out: Array = _builtins.duplicate()
		out.append_array(_cmds.keys())
		return out

	func run(line: String) -> String:
		line = line.strip_edges()
		if line.is_empty():
			return ""
		var sp := line.find(" ")
		var name := line if sp < 0 else line.substr(0, sp)
		var rest := "" if sp < 0 else line.substr(sp + 1).strip_edges()
		var args := rest.split(" ", false)
		match name:
			"help": return _help()
			"mods": return _mods()
			"cmd": return _cmd(rest)
			"events": return _events(rest)
			"state": return JSON.stringify(_core.state.snapshot(), "  ")
			"spawn": return _spawn(args)
			"money": return _money(args)
			"phase": return _phase(args)
			"ents": return _ents(args)
			"log": return "\n".join(_core.log_sink.tail(int(args[0]) if args.size() > 0 and args[0].is_valid_int() else 20))
		if _cmds.has(name):
			var c: Dictionary = _cmds[name]
			var r = _core.guard_call(c.owner, c.handler, [args])
			return str(r) if r != null else ""
		return "unknown command '%s' (try help)" % name

	func _help() -> String:
		var lines: Array = [
			"help                     this list",
			"mods                     mod states",
			"cmd <name> <json>        run any API command, e.g. cmd money.add {\"amount\":100}",
			"events [filter|off]      live tail of events (prefix filter, e.g. money.)",
			"state                    state snapshot",
			"spawn <pool> [n]         spawn at the look point",
			"money <add|set> <n>      change money",
			"phase <n>                set the phase (cheat)",
			"ents [pool]              tracked entities",
			"log [n]                  last n log lines",
		]
		for n in _cmds:
			lines.append("%-24s %s (%s)" % [n, _cmds[n].help, _cmds[n].owner])
		return "\n".join(lines)

	func _mods() -> String:
		var lines: Array = []
		for s in _core.loader.status():
			lines.append("%-24s %-8s %-12s %s" % [s.id, s.version, s.state, s.reason])
		return "\n".join(lines)

	func _cmd(rest: String) -> String:
		var sp := rest.find(" ")
		var name := rest if sp < 0 else rest.substr(0, sp)
		var json_text := "{}" if sp < 0 else rest.substr(sp + 1)
		var j := JSON.new()
		if j.parse(json_text) != OK or typeof(j.data) != TYPE_DICTIONARY:
			return "args must be a JSON object"
		var r = _core.commands.execute(name, j.data, "console")
		if not r.done:
			return "submitted #%d (pending)" % r.id
		return JSON.stringify(r.to_dict())

	func _events(rest: String) -> String:
		if rest == "off":
			tail_enabled = false
			return "event tail off"
		tail_enabled = true
		tail_filter = rest
		var lines: Array = []
		for ev in _core.events.history.slice(maxi(0, _core.events.history.size() - 15)):
			if tail_filter == "" or ev.name.begins_with(tail_filter):
				lines.append("#%d %s %s" % [ev.seq, ev.name, JSON.stringify(ev.payload)])
		lines.append("(event tail on%s; 'events off' to stop)" % ((" for " + tail_filter) if tail_filter != "" else ""))
		return "\n".join(lines)

	func _spawn(args: PackedStringArray) -> String:
		if args.is_empty():
			return "usage: spawn <pool> [n]"
		var n := clampi(int(args[1]) if args.size() > 1 and args[1].is_valid_int() else 1, 1, 100)
		var at: Vector3 = _core.player.get_look_point(3.0) if _core.player.get_local() != null else Vector3(0, 5, 0)
		var ids: Array = []
		for i in n:
			var r = _core.spawn.spawn(args[0], at + Vector3(0, 0.3 * i, 0))
			if not r.ok:
				return "spawn failed: %s %s" % [r.code, r.error]
			ids.append(r.value.entity_id)
		return "spawned %s" % str(ids)

	func _money(args: PackedStringArray) -> String:
		if args.size() < 2 or not (args[0] in ["add", "set"]):
			return "usage: money <add|set> <n>"
		var r = _core.commands.execute("money.%s" % args[0], {"amount": args[1]}, "console")
		return "money = %s" % _core.state.get_money() if r.ok else "failed: %s" % r.error

	func _phase(args: PackedStringArray) -> String:
		if args.is_empty() or not args[0].is_valid_int():
			return "phase = %d (%s)" % [_core.state.get_phase(), _core.state.get_phase_name()]
		var r = _core.commands.execute("phase.set", {"phase": int(args[0])}, "console")
		return "phase -> %s" % args[0] if r.ok else "failed: %s" % r.error

	func _ents(args: PackedStringArray) -> String:
		var filter := {}
		if args.size() > 0:
			filter["pool_id"] = args[0]
		var ids: Array = _core.entities.list(filter)
		var lines: Array = ["%d entities" % ids.size()]
		for id in ids.slice(0, 40):
			var d: Dictionary = _core.entities.describe(id)
			lines.append("%d %s %s %s" % [id, d.get("kind", ""), d.get("pool_id", d.get("key", "")), str(Serial.to_json_safe(d.get("position", null)))])
		return "\n".join(lines)
