extends "res://tests/test_case.gd"

const Log = preload("res://gamedir/mods/PittAPI/core/log.gd")


func test_rotation_keeps_three() -> void:
	var dir := "user://t_log"
	rm_rf(ProjectSettings.globalize_path(dir))
	var sink = Log.make_sink(dir.path_join("x.log"), 2000, 3)
	sink.echo = false
	var l = Log.new(sink, "T")
	for i in 200:
		l.info("line %d with some padding to fill the file quickly" % i, {"i": i})
	sink.close()
	assert_true(FileAccess.file_exists(dir.path_join("x.log")), "current file")
	assert_true(FileAccess.file_exists(dir.path_join("x.log.1")), ".1")
	assert_true(FileAccess.file_exists(dir.path_join("x.log.3")), ".3")
	assert_false(FileAccess.file_exists(dir.path_join("x.log.4")), "keeps only 3")
	var size := FileAccess.get_file_as_bytes(dir.path_join("x.log.1")).size()
	assert_true(size <= 2200, "rotated at ~max bytes (%d)" % size)


func test_line_format_and_levels() -> void:
	var dir := "user://t_log2"
	rm_rf(ProjectSettings.globalize_path(dir))
	var sink = Log.make_sink(dir.path_join("y.log"))
	sink.echo = false
	sink.set_level_name("warn")
	var l = Log.new(sink, "ExampleMod")
	l.info("hidden")
	l.warn("shown", {"a": 1})
	sink.close()
	var text := FileAccess.get_file_as_string(dir.path_join("y.log"))
	assert_false(text.contains("hidden"), "below level filtered")
	var re := RegEx.new()
	re.compile("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3} \\[WARN \\] \\[ExampleMod\\] shown \\{\"a\":1\\}")
	assert_true(re.search(text.strip_edges()) != null, "line format: %s" % text.strip_edges())
