extends "res://tests/test_case.gd"


func test_order_and_priority() -> void:
	var seen: Array = []
	var a: int = core.events.on("t.order", func(_e): seen.append("a"))
	var b: int = core.events.on("t.order", func(_e): seen.append("b"), 10)
	var c: int = core.events.on("t.order", func(_e): seen.append("c"))
	core.events.emit_internal("t.order", {})
	assert_eq(seen, ["b", "a", "c"], "priority first, then subscription order")
	for id in [a, b, c]:
		core.events.off(id)


func test_wildcards_and_off() -> void:
	var all: Array = []
	var pre: Array = []
	var a: int = core.events.on("*", func(e): all.append(e.name))
	var b: int = core.events.on("t.wild.*", func(e): pre.append(e.name))
	core.events.emit_internal("t.wild.one", {})
	core.events.emit_internal("t.other", {})
	assert_has(all, "t.wild.one", "* sees everything")
	assert_has(all, "t.other", "* sees everything")
	assert_eq(pre, ["t.wild.one"], "prefix match only")
	core.events.off(b)
	core.events.emit_internal("t.wild.two", {})
	assert_eq(pre.size(), 1, "off stops delivery")
	core.events.off(a)


func test_once_and_last() -> void:
	var n := [0]
	core.events.once("t.once", func(_e): n[0] += 1)
	core.events.emit_internal("t.once", {"v": 1})
	core.events.emit_internal("t.once", {"v": 2})
	assert_eq(n[0], 1, "once fires once")
	var last = core.events.last("t.once")
	assert_eq(last.payload.v, 2, "last() returns the latest")
	assert_true(last.seq > 0 and last.t_ms >= 0 and last.origin == 1, "event metadata")


func test_payloads_json_safe() -> void:
	var got: Array = []
	var id: int = core.events.on("t.safe", func(e): got.append(e))
	core.events.emit_internal("t.safe", {"v": Vector3(1, 2, 3), "s": &"name", "t": Transform3D.IDENTITY})
	assert_eq(got[0].payload.v, [1.0, 2.0, 3.0], "Vector3 -> array")
	assert_eq(got[0].payload.s, "name", "StringName -> String")
	assert_eq(got[0].payload.t.size(), 12, "Transform3D -> 12 floats")
	assert_true(JSON.parse_string(JSON.stringify(got[0].payload)) != null, "round-trips through JSON")
	core.events.off(id)


func test_mod_emit_rules() -> void:
	var ctx = core.loader.mods["ExampleMod"].ctx
	assert_eq(ctx.events.emit("mod.ExampleMod.hello", {"x": 1}), OK, "own namespace")
	assert_eq(ctx.events.emit("money.changed", {}), ERR_UNAUTHORIZED, "core names refused")
	assert_eq(ctx.events.emit("mod.Other.x", {}), ERR_UNAUTHORIZED, "other mod namespace refused")
	assert_eq(ctx.events.emit("mod.ExampleMod.bad", {"cb": func(): pass}), ERR_INVALID_DATA, "Callable rejected")
	assert_eq(ctx.events.emit("mod.ExampleMod.bad", {"o": RefCounted.new()}), ERR_INVALID_DATA, "plain Object rejected")
	assert_eq(core.events.last("mod.ExampleMod.hello").source, "mod:ExampleMod", "source tag")


func test_handler_error_does_not_stop_others() -> void:
	var seen: Array = []
	var a: int = core.events.on("t.err", func(_e):
		var n = null
		n.boom(), 5)
	var b: int = core.events.on("t.err", func(_e): seen.append("after"))
	assert_error_logged(func(): core.events.emit_internal("t.err", {}), "handler error")
	assert_eq(seen, ["after"], "next handler still ran")
	core.events.off(a)
	core.events.off(b)


func test_wait() -> void:
	var t0 := Time.get_ticks_msec()
	var ev = await core.events.wait("t.never", 0.2)
	assert_eq(ev, null, "timeout returns null")
	assert_true(Time.get_ticks_msec() - t0 >= 150, "waited")
	_emit_next_frame()
	var ev2 = await core.events.wait("t.soon", 2.0)
	assert_true(ev2 != null and ev2.payload.ok, "wait returns the event")


func _emit_next_frame() -> void:
	await tree.process_frame
	core.events.emit_internal("t.soon", {"ok": true})


func test_bound_off_is_owner_checked() -> void:
	var seen: Array = []
	var core_sub: int = core.events.on("t.owned", func(_e): seen.append(1), 0, "PittAPI")
	var ex = core.loader.mods["ExampleMod"].ctx
	assert_false(ex.events.off(core_sub), "a mod cannot cancel another owner's subscription")
	core.events.emit_internal("t.owned", {})
	assert_eq(seen.size(), 1, "subscription still active")
	var mine: int = ex.events.on("t.owned", func(_e): pass)
	assert_true(ex.events.off(mine), "own subscription removed")
	core.events.off(core_sub)
