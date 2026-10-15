extends RefCounted
## MP2 gate (MP2-DESIGN 1.1). Every GAMEPLAY extension does
##     const G = preload("../../gameplay/mp_gate.gd")
## and starts each overridden method with one gate call. Outside a session every
## gate passes (single player unchanged, H-SP1); on the host every gate passes.
## On a client:
##   sink           always blocks
##   replay         blocks, except while BODIES/GAMEPLAY apply host state (api.net.is_applying())
##   input          blocks; inside the input scope the call is first forwarded to the
##                  host as interact / tool_in (the host runs the same method)
##   input_predict  like input, but inside the input scope it then PASSES (local feedback;
##                  the method's own mutators are gated themselves)
## The input scope is set only around the game's input dispatchers
## (main_camera.handle_input/_do_interact/_input/_handle_dpad_context,
## interact_ray._input/handle_*, golf_club._input),
## so a gated method reached from inside them was caused by the local player and
## anything else on a client was caused by a local machine copy.
##
## The gameplay module (gameplay.gd) installs itself in `gp` while a session runs.
## No game members are touched here; extensions call game code by name only.

## gameplay module while a session is live (duck typed: gate_live, gate_role,
## gate_applying, forward_input, ...), else null
static var gp: Object = null
## host: the peer a host_exec call runs for (0 = not inside host_exec)
static var exec_peer: int = 0
static var _scope: int = 0


static func live() -> bool:
	return gp != null and is_instance_valid(gp) and bool(gp.gate_live())


static func is_client() -> bool:
	return live() and String(gp.gate_role()) == "client"


static func is_host() -> bool:
	return live() and String(gp.gate_role()) == "host"


static func applying() -> bool:
	return live() and bool(gp.gate_applying())


static func in_input_scope() -> bool:
	return _scope > 0


## true = return early (the host's copy does it)
static func sink(_node: Object) -> bool:
	return is_client()


static func replay(_node: Object) -> bool:
	return is_client() and not bool(gp.gate_applying())


static func input(node: Object, verb: String, arg = null) -> bool:
	if not is_client():
		return false
	if bool(gp.gate_applying()):
		return false
	if _scope > 0:
		gp.forward_input(node, verb, _args(arg))
	return true


static func input_predict(node: Object, verb: String, arg = null) -> bool:
	if not is_client():
		return false
	if bool(gp.gate_applying()):
		return false
	if _scope > 0:
		gp.forward_input(node, verb, _args(arg))
		return false
	return true


static func begin_input_scope() -> void:
	_scope += 1


static func end_input_scope() -> void:
	_scope = maxi(_scope - 1, 0)


static func reset() -> void:
	gp = null
	exec_peer = 0
	_scope = 0


static func _args(arg) -> Array:
	if arg == null:
		return []
	if typeof(arg) == TYPE_ARRAY:
		return arg
	return [arg]


# ================================================================== helpers for extensions
# (all no-ops outside a session)

## The local player body (PlayerController is the only node in group "player";
## host ghosts of remote players are never in it, MP2 6.5).
static func is_local_player(body: Object) -> bool:
	return body != null and is_instance_valid(body) and body is Node and (body as Node).is_in_group("player")


## Client: a local player branch charged money (reverted by the money clamp);
## the host charges once (MP2 6.8).
static func penalty(kind: String) -> void:
	if is_client():
		gp.send_penalty(kind)


## Host: one-shot cosmetic effect for every client (MP2 6.12). args JSON-safe.
static func fx(kind: String, node: Object = null, args: Dictionary = {}) -> void:
	if is_host():
		gp.fx_emit(kind, node, args)


## Host: a world-event achievement unlocked in host-only code.
static func ach(id: String) -> void:
	if is_host():
		gp.fx_emit("ach", null, {"id": id})


## Host: after an interaction or a state change worth pushing now.
static func host_after(node: Object, _what: String = "") -> void:
	if is_host():
		gp.host_after(node)


## Host: the game consumed / captured `body`; a remote owner loses it (MP2 5.4).
static func consumed(body: Object, reason: String) -> void:
	if is_host():
		gp.host_consumed(body, reason)


## Host: owned (held or equipped) by a remote peer.
static func remote_owned(node: Object) -> bool:
	return is_host() and bool(gp.remote_owned(node))


## Host: a teleport (no interpolated streak on clients).
static func mark_snap(node: Object) -> void:
	if is_host():
		gp.mark_snap(node)


## Host bench holder set (MP2 4.4). start: records the holder.
static func bench_hold(node: Object) -> void:
	if is_host():
		gp.bench_hold(node, _holder_peer())


## Hold-to-craft start (MP2 4.4), for every bench's start_crafting. true = return.
## Client: as input (interact_client sends one start per hold, however often
## interact_ray calls it before the replayed is_crafting arrives).
## Host: records the holder; while the bench already crafts (another player
## holds craft too), a second start does not reset its progress.
static func bench_start(node: Object) -> bool:
	if is_host():
		bench_hold(node)
		return node.get("is_crafting") == true
	return input(node, "start_crafting")


## Hold-to-craft stop input. true = return.
static func bench_stop(node: Object) -> bool:
	return input(node, "stop_crafting")


## Client: a start was sent for this bench and its stop is still pending (the
## replayed is_crafting may not have arrived: interact_ray only stops a bench
## whose is_crafting is true).
static func bench_requested(node: Object) -> bool:
	return is_client() and node != null and is_instance_valid(node) and bool(gp.interact_client.holding(node))


## Host: false = another player still holds craft, keep crafting.
static func bench_release(node: Object) -> bool:
	if not is_host():
		return true
	return bool(gp.bench_release(node, _holder_peer()))


static func _holder_peer() -> int:
	if exec_peer > 0:
		return exec_peer
	return 1 if _scope > 0 else 0


## Host: the ghost collider of a remote player (or null).
static func ghost_peer(body: Object) -> int:
	if body == null or not is_instance_valid(body) or not (body is Node):
		return 0
	return int((body as Node).get_meta("pitt_mp_ghost_peer", 0))


## Host: an impulse for a remote player's own body (qa_arm whack).
static func remote_impulse(peer: int, v: Vector3, src: String) -> void:
	if is_host() and peer > 1:
		gp.player_impulse(peer, v, src)


## Client: an explicit forward with custom arguments (only from the input scope,
## or for a local-player event such as the loop puzzle's run end).
static func forward(node: Object, verb: String, args: Array = []) -> void:
	if is_client() and not bool(gp.gate_applying()):
		gp.forward_input(node, verb, args)


## The replicated id of a node (0 outside a session or when not replicated).
static func eid(node: Object) -> int:
	return int(gp.eid_of(node)) if live() else 0


## A GameState member by name (extensions never name autoload members statically).
static func gs(name: String, default_value = null):
	if gp != null and is_instance_valid(gp) and gp.adapter != null:
		return gp.adapter.gs_get(name, default_value)
	var t := Engine.get_main_loop() as SceneTree
	var n = t.root.get_node_or_null("GameState") if t != null else null
	return n.get(name) if n != null and name in n else default_value


## GameProgression.ending_active (the phase-5 suction takes players without a fine).
static func ending_active() -> bool:
	var t := Engine.get_main_loop() as SceneTree
	var prog = t.root.get_node_or_null("GameProgression") if t != null else null
	return prog != null and prog.get("ending_active") == true


## Host: the safety stat for a remote player's accident (qa_arm whack).
static func safety_violation() -> void:
	if is_host():
		gp.adapter.record_safety_violation()


## Bowling pins are fixture bodies with per-generation keys (MP2 4.6).
static func pins_spawned(set_node: Object) -> void:
	if live():
		gp.fixtures.pins_spawned(set_node)


static func pins_despawned(set_node: Object) -> void:
	if live():
		gp.fixtures.pins_despawned(set_node)


## Host: the terminal spawned a fixture (press / trading / bowling set) (MP2 6.1).
static func fixture_spawned(key: String, level: int) -> void:
	if is_host():
		gp.host_fixture_spawned(key, level)


## Client: rack a panel / take one from the rack through the host (MP2 6.11).
static func rack_store(panel: Object) -> bool:
	return is_client() and bool(gp.rack.client_store(panel))


static func rack_withdraw() -> bool:
	return is_client() and bool(gp.rack.client_withdraw())


## Client: recall a tool on the host (MP2 6.1).
static func recall(tool_name: String) -> void:
	if is_client() and gp.api != null and "commands" in gp.api:
		gp.api.commands.execute(gp.CMD_RECALL, {"tool": tool_name})
