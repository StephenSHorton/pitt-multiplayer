extends RefCounted
## Steam achievements policy (MP-DESIGN 8.4, owner decision D4).
## Host: single-player behaviour.
## Client, "presence" (default): nothing is granted for progress LOADED on join,
## only for thresholds crossed while connected:
##   1. before the snapshot load: remember Steamworks._granted, then
##      achievements.suppress (every id marked granted, scope local)
##   2. on save.applied: baseline = achievements the loaded state already meets
##      (the game's own _get_stat/_meets + the rule tables evaluate_all uses)
##   3. _granted = saved + baseline; everything else can fire on a real crossing
## "none": stays suppressed for the session. "all": single-player behaviour.
## Cheats: once a cheat succeeded on the host (rules.cheats), every peer
## suppresses for the rest of the session.

var session = null
var adapter = null
var mode := "presence"
var _saved: Dictionary = {}
var _joined := false
var suppressed_for_cheats := false
var baseline: Array = []


func _init(p_session = null, p_adapter = null, p_mode: String = "presence") -> void:
	session = p_session
	adapter = p_adapter
	mode = p_mode if p_mode in ["presence", "none", "all"] else "presence"


func before_join_load() -> void:
	if mode == "all":
		return
	_saved = adapter.ach_granted()
	_joined = true
	_suppress()


func after_join_load() -> void:
	if not _joined:
		return
	if mode == "none" or suppressed_for_cheats:
		return
	baseline = adapter.ach_baseline()
	var g := _saved.duplicate()
	for id in baseline:
		g[id] = true
	adapter.ach_set_granted(g)


## rules.cheats arrived (or a cheat ran here as host).
func on_cheats() -> void:
	if suppressed_for_cheats:
		return
	if not _joined:
		_saved = adapter.ach_granted()
		_joined = true
	suppressed_for_cheats = true
	_suppress()


## Session over: _granted goes back to what it was before the session (it is
## only a cache: unlock_achievement asks Steam whether an id is already achieved,
## so anything really unlocked during the session never fires twice).
func reset() -> void:
	if _joined:
		adapter.ach_set_granted(_saved)
	_joined = false
	_saved = {}
	baseline = []
	suppressed_for_cheats = false


func _suppress() -> void:
	if session != null:
		session.execute_command("achievements.suppress", {})
