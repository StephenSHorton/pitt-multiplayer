extends RefCounted
## MpAuthority (MP-DESIGN 3.1): the PittAPI command authority during a session.
## Duck-typed to what Commands calls; installed with api.net.install_authority.
##
## Host: is the authority. Local envelopes dispatch locally, then the Session
## flushes pending state (econ) BEFORE the result completes (R20). Remote `cmd`
## envelopes are validated, cheat-gated, run with commands.dispatch_remote(env,
## sender) using the TRANSPORT's sender id, state is flushed, then `res` goes
## back on the same ordered channel.
## Client: scope "local" commands dispatch here; everything else goes to the
## host as `cmd` and completes when `res` arrives (10 s deadline, then
## ERR_UNAVAILABLE; the same when the session ends).

signal peers_changed()

const ERR_UNAVAILABLE := "ERR_UNAVAILABLE"
const ERR_DENIED := "ERR_DENIED"
const ERR_INVALID := "ERR_INVALID"
const COMMAND_TIMEOUT_MS := 10000

var commands: Object = null      # set by Commands.set_authority
var role := "host"               # "host" | "client"
var my_peer := 1
var allow_remote_cheats := false
var timeout_ms := COMMAND_TIMEOUT_MS
var _session: WeakRef = null
var _pending: Dictionary = {}    # cmd id -> {env, deadline}
var _peers: Array[int] = [1]
var remote_cheat_used := false


func _init(session: Object = null, p_role: String = "host", peer: int = 1) -> void:
	_session = weakref(session) if session != null else null
	role = p_role
	my_peer = peer


func _s() -> Object:
	return _session.get_ref() if _session != null else null


func get_kind() -> String:
	return "pitt_mp"


func is_authority() -> bool:
	return role == "host"


func local_peer_id() -> int:
	return my_peer


func get_peers() -> Array[int]:
	return _peers.duplicate()


func is_multiplayer() -> bool:
	return true


func set_peers(list: Array) -> void:
	var out: Array[int] = []
	for p in list:
		out.append(int(p))
	out.sort()
	if out != _peers:
		_peers = out
		peers_changed.emit()


func submit(envelope: Dictionary) -> void:
	if commands == null:
		return
	if role == "host":
		var result: Dictionary = commands.dispatch_envelope(envelope)
		var s := _s()
		if s != null and s.has_method("flush_state"):
			s.flush_state()
		complete(envelope, result)
		return
	var name := String(envelope.get("name", ""))
	var d: Dictionary = commands.describe(name)
	if d.is_empty() or String(d.get("scope", "authority")) == "local" or bool(d.get("internal", false)):
		# unknown -> the local dispatch reports ERR_UNKNOWN; local/internal never leave this machine
		complete(envelope, commands.dispatch_envelope(envelope))
		return
	var s := _s()
	if s == null or not s.has_method("send_cmd") or not s.send_cmd(envelope):
		complete(envelope, {"ok": false, "value": null, "error": "not connected to the host", "code": ERR_UNAVAILABLE})
		return
	_pending[int(envelope.get("id", 0))] = {"env": envelope, "deadline": Time.get_ticks_msec() + timeout_ms}


func complete(envelope: Dictionary, result: Dictionary) -> void:
	if commands != null:
		commands.complete_envelope(envelope, result)


## Client: a `res` arrived. Unknown / late ids are ignored.
func on_result(id: int, result: Dictionary) -> bool:
	if not _pending.has(id):
		return false
	var env: Dictionary = _pending[id].env
	_pending.erase(id)
	var r := {"ok": bool(result.get("ok", false)), "value": result.get("value", null),
		"error": String(result.get("error", "")), "code": String(result.get("code", ""))}
	complete(env, r)
	return true


func pending_count() -> int:
	return _pending.size()


## Client: expire pending commands (wall clock).
func tick(now_ms: int) -> void:
	if _pending.is_empty():
		return
	for id in _pending.keys():
		if now_ms >= int(_pending[id].deadline):
			var env: Dictionary = _pending[id].env
			_pending.erase(id)
			complete(env, {"ok": false, "value": null, "error": "the host did not answer in time", "code": ERR_UNAVAILABLE})


## Session ended: every pending command fails with ERR_UNAVAILABLE (R42).
func fail_all(reason: String = "session ended") -> void:
	var ids := _pending.keys()
	for id in ids:
		if not _pending.has(id):
			continue
		var env: Dictionary = _pending[id].env
		_pending.erase(id)
		complete(env, {"ok": false, "value": null, "error": reason, "code": ERR_UNAVAILABLE})


## Host: a client's `cmd`. Returns the result to send back as `res`.
## The envelope shape is validated; envelope.origin is ignored (the transport's
## sender id is used); only commands registered with remote = true run; cheat
## commands are refused unless allow_remote_cheats (R19).
func handle_remote(env: Variant, sender_peer: int) -> Dictionary:
	if role != "host" or commands == null:
		return {"ok": false, "value": null, "error": "not the host", "code": ERR_UNAVAILABLE}
	var shape := check_envelope(env)
	if shape != "":
		return {"ok": false, "value": null, "error": shape, "code": ERR_INVALID}
	var d: Dictionary = commands.describe(String(env.name))
	if not d.is_empty():
		var cheat := bool(d.get("cheat", false))
		if cheat and not allow_remote_cheats:
			return {"ok": false, "value": null, "error": "cheat commands from clients are refused by the host", "code": ERR_DENIED}
		# allowlist: only commands registered with remote = true (PittMultiplayer's
		# contribute / buy_*, or a mod that opts in) run for a client; money.*,
		# item.buy, entity.* and the rest stay host-only (R11, R19)
		if not bool(d.get("remote", false)) and not (cheat and allow_remote_cheats):
			return {"ok": false, "value": null, "error": "'%s' is not accepted from clients" % String(env.name), "code": ERR_DENIED}
	var result: Dictionary = commands.dispatch_remote(env, sender_peer)
	if bool(result.get("ok", false)) and bool(d.get("cheat", false)):
		remote_cheat_used = true
	return result


## "" when env looks like a PittAPI envelope {v,id,name,args,mod,origin,t}.
static func check_envelope(env: Variant) -> String:
	if typeof(env) != TYPE_DICTIONARY:
		return "envelope must be a Dictionary"
	if int(env.get("v", 0)) != 1:
		return "unsupported envelope version"
	if typeof(env.get("id", null)) != TYPE_INT or int(env.id) <= 0:
		return "envelope id must be a positive int"
	if typeof(env.get("name", null)) != TYPE_STRING or String(env.name).length() > 128:
		return "envelope name must be a String"
	if typeof(env.get("args", null)) != TYPE_DICTIONARY:
		return "envelope args must be a Dictionary"
	if env.has("mod") and typeof(env.mod) != TYPE_STRING:
		return "envelope mod must be a String"
	return ""
