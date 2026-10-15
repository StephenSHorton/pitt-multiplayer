extends RefCounted
## Mirror fields GAMEPLAY registers with econ_host.register_field (MP2-DESIGN
## 6.10, D14). Host read() -> JSON-safe value (sent on change and with every full
## econ); client apply(v) in apply scope.
##   remote  {ch: [[eid, ...], ...], st: [bool, ...]}  shared remote channels and links;
##           links are rebuilt from eids, states go through set_remote_channel_state
##           (its remote_toggle calls pass the replay gate) so antennas and LEDs redraw
##   flags   {uv_unlocked, torch_unlocked, pickaxe_tier, pickaxe_found, keypad_revealed,
##            elevator_hacked, secret_ending_seen}
##   buffs   [[type, multiplier, duration, end_host_ms], ...]  stable while a buff runs
##           (end time instead of the per-frame remaining time); clients activate_buff so the
##           HUD shows them (buffs only change host-simulated values)
## The per-player panel rack is not a broadcast field: rack.gd sends each peer its
## own stack.

const FLAGS := ["uv_unlocked", "torch_unlocked", "pickaxe_tier", "pickaxe_found", "keypad_revealed",
	"elevator_hacked", "secret_ending_seen"]

var gp = null
var _buff_seen: Dictionary = {}     # host: type -> {m, d, end}
var registered := false


func _init(p_gp) -> void:
	gp = p_gp


func register_all() -> void:
	registered = false
	var s = gp.session
	if s == null or not ("econ_host" in s) or s.econ_host == null or not s.econ_host.has_method("register_field"):
		return
	s.econ_host.register_field("remote", read_remote, apply_remote)
	s.econ_host.register_field("flags", read_flags, apply_flags)
	s.econ_host.register_field("buffs", read_buffs, apply_buffs)
	registered = true


# ------------------------------------------------------------------ remote channels

func read_remote() -> Variant:
	var a = gp.adapter
	var chans = a.gs_get("remote_channels", [])
	var states = a.gs_get("remote_channel_states", [])
	var ch: Array = []
	if typeof(chans) == TYPE_ARRAY:
		for c in chans:
			var ids: Array = []
			if typeof(c) == TYPE_ARRAY:
				for t in c:
					var eid := int(gp.eid_of(t)) if t != null and is_instance_valid(t) else 0
					if eid > 0:
						ids.append(eid)
			ch.append(ids)
	var st: Array = []
	if typeof(states) == TYPE_ARRAY:
		for v in states:
			st.append(bool(v))
	return {"ch": ch, "st": st}


func apply_remote(v) -> void:
	if typeof(v) != TYPE_DICTIONARY:
		return
	var gs = gp.adapter.game_state()
	if gs == null:
		return
	var chans = gs.get("remote_channels")
	var ch = v.get("ch", [])
	if typeof(chans) == TYPE_ARRAY and typeof(ch) == TYPE_ARRAY:
		for i in mini(chans.size(), ch.size()):
			var list = chans[i]
			if typeof(list) != TYPE_ARRAY:
				continue
			list.clear()
			if typeof(ch[i]) != TYPE_ARRAY:
				continue
			for eid in ch[i]:
				var n = gp.node_of(int(eid))
				if n != null:
					list.append(n)
	var st = v.get("st", [])
	var states = gs.get("remote_channel_states")
	if typeof(st) == TYPE_ARRAY and typeof(states) == TYPE_ARRAY and gs.has_method("set_remote_channel_state"):
		for i in mini(st.size(), states.size()):
			if bool(states[i]) != bool(st[i]):
				gs.set_remote_channel_state(i, bool(st[i]))


# ------------------------------------------------------------------ world flags

func read_flags() -> Variant:
	var out := {}
	for f in FLAGS:
		var val = gp.adapter.gs_get(f, null)
		if val != null:
			out[f] = int(val) if f == "pickaxe_tier" else bool(val)
	return out


func apply_flags(v) -> void:
	if typeof(v) != TYPE_DICTIONARY:
		return
	for f in FLAGS:
		if v.has(f):
			gp.adapter.gs_set(f, int(v[f]) if f == "pickaxe_tier" else bool(v[f]))


# ------------------------------------------------------------------ buffs

func read_buffs() -> Variant:
	var active = gp.adapter.gs_get("active_buffs", {})
	var now := int(gp.host_now())
	var out: Array = []
	if typeof(active) != TYPE_DICTIONARY:
		return out
	for t in _buff_seen.keys():
		if not active.has(t):
			_buff_seen.erase(t)
	var types: Array = active.keys()
	types.sort()
	for t in types:
		var b = active[t]
		if typeof(b) != TYPE_DICTIONARY:
			continue
		var m := float(b.get("multiplier", 1.0))
		var d := float(b.get("duration", 0.0))
		var end := now + int(float(b.get("time_remaining", 0.0)) * 1000.0)
		var seen: Dictionary = _buff_seen.get(t, {})
		# a re-activation (new multiplier/duration or more time left) moves the end
		if seen.is_empty() or float(seen.m) != m or float(seen.d) != d or end > int(seen.end) + 500:
			seen = {"m": m, "d": d, "end": end}
			_buff_seen[t] = seen
		out.append([String(t), m, d, int(seen.end)])
	return out


func apply_buffs(v) -> void:
	if typeof(v) != TYPE_ARRAY:
		return
	var gs = gp.adapter.game_state()
	if gs == null:
		return
	var active = gs.get("active_buffs")
	if typeof(active) != TYPE_DICTIONARY:
		return
	var now := int(gp.host_now())
	var want := {}
	for e in v:
		if typeof(e) != TYPE_ARRAY or e.size() < 4:
			continue
		var t := String(e[0])
		var rem := float(int(e[3]) - now) / 1000.0
		if rem <= 0.0:
			continue
		want[t] = true
		var cur = active.get(t, null)
		if cur == null or float(cur.get("multiplier", 0.0)) != float(e[1]):
			if gs.has_method("activate_buff"):
				gs.activate_buff(t, float(e[1]), float(e[2]))
			cur = active.get(t, null)
		if typeof(cur) == TYPE_DICTIONARY:
			cur["time_remaining"] = rem
	for t in active.keys():
		if not want.has(t):
			active.erase(t)
			if gs.has_signal("buff_expired"):
				gs.emit_signal("buff_expired", t)
