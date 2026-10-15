extends RefCounted
## Penalties (MP2-DESIGN 6.8). A client's own player branch that charges money
## (maw fine, fail-safe) runs locally for its respawn effect; the money clamp
## reverts the local charge and the client sends PittMultiplayer.penalty {kind}.
## Host: one per peer per DEDUPE_MS, ignored within JOIN_GRACE_MS of the peer's
## ready (a joiner can land in a fail-safe while its world settles);
##   maw       -> spend(_maw_fine()) + record_safety_violation() + reset_combo()  (D9)
##   fail_safe -> spend(1) + reset_combo()

const CMD := "PittMultiplayer.penalty"
const KINDS := ["maw", "fail_safe"]
const DEDUPE_MS := 2000
const JOIN_GRACE_MS := 5000

var gp = null
var _ready_ms: Dictionary = {}      # peer -> ms of world ready
var _last_ms: Dictionary = {}       # peer -> ms of the last applied penalty
var _ctr := {"penalties_applied": 0, "penalties_dedup": 0, "penalties_grace": 0, "penalties_sent": 0}
## clock override for tests
var now_fn: Callable = Callable()


func _init(p_gp) -> void:
	gp = p_gp


func counters() -> Dictionary:
	return _ctr.duplicate()


func clear() -> void:
	_ready_ms.clear()
	_last_ms.clear()


func _now() -> int:
	return int(now_fn.call()) if now_fn.is_valid() else Time.get_ticks_msec()


func on_peer_ready(peer: int) -> void:
	_ready_ms[peer] = _now()


func on_peer_left(peer: int) -> void:
	_ready_ms.erase(peer)
	_last_ms.erase(peer)


## Client.
func client_send(kind: String) -> void:
	if gp.api == null or not ("commands" in gp.api) or gp.api.commands == null:
		return
	gp.api.commands.execute(CMD, {"kind": kind})
	_ctr.penalties_sent += 1


## Host command handler.
func cmd_penalty(args: Dictionary, ctx) -> Variant:
	if gp.role != "host" or not gp.gate_live():
		return ctx.fail("penalties need the host's running world", "ERR_UNAVAILABLE")
	var kind := String(args.get("kind", ""))
	if not (kind in KINDS):
		return ctx.fail("unknown penalty '%s'" % kind, "ERR_INVALID")
	var peer := int(ctx.origin_peer) if ctx.is_remote else 1
	if peer <= 1:
		return ctx.fail("penalties come from clients", "ERR_DENIED")
	return apply(peer, kind)


## {applied: bool, reason?} (tests call it directly).
func apply(peer: int, kind: String) -> Dictionary:
	var now := _now()
	if _ready_ms.has(peer) and now - int(_ready_ms[peer]) < JOIN_GRACE_MS:
		_ctr.penalties_grace += 1
		gp.count("penalties_ignored")
		return {"applied": false, "reason": "join_grace"}
	if _last_ms.has(peer) and now - int(_last_ms[peer]) < DEDUPE_MS:
		_ctr.penalties_dedup += 1
		gp.count("penalties_ignored")
		return {"applied": false, "reason": "dedupe"}
	_last_ms[peer] = now
	var a = gp.adapter
	match kind:
		"maw":
			# the game records the violation on contact and charges the fine 3 s later
			a.record_safety_violation()
			a.spend(int(a.maw_fine()))
			a.reset_combo()
		"fail_safe":
			a.spend(1)
			a.reset_combo()
	_ctr.penalties_applied += 1
	gp.count("penalties")
	return {"applied": true}
