extends "../scenario_base.gd"
## D1 / D2 (v0.2.1, the first two-PC Steam test): the game's own duck workbench
## ("the dispenser"), driven through the real input path on both sides.
##   D1  the host holds LMB at the manual duck workbench (Input.action_press, read by
##       interact_ray.handle_workbench_interaction); workbench.craft_item spawns the
##       duck through ObjectPoolManager. The client must see that duck (a puppet with
##       the host eid) within 1.5 s.
##   D2  the client does the same at its copy of the bench: the gated start_crafting
##       goes to the host as interact, the host's bench crafts a duck, the client sees
##       it; releasing LMB stops the host's bench (stop_crafting forwarded).
## Marks: d1_host_spawned {d1_eid}, d1_client_checked, d2_client_holding,
## d2_host_crafted {d2_eid}, d2_client_released, d2_host_checked.

const CRAFT_WAIT_S := 15.0


func _bench() -> Node3D:
	var p := player()
	var best: Node3D = null
	var best_named := false
	var best_d := INF
	for n in tree().get_nodes_in_group("workbench"):
		var b := n as Node3D
		if b == null or b.is_in_group("automated_workbench") or not b.has_method("start_crafting"):
			continue
		var named := String(b.name).contains("Duck")
		var d := b.global_position.distance_to(p.global_position) if p != null else 0.0
		if (named and not best_named) or (named == best_named and d < best_d):
			best = b
			best_named = named
			best_d = d
	return best


func _ray():
	var cam := tree().get_first_node_in_group("main_camera")
	return cam.get("interact_ray") if cam != null else null


## Stand in front of the bench and look at it until the interact ray reports it.
func _at_bench(bench: Node3D) -> bool:
	var bp := bench.global_position
	var ray = _ray()
	for dir in [Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(-1, 0, 0)]:
		var spot := open_spot(bp + Vector3(0, 0.975, 0), dir, [1.6, 2.0, 2.4])
		if spot == Vector3.INF:
			continue
		await cmd("player.teleport", {"position": [spot.x, spot.y, spot.z]})
		await sleep_ms(400)
		var ok: bool = await wait_for(func():
			face(bp + Vector3(0, 0.6, 0))
			return ray != null and ray.get("last_collider") == bench, 2.0)
		if ok:
			return true
	return false


func _hold_lmb(on: bool) -> void:
	if on:
		Input.action_press("lMouse")
	else:
		Input.action_release("lMouse")


func run_host() -> void:
	report.begin("D1_host_dispenses")
	var bench := _bench()
	if not report.check("d1_bench_found", bench != null, ""):
		report.mark("d1_host_spawned", {"d1_eid": 0})
		report.mark("d2_host_crafted", {"d2_eid": 0})
		report.mark("d2_host_checked")
		return
	var start := player().global_position if player() != null else Vector3.INF
	var made: Array = []
	var spawned: Array = []
	var sub = api.events.on("entity.spawned", func(ev):
		var pid := String(ev.payload.get("pool_id", ""))
		var n = api.entities.get_node(int(ev.payload.get("entity_id", 0)))
		if pid.begins_with("duck") and n != null and (n as Node3D).global_position.distance_to(bench.global_position) < 4.0:
			spawned.append(int(ev.payload.entity_id))
			made.append(int(ev.payload.entity_id)))
	var on: bool = await _at_bench(bench)
	report.check("d1_ray_on_bench", on, "last_collider %s" % str(_ray().get("last_collider") if _ray() != null else null))
	_hold_lmb(true)
	var ok: bool = await wait_for(func(): return not spawned.is_empty(), CRAFT_WAIT_S)
	_hold_lmb(false)
	report.check("d1_host_crafted_through_input", ok, "%d duck(s) from the bench" % spawned.size())
	var eid: int = int(spawned[0]) if ok else 0
	report.mark("d1_host_spawned", {"d1_eid": eid, "d1_bench": [bench.global_position.x, bench.global_position.y,
		bench.global_position.z]})
	await wait_peer_mark("d1_client_checked", 30.0)
	# step back: the client stands at the bench for D2
	var p := player()
	if p != null:
		var back := p.global_position + (p.global_position - bench.global_position).normalized() * 2.0
		await cmd("player.teleport", {"position": [back.x, p.global_position.y, back.z]})

	report.begin("D2_client_crafts")
	spawned.clear()
	var hv: Dictionary = await wait_peer_mark("d2_client_holding", 60.0)
	report.check("d2_client_holding", not hv.is_empty(), "")
	ok = await wait_for(func(): return not spawned.is_empty(), CRAFT_WAIT_S)
	report.check("d2_host_bench_crafted_for_client", ok, "%d duck(s), bench crafting %s" % [spawned.size(),
		str(bench.get("is_crafting"))])
	report.mark("d2_host_crafted", {"d2_eid": int(spawned[0]) if ok else 0})
	var rv: Dictionary = await wait_peer_mark("d2_client_released", 30.0)
	if not rv.is_empty():
		var stopped: bool = await wait_for(func(): return bench.get("is_crafting") != true, 3.0)
		report.check("d2_host_bench_stopped_on_release", stopped, "is_crafting %s" % str(bench.get("is_crafting")))
	api.events.off(sub)
	# leave the floor as the later scenarios expect it: crafted ducks gone, host back
	for e in made:
		var n = api.entities.get_node(int(e))
		if n != null and (n as Node3D).visible:
			g("ObjectPoolManager").recycle(n)
	if start != Vector3.INF:
		await cmd("player.teleport", {"position": [start.x, start.y, start.z]})
	await sleep_ms(500)
	report.mark("d2_host_checked")


func run_client() -> void:
	report.begin("D1_client_sees_dispensed")
	var b = session.get_module("bodies")
	var hv: Dictionary = await wait_peer_mark("d1_host_spawned", 90.0)
	var eid := int(hv.get("d1_eid", 0))
	var t0 := Time.get_ticks_msec()
	var seen := false
	if eid > 0:
		seen = await wait_for(func(): return b.node_of(eid) != null and (b.node_of(eid) as Node3D).visible, 1.5)
	report.value("d1_seen_after_ms", Time.get_ticks_msec() - t0)
	report.check("d1_client_sees_host_duck", seen, "eid %d, puppets %d, counters %s" % [eid,
		int(b.counters().get("puppets", 0)), str(session.counters)])
	await shot("mp2-d1-client-sees-dispensed-duck")
	report.mark("d1_client_checked")

	report.begin("D2_client_crafts")
	var bench := _bench()
	if not report.check("d2_bench_on_client", bench != null, ""):
		report.mark("d2_client_holding")
		report.mark("d2_client_released")
		return
	await sleep_ms(800)
	var on: bool = await _at_bench(bench)
	report.check("d2_ray_on_bench", on, "")
	var tx0 := int(gameplay_counter("interact_tx"))
	_hold_lmb(true)
	report.mark("d2_client_holding")
	var cv: Dictionary = await wait_peer_mark("d2_host_crafted", CRAFT_WAIT_S + 10.0)
	_hold_lmb(false)
	report.check("d2_interact_sent", int(gameplay_counter("interact_tx")) > tx0, "interact_tx %d -> %d" % [tx0,
		int(gameplay_counter("interact_tx"))])
	var e2 := int(cv.get("d2_eid", 0))
	seen = false
	if e2 > 0:
		seen = await wait_for(func(): return b.node_of(e2) != null, 1.5)
	report.check("d2_client_sees_its_crafted_duck", seen, "eid %d" % e2)
	report.check("d2_no_local_craft", int(b.counters().get("stray_spawns", 0)) == 0, "strays %d" % int(
		b.counters().get("stray_spawns", 0)))
	await sleep_ms(300)
	report.mark("d2_client_released")
	await wait_peer_mark("d2_host_checked", 30.0)


func gameplay_counter(k: String) -> int:
	var gp = session.get_module("gameplay")
	if gp == null or not gp.has_method("counters"):
		return 0
	return int(gp.counters().get(k, 0))
