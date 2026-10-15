extends Node
## FakeSession: the UI stream's double of NET's net/session.gd (MP-DESIGN 5.4).
## Records every call in `calls`; test code drives it with set_state(),
## set_roster(), set_start(), end(). Like the real Session it moves to "lobby"
## on lobby_entered and leave() always ends with lobby.leave().

signal state_changed(state: String, info: Dictionary)
signal roster_changed(players: Array)
signal start_availability_changed(ok: bool, reason: String)
signal ended(reason: String, detail: String)

var calls: Array = []
var lobby: Node = null
var state := "idle"
var role := ""
var info: Dictionary = {"role": "", "sub": "", "host_state": ""}
var roster: Array = []
var start_ok := true
var start_reason := ""
var start_result: int = OK
var last_end: Dictionary = {}


func attach(p_lobby: Node) -> void:
	lobby = p_lobby
	lobby.lobby_entered.connect(_on_lobby_entered)
	lobby.lobby_left.connect(_on_lobby_left)


func _on_lobby_entered(li: Dictionary) -> void:
	role = "host" if bool(li.get("is_owner", false)) else "client"
	set_state("lobby", {"role": role, "sub": "waiting" if role == "host" else "connecting", "host_state": "lobby"})


func _on_lobby_left(reason: String) -> void:
	if state != "idle":
		if reason == "host_left":
			end("host_left", "")
		else:
			set_state("idle", {"role": "", "sub": "", "host_state": ""})


# ------------------------------------------------------------------ 5.4 queries

func get_state() -> String:
	return state


func get_role() -> String:
	return role


func is_live() -> bool:
	return state != "idle" and state != "closing"


func get_roster() -> Array:
	return roster.duplicate(true)


func can_start() -> Dictionary:
	if role != "host" or state != "lobby":
		return {"ok": false, "reason": "MP_START_NOT_HOST" if role != "host" else "MP_START_BUSY"}
	return {"ok": start_ok, "reason": start_reason}


func consume_last_end() -> Dictionary:
	calls.append(["consume_last_end", []])
	var e := last_end
	last_end = {}
	return e


# ------------------------------------------------------------------ 5.4 commands

func start_game() -> Error:
	calls.append(["start_game", []])
	if start_result != OK:
		return start_result
	set_state("starting", {"role": "host", "sub": "", "host_state": "starting"})
	if lobby != null:
		lobby.set_state("starting")
	return OK


func cancel_start() -> void:
	calls.append(["cancel_start", []])
	set_state("lobby", {"role": "host", "sub": "waiting", "host_state": "lobby"})
	if lobby != null:
		lobby.set_state("waiting")


func notify_host_launch(scene_path: String) -> void:
	calls.append(["notify_host_launch", [scene_path]])
	set_state("loading", {"role": "host", "sub": "", "host_state": "starting"})


func leave(reason: String = "left") -> void:
	calls.append(["leave", [reason]])
	var was := state != "idle"
	state = "idle"
	role = ""
	if lobby != null:
		lobby.leave()
	if was:
		state_changed.emit("idle", {"role": "", "sub": "", "host_state": ""})


# ------------------------------------------------------------------ test drivers

func set_state(s: String, i: Dictionary = {}) -> void:
	state = s
	info = i.duplicate()
	if i.has("role"):
		role = str(i.role)
	state_changed.emit(s, info)


func set_roster(r: Array) -> void:
	roster = r.duplicate(true)
	roster_changed.emit(get_roster())


func set_start(ok: bool, reason: String = "") -> void:
	start_ok = ok
	start_reason = reason
	start_availability_changed.emit(ok, reason)


## The session ends: last_end is recorded (consumed by the next main menu), then ended fires.
func end(reason: String, detail: String = "") -> void:
	last_end = {"reason": reason, "detail": detail}
	state = "idle"
	role = ""
	ended.emit(reason, detail)
	if lobby != null:
		lobby.leave()
	state_changed.emit("idle", {"role": "", "sub": "", "host_state": ""})


func called(name: String) -> int:
	var n := 0
	for c in calls:
		if c[0] == name:
			n += 1
	return n
