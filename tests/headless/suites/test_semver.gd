extends "res://tests/test_case.gd"

const Semver = preload("res://gamedir/mods/PittAPI/core/semver.gd")


func test_parse() -> void:
	assert_eq(Semver.parse("1.2.3").major, 1, "major")
	assert_eq(Semver.parse("1.2.3").patch, 3, "patch")
	assert_true(Semver.parse("x.y").is_empty(), "garbage is invalid")
	assert_true(Semver.is_valid("1.0.0"), "1.0.0 valid")
	assert_false(Semver.is_valid("1.0"), "1.0 is not a full version")


func test_compare() -> void:
	assert_eq(Semver.compare("1.0.0", "1.0.1"), -1, "patch order")
	assert_eq(Semver.compare("2.0.0", "1.9.9"), 1, "major order")
	assert_eq(Semver.compare("1.0.0-beta", "1.0.0"), -1, "pre-release sorts first")
	assert_eq(Semver.compare("1.2.3", "1.2.3"), 0, "equal")


func test_ranges() -> void:
	var cases := [
		["1.0.0", "^1.0", true], ["1.9.3", "^1.0", true], ["2.0.0", "^1.0", false],
		["0.3.5", "^0.3.1", true], ["0.4.0", "^0.3.1", false],
		["1.2.9", "~1.2.3", true], ["1.3.0", "~1.2.3", false],
		["1.0.0", ">=1.0.0 <2.0.0", true], ["2.0.0", ">=1.0.0 <2.0.0", false],
		["5.0.0", "*", true], ["5.0.0", "", true],
		["1.2.3", "1.2.3", true], ["1.2.4", "1.2.3", false], ["1.2.9", "1.2", true],
		["3.0.0", "^1.0 || ^3.0", true], ["2.0.0", "^1.0 || ^3.0", false],
	]
	for c in cases:
		assert_eq(Semver.satisfies(c[0], c[1]), c[2], "%s in '%s'" % [c[0], c[1]])
	assert_false(Semver.is_valid_range("^banana"), "invalid range")
