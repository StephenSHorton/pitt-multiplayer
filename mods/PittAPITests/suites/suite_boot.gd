extends RefCounted
## Boot suite: runs right after game.boot_complete. Read-only.
## Also probes the three live-only questions from the design (S1-S3).

const ALL_AUTOLOADS := ["CameraFeedManager", "ObjectPoolManager", "PerformanceMonitor", "LocalizationManager",
	"GameState", "ComboSystem", "Steamworks", "PostProcessManager", "MusicManager", "GameProgression",
	"WorkbenchSpawning", "InputManager", "MenuManager", "SaveManager", "UnlockManager", "LoadingScreen",
	"ResourceWarmer", "PortalPairManager", "ScreenFade", "ImpactAudio"]


func run(t, api, host: Node) -> void:
	var dir: String = api.pittapi_dir()
	var status_path := dir.path_join("status.json")
	t.check("loader.status_json_exists", FileAccess.file_exists(status_path), status_path)
	var status = JSON.parse_string(FileAccess.get_file_as_string(status_path)) if FileAccess.file_exists(status_path) else null
	var states := {}
	if typeof(status) == TYPE_DICTIONARY:
		for m in status.get("mods", []):
			states[m.id] = m
	t.eq("loader.self_loaded", String(states.get("PittAPITests", {}).get("state", "")), "LOADED")
	t.eq("loader.example_loaded", String(states.get("ExampleMod", {}).get("state", "")), "LOADED",
		String(states.get("ExampleMod", {}).get("reason", "")))
	var broken: Dictionary = states.get("_PittAPIBrokenFixture", {})
	t.eq("loader.broken_fixture_failed", String(broken.get("state", "<missing>")), "FAILED", String(broken.get("reason", "")))
	t.check("loader.broken_fixture_reason_compile", String(broken.get("reason", "")).contains("compile"), String(broken.get("reason", "")))

	var disabled: Array = status.get("contract", {}).get("disabled", ["<no status>"]) if typeof(status) == TYPE_DICTIONARY else ["<no status>"]
	t.check("contract.no_disabled_features", disabled.is_empty(),
		"disabled=%s missing=%s" % [str(disabled), JSON.stringify(status.get("contract", {}).get("missing", {})) if typeof(status) == TYPE_DICTIONARY else ""])

	var ext_ok := false
	for e in api.extensions.list():
		if e.target == "res://scripts/hud.gd":
			for c in e.chain:
				if c.mod == "ExampleMod":
					ext_ok = true
	t.check("extensions.example_hud_registered", ext_ok, JSON.stringify(api.extensions.list()))
	var blocked: Array = api.extensions.blocked_autoloads()
	var missing: Array = []
	for n in ALL_AUTOLOADS:
		if not (n in blocked):
			missing.append(n)
	t.check("extensions.blocked_all_20_autoloads", missing.is_empty(), "missing=%s" % str(missing))
	t.check("extensions.blocked_has_big_int", "res://scripts/big_int.gd" in api.extensions.blocked(), "")

	t.check("log.file_exists", FileAccess.file_exists(dir.path_join("pittapi.log")), "")
	var re := RegEx.new()
	re.compile("^\\d+\\.\\d+\\.\\d+$")
	t.check("version.semver", re.search(api.api_version) != null, api.api_version)
	t.eq("version.game", api.game_version, "1.0.8")
	t.check("events.boot_complete_seen", api.events.last("game.boot_complete") != null, "")
	t.check("errors.none_from_pittapi", api.recent_errors(200, "PittAPI").is_empty(),
		JSON.stringify(api.recent_errors(5, "PittAPI")))

	# Engine (C++) errors reach the Logger in every build: get_node on a missing
	# path is an ERR_FAIL in node.cpp. It must be attributed to this mod (by frame
	# or, in release builds without script backtraces, by the guard scope).
	var before: int = api.recent_errors(500, "PittAPITests").size()
	api.invoke(Callable(self, "_deliberate_engine_error").bind(host))
	var mine: Array = api.recent_errors(500, "PittAPITests")
	t.check("guard.error_attributed_to_mod", mine.size() > before, "engine errors attributed to PittAPITests: %d -> %d" % [before, mine.size()])
	if mine.size() > before:
		var e: Dictionary = mine[mine.size() - 1]
		# S2: does the release template report script frames for engine errors?
		var file_ok := String(e.file).replace("\\", "/").to_lower().contains("/pittapitests/") 			or str(e.frames).to_lower().contains("pittapitests")
		t.check("S2.release_reports_file_paths", file_ok,
			"file=%s frames=%s (false = attribution uses the scope fallback)" % [e.file, str(e.frames)], true)

	# GDScript VM runtime errors (call on null): reported to loggers only in debug
	# builds. Release templates neither report them nor abort the function.
	before = api.recent_errors(500, "PittAPITests").size()
	_continued = false
	api.invoke(Callable(self, "_deliberate_error"))
	var after: int = api.recent_errors(500, "PittAPITests").size()
	if OS.is_debug_build():
		t.check("guard.script_error_attributed_to_mod", after > before, "script errors: %d -> %d" % [before, after])
	else:
		t.check("S4.release_reports_script_errors", after > before,
			"script errors: %d -> %d, function continued=%s (release: VM errors are invisible to loggers)" % [before, after, _continued], true)

	# S3: can scripts compiled after boot use the PittAPI global identifier?
	var s := GDScript.new()
	s.source_code = "extends RefCounted\nfunc v():\n\treturn PittAPI.api_version\n"
	var err := s.reload()
	var s3: bool = err == OK and s.can_instantiate() and str(s.new().v()) == api.api_version
	t.check("S3.global_identifier_PittAPI", s3, "reload=%s (false = use the api handle only)" % error_string(err), true)


var _continued := false


func _deliberate_error() -> void:
	# intentionally calls a missing method to produce a script error
	var nothing = null
	nothing.this_method_does_not_exist()
	_continued = true


func _deliberate_engine_error(host: Node) -> void:
	host.get_node("PittAPITests_no_such_child/x")
