extends "res://tests/test_case.gd"
## Regression tests for the MP1 review fixes: BigInt money, contributions
## gone in MP2 (3.8), the ready/xfer check,
## snapshot chunks that overtake snap_begin, Steam lobby membership, the
## UnlockManager check_milestones block, the secret-ending pause exemption,
## ghost puppets, the host marking its lobby ending, and late purchase grants.

const MpRig = preload("res://tests/fakes/mp_net/mp_rig.gd")
const Loopback = preload("res://gamedir/mods/PittMultiplayer/net/transport_loopback.gd")
const PauseGuard = preload("res://gamedir/mods/PittMultiplayer/world/pause_guard.gd")
const SteamSignals = preload("res://gamedir/mods/PittMultiplayer/lobby/steam_signals.gd")

var rig = null


## Loopback endpoint that reports itself as Steam with SteamID-like platform ids.
class SteamLikeLoopback extends Loopback:
	func kind() -> String:
		return "steam"

	func platform_id_of(peer_id: int) -> String:
		return str(76561190000000000 + peer_id)


func _new_rig() -> void:
	if rig != null:
		await rig.cleanup()
	rig = MpRig.new(tree, runner)


func after_all() -> void:
	if rig != null:
		await rig.cleanup()


func _in_game(p) -> Callable:
	return func(): return p.session.get_state() == "in_game"


func test_huge_money_is_one_bigint_operation() -> void:
	await _new_rig()
	var h = rig.add_host({}, 1)
	await rig.until(_in_game(h))
	h.adapter.fgs().set_money_int(5)
	var huge := "1" + "0".repeat(29)
	var t0 := Time.get_ticks_msec()
	h.adapter.add_money_digits(huge)
	assert_true(Time.get_ticks_msec() - t0 < 200, "1e29 added without a per-1e18 loop")
	assert_eq(h.adapter.get_money(), "1" + "0".repeat(28) + "5", "exact BigInt sum")
	var spent: String = h.adapter.spend_floor_digits("1" + "0".repeat(40))
	assert_eq(spent, "1" + "0".repeat(28) + "5", "spend floors at the money there is")
	assert_eq(h.adapter.get_money(), "0", "money at 0")
	h.adapter.add_money_digits("12")
	assert_eq(h.adapter.get_money(), "12", "small amounts still go through add_money")


## MP2 3.8 replaces review fixes #4, #5 and #11 (contribution resend, feed
## budget, floored fine): clients send no money or feeding at all any more, so
## nothing can be counted twice or flooded; the host is the only earner.
func test_contributions_are_gone() -> void:
	await _new_rig()
	var h = rig.add_host({}, 1)
	await rig.until(_in_game(h))
	var c = rig.add_client("c")
	await rig.until(_in_game(c), 5.0)
	assert_true(h.api.commands.describe("PittMultiplayer.contribute").is_empty(), "no contribute command on the host")
	assert_false(c.session.has_method("ext_feed"), "no client feeding hook")
	assert_false("contributions" in c.session, "no contributions module")
	h.adapter.fgs().set_money_int(1000)
	await rig.until(func(): return c.adapter.get_money() == "1000", 3.0)
	c.adapter.fgs().add_money(250)    # a payout in the client's copy of the world
	await rig.ms(300)
	assert_eq(h.adapter.get_money(), "1000", "a client-local payout never reaches the shared wallet")
	assert_eq(c.adapter.get_money(), "1000", "and is reverted on the client (money clamp, P5)")


func test_ready_needs_a_served_snapshot() -> void:
	await _new_rig()
	var h = rig.add_host({}, 1)
	await rig.until(_in_game(h))
	var c = rig.add_client()
	await rig.until(_in_game(c), 5.0)
	var peer: int = c.session.my_peer
	h.session.roster.set_state(peer, "connected")
	h.session._host_on_ready(peer, 777)
	assert_eq(h.session.roster.state_of(peer), "connected", "ready without being served is ignored")
	h.session.roster.set_state(peer, "in_game")


func test_chunks_before_snap_begin() -> void:
	await _new_rig()
	# CH_CONTROL (snap_begin) arrives 400 ms after CH_BULK (the chunks)
	rig.hub.channel_delay_ms = {0: 400}
	var h = rig.add_host({}, 1)
	await rig.until(_in_game(h))
	var c = rig.add_client()
	var ok: bool = await rig.until(_in_game(c), 10.0)
	rig.hub.channel_delay_ms = {}
	assert_true(ok, "the join completes when chunks overtake snap_begin (state %s)" % c.session.get_state())
	assert_true(int(c.session.counters.early_chunks) > 0, "chunks really arrived first and were buffered")


func test_steam_peer_must_be_lobby_member() -> void:
	await _new_rig()
	var host_cfg := {"transport_factory": func(_k): return SteamLikeLoopback.new()}
	var h = rig.add_host(host_cfg, 1)
	h.session.member_wait_ms = 300
	await rig.until(_in_game(h))
	var host_sid := str(76561190000000000 + 1)
	h.lobby._members = [{"id": host_sid, "name": "HostPersona", "is_owner": true, "is_self": true}]
	# a stranger who knows the host's SteamID but is not in the lobby
	var stranger = rig.add_client("evil")
	await rig.until(func(): return not stranger.ended.is_empty(), 5.0)
	assert_eq(h.session.get_roster().size(), 1, "a non-member is never admitted")
	assert_true(not stranger.ended.is_empty() and String(stranger.ended.back()[0]) == "protocol",
		"refused (protocol): %s" % str(stranger.ended))
	# a friend in the lobby, whose hello claims another name
	var friend_peer: int = rig.hub.next_peer
	var fsid := str(76561190000000000 + friend_peer)
	h.lobby._members.append({"id": fsid, "name": "FriendPersona", "is_owner": false, "is_self": false})
	var f = rig.add_client("ImpersonatedName")
	var ok: bool = await rig.until(_in_game(f), 5.0)
	assert_true(ok, "a lobby member is admitted")
	assert_eq(String(h.session.roster.name_of(friend_peer)), "FriendPersona", "the name comes from the lobby, never the hello")
	# the friend leaves the Steam lobby: removed from the session too
	h.lobby._members = [h.lobby._members[0]]
	h.lobby.members_changed.emit(h.lobby.get_members())
	ok = await rig.until(func(): return h.session.get_roster().size() == 1, 3.0)
	assert_true(ok, "a peer whose SteamID left the lobby is kicked")


func test_check_milestones_blocked_on_clients() -> void:
	await _new_rig()
	var h = rig.add_host({}, 1)
	await rig.until(_in_game(h))
	var c = rig.add_client()
	await rig.until(_in_game(c), 5.0)
	var um = c.adapter.fum()
	assert_true(c.adapter.milestones_blocked(), "milestones carry the block requirement")
	c.adapter.fgs().total_money_gained.add_int(1000)
	um.check_milestones()   # e.g. pickaxe.gd:257 calls it directly
	assert_false("unlock_luck" in um.unlocked_milestones, "a direct check_milestones unlocks nothing on a client")
	c.adapter.force_unlock("unlock_fan")
	assert_true("unlock_fan" in um.unlocked_milestones, "the host's unlocks still apply (force_unlock)")
	c.session.leave()
	assert_false(c.adapter.milestones_blocked(), "restored at teardown")
	assert_false(um.milestones.unlock_luck.has("requires"), "original requires restored")


func test_pause_guard_exempts_end_screen() -> void:
	await _new_rig()
	var h = rig.add_host({}, 1)
	await rig.until(_in_game(h))
	var mm = h.adapter.nodes.MenuManager
	var end_menu := CanvasLayer.new()
	end_menu.set_script(load("res://tests/fakes/mp_net/end_menu_stub.gd"))
	runner.add_child(end_menu)
	mm.current_menu = end_menu
	assert_true(h.adapter.end_screen_open(), "an end-of-game menu is detected")
	var g = h.session.pause_guard
	assert_true(g._exempt(), "the secret ending's end screen keeps its pause")
	mm.current_menu = null
	end_menu.queue_free()
	assert_false(g._exempt(), "not exempt otherwise")


func test_no_ghost_puppet_for_departed_slot() -> void:
	await _new_rig()
	var h = rig.add_host({}, 1)
	await rig.until(_in_game(h))
	var c = rig.add_client()
	await rig.until(_in_game(c), 5.0)
	var av = c.session.avatars
	var before: int = av.puppet_count()
	av.on_frame(1, {"slot": 9, "pos": Vector3.ZERO, "yaw": 0.0, "pitch": 0.0, "vel": Vector3.ZERO, "t": 0}, PackedByteArray())
	assert_eq(av.puppet_count(), before, "a frame for a slot nobody holds creates no puppet")


func test_host_marks_lobby_ending_before_leaving() -> void:
	await _new_rig()
	var h = rig.add_host({}, 1)
	await rig.until(_in_game(h))
	h.session.leave()
	assert_eq(String(h.lobby.states.back()) if not h.lobby.states.is_empty() else "", "ending",
		"lobby state ending (not joinable) before leave: %s" % str(h.lobby.states))


func test_late_grant_spawns_the_item() -> void:
	await _new_rig()
	var h = rig.add_host({}, 1)
	await rig.until(_in_game(h))
	var c = rig.add_client()
	await rig.until(_in_game(c), 5.0)
	var p = c.session.purchases
	var ui = c.adapter.upgrade_ui()
	assert_true(ui != null, "fake upgrade UI")
	var spawned_before: int = ui.spawned_toys.size() if "spawned_toys" in ui else -1
	p._late[4242] = {"kind": "toy", "args": {"toy": "bumper"}}
	assert_true(p.on_grant({"id": 4242, "toy": "bumper"}), "a grant for a timed-out purchase spawns it")
	if spawned_before >= 0:
		assert_eq(ui.spawned_toys.size(), spawned_before + 1, "spawned in the buyer's world")
	assert_false(p.on_grant({"id": 4242, "toy": "bumper"}), "only once")
	p._waiting[5555] = true
	p._late[5555] = {"kind": "toy", "args": {"toy": "bumper"}}
	assert_false(p.on_grant({"id": 5555}), "a pending result spawns it instead")
	p._waiting.clear()
	p._late.clear()


func test_join_game_requested_connect_string() -> void:
	assert_eq(SteamSignals.connect_lobby_of([76561190000000002, "+connect_lobby 109775241234567890"]), "109775241234567890",
		"lobby id from the rich-presence connect string")
	assert_eq(SteamSignals.connect_lobby_of([1, ""]), "", "no id")
	assert_true(SteamSignals.SIGNALS.has("join_game_requested"), "join_game_requested is connected")
