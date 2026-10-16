extends "res://scripts/gambling_terminal.gd"
## MP2 4.2: sweeping, banking and rolling run on the host (the bank is mirrored;
## arcing bodies stream as normal entities). A remote owner loses a body the
## terminal claims.

const G = preload("../../gameplay/mp_gate.gd")

## host: the peer whose press started (or stopped) the roll (1 = the host player)
var _mp_roller := 1
## host: stands in for the HUD while the roll result is another player's (no
## show_roll_result method, so the game skips its popup)
static var _mp_no_hud: Node = null


func _on_collector_body_entered(body: Node) -> void:
	if G.sink(self):
		return
	super(body)


func _collect(groups: Array, require_unplaced: bool) -> Array:
	if G.sink(self):
		return []
	return super(groups, require_unplaced)


func _sweep(groups: Array, require_unplaced: bool) -> void:
	if G.sink(self):
		return
	super(groups, require_unplaced)


func _arc_to_intake(body: Node, delay: float = 0.0) -> bool:
	if G.sink(self):
		return false
	G.consumed(body, "terminal")
	return super(body, delay)


func _bank_and_despawn(body: Node) -> void:
	if G.sink(self):
		return
	G.consumed(body, "terminal")
	super(body)


func _despawn(body: Node) -> void:
	if G.sink(self):
		return
	super(body)


func _do_roll_or_stop() -> void:
	if G.sink(self):
		return
	_mp_roller = G.exec_peer if G.exec_peer > 0 else 1
	super()
	G.host_after(self)


## Host. The result labels, sounds and particles replay on every client (fx
## roll_result); the HUD popup is the roller's only (0.2.2).
func _resolve(mult: float) -> void:
	if G.sink(self):
		return
	var bank_before := float(G.gs("bank", 0.0))
	var stop_time := float(_remaining)
	var hud_saved = _hud
	if G.live() and _mp_roller > 1:
		if _mp_no_hud == null or not is_instance_valid(_mp_no_hud):
			_mp_no_hud = Node.new()
		_hud = _mp_no_hud
	super(mult)
	if _hud == _mp_no_hud:
		_hud = hud_saved
	G.fx("roll_result", self, {"mult": mult, "stop": stop_time, "payout": maxi(0, int(floor(bank_before * mult))),
		"peer": _mp_roller})
	G.host_after(self)


func _spawn_recycle_cube(payout: int) -> void:
	if G.sink(self):
		return
	super(payout)


func sweep_tools_all() -> void:
	if G.sink(self):
		return
	super()
