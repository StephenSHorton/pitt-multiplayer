extends Node
## MpMenuRouter: panel stack for our main-menu panels, swapped exactly like the
## game swaps MenuButtons <-> MenuLoad (visible flags, _temporarily_ignore_input,
## grab_focus when InputManager.using_gamepad).
##
## It lives under Background, so its _unhandled_input runs before MainMenu's
## (children first); it handles ui_cancel for our panels and marks it handled, so
## the game's quit dialog never opens from our panels.
##
## Host-picking mode: the host pressed Start and the game's own save panel
## (MenuLoad) is open on top of our stack; main_menu_ext routes Back / Sandbox /
## _launch_game through mp_ui while `picking` is true.

signal panel_changed(top: String)

var menu: Node = null            # the MainMenu CanvasLayer
var buttons_panel: Control = null   # Background/MenuButtons
var panels: Dictionary = {}      # name -> panel Control (has on_shown/on_hidden/on_back/first_focus)
var stack: Array[String] = []
var picking := false


func setup(p_menu: Node, p_buttons: Control) -> void:
	menu = p_menu
	buttons_panel = p_buttons
	name = "MPRouter"
	process_mode = Node.PROCESS_MODE_ALWAYS


func add_panel(panel_name: String, panel: Control) -> void:
	panels[panel_name] = panel


func top() -> String:
	return stack[-1] if not stack.is_empty() else ""


func top_panel() -> Control:
	return panels.get(top(), null)


func has(panel_name: String) -> bool:
	return panel_name in stack


func is_active() -> bool:
	return not stack.is_empty()


## Shows panel_name on top of the stack (hides MenuButtons or the previous panel).
func push(panel_name: String) -> void:
	if not panels.has(panel_name):
		return
	if top() == panel_name:
		_show_top()
		return
	if panel_name in stack:
		pop_to(panel_name)
		return
	_hide_current()
	stack.append(panel_name)
	_show_top()


## Removes the top panel and shows the one below (or MenuButtons).
func pop() -> void:
	if stack.is_empty():
		return
	var name_ := stack.pop_back() as String
	_hide(name_)
	_show_top()


## Pops until panel_name is on top (no-op if it is not in the stack).
func pop_to(panel_name: String) -> void:
	if not (panel_name in stack):
		return
	while not stack.is_empty() and top() != panel_name:
		_hide(stack.pop_back())
	_show_top()


## Pops panel_name and everything above it.
func pop_past(panel_name: String) -> void:
	if not (panel_name in stack):
		return
	while not stack.is_empty():
		var n := stack.pop_back() as String
		_hide(n)
		if n == panel_name:
			break
	_show_top()


func pop_to_root() -> void:
	while not stack.is_empty():
		_hide(stack.pop_back())
	_show_top()


## Host pressed Start: hide our stack and open the game's own save panel.
func begin_host_pick() -> void:
	picking = true
	var p := top_panel()
	if p != null:
		p.visible = false
	if menu != null and menu.has_method("_on_play_pressed"):
		menu._on_play_pressed()


## Back from the save panel while picking: MenuLoad hides, our top panel returns.
func end_host_pick(show_ours: bool = true) -> void:
	if not picking:
		return
	picking = false
	var load_panel := _menu_node("Background/MenuLoad")
	var sandbox := _menu_node("Background/MenuSandbox")
	if load_panel != null:
		load_panel.visible = false
	if sandbox != null:
		sandbox.visible = false
	if show_ours:
		_show_top()


func _hide_current() -> void:
	if stack.is_empty():
		if buttons_panel != null:
			buttons_panel.visible = false
		# a join request may arrive while the game's own panels are open
		for p in ["Background/MenuLoad", "Background/MenuSandbox"]:
			var n := _menu_node(p)
			if n != null and n.visible and not picking:
				n.visible = false
	else:
		_hide(top())


func _hide(panel_name: String) -> void:
	var p: Control = panels.get(panel_name, null)
	if p == null:
		return
	p.visible = false
	if p.has_method("on_hidden"):
		p.on_hidden()


func _show_top() -> void:
	if stack.is_empty():
		if buttons_panel != null:
			buttons_panel.visible = true
		_after_swap(buttons_panel)
		panel_changed.emit("")
		return
	if buttons_panel != null:
		buttons_panel.visible = false
	var p := top_panel()
	if p == null:
		return
	p.visible = true
	if p.has_method("on_shown"):
		p.on_shown()
	_after_swap(p)
	panel_changed.emit(top())


func _after_swap(focus_root: Control) -> void:
	if menu != null and menu.has_method("_temporarily_ignore_input") and menu.is_inside_tree():
		menu._temporarily_ignore_input()
	if _using_gamepad():
		focus_current.call_deferred()


## Focuses the first enabled button of the visible top panel. True if ours is visible.
func focus_current() -> bool:
	var p := top_panel()
	if p == null or not p.visible:
		if stack.is_empty() and buttons_panel != null and buttons_panel.visible and _using_gamepad():
			if menu != null and menu.has_method("_grab_first_button"):
				menu._grab_first_button(buttons_panel)
		return false
	var f: Control = p.first_focus() if p.has_method("first_focus") else null
	if f != null and f.is_inside_tree():
		f.grab_focus()
	return true


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	if stack.is_empty() or picking:
		return
	var p := top_panel()
	if p == null or not p.is_visible_in_tree():
		return
	if menu != null and menu.get("ignore_input") == true:
		get_viewport().set_input_as_handled()
		return
	get_viewport().set_input_as_handled()
	back()


## Esc / Back button on the top panel.
func back() -> void:
	var p := top_panel()
	if p != null and p.has_method("on_back"):
		p.on_back()
	else:
		pop()


## Wires a button like the game's menu buttons: hover sound, ignore_input gate,
## click sound, then cb.
func wire(b: BaseButton, cb: Callable, click: bool = true) -> void:
	if menu != null and menu.has_method("_on_mouse_entered"):
		b.mouse_entered.connect(menu._on_mouse_entered)
	b.pressed.connect(func():
		if menu != null and menu.get("ignore_input") == true:
			return
		if click:
			play_click()
		cb.call())


func play_click() -> void:
	if menu != null and menu.has_method("_play_ui_sound"):
		menu._play_ui_sound(menu.get("click_sound"))


func _menu_node(path: String) -> Control:
	if menu == null or not is_instance_valid(menu):
		return null
	return menu.get_node_or_null(path) as Control


func _using_gamepad() -> bool:
	if not is_inside_tree():
		return false
	var im := get_tree().root.get_node_or_null("InputManager")
	return im != null and im.get("using_gamepad") == true
