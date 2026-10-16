extends RefCounted
## Host -> clients economy mirror (MP-DESIGN 6.2, MP2-DESIGN 3.8). State-based
## and idempotent: money is always an absolute decimal string; items carry
## absolute values ("cat/key/sub" -> {level, enabled, price0}); purchased_once
## entries. MP2 adds the shared gambling bank, the mining bank, the statistics
## counters (D24) and a field registry for other modules (register_field, 6.10).
## There is no contribution ack any more: clients earn nothing locally.
## At most one delta per 100 ms when something changed (polled: the golden
## statue writes money directly and toy prices change silently), a full econ
## every 2 s (self-heals drift) and on `ready`. flush() runs before every `res`
## so a command's result never overtakes the state it caused (R20).

const DELTA_INTERVAL_MS := 100
const FULL_INTERVAL_MS := 2000

var session = null
var adapter = null
var _last: Dictionary = {}         # last broadcast state
var _last_delta_ms := 0
var _last_full_ms := 0
var sent_deltas := 0
var sent_fulls := 0
## name -> {read: Callable, apply: Callable} (10.2: GAMEPLAY's mirror fields).
## Both roles register; the host reads, econ_client applies.
var fields: Dictionary = {}


func _init(p_session = null, p_adapter = null) -> void:
	session = p_session
	adapter = p_adapter


func reset() -> void:
	_last = {}


## host read() -> Variant (JSON-safe); client apply(v) runs in apply scope.
## Sent on change and with every full econ.
func register_field(name: String, read: Callable, apply: Callable) -> void:
	if name == "":
		return
	fields[name] = {"read": read, "apply": apply}


func unregister_field(name: String) -> void:
	fields.erase(name)


func capture() -> Dictionary:
	var d := {"money": adapter.get_money(), "items": adapter.mirror_items(), "po": adapter.purchased_once()}
	if adapter.has_method("mirror_stats"):
		d["stats"] = adapter.mirror_stats()
		d["bank"] = adapter.get_bank()
		d["mbank"] = adapter.get_mining_bank()
	var f := {}
	for n in fields:
		var r: Callable = fields[n].read
		if r.is_valid():
			f[n] = r.call()
	d["f"] = f
	return d


func forget_peer(_peer: int) -> void:
	pass


func tick(now_ms: int) -> void:
	if session == null or session.in_game_peers().is_empty():
		return
	if now_ms - _last_full_ms >= FULL_INTERVAL_MS:
		_last_full_ms = now_ms
		_last_delta_ms = now_ms
		send_full(0)
		return
	if now_ms - _last_delta_ms >= DELTA_INTERVAL_MS:
		_last_delta_ms = now_ms
		flush()


## Sends a delta to every in-game client if anything changed. Returns true when sent.
func flush() -> bool:
	if session == null:
		return false
	var peers: Array = session.in_game_peers()
	if peers.is_empty():
		_last = capture()
		return false
	var now := capture()
	var msg := diff(_last, now)
	if msg.is_empty():
		return false
	# money moved (sales, another player's spend): an open menu re-checks what is affordable
	if msg.has("money_changed") and adapter != null and adapter.has_method("request_upgrade_ui_refresh"):
		adapter.request_upgrade_ui_refresh(false)
	msg.erase("money_changed")
	msg["full"] = false
	msg["money"] = now.money
	_last = now
	for p in peers:
		session.send_msg(p, "econ", msg)
	sent_deltas += 1
	return true


## peer 0 = every in-game client. A delta goes out first so every receiver
## shares the same baseline afterwards.
func send_full(peer: int) -> void:
	if session == null:
		return
	flush()
	var now := capture()
	_last = now
	var msg := {"full": true, "money": now.money, "items": now.items, "purchased_once": now.po, "f": now.f}
	if now.has("stats"):
		msg["stats"] = now.stats
		msg["bank"] = now.bank
		msg["mbank"] = now.mbank
	var targets: Array = session.in_game_peers() if peer == 0 else [peer]
	for p in targets:
		session.send_msg(p, "econ", msg)
	sent_fulls += 1


## {items?, purchased_once?, stats?, bank?, mbank?, f?} of what changed between
## two captures ({} if nothing).
static func diff(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := {}
	var items := _dict_diff(a.get("items", {}), b.get("items", {}))
	if not items.is_empty():
		out["items"] = items
	var po := _dict_diff(a.get("po", {}), b.get("po", {}))
	if not po.is_empty():
		out["purchased_once"] = po
	var st := _dict_diff(a.get("stats", {}), b.get("stats", {}))
	if not st.is_empty():
		out["stats"] = st
	var f := _dict_diff(a.get("f", {}), b.get("f", {}))
	if not f.is_empty():
		out["f"] = f
	if b.has("bank") and (not a.has("bank") or not is_equal_approx(float(a.bank), float(b.bank))):
		out["bank"] = b.bank
	if b.has("mbank") and (not a.has("mbank") or int(a.mbank) != int(b.mbank)):
		out["mbank"] = b.mbank
	if String(a.get("money", "")) != String(b.get("money", "")):
		out["money_changed"] = true
	return out


static func _dict_diff(a, b) -> Dictionary:
	var out := {}
	if typeof(b) != TYPE_DICTIONARY:
		return out
	var aa: Dictionary = a if typeof(a) == TYPE_DICTIONARY else {}
	for k in b:
		if not aa.has(k) or aa[k] != b[k]:
			out[k] = b[k]
	return out
