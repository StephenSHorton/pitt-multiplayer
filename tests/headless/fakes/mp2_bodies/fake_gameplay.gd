extends RefCounted
## BODIES' double of the GAMEPLAY module (MP2-DESIGN 10.8): registers a meta
## adapter (kind "tst": nodes with meta tst_val) and a mirror field
## ("tst_field") the way GAMEPLAY does, so the registry paths run end to end.

var session = null
var role := ""
var field_value = 0
var applied_field: Array = []
var applied_meta: Array = []
var scope_ok := true


func mod_name() -> String:
	return "gameplay"


func msg_kinds() -> Dictionary:
	return {"ch3_c2h": [], "ch3_h2c": [], "ch0_c2h": [], "ch0_h2c": [], "raw_c2h": []}


func on_session_start(p_session: Object, p_role: String) -> void:
	session = p_session
	role = p_role
	var b = session.get_module("bodies")
	if b != null:
		b.register_meta("tst", func(n): return n.has_meta("tst_val"), func(n): return {"v": n.get_meta("tst_val")},
			_apply_meta, 10.0)
	session.econ_host.register_field("tst_field", func(): return field_value, _apply_field)


func _apply_meta(node: Node, d: Dictionary) -> void:
	if not session.api.net.is_applying():
		scope_ok = false
	applied_meta.append([node, d.duplicate()])
	if d.has("v"):
		node.set_meta("tst_val", d.v)


func _apply_field(v) -> void:
	if not session.api.net.is_applying():
		scope_ok = false
	applied_field.append(v)
	field_value = v


func teardown() -> void:
	if session != null:
		session.econ_host.unregister_field("tst_field")
	session = null
