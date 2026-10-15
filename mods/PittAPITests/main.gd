extends Node
## PittAPITests: the in-game test suite.
## Armed ONLY by the one-shot flag file user://pittapi/autotest.flag, holding
##   {"run_id":"...","suites":["boot","menu","gameplay"],"quit":true,"timeout_s":240}
## The flag is deleted as soon as it is read, so a later normal launch never runs
## tests. Without the flag this mod does nothing.
##
## Order: boot (after game.boot_complete, read-only) -> menu (first main menu,
## read-only) -> gameplay (isolated new game; opt-in) -> gameplay_phase (opt-in)
## -> write report -> quit (get_tree().quit(); nothing saves on quit).

const Runner = preload("runner.gd")
const SuiteBoot = preload("suites/suite_boot.gd")
const SuiteMenu = preload("suites/suite_menu.gd")
const SuiteGameplay = preload("suites/suite_gameplay.gd")
const SuiteGameplayPhase = preload("suites/suite_gameplay_phase.gd")

var api = null
var armed := false
var flag: Dictionary = {}
var runner = null
var _started_ms := 0
var _finished := false
var _menu_started := false


func _mod_init(p_api) -> void:
	api = p_api
	var flag_path: String = api.pittapi_dir().path_join("autotest.flag")
	if not FileAccess.file_exists(flag_path):
		api.log.info("not armed (no %s); idle" % flag_path)
		return
	var text := FileAccess.get_file_as_string(flag_path)
	DirAccess.remove_absolute(flag_path)   # one-shot
	var j := JSON.new()
	flag = j.data if j.parse(text) == OK and typeof(j.data) == TYPE_DICTIONARY else {}
	if not flag.has("suites"):
		flag["suites"] = ["boot", "menu"]
	armed = true
	runner = Runner.new(api, String(flag.get("run_id", "run-%d" % Time.get_unix_time_from_system())))
	runner.report["flag"] = flag.duplicate()
	runner.write(false)
	_started_ms = Time.get_ticks_msec()
	api.log.info("ARMED: suites %s" % str(flag.suites))
	api.events.once("game.boot_complete", _on_boot_complete)
	api.events.on("scene.changed", _on_scene_changed)


func _process(_delta: float) -> void:
	if not armed or _finished:
		return
	var timeout_s := float(flag.get("timeout_s", 240))
	if Time.get_ticks_msec() - _started_ms > int(timeout_s * 1000.0):
		runner.fatal("timeout after %d s" % int(timeout_s))
		_finish()


func _wants(suite: String) -> bool:
	return suite in flag.get("suites", [])


func _on_boot_complete(_ev) -> void:
	if _wants("boot"):
		runner.begin_suite("boot")
		SuiteBoot.new().run(runner, api, self)
		runner.end_suite()
	# the main menu may already be current (unlikely at boot); otherwise wait
	var ev = api.events.last("scene.changed")
	if ev != null and ev.payload.kind == "main_menu":
		_start_menu.call_deferred()
	elif not _wants("menu") and not _wants("gameplay") and not _wants("gameplay_phase"):
		_finish()


func _on_scene_changed(ev) -> void:
	if ev.payload.kind == "main_menu" and not _menu_started:
		_start_menu.call_deferred()


func _start_menu() -> void:
	if _menu_started or _finished:
		return
	_menu_started = true
	# give the main menu a few frames to finish its _ready
	for i in 10:
		await get_tree().process_frame
	if _wants("menu"):
		runner.begin_suite("menu")
		await SuiteMenu.new().run(runner, api, self)
		runner.end_suite()
	if _wants("gameplay") or _wants("gameplay_phase"):
		runner.begin_suite("gameplay")
		await SuiteGameplay.new().run(runner, api, self)
		runner.end_suite()
		if _wants("gameplay_phase") and api.state.is_in_world():
			runner.begin_suite("gameplay_phase")
			await SuiteGameplayPhase.new().run(runner, api, self)
			runner.end_suite()
	_finish()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	runner.report["duration_ms"] = Time.get_ticks_msec() - _started_ms
	runner.write(true)
	api.log.info("tests finished: %s" % JSON.stringify(runner.report.summary))
	if bool(flag.get("quit", true)):
		# direct quit: bypasses the pause menu's save_before_exit; the game does
		# not save on window close (save_manager has no close handler)
		get_tree().quit(0 if runner.failed_count() == 0 else 1)
