extends "res://scripts/piston_3.gd"
## MP2 4.5: the weight piston (piston3.tscn). piston_3.gd overrides
## scroll_tune_up/down without super(), so piston_2_ext's gates never run for
## it: tuning the weight preset goes to the host here, and the preset replays on
## clients from meta (entity_meta "wpreset" -> set_weight_preset(i, false)).
## Listed after piston_2_ext.gd (this script's base is the extended piston_2.gd).
## Clients: every puppet is frozen, so piston_3's own front mass (which skips
## frozen bodies) would always read 0 and the pusher would wait for the meta;
## the client counts the puppets the host simulates, so its predicted phase
## follows the host's (the piston meta still corrects it).

const G = preload("../../gameplay/mp_gate.gd")
const PUPPET_META := "pitt_mp_puppet"


func scroll_tune_up() -> void:
	if G.input(self, "scroll_tune_up"):
		return
	super()


func scroll_tune_down() -> void:
	if G.input(self, "scroll_tune_down"):
		return
	super()


func cycle_weight_preset(direction: int) -> void:
	if G.replay(self):
		return
	super(direction)


func set_weight_preset(index: int, play_feedback: bool) -> void:
	if G.replay(self):
		return
	super(index, play_feedback)


func _compute_front_mass() -> float:
	if not G.is_client():
		return super()
	if not is_instance_valid(detection_area):
		return INF
	var sum := 0.0
	for rb in detection_area.get_overlapping_bodies().filter(_mp_weighs_on_front):
		sum += rb.mass
	return sum


## A product body in front of the pusher that the host would weigh: a puppet
## stands for a dynamic host body; a frozen non-puppet is frozen on the host too.
func _mp_weighs_on_front(b) -> bool:
	if not is_instance_valid(b) or not (b is RigidBody3D) or b == self or b == pusher_body:
		return false
	return b.is_in_group("product") and (b.has_meta(PUPPET_META) or not b.freeze)
