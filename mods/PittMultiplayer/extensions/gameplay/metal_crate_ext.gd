extends "res://scripts/metal_crate.gd"
## MP2 4.3 / spike S-M3: metal_crate.gd extends wodd_crate.gd through class_name GamblingCrate.
## Once wodd_crate.gd is taken over, "GamblingCrate" no longer resolves for a script
## compiled later, so this extension is listed BEFORE wodd_crate_ext.gd in mod.json: it
## compiles metal_crate.gd against the original crate script, and therefore repeats the crate
## gates of wodd_crate_ext.gd (keep the two in sync; test_mp2_gameplay_crates checks it).

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
