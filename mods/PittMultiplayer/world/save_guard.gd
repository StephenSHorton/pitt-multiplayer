extends RefCounted
## Save guard (MP-DESIGN 8.3), clients only: save.isolate (scope local, L1) on
## the session file from before the world loads until after it is left. PittAPI
## re-asserts the lock and the path every frame (the elevator resets
## save_locked, elevator.gd:57). set_active_slot is never called. The session
## file is deleted at session end; orphans are deleted at boot.
## The host saves its own slot normally (it holds the merged co-op progress).

const Snapshot = preload("../sync/snapshot.gd")

var session = null
var adapter = null
var active := false
var path := ""


func _init(p_session = null, p_adapter = null) -> void:
	session = p_session
	adapter = p_adapter


## -> "" or an error.
func enable(p_path: String) -> String:
	path = p_path
	var r = session.execute_command("save.isolate", {"enabled": true, "path": p_path})
	if r == null or not r.done or not r.ok:
		return "save.isolate failed: %s" % (r.error if r != null else "no command")
	active = true
	return ""


func disable() -> void:
	if active:
		active = false
		session.execute_command("save.isolate", {"enabled": false})
	if path != "":
		adapter.delete_file(path)
		path = ""


## Leftovers of a crashed session.
static func cleanup_orphans(dir: String) -> int:
	var n := 0
	var d := dir.path_join("session")
	var da := DirAccess.open(d)
	if da == null:
		return 0
	for f in da.get_files():
		if f.begins_with("mp_") and (f.ends_with(".save") or f.contains(".save.")):
			DirAccess.remove_absolute(d.path_join(f))
			n += 1
	return n
