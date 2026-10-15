extends RefCounted
## PittSpawn: always through ObjectPoolManager (nothing is ever instantiate()d).

const Serial = preload("../core/serial.gd")

var _core: Object = null
var _mod := ""


func _init(core: Object, mod_id: String) -> void:
	_core = core
	_mod = mod_id


func _pm() -> Object:
	return _core.g("ObjectPoolManager") if _core.feature_ok("spawn") else null


## Pool ids ([] before Play).
func pools() -> Array[String]:
	var out: Array[String] = []
	var pm = _pm()
	if pm == null:
		return out
	for k in pm._pools.keys():
		out.append(String(k))
	out.sort()
	return out


func is_ready() -> bool:
	var pm = _pm()
	return pm != null and bool(pm._initialized)


func headroom(pool_id: String) -> int:
	var pm = _pm()
	if pm == null or not pm._pools.has(pool_id):
		return 0
	return int(pm.pool_headroom(pool_id))


## value: {entity_id, pool_id}. opts: {velocity: Vector3, meta: Dictionary}
func spawn(pool_id: String, position: Vector3, rotation: Vector3 = Vector3.ZERO, opts: Dictionary = {}) -> RefCounted:
	var args := {"pool_id": pool_id, "position": Serial.to_json_safe(position)}
	if rotation != Vector3.ZERO:
		args["rotation"] = Serial.to_json_safe(rotation)
	if opts.has("velocity"):
		args["velocity"] = Serial.to_json_safe(opts.velocity)
	if opts.has("meta"):
		args["meta"] = opts.meta
	return _core.commands.execute("entity.spawn", args, _mod)


func despawn(entity_id: int) -> RefCounted:
	return _core.commands.execute("entity.despawn", {"entity_id": entity_id}, _mod)
