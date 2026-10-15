extends RefCounted
## GAMEPLAY meta adapters for machines and tools (MP2-DESIGN 4.5), on top of the
## generic save-schema meta BODIES already sends (is_active, piston, scheduler,
## channels, queue/bag counts, value, grade, ...):
##   gp_qa_arm    {s: _state, y: _yaw} at 15 Hz -> turret yaw + bat pose (the client's
##                state machine is gated off)
##   gp_ore       {mb: mining_bank, t: pickaxe_tier} -> _update_labels (the mirror
##                writes the GameState values; this refreshes the processor's labels)
##   gp_pickaxe   {t: pickaxe_tier} -> _apply_tier_visual

const FixtureAdapters = preload("fixture_adapters.gd")

var gp = null


func _init(p_gp) -> void:
	gp = p_gp


func register_all() -> void:
	var fa = gp.fixtures
	fa.reg("gp_qa_arm", ["qa_arm"], read_qa_arm, apply_qa_arm, 15.0)
	fa.reg("gp_ore", ["ore_processor"], read_ore, apply_ore, 2.0)
	fa.reg("gp_pickaxe", ["pickaxe"], read_pickaxe, apply_pickaxe, 1.0)


func read_qa_arm(n: Object) -> Dictionary:
	return {"s": int(n.get("_state")), "y": snappedf(float(n.get("_yaw")), 0.001)}


static func apply_qa_arm(n: Object, cur: Dictionary, _prev: Dictionary) -> void:
	n.set("_state", int(cur.get("s", 0)))
	var y := float(cur.get("y", 0.0))
	n.set("_yaw", y)
	var tp = n.get("turret_pivot")
	if tp is Node3D:
		(tp as Node3D).rotation.y = y
	if n.has_method("_drive_bat"):
		n._drive_bat()


func read_ore(_n: Object) -> Dictionary:
	var a = gp.adapter
	return {"mb": int(a.gs_get("mining_bank", 0)), "t": int(a.gs_get("pickaxe_tier", 1))}


## The values travel on ch3 next to the meta, so the labels never show a stale
## bank while the ch0 econ mirror is still in flight (same values either way).
func apply_ore(n: Object, cur: Dictionary, _prev: Dictionary) -> void:
	gp.adapter.gs_set("mining_bank", int(cur.get("mb", 0)))
	gp.adapter.gs_set("pickaxe_tier", int(cur.get("t", 1)))
	if n.has_method("_update_labels"):
		n._update_labels()


func read_pickaxe(_n: Object) -> Dictionary:
	return {"t": int(gp.adapter.gs_get("pickaxe_tier", 1))}


static func apply_pickaxe(n: Object, cur: Dictionary, prev: Dictionary) -> void:
	if cur.get("t") != prev.get("t") and n.has_method("_apply_tier_visual"):
		n._apply_tier_visual()
