extends "res://scripts/upgradeUI.gd"
## PittMultiplayer: client purchases go through the host (MP-DESIGN 6.5).
## Inert unless a session is live and this peer is a client: the vanilla path
## always runs first (super) and single player is unchanged. No game code is
## copied: rows are created by super, then sync/purchases.gd swaps the button's
## single pressed connection for one that sends a command to the host. The
## feedback below only calls the terminal's own helpers. _ready is not
## overridden (the is_mirror early return stays the game's).
## MP2 (MP2-DESIGN 6.1): bought tools and toys exist once, spawned by the HOST's
## terminal; a client spawns only the fixtures every peer builds itself (press,
## trading terminal, bowling set: from its save flags or a fixture_spawn), and the
## host tells clients when it spawned one. Recall runs on the host and never yanks a
## unit a remote player holds. All of it is inert without an MP2 session (mp_gate).

const G = preload("../gameplay/mp_gate.gd")
const _MP_FIXTURE_TOOLS := ["press", "trading"]
const _MP_FIXTURE_TOYS := ["bowling_pin_set"]


func _mp() -> Object:
	return Engine.get_meta("pitt_mp", null) if Engine.has_meta("pitt_mp") else null


## (a mirror terminal never sells, so its rows are left alone)
func _mp_rewire(row: HBoxContainer, kind: String, args: Dictionary) -> void:
	var mp := _mp()
	if mp != null and mp.has_method("ext_rewire_row") and not has_meta("is_mirror"):
		mp.ext_rewire_row(self, row, kind, args)


func _create_upgrade_row(category: String, key: String, subkey: = "") -> HBoxContainer:
	var row: HBoxContainer = super(category, key, subkey)
	_mp_rewire(row, "item", {"category": category, "key": key, "subkey": subkey})
	return row


func _create_tool_buy_row(tool_name: String, level: int, display_name: = "", display_level: = -1) -> HBoxContainer:
	var row: HBoxContainer = super(tool_name, level, display_name, display_level)
	_mp_rewire(row, "tool", {"tool": tool_name, "level": level})
	return row


func _create_toy_buy_row(toy_name: String) -> HBoxContainer:
	var row: HBoxContainer = super(toy_name)
	_mp_rewire(row, "toy", {"toy": toy_name})
	return row


## A live part (label / button meta) of a row that is still in use, else null.
static func _mp_row_part(row: Object, part: String):
	if row == null or not is_instance_valid(row) or row.is_queued_for_deletion() or not row.has_meta(part):
		return null
	var node = row.get_meta(part)
	return node if is_instance_valid(node) else null


## Called by sync/purchases.gd when the host answered. The feedback is the
## terminal's own (its sound, pulse, shake and floating-text helpers):
##   upgrade ok: upgrade sound, success burst on the button, label pulse, refresh
##   tool/toy ok: credits + row refresh, buy sound, button pulse, harder shake
##   refused: error sound, label flash, button shake, a red reason
func _mp_purchase_feedback(row: Object, kind: String, ok: bool, code: String, args: Dictionary) -> void:
	var lbl = _mp_row_part(row, "label")
	var btn = _mp_row_part(row, "button")
	var is_upgrade := kind == "item"
	if not ok:
		_mp_purchase_refused(lbl, btn, is_upgrade, code)
		return
	var sfx: AudioStream = buy_sound
	if is_upgrade and upgrade_sound:
		sfx = upgrade_sound
	if is_upgrade:
		_play_sound(sfx, 0.1)
		if btn:
			_create_success_effect(btn)
	else:
		update_credits()
		if row != null and is_instance_valid(row) and not row.is_queued_for_deletion():
			match kind:
				"tool": _refresh_tool_buy_row(row)
				"toy": _refresh_toy_buy_row(row)
		_play_sound(sfx, 0.12)
	var pulse_target = lbl if is_upgrade else btn
	if pulse_target:
		_pulse_node(pulse_target, COLOR_DIM, 0.3)
	if is_upgrade:
		_screen_shake(1.5, 0.08)
		mp_request_refresh(true)
	else:
		_screen_shake(2.0, 0.1)
	if btn:
		_spawn_floating_text(btn, tr("UI_UPGRADED" if is_upgrade else "UI_PURCHASED"), COLOR_DIM)


func _mp_purchase_refused(lbl, btn, is_upgrade: bool, code: String) -> void:
	_play_sound(error_sound, 0.15 if is_upgrade else 0.1)
	if btn and is_upgrade:
		_create_error_effect(btn)
	if lbl:
		_flash_label(lbl, COLOR_RED)
	if btn:
		_enhanced_shake_node(btn)
	_screen_shake(0.8, 0.04)
	var reasons := {"ERR_UNAVAILABLE": "MP_SHOP_UNAVAILABLE", "ERR_DENIED": "UI_LOCKED"}
	var key: String = reasons.get(code, "UI_INSUFFICIENT_CREDITS" if is_upgrade else "UI_INSUFFICIENT_FUNDS")
	if btn:
		_spawn_floating_text(btn, tr(key), COLOR_RED)


func _spawn_tool_instance(tool_name: String, level: int) -> void:
	if G.is_client() and not G.applying() and not (tool_name in _MP_FIXTURE_TOOLS):
		return
	super(tool_name, level)
	if tool_name in _MP_FIXTURE_TOOLS:
		G.fixture_spawned(tool_name, level)


func _spawn_toy_instance(toy_name: String) -> void:
	if G.is_client() and not G.applying() and not (toy_name in _MP_FIXTURE_TOYS):
		return
	super(toy_name)
	if toy_name in _MP_FIXTURE_TOYS:
		G.fixture_spawned(toy_name, 0)


func _recall_tool(tool_name: String) -> int:
	if G.is_client() and not G.applying():
		# the host recalls (its units are the world's); the row shows "recalled"
		G.recall(tool_name)
		return 1
	return super(tool_name)


func _unit_owned_elsewhere(unit: Node) -> bool:
	if G.remote_owned(unit):
		return true
	return super(unit)


# ------------------------------------------------------------------ live refresh (0.2.2)
# Another player's purchase, an unlock or a money change reaches this peer as
# replicated state; the game refreshes its open menu only after its own purchases.
# Requests are coalesced to one per frame; nothing happens while the menu is closed
# (show_menu rebuilds it). Structural (levels, prices, unlocks, items): the game's
# update_ui with the viewer's scroll and focused row kept. Money only: the credits
# label and the game's per-row refreshers, in place (no rebuild, no flicker). The
# terminal's world-screen mirror (meta is_mirror) is a snapshot in the game too.

var _mp_refresh := 0           # 0 none, 1 money, 2 structural (pending this frame)


func mp_request_refresh(structural: bool) -> void:
	if has_meta("is_mirror") or not is_inside_tree():
		return
	var want := 2 if structural else 1
	if _mp_refresh >= want:
		return
	var was := _mp_refresh
	_mp_refresh = want
	if was == 0:
		get_tree().process_frame.connect(_mp_do_refresh, CONNECT_ONE_SHOT)


func _mp_do_refresh() -> void:
	var kind := _mp_refresh
	_mp_refresh = 0
	if not visible or not is_inside_tree():
		return
	if kind == 1:
		update_credits()
		for row in _mp_live_rows():
			var btn = _mp_row_part(row, "button")
			if btn is Button:
				(btn as Button).add_theme_color_override("font_color", COLOR_GREEN)
			var refresher := _mp_row_refresher(row)
			if refresher != "":
				call(refresher, row)
		return
	var scrolls := {}
	for sc in find_children("*", "ScrollContainer", true, false):
		scrolls[sc] = (sc as ScrollContainer).scroll_vertical
	var focus_id := _mp_row_id(get_viewport().gui_get_focus_owner())
	update_ui()
	update_credits()
	await get_tree().process_frame
	for sc in scrolls:
		if is_instance_valid(sc):
			(sc as ScrollContainer).scroll_vertical = int(scrolls[sc])
	if focus_id != "":
		for row in _mp_live_rows():
			if _mp_row_id(_mp_row_part(row, "button")) == focus_id:
				var b = _mp_row_part(row, "button")
				if b is Control and (b as Control).is_visible_in_tree():
					(b as Control).grab_focus()
				break


## The game's in-place refresher for a row kind ("" = none).
static func _mp_row_refresher(row: Node) -> String:
	for kind in [["tool_name", "_refresh_tool_buy_row"], ["toy_name", "_refresh_toy_buy_row"],
			["category", "_refresh_upgrade_row"]]:
		if row.has_meta(kind[0]) and row.has_meta("label"):
			return String(kind[1])
	return ""


func _mp_live_rows() -> Array:
	var out: Array = []
	for r in find_children("*", "HBoxContainer", true, false):
		if r.has_meta("button") and not r.is_queued_for_deletion():
			out.append(r)
	return out


## The row identity of a focused button ("" if it is not a row button).
func _mp_row_id(c) -> String:
	if c == null or not is_instance_valid(c) or not (c is Node):
		return ""
	var row = (c as Node).get_parent()
	if row == null or not row.has_meta("button") or row.get_meta("button") != c:
		return ""
	for k in ["tool_name", "toy_name"]:
		if row.has_meta(k):
			return "%s:%s:%s" % [k, str(row.get_meta(k)), str(row.get_meta("level", ""))]
	return "item:%s:%s:%s" % [str(row.get_meta("category", "")), str(row.get_meta("key", "")), str(row.get_meta("subkey", ""))]
