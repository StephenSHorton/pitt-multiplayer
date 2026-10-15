extends "res://scripts/vacuum.gd"
## MP2 4.5: ingesting, the bag and releases run on the host (ingested bodies are
## HIDDEN entities); equipped input goes to the host as tool_in, the local copy
## spools for feedback.

const G = preload("../../gameplay/mp_gate.gd")


func _check_ingestion() -> void:
	if G.sink(self):
		return
	super()


func _ingest(body: RigidBody3D) -> void:
	if G.sink(self):
		return
	G.consumed(body, "vacuum")
	super(body)


func _release_one() -> void:
	if G.sink(self):
		return
	super()


func _release_all() -> void:
	if G.sink(self):
		return
	super()


func _force_clear_bag() -> void:
	if G.sink(self):
		return
	super()


func equipped_lmb_pressed() -> void:
	if G.input_predict(self, "equipped_lmb_pressed"):
		return
	super()


func equipped_lmb_released() -> void:
	if G.input_predict(self, "equipped_lmb_released"):
		return
	super()


func equipped_rmb_pressed() -> void:
	if G.input_predict(self, "equipped_rmb_pressed"):
		return
	super()


func toggle_vacuum() -> void:
	if G.input(self, "toggle_vacuum"):
		return
	super()


func interact() -> void:
	if G.input(self, "interact"):
		return
	super()


func remote_toggle(on: bool) -> void:
	if G.replay(self):
		return
	super(on)
