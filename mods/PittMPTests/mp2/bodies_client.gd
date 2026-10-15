extends RefCounted
## BODIES B-scenarios, client side (MP2-DESIGN 11.2). Every check is about what
## THIS instance sees; the host writes the truth in its marks.

const RF_LIN := 1          # net/codec.gd RF_LIN: the record carries a linear velocity

var s = null


func run(p_s) -> void:
	s = p_s
	var r = s.report
	var b = s.bodies()

	r.begin("B4_late_join")
	var jv: Dictionary = s.peer().get("values", {}).get("join_now", {})
	var pre_eids: Array = jv.get("pre_eids", [])
	var ok: bool = await s.wait_for(func(): return _have_all(b, pre_eids), 5.0)
	r.check("b4_all_prepopulated_puppets", ok and not pre_eids.is_empty(), "%d of %d" % [_count_have(b, pre_eids),
		pre_eids.size()])
	var pre_pools: Dictionary = jv.get("pre_pools", {})
	var mism: Array = []
	for e in pre_eids:
		if b.pool_id_of(int(e)) != String(pre_pools.get(str(int(e)), "?")):
			mism.append(int(e))
	r.check("b4_pool_ids_match", mism.is_empty() and pre_eids.size() >= 340, "%d mismatched of %d" % [mism.size(), pre_eids.size()])
	var ws: Dictionary = s.session.wsnap_stats
	r.value("b4_wsnap_client", ws)
	r.check("b4_world_req_to_ready_le_3s", int(ws.get("total_ms", 99999)) <= 3000, "%d ms (apply %d ms)" % [
		int(ws.get("total_ms", -1)), int(ws.get("apply_ms", -1))])
	r.check("b4_from_world_snapshot", int(b.counters().get("wsnap_rows", 0)) >= pre_eids.size(), str(b.counters().get("wsnap_rows", 0)))
	r.check("b4_ids_adopted", _ids_adopted(b, pre_eids), "api.entities.id_of(puppet) == host eid (L7)")
	r.mark("b4_checked")

	r.begin("B9_tick")
	r.check("client_tick_60", Engine.physics_ticks_per_second == 60, str(Engine.physics_ticks_per_second))

	if s.wants("B1"):
		r.begin("B1_client")
		var sv: Dictionary = await s.wait_peer_mark("b1_spawned", 300.0)
		var eids: Array = sv.get("b1_spawned", {}).get("eids", [])
		var t0 := Time.get_ticks_msec()
		ok = await s.wait_for(func(): return _have_all(b, eids), 3.0)
		r.check("b1_puppets_with_host_eids", ok and eids.size() >= 40, "%d of %d after %d ms (incl. file polling)" % [
			_count_have(b, eids), eids.size(), Time.get_ticks_msec() - t0])
		if not eids.is_empty():
			var n0 = b.node_of(int(eids[0]))
			if n0 != null:
				s.face(n0.global_position)
		await s.sleep_ms(300)
		await s.shot("mp2-client-sees-host-ducks-moving")
		var moving := 0
		for e in eids:
			var hs: Dictionary = b.host_state(int(e))
			if not hs.is_empty() and (int(hs.flags) & RF_LIN):
				moving += 1
		r.value("b1_moving_records", moving)
		var rv: Dictionary = await s.wait_peer_mark("b1_rest", 30.0)
		var poses: Dictionary = rv.get("b1_rest", {}).get("poses", {})
		await s.sleep_ms(1500)
		var worst := 0.0
		var missing := 0
		for k in poses:
			var n = b.node_of(int(String(k)))
			if n == null:
				missing += 1
				continue
			var hp := Vector3(float(poses[k][0]), float(poses[k][1]), float(poses[k][2]))
			worst = maxf(worst, (n.global_position as Vector3).distance_to(hp))
		r.value("b1_rest_worst_m", worst)
		r.check("b1_rest_within_1cm", missing == 0 and worst <= 0.01 and not poses.is_empty(),
			"worst %.4f m, %d missing of %d" % [worst, missing, poses.size()])
		await s.shot("mp2-client-ducks-at-rest")
		r.mark("b1_checked")

		if s.wants("B2"):
			r.begin("B2_client")
			var gv: Dictionary = await s.wait_peer_mark("b2_recycled", 60.0)
			var gone: Array = gv.get("b2_recycled", {}).get("gone", [])
			ok = await s.wait_for(func():
				for e in gone:
					if b.is_replicated(int(e)):
						return false
				return true, 2.0)
			r.check("b2_despawned", ok and not gone.is_empty(), "%d gone" % gone.size())
			var uv: Dictionary = await s.wait_peer_mark("b2_reuse", 30.0)
			var old_eid := int(uv.get("b2_reuse", {}).get("old", 0))
			var new_eid := int(uv.get("b2_reuse", {}).get("new", 0))
			ok = await s.wait_for(func(): return not b.is_replicated(old_eid) and b.is_replicated(new_eid), 2.0)
			r.check("b2_reuse_new_eid", ok, "old %d replicated %s, new %d replicated %s" % [old_eid,
				b.is_replicated(old_eid), new_eid, b.is_replicated(new_eid)])
			var active := 0
			var pools = s.pools()
			if pools != null:
				for pid in pools._pools:
					active += pools._pools[pid].active.size()
			r.check("b2_no_leftovers", active == b.client.pooled_count(), "active %d puppets %d" % [active,
				b.client.pooled_count()])
			r.mark("b2_checked")

	r.begin("B7_money_clamp")
	var gs = s.g("GameState")
	var before: String = s.money()
	var w0 := int(s.session.econ_client.local_money_writes)
	gs.add_money(1000)
	await s.tree().physics_frame
	await s.tree().physics_frame
	r.check("b7_reverted_within_a_frame", s.money() == before, "%s -> %s" % [before, s.money()])
	r.check("b7_counted", int(s.session.econ_client.local_money_writes) == w0 + 1, "")
	s.expected_money_writes += 1
	var cr = await s.cmd("PittMultiplayer.contribute", {"seq": 1, "money": "+1"})
	r.check("b7_contribute_unknown", not cr.ok, String(cr.error))
	r.mark("b7_checked")


func _have_all(b, eids: Array) -> bool:
	return _count_have(b, eids) == eids.size()


func _count_have(b, eids: Array) -> int:
	var n := 0
	for e in eids:
		if b.is_replicated(int(e)) and b.node_of(int(e)) != null:
			n += 1
	return n


func _ids_adopted(b, eids: Array) -> bool:
	for e in eids:
		var n = b.node_of(int(e))
		if n == null or int(s.api.entities.id_of(n)) != int(e):
			return false
	return true
