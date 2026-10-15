extends "res://tests/fakes/mp_net/fake_game_adapter.gd"
## NET's FakeGameAdapter with a GameState that also has the MP2 mirrored
## members (bank + bank_updated, mining_bank, the scalar statistics), so the
## production MP2 econ mirror code of game_adapter.gd runs in the tests.


class FGameState2 extends FGameState:
	signal bank_updated(new_amount)
	var bank := 0.0
	var mining_bank := 0
	var total_products := 0.0
	var max_combo := 0
	var total_combos := 0
	var combo_bonus_total = BigInt.from_int(0)
	var safety_violations := 0
	var long_range_feeds := 0
	var panel_ricochet_feeds := 0
	var cameras_destroyed := 0
	var total_wodden_gambling_crates := 0
	var max_simultaneous_toggle_tools := 0
	var peak_production_rate := 0.0


var stat_events: Array = []
var bank_events: Array = []


func _init(p_name: String = "peer", tree: SceneTree = null) -> void:
	super(p_name, tree)
	var old = nodes.GameState
	var gs := FGameState2.new()
	gs.ws = nodes.WorkbenchSpawning
	nodes.UnlockManager.gs = gs
	nodes.SaveManager.gs = gs
	nodes.Steamworks.gs = gs
	gs.stat_changed.connect(nodes.UnlockManager._on_stat_changed)
	gs.stat_changed.connect(nodes.Steamworks.on_stat)
	gs.stat_changed.connect(func(n, v): stat_events.append([n, v]))
	gs.bank_updated.connect(func(v): bank_events.append(v))
	nodes.GameState = gs
	old.free()
