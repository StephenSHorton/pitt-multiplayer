extends Node
## UI root of PittMultiplayer (STREAM UI). Owns the main-menu injection, the
## panel router, dialogs and join-request routing. Talks to LobbyService (host,
## join, scan) and Session (start, cancel, leave) only through their 5.3 / 5.4
## members; never calls Steam and never calls lobby.leave() (session.leave()
## does that).
##
## Composition (NET main.gd): ui = load(api.path("ui/mp_ui.gd")).new();
## add_child(ui); ui.setup(api, lobby, session).

const Injector = preload("menu_injector.gd")
const Dialogs = preload("dialogs.gd")
const Contract = preload("contract_ui.gd")
const Model = preload("../lobby/lobby_model.gd")

const GROUP := "pittmp_ui"
const MAIN_MENU_GROUP := "MainMenu"
const DIALOG_DEDUPE_MS := 1500
const SILENT_END_REASONS := ["left", "ending"]

var api = null
var lobby: Node = null
var session: Node = null
var router: Node = null           # MpMenuRouter of the current menu instance (or null)
var menu: Node = null             # current MainMenu instance (or null)
var dialogs = Dialogs.new()
var nodes: Dictionary = {}        # injector result for the current menu
var last_session_info: Dictionary = {}
var last_lobby_op := ""           # "host" | "join" while waiting for lobby_entered
var pending_join_id := ""         # join request that arrived in a world
var contract_ok := true
var contract_missing: Array = []

var _last_dialog_ms := -100000
var _last_error_ms := -100000
var _launch_join_checked := false
var _launch_join_tries := 0
const LAUNCH_JOIN_RETRIES := 20
const LAUNCH_JOIN_RETRY_S := 0.5
var _sub_scene := -1


func _init() -> void:
	name = "MpUI"
	process_mode = Node.PROCESS_MODE_ALWAYS


func setup(p_api: Object, p_lobby: Node, p_session: Node) -> void:
	api = p_api
	lobby = p_lobby
	session = p_session
	if not is_in_group(GROUP):
		add_to_group(GROUP)
	_check_contract()
	if lobby != null:
		lobby.lobby_left.connect(_on_lobby_left)
		lobby.lobby_entered.connect(_on_lobby_entered)
		lobby.join_requested.connect(_on_join_requested)
		lobby.error.connect(_on_lobby_error)
	if session != null:
		if session.has_signal("state_changed"):
			session.state_changed.connect(_on_session_state)
		if session.has_signal("ended"):
			session.ended.connect(_on_session_ended)
	if api != null and api.get("events") != null:
		_sub_scene = api.events.on("scene.changed", _on_scene_changed)
	_try_inject_current.call_deferred()


func _exit_tree() -> void:
	if api != null and api.get("events") != null and _sub_scene >= 0:
		api.events.off(_sub_scene)
		_sub_scene = -1


## Used by main_menu_ext only.
func is_host_picking() -> bool:
	return router != null and is_instance_valid(router) and router.picking


# ------------------------------------------------------------------ injection

func _on_scene_changed(ev) -> void:
	var kind := str(ev.payload.get("kind", "")) if ev != null else ""
	if kind == "main_menu":
		_inject_later()
	else:
		_forget_menu()


func _inject_later() -> void:
	await get_tree().process_frame
	_try_inject_current()


func _try_inject_current() -> void:
	if not is_inside_tree():
		return
	var m := _find_menu()
	if m != null:
		inject(m)


func _find_menu() -> Node:
	var tree := get_tree()
	var m := tree.get_first_node_in_group(MAIN_MENU_GROUP)
	if m == null and tree.current_scene != null and Injector.can_inject(tree.current_scene):
		m = tree.current_scene
	return m if m != null and Injector.can_inject(m) else null


## Injects into a MainMenu instance (also called by tests). Idempotent.
func inject(m: Node) -> bool:
	var r: Dictionary = Injector.inject(m, self)
	if not r.get("ok", false):
		return false
	menu = m
	nodes = r
	router = r.router
	if not m.has_meta("pittmp_exit_hook"):
		m.set_meta("pittmp_exit_hook", true)
		m.tree_exiting.connect(_on_menu_exiting.bind(m))
	_update_button()
	if r.get("fresh", false):
		_after_inject.call_deferred()
	return true


func _on_menu_exiting(m: Node) -> void:
	if menu == m:
		_forget_menu()


func _forget_menu() -> void:
	menu = null
	router = null
	nodes = {}


func _after_inject() -> void:
	if menu == null:
		return
	# no ghost lobbies: back on the menu without a session means we must not be in one
	if lobby != null and lobby.is_in_lobby() and session != null and _session_state() == "idle":
		session.leave("left")
	# the end-of-session dialog (ended fired before the scene change back here)
	if session != null and session.has_method("consume_last_end"):
		var e: Dictionary = session.consume_last_end()
		if not e.is_empty() and not (str(e.get("reason", "")) in SILENT_END_REASONS):
			_show_end_dialog("MP_END_" + str(e.reason).to_upper(), str(e.get("detail", "")))
	# +connect_lobby from the launch command line, once
	_check_launch_join()
	# an invite accepted while in a world
	if pending_join_id != "":
		var pid := pending_join_id
		pending_join_id = ""
		dialogs.confirm(menu, "MP_JOIN_PENDING_TITLE", "MP_JOIN_PENDING_BODY", func(): _join_from_menu(pid),
			"MP_JOIN", "MENU_CANCEL", nodes.get("button"))


## The launch "Join Game" is consumed only once the join can actually run:
## while Steamworks is still initialising (MP_ERR_NO_STEAM) it is retried for
## a few seconds instead of being lost.
func _check_launch_join() -> void:
	if _launch_join_checked or lobby == null or not lobby.has_method("take_launch_join"):
		return
	var av := availability()
	if not av.ok and str(av.get("reason", "")) == "MP_ERR_NO_STEAM" and _launch_join_tries < LAUNCH_JOIN_RETRIES:
		_launch_join_tries += 1
		if is_inside_tree():
			get_tree().create_timer(LAUNCH_JOIN_RETRY_S, true).timeout.connect(_check_launch_join)
		return
	_launch_join_checked = true
	var id: String = lobby.take_launch_join()
	if id != "":
		_on_join_requested(id)


func availability() -> Dictionary:
	if not contract_ok:
		return {"ok": false, "reason": "MP_ERR_INCOMPATIBLE_BUILD"}
	if lobby != null and lobby.has_method("available"):
		var a: Dictionary = lobby.available()
		if not bool(a.get("ok", true)):
			return {"ok": false, "reason": str(a.get("reason", "MP_ERR_NO_STEAM"))}
	return {"ok": true, "reason": ""}


func _update_button() -> void:
	var b: Button = nodes.get("button")
	if b == null:
		return
	var av := availability()
	b.disabled = not av.ok
	b.tooltip_text = tr(av.reason) if not av.ok else ""


func _check_contract() -> void:
	contract_ok = true
	contract_missing = []
	if api != null and api.has_method("contract_check"):
		var r = api.contract_check(Contract.ENTRIES)
		if typeof(r) == TYPE_DICTIONARY:
			contract_ok = bool(r.get("ok", true))
			contract_missing = r.get("missing", [])


# ------------------------------------------------------------------ button handlers

func multiplayer_pressed() -> void:
	if router == null:
		return
	router.push("MPHostJoin")


func host_pressed() -> void:
	if lobby == null or not availability().ok:
		return
	last_lobby_op = "host"
	router.push("MPLobby")
	lobby.host(Model.MAX_MEMBERS)
	_redraw_lobby()


func join_lobby(id: String) -> void:
	if lobby == null or id == "":
		return
	last_lobby_op = "join"
	router.push("MPLobby")
	lobby.join(id)
	_redraw_lobby()


func start_pressed() -> void:
	if session == null or lobby == null or not lobby.is_owner():
		return
	var cs: Dictionary = session.can_start() if session.has_method("can_start") else {"ok": true}
	if not bool(cs.get("ok", false)):
		return
	var err: int = session.start_game()
	if err != OK:
		_notice("MP_ERROR_TITLE", "MP_ERR_START_FAILED")
		return
	router.begin_host_pick()


func invite_pressed() -> void:
	if lobby != null and lobby.is_owner():
		lobby.invite_friends()


func leave_pressed() -> void:
	if lobby != null and not lobby.is_in_lobby() and (not lobby.has_method("is_pending") or lobby.is_pending() == ""):
		# nothing to leave (e.g. the create failed): just go back
		_leave_now()
		return
	var body := "MP_CONFIRM_CLOSE_LOBBY_BODY" if lobby != null and lobby.is_owner() else "MP_CONFIRM_LEAVE_BODY"
	var focus: Control = null
	var lp = nodes.get("panels", {}).get("MPLobby")
	if lp != null:
		focus = lp.leave_button
	dialogs.confirm(menu, "MP_CONFIRM_LEAVE_TITLE", body, func(): _leave_now(), "MP_LEAVE", "MENU_CANCEL", focus)


func _leave_now() -> void:
	last_lobby_op = ""
	if session != null:
		session.leave("left")
	_pop_lobby_if_gone()


## main_menu_ext: the game is about to launch the world while the host picks a save.
func on_host_launch(scene_path: String) -> void:
	if router != null:
		router.picking = false
	if session != null and session.has_method("notify_host_launch"):
		session.notify_host_launch(scene_path)


## main_menu_ext: Back from the save panel while picking.
func on_host_pick_cancelled() -> void:
	if router == null:
		return
	router.end_host_pick(true)
	if session != null and session.has_method("cancel_start"):
		session.cancel_start()
	_redraw_lobby()


## main_menu_ext: Sandbox while picking.
func on_sandbox_blocked() -> void:
	if api != null and api.get("hud") != null:
		api.hud.toast(tr("MP_SANDBOX_UNSUPPORTED"))


## main_menu_ext: _focus_current_panel. True when one of our panels took focus.
func focus_current_panel() -> bool:
	if router == null or is_host_picking():
		return false
	return router.focus_current()


# ------------------------------------------------------------------ lobby / session events

func _on_lobby_entered(_info: Dictionary) -> void:
	last_lobby_op = ""
	_redraw_lobby()


func _on_lobby_left(reason: String) -> void:
	last_lobby_op = ""
	if router != null:
		if router.picking:
			router.end_host_pick(false)
		router.pop_past("MPLobby")
	if reason in ["host_left", "kicked", "join_failed", "error"]:
		_lobby_left_dialog.call_deferred(reason)


func _lobby_left_dialog(reason: String) -> void:
	if Time.get_ticks_msec() - _last_dialog_ms < DIALOG_DEDUPE_MS:
		return
	if reason in ["join_failed", "error"] and Time.get_ticks_msec() - _last_error_ms < DIALOG_DEDUPE_MS:
		return   # the error signal already explained it
	_show_end_dialog("MP_LOBBY_" + reason.to_upper(), "")


func _on_lobby_error(code: String, detail: String) -> void:
	_last_error_ms = Time.get_ticks_msec()
	if menu != null and is_instance_valid(menu):
		_notice("MP_ERROR_TITLE", code)
	elif api != null and api.get("hud") != null:
		api.hud.toast(tr(code))


func _on_session_state(state: String, info: Dictionary) -> void:
	last_session_info = info.duplicate() if info != null else {}
	if router == null:
		return
	if state == "idle":
		if router.picking:
			router.end_host_pick(false)
		_pop_lobby_if_gone()
	_redraw_lobby()


func _on_session_ended(reason: String, detail: String) -> void:
	if reason in SILENT_END_REASONS:
		return
	# on the menu (e.g. waiting in the lobby when the host left): show it now;
	# in a world the menu is re-instanced and consume_last_end() shows it there.
	if menu != null and is_instance_valid(menu) and menu.is_inside_tree() and _session_state() != "loading":
		if session.has_method("consume_last_end"):
			session.consume_last_end()
		_show_end_dialog("MP_END_" + reason.to_upper(), detail)


func _on_join_requested(id: String) -> void:
	if id == "":
		return
	var st := _session_state()
	var on_menu := menu != null and is_instance_valid(menu) and menu.is_inside_tree()
	if not on_menu or st == "loading" or st == "in_game":
		pending_join_id = id
		if api != null and api.get("hud") != null:
			api.hud.toast(tr("MP_JOIN_FROM_MENU"))
		return
	if lobby != null and (lobby.is_in_lobby() or (session != null and session.has_method("is_live") and session.is_live())):
		if lobby.is_in_lobby() and str(lobby.current().get("id", "")) == id:
			router.push("MPLobby")
			return
		dialogs.confirm(menu, "MP_CONFIRM_SWITCH_TITLE", "MP_CONFIRM_SWITCH_BODY", func(): _switch_to(id),
			"MP_JOIN", "MENU_CANCEL", null)
		return
	_join_from_menu(id)


func _switch_to(id: String) -> void:
	if session != null:
		session.leave("left")
	if router != null and router.picking:
		router.end_host_pick(false)
	_pop_lobby_if_gone()
	_join_from_menu.call_deferred(id)


func _join_from_menu(id: String) -> void:
	if router == null or lobby == null:
		return
	if lobby.is_in_lobby():
		return
	if not availability().ok:
		_notice("MP_ERROR_TITLE", availability().reason)
		return
	if not router.has("MPHostJoin"):
		router.push("MPHostJoin")
	join_lobby(id)


# ------------------------------------------------------------------ helpers

func _pop_lobby_if_gone() -> void:
	if router == null or lobby == null:
		return
	if not lobby.is_in_lobby() and (not lobby.has_method("is_pending") or lobby.is_pending() == ""):
		router.pop_past("MPLobby")


func _redraw_lobby() -> void:
	var lp = nodes.get("panels", {}).get("MPLobby")
	if lp != null and is_instance_valid(lp):
		lp.redraw()


func _session_state() -> String:
	if session != null and session.has_method("get_state"):
		return str(session.get_state())
	return "idle"


func _show_end_dialog(body_key: String, detail: String) -> void:
	_last_dialog_ms = Time.get_ticks_msec()
	var body := tr(body_key)
	if detail != "" and detail != body_key:
		body = "%s\n%s" % [body, detail]
	_notice("MP_END_TITLE", body)


func _notice(title_key: String, body: String) -> void:
	var focus: Control = nodes.get("button")
	dialogs.notice(menu, title_key, body, focus)
