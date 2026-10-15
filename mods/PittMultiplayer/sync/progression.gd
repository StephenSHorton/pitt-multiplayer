extends RefCounted
## Unlocks, phase and hole (MP-DESIGN 6.3, 4.2).
## Host: polls the host's UnlockManager / GameProgression / hole and sends
##   unlock {ids} (new ids in host order), phase {kind: begin|settled, phase},
##   hole {target_radius, phase_nutrition_total} (<= 4 Hz, on change).
## Client: applies them through the game's live paths: force_unlock per id
##   (actions, notification, badges), GameProgression.change_phase (the real
##   cinematic; forward only), and the saveable_hole fields. The client's
##   UnlockManager is detached for the session, so milestones are judged on
##   host state only.

const HOLE_INTERVAL_MS := 250
const UNLOCK_INTERVAL_MS := 100

var session = null
var adapter = null

# host
var _sent_unlocks: Array = []
var _sent_set: Dictionary = {}
var _last_phase := -1
var _settled_phase := -1
var _last_hole: Dictionary = {}
var _last_hole_ms := 0
var _last_unlock_ms := 0

# client
var applied_unlocks := 0
var skipped_unlocks := 0
var phase_changes: Array = []


func _init(p_session = null, p_adapter = null) -> void:
	session = p_session
	adapter = p_adapter


# ================================================================== host

func host_reset() -> void:
	_sent_unlocks = adapter.unlocked_list()
	_sent_set.clear()
	for id in _sent_unlocks:
		_sent_set[id] = true
	_last_phase = adapter.get_phase()
	_settled_phase = _last_phase
	_last_hole = adapter.hole_state()


func host_tick(now_ms: int) -> void:
	if now_ms - _last_unlock_ms >= UNLOCK_INTERVAL_MS:
		_last_unlock_ms = now_ms
		var new_ids: Array = []
		for id in adapter.unlocked_list():
			if not _sent_set.has(id):
				_sent_set[id] = true
				_sent_unlocks.append(id)
				new_ids.append(id)
		if not new_ids.is_empty():
			_broadcast("unlock", {"ids": new_ids})
	_check_phase_begin()
	if now_ms - _last_hole_ms >= HOLE_INTERVAL_MS:
		_last_hole_ms = now_ms
		var h: Dictionary = adapter.hole_state()
		if not h.is_empty() and _hole_changed(_last_hole, h):
			_last_hole = h
			_broadcast("hole", h)


func _check_phase_begin() -> void:
	var p: int = adapter.get_phase()
	if p != _last_phase:
		_last_phase = p
		_broadcast("phase", {"kind": "begin", "phase": p})
		if session != null:
			session.on_host_phase("begin", p)


## GameProgression.phase_changed on the host: the transition finished. A
## change that settles at once (phase 1, the ending) still begins first.
func host_on_settled(p: int) -> void:
	_check_phase_begin()
	_settled_phase = p
	_broadcast("phase", {"kind": "settled", "phase": p})
	if session != null:
		session.on_host_phase("settled", p)


func host_phase_settled() -> bool:
	return _settled_phase == adapter.get_phase()


## A client finished loading: everything since the snapshot.
func host_send_all(peer: int) -> void:
	if session == null:
		return
	session.send_msg(peer, "unlock", {"ids": adapter.unlocked_list()})
	session.send_msg(peer, "phase", {"kind": "settled" if host_phase_settled() else "begin", "phase": adapter.get_phase()})
	var h: Dictionary = adapter.hole_state()
	if not h.is_empty():
		session.send_msg(peer, "hole", h)


func _broadcast(k: String, body: Dictionary) -> void:
	if session == null:
		return
	for p in session.in_game_peers():
		session.send_msg(p, k, body)


static func _hole_changed(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty():
		return true
	return absf(float(a.get("target_radius", 0.0)) - float(b.get("target_radius", 0.0))) > 0.0005 \
		or absf(float(a.get("phase_nutrition_total", 0.0)) - float(b.get("phase_nutrition_total", 0.0))) > 0.0001


# ================================================================== client

func client_on_unlock(ids: Variant) -> void:
	if typeof(ids) != TYPE_ARRAY:
		return
	var any := false
	if session != null:
		session.begin_apply()
	for id in ids:
		var s := String(id)
		if not adapter.has_milestone(s):
			skipped_unlocks += 1
			if session != null and session.has_method("log_info"):
				session.log_info("unknown milestone from host skipped: %s" % s)
			continue
		if adapter.is_unlocked(s):
			continue
		adapter.force_unlock(s)
		applied_unlocks += 1
		any = true
	if session != null:
		session.end_apply()
	if any:
		adapter.refresh_upgrade_ui()


## Phase never moves backwards. Returns the phase applied, or -1.
func client_on_phase(kind: String, p: int) -> int:
	var cur: int = adapter.get_phase()
	if p <= cur or p < 0 or p > 5:
		return -1
	phase_changes.append(p)
	if session != null:
		session.begin_apply()
	adapter.change_phase(p)
	if session != null:
		session.end_apply()
	return p


func client_on_hole(d: Dictionary) -> void:
	adapter.set_hole_state(d)


func detach_unlock_manager() -> void:
	adapter.detach_unlock_manager()


func restore_unlock_manager() -> void:
	adapter.restore_unlock_manager()
