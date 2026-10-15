extends RefCounted
## Client side of grab ownership (MP2-DESIGN 5.2-5.5).
##   rows : eid -> {owner, kind, epoch}   last known host row (own messages + wsnap section)
##   pend : eid -> Pend                   predicted grab, own_req sent, no answer yet
##   mine : eid -> {epoch, kind}          granted to this peer
## The carry is predicted: _begin_carry runs at once (the body becomes local_sim),
## own_req goes to the host; a deny or revoke undoes it with the game's safe
## drop (release_held_object) without sending own_rel.

const HeldStream = preload("held_stream.gd")
const GrabAdapter = preload("../game/grab_adapter.gd")

const HOST := 1
const FLAG_HELD := 16                   # body record rflags (2.3)
## a request released before its answer: give up waiting after this long
const PEND_TIMEOUT_MS := 3000


class Pend extends RefCounted:
	var t_ms := 0
	var seen_epoch := 0
	var released := false
	var equipped := false


var grab = null
var rows: Dictionary = {}
var pend: Dictionary = {}
var mine: Dictionary = {}
var suppress: Dictionary = {}      # eid -> true: the next release of eid is ours (deny/revoke), no own_rel
var want_carry: Dictionary = {}    # eid -> epoch: unsolicited grant with carry (rack), body not adopted yet
var counters := {"requests": 0, "granted": 0, "denied": 0, "revoked": 0, "refused_local": 0, "rel_tx": 0,
	"equip_tx": 0, "unequip_tx": 0, "undo_drops": 0, "pend_timeouts": 0}
var refusals: Dictionary = {}


func _init(p_grab = null) -> void:
	grab = p_grab


func my_peer() -> int:
	return int(grab.my_peer_id())


func owner_of(eid: int) -> int:
	return int(rows[eid].owner) if rows.has(eid) else HOST


func hold_kind(eid: int) -> String:
	return String(rows[eid].kind) if rows.has(eid) else ""


func epoch_of(eid: int) -> int:
	return int(rows[eid].epoch) if rows.has(eid) else 0


func is_mine(eid: int) -> bool:
	return mine.has(eid)


# ------------------------------------------------------------------ prediction (5.2 step 1)

## "" or why this peer must not even try (the game's pick simply does not happen).
func local_refusal(eid: int, node: Node) -> String:
	if rows.has(eid):
		var r: Dictionary = rows[eid]
		if String(r.kind) != "" and int(r.owner) != my_peer():
			return "owned"
	var bodies = grab.bodies()
	if bodies != null and (int(bodies.flags_of(eid)) & FLAG_HELD) != 0:
		return "held"
	if GrabAdapter.busy_reason(node) != "":
		return "busy"
	if bodies != null:
		var meta = bodies.meta_of(eid)
		if typeof(meta) == TYPE_DICTIONARY:
			for m in GrabAdapter.BUSY_METAS:
				if meta.has(m) and meta[m] != null and meta[m] != false:
					return "busy"
	return ""


## main_camera._begin_carry on a client. true = run the game's carry.
func begin_carry(eid: int, node: Node) -> bool:
	var bodies = grab.bodies()
	if mine.has(eid):
		# granted already (rack withdraw, or a re-pick of our own unequipped tool)
		if bodies != null:
			bodies.set_local_sim(eid, true)
		want_carry.erase(eid)
		return true
	var why := local_refusal(eid, node)
	if why == "" and pend.has(eid) and (pend[eid] as Pend).released:
		# released before the host answered: the next grant / set belongs to that
		# request (and our own_rel), so a re-grab waits until it is answered
		why = "pending"
	if why != "":
		counters.refused_local += 1
		refusals[why] = int(refusals.get(why, 0)) + 1
		return false
	if bodies != null:
		bodies.set_local_sim(eid, true)
	var p := Pend.new()
	p.t_ms = grab.now()
	p.seen_epoch = epoch_of(eid)
	pend[eid] = p
	return true


## After the game's carry started: ask the host.
func carry_started(eid: int) -> void:
	if not pend.has(eid):
		return
	counters.requests += 1
	grab.send_world(HOST, "own_req", {"eid": eid, "seen_epoch": (pend[eid] as Pend).seen_epoch})


# ------------------------------------------------------------------ host answers

func on_own(msg: Dictionary) -> void:
	var ev := String(msg.get("ev", ""))
	var eid := int(msg.get("eid", 0))
	if eid <= 0:
		return
	var owner := int(msg.get("peer", HOST))
	var kind := String(msg.get("kind", ""))
	var epoch := int(msg.get("epoch", 0))
	var me := my_peer()
	match ev:
		"grant":
			if owner != me:
				_set_row(eid, owner, kind, epoch)
				return
			counters.granted += 1
			if pend.has(eid):
				var p: Pend = pend[eid]
				pend.erase(eid)
				if p.released:
					# released before the answer: the host processes our own_rel (epoch 0) next
					_set_row(eid, owner, kind, epoch)
					_unsim(eid, epoch + 1)
					return
				mine[eid] = {"epoch": epoch, "kind": "equipped" if p.equipped else kind}
				if p.equipped:
					mine[eid].epoch = epoch + 1      # our own_equip (epoch 0) bumps it on the host
			else:
				mine[eid] = {"epoch": epoch, "kind": kind}
				if bool(msg.get("carry", false)):
					want_carry[eid] = epoch
					var bodies = grab.bodies()
					if bodies != null and bodies.node_of(eid) != null:
						bodies.set_local_sim(eid, true)
			_set_row(eid, owner, kind, epoch)
		"deny":
			counters.denied += 1
			pend.erase(eid)
			_undo_carry(eid)
			_set_row(eid, owner, kind, epoch)
			_unsim(eid, epoch)
		"revoke":
			counters.revoked += 1
			pend.erase(eid)
			var had := mine.has(eid)
			mine.erase(eid)
			want_carry.erase(eid)
			if had:
				_undo_carry(eid)
			_set_row(eid, owner, kind, epoch)
			_unsim(eid, epoch)
		"set":
			if owner == me:
				if mine.has(eid):
					mine[eid].epoch = epoch
					mine[eid].kind = kind
			elif mine.has(eid):
				# ownership moved on without a revoke addressed to us: we released it already
				mine.erase(eid)
				if _carrying(eid):
					_undo_carry(eid)
					_unsim(eid, epoch)
			_set_row(eid, owner, kind, epoch)


func _set_row(eid: int, owner: int, kind: String, epoch: int) -> void:
	var prev = rows.get(eid, null)
	rows[eid] = {"owner": owner, "kind": kind, "epoch": epoch}
	var bodies = grab.bodies()
	if bodies != null:
		bodies.set_owner_view(eid, owner, kind, epoch)
	if prev == null or int(prev.owner) != owner or String(prev.kind) != kind or int(prev.epoch) != epoch:
		grab.emit_owner_changed(eid, owner, kind, epoch)


func _unsim(eid: int, min_epoch: int) -> void:
	var bodies = grab.bodies()
	if bodies != null and bodies.is_local_sim(eid):
		bodies.set_local_sim(eid, false, min_epoch)


func _carrying(eid: int) -> bool:
	var node: Node = _node(eid)
	if node == null:
		return false
	var cam: Node = grab.camera()
	return grab.adapter.picked(cam) == node or grab.adapter.equipped(cam) == node


## Undo a predicted or granted carry with the game's own drop; the release
## path sees `suppress` and sends nothing.
func _undo_carry(eid: int) -> void:
	var node: Node = _node(eid)
	if node == null:
		return
	var cam: Node = grab.camera()
	if grab.adapter.equipped(cam) == node:
		suppress[eid] = true
		counters.undo_drops += 1
		grab.adapter.force_unequip(cam)
		grab.capture.forget(node)
	if grab.adapter.picked(cam) == node:
		suppress[eid] = true
		counters.undo_drops += 1
		grab.adapter.release_held(cam)


func _node(eid: int) -> Node:
	var bodies = grab.bodies()
	var n: Node = bodies.node_of(eid) if bodies != null else null
	return n if n != null and is_instance_valid(n) else null


# ------------------------------------------------------------------ local releases (release_capture callbacks)

## The carry ended locally (drop, throw, pause-menu release); state captured one physics frame later.
func on_release(eid: int, info: Dictionary) -> void:
	if suppress.has(eid):
		suppress.erase(eid)
		return
	var body := {"eid": eid, "s": HeldStream.state_to_json(info.get("s", {})), "thrown": bool(info.get("thrown", false)),
		"placed": bool(info.get("placed", false))}
	if info.has("panel_state"):
		body["panel_state"] = int(info.panel_state)
	var tm: Dictionary = info.get("throw_meta", {})
	if not tm.is_empty():
		body["throw_meta"] = {"age_ms": int(tm.age_ms), "pos": HeldStream.vec3_json(tm.pos)}
	if mine.has(eid):
		var ep := int(mine[eid].epoch)
		body["epoch"] = ep
		mine.erase(eid)
		counters.rel_tx += 1
		grab.send_world(HOST, "own_rel", body)
		_set_row(eid, HOST, "", ep + 1)
		_unsim(eid, ep + 1)
	elif pend.has(eid):
		body["epoch"] = 0
		(pend[eid] as Pend).released = true
		(pend[eid] as Pend).t_ms = grab.now()
		counters.rel_tx += 1
		grab.send_world(HOST, "own_rel", body)
	else:
		_unsim(eid, epoch_of(eid))


func on_equip(eid: int) -> void:
	if mine.has(eid):
		var ep := int(mine[eid].epoch)
		counters.equip_tx += 1
		grab.send_world(HOST, "own_equip", {"eid": eid, "epoch": ep})
		mine[eid].kind = "equipped"
		mine[eid].epoch = ep + 1
	elif pend.has(eid):
		(pend[eid] as Pend).equipped = true
		counters.equip_tx += 1
		grab.send_world(HOST, "own_equip", {"eid": eid, "epoch": 0})


func on_unequip(eid: int, drop: Vector3, s: Dictionary) -> void:
	if not mine.has(eid):
		return
	var ep := int(mine[eid].epoch)
	counters.unequip_tx += 1
	grab.send_world(HOST, "own_unequip", {"eid": eid, "epoch": ep, "drop": HeldStream.vec3_json(drop),
		"s": HeldStream.state_to_json(s)})
	mine[eid].kind = "held"
	mine[eid].epoch = ep + 1


## Held-frame records for what this peer carries now (granted or still pending).
func held_records(node: Node) -> Array:
	var bodies = grab.bodies()
	if node == null or bodies == null:
		return []
	var eid := int(bodies.eid_of(node))
	if eid <= 0:
		return []
	var ep := -1
	if mine.has(eid) and String(mine[eid].kind) == "held":
		ep = int(mine[eid].epoch)
	elif pend.has(eid) and not (pend[eid] as Pend).released:
		ep = 0
	if ep < 0:
		return []
	var s := GrabAdapter.body_state(node)
	s["eid"] = eid
	s["epoch"] = ep & 0xFFFF
	return [s]


func tick(now: int) -> void:
	for eid in pend.keys():
		var p: Pend = pend[eid]
		if p.released and now - p.t_ms > PEND_TIMEOUT_MS:
			pend.erase(eid)
			counters.pend_timeouts += 1
			_unsim(eid, 0)


## BODIES despawned eid (fired before the node is recycled): drop the carry.
func entity_removed(eid: int) -> void:
	if _carrying(eid):
		_undo_carry(eid)
	suppress.erase(eid)
	rows.erase(eid)
	pend.erase(eid)
	mine.erase(eid)
	want_carry.erase(eid)


func entity_added(eid: int) -> void:
	if want_carry.has(eid):
		var bodies = grab.bodies()
		if bodies != null:
			bodies.set_local_sim(eid, true)


func apply_wsnap_section(d: Dictionary) -> void:
	for row in d.get("rows", []):
		if typeof(row) != TYPE_ARRAY or row.size() < 4:
			continue
		_set_row(int(row[0]), int(row[1]), String(row[2]), int(row[3]))


func world_stopped() -> void:
	rows.clear()
	pend.clear()
	mine.clear()
	suppress.clear()
	want_carry.clear()
