extends "dispenser.gd"
## 0.2.2 co-op checks from the second two-PC Steam test, both sides, paired through
## report marks (driven by scenario_mp2.gd):
##   W1  the manual duck workbench's HUD progress bar is the operator's only: the
##       client crafts (its bar shows, the host's stays hidden), then the host
##       crafts (its bar shows, the client's stays hidden)
##   M1  an open upgrade menu follows another player's purchase live: the client has
##       it open while the host buys through its own row, then the reverse; the
##       viewer's row text (level, price) changes without reopening the menu
##   T1  the client's equipped broom sweeps along the client's facing (it swept to
##       the left): at four yaws the host checks the broom's push axis on the
##       client's rig and that a duck in front of the client moves along its facing
## Marks: w1_*, m1_*, t1_*.

const BAR_GROUP := "WorkbenchProgress"
const T1_YAWS := [0.0, 1.3, 2.6, 4.2]
const T1_PITCH := -0.4
const T1_MAX_ANGLE_DEG := 35.0
const T1_MIN_MOVE_M := 0.2


func _bar() -> Range:
	return tree().get_first_node_in_group(BAR_GROUP) as Range


## Watches `cond_bar` for `ms`: whether the bar was ever visible.
func _bar_seen_for(ms: int) -> bool:
	var bar := _bar()
	var t0 := Time.get_ticks_msec()
	var seen := false
	while Time.get_ticks_msec() - t0 < ms:
		if bar != null and bar.is_visible_in_tree():
			seen = true
		await tree().process_frame
	return seen


func _step_back(from: Vector3, m: float) -> void:
	var p := player()
	if p == null:
		return
	var away := p.global_position - from
	away.y = 0.0
	if away.length() < 0.1:
		away = Vector3(1, 0, 0)
	var to := p.global_position + away.normalized() * m
	await cmd("player.teleport", {"position": [to.x, p.global_position.y, to.z]})
	await sleep_ms(400)


# ---------------------------------------------------------------- W1

func w1_host() -> void:
	report.begin("W1_bench_bar_operator_only")
	var bench := _bench()
	var start := player().global_position if player() != null else Vector3.INF
	if not report.check("w1_bench_and_bar", bench != null and _bar() != null, ""):
		report.mark("w1_ready", {"w1_ok": false})
		return
	report.mark("w1_ready", {"w1_ok": true})
	# a: the client crafts
	var hv: Dictionary = await wait_peer_mark("w1_client_holding", 60.0)
	if report.check("w1_client_holding", not hv.is_empty(), ""):
		var crafting: bool = await wait_for(func(): return bench.get("is_crafting") == true, 5.0)
		var seen: bool = await _bar_seen_for(1000)
		report.check("w1_host_bench_crafts_for_client", crafting, "")
		report.check("w1_host_bar_hidden_while_client_crafts", not seen, "host bar visible during the client's craft")
	report.mark("w1_host_checked_a")
	await wait_peer_mark("w1_client_released", 30.0)
	# b: the host crafts
	var on: bool = await _at_bench(bench)
	report.check("w1_host_ray_on_bench", on, "")
	_hold_lmb(true)
	var crafting2: bool = await wait_for(func(): return bench.get("is_crafting") == true, 5.0)
	var shown: bool = await wait_for(func(): return _bar() != null and _bar().is_visible_in_tree(), 2.0)
	report.check("w1_host_bar_shown_for_own_craft", crafting2 and shown, "crafting %s, bar %s" % [crafting2, shown])
	report.mark("w1_host_holding")
	await wait_peer_mark("w1_client_checked_b", 30.0)
	_hold_lmb(false)
	var hidden: bool = await wait_for(func(): return _bar() == null or not _bar().is_visible_in_tree(), 2.0)
	report.check("w1_host_bar_hidden_after_release", hidden, "")
	await sleep_ms(1500)
	for n in tree().get_nodes_in_group("product"):
		if n is RigidBody3D and n.visible and (n as Node3D).global_position.distance_to(bench.global_position) < 5.0:
			g("ObjectPoolManager").recycle(n)
	if start != Vector3.INF:
		await cmd("player.teleport", {"position": [start.x, start.y, start.z]})
	await sleep_ms(400)
	report.mark("w1_done")


func w1_client() -> void:
	report.begin("W1_bench_bar_operator_only")
	var rv: Dictionary = await wait_peer_mark("w1_ready", 90.0)
	var bench := _bench()
	if not bool(rv.get("w1_ok", false)) or not report.check("w1_bench_and_bar", bench != null and _bar() != null, ""):
		report.mark("w1_client_holding")
		report.mark("w1_client_released")
		report.mark("w1_client_checked_b")
		return
	var b = session.get_module("bodies")
	var known: bool = await wait_for(func(): return int(b.eid_of(bench)) > 0, 10.0)
	report.check("w1_client_bench_replicated", known, "")
	await sleep_ms(800)
	var on: bool = await _at_bench(bench)
	report.check("w1_client_ray_on_bench", on, "")
	var tx0 := gameplay_counter("interact_tx")
	_hold_lmb(true)
	report.mark("w1_client_holding")
	var crafting: bool = await wait_for(func(): return bench.get("is_crafting") == true, 3.0)
	var shown: bool = await wait_for(func(): return _bar().is_visible_in_tree(), 1.0)
	report.value("w1_client_gameplay_counters", session.get_module("gameplay").counters())
	report.check("w1_client_bar_shown_for_own_craft", crafting and shown, "replayed crafting %s, bar %s, interact_tx %d -> %d" % [
		crafting, shown, tx0, gameplay_counter("interact_tx")])
	await wait_peer_mark("w1_host_checked_a", 30.0)
	_hold_lmb(false)
	var hidden: bool = await wait_for(func(): return not _bar().is_visible_in_tree(), 2.0)
	report.check("w1_client_bar_hidden_after_release", hidden, "")
	await _step_back(bench.global_position, 2.5)
	report.mark("w1_client_released")
	await wait_peer_mark("w1_host_holding", 40.0)
	var crafting2: bool = await wait_for(func(): return bench.get("is_crafting") == true, 3.0)
	var seen: bool = await _bar_seen_for(1000)
	report.check("w1_client_sees_host_bench_craft", crafting2, "")
	report.check("w1_client_bar_hidden_while_host_crafts", not seen, "client bar visible during the host's craft")
	await shot("mp2-w1-client-while-host-crafts")
	report.mark("w1_client_checked_b")
	await wait_peer_mark("w1_done", 30.0)


# ---------------------------------------------------------------- M1

func _ui() -> Control:
	return tree().get_first_node_in_group("UpgradeUI") as Control


## Live (not queued) rows of an upgrade item.
func _row_text(ui: Node, key: String) -> String:
	for r in ui.find_children("*", "HBoxContainer", true, false):
		if r.is_queued_for_deletion() or not r.has_meta("label") or String(r.get_meta("category", "")) != "upgrades":
			continue
		if String(r.get_meta("key", "")) == key and String(r.get_meta("subkey", "")) == "":
			var l = r.get_meta("label")
			return (l as Label).text if l is Label and is_instance_valid(l) else ""
	return ""


## An enabled, affordable upgrade row of this peer's menu (rewired on a client).
func _buyable_row(ui: Node, client: bool) -> HBoxContainer:
	for r in ui.find_children("*", "HBoxContainer", true, false):
		if r.is_queued_for_deletion() or String(r.get_meta("category", "")) != "upgrades" or String(r.get_meta("subkey", "")) != "":
			continue
		var b = r.get_meta("button", null)
		if not (b is Button) or (b as Button).disabled:
			continue
		if client and not r.get_meta("pittmp_rewired", false):
			continue
		return r
	return null


func _m1_buy(tag: String, client: bool) -> String:
	var ui := _ui()
	var gs = g("GameState")
	var row := _buyable_row(ui, client)
	if not report.check(tag + "_buyable_row", row != null, ""):
		return ""
	var key := String(row.get_meta("key"))
	var before := int(gs.upgrades[key].level)
	report.mark(tag + "_buying", {"m1_key": key, "m1_before": before})
	await sleep_ms(300)
	(row.get_meta("button") as Button).pressed.emit()
	var ok: bool = await wait_for(func(): return int(gs.upgrades[key].level) == before + 1, 10.0)
	report.check(tag + "_bought", ok, "%s %d -> %d" % [key, before, int(gs.upgrades[key].level)])
	report.mark(tag + "_bought", {"m1_key": key, "m1_level": int(gs.upgrades[key].level)})
	return key


## The viewer: its open menu's row for the key changes without reopening it.
func _m1_watch(tag: String) -> void:
	var ui := _ui()
	var gs = g("GameState")
	var bv: Dictionary = await wait_peer_mark(tag + "_buying", 40.0)
	var key := String(bv.get("m1_key", ""))
	if not report.check(tag + "_buyer_ready", key != "", ""):
		return
	var before := _row_text(ui, key)
	report.check(tag + "_viewer_row_exists", before != "", key)
	var dv: Dictionary = await wait_peer_mark(tag + "_bought", 20.0)
	var lvl := int(dv.get("m1_level", -1))
	var ok: bool = await wait_for(func(): return int(gs.upgrades[key].level) == lvl, 5.0)
	report.check(tag + "_level_mirrored", ok, "%s local %d host %d" % [key, int(gs.upgrades[key].level), lvl])
	var shown: bool = await wait_for(func(): return _row_text(ui, key) != before and _row_text(ui, key) != "", 2.0)
	report.value(tag + "_row_text", {"before": before, "after": _row_text(ui, key)})
	report.check(tag + "_open_menu_row_updated_live", shown and ui.visible, "'%s' -> '%s', menu visible %s" % [before,
		_row_text(ui, key), ui.visible])


func m1_host() -> void:
	report.begin("M1_menu_live_refresh")
	var ui := _ui()
	if not report.check("m1_upgrade_ui", ui != null, ""):
		report.mark("m1a_buying", {})
		report.mark("m1a_bought", {})
		report.mark("m1b_menu_open", {})
		return
	ui.update_ui()
	await wait_peer_mark("m1a_menu_open", 60.0)
	await _m1_buy("m1a", false)
	# c: only money moves (earnings, a tool bought elsewhere): the open menu's credits follow
	await wait_peer_mark("m1a_seen", 20.0)
	await cmd("money.add", {"amount": "12345"})
	report.mark("m1c_paid", {"m1_money": money()})
	await wait_peer_mark("m1a_checked", 20.0)
	ui.show_menu()
	await sleep_ms(800)
	report.mark("m1b_menu_open")
	await _m1_watch("m1b")
	await shot("mp2-m1-host-menu-after-client-buy")
	ui.hide_menu()
	await sleep_ms(500)
	report.mark("m1_done")


func m1_client() -> void:
	report.begin("M1_menu_live_refresh")
	var ui := _ui()
	if not report.check("m1_upgrade_ui", ui != null, ""):
		report.mark("m1a_menu_open")
		report.mark("m1a_checked")
		report.mark("m1b_buying", {})
		report.mark("m1b_bought", {})
		return
	ui.show_menu()
	await sleep_ms(800)
	report.mark("m1a_menu_open")
	await _m1_watch("m1a")
	await shot("mp2-m1-client-menu-after-host-buy")
	var credits = ui.get("credits_label")
	var c0: String = (credits as Label).text if credits is Label else ""
	report.mark("m1a_seen")
	var pv: Dictionary = await wait_peer_mark("m1c_paid", 20.0)
	var ok: bool = await wait_for(func(): return money() == String(pv.get("m1_money", "?")), 3.0)
	var moved: bool = await wait_for(func(): return credits is Label and (credits as Label).text != c0, 2.0)
	report.value("m1c_credits", {"before": c0, "after": (credits as Label).text if credits is Label else ""})
	report.check("m1c_open_menu_credits_follow_money", ok and moved, "money mirrored %s, credits '%s' -> '%s'" % [ok, c0,
		(credits as Label).text if credits is Label else ""])
	ui.hide_menu()
	await sleep_ms(500)
	report.mark("m1a_checked")
	await wait_peer_mark("m1b_menu_open", 30.0)
	ui.update_ui()
	await frame()
	await _m1_buy("m1b", true)
	await wait_peer_mark("m1_done", 30.0)


# ---------------------------------------------------------------- T1

func _client_peer() -> int:
	return int(session.peer_of_slot(2)) if session.has_method("peer_of_slot") else 2


func t1_host() -> void:
	report.begin("T1_broom_sweep_direction")
	var gs = g("GameState")
	gs.upgrades["equip"]["level"] = maxi(1, int(gs.upgrades["equip"]["level"]))
	var pose: Dictionary = session.avatar_pose(_client_peer())
	if not report.check("t1_client_pose", bool(pose.get("ok", false)), ""):
		report.mark("t1_ready", {"t1_eid": 0})
		return
	var fwd := Vector3(0, 0, -1).rotated(Vector3.UP, float(pose.yaw))
	var at: Vector3 = Vector3(pose.pos) + fwd * 1.2 + Vector3(0, 0.3, 0)
	var r = await cmd("entity.spawn", {"pool_id": "tool_broom", "position": [at.x, at.y, at.z]})
	var eid := int(r.value.get("entity_id", 0)) if r.ok and typeof(r.value) == TYPE_DICTIONARY else 0
	var grab = session.get_module("grab")
	var broom = session.get_module("bodies").node_of(eid) if eid > 0 else null
	if not report.check("t1_broom_spawned", broom != null, str(r.error) if not r.ok else ""):
		report.mark("t1_ready", {"t1_eid": 0})
		return
	await sleep_ms(1000)
	report.mark("t1_ready", {"t1_eid": eid})
	var ev: Dictionary = await wait_peer_mark("t1_equipped", 30.0)
	var ok: bool = await wait_for(func(): return grab.owner_of(eid) == _client_peer() and grab.hold_kind(eid) == "equipped", 3.0)
	if not report.check("t1_host_sees_equipped", not ev.is_empty() and ok, "owner %d kind %s" % [grab.owner_of(eid), grab.hold_kind(eid)]):
		report.mark("t1_end")
		return
	var rig: Camera3D = session.get_module("gameplay").rig_of(_client_peer())
	var results: Array = []
	for i in T1_YAWS.size():
		var tag := "t1_%d" % i
		report.mark(tag + "_pose", {"t1_yaw": T1_YAWS[i]})
		await wait_peer_mark(tag + "_posed", 20.0)
		var want := float(T1_YAWS[i])
		# the avatar stream carries the new yaw a little later than the mark
		var turned: bool = await wait_for(func():
			var ps: Dictionary = session.avatar_pose(_client_peer())
			return absf(angle_difference(float(ps.get("yaw", 99.0)), want)) < 0.05, 3.0)
		report.check(tag + "_client_turned", turned, "avatar yaw %.2f, want %.2f" % [float(session.avatar_pose(_client_peer()).get("yaw", 0.0)), want])
		await sleep_ms(300)
		pose = session.avatar_pose(_client_peer())
		var face := Vector3(0, 0, -1).rotated(Vector3.UP, want)
		if rig != null:
			var push: Vector3 = (broom as Node3D).global_transform.basis.z.normalized()
			var look := -rig.global_transform.basis.z.normalized()
			report.value(tag + "_push_dot_look", push.dot(look))
			report.check(tag + "_broom_pushes_where_rig_looks", push.dot(look) > 0.9, "dot %.2f" % push.dot(look))
		var floor_y := float(pose.pos.y) - 0.975
		var dp: Vector3 = Vector3(pose.pos) + face * 2.6
		dp.y = floor_y + 0.15
		var dr = await cmd("entity.spawn", {"pool_id": "duck", "position": [dp.x, dp.y, dp.z]})
		var duck = session.get_module("bodies").node_of(int(dr.value.get("entity_id", 0))) if dr.ok and typeof(dr.value) == TYPE_DICTIONARY else null
		await sleep_ms(900)
		if duck == null:
			report.check(tag + "_duck", false, "")
			report.mark(tag + "_duck", {})
			continue
		var p0: Vector3 = (duck as Node3D).global_position
		report.mark(tag + "_duck", {"t1_duck": int(api.entities.id_of(duck))})
		await wait_peer_mark(tag + "_swept", 20.0)
		await sleep_ms(1000)
		var mv: Vector3 = (duck as Node3D).global_position - p0
		mv.y = 0.0
		var ang := rad_to_deg(mv.normalized().angle_to(Vector3(face.x, 0, face.z).normalized())) if mv.length() > 0.001 else 180.0
		results.append({"yaw": snappedf(want, 0.01), "moved_m": snappedf(mv.length(), 0.01), "angle_deg": snappedf(ang, 0.1)})
		report.check(tag + "_duck_moves_along_client_facing", mv.length() >= T1_MIN_MOVE_M and ang <= T1_MAX_ANGLE_DEG,
			"yaw %.2f: moved %.2f m at %.1f deg from the facing" % [want, mv.length(), ang])
		if is_instance_valid(duck) and duck.visible:
			g("ObjectPoolManager").recycle(duck)
	report.value("t1_results", results)
	report.mark("t1_end")
	await wait_peer_mark("t1_client_done", 20.0)
	if is_instance_valid(broom) and broom.visible and grab.hold_kind(eid) == "":
		g("ObjectPoolManager").recycle(broom)


func t1_client() -> void:
	report.begin("T1_broom_sweep_direction")
	var rv: Dictionary = await wait_peer_mark("t1_ready", 90.0)
	var eid := int(rv.get("t1_eid", 0))
	var b = session.get_module("bodies")
	var grab = session.get_module("grab")
	var cam = tree().get_first_node_in_group("main_camera")
	if not report.check("t1_host_ready", eid > 0, ""):
		report.mark("t1_client_done")
		return
	await wait_for(func(): return b.node_of(eid) != null, 3.0)
	var broom = b.node_of(eid)
	var gs = g("GameState")
	await wait_for(func(): return int(gs.upgrades["equip"]["level"]) > 0, 3.0)
	face((broom as Node3D).global_position)
	await sleep_ms(200)
	cam._begin_carry(broom)
	await wait_for(func(): return grab.is_mine(eid), 2.0)
	# the game's equip key (main_camera.handle_input: equip_item.equip(main_camera))
	await tree().physics_frame
	Input.action_press("equip")
	await tree().physics_frame
	await tree().physics_frame
	Input.action_release("equip")
	var ok: bool = await wait_for(func(): return cam.equipped_item == broom and grab.hold_kind(eid) == "equipped", 3.0)
	if not report.check("t1_client_equipped", ok, "equipped %s kind %s level %d" % [str(cam.equipped_item), grab.hold_kind(eid),
			int(gs.upgrades["equip"]["level"])]):
		report.mark("t1_equipped")
		report.mark("t1_client_done")
		return
	report.mark("t1_equipped")
	for i in T1_YAWS.size():
		var tag := "t1_%d" % i
		var pv: Dictionary = await wait_peer_mark(tag + "_pose", 30.0)
		if pv.is_empty():
			break
		player().rotation.y = float(pv.get("t1_yaw", 0.0))
		cam.rotation.x = T1_PITCH
		await sleep_ms(500)
		report.mark(tag + "_posed")
		var dv: Dictionary = await wait_peer_mark(tag + "_duck", 20.0)
		var de := int(dv.get("t1_duck", 0))
		if de > 0:
			await wait_for(func(): return b.node_of(de) != null, 2.0)
			await sleep_ms(200)
		# the game's interact key: main_camera._do_interact -> broom.interact (forwarded)
		await tree().physics_frame
		Input.action_press("interact")
		await tree().physics_frame
		await tree().physics_frame
		Input.action_release("interact")
		await sleep_ms(100)
		report.mark(tag + "_swept")
	await wait_peer_mark("t1_end", 60.0)
	# put the broom back in the world
	if cam.equipped_item == broom:
		await tree().physics_frame
		Input.action_press("equip")
		await tree().physics_frame
		await tree().physics_frame
		Input.action_release("equip")
		await sleep_ms(300)
	if cam.picked_object == broom:
		cam.call("release_held_object")
	await sleep_ms(500)
	report.check("t1_client_put_broom_down", cam.equipped_item == null and cam.picked_object == null, "equipped %s held %s" % [
		str(cam.equipped_item), str(cam.picked_object)])
	report.mark("t1_client_done")
