extends "res://scripts/golden_duck_statue.gd"
## MP2 4.2: blessings and petting pay on the host (money mirrored); the texts,
## sparkles and quack replay on clients.

const G = preload("../../gameplay/mp_gate.gd")


func _on_bless_body_entered(body: Node3D) -> void:
	if G.sink(self):
		return
	super(body)


func interact() -> void:
	if G.input(self, "interact"):
		return
	super()


func _spawn_bless_text(body: Node3D, amount: float) -> void:
	super(body, amount)
	G.fx("statue_bless", self, {"amount": amount, "body": G.eid(body)})


func _spawn_pet_text(amount: float) -> void:
	super(amount)
	G.fx("statue_pet", self, {"amount": amount})
