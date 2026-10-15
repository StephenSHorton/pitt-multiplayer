extends RefCounted
## Adds our nodes to a live MainMenu instance. Idempotent: returns the existing
## nodes when Background/MenuButtons/MPMultiplayer is already there. Re-run on
## every main-menu instance (returning from gameplay re-creates the menu;
## Options / Credits only hide it, so our nodes survive those).
##
##   Background/MenuButtons/MPMultiplayer   duplicate of Play, inserted right after it
##   Background/MPHostJoin, MPLobby, MPJoin  sibling panels laid out like MenuLoad
##   Background/MPLobbyMembers               full-rect, centred member list
##   Background/MPRouter                     panel stack + Esc

const Style = preload("ui_style.gd")
const Router = preload("mp_router.gd")
const HostJoinPanel = preload("host_join_panel.gd")
const LobbyPanel = preload("lobby_panel.gd")
const JoinPanel = preload("join_panel.gd")
const FitWidth = preload("fit_width.gd")

const BUTTON_NAME := "MPMultiplayer"
const PATH_BUTTONS := "Background/MenuButtons"
const PATH_PLAY := "Background/MenuButtons/Play"
const PATH_LOAD := "Background/MenuLoad"
const PATH_TEMPLATE := "Background/MenuLoad/New"
const PATH_SCROLL := "Background/MenuLoad/ScrollContainer"
const PANELS := ["MPHostJoin", "MPLobby", "MPJoin"]
const MEMBERS_GAP := 48.0


## True if menu has the node paths we need.
static func can_inject(menu: Node) -> bool:
	return menu != null and is_instance_valid(menu) and menu.get_node_or_null(PATH_PLAY) is Button \
		and menu.get_node_or_null(PATH_LOAD) is Control and menu.get_node_or_null(PATH_TEMPLATE) is Button


static func is_injected(menu: Node) -> bool:
	return menu != null and is_instance_valid(menu) and menu.get_node_or_null(PATH_BUTTONS + "/" + BUTTON_NAME) != null


## Returns {ok, button, router, panels: {name: Control}, members_root, fresh: bool}.
static func inject(menu: Node, ui) -> Dictionary:
	if not can_inject(menu):
		return {"ok": false}
	var bg: Control = menu.get_node("Background")
	if is_injected(menu):
		var existing := {"ok": true, "fresh": false, "button": menu.get_node(PATH_BUTTONS + "/" + BUTTON_NAME),
			"router": bg.get_node_or_null("MPRouter"), "members_root": bg.get_node_or_null("MPLobbyMembers"), "panels": {}}
		for p in PANELS:
			existing.panels[p] = bg.get_node_or_null(p)
		return existing

	var buttons: Control = menu.get_node(PATH_BUTTONS)
	var play: Button = menu.get_node(PATH_PLAY)
	var load_panel: Control = menu.get_node(PATH_LOAD)
	var template: Button = menu.get_node(PATH_TEMPLATE)
	var scroll: Control = menu.get_node_or_null(PATH_SCROLL)

	var router: Node = Router.new()
	router.setup(menu, buttons)
	ui.router = router

	# 1. the Multiplayer button: a duplicate of the real Play button
	var column_width: float = buttons.offset_right - buttons.offset_left
	if column_width <= 0.0:
		column_width = buttons.size.x
	var mp: Button = Style.clone_button(play, BUTTON_NAME, "MP_MULTIPLAYER")
	_copy_scale_meta(play, mp)
	buttons.add_child(mp)
	buttons.move_child(mp, play.get_index() + 1)
	router.wire(mp, func(): ui.multiplayer_pressed())
	# same font and size as Play, unless the label is wider than the column:
	# then the largest size that fits, so the game's column keeps its layout
	var fitter = FitWidth.new()
	fitter.setup(mp, play, buttons, column_width)
	mp.add_child(fitter)
	fitter.fit()

	# 2. panels, right after MenuLoad / MenuSandbox in the tree (same theme inheritance)
	var after := load_panel.get_index()
	var sandbox := bg.get_node_or_null("MenuSandbox")
	if sandbox != null:
		after = maxi(after, sandbox.get_index())

	# member list: the free area right of the menu column (the column is where
	# the title and buttons are; a list under them would overlap at 16:9 and 4:3).
	# Accepted deviation from "center of the screen", recorded in
	# docs/MULTIPLAYER-UI-SPEC.md (owner to confirm).
	var members_root := Control.new()
	members_root.name = "MPLobbyMembers"
	members_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	members_root.offset_left = load_panel.offset_right + MEMBERS_GAP
	members_root.offset_right = -MEMBERS_GAP
	members_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	members_root.visible = false

	var host_join: VBoxContainer = Style.make_panel("MPHostJoin", load_panel, HostJoinPanel)
	var lobby_panel: VBoxContainer = Style.make_panel("MPLobby", load_panel, LobbyPanel)
	var join_panel: VBoxContainer = Style.make_panel("MPJoin", load_panel, JoinPanel)
	host_join.build(ui, template)
	join_panel.build(ui, template, scroll)
	lobby_panel.build(ui, template, scroll, members_root)
	for b in _buttons_of([host_join, join_panel, lobby_panel]):
		_copy_scale_meta(template, b)

	var idx := after + 1
	for n in [host_join, lobby_panel, join_panel, members_root]:
		bg.add_child(n)
		bg.move_child(n, idx)
		idx += 1
	bg.add_child(router)

	router.add_panel("MPHostJoin", host_join)
	router.add_panel("MPLobby", lobby_panel)
	router.add_panel("MPJoin", join_panel)

	# 3. MenuButtons keeps the engine's automatic focus neighbours (the game sets
	# none there), so the inserted button is reachable with up/down like the others.
	menu.set_meta("pittmp_ui", ui)
	var mm := menu.get_tree().root.get_node_or_null("MenuManager") if menu.is_inside_tree() else null
	if mm != null and mm.has_method("apply_menu_scales"):
		mm.apply_menu_scales()
	fitter.fit()
	return {"ok": true, "fresh": true, "button": mp, "router": router, "members_root": members_root,
		"panels": {"MPHostJoin": host_join, "MPLobby": lobby_panel, "MPJoin": join_panel}}


## MenuManager scales fonts from meta "base_font_size"; a duplicate must keep the
## template's unscaled base, or every apply_menu_scales would shrink it again.
static func _copy_scale_meta(src: Control, dst: Control) -> void:
	if src.has_meta("base_font_size"):
		dst.set_meta("base_font_size", src.get_meta("base_font_size"))
		dst.add_theme_font_size_override("font_size", src.get_theme_font_size("font_size"))


static func _buttons_of(panels: Array) -> Array:
	var out: Array = []
	for p in panels:
		for c in p.get_children():
			if c is Button:
				out.append(c)
	return out
