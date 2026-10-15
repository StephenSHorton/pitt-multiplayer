extends SceneTree
## Second process of test_mp_net_two_process (real ENet over localhost).
##   godot --headless --path <test project> -s res://tests/fakes/mp_net/peer2_main.gd --
##         --pittapi-instance=peer2 --port=<n> --report=<abs path>
## 1. joins with a wrong mods_hash -> expects ended("mods")
## 2. joins properly -> in_game via the snapshot, money.add round trip, econ,
##    avatar stream, then waits for the host to leave -> ended("host_left")
## Writes a JSON report the main test process reads.

const Session = preload("res://gamedir/mods/PittMultiplayer/net/session.gd")
const FakeApi = preload("res://tests/fakes/mp_net/fake_api.gd")
const StubLobby = preload("res://tests/fakes/mp_net/stub_lobby.gd")
const FakeAdapter = preload("res://tests/fakes/mp_net/fake_game_adapter.gd")
const VERSION := {"pitt_version": "1.0.8", "pittapi_version": "1.1.0", "mp_proto": 1, "mods_hash": "abcd1234abcd1234"}


class Runner extends Node:
	var port := 0
	var report_path := ""
	var rep := {"finished": false, "steps": {}}

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		_run.call_deferred()

	func _write() -> void:
		var f := FileAccess.open(report_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(rep))
			f.close()

	func _step(name: String, v: Variant) -> void:
		rep.steps[name] = v
		_write()

	func _sleep(sec: float) -> void:
		await get_tree().create_timer(sec).timeout

	func _wait(cond: Callable, s: float) -> bool:
		var t0 := Time.get_ticks_msec()
		while not cond.call():
			if Time.get_ticks_msec() - t0 > int(s * 1000.0):
				return false
			await get_tree().process_frame
		return true

	func _peer(name: String, version: Dictionary) -> Array:
		var api = FakeApi.new(name)
		var lobby = StubLobby.new()
		lobby.local_name = name
		add_child(lobby)
		var ad = FakeAdapter.new(name, get_tree())
		ad.api = api
		var s = Session.new(api, lobby, ad, {"version": version, "data_dir": api.data_dir()})
		add_child(s)
		var ended: Array = []
		s.ended.connect(func(r, d): ended.append(r))
		lobby.enter({"is_owner": false}, {"kind": "enet", "role": "client", "address": "127.0.0.1", "port": port})
		return [api, lobby, ad, s, ended]

	func _run() -> void:
		rep["pid"] = OS.get_process_id()
		_step("started", true)
		# 1. mismatch
		var bad_v := VERSION.duplicate()
		bad_v.mods_hash = "ffffffffffffffff"
		var b := _peer("mismatch", bad_v)
		var ok: bool = await _wait(func(): return not b[4].is_empty(), 10.0)
		_step("mismatch_ended", b[4][0] if ok else "timeout")
		await _sleep(0.5)
		# 2. proper join
		var p := _peer("peer2", VERSION)
		var s = p[3]
		var ad = p[2]
		ok = await _wait(func(): return s.get_state() == "in_game", 30.0)
		_step("in_game", ok)
		_step("peer_id", s.my_peer)
		_step("money_after_join", ad.get_money())
		var r = p[0].commands.execute("money.add", {"amount": 7})
		await _wait(func(): return r.done, 10.0)
		_step("cmd_round_trip", r.ok)
		ad.avatar = {"pos": Vector3(4, 5, 6), "yaw": 0.25, "pitch": 0.0, "vel": Vector3.ZERO}
		ok = await _wait(func(): return ad.get_money() == "999", 10.0)
		_step("econ_money_999", ok)
		ad.fgs().add_money(1)      # a local write: MP2 reverts it (money clamp), the host never sees it
		ok = await _wait(func(): return ad.get_money() == "999", 5.0)
		_step("local_income_reverted", ok)
		ok = await _wait(func(): return s.avatars.get_puppet(1) != null, 10.0)
		_step("host_puppet", ok)
		ok = await _wait(func(): return not p[4].is_empty(), 30.0)
		_step("ended", p[4][0] if ok else "timeout")
		rep.finished = true
		_write()
		await _sleep(0.3)
		get_tree().quit(0)


func _initialize() -> void:
	var r := Runner.new()
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if s.begins_with("--port="):
			r.port = s.trim_prefix("--port=").to_int()
		elif s.begins_with("--report="):
			r.report_path = s.trim_prefix("--report=")
	root.add_child.call_deferred(r)
	create_timer(60.0).timeout.connect(func(): quit(2))
