extends RefCounted
## Client side of the economy mirror (MP-DESIGN 6.3, MP2-DESIGN 3.8, P5).
## Applied inside api.net.begin_apply(1) / end_apply() so events are tagged
## source "net". Idempotent, in this order:
##   1. items: host values + the post-hooks GameState.buy would have run here
##      (remote tier, auto workbench 0->1); then UpgradeUI refresh
##   2. money = host money, exactly (clients earn nothing locally in MP2)
##   3. bank (+ bank_updated), mining bank, statistics (stat_changed per change),
##      registered mirror fields (econ_host.register_field)
## Money clamp (P5): every physics frame (and every process frame) a local
## write to the money (a fine, a combo payout, a missed gate) is reverted to the
## host's last value and counted in local_money_writes.

const Codec = preload("../net/codec.gd")

var session = null
var adapter = null
var my_peer := 0
var applied := 0
var drift_heals := 0
var last_full_ms := 0
var local_money_writes := 0
var reverts: Array = []     # the last 8 reverted local writes {local, host, ms}
var stats_applied := 0
var _ui_dirty := false
var _ui_last_ms := 0
var _money_dirty := false
var _host_money := ""
var _clamp_signal_connected := false
var _clamp_sig: Signal


func _init(p_session = null, p_adapter = null) -> void:
	session = p_session
	adapter = p_adapter


func reset() -> void:
	_host_money = ""
	_disconnect_clamp()


func host_money() -> String:
	return _host_money


func on_econ(msg: Dictionary) -> void:
	if adapter == null:
		return
	var full := bool(msg.get("full", false))
	if full:
		_check_drift(msg)
		last_full_ms = Time.get_ticks_msec()
	_begin()
	var items = msg.get("items", {})
	if typeof(items) == TYPE_DICTIONARY and not items.is_empty():
		var r: Dictionary = adapter.apply_mirror_items(items)
		if bool(r.get("changed", false)):
			_ui_dirty = true
	var po = msg.get("purchased_once", {})
	if typeof(po) == TYPE_DICTIONARY and (full or not po.is_empty()):
		adapter.set_purchased_once(po, full)
		_money_dirty = true
	var money := String(msg.get("money", ""))
	if s_valid(money):
		var m := s_norm(money)
		if m != _host_money:
			_money_dirty = true
		_host_money = m
		adapter.set_money(_host_money)
	if msg.has("bank") and adapter.has_method("set_bank") and float(msg.bank) >= 0.0:
		adapter.set_bank(float(msg.bank))
	if msg.has("mbank") and adapter.has_method("set_mining_bank") and int(msg.mbank) >= 0:
		adapter.set_mining_bank(int(msg.mbank))
	var st = msg.get("stats", {})
	if typeof(st) == TYPE_DICTIONARY and not st.is_empty() and adapter.has_method("apply_mirror_stats"):
		stats_applied += int(adapter.apply_mirror_stats(st))
	var f = msg.get("f", {})
	if typeof(f) == TYPE_DICTIONARY and session != null and "econ_host" in session and session.econ_host != null:
		var reg: Dictionary = session.econ_host.fields
		for n in f:
			if reg.has(n):
				var ap: Callable = reg[n].apply
				if ap.is_valid():
					ap.call(f[n])
	_end()
	applied += 1
	_connect_clamp()


## An open upgrade menu follows mirrored items (rebuild) and money (in place),
## coalesced to once per frame (0.2.2); the money clamp also runs here (process frames).
func tick(now_ms: int) -> void:
	clamp_money()
	if _ui_dirty or _money_dirty:
		_ui_last_ms = now_ms
		if adapter.has_method("request_upgrade_ui_refresh"):
			adapter.request_upgrade_ui_refresh(_ui_dirty)
		_ui_dirty = false
		_money_dirty = false


## P5: any local money write is reverted to the host's value. true = reverted.
func clamp_money() -> bool:
	if _host_money == "" or adapter == null:
		return false
	if session != null and session.has_method("get_role") and session.get_role() != "client":
		return false
	if adapter.get_money() == _host_money:
		return false
	local_money_writes += 1
	# diagnostics (`mp dump`, tests): which local write was reverted
	reverts.append({"local": str(adapter.get_money()), "host": _host_money, "ms": Time.get_ticks_msec()})
	if reverts.size() > 8:
		reverts.pop_front()
	_begin()
	adapter.set_money(_host_money)
	_end()
	return true


func _on_physics_frame() -> void:
	clamp_money()


func _connect_clamp() -> void:
	if _clamp_signal_connected or adapter == null or not adapter.has_method("physics_frame_signal"):
		return
	var sig: Signal = adapter.physics_frame_signal()
	if sig.is_null():
		return
	_clamp_sig = sig
	_clamp_sig.connect(_on_physics_frame)
	_clamp_signal_connected = true


func _disconnect_clamp() -> void:
	if _clamp_signal_connected and not _clamp_sig.is_null() and _clamp_sig.is_connected(_on_physics_frame):
		_clamp_sig.disconnect(_on_physics_frame)
	_clamp_signal_connected = false


func _begin() -> void:
	if session != null and session.has_method("begin_apply"):
		session.begin_apply()


func _end() -> void:
	if session != null and session.has_method("end_apply"):
		session.end_apply()


func _check_drift(msg: Dictionary) -> void:
	var items = msg.get("items", {})
	if typeof(items) != TYPE_DICTIONARY:
		return
	# the wire normalises integral floats to ints (prices): compare like for like,
	# or a float price counts as drift on every full econ
	var mine: Dictionary = Codec.normalize_numbers(adapter.mirror_items())
	var diffs := 0
	var sample: Array = []
	for k in items:
		if mine.has(k) and mine[k] != items[k]:
			diffs += 1
			if sample.size() < 3:
				sample.append("%s here %s host %s" % [k, JSON.stringify(mine[k]), JSON.stringify(items[k])])
	if diffs > 0:
		drift_heals += 1
		if session != null and session.has_method("log_info"):
			session.log_info("full econ healed %d drifted item(s): %s" % [diffs, "; ".join(sample)])


# ------------------------------------------------------------------ decimal strings

static func s_valid(s: String) -> bool:
	if s == "":
		return false
	var body := s.substr(1) if s.begins_with("-") else s
	if body == "":
		return false
	for c in body:
		if c < "0" or c > "9":
			return false
	return true


static func s_norm(s: String) -> String:
	var neg := s.begins_with("-")
	var body := s.substr(1) if neg else s
	body = body.lstrip("0")
	if body == "":
		return "0"
	return ("-" if neg else "") + body

