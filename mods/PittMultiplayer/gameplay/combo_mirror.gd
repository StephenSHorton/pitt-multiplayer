extends RefCounted
## Shared combo (D9, MP2-DESIGN 6.9). Only the host's maw consumes, so the host's
## ComboSystem is the one combo.
## Host: listens to every ComboSystem signal and sends `combo` (ch0) on every
## event and at most SEND_HZ times a second while the combo runs:
##   {a, c, t, w, tb, ch, dm, rc, mp, ma, mm, bm, ev: [["started", lvl], ["ended", lvl, total],
##    ["broken"], ["chain", lvl, bonus], ["diversity", types, bonus], ["rhythm", c, bonus], ["mega", mult]]}
## Client: ComboSystem.set_physics_process(false) for the session (its own timer
## would end combos the host still runs); the fields are written in apply scope,
## `ev` re-emits the game's own signals so the HUD reacts as in single player,
## and combo_updated(current_combo, progress) is emitted every frame from a
## locally decremented timer. The HUD's show_result calls add_bonus locally; the
## money clamp reverts it (the host already paid). MORE / EXTRA / MEGA unlock on
## the client when the mirrored combo crosses 100 / 200 / 300 (the achievements
## policy suppression still applies inside Steamworks).

const SEND_HZ := 10.0
const ACH := [[100, "MORE"], [200, "EXTRA"], [300, "MEGA"]]
const SIGNALS := ["combo_started", "combo_ended", "combo_broken", "chain_combo_triggered",
	"diversity_bonus_triggered", "rhythm_bonus_triggered", "mega_combo_activated"]

var gp = null
var _cs: Object = null
var _ev: Array = []
var _last_sent_c := -1
var _last_send_ms := 0
var _dirty := false
var _client_prev_phys := true
var _client_disabled := false
var _client_c := 0
var _connected: Array = []         # [signal name, callable]
var _ctr := {"combo_tx": 0, "combo_rx": 0, "combo_events": 0}


func _init(p_gp) -> void:
	gp = p_gp


func counters() -> Dictionary:
	return _ctr.duplicate()


func on_world_started() -> void:
	_cs = gp.adapter.combo_system() if gp.adapter != null else null
	if _cs == null:
		return
	if gp.role == "host":
		_connect_host()
	else:
		if not _client_disabled:
			_client_prev_phys = _cs.is_physics_processing()
			_cs.set_physics_process(false)
			_client_disabled = true


func on_world_stopped() -> void:
	_disconnect_host()


func teardown() -> void:
	_disconnect_host()
	if _client_disabled and _cs != null and is_instance_valid(_cs):
		_cs.set_physics_process(_client_prev_phys)
	_client_disabled = false
	_cs = null
	_ev.clear()
	_last_sent_c = -1
	_client_c = 0


# ------------------------------------------------------------------ host

func _connect_host() -> void:
	_disconnect_host()
	for s in SIGNALS:
		if not _cs.has_signal(s):
			continue
		var c := Callable(self, "_on_" + s)
		_cs.connect(s, c)
		_connected.append([s, c])


func _disconnect_host() -> void:
	if _cs != null and is_instance_valid(_cs):
		for e in _connected:
			if _cs.is_connected(e[0], e[1]):
				_cs.disconnect(e[0], e[1])
	_connected.clear()


func _push(e: Array) -> void:
	_ev.append(e)
	_dirty = true
	_ctr.combo_events += 1


func _on_combo_started(lvl) -> void:
	_push(["started", int(lvl)])


func _on_combo_ended(lvl, total) -> void:
	_push(["ended", int(lvl), float(total)])


func _on_combo_broken() -> void:
	_push(["broken"])


func _on_chain_combo_triggered(lvl, bonus) -> void:
	_push(["chain", int(lvl), float(bonus)])


func _on_diversity_bonus_triggered(types, bonus) -> void:
	var t: Array = []
	if typeof(types) == TYPE_ARRAY:
		for x in types:
			t.append(String(x))
	_push(["diversity", t, float(bonus)])


func _on_rhythm_bonus_triggered(consistency, bonus) -> void:
	_push(["rhythm", float(consistency), float(bonus)])


func _on_mega_combo_activated(mult) -> void:
	_push(["mega", float(mult)])


func full_state() -> Dictionary:
	var cs = _cs if _cs != null and is_instance_valid(_cs) else (gp.adapter.combo_system() if gp.adapter != null else null)
	if cs == null:
		return {}
	var w := 0.0
	if cs.has_method("get_current_time_window"):
		w = float(cs.get_current_time_window())
	return {"a": bool(cs.get("is_combo_active")), "c": int(cs.get("current_combo")), "t": float(cs.get("combo_timer")),
		"w": w, "tb": float(cs.get("total_bonus")), "ch": int(cs.get("current_chain_level")),
		"dm": float(cs.get("diversity_multiplier")), "rc": float(cs.get("rhythm_consistency")),
		"mp": int(cs.get("mega_combo_progress")), "ma": bool(cs.get("mega_combo_active")),
		"mm": float(cs.get("mega_combo_multiplier")), "bm": float(cs.get("bowling_multiplier"))}


func send_full(peer: int) -> void:
	if gp.role != "host":
		return
	var st := full_state()
	if st.is_empty():
		return
	if gp.session != null and gp.session.has_method("send_msg"):
		gp.session.send_msg(peer, "combo", st)
		_ctr.combo_tx += 1


func tick(now_ms: int) -> void:
	if gp.role != "host" or _cs == null or not is_instance_valid(_cs):
		return
	var c := int(_cs.get("current_combo"))
	var active := bool(_cs.get("is_combo_active"))
	var due := _dirty or (active and c != _last_sent_c and now_ms - _last_send_ms >= int(1000.0 / SEND_HZ))
	if not due:
		return
	var st := full_state()
	st["ev"] = _ev
	_ev = []
	_dirty = false
	_last_sent_c = c
	_last_send_ms = now_ms
	for p in gp._in_game():
		gp.session.send_msg(int(p), "combo", st)
	_ctr.combo_tx += 1


# ------------------------------------------------------------------ client

func client_on_combo(msg: Dictionary) -> void:
	_ctr.combo_rx += 1
	var cs = gp.adapter.combo_system() if gp.adapter != null else null
	if cs == null:
		return
	var prev_c := int(cs.get("current_combo"))
	gp.begin_apply()
	_put(cs, "is_combo_active", bool(msg.get("a", false)))
	_put(cs, "current_combo", int(msg.get("c", 0)))
	_put(cs, "combo_timer", float(msg.get("t", 0.0)))
	_put(cs, "total_bonus", float(msg.get("tb", 0.0)))
	_put(cs, "current_chain_level", int(msg.get("ch", 0)))
	_put(cs, "diversity_multiplier", float(msg.get("dm", 1.0)))
	_put(cs, "rhythm_consistency", float(msg.get("rc", 0.0)))
	_put(cs, "mega_combo_progress", int(msg.get("mp", 0)))
	_put(cs, "mega_combo_active", bool(msg.get("ma", false)))
	_put(cs, "mega_combo_multiplier", float(msg.get("mm", 1.0)))
	_put(cs, "bowling_multiplier", float(msg.get("bm", 1.0)))
	var ev = msg.get("ev", [])
	if typeof(ev) == TYPE_ARRAY:
		for e in ev:
			_emit(cs, e)
	var c := int(msg.get("c", 0))
	if c > prev_c and c > 1 and cs.has_method("_play_combo_hit_sound"):
		cs._play_combo_hit_sound()
	for a in ACH:
		if prev_c < int(a[0]) and c >= int(a[0]):
			gp.adapter.unlock_achievement(String(a[1]))
	_client_c = c
	gp.end_apply()


func _put(cs: Object, prop: String, v) -> void:
	if prop in cs:
		cs.set(prop, v)


func _emit(cs: Object, e) -> void:
	if typeof(e) != TYPE_ARRAY or e.is_empty():
		return
	match String(e[0]):
		"started":
			if e.size() >= 2 and cs.has_signal("combo_started"):
				cs.emit_signal("combo_started", int(e[1]))
		"ended":
			if e.size() >= 3 and cs.has_signal("combo_ended"):
				cs.emit_signal("combo_ended", int(e[1]), float(e[2]))
		"broken":
			if cs.has_signal("combo_broken"):
				cs.emit_signal("combo_broken")
		"chain":
			if e.size() >= 3 and cs.has_signal("chain_combo_triggered"):
				cs.emit_signal("chain_combo_triggered", int(e[1]), int(e[2]))
		"diversity":
			if e.size() >= 3 and cs.has_signal("diversity_bonus_triggered") and typeof(e[1]) == TYPE_ARRAY:
				cs.emit_signal("diversity_bonus_triggered", e[1], int(e[2]))
		"rhythm":
			if e.size() >= 3 and cs.has_signal("rhythm_bonus_triggered"):
				cs.emit_signal("rhythm_bonus_triggered", float(e[1]), int(e[2]))
		"mega":
			if e.size() >= 2 and cs.has_signal("mega_combo_activated"):
				cs.emit_signal("mega_combo_activated", float(e[1]))


## Client, every process frame: the local timer between host updates.
func process(delta: float) -> void:
	if gp.role != "client" or not _client_disabled:
		return
	var cs = _cs
	if cs == null or not is_instance_valid(cs) or not bool(cs.get("is_combo_active")):
		return
	var t := maxf(float(cs.get("combo_timer")) - delta, 0.0)
	cs.set("combo_timer", t)
	var w := 0.0
	if cs.has_method("get_current_time_window"):
		w = float(cs.get_current_time_window())
	var progress := t / w if w > 0.0 else 0.0
	cs.emit_signal("combo_updated", int(cs.get("current_combo")), progress)
