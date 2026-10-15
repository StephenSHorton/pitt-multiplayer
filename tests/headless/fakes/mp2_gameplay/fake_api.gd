extends RefCounted
## A per-peer stand-in for PittMultiplayer's PittAPIContext in the GAMEPLAY
## suites: a REAL loader Commands registry (own local authority), an api.net with
## begin_apply / end_apply / is_applying (the MP2 gate reads it), and the local
## player commands the client side uses (player.impulse / player.teleport), which
## only record here.

const Commands = preload("res://gamedir/mods/PittAPI/core/commands.gd")
const Authority = preload("res://gamedir/mods/PittAPI/core/authority.gd")


class ApplyNet extends RefCounted:
	var depth := 0
	var apply_calls := 0

	func begin_apply(_origin: int = 1) -> void:
		depth += 1
		apply_calls += 1

	func end_apply() -> void:
		depth = maxi(depth - 1, 0)

	func is_applying() -> bool:
		return depth > 0


class Log extends RefCounted:
	var lines: Array = []

	func info(m: String, _d = null) -> void:
		lines.append("I " + m)

	func warn(m: String, _d = null) -> void:
		lines.append("W " + m)

	func error(m: String, _d = null) -> void:
		lines.append("E " + m)

	func debug(_m: String, _d = null) -> void:
		pass


var name := ""
var commands = null
var net := ApplyNet.new()
var log := Log.new()
var impulses: Array = []
var teleports: Array = []
var executed: Array = []          # [name, args] of every command this peer issued


func _init(p_name: String = "peer") -> void:
	name = p_name
	commands = Commands.new(null, Authority.new())
	commands.register("player.impulse", func(a, _c):
		impulses.append(Vector3(float(a.impulse[0]), float(a.impulse[1]), float(a.impulse[2])))
		return {}, {"scope": "local", "replicate": "none", "schema": {"impulse": TYPE_ARRAY}})
	commands.register("player.teleport", func(a, _c):
		teleports.append(Vector3(float(a.position[0]), float(a.position[1]), float(a.position[2])))
		return {}, {"scope": "local", "replicate": "none", "schema": {"position?": TYPE_ARRAY}})


func path(rel: String) -> String:
	return "res://gamedir/mods/PittMultiplayer".path_join(rel)
