extends RefCounted
## PittCommands: the only mutation path. A command is a name plus a JSON-safe
## Dictionary of args. Execution always goes through the authority, so local and
## (future) remote execution look the same to callers: check result.done or
## await result.completed / execute_async().

const Serial = preload("serial.gd")

const CORE := "PittAPI"
const NAME_REGEX := "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+$"

const ERR_UNKNOWN := "ERR_UNKNOWN"
const ERR_INVALID := "ERR_INVALID"
const ERR_DENIED := "ERR_DENIED"
const ERR_UNAVAILABLE := "ERR_UNAVAILABLE"
const ERR_FAILED := "ERR_FAILED"

const SCOPE_AUTHORITY := "authority"
const SCOPE_LOCAL := "local"

var _core: Object = null
var _registry: Dictionary = {}
var _pending: Dictionary = {}
var _next_id := 1
var _name_re := RegEx.new()
var authority: Object = null


class PittCommandResult extends RefCounted:
	signal completed(result)
	var id: int = 0
	var name: String = ""
	var ok: bool = false
	var value: Variant = null
	var error: String = ""
	var code: String = ""
	var done: bool = false

	func _finish(p_ok: bool, p_value: Variant, p_error: String, p_code: String) -> void:
		if done:
			return
		ok = p_ok
		value = p_value
		error = p_error
		code = p_code
		done = true
		completed.emit(self)

	## Await-able helper: var r = await result.wait()
	func wait() -> RefCounted:
		if not done:
			await completed
		return self

	func to_dict() -> Dictionary:
		return {"id": id, "name": name, "ok": ok, "value": value, "error": error, "code": code, "done": done}

	func _to_string() -> String:
		return "PittCommandResult(%s ok=%s %s %s)" % [name, ok, code, error]


class PittCommandCtx extends RefCounted:
	var origin_peer: int = 1
	## The mod that issued the command. For remote envelopes this is only what the
	## sender claimed (is_remote = true): never use it for authorization.
	var mod_id: String = ""
	var is_remote: bool = false
	var is_replay: bool = false
	var cmd_id: int = 0
	var error: String = ""
	var code: String = ""

	## In a handler: return ctx.fail("reason")
	func fail(msg: String, p_code: String = "ERR_FAILED") -> Variant:
		error = msg
		code = p_code
		return null


func _init(core: Object = null, p_authority: Object = null) -> void:
	_core = core
	_name_re.compile(NAME_REGEX)
	set_authority(p_authority)


func set_authority(a: Object) -> void:
	authority = a
	if authority != null:
		authority.commands = self


## opts: {schema: {arg: TYPE_* | [TYPE_*...]} (suffix "?" = optional), cheat: bool,
##        authority_only: bool = true, replicate: "events"|"none", description: String,
##        feature: String (contract feature that must be available),
##        scope: "authority" (default) | "local"}
## scope "local": the command always runs on the machine that issues it (a
## multiplayer client never forwards it to the host) and is refused when it
## arrives from a remote sender. Used for per-machine utilities (save.isolate,
## achievements.suppress, player.teleport, ...).
## handler: func(args: Dictionary, ctx: PittCommandCtx) -> Variant (JSON-safe)
func register(name: String, handler: Callable, opts: Dictionary = {}, owner: String = CORE) -> Error:
	if _name_re.search(name) == null:
		_warn("command name '%s' is invalid (expected dotted name like 'mymod.do_thing')" % name)
		return ERR_INVALID_PARAMETER
	if owner != CORE and not (name.begins_with(owner + ".") or name.begins_with(owner.to_lower() + ".")):
		_warn("mod '%s' may only register '%s.*' commands (tried '%s')" % [owner, owner, name])
		return ERR_UNAUTHORIZED
	if _registry.has(name) and _registry[name].owner != owner:
		_warn("command '%s' is already registered by '%s'" % [name, _registry[name].owner])
		return ERR_ALREADY_EXISTS
	if not handler.is_valid():
		return ERR_INVALID_PARAMETER
	var schema = opts.get("schema", null)
	if schema != null and typeof(schema) != TYPE_DICTIONARY:
		return ERR_INVALID_PARAMETER
	var scope := String(opts.get("scope", SCOPE_AUTHORITY))
	if not (scope in [SCOPE_AUTHORITY, SCOPE_LOCAL]):
		_warn("command '%s': scope must be '%s' or '%s' (got '%s')" % [name, SCOPE_AUTHORITY, SCOPE_LOCAL, scope])
		return ERR_INVALID_PARAMETER
	_registry[name] = {
		"scope": scope,
		"name": name,
		"handler": handler,
		"owner": owner,
		"schema": schema,
		"cheat": bool(opts.get("cheat", false)),
		"authority_only": bool(opts.get("authority_only", true)),
		"replicate": String(opts.get("replicate", "events")),
		"description": String(opts.get("description", "")),
		"feature": String(opts.get("feature", "")),
		"internal": bool(opts.get("internal", false)),
		"remote": bool(opts.get("remote", false)),
	}
	return OK


func unregister(name: String) -> void:
	_registry.erase(name)


func unregister_owner(owner: String) -> int:
	var n := 0
	for name in _registry.keys():
		if _registry[name].owner == owner:
			_registry.erase(name)
			n += 1
	return n


func has(name: String) -> bool:
	return _registry.has(name)


func list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var names := _registry.keys()
	names.sort()
	for n in names:
		out.append(describe(n))
	return out


func describe(name: String) -> Dictionary:
	if not _registry.has(name):
		return {}
	var r: Dictionary = _registry[name]
	var schema := {}
	if r.schema != null:
		for k in r.schema:
			var t = r.schema[k]
			var names: Array = []
			for tt in (t if typeof(t) == TYPE_ARRAY else [t]):
				names.append(type_string(int(tt)))
			schema[k] = names
	return {"name": name, "owner": r.owner, "cheat": r.cheat, "authority_only": r.authority_only,
		"replicate": r.replicate, "description": r.description, "schema": schema, "feature": r.feature,
		"scope": r.scope, "internal": r.internal, "remote": r.remote}


func execute(name: String, args: Dictionary = {}, mod_id: String = CORE) -> RefCounted:
	var res := PittCommandResult.new()
	res.id = _next_id
	_next_id += 1
	res.name = name
	var reg = _registry.get(name, null)
	if reg == null:
		res._finish(false, null, "unknown command '%s'" % name, ERR_UNKNOWN)
		return res
	var err := Serial.check_json_safe(args)
	if err != "":
		res._finish(false, null, "args are not JSON-safe: " + err, ERR_INVALID)
		return res
	var clean = Serial.to_json_safe(args)
	# early local rejection; dispatch_envelope runs the same checks on the authority
	var adm := _admit(reg, clean)
	if not adm.is_empty():
		res._finish(false, null, adm.error, adm.code)
		return res
	var envelope := {
		"v": 1,
		"id": res.id,
		"name": name,
		"args": clean,
		"mod": mod_id,
		"origin": authority.local_peer_id() if authority != null else 1,
		"t": Time.get_ticks_msec(),
	}
	_pending[res.id] = res
	if authority == null:
		complete_envelope(envelope, dispatch_envelope(envelope))
	else:
		authority.submit(envelope)
	return res


## Coroutine: var r = await api.commands.execute_async("money.add", {"amount": 5})
func execute_async(name: String, args: Dictionary = {}, mod_id: String = CORE) -> RefCounted:
	var res: PittCommandResult = execute(name, args, mod_id)
	if not res.done:
		await res.completed
	return res


## Runs the handler for a LOCAL envelope (built by execute() on this machine).
## Returns a result dict. Remote envelopes must use dispatch_remote().
func dispatch_envelope(envelope: Dictionary, is_replay: bool = false) -> Dictionary:
	var origin := int(envelope.get("origin", 1))
	return _dispatch(envelope, is_replay, false, origin)


## Runs an envelope that arrived from another peer. sender_peer is the id the
## TRANSPORT reports (never envelope.origin); envelope.mod is kept only as an
## untrusted label (ctx.is_remote = true).
func dispatch_remote(envelope: Dictionary, sender_peer: int, is_replay: bool = false) -> Dictionary:
	if sender_peer <= 0:
		return {"ok": false, "value": null, "error": "invalid sender peer", "code": ERR_DENIED}
	return _dispatch(envelope, is_replay, true, sender_peer)


func _dispatch(envelope: Dictionary, is_replay: bool, remote: bool, origin: int) -> Dictionary:
	var name := String(envelope.get("name", ""))
	var reg = _registry.get(name, null)
	if reg == null:
		return {"ok": false, "value": null, "error": "unknown command '%s'" % name, "code": ERR_UNKNOWN}
	var raw = envelope.get("args", {})
	if typeof(raw) != TYPE_DICTIONARY:
		return {"ok": false, "value": null, "error": "args must be a Dictionary", "code": ERR_INVALID}
	# every gate runs again here: remote envelopes have not been through execute()
	var jerr := Serial.check_json_safe(raw)
	if jerr != "":
		return {"ok": false, "value": null, "error": "args are not JSON-safe: " + jerr, "code": ERR_INVALID}
	var args: Dictionary = Serial.to_json_safe(raw)
	var adm := _admit(reg, args)
	if not adm.is_empty():
		return {"ok": false, "value": null, "error": adm.error, "code": adm.code}
	var local_scope: bool = reg.scope == SCOPE_LOCAL
	if remote and local_scope:
		return {"ok": false, "value": null, "error": "'%s' runs only on the machine that issues it (scope local)" % name, "code": ERR_DENIED}
	if reg.authority_only and not local_scope and authority != null and not authority.is_authority():
		return {"ok": false, "value": null, "error": "'%s' runs only on the authority" % name, "code": ERR_DENIED}
	if remote and reg.internal:
		return {"ok": false, "value": null, "error": "'%s' is local-only" % name, "code": ERR_DENIED}
	var ctx := PittCommandCtx.new()
	ctx.origin_peer = origin
	ctx.is_remote = remote
	ctx.mod_id = String(envelope.get("mod", ""))
	ctx.cmd_id = int(envelope.get("id", 0))
	ctx.is_replay = is_replay
	var before := _error_count()
	var value = null
	if _core != null and _core.has_method("guard_call"):
		value = _core.guard_call(reg.owner, reg.handler, [args, ctx])
	else:
		value = reg.handler.call(args, ctx)
	var errored := _error_count() > before
	if ctx.error != "":
		return {"ok": false, "value": null, "error": ctx.error, "code": ctx.code if ctx.code != "" else ERR_FAILED}
	if value == null and errored:
		return {"ok": false, "value": null, "error": "command handler raised an error", "code": ERR_FAILED}
	if reg.cheat and not is_replay and _core != null and _core.has_method("on_cheat_used"):
		_core.on_cheat_used()
	var ents: Object = _core.entities if _core != null and "entities" in _core else null
	return {"ok": true, "value": Serial.to_json_safe(value, ents), "error": "", "code": ""}


## Called by the authority when an envelope has a result (now, or later for remote).
func complete_envelope(envelope: Dictionary, result: Dictionary) -> void:
	var id := int(envelope.get("id", 0))
	var res: PittCommandResult = _pending.get(id, null)
	_pending.erase(id)
	var ok := bool(result.get("ok", false))
	if res != null:
		res._finish(ok, result.get("value", null), String(result.get("error", "")), String(result.get("code", "")))
	var reg = _registry.get(String(envelope.get("name", "")), null)
	if _core != null and "events" in _core and _core.events != null and (reg == null or not reg.internal):
		_core.events.emit_internal("command.executed", {
			"id": id,
			"name": envelope.get("name", ""),
			"args": envelope.get("args", {}),
			"ok": ok,
			"error": result.get("error", ""),
			"code": result.get("code", ""),
			"origin": envelope.get("origin", 1),
			"mod": envelope.get("mod", ""),
		}, "api")


func pending_count() -> int:
	return _pending.size()


## Cheat, feature and schema gates shared by execute() and dispatch. {} = admitted,
## else {error, code}. Normalizes args in place (float -> int per schema).
func _admit(reg: Dictionary, args: Dictionary) -> Dictionary:
	var verr := _validate_schema(reg.schema, args)
	if verr != "":
		return {"error": verr, "code": ERR_INVALID}
	if reg.cheat and not _cheats_allowed():
		return {"error": "cheat commands are disabled (cheats_allowed=false)", "code": ERR_DENIED}
	if reg.feature != "" and _core != null and _core.has_method("feature_ok") and not _core.feature_ok(reg.feature):
		return {"error": "feature '%s' is unavailable (game contract check failed)" % reg.feature, "code": ERR_UNAVAILABLE}
	return {}


func _validate_schema(schema, args: Dictionary) -> String:
	if schema == null:
		return ""
	var allowed := {}
	for raw_key in schema:
		var key := String(raw_key)
		var optional := key.ends_with("?")
		var k := key.trim_suffix("?")
		allowed[k] = true
		var types: Array = schema[raw_key] if typeof(schema[raw_key]) == TYPE_ARRAY else [schema[raw_key]]
		if not args.has(k):
			if optional:
				continue
			return "missing required arg '%s'" % k
		var v = args[k]
		var ok := false
		for t in types:
			var ti := int(t)
			if typeof(v) == ti:
				ok = true
			elif ti == TYPE_INT and typeof(v) == TYPE_FLOAT and v == floor(v) and absf(v) < 9.0e15:
				args[k] = int(v)
				ok = true
			elif ti == TYPE_FLOAT and typeof(v) == TYPE_INT:
				ok = true
			elif ti == TYPE_NIL:
				ok = true
			if ok:
				break
		if not ok:
			var names: Array = []
			for t in types:
				names.append(type_string(int(t)))
			return "arg '%s' must be %s (got %s)" % [k, " or ".join(names), type_string(typeof(v))]
	for k in args:
		if not allowed.has(String(k)):
			return "unknown arg '%s'" % str(k)
	return ""


func _cheats_allowed() -> bool:
	if _core != null and _core.has_method("setting"):
		return bool(_core.setting("cheats_allowed", true))
	return true


func _error_count() -> int:
	if _core != null and "guard" in _core and _core.guard != null:
		return _core.guard.total_errors()
	return 0


func _warn(msg: String) -> void:
	if _core != null and "log" in _core and _core.log != null:
		_core.log.warn(msg)


## The per-mod view handed to mods as api.commands.
class Bound extends RefCounted:
	var _cmds = null
	var _mod := ""

	func _init(cmds, mod_id: String) -> void:
		_cmds = cmds
		_mod = mod_id

	func register(name: String, handler: Callable, opts: Dictionary = {}) -> Error:
		return _cmds.register(name, handler, opts, _mod)

	func unregister(name: String) -> void:
		if _cmds.describe(name).get("owner", "") == _mod:
			_cmds.unregister(name)

	func execute(name: String, args: Dictionary = {}) -> RefCounted:
		return _cmds.execute(name, args, _mod)

	func execute_async(name: String, args: Dictionary = {}) -> RefCounted:
		return await _cmds.execute_async(name, args, _mod)

	func list() -> Array[Dictionary]:
		return _cmds.list()

	func describe(name: String) -> Dictionary:
		return _cmds.describe(name)

	func has(name: String) -> bool:
		return _cmds.has(name)
