extends Node
## PittMPTests: the two-instance ENet loopback scenario (MP-DESIGN 10.2), run
## by tools/test-mp-loopback.ps1. Armed only by <pittapi dir>/mp_autotest.flag
## (deleted when read), so a normal launch never runs anything:
##   {"role": "host"|"client", "run_id": "...", "timeout_s": 600, "quit": true,
##    "report": "<abs path>", "peer_report": "<abs path of the other side's report>",
##    "address": "127.0.0.1", "port": 27450,
##    "conditioning": {"latency_ms": 100, "jitter_ms": 30, "loss": 0.05}}
## The scenario starts on the first main menu.

const Report = preload("report.gd")
const ScenarioHost = preload("scenario_host.gd")
const ScenarioClient = preload("scenario_client.gd")
const ScenarioUiLive = preload("scenario_ui_live.gd")
const ScenarioMp2 = preload("mp2/scenario_mp2.gd")   # role "mp2", side host|client (MP2-DESIGN 11.2)

var api = null
var flag: Dictionary = {}
var report = null
var _started := false


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _mod_init(p_api) -> void:
	api = p_api
	var fp: String = api.pittapi_dir().path_join("mp_autotest.flag")
	if not FileAccess.file_exists(fp):
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(fp))
	DirAccess.remove_absolute(fp)
	if typeof(d) != TYPE_DICTIONARY or not (String(d.get("role", "")) in ["host", "client", "ui_live", "mp2"]):
		api.log.warn("mp_autotest.flag is invalid; ignored")
		return
	flag = d
	var rp := String(flag.get("report", ""))
	if rp == "":
		rp = ProjectSettings.globalize_path(api.pittapi_dir().path_join("mp_report.json"))
	report = Report.new(rp, String(flag.get("run_id", "")), String(flag.role))
	report.value("user_dir", OS.get_user_data_dir())
	report.value("pittapi_dir", ProjectSettings.globalize_path(api.pittapi_dir()))
	api.log.info("PittMPTests armed as %s (run %s)" % [flag.role, flag.get("run_id", "")])
	api.events.on("scene.changed", _on_scene)
	var tmo := float(flag.get("timeout_s", 900))
	get_tree().create_timer(tmo, true, false, true).timeout.connect(_on_timeout)
	_maybe_start.call_deferred()


func _on_scene(ev) -> void:
	if String(ev.payload.get("kind", "")) == "main_menu":
		_maybe_start()


func _maybe_start() -> void:
	if _started or report == null:
		return
	var tree := get_tree()
	if tree.current_scene == null or tree.current_scene.scene_file_path != "res://scenes/main_menu.tscn":
		return
	_started = true
	await get_tree().create_timer(1.5, true, false, true).timeout
	var mp = api.get_mod_api("PittMultiplayer")
	if mp == null or mp.get("session") == null:
		report.fatal("PittMultiplayer is not loaded")
		_end()
		return
	var sc = ScenarioHost.new() if String(flag.role) == "host" else (ScenarioUiLive.new() if String(flag.role) == "ui_live" else (ScenarioMp2.new() if String(flag.role) == "mp2" else ScenarioClient.new()))
	sc.setup(self, api, mp, report, flag)
	await sc.run()
	_end()


func _on_timeout() -> void:
	if report != null and not report.data.finished:
		report.fatal("timeout after %s s" % str(flag.get("timeout_s", 900)))
		_end()


func _end() -> void:
	if report == null or report.data.finished:
		return
	var mp = api.get_mod_api("PittMultiplayer")
	if mp != null and mp.get("session") != null:
		report.value("session_dump", mp.session.dump())
	report.finish()
	if bool(flag.get("quit", true)):
		await get_tree().create_timer(1.0, true, false, true).timeout
		get_tree().quit()
