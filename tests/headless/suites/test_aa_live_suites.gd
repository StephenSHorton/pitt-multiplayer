extends "res://tests/test_case.gd"
## Runs the in-game PittAPITests boot and menu suites against the fakes, so their
## code paths are exercised before the live run. Named test_aa_* so it runs first
## (before other suites initialize the fake pools). Checks that need the real game
## are listed as expected failures.

const Runner = preload("res://gamedir/mods/PittAPITests/runner.gd")
const SuiteBoot = preload("res://gamedir/mods/PittAPITests/suites/suite_boot.gd")
const SuiteMenu = preload("res://gamedir/mods/PittAPITests/suites/suite_menu.gd")

const EXPECTED_HEADLESS_FAILURES := [
	"loader.broken_fixture_failed",          # fixture only installed/armed for live runs
	"loader.broken_fixture_reason_compile",
	"extensions.blocked_all_20_autoloads",   # the fake project has 10 autoloads
	"bridge.scene_changed_main_menu",        # no main menu scene headless
]


func _failing(r) -> Array:
	var out: Array = []
	for s in r.report.suites:
		for t in s.tests:
			if not t.ok and not t.get("info", false):
				out.append(t.name)
	return out


func test_boot_and_menu_suites() -> void:
	var ctx = core.loader.mods["PittAPITests"].ctx
	var r = Runner.new(ctx, "headless")
	r.begin_suite("boot")
	SuiteBoot.new().run(r, ctx, runner)
	r.end_suite()
	r.begin_suite("menu")
	await SuiteMenu.new().run(r, ctx, runner)
	r.end_suite()
	r.write(true)
	var failing := _failing(r)
	for name in failing:
		assert_has(EXPECTED_HEADLESS_FAILURES, name, "unexpected failure in the live suites: %s" % name)
	assert_true(r.report.summary.passed > 30, "live suites ran: %d passed" % r.report.summary.passed)
	assert_true(FileAccess.file_exists("user://pittapi/test_report.json"), "report written")
	var info := {}
	for s in r.report.suites:
		for t in s.tests:
			if t.get("info", false):
				info[t.name] = t.ok
	assert_true(info.get("S2.release_reports_file_paths", false), "editor build reports file paths (S2 baseline)")
	assert_true(info.get("S3.global_identifier_PittAPI", false), "editor build: PittAPI global usable (S3 baseline)")
	core.input_registry.remove_owner("PittAPITests")
