extends "lobby_service.gd"
## DevLobbyService: ENet localhost lobby for development and the two-instance
## tests (one Steam account cannot P2P to itself). No discovery: the Join list
## shows one row per config.dev_targets entry ("address:port" or
## {address, port, name}); lobby id = "dev:<address>:<port>". The member list
## comes from NET through set_external_members (the session roster).
##
## config: dev_address ("127.0.0.1"), dev_port (27450), dev_targets, dev_name.

const DEFAULT_ADDRESS := "127.0.0.1"
const DEFAULT_PORT := 27450

var _target: Dictionary = {}
var _local_name := ""


func kind() -> String:
	return "dev"


func _setup() -> void:
	var n := str(config.get("dev_name", ""))
	_local_name = n if n != "" else "Player %d" % (1 + OS.get_process_id() % 1000)


func get_local_name() -> String:
	return _local_name


func transport_target() -> Dictionary:
	return _target.duplicate() if is_in_lobby() else {}


func address() -> String:
	return str(config.get("dev_address", DEFAULT_ADDRESS))


func port() -> int:
	return int(config.get("dev_port", DEFAULT_PORT))


static func lobby_id_for(addr: String, p: int) -> String:
	return "dev:%s:%d" % [addr, p]


## "dev:<address>:<port>" -> {address, port}, or {} when malformed.
static func parse_id(id: String) -> Dictionary:
	if not id.begins_with("dev:"):
		return {}
	var rest := id.substr(4)
	var colon := rest.rfind(":")
	if colon <= 0:
		return {}
	var p := rest.substr(colon + 1)
	if not p.is_valid_int() or p.to_int() <= 0 or p.to_int() > 65535:
		return {}
	return {"address": rest.substr(0, colon), "port": p.to_int()}


func _targets() -> Array:
	var raw = config.get("dev_targets", null)
	var list: Array = []
	if typeof(raw) == TYPE_ARRAY:
		list = raw
	elif typeof(raw) == TYPE_STRING and str(raw) != "":
		list = Array(str(raw).split(",", false))
	if list.is_empty():
		list = ["%s:%d" % [DEFAULT_ADDRESS, DEFAULT_PORT]]
	var out: Array = []
	for t in list:
		var addr := ""
		var p := 0
		var label := ""
		if typeof(t) == TYPE_DICTIONARY:
			addr = str(t.get("address", DEFAULT_ADDRESS))
			p = int(t.get("port", DEFAULT_PORT))
			label = str(t.get("name", ""))
		else:
			var parsed := parse_id("dev:" + str(t).strip_edges())
			if parsed.is_empty():
				continue
			addr = parsed.address
			p = parsed.port
		out.append({"address": addr, "port": p, "name": label if label != "" else "%s:%d" % [addr, p]})
	return out


func _host(max_members: int) -> void:
	var id := lobby_id_for(address(), port())
	_target = Model.enet_target("host", address(), port())
	var info := Model.lobby_info({"id": id, "owner_id": "dev:host", "host_name": _local_name, "members": 1,
		"max": max_members, "state": "waiting"})
	for k in version:
		info[k] = version[k]
	info = Model.evaluate(info, version)
	info.is_owner = true
	_enter.call_deferred(info, [Model.member_info("dev:host", _local_name, true, true)])


func _join(lobby_id: String) -> void:
	var parsed := parse_id(lobby_id)
	if parsed.is_empty():
		_emit_error("MP_ERR_JOIN_FAILED", lobby_id)
		_drop.call_deferred("join_failed")
		return
	_target = Model.enet_target("client", parsed.address, parsed.port)
	var info := Model.lobby_info({"id": lobby_id, "owner_id": "dev:host", "host_name": "%s:%d" % [parsed.address, parsed.port],
		"members": 0, "max": MAX_MEMBERS, "state": "waiting"})
	for k in version:
		info[k] = version[k]
	info = Model.evaluate(info, version)
	info.joinable = true
	info.reason = ""
	info.is_owner = false
	_enter.call_deferred(info, [])


## Deferred enter: dropped if leave() ran in between.
func _enter(info: Dictionary, members: Array) -> void:
	if _pending == "" or is_in_lobby():
		return
	super(info, members)


func _leave() -> void:
	_target = {}


func _refresh() -> void:
	var rows: Dictionary = {}
	for t in _targets():
		var id := lobby_id_for(t.address, t.port)
		var row := Model.lobby_info({"id": id, "owner_id": "dev:host", "host_name": t.name, "members": 0,
			"max": MAX_MEMBERS, "state": "waiting"})
		for k in version:
			row[k] = version[k]
		row = Model.evaluate(row, version)
		row["dev"] = true
		rows[id] = row
	_set_rows(rows)


## NET pushes the session roster as [MemberInfo].
func set_external_members(list: Array) -> void:
	if not is_in_lobby():
		return
	var members: Array = []
	for m in list:
		if typeof(m) != TYPE_DICTIONARY:
			continue
		members.append(Model.member_info(m.get("id", ""), str(m.get("name", "")), bool(m.get("is_owner", false)),
			bool(m.get("is_self", false))))
	_set_members(members)
	for m in members:
		if m.is_owner and not is_owner():
			_current.host_name = m.name
	lobby_data_changed.emit(current())


func _write_state(_state: String) -> void:
	pass


## Client side: the host's lobby state arrives through the session; NET may
## mirror it here so the lobby screen shows it. Extra member.
func set_remote_state(state: String) -> void:
	if not is_in_lobby() or is_owner():
		return
	_current.state = Model.normalize_state(state)
	lobby_data_changed.emit(current())
