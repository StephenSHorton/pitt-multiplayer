extends "../scenario_base.gd"
## MP2 two-instance harness (MP2-DESIGN 11.2), armed with role "mp2" and
## side "host" | "client" (tools/test-mp-loopback.ps1 -Suite mp2). Opens the
## host world / joins it like the MP1 scenario, then runs the stream scenario
## files in order (BODIES: bodies_host.gd / bodies_client.gd; GAMEPLAY and
## GRAB add theirs). flag.scenario = "<id>" runs one scenario id only (B1...).
## Every run ends with the 11.2 end checks on the client: strays only from the
## expected sources, orphan frames <= 1 %, no local money writes beyond the
## expected ones.

const BodiesHost = preload("bodies_host.gd")
const BodiesClient = preload("bodies_client.gd")
const GameplayHost = preload("gameplay_host.gd")
const GameplayClient = preload("gameplay_client.gd")
const GrabHost = preload("grab_host.gd")
const GrabClient = preload("grab_client.gd")
const Dispenser = preload("dispenser.gd")
const Coop = preload("coop_checks.gd")
const GAMEPLAY_IDS := ["P8", "P2", "P3", "P12", "P10", "P11", "P1"]
const GRAB_IDS := ["G1", "G3", "G2", "G4", "G6", "G10"]    # G5 (leaves the session) runs after the end checks

const JOIN_TIMEOUT_S := 240.0

var side := ""
var only := ""
var expected_money_writes := 0
var _join_pos := Vector3.INF


func run() -> void:
	side = String(flag.get("side", "host"))
	only = String(flag.get("scenario", ""))
	report.value("suite", "mp2")
	report.value("side", side)
	if side == "host":
		if not await _host_open():
			return
		await BodiesHost.new().run(self)
		if wants("V1"):
			await _v1_host()
		await _sub(GameplayHost).run_gameplay(_ids(GAMEPLAY_IDS))
		if wants("D1"):
			await _sub(Dispenser).run_host()
		if wants("W1"):
			await _sub(Coop).w1_host()
		if wants("M1"):
			await _sub(Coop).m1_host()
		# the host spawns the test bodies at the client's avatar: wait until it stands still
		await wait_peer_mark("client_positioned_grab", 120.0)
		await sleep_ms(500)
		await _sub(GrabHost).run_grab(_ids(GRAB_IDS))
		if wants("B6"):
			await _b6_host()
		# T1 after B6: on a headless client the equipped broom floods the log with display
		# server errors (2 per frame), which skews B6's timing measurements
		if wants("T1"):
			await wait_peer_mark("client_positioned_t1", 120.0)
			await sleep_ms(500)
			await _sub(Coop).t1_host()
		# H1 (end): the client's HUD money label shows this value
		await wait_peer_mark("hud_money_req", 120.0)
		report.mark("hud_money_host", {"hud_money": money()})
		await wait_peer_mark("mp2_end_checked", 60.0)
		if wants("G5"):
			await wait_peer_mark("client_positioned_g5", 120.0)
			await sleep_ms(500)
			await _sub(GrabHost).run_grab(["G5"])
	elif side == "client2":
		# 3-instance run: a passive second client (B4 late join after client 1, B1/B2 seen
		# from a third peer, both other avatars), then the end checks
		if not await _client_join():
			return
		await BodiesClient.new().run(self)
		_check_other_avatars()
		await wait_peer_mark("grab_host_done", 900.0)
		# it is in the session during P10 and P1 too: hud.show_result pays each mirrored
		# combo out locally (GameState.add_bonus) and the money clamp reverts it
		expected_money_writes += _ids(["P10", "P1"]).size()
		_end_checks()
		report.mark("mp2_end_checked")
	else:
		if not await _client_join():
			return
		await BodiesClient.new().run(self)
		if wants("V1"):
			await _v1_client()
		await _sub(GameplayClient).run_gameplay(_ids(GAMEPLAY_IDS))
		if wants("D1"):
			await _sub(Dispenser).run_client()
		if wants("W1"):
			await _sub(Coop).w1_client()
		if wants("M1"):
			await _sub(Coop).m1_client()
		# P10 and P1 each end a combo: the mirrored combo_ended reaches hud.show_result, which
		# pays the bonus out locally (GameState.add_bonus); the money clamp reverts it in the
		# same frame (MP2 P5; the host pays once)
		expected_money_writes += _ids(["P10", "P1"]).size()
		await _to_open_floor()
		report.mark("client_positioned_grab")
		await _sub(GrabClient).run_grab(_ids(GRAB_IDS))
		if wants("B6"):
			await _b6_client()
		if wants("T1"):
			await _to_open_floor()
			report.mark("client_positioned_t1")
			await _sub(Coop).t1_client()
		report.mark("hud_money_req")
		var hm: Dictionary = await wait_peer_mark("hud_money_host", 60.0)
		await _check_hud_money("h1_end", String(hm.get("hud_money", "")))
		_end_checks()
		report.mark("mp2_end_checked")
		if wants("G5"):
			await _to_open_floor()
			report.mark("client_positioned_g5")
			await _sub(GrabClient).run_grab(["G5"])
	report.mark("mp2_done")
	# the other side may still be checking: give it time before the session ends
	await wait_peer_mark("mp2_done", 60.0)
	await sleep_ms(500)


## A stream's scenario file (extends scenario_base.gd) sharing this run's report and flag.
func _sub(script: Script) -> Object:
	var sc = script.new()
	sc.setup(node, api, mp, report, flag)
	return sc


## The ids of one stream's list that this run wants (flag.scenario).
func _ids(all: Array) -> Array:
	return all.filter(func(i): return wants(String(i)))


## Whether scenario id should run (flag.scenario).
func wants(id: String) -> bool:
	return only == "" or only == id or id in only.split(",")


func bodies():
	return session.get_module("bodies")


func pools() -> Object:
	return g("ObjectPoolManager")


func _host_open() -> bool:
	report.begin("mp2_0_host_world")
	await suppress_steam()
	var r = await cmd("save.isolate", {"enabled": true, "path": api.pittapi_dir().path_join("test/mp_host.save")})
	report.check("save_isolated", r.ok, r.error)
	report.check("mp2_modules", session.get_module("bodies") != null, "modules %s" % str(session.dump().get("mp2", {})))
	lobby.host()
	var ok: bool = await wait_for(func(): return session.get_state() == "lobby", 10.0)
	if not report.check("lobby_hosted", ok, "state %s" % session.get_state()):
		return false
	report.mark("lobby_ready", {"address": lobby.transport_target().get("address", ""), "port": lobby.transport_target().get("port", 0)})
	report.check("start_game", session.start_game() == OK, "")
	var menu = tree().get_first_node_in_group("MainMenu")
	g("GameState").sandbox_mode = false
	g("GameProgression").reset_run_state()
	g("GameProgression").current_phase = 1
	g("SaveManager").pending_camera_data = {}
	g("SaveManager").should_load_on_ready = false
	menu._pending_new_game = true
	session.notify_host_launch("res://scenes/world.tscn")
	menu._launch_game("res://scenes/world.tscn")
	ok = await wait_for(func(): return session.get_state() == "in_game" and session.world_live(), 180.0)
	if not report.check("host_open", ok, "state %s host_state %s world %s" % [session.get_state(), session.host_state,
			session.world_live()]):
		return false
	await cmd("money.set", {"amount": "5000000"})
	await sleep_ms(1000)
	report.mark("world_open", {"money": money(), "phase": phase()})
	return true


func _client_join() -> bool:
	report.begin("mp2_0_join")
	await suppress_steam()
	var lv: Dictionary = await wait_peer_mark("lobby_ready", 120.0)
	if not report.check("host_lobby_ready", not lv.is_empty(), ""):
		return false
	# the host may pre-populate its world before we join (B4)
	var gate := String(flag.get("join_after", "join_now"))
	var wv: Dictionary = await wait_peer_mark(gate, 300.0)
	report.check("host_ready_for_join", not wv.is_empty(), gate)
	var id := "dev:%s:%d" % [String(flag.get("address", "127.0.0.1")), int(flag.get("port", 27450))]
	var t_join := Time.get_ticks_msec()
	var ended: Array = []
	session.ended.connect(func(r, d): ended.append([r, d]))
	lobby.join(id)
	var ok: bool = await wait_for(func(): return session.get_state() == "in_game" and session.world_live(), JOIN_TIMEOUT_S)
	if not report.check("in_game", ok, "state %s after %d ms (%s)" % [session.get_state(), Time.get_ticks_msec() - t_join,
			str(ended)]):
		return false
	report.value("join_ms", Time.get_ticks_msec() - t_join)
	await sleep_ms(300)
	_join_pos = player().global_position if player() != null else Vector3.INF
	report.mark("client_in_game", {"money": money(), "phase": phase()})
	if side == "client":
		var wo: Dictionary = await wait_peer_mark("world_open", 5.0)
		await _check_hud_money("h1_join", String(wo.get("money", "")))
	return true


## H1: the game's own HUD money label (hud.gd $Money, fed by GameState.money_updated)
## is drawn and shows the host's money (the second real Steam report: "the client
## couldn't see the money").
func _check_hud_money(tag: String, host_digits: String) -> void:
	var gs = g("GameState")
	var hud := tree().get_first_node_in_group("HUD")
	var label = hud.get_node_or_null("Money") if hud != null else null
	if not report.check(tag + "_hud_money_label", label is Label, "hud %s" % str(hud)):
		return
	var want := ""
	if gs != null and gs.money != null and host_digits.is_valid_int():
		want = "%s$" % gs.format_big_number(gs.money.get_script().from_string(host_digits))
	var ok: bool = await wait_for(func(): return want != "" and (label as Label).text == want, 3.0)
	var l := label as Label
	report.value(tag + "_hud_money", {"text": l.text, "want": want, "host": host_digits, "local": money()})
	report.check(tag + "_hud_money_shows_host_value", ok, "label %s, host %s (%s), local %s" % [l.text, want,
		host_digits, money()])
	var on_screen := l.get_global_rect().intersects(Rect2(Vector2.ZERO, l.get_viewport_rect().size))
	var n: Node = l
	while n != null:
		if n is CanvasLayer and not (n as CanvasLayer).visible:
			on_screen = false
		n = n.get_parent()
	report.check(tag + "_hud_money_visible", l.is_visible_in_tree() and l.modulate.a > 0.5
		and l.self_modulate.a > 0.5 and on_screen and l.get_global_rect().size.x > 1.0, "visible %s alpha %.2f on screen %s rect %s" % [
		l.is_visible_in_tree(), l.modulate.a, on_screen, str(l.get_global_rect())])
	report.check(tag + "_game_started", gs != null and gs.get("is_game_started") == true, "GameState.is_game_started %s" % str(
		gs.get("is_game_started") if gs != null else null))
	await shot(tag + "-hud-money")


## 11.2 end checks (client).
func _end_checks() -> void:
	report.begin("mp2_end")
	var b = bodies()
	if b == null:
		report.check("bodies_module", false, "")
		return
	var c: Dictionary = b.counters()
	report.value("client_counters", c)
	report.check("no_unexpected_strays", int(c.get("stray_spawns", 0)) == 0, "stray_spawns %d by pool %s" % [
		int(c.get("stray_spawns", 0)), str(b.stray.by_pool)])
	var rx := maxi(1, int(c.get("records_rx", 0)))
	var orph := int(c.get("orphan_frames", 0))
	report.check("orphan_frames_le_1pct", float(orph) / float(rx) <= 0.01, "%d orphan of %d records" % [orph, rx])
	var lmw := int(session.econ_client.local_money_writes)
	# reverted local writes: B7's test write plus the client's own ComboSystem paying out a
	# mirrored combo when it ends (P10, P1); the host pays the combo once, the clamp undoes the copy
	report.value("money_reverts", session.econ_client.reverts if "reverts" in session.econ_client else [])
	report.check("local_money_writes_expected", lmw <= expected_money_writes, "%d (expected <= %d)" % [lmw,
		expected_money_writes])
	report.check("tick_60", Engine.physics_ticks_per_second == 60, str(Engine.physics_ticks_per_second))


# ---------------------------------------------------------------- V1 avatars stay visible, never block the view

const HOST_SLOT := 1
const CLIENT_SLOT := 2


## Checks the other player's puppet from this camera: drawn, opaque, in view, at range.
func _check_puppet_in_view(tag: String, slot: int) -> void:
	var pup = puppet(slot)
	var cam := tree().root.get_viewport().get_camera_3d()
	if not report.check(tag + "_puppet_exists", pup != null and cam != null, ""):
		return
	var d: float = pup.axis_distance(cam.global_position)
	report.value(tag + "_distance_m", d)
	report.check(tag + "_puppet_drawn", pup.visible and pup.body.visible and pup.body.transparency < 0.05,
		"visible %s body %s transparency %.2f" % [pup.visible, pup.body.visible, pup.body.transparency])
	report.check(tag + "_puppet_in_view", cam.is_position_in_frustum(pup.global_position), "")
	report.check(tag + "_distance_2_to_6m", d >= 2.0 and d <= 6.0, "%.2f m" % d)
	report.check(tag + "_name_label", pup.label != null and pup.label.visible and pup.label.text != "", "")
	# the face plate is small and light (the old dark visor bar is gone)
	var vm = pup.visor.material_override if pup.visor != null else null
	report.check(tag + "_face_plate_small_light", pup.visor != null and (pup.visor.mesh as BoxMesh).size.x <= 0.3
		and vm != null and vm.albedo_color.v > 0.7, "")


## Nothing of the multiplayer layer is drawn within 0.5 m of the local camera.
func _check_nothing_at_camera(tag: String) -> void:
	var cam := tree().root.get_viewport().get_camera_3d()
	var bad: Array = []
	for slot in [HOST_SLOT, CLIENT_SLOT]:
		var pup = puppet(slot)
		if pup == null or not pup.visible:
			continue
		for m in [pup.body, pup.visor]:
			if m != null and m.visible and m.transparency < 0.99 and (m.global_position.distance_to(cam.global_position) < 0.5
					or pup.axis_distance(cam.global_position) < 0.5):
				bad.append("%s/%s" % [pup.name, m.name])
	report.check(tag + "_nothing_drawn_at_camera", bad.is_empty(), str(bad))
	report.check(tag + "_main_camera_current", cam != null and cam.is_in_group("main_camera"),
		str(cam.get_path()) if cam != null else "none")


func _v1_host() -> void:
	report.begin("V1_avatar_view_host")
	var peer := int(session.peer_of_slot(CLIENT_SLOT))
	var pose: Dictionary = session.avatar_pose(peer)
	if not report.check("v1_client_pose", bool(pose.get("ok", false)), ""):
		report.mark("v1_host_done", {})
		return
	var cpos: Vector3 = pose.pos
	var fwd := Vector3(0, 0, -1).rotated(Vector3.UP, float(pose.yaw))
	var spot := open_spot(cpos, fwd, [3.5, 3.0, 2.6, 4.0])
	if spot == Vector3.INF:
		spot = open_spot(cpos, -fwd, [3.5, 3.0, 2.6, 4.0])
	if spot == Vector3.INF:
		spot = open_spot(cpos, fwd.cross(Vector3.UP), [3.5, 3.0, 2.6, 4.0])
	report.check("v1_found_spot", spot != Vector3.INF, "")
	if spot != Vector3.INF:
		await cmd("player.teleport", {"position": [spot.x, spot.y, spot.z]})
	await sleep_ms(700)
	face(cpos + Vector3(0, 0.3, 0))
	await sleep_ms(500)
	_check_puppet_in_view("v1_host", CLIENT_SLOT)
	_check_nothing_at_camera("v1_host")
	await shot("mp2-v1-host-sees-client")
	var hp := player().global_position
	report.mark("v1_host_done", {"v1_host_pos": [hp.x, hp.y, hp.z]})
	await wait_peer_mark("v1_client_done", 60.0)


func _v1_client() -> void:
	report.begin("V1_avatar_view_client")
	var hv: Dictionary = await wait_peer_mark("v1_host_done", 60.0)
	var hpa: Array = hv.get("v1_host_pos", [])
	if not report.check("v1_host_ready", hpa.size() == 3, ""):
		report.mark("v1_client_done")
		return
	var hp := Vector3(float(hpa[0]), float(hpa[1]), float(hpa[2]))
	await sleep_ms(400)
	var pup = puppet(HOST_SLOT)
	face((pup.global_position if pup != null else hp) + Vector3(0, 0.3, 0))
	await sleep_ms(500)
	_check_puppet_in_view("v1_client", HOST_SLOT)
	_check_nothing_at_camera("v1_client")
	await shot("mp2-v1-client-sees-host")
	# walk into the host: its puppet must hide instead of filling the view
	var back := player().global_position
	var into := hp + (back - hp).normalized() * 0.3
	await cmd("player.teleport", {"position": [into.x, hp.y, into.z]})
	await sleep_ms(600)
	face(hp + (hp - back).normalized() * 3.0)
	await sleep_ms(300)
	pup = puppet(HOST_SLOT)
	var cam := tree().root.get_viewport().get_camera_3d()
	if pup != null and cam != null:
		var d: float = pup.axis_distance(cam.global_position)
		report.value("v1_inside_distance_m", d)
		report.check("v1_inside_puppet_hidden", d > 0.9 or not pup.body.visible, "axis %.2f m, body visible %s" % [d,
			pup.body.visible])
	_check_nothing_at_camera("v1_inside")
	await shot("mp2-v1-client-inside-host")
	await cmd("player.teleport", {"position": [back.x, back.y, back.z]})
	await sleep_ms(500)
	report.mark("v1_client_done")


# ---------------------------------------------------------------- B6 moving bodies under 100 ms +- 30 / 5 % loss

const B6_COUNT := 50


func _b6_cond() -> Dictionary:
	return flag.get("conditioning", {"latency_ms": 100, "jitter_ms": 30, "loss": 0.05})


func _b6_host() -> void:
	report.begin("B6_conditioned")
	var b = bodies()
	var peer := int(session.peer_of_slot(CLIENT_SLOT))
	var full: int = b.budget_bps(peer)
	session.set_conditioning(_b6_cond())
	report.mark("b6_host_conditioned", {"b6_cond": _b6_cond()})
	await wait_peer_mark("b6_client_conditioned", 30.0)
	await sleep_ms(1000)
	# 50 ducks thrown up in front of the client's avatar
	var pose: Dictionary = session.avatar_pose(peer)
	var c: Vector3 = pose.get("pos", player().global_position)
	var fwd := Vector3(0, 0, -1).rotated(Vector3.UP, float(pose.get("yaw", 0.0)))
	var right := fwd.cross(Vector3.UP)
	var ducks: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in B6_COUNT:
		var at: Vector3 = c + fwd * (3.0 + (i / 10) * 0.5) + right * ((i % 10) - 5) * 0.45 + Vector3(0, 0.5, 0)
		var d = pools().spawn("duck", at)
		if d != null:
			ducks.append(d)
	await tree().physics_frame
	for d in ducks:
		(d as RigidBody3D).apply_central_impulse(Vector3(rng.randf_range(-1.5, 1.5), rng.randf_range(3, 5), rng.randf_range(-1.5, 1.5)))
	await tree().physics_frame
	var eids: Array = []
	for d in ducks:
		eids.append(int(api.entities.id_of(d)))
	report.mark("b6_spawned", {"b6_eids": eids})
	# host history: every second physics frame for 4 s, stamped with the host clock
	var hist := {}
	for e in eids:
		hist[str(e)] = []
	var min_budget := full
	var t0 := Time.get_ticks_msec()
	var k := 0
	while Time.get_ticks_msec() - t0 < 4000:
		await tree().physics_frame
		k += 1
		min_budget = mini(min_budget, b.budget_bps(peer))
		if k % 2 != 0:
			continue
		var t := int(session.host_now())
		for d in ducks:
			if is_instance_valid(d):
				var gp: Vector3 = d.global_position
				hist[str(int(api.entities.id_of(d)))].append([t, snappedf(gp.x, 0.001), snappedf(gp.y, 0.001), snappedf(gp.z, 0.001)])
	report.mark("b6_hist", {"b6_hist": hist})
	# most come to rest within 15 s (a few can keep rolling on other bodies); the rest
	# check uses the sleeping ones only
	var asleep := func() -> int:
		var n := 0
		for d in ducks:
			if is_instance_valid(d) and (d as RigidBody3D).sleeping:
				n += 1
		return n
	var rested: bool = await wait_for(func(): return asleep.call() >= int(ducks.size() * 0.7), 15.0)
	report.check("b6_came_to_rest_70pct", rested, "%d of %d asleep" % [asleep.call(), ducks.size()])
	var rest := {}
	for d in ducks:
		if is_instance_valid(d) and (d as RigidBody3D).sleeping:
			rest[str(int(api.entities.id_of(d)))] = [d.global_position.x, d.global_position.y, d.global_position.z]
	report.mark("b6_rest", {"b6_rest": rest})
	await wait_peer_mark("b6_client_checked", 40.0)
	for t in 5:
		min_budget = mini(min_budget, b.budget_bps(peer))
		await sleep_ms(1000)
	report.value("b6_budget", {"full": full, "min_under_conditioning": min_budget})
	report.check("b6_budget_adapted_down", min_budget < full, "full %d min %d" % [full, min_budget])
	session.set_conditioning({})
	report.mark("b6_host_clean")
	var ok: bool = await wait_for(func(): return b.budget_bps(peer) >= full, 15.0)
	report.check("b6_budget_recovered_15s", ok, "budget %d of %d" % [b.budget_bps(peer), full])
	for d in ducks:
		if is_instance_valid(d) and d.visible:
			pools().recycle(d)
	await wait_peer_mark("b6_client_done", 30.0)


func _b6_client() -> void:
	report.begin("B6_conditioned")
	var b = bodies()
	await wait_peer_mark("b6_host_conditioned", 120.0)
	session.set_conditioning(_b6_cond())
	report.mark("b6_client_conditioned")
	var sv: Dictionary = await wait_peer_mark("b6_spawned", 30.0)
	var eids: Array = sv.get("b6_eids", [])
	# what this screen shows, stamped with the host time each pose represents
	var seen := {}
	var t0 := Time.get_ticks_msec()
	var prev_rt := -1
	while Time.get_ticks_msec() - t0 < 4500:
		# SceneTree.physics_frame fires BEFORE this tick's _physics_process: the poses read
		# here were written by the replicator in the previous tick, for that tick's render time
		await tree().physics_frame
		var rt_now := int(session.host_now()) - int(b.client.interp_delay)
		var rt := prev_rt
		prev_rt = rt_now
		if rt < 0:
			continue
		for e in eids:
			var n = b.node_of(int(e))
			if n != null and not b.is_local_sim(int(e)):
				if not seen.has(e):
					seen[e] = []
				seen[e].append([rt, n.global_position])
	var hv: Dictionary = await wait_peer_mark("b6_hist", 30.0)
	var hist: Dictionary = hv.get("b6_hist", {})
	var errs: Array = []
	for e in seen:
		var h: Array = hist.get(str(int(e)), [])
		if h.size() < 2:
			continue
		for smp in seen[e]:
			var t := int(smp[0])
			if t < int(h[0][0]) or t > int(h.back()[0]):
				continue
			for i in range(h.size() - 1):
				if t >= int(h[i][0]) and t <= int(h[i + 1][0]):
					var span := maxf(1.0, float(int(h[i + 1][0]) - int(h[i][0])))
					var w := float(t - int(h[i][0])) / span
					var a := Vector3(float(h[i][1]), float(h[i][2]), float(h[i][3]))
					var bb := Vector3(float(h[i + 1][1]), float(h[i + 1][2]), float(h[i + 1][3]))
					errs.append((smp[1] as Vector3).distance_to(a.lerp(bb, w)))
					break
	errs.sort()
	var p95: float = errs[mini(errs.size() - 1, int(errs.size() * 0.95))] if not errs.is_empty() else 99.0
	report.value("b6_moving_err", {"samples": errs.size(), "p50": errs[errs.size() / 2] if not errs.is_empty() else -1.0, "p95": p95})
	report.check("b6_moving_p95_le_25cm", errs.size() > 100 and p95 <= 0.25, "p95 %.3f m over %d samples" % [p95, errs.size()])
	var rv: Dictionary = await wait_peer_mark("b6_rest", 40.0)
	var rest: Dictionary = rv.get("b6_rest", {})
	await sleep_ms(3000)
	var worst := 0.0
	var missing := 0
	for k in rest:
		var n = b.node_of(int(String(k)))
		if n == null:
			missing += 1
			continue
		worst = maxf(worst, (n.global_position as Vector3).distance_to(Vector3(float(rest[k][0]), float(rest[k][1]), float(rest[k][2]))))
	report.value("b6_rest_worst_m", worst)
	report.check("b6_rest_within_1cm_after_3s", missing == 0 and worst <= 0.01 and not rest.is_empty(), "worst %.4f m, %d missing" % [
		worst, missing])
	await shot("mp2-b6-client-conditioned-at-rest")
	report.mark("b6_client_checked")
	await wait_peer_mark("b6_host_clean", 30.0)
	session.set_conditioning({})
	report.mark("b6_client_done")


## client2: the host's and client 1's puppets exist and are drawn.
func _check_other_avatars() -> void:
	report.begin("V2_three_players")
	await sleep_ms(500)
	for slot in [HOST_SLOT, CLIENT_SLOT]:
		var pup = puppet(slot)
		report.check("v2_puppet_slot%d" % slot, pup != null and pup.visible and pup.frames_rx > 0, "")
	await shot("mp2-v2-client2-view")


## Client: back to where it joined (beside the host's start spot, away from the benches
## and the maw), so the host's test bodies land on a flat floor in front of us.
func _to_open_floor() -> void:
	var p := player()
	if p == null:
		return
	var spot: Vector3 = _join_pos if _join_pos != Vector3.INF else p.global_position
	await cmd("player.teleport", {"position": [spot.x, spot.y, spot.z]})
	await sleep_ms(800)
