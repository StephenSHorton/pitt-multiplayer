extends RefCounted
## Generic per-entity meta (MP2-DESIGN 3.5): exactly the field vocabulary of the
## game's own save schema (SaveManager._save_object_pools, save_manager.gd:657-795),
## read field by field from the live node, plus is_flattened, grade, bag_count,
## queue_count, preset and wpreset (piston_3's weight preset). The client apply mirrors _load_object_pools
## (save_manager.gd:1034-1240) per field with the same game setters, inside
## apply scope. Never on clients: apply_loaded_bag / apply_loaded_queue (they
## spawn) and GameState.remote_link_tool (links come from GAMEPLAY's mirror).
## JSON-safe values only (Color -> [r, g, b, a]).

const KIND := "g"
const STARTER_CRATE_META := "starter_crate"   # ObjectPoolManager.STARTER_CRATE_META


## host: node -> {field: value}
static func read(node: Object) -> Dictionary:
	var d := {}
	if node == null or not is_instance_valid(node):
		return d
	if "state" in node and "PanelState" in node:
		d["panel_state"] = int(node.state)
	elif "placed" in node:
		d["is_placed"] = bool(node.placed)
	if "is_active" in node:
		d["is_active"] = bool(node.is_active)
	if node.has_meta("tint_color"):
		var c = node.get_meta("tint_color")
		if c is Color:
			d["tint_color"] = [snappedf(c.r, 0.0001), snappedf(c.g, 0.0001), snappedf(c.b, 0.0001), snappedf(c.a, 0.0001)]
	if node.get_meta("gambled", false):
		d["gambled"] = true
	if node.has_meta("crude_source"):
		d["crude_source"] = int(node.get_meta("crude_source"))
	if node.get_meta(STARTER_CRATE_META, false):
		d["starter_crate"] = true
	if "value" in node and "base_value" in node:
		d["value"] = int(node.value)
	if "current_variant" in node:
		d["current_variant"] = _json(node.current_variant)
	if "scheduler_mode" in node:
		d["scheduler_mode"] = int(node.scheduler_mode)
		d["scheduler_interval"] = snappedf(float(node.scheduler_interval), 0.001)
		d["scheduler_duration"] = snappedf(float(node.scheduler_duration), 0.001)
	if "stat_index" in node:
		d["stat_index"] = int(node.stat_index)
	if "camera_id" in node:
		d["camera_id"] = str(node.camera_id)
	if "watched_camera_id" in node:
		d["watched_camera_id"] = str(node.watched_camera_id)
	if "current_channel" in node:
		d["current_channel"] = int(node.current_channel)
	if node.has_method("_is_repell"):
		d["is_repelling"] = bool(node._is_repell())
	if node.has_method("get_piston_save_data"):
		d["piston"] = _json(node.get_piston_save_data())
	if node.has_method("set_preset") and "_current_preset_index" in node:
		d["preset"] = int(node._current_preset_index)
	if node.has_method("set_weight_preset") and "_current_weight_preset_index" in node:
		d["wpreset"] = int(node._current_weight_preset_index)
	if node.has_method("get_bag_save_data") and "_bag_items" in node:
		d["bag_count"] = int(node._bag_items.size())
	if node.has_method("get_queue_save_data") and "_queue" in node:
		d["queue_count"] = int(node._queue.size())
	if "is_flattened" in node:
		d["is_flattened"] = bool(node.is_flattened)
	if "grade" in node and node.has_method("set_grade"):
		d["grade"] = int(node.grade)
	return d


## client (apply scope): the changed fields `d` onto `node`, in the load path's order.
static func apply(node: Object, d: Dictionary, pool_id: String = "") -> void:
	if node == null or not is_instance_valid(node) or d.is_empty():
		return
	if d.has("panel_state") and "state" in node:
		node.state = int(d.panel_state)
		if int(d.panel_state) == 1 and node.has_method("_rebuild_merge_group") and not node.is_in_group("slick_placed"):
			node.add_to_group("slick_placed")
			node.call_deferred("_rebuild_merge_group")
	elif d.has("is_placed") and "placed" in node:
		node.placed = bool(d.is_placed)
	if d.has("is_active") and "is_active" in node and pool_id != "tool_remote":
		var want := bool(d.is_active)
		if node.has_method("remote_toggle"):
			if bool(node.is_active) != want:
				node.remote_toggle(want)
		else:
			node.is_active = want
			if node.has_method("update_fan_state"):
				node.update_fan_state()
	if d.has("tint_color") and typeof(d.tint_color) == TYPE_ARRAY and d.tint_color.size() == 4 and node.has_method("_apply_tint"):
		var c: Array = d.tint_color
		node.set_meta("tint_color", Color(float(c[0]), float(c[1]), float(c[2]), float(c[3])))
		node._apply_tint()
	if bool(d.get("gambled", false)):
		node.set_meta("gambled", true)
	if d.has("crude_source") and node.has_method("set_crude_source"):
		node.set_crude_source(int(d.crude_source))
	if d.has("grade") and node.has_method("set_grade"):
		node.set_grade(int(d.grade))
	if bool(d.get("starter_crate", false)):
		node.set_meta(STARTER_CRATE_META, true)
	if d.has("current_variant") and node.has_method("_apply_variant"):
		node._apply_variant(d.current_variant)
	if d.has("is_placed") and node.has_method("apply_placed_state"):
		node.apply_placed_state(bool(d.is_placed))
	if d.has("piston") and typeof(d.piston) == TYPE_DICTIONARY and node.has_method("apply_piston_save_data"):
		node.apply_piston_save_data(d.piston)
	if d.has("preset") and node.has_method("set_preset"):
		node.set_preset(int(d.preset), false)
	if d.has("wpreset") and node.has_method("set_weight_preset"):
		node.set_weight_preset(int(d.wpreset), false)
	if d.has("value") and "value" in node and "base_value" in node:
		node.value = clampi(int(d.value), 1, maxi(1, int(node.base_value)))
		if node.has_method("_update_value_label"):
			node._update_value_label()
	if d.has("stat_index") and "stat_index" in node:
		node.stat_index = int(d.stat_index)
		if node.has_method("_refresh"):
			node._refresh()
	if d.has("scheduler_mode") and "scheduler_mode" in node:
		node.scheduler_mode = int(d.scheduler_mode)
		node.scheduler_interval = float(d.get("scheduler_interval", 4.0))
		node.scheduler_duration = float(d.get("scheduler_duration", 1.0))
		if node.has_method("_update_screen"):
			node._update_screen()
		if node.has_method("_refresh"):
			node._refresh()
	if d.has("camera_id") and "camera_id" in node:
		node.camera_id = str(d.camera_id)
	if d.has("watched_camera_id") and "watched_camera_id" in node:
		node.watched_camera_id = str(d.watched_camera_id)
	if d.has("current_channel") and "current_channel" in node:
		node.current_channel = maxi(0, int(d.current_channel))
		if node.has_method("_update_screen"):
			node._update_screen()
	if d.has("is_repelling") and node.has_method("flip_mode"):
		node.flip_mode(bool(d.is_repelling))
	if d.has("is_flattened") and "is_flattened" in node:
		var flat := bool(d.is_flattened)
		if flat and not bool(node.is_flattened) and node.has_method("flatten_mesh_world_y"):
			node.flatten_mesh_world_y()
		elif not flat and bool(node.is_flattened) and node.has_method("restore_mesh"):
			node.restore_mesh()


## Changed fields of b against a (a field missing from b is not a change).
static func diff(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := {}
	for k in b:
		if not a.has(k) or typeof(a[k]) != typeof(b[k]) or a[k] != b[k]:
			out[k] = b[k]
	return out


static func _json(v: Variant) -> Variant:
	match typeof(v):
		TYPE_INT, TYPE_BOOL, TYPE_STRING, TYPE_NIL:
			return v
		TYPE_FLOAT:
			return snappedf(v, 0.0001)
		TYPE_STRING_NAME:
			return String(v)
		TYPE_VECTOR3:
			return [snappedf(v.x, 0.0001), snappedf(v.y, 0.0001), snappedf(v.z, 0.0001)]
		TYPE_ARRAY:
			var a: Array = []
			for x in v:
				a.append(_json(x))
			return a
		TYPE_DICTIONARY:
			var d := {}
			for k in v:
				d[String(k)] = _json(v[k])
			return d
	return str(v)
