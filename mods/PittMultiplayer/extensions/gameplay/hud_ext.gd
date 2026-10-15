extends "res://scripts/hud.gd"
## MP2 4.2 / 6.9: host bonus texts (dunks, radar, golf, bowling, graffiti) are shown
## on every client. Combo texts are not forwarded: clients produce them from the
## mirrored combo signals.

const G = preload("../../gameplay/mp_gate.gd")


var _mp_combo_text := 0


func _spawn_special_bonus_text(text: String, color: Color):
	super(text, color)
	if _mp_combo_text == 0:
		G.fx("bonus_text", null, {"text": text, "color": color.to_html()})


func _on_chain_combo_triggered(chain_level: int, bonus: int):
	_mp_combo_text += 1
	super(chain_level, bonus)
	_mp_combo_text -= 1


func _on_diversity_bonus_triggered(product_types: Array, bonus: int):
	_mp_combo_text += 1
	super(product_types, bonus)
	_mp_combo_text -= 1


func _on_rhythm_bonus_triggered(consistency: float, bonus: int):
	_mp_combo_text += 1
	super(consistency, bonus)
	_mp_combo_text -= 1
