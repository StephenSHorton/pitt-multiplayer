extends "res://scripts/pinata.gd"
## MP2 4.3: impacts, bursts and candy spawns on the host; the burst effect replays
## on clients just before the despawn.

const G = preload("../../gameplay/mp_gate.gd")


func _process_impact_deferred(impact_force: float, is_tool: bool, is_cushion) -> void:
	if G.sink(self):
		return
	await super(impact_force, is_tool, is_cushion)


func _burst(impact_force: float = 0.0, overide: bool = false) -> void:
	if G.sink(self):
		return
	G.consumed(self, "burst")
	super(impact_force, overide)


func _spawn_candies(impact_force: float = 0.0) -> void:
	if G.sink(self):
		return
	super(impact_force)


func on_whacked(force: float) -> void:
	if G.sink(self):
		return
	super(force)


func _spawn_burst_effects(detached_audio: Dictionary) -> void:
	super(detached_audio)
	G.fx("pinata_burst", self)
