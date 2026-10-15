extends RefCounted
## +connect_lobby <id>: Steam passes it on the command line when a friend clicks
## "Join Game" while the game is closed (OS.get_cmdline_args), or through
## Steam.getLaunchCommandLine() when the game is started from a rich-presence link.

const FLAG := "+connect_lobby"


## The lobby id (decimal String) in args, or "".
static func find_connect_lobby(args: Array) -> String:
	for i in args.size():
		var a := str(args[i]).strip_edges()
		if a == FLAG and i + 1 < args.size():
			var v := str(args[i + 1]).strip_edges()
			if _is_id(v):
				return v
		elif a.begins_with(FLAG + "="):
			var v2 := a.substr(FLAG.length() + 1).strip_edges()
			if _is_id(v2):
				return v2
	return ""


## Splits a command line string (Steam.getLaunchCommandLine) on whitespace.
static func split_command_line(line: String) -> Array:
	var out: Array = []
	for part in line.split(" ", false):
		var p := part.strip_edges().trim_prefix("\"").trim_suffix("\"")
		if p != "":
			out.append(p)
	return out


## Reads every source; steam may be null.
static func read(steam: Object = null) -> String:
	var args: Array = []
	args.append_array(Array(OS.get_cmdline_args()))
	args.append_array(Array(OS.get_cmdline_user_args()))
	var id := find_connect_lobby(args)
	if id != "":
		return id
	if steam != null and steam.has_method("getLaunchCommandLine"):
		var line = steam.call("getLaunchCommandLine")
		if typeof(line) == TYPE_STRING and line != "":
			return find_connect_lobby(split_command_line(line))
	return ""


static func _is_id(v: String) -> bool:
	return v.is_valid_int() and v.to_int() > 0
