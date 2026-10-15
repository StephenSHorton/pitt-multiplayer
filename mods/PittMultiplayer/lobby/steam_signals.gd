extends RefCounted
## GodotSteam signal adapters. Every Steam signal is connected through a lambda
## with defaulted parameters, so a GodotSteam build that emits fewer (or more,
## up to 6) arguments than expected still reaches the handler. The handler gets
## the signal name and the raw argument array: handler.call(name, [args...]).
##
## Arities checked in the decomp instance (GodotSteam bundled with v1.0.8):
##   lobby_created(connect, lobby_id)
##   lobby_joined(lobby, permissions, locked, response)
##   lobby_chat_update(lobby_id, changed_id, making_change_id, chat_state)
##   lobby_data_update(success, lobby_id, member_id)
##   persona_state_change(steam_id, flags)
##   join_requested(lobby_id, steam_id)
##   join_game_requested(steam_id, connect)   "Join Game" while running (rich presence)

const LaunchArgs = preload("launch_args.gd")

const SIGNALS := {
	"lobby_created": 2,
	"lobby_joined": 4,
	"lobby_chat_update": 4,
	"lobby_data_update": 3,
	"persona_state_change": 2,
	"join_requested": 2,
	"join_game_requested": 2,
}

const _NONE := "__pittmp_none__"

var _steam: Object = null
var _conns: Array = []   # [[signal, callable]]


## Connects every known signal present on steam. Returns the number connected.
func connect_all(steam: Object, handler: Callable) -> int:
	disconnect_all()
	_steam = steam
	if steam == null:
		return 0
	for sig in SIGNALS:
		if not steam.has_signal(sig):
			continue
		var cb := _adapter(sig, handler)
		if steam.connect(sig, cb) == OK:
			_conns.append([sig, cb])
	return _conns.size()


func disconnect_all() -> void:
	if _steam != null and is_instance_valid(_steam):
		for c in _conns:
			if _steam.is_connected(c[0], c[1]):
				_steam.disconnect(c[0], c[1])
	_conns.clear()
	_steam = null


func connected_count() -> int:
	return _conns.size()


## Real arity of a signal on this build (-1 if missing). For diagnostics.
static func arity(steam: Object, sig: String) -> int:
	if steam == null:
		return -1
	for s in steam.get_signal_list():
		if s.get("name", "") == sig:
			return s.get("args", []).size()
	return -1


static func _adapter(sig: String, handler: Callable) -> Callable:
	return func(a0 = _NONE, a1 = _NONE, a2 = _NONE, a3 = _NONE, a4 = _NONE, a5 = _NONE) -> void:
		var args: Array = []
		for a in [a0, a1, a2, a3, a4, a5]:
			if typeof(a) == TYPE_STRING and a == _NONE:
				break
			args.append(a)
		handler.call(sig, args)


## Argument i as int (0 when missing).
static func arg_int(args: Array, i: int) -> int:
	if i >= args.size():
		return 0
	var v = args[i]
	if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_BOOL:
		return int(v)
	if typeof(v) == TYPE_STRING and String(v).is_valid_int():
		return String(v).to_int()
	return 0


## The lobby id in a join_game_requested connect string (any String argument),
## e.g. "+connect_lobby 109775241234567890". "" when there is none.
static func connect_lobby_of(args: Array) -> String:
	for a in args:
		if typeof(a) == TYPE_STRING:
			var id := LaunchArgs.find_connect_lobby(LaunchArgs.split_command_line(String(a)))
			if id != "":
				return id
	return ""
