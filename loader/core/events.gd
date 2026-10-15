extends RefCounted
## PittEvents: the event bus. Every observation in the API is a PittEvent with a
## JSON-safe payload, so the same events can be forwarded to peers later.
## Subscriptions: exact names, "*" (everything) and "prefix.*".
## Dispatch: priority (high first), then subscription order. Every handler runs
## through the owner's guard, so one failing handler never stops the others.

const Serial = preload("serial.gd")

const CORE := "PittAPI"

var _core: Object = null
var _subs: Array = []
var _next_sub := 1
var _seq := 0
var _last: Dictionary = {}
var history: Array = []
var history_cap := 300
var strict_payloads := true

## Emitted after every event dispatch (used by the console tail and the tests).
signal emitted(ev)


class PittEvent extends RefCounted:
	var name: String = ""
	var payload: Dictionary = {}
	var seq: int = 0
	var t_ms: int = 0
	var origin: int = 1
	var source: String = "game"

	func to_dict() -> Dictionary:
		return {"name": name, "payload": payload.duplicate(true), "seq": seq, "t_ms": t_ms,
			"origin": origin, "source": source}

	func _to_string() -> String:
		return "PittEvent(%s #%d %s)" % [name, seq, JSON.stringify(payload)]


class _Waiter extends RefCounted:
	signal done
	var ev = null
	var fired := false

	func fire(e) -> void:
		if fired:
			return
		fired = true
		ev = e
		done.emit()

	func timeout() -> void:
		if fired:
			return
		fired = true
		ev = null
		done.emit()


func _init(core: Object = null) -> void:
	_core = core


## Subscribes handler(ev) to name. Returns a subscription id (> 0), or 0 on error.
func on(name: String, handler: Callable, priority: int = 0, owner: String = "") -> int:
	return _add(name, handler, priority, owner, false)


func once(name: String, handler: Callable, owner: String = "") -> int:
	return _add(name, handler, 0, owner, true)


func off(sub_id: int) -> void:
	for i in range(_subs.size() - 1, -1, -1):
		if _subs[i].id == sub_id:
			_subs[i].dead = true
			_subs.remove_at(i)
			return


## off() restricted to subscriptions of owner. True when one was removed.
func off_owned(sub_id: int, owner: String) -> bool:
	for i in range(_subs.size() - 1, -1, -1):
		if _subs[i].id == sub_id:
			if _subs[i].owner != owner:
				_warn("'%s' tried to remove subscription %d owned by '%s'" % [owner, sub_id, _subs[i].owner])
				return false
			_subs[i].dead = true
			_subs.remove_at(i)
			return true
	return false


func off_owner(owner: String) -> int:
	var n := 0
	for i in range(_subs.size() - 1, -1, -1):
		if _subs[i].owner == owner:
			_subs[i].dead = true
			_subs.remove_at(i)
			n += 1
	return n


func subscription_count(owner: String = "") -> int:
	if owner == "":
		return _subs.size()
	var n := 0
	for s in _subs:
		if s.owner == owner:
			n += 1
	return n


func _add(name: String, handler: Callable, priority: int, owner: String, is_once: bool) -> int:
	if name.is_empty() or not handler.is_valid():
		return 0
	var sub := {
		"id": _next_sub,
		"name": name,
		"all": name == "*",
		"prefix": name.substr(0, name.length() - 1) if name.ends_with(".*") else "",
		"priority": priority,
		"owner": owner,
		"handler": handler,
		"once": is_once,
		"dead": false,
	}
	_next_sub += 1
	# keep sorted: priority desc, then insertion order
	var idx := _subs.size()
	for i in _subs.size():
		if _subs[i].priority < priority:
			idx = i
			break
	_subs.insert(idx, sub)
	return sub.id


## Core/bridge/extension emit. source is "game", "api" or "mod:<id>".
func emit_internal(name: String, payload: Dictionary = {}, source: String = "game") -> RefCounted:
	var ev := PittEvent.new()
	_seq += 1
	ev.name = name
	ev.seq = _seq
	ev.t_ms = Time.get_ticks_msec()
	ev.origin = _local_peer()
	ev.source = source
	# L3: replicated state being applied (api.net.begin_apply/end_apply)
	var applying := _applying_origin()
	if applying > 0:
		ev.origin = applying
		ev.source = "net"
	var ents: Object = _core.entities if _core != null and "entities" in _core else null
	var safe = Serial.to_json_safe(payload, ents)
	ev.payload = safe if typeof(safe) == TYPE_DICTIONARY else {}
	_last[name] = ev
	history.append(ev)
	if history.size() > history_cap:
		history.remove_at(0)
	_dispatch(ev)
	emitted.emit(ev)
	return ev


## Emit on behalf of a mod. Only "mod.<mod_id>.*" names are allowed.
## Returns OK, ERR_UNAUTHORIZED (wrong namespace) or ERR_INVALID_DATA (payload).
func emit_from_mod(mod_id: String, name: String, payload: Dictionary = {}) -> Error:
	if not name.begins_with("mod.%s." % mod_id):
		_warn("mod '%s' may only emit 'mod.%s.*' events (tried '%s')" % [mod_id, mod_id, name])
		return ERR_UNAUTHORIZED
	var err := Serial.check_json_safe(payload)
	if err != "":
		_warn("mod '%s' emitted '%s' with a non JSON-safe payload: %s" % [mod_id, name, err])
		return ERR_INVALID_DATA
	emit_internal(name, payload, "mod:%s" % mod_id)
	return OK


## Unbound emit (global PittAPI.events.emit): allowed for "mod.*" names only.
func emit(name: String, payload: Dictionary = {}) -> Error:
	if not name.begins_with("mod."):
		return ERR_UNAUTHORIZED
	var err := Serial.check_json_safe(payload)
	if err != "":
		return ERR_INVALID_DATA
	emit_internal(name, payload, "api")
	return OK


func last(name: String) -> RefCounted:
	return _last.get(name, null)


## Await-able: var ev = await events.wait("world.ready", 30.0). Null on timeout.
func wait(name: String, timeout_s: float = 0.0) -> RefCounted:
	var w := _Waiter.new()
	var id := on(name, w.fire, 1000, CORE)
	if timeout_s > 0.0 and _core != null and _core is Node and _core.is_inside_tree():
		_core.get_tree().create_timer(timeout_s, true, false, true).timeout.connect(w.timeout)
	if not w.fired:
		await w.done
	off(id)
	return w.ev


func _dispatch(ev: PittEvent) -> void:
	var snapshot := _subs.duplicate()
	for sub in snapshot:
		if sub.dead:
			continue
		if not (sub.all or sub.name == ev.name or (sub.prefix != "" and ev.name.begins_with(sub.prefix))):
			continue
		if sub.once:
			off(sub.id)
		if not sub.handler.is_valid():
			off(sub.id)
			continue
		if _core != null and _core.has_method("guard_call"):
			_core.guard_call(sub.owner, sub.handler, [ev])
		else:
			sub.handler.call(ev)


func _applying_origin() -> int:
	if _core != null and "_net_apply_origin" in _core:
		return int(_core._net_apply_origin)
	return 0


func _local_peer() -> int:
	if _core != null and "authority" in _core and _core.authority != null:
		return _core.authority.local_peer_id()
	return 1


func _warn(msg: String) -> void:
	if _core != null and "log" in _core and _core.log != null:
		_core.log.warn(msg)


## The per-mod view handed to mods as api.events.
class Bound extends RefCounted:
	var _bus = null
	var _mod := ""

	func _init(bus, mod_id: String) -> void:
		_bus = bus
		_mod = mod_id

	func on(name: String, handler: Callable, priority: int = 0) -> int:
		return _bus.on(name, handler, priority, _mod)

	func once(name: String, handler: Callable) -> int:
		return _bus.once(name, handler, _mod)

	## Removes one of THIS mod's subscriptions (other owners' ids are ignored).
	func off(sub_id: int) -> bool:
		return _bus.off_owned(sub_id, _mod)

	func emit(name: String, payload: Dictionary = {}) -> Error:
		return _bus.emit_from_mod(_mod, name, payload)

	func last(name: String) -> RefCounted:
		return _bus.last(name)

	func wait(name: String, timeout_s: float = 0.0) -> RefCounted:
		return await _bus.wait(name, timeout_s)
