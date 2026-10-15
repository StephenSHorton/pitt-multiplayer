extends RefCounted
## Builds a stub MainMenu with the real node paths of res://scenes/main_menu.tscn
## (Background/MenuButtons/{FeedbackButton,Play,Options,Credits,Quit},
## Background/MenuLoad/{ScrollContainer/SlotContainer,Load,New,Sandbox,Rename,Delete,Return},
## Background/MenuSandbox/..., Background/Version) and the same .tscn signal
## connections for Play. script: the main-menu script to use (the stub, or the
## stub extended by main_menu_ext.gd).


static func build(script: Script) -> CanvasLayer:
	var menu: CanvasLayer = CanvasLayer.new()
	menu.set_script(script)
	menu.name = "MainMenu"
	var bg := ColorRect.new()
	bg.name = "Background"
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0, 0, 0, 0)
	menu.add_child(bg)

	var buttons := _panel("MenuButtons", true)
	bg.add_child(buttons)
	var fb := _button("FeedbackButton", "SESSION_FEEDBACK", 42)
	fb.visible = false
	buttons.add_child(fb)
	for n in [["Play", "MENU_PLAY"], ["Options", "MENU_OPTIONS"], ["Credits", "MENU_CREDITS"], ["Quit", "MENU_QUIT"]]:
		buttons.add_child(_button(n[0], n[1], 104))

	var load_panel := _panel("MenuLoad", false)
	bg.add_child(load_panel)
	var scroll := ScrollContainer.new()
	scroll.name = "ScrollContainer"
	scroll.custom_minimum_size = Vector2(100, 200)
	load_panel.add_child(scroll)
	var slots := VBoxContainer.new()
	slots.name = "SlotContainer"
	slots.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(slots)
	for n in [["Load", "MENU_CONTINUE"], ["New", "MENU_NEW_GAME"], ["Sandbox", "MENU_SANDBOX"],
			["Rename", "MENU_SLOT_RENAME"], ["Delete", "MENU_DELETE"], ["Return", "MENU_BACK"]]:
		load_panel.add_child(_button(n[0], n[1], 52))

	var sandbox := _panel("MenuSandbox", false)
	bg.add_child(sandbox)
	for n in [["Continue", "MENU_SANDBOX_CONTINUE"], ["NewCopy", "MENU_SANDBOX_NEW_COPY"],
			["NewFresh", "MENU_SANDBOX_NEW_FRESH"], ["Return", "MENU_BACK"]]:
		sandbox.add_child(_button(n[0], n[1], 104))

	var version := Label.new()
	version.name = "Version"
	bg.add_child(version)

	# the .tscn connections the injector must NOT copy to the duplicate
	var play: Button = buttons.get_node("Play")
	play.pressed.connect(Callable(menu, "_on_play_pressed"))
	play.mouse_entered.connect(Callable(menu, "_on_mouse_entered"))
	buttons.get_node("Quit").pressed.connect(Callable(menu, "_on_quit_pressed"))
	load_panel.get_node("New").pressed.connect(Callable(menu, "_on_new_game"))
	load_panel.get_node("Return").pressed.connect(Callable(menu, "_on_return_save_load"))
	load_panel.get_node("Sandbox").pressed.connect(Callable(menu, "_on_sandbox_pressed"))
	return menu


static func _panel(panel_name: String, visible: bool) -> VBoxContainer:
	var p := VBoxContainer.new()
	p.name = panel_name
	p.anchor_top = 0.5
	p.anchor_bottom = 0.5
	p.offset_left = 49.0
	p.offset_top = -76.0
	p.offset_right = 785.0
	p.offset_bottom = 384.0
	p.grow_vertical = Control.GROW_DIRECTION_BOTH
	p.visible = visible
	return p


static func _button(button_name: String, text: String, size: int) -> Button:
	var b := Button.new()
	b.name = button_name
	b.text = text
	b.add_theme_font_size_override("font_size", size)
	b.set_meta("base_font_size", size)
	return b
