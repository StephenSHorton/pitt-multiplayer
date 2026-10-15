extends RefCounted
## Game members the UI stream uses (MP-DESIGN section 11), in the core contract
## format "feature|target|kind|member". Checked at boot with api.contract_check
## (when the loader provides it) and by tools/contract_check.py against decomp/.
## Any missing member disables multiplayer as a whole (MP_ERR_INCOMPATIBLE_BUILD).

const ENTRIES := [
	"mp.menu|res://scripts/main_menu.gd|method|_launch_game",
	"mp.menu|res://scripts/main_menu.gd|method|_on_play_pressed",
	"mp.menu|res://scripts/main_menu.gd|method|_on_return_save_load",
	"mp.menu|res://scripts/main_menu.gd|method|_on_sandbox_pressed",
	"mp.menu|res://scripts/main_menu.gd|method|_focus_current_panel",
	"mp.menu|res://scripts/main_menu.gd|method|_grab_first_button",
	"mp.menu|res://scripts/main_menu.gd|method|_on_mouse_entered",
	"mp.menu|res://scripts/main_menu.gd|method|_play_ui_sound",
	"mp.menu|res://scripts/main_menu.gd|method|_temporarily_ignore_input",
	"mp.menu|res://scripts/main_menu.gd|method|_unhandled_input",
	"mp.menu|res://scripts/main_menu.gd|prop|ignore_input",
	"mp.menu|res://scripts/main_menu.gd|prop|click_sound",
	"mp.menu|res://scripts/main_menu.gd|prop|hover_sound",
	"mp.menu|res://scripts/main_menu.gd|const|SLOT_COLOR_NORMAL",
	"mp.menu|res://scripts/main_menu.gd|const|SLOT_COLOR_EMPTY",
	"mp.menu|res://scripts/main_menu.gd|const|SLOT_COLOR_SELECTED",
	"mp.menu|res://scripts/confirm_dialog.gd|method|setup",
	"mp.menu|MenuManager|method|apply_menu_scales",
	"mp.menu|MenuManager|method|play_ui_sound",
	"mp.menu|InputManager|prop|using_gamepad",
	"mp.menu|InputManager|signal|input_device_changed",
	"mp.menu|Steamworks|prop|is_steam_initialized",
]

## Node paths the injector needs in res://scenes/main_menu.tscn (checked at injection).
const NODE_PATHS := [
	"Background/MenuButtons/Play",
	"Background/MenuLoad",
	"Background/MenuLoad/New",
	"Background/MenuLoad/ScrollContainer",
	"Background/MenuSandbox",
]
