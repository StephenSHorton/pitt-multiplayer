extends RefCounted
## One-shot effects, achievements and notifications host -> clients (MP2-DESIGN
## 6.12). The host extensions call MpGate.fx(kind, node, args) where the game ran
## a host-only branch. Each effect is sent at once on ch3: BODIES batches the
## despawn of the same entity and flushes it later (at most 30 Hz, from its tick),
## so on the ordered channel the effect always precedes the despawn. (A per-frame
## batch flushed from our own tick could run after BODIES' flush in the same frame.)
## Message: fx {list: [{kind, eid?, pos?, args?}]}.
## Clients replay the game's own cosmetic helper on their copy of the node inside
## apply scope. Effects whose target is unknown on the client are dropped
## (counted), except those that only need a position.

var gp = null
var _ctr := {"fx_tx": 0, "fx_rx": 0, "fx_dropped": 0, "fx_applied": 0}
var applied_kinds: Array = []      # tests: kinds applied on this client (last 64)


func _init(p_gp) -> void:
	gp = p_gp


func counters() -> Dictionary:
	return _ctr.duplicate()


# ------------------------------------------------------------------ host

func emit(kind: String, node: Object, args: Dictionary) -> void:
	var e := {"kind": kind}
	if node != null and is_instance_valid(node):
		var eid := int(gp.eid_of(node))
		if eid > 0:
			e["eid"] = eid
		if node is Node3D and (node as Node3D).is_inside_tree():
			var p: Vector3 = (node as Node3D).global_position
			e["pos"] = [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)]
	if not args.is_empty():
		e["args"] = args
	if gp.role != "host" or not gp.live:
		return
	if gp.send_world(0, "fx", {"list": [e]}) == OK:
		_ctr.fx_tx += 1


## Kept for the module's tick/teardown (nothing is queued any more).
func flush() -> void:
	pass


# ------------------------------------------------------------------ client

func client_apply(msg: Dictionary) -> void:
	var list = msg.get("list", [])
	if typeof(list) != TYPE_ARRAY:
		return
	gp.begin_apply()
	for e in list:
		if typeof(e) == TYPE_DICTIONARY:
			_ctr.fx_rx += 1
			if _apply_one(e):
				_ctr.fx_applied += 1
				applied_kinds.append(String(e.get("kind", "")))
				if applied_kinds.size() > 64:
					applied_kinds.pop_front()
			else:
				_ctr.fx_dropped += 1
	gp.end_apply()


static func _vec(a) -> Variant:
	if typeof(a) != TYPE_ARRAY or a.size() != 3:
		return null
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func _apply_one(e: Dictionary) -> bool:
	var kind := String(e.get("kind", ""))
	var args: Dictionary = e.get("args", {}) if typeof(e.get("args", {})) == TYPE_DICTIONARY else {}
	var n: Node = gp.node_of(int(e.get("eid", 0))) if int(e.get("eid", 0)) > 0 else null
	var pos = _vec(e.get("pos", null))
	var a = gp.adapter
	match kind:
		"ach":
			a.unlock_achievement(String(args.get("id", "")))
			return true
		"notify":
			a.notify(String(args.get("key", "")))
			return true
		"bonus_text":
			var hud = a.hud()
			if hud == null or not hud.has_method("_spawn_special_bonus_text"):
				return false
			hud._spawn_special_bonus_text(String(args.get("text", "")), Color.html(String(args.get("color", "ffffff"))))
			return true
		"hack_success":
			var t = a.tree()
			if t == null:
				return false
			t.call_group("security_elevator", "on_hack_success")
			return true
		"keypad_reveal":
			var t2 = a.tree()
			if t2 == null:
				return false
			t2.call_group("security_keypad", "reveal")
			return true
		"rack":
			return bool(gp.rack.client_apply_stack(args.get("stack", null)))
	if n == null or not is_instance_valid(n):
		return false
	match kind:
		"maw":
			if n.has_method("maw_effect"):
				var p = _vec(args.get("p", null))
				n.maw_effect(String(args.get("type", "")), p if p != null else (pos if pos != null else Vector3.ZERO))
				return true
		"pinata_burst":
			if n.has_method("_spawn_burst_effects"):
				var d = n._detach_audio_players() if n.has_method("_detach_audio_players") else {}
				n._spawn_burst_effects(d if typeof(d) == TYPE_DICTIONARY else {})
				return true
		"register_depleted":
			if n.has_method("_spawn_destroy_effect"):
				n._spawn_destroy_effect()
				return true
		"candy_expire":
			if n.has_method("_spawn_expire_effects"):
				n._spawn_expire_effects()
				return true
		"crate_break":
			var rarity := String(args.get("rarity", "common"))
			var color := Color.html(String(args.get("color", "ffffff")))
			if n.has_method("_spawn_break_effects"):
				var d2 = n._detach_audio_players() if n.has_method("_detach_audio_players") else {}
				n._spawn_break_effects(color, rarity, d2 if typeof(d2) == TYPE_DICTIONARY else {})
			if n.has_method("_spawn_floating_rarity_text"):
				n._spawn_floating_rarity_text(rarity, color)
			return true
		"crate_buff":
			if n.has_method("_spawn_floating_buff_text"):
				n._spawn_floating_buff_text(String(args.get("buff", "")))
				return true
		"debris_hit":
			var at = _vec(args.get("at", null))
			if at != null and n.has_method("_spawn_destruction_effect"):
				n._spawn_destruction_effect(Transform3D(Basis(), at))
			if n.has_method("_apply_landing_shake") and args.has("force"):
				n._apply_landing_shake(float(args.force))
			return true
		"cannon_fire":
			if n.has_method("_trigger_muzzle_flash"):
				n._trigger_muzzle_flash()
			if n.has_method("_emit_smoke"):
				n._emit_smoke()
			return true
		"statue_bless":
			if n.has_method("_spawn_bless_text"):
				var body = gp.node_of(int(args.get("body", 0))) if int(args.get("body", 0)) > 0 else null
				n._spawn_bless_text(body if body is Node3D else n, float(args.get("amount", 0.0)))
			if n.has_method("_play_sparkle_burst"):
				n._play_sparkle_burst()
			return true
		"statue_pet":
			if n.has_method("_spawn_pet_text"):
				n._spawn_pet_text(float(args.get("amount", 0.0)))
			if n.has_method("_triumphant_quack"):
				n._triumphant_quack()
			return true
		"block_hit":
			if n.has_method("_play_hit"):
				n._play_hit()
				return true
		"radar_flash":
			if n.has_method("_trigger_flash"):
				n._trigger_flash(float(args.get("intensity", 1.0)))
				return true
		"bowling_text":
			if n.has_method("_spawn_bowling_label"):
				n._spawn_bowling_label(float(args.get("value", 1.0)))
				return true
		"collect":
			var cam = a.main_camera()
			if cam != null and cam.get("picked_object") == n:
				a.release_held_object()
			n.queue_free()
			return true
		"press_start":
			if n.has_method("start_pressing") and not bool(n.get("is_pressing")):
				n.start_pressing()
				return true
	return false
