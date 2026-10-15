extends VBoxContainer
## Host / Join screen: Host, Join, Back. A sibling of MenuLoad with its layout;
## the buttons are clones of MenuLoad/New (font size 52 + overrides).

const Style = preload("ui_style.gd")

var ui = null
var host_button: Button = null
var join_button: Button = null
var back_button: Button = null


func build(p_ui, template: Button) -> void:
	ui = p_ui
	host_button = Style.clone_button(template, "Host", "MP_HOST")
	join_button = Style.clone_button(template, "Join", "MP_JOIN")
	back_button = Style.clone_button(template, "Return", "MENU_BACK")
	for b in [host_button, join_button, back_button]:
		add_child(b)
	ui.router.wire(host_button, func(): ui.host_pressed())
	ui.router.wire(join_button, func(): ui.router.push("MPJoin"))
	ui.router.wire(back_button, func(): ui.router.pop())


func on_shown() -> void:
	var av: Dictionary = ui.availability()
	host_button.disabled = not av.ok
	join_button.disabled = not av.ok
	host_button.tooltip_text = tr(av.reason) if not av.ok else ""
	join_button.tooltip_text = host_button.tooltip_text
	Style.chain_focus([host_button, join_button, back_button])


func on_hidden() -> void:
	pass


func on_back() -> void:
	ui.router.play_click()
	ui.router.pop()


func first_focus() -> Control:
	return Style.first_button(self)
