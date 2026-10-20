extends RefCounted
## GRAB stream game contract (MP2-DESIGN 10.7), feature mp2.grab. Same format
## as loader/core/contract.gd ("feature|target|kind|member"); checked at boot
## with api.contract_check and by tools/contract_check.py against decomp/.
## Any missing member disables multiplayer as a whole (MP1 11).
##
## Metas are strings and cannot be checked here; GRAB reads or writes:
##   player_throw_time, player_throw_position   (main_camera.gd:602, bottom_maw.gd:222)
##   consumed, pending_maw_recycle               (bottom_maw / hole: being eaten)
##   in_cannon_barrel                             (cannon.gd _load_body)
##   in_vacuum_bag                                (vacuum.gd _ingest)
## and the group terminal_pull (gambling terminal arc).

const ENTRIES := [
	"mp2.grab|res://scripts/main_camera.gd|prop|picked_object",
	"mp2.grab|res://scripts/main_camera.gd|prop|equipped_item",
	"mp2.grab|res://scripts/main_camera.gd|prop|max_grab_distance",
	"mp2.grab|res://scripts/main_camera.gd|prop|interact_ray",
	"mp2.grab|res://scripts/main_camera.gd|prop|_rack_basis",
	"mp2.grab|res://scripts/main_camera.gd|method|_begin_carry",
	"mp2.grab|res://scripts/main_camera.gd|method|drop_object",
	"mp2.grab|res://scripts/main_camera.gd|method|release_held_object",
	"mp2.grab|res://scripts/main_camera.gd|method|handle_input",
	"mp2.grab|res://scripts/interact_ray.gd|method|refresh_controls",
	"mp2.grab|res://scripts/panel.gd|prop|state",
	"mp2.grab|res://scripts/panel.gd|method|force_place",
	"mp2.grab|res://scripts/panel.gd|method|place",
	"mp2.grab|res://scripts/panel.gd|method|unplace",
	"mp2.grab|res://scripts/fan.gd|prop|placed",
	"mp2.grab|res://scripts/fan.gd|method|place",
	"mp2.grab|res://scripts/fan.gd|method|unplace",
	"mp2.grab|res://scripts/fan.gd|method|equip",
	"mp2.grab|res://scripts/fan.gd|method|unequip",
]
