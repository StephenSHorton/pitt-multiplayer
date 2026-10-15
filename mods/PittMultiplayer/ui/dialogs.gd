extends RefCounted
## Wraps the game's own ConfirmDialog (res://scripts/confirm_dialog.gd), set up
## exactly like main_menu._on_delete_save_pressed / _show_slots_full_notice and
## added to the menu. Without the game script (headless) nothing is shown; the
## request is still recorded in `history` for tests.
##
## ConfirmDialog passes title / body through tr(), so already-formatted text works too.

const DIALOG_PATH := "res://scripts/confirm_dialog.gd"

var history: Array = []    # [{title, body, ok_key, cancel_key, has_confirm, node}]
var dialog_script_path := DIALOG_PATH


## Two-button dialog (cancel + confirm). on_ok may be an empty Callable (notice).
func confirm(menu: Node, title_key: String, body: String, on_ok: Callable, ok_key: String = "MENU_BACK",
		cancel_key: String = "MENU_CANCEL", focus: Control = null) -> Node:
	var rec := {"title": title_key, "body": body, "ok_key": ok_key, "cancel_key": cancel_key,
		"on_ok": on_ok, "node": null}
	history.append(rec)
	if menu == null or not is_instance_valid(menu) or not menu.is_inside_tree():
		return null
	if not ResourceLoader.exists(dialog_script_path):
		return null
	var script = load(dialog_script_path)
	if script == null or not script.can_instantiate():
		return null
	var d = script.new()
	var click = menu.get("click_sound")
	var hover = menu.get("hover_sound")
	d.setup(title_key, body, on_ok, ok_key, cancel_key, click, hover, focus)
	menu.add_child(d)
	rec.node = d
	return d


## A notice: the same dialog the game uses for "slots full" (Back closes it).
func notice(menu: Node, title_key: String, body: String, focus: Control = null) -> Node:
	return confirm(menu, title_key, body, Callable(), "MENU_BACK", "MENU_CANCEL", focus)


func last() -> Dictionary:
	return history[-1] if not history.is_empty() else {}


## Test helper: runs the confirm callback of the last dialog.
func accept_last() -> void:
	var r := last()
	if r.is_empty():
		return
	if is_instance_valid(r.get("node")) and r.node.has_method("_on_confirm_pressed"):
		r.node._on_confirm_pressed()
		return
	var cb: Callable = r.on_ok
	if cb.is_valid():
		cb.call()


## Any of our dialogs still open?
func is_open() -> bool:
	for r in history:
		if r.node != null and is_instance_valid(r.node) and r.node.is_inside_tree():
			return true
	return false
