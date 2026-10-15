extends "res://scripts/wodd_crate.gd"
## MP2 4.3: crate damage, opening, loot and buffs on the host (loot arrives as
## entities, buffs through the mirror); the break effects replay on clients.
## metal/plush/anomaly crates extend the ORIGINAL crate script through class_name
## GamblingCrate (spike S-M3: a script compiled after this takes over the path cannot
## resolve the class), so they have their own copies of these gates
## (metal_crate_ext.gd, plush_crate_ext.gd, anomaly_crate_ext.gd, listed before this one).

const G = preload("../../gameplay/mp_gate.gd")


func _on_body_entered(_body):
	if G.sink(self):
		return
	super(_body)


func break_crate():
	if G.sink(self):
		return
	G.consumed(self, "crate_break")
	await super()


func _spawn_loot(_rarity: String, loot_data: Dictionary, force_buff: bool = false):
	if G.sink(self):
		return
	super(_rarity, loot_data, force_buff)


func _spawn_products(count: int, is_lucky: bool):
	if G.sink(self):
		return
	super(count, is_lucky)


func _spawn_tool(tool_name: String):
	if G.sink(self):
		return
	super(tool_name)


func _apply_buff():
	if G.sink(self):
		return
	super()


func on_whacked(_force: float) -> void:
	if G.sink(self):
		return
	super(_force)


func _spawn_break_effects(rarity_color: Color, rarity: String, detached_audio_players: Dictionary):
	super(rarity_color, rarity, detached_audio_players)
	G.fx("crate_break", self, {"rarity": rarity, "color": rarity_color.to_html()})


func _spawn_floating_buff_text(buff_name: String):
	super(buff_name)
	G.fx("crate_buff", self, {"buff": buff_name})
