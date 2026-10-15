extends "res://tests/test_case.gd"
## MP2 3.4 / P6 stray guard (unit): a matching count costs nothing; on a
## mismatch every active pooled node that is not a puppet (and not marked
## pitt_mp_local) is recycled; debris and panels are expected, silent sources.

const StrayGuard = preload("res://gamedir/mods/PittMultiplayer/world/bodies/stray_guard.gd")
const FakePools = preload("res://tests/fakes/mp2_bodies/fake_pools.gd")


class PoolsAdapter extends RefCounted:
	var pm = null

	func pools() -> Dictionary:
		return pm._pools


func test_stray_guard() -> void:
	var container := Node3D.new()
	container.name = "ObjectPools"
	runner.add_child(container)
	var pm = FakePools.new()
	pm.gravity = false
	runner.add_child(pm)
	pm.setup(container)
	var ad := PoolsAdapter.new()
	ad.pm = pm
	var g := StrayGuard.new(ad)
	var logs: Array = []
	g.log_cb = func(m): logs.append(m)
	var puppet: Node3D = pm.spawn("duck")
	puppet.set_meta("pitt_mp_puppet", 1001)
	var recycled: Array = []
	var rec := func(n):
		recycled.append(n)
		pm.recycle(n)
	assert_eq(g.check(1, rec), 0, "count matches: nothing to do")
	assert_eq(g.diffs, 0, "no diff on a match")
	var stray: Node3D = pm.spawn("duck")
	var debris: Node3D = pm.spawn("debris_chunk")
	var panel: Node3D = pm.spawn("tool_panel")
	var local: Node3D = pm.spawn("candy")
	local.set_meta("pitt_mp_local", true)
	assert_eq(g.check(1, rec), 3, "three strays recycled")
	assert_has(recycled, stray, "the duck")
	assert_has(recycled, debris, "debris (GameProgression)")
	assert_has(recycled, panel, "panel (dump_panel_stack)")
	assert_false(local in recycled, "pitt_mp_local is left alone")
	assert_false(puppet in recycled, "puppets are never touched")
	assert_eq(g.stray_spawns, 1, "only the duck counts as a missed gate")
	assert_eq(g.stray_expected, 2, "debris + panel are expected")
	assert_eq(int(g.by_pool.get("duck", 0)), 1, "by pool")
	assert_eq(logs.size(), 1, "one log line (the unexpected one)")
	container.queue_free()
	pm.queue_free()
