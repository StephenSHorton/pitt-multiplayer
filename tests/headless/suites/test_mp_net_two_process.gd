extends "res://tests/test_case.gd"
## A second headless Godot (OS.create_process, --pittapi-instance=peer2) joins
## this process's host over REAL ENet localhost: reject on mismatch, handshake,
## snapshot join, cmd round trip, econ between two fake adapters, avatar stream
## both ways, host leave. Skipped (with a pass + note) where processes cannot spawn.

const Session = preload("res://gamedir/mods/PittMultiplayer/net/session.gd")
const FakeApi = preload("res://tests/fakes/mp_net/fake_api.gd")
const StubLobby = preload("res://tests/fakes/mp_net/stub_lobby.gd")
const FakeAdapter = preload("res://tests/fakes/mp_net/fake_game_adapter.gd")
const VERSION := {"pitt_version": "1.0.8", "pittapi_version": "1.1.0", "mp_proto": 1, "mods_hash": "abcd1234abcd1234"}


func _wait(cond: Callable, s: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - t0 > int(s * 1000.0):
			return false
		await tree.process_frame
	return true


func _read(p: String) -> Dictionary:
	if not FileAccess.file_exists(p):
		return {}
	var d = JSON.parse_string(FileAccess.get_file_as_string(p))
	return d if typeof(d) == TYPE_DICTIONARY else {}


func test_two_processes_over_enet() -> void:
	var port := 28100 + (Time.get_ticks_msec() % 500)
	var api = FakeApi.new("host2p")
	var lobby = StubLobby.new()
	lobby.local_name = "host2p"
	runner.add_child(lobby)
	var ad = FakeAdapter.new("host2p", tree)
	ad.api = api
	api.adapter = ad
	var s = Session.new(api, lobby, ad, {"version": VERSION, "data_dir": api.data_dir()})
	runner.add_child(s)
	lobby.enter({"is_owner": true, "owner_id": "enet:1"}, {"kind": "enet", "role": "host", "address": "127.0.0.1", "port": port})
	assert_eq(s.get_state(), "lobby", "host listening on %d" % port)
	s.start_game()
	s.notify_host_launch("res://scenes/world.tscn")
	ad.fgs().set_money_int(992)
	ad.enter_world(1, runner)
	await _wait(func(): return s.get_state() == "in_game", 3.0)
	assert_eq(s.get_state(), "in_game", "host open")
	ad.avatar = {"pos": Vector3(1, 1, 1), "yaw": 0.0, "pitch": 0.0, "vel": Vector3.ZERO}
	var report := ProjectSettings.globalize_path("user://peer2_report_%d.json" % port)
	DirAccess.remove_absolute(report)
	var args := ["--headless", "--path", ProjectSettings.globalize_path("res://"), "-s", "res://tests/fakes/mp_net/peer2_main.gd",
		"--", "--pittapi-instance=peer2", "--port=%d" % port, "--report=%s" % report]
	var pid := OS.create_process(OS.get_executable_path(), args)
	if pid <= 0:
		assert_true(true, "cannot spawn processes here: skipped")
		s.leave()
		s.queue_free()
		lobby.queue_free()
		ad.free_all()
		return
	var ok: bool = await _wait(func(): return bool(_read(report).get("steps", {}).get("in_game", false)), 45.0)
	var rep := _read(report)
	assert_true(rep.get("steps", {}).has("started"), "peer2 started: %s" % str(rep))
	assert_eq(String(rep.get("steps", {}).get("mismatch_ended", "")), "mods", "mods mismatch rejected across processes")
	assert_true(ok, "peer2 joined through the snapshot over ENet: %s" % str(rep))
	ok = await _wait(func(): return ad.get_money() == "999", 15.0)
	assert_true(ok, "cmd money.add (+7) reached the host: %s" % ad.get_money())
	assert_eq(api.money_adds.size(), 1, "money.add ran on the host")
	ok = await _wait(func(): return s.avatars.puppet_count() == 1, 10.0)
	assert_true(ok, "the host sees peer2's avatar")
	ok = await _wait(func(): return bool(_read(report).get("steps", {}).get("host_puppet", false)), 10.0)
	assert_true(ok, "peer2 sees the host's avatar")
	rep = _read(report)
	assert_true(bool(rep.steps.get("cmd_round_trip", false)), "cmd round trip ok")
	assert_true(bool(rep.steps.get("econ_money_999", false)), "econ mirrored to the other process")
	assert_true(bool(rep.steps.get("local_income_reverted", false)), "a client-local payout is reverted (MP2 P5)")
	assert_eq(ad.get_money(), "999", "and never reaches the host")
	s.leave()
	ok = await _wait(func(): return bool(_read(report).get("finished", false)), 15.0)
	rep = _read(report)
	assert_true(ok, "peer2 finished")
	assert_eq(String(rep.get("steps", {}).get("ended", "")), "host_left", "host leave seen as host_left")
	if OS.is_process_running(pid):
		OS.kill(pid)
	s.queue_free()
	lobby.queue_free()
	ad.free_all()
	DirAccess.remove_absolute(report)
	await wait_frames(2)
