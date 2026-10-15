extends "../scenario_base.gd"
## MP2 GRAB loopback scenarios, host side (MP2-DESIGN 11.2 G1-G6). Driven by
## the MP2 harness (scenario_mp2.gd, BODIES) once both peers are in the shared
## world: `await run_grab(ids)`. Every step is paired with grab_client.gd
## through report marks ("g<n>_*"); every check is about what THIS instance sees.
## G5 (disconnect) ends the client's session, so it runs last.

const ORDER := ["G1", "G3", "G2", "G4", "G6", "G5"]
const CLIENT_SLOT := 2

var _changes: Array = []        # [unix_ms, eid, owner, kind, epoch]


func grab() -> Object:
	return session.get_module("grab") if session.has_method("get_module") else null


func bodies() -> Object:
	return session.get_module("bodies") if session.has_method("get_module") else null


func client_peer() -> int:
	return int(session.peer_of_slot(CLIENT_SLOT)) if session.has_method("peer_of_slot") else 2


func run_grab(ids: Array = ORDER) -> void:
	if not report.check("grab_module_present", grab() != null and bodies() != null, ""):
		return
	grab().owner_changed.connect(func(eid, o, k, e): _changes.append([Report.unix_ms(), eid, o, k, e]))
	for id in ORDER:
		if id in ids:
			await call("_" + String(id).to_lower())
	report.mark("grab_host_done")


## A duck 1.5 m in front of the client's avatar (it falls onto the floor there).
func _spawn_for_client() -> int:
	var pose: Dictionary = session.avatar_pose(client_peer())
	if not bool(pose.get("ok", false)):
		return 0
	var fwd := Vector3(0, 0, -1).rotated(Vector3.UP, float(pose.yaw))
	var at: Vector3 = pose.pos + fwd * 1.5 + Vector3(0, 0.6, 0)
	var r = await cmd("entity.spawn", {"pool_id": "duck", "position": [at.x, at.y, at.z]})
	var eid := int(r.value.get("entity_id", 0)) if r.ok and typeof(r.value) == TYPE_DICTIONARY else 0
	await sleep_ms(800)          # settle; BODIES streams it to the client
	return eid


func _node(eid: int) -> Node3D:
	return bodies().node_of(eid) as Node3D if bodies() != null else null


func _last_change(eid: int) -> Array:
	for i in range(_changes.size() - 1, -1, -1):
		if int(_changes[i][1]) == eid:
			return _changes[i]
	return []


# ---------------------------------------------------------------- G1 grab + throw, the host sees it land

func _g1() -> void:
	report.begin("G1_grab_throw")
	var eid := await _spawn_for_client()
	if not report.check("g1_spawned", eid > 0, ""):
		return
	var e0: int = grab().epoch_of(eid)
	report.mark("g1_ready", {"g1_eid": eid})
	var held: Dictionary = await wait_peer_mark("g1_holding", 20.0)
	if not report.check("g1_client_holding", not held.is_empty(), ""):
		return
	report.check("g1_host_table_owner", grab().owner_of(eid) == client_peer() and grab().hold_kind(eid) == "held",
		"owner %d kind %s" % [grab().owner_of(eid), grab().hold_kind(eid)])
	await sleep_ms(150)
	var cp := Vector3(float(held.g1_pos[0]), float(held.g1_pos[1]), float(held.g1_pos[2]))
	var n := _node(eid)
	var d := n.global_position.distance_to(cp) if n != null else 99.0
	report.value("g1_follow_err_m", d)
	report.check("g1_host_copy_follows_10cm", d <= 0.10, "%.3f m" % d)
	var rel: Dictionary = await wait_peer_mark("g1_released", 20.0)
	report.check("g1_client_released", not rel.is_empty(), "")
	var ok: bool = await wait_for(func(): return grab().owner_of(eid) == 1 and grab().hold_kind(eid) == "", 3.0)
	report.check("g1_back_to_host", ok, "")
	report.check("g1_epoch_plus_2", grab().epoch_of(eid) == e0 + 2, "%d -> %d" % [e0, grab().epoch_of(eid)])
	var rb := _node(eid) as RigidBody3D
	report.check("g1_host_body_dynamic", rb != null and not rb.freeze, "")
	await sleep_ms(2500)
	var land := _node(eid).global_position if _node(eid) != null else Vector3.ZERO
	report.mark("g1_landed", {"g1_land": [land.x, land.y, land.z]})
	await shot("mp2-g1-host-sees-landing")


# ---------------------------------------------------------------- G3 deny a body a machine owns

func _g3() -> void:
	report.begin("G3_deny")
	var eid := await _spawn_for_client()
	if not report.check("g3_spawned", eid > 0, ""):
		return
	var n := _node(eid)
	n.set_meta("consumed", true)       # host-only: the maw is eating it
	report.mark("g3_ready", {"g3_eid": eid})
	var done: Dictionary = await wait_peer_mark("g3_done", 20.0)
	report.check("g3_client_done", not done.is_empty(), "")
	report.check("g3_still_host", grab().owner_of(eid) == 1 and grab().hold_kind(eid) == "", "")
	var c: Dictionary = grab().counters()
	report.check("g3_denied_busy", int(c.get("grab_deny_reasons", {}).get("busy", 0)) >= 1, str(c.get("grab_deny_reasons", {})))
	n.remove_meta("consumed")


# ---------------------------------------------------------------- G2 race: both grab at the same instant

func _g2() -> void:
	report.begin("G2_race")
	var eid := await _spawn_for_client()
	if not report.check("g2_spawned", eid > 0, ""):
		return
	# the host player must be in reach too (the game drops a carry that is too far away)
	var dn := _node(eid)
	var pose: Dictionary = session.avatar_pose(client_peer())
	if dn != null and bool(pose.get("ok", false)):
		var away: Vector3 = dn.global_position - Vector3(pose.pos)
		away.y = 0
		var hp: Vector3 = dn.global_position + away.normalized() * 1.4
		await cmd("player.teleport", {"position": [hp.x, float(pose.pos.y), hp.z]})
		await sleep_ms(400)
		face(dn.global_position)
	var at := Report.unix_ms() + 2500
	report.mark("g2_ready", {"g2_eid": eid, "g2_at": at})
	while Report.unix_ms() < at:
		await tree().process_frame
	var cam = tree().get_first_node_in_group("main_camera")
	var n := _node(eid) as RigidBody3D
	if cam != null and n != null:
		cam._begin_carry(n)
	var t_host := Report.unix_ms()
	await sleep_ms(1500)
	var host_holds: bool = cam != null and cam.picked_object == n
	var res: Dictionary = await wait_peer_mark("g2_result", 20.0)
	var client_holds := bool(res.get("g2_client_holds", false))
	report.value("g2_skew_ms", absi(t_host - int(res.get("g2_t", t_host))))
	report.check("g2_exactly_one_owner", host_holds != client_holds, "host %s client %s" % [host_holds, client_holds])
	var owner: int = grab().owner_of(eid)
	report.check("g2_table_matches", (owner == 1) == host_holds, "owner %d" % owner)
	if host_holds and cam != null:
		cam.call("release_held_object")
	report.mark("g2_end")
	await sleep_ms(500)


# ---------------------------------------------------------------- G4 owner silence revokes after 1.5 s

func _g4() -> void:
	report.begin("G4_silence")
	var eid := await _spawn_for_client()
	if not report.check("g4_spawned", eid > 0, ""):
		return
	report.mark("g4_ready", {"g4_eid": eid})
	var p: Dictionary = await wait_peer_mark("g4_paused", 20.0)
	if not report.check("g4_client_paused", not p.is_empty(), ""):
		return
	var ok: bool = await wait_for(func(): return grab().hold_kind(eid) == "", 4.0)
	var ch := _last_change(eid)
	var dt := int(ch[0]) - int(p.get("g4_paused_ms", 0)) if not ch.is_empty() else -1
	report.value("g4_revoke_after_ms", dt)
	report.check("g4_revoked_1500_pm_200", ok and dt >= 1300 and dt <= 1700, "%d ms" % dt)
	report.check("g4_reason_silence", int(grab().counters().get("grab_revoke_reasons", {}).get("silence", 0)) >= 1, "")
	report.mark("g4_revoked")


# ---------------------------------------------------------------- G6 the client opens the pause menu while holding

func _g6() -> void:
	report.begin("G6_pause_release")
	var eid := await _spawn_for_client()
	if not report.check("g6_spawned", eid > 0, ""):
		return
	report.mark("g6_ready", {"g6_eid": eid})
	var p: Dictionary = await wait_peer_mark("g6_paused", 20.0)
	report.check("g6_client_paused", not p.is_empty(), "")
	var ok: bool = await wait_for(func(): return grab().owner_of(eid) == 1 and grab().hold_kind(eid) == "", 3.0)
	report.check("g6_released_normally", ok, "")
	var rb := _node(eid) as RigidBody3D
	report.check("g6_body_dynamic", rb != null and not rb.freeze, "")
	report.mark("g6_end")


# ---------------------------------------------------------------- G5 disconnect while holding

func _g5() -> void:
	report.begin("G5_disconnect")
	var eid := await _spawn_for_client()
	if not report.check("g5_spawned", eid > 0, ""):
		return
	report.mark("g5_ready", {"g5_eid": eid})
	var h: Dictionary = await wait_peer_mark("g5_leaving", 20.0)
	report.check("g5_client_leaving", not h.is_empty(), "")
	var ok: bool = await wait_for(func(): return grab().hold_kind(eid) == "", 5.0)
	report.check("g5_revoked_on_leave", ok, "")
	report.check("g5_reason_left", int(grab().counters().get("grab_revoke_reasons", {}).get("left", 0)) >= 1, "")
	var rb := _node(eid) as RigidBody3D
	var y0 := rb.global_position.y if rb != null else 0.0
	report.check("g5_body_dynamic", rb != null and not rb.freeze, "")
	await sleep_ms(1000)
	report.value("g5_dy", (rb.global_position.y - y0) if rb != null else 0.0)
	report.mark("g5_end")
