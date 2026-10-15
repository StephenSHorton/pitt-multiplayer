extends RefCounted
## Snapshot and late join (MP-DESIGN 9). One path for Start and late join.
## Host: the game's own save collectors into a FRESH dictionary (never
## SaveManager.save_data, no file, no pause), stripped per the MP1 table, JSON
## -> zstd -> sha256 -> 32 KB chunks on channel 1. Joins within 2 s share a build.
## Client: reassembles, verifies, and the Session writes it to the isolated,
## encrypted session file and loads it through the game's normal load path.

const Codec = preload("../net/codec.gd")
const Proto = preload("../net/proto.gd")

const SHARE_MS := 2000
const SPAWN_LIFT := 0.3
const FALLBACK_POS := Vector3(0, 6, 18)
const HALF_HEIGHT := 0.975          # player_controller.gd standing_height / 2: origin = capsule centre
const EYE := Vector3(0, 0.65, 0)    # CameraPivot height
## far rings first; the 1.3-1.6 m rings are for tight spots (the start elevator)
const SPAWN_RINGS := [2.2, 3.0, 4.0, 1.6, 1.3]
const MAX_STEP := 0.6               # floor at most this far from the host's floor (no ledges / pit)
const SUPPORT_DROP := 1.5

## Keys the game restores from a save; the snapshot always carries exactly these.
const KEYS := ["version", "timestamp", "game_state", "game_statistics", "unlocked_milestones", "phase", "hole",
	"workbenches", "vertical_gates", "cameras", "minable_blocks", "loop_puzzle", "object_pools",
	"press_spawned", "trading_terminal_spawned", "bowling_set_spawned", "pickaxe", "player_position", "pitt_mp"]
## game_state fields that are per player (MP2 3.8): the panel rack (D13) arrives
## in GAMEPLAY's world-snapshot section; bank and mining_bank are shared (D14).
const LOCAL_GAME_STATE := {"panel_stack": []}

var adapter = null
var _cache: Dictionary = {}     # {ms, slot, text, ...}
var _xfer := 0
var builds := 0
## Spawn probe (tests inject one; null = a WorldProbe over the host's world per build).
var spawn_probe = null


func _init(p_adapter = null) -> void:
	adapter = p_adapter


## The MP2 strip table (MP2-DESIGN 3.8) applied to the collectors' output. Pure.
## object_pools stays empty: objects come in the world snapshot with host ids.
## press / trading terminal / bowling set / pickaxe are KEPT from the host (the
## joiner's own load path builds the same fixtures); bank and mining_bank are kept.
static func strip(d: Dictionary) -> Dictionary:
	var out := d.duplicate(true)
	var gs = out.get("game_state", {})
	if typeof(gs) == TYPE_DICTIONARY:
		for k in LOCAL_GAME_STATE:
			if gs.has(k):
				gs[k] = LOCAL_GAME_STATE[k].duplicate() if typeof(LOCAL_GAME_STATE[k]) == TYPE_ARRAY else LOCAL_GAME_STATE[k]
	out["object_pools"] = {}
	out.erase("music")
	out.erase("seen_items")
	out.erase("demo_end_triggered")
	return out


## Where a joiner spawns (MP1 fix "puppet blocks the view"): never ON the host
## (the two cameras would sit inside each other's puppet). Candidates on rings
## around the host's last SAFE position (the game records it only on solid
## floor) are validated against the host's world, which is the same map the
## joiner loads: not over the maw, a clear line of sight from the host (never
## through a wall), floor below at the host's floor level, and room for a
## standing capsule. The first valid one wins (ring phase per slot so joiners
## spread out); otherwise the game's own clear-spot search
## (player_controller._find_clear_spot, the respawn logic) around the host,
## and without any world the host's spot. Always lifted SPAWN_LIFT: no
## fall-off fine on join (fail_safe.gd charges the shared wallet).
static func ring_position(center: Vector3, slot: int, probe = null, why: Array = []) -> Vector3:
	if not center.is_finite() or center == Vector3.ZERO:
		center = FALLBACK_POS
	var lift := Vector3(0.0, SPAWN_LIFT, 0.0)
	if probe == null:
		return center + lift
	var floor0: float = probe.floor_y(center)
	if is_nan(floor0):
		floor0 = center.y - HALF_HEIGHT
	for c in spawn_candidates(center, slot):
		if probe.over_maw(c):
			why.append("%s maw" % str(c))
			continue
		if not probe.sight(center + EYE, c + EYE):
			why.append("%s no_sight" % str(c))
			continue
		var fy: float = probe.floor_y(c)
		if is_nan(fy) or absf(fy - floor0) > MAX_STEP:
			why.append("%s floor %s (host floor %.2f)" % [str(c), str(fy), floor0])
			continue
		var p := Vector3(c.x, fy + HALF_HEIGHT, c.z)
		if not probe.clear(p):
			why.append("%s blocked" % str(c))
			continue
		why.append("%s ok" % str(c))
		return p + lift
	why.append("fallback")
	var fb: Vector3 = probe.fallback(center)
	if not fb.is_finite():
		fb = center
	return fb + lift


## Ring candidates around `center` (same height), nearest ring first. Pure.
static func spawn_candidates(center: Vector3, slot: int) -> Array:
	var out: Array = []
	var phase := float(maxi(slot, 0)) * TAU / 8.0 * 3.0
	for r in SPAWN_RINGS:
		for i in 8:
			var a := phase + TAU * float(i) / 8.0
			out.append(center + Vector3(cos(a), 0.0, sin(a)) * float(r))
	return out


## The probe over the host's real physics world (ring_position's `probe`).
class WorldProbe extends RefCounted:
	var player: Node3D = null
	var space: PhysicsDirectSpaceState3D = null
	var mask := 15
	var exclude: Array[RID] = []

	func _init(p: Node3D) -> void:
		player = p
		space = p.get_world_3d().direct_space_state
		var m = p.get("respawn_clear_mask")
		if m != null:
			mask = int(m)
		if p is CollisionObject3D:
			exclude.append((p as CollisionObject3D).get_rid())

	## Floor height below a body origin at p (searched from 0.3 m above the
	## origin down to SUPPORT_DROP under the feet), NAN when none.
	func floor_y(p: Vector3) -> float:
		var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.3,
			p + Vector3.DOWN * (HALF_HEIGHT + SUPPORT_DROP), mask, exclude)
		q.hit_from_inside = false
		var hit := space.intersect_ray(q)
		return float(hit.position.y) if not hit.is_empty() else NAN

	func sight(a: Vector3, b: Vector3) -> bool:
		var q := PhysicsRayQueryParameters3D.create(a, b, mask, exclude)
		return space.intersect_ray(q).is_empty()

	## A standing capsule at body origin p (a little lifted) touches nothing.
	func clear(p: Vector3) -> bool:
		var shape := CapsuleShape3D.new()
		shape.radius = 0.32
		shape.height = HALF_HEIGHT * 2.0 - 0.04
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = shape
		q.collision_mask = mask
		q.collide_with_areas = false
		q.exclude = exclude
		q.transform = Transform3D(Basis(), p + Vector3.UP * 0.05)
		return space.intersect_shape(q, 1).is_empty()

	func over_maw(p: Vector3) -> bool:
		return player.has_method("_over_maw") and bool(player.call("_over_maw", p))

	func fallback(center: Vector3) -> Vector3:
		if player.has_method("_find_clear_spot"):
			return player.call("_find_clear_spot", center)
		return center


## The world probe for the host's own player, null outside a 3D world.
func _make_probe():
	if adapter == null or not adapter.has_method("_group"):
		return null
	var p = adapter._group("player")
	if not (p is Node3D) or not p.is_inside_tree() or p.get_world_3d() == null:
		return null
	return WorldProbe.new(p)


## -> {xfer, text, zbytes, raw_size, sha256, chunks:[PackedByteArray], phase}
func build(slot: int, sid: String, econ_q: int) -> Dictionary:
	var now := Time.get_ticks_msec()
	var base: Dictionary
	if not _cache.is_empty() and now - int(_cache.ms) < SHARE_MS:
		base = _cache.base
	else:
		base = strip(adapter.build_snapshot())
		_cache = {"ms": now, "base": base}
		builds += 1
	var d := base.duplicate(true)
	var probe = spawn_probe if spawn_probe != null else _make_probe()
	var pos := ring_position(adapter.host_player_position(), slot, probe)
	d["player_position"] = {"x": pos.x, "y": pos.y, "z": pos.z}
	_xfer += 1
	d["pitt_mp"] = {"proto": Proto.PROTO, "sid": sid, "econ_q": econ_q, "xfer": _xfer, "slot": slot}
	var text := JSON.stringify(d)
	var raw := text.to_utf8_buffer()
	var z := Codec.zstd(raw)
	return {"xfer": _xfer, "text": text, "zbytes": z, "raw_size": raw.size(), "sha256": Codec.sha256_hex(raw),
		"chunks": Codec.split(z, Proto.CHUNK_SIZE), "phase": int(d.get("phase", 1))}


func invalidate() -> void:
	_cache = {}


# ================================================================== client reassembly

class Receive extends RefCounted:
	var xfer := 0
	var chunks_total := 0
	var raw_size := 0
	var zsize := 0
	var sha := ""
	var parts: Dictionary = {}
	var ended := false
	var started_ms := 0

	func complete() -> bool:
		return ended and parts.size() == chunks_total

	## -> {ok, text, data, error}
	func assemble() -> Dictionary:
		var z := PackedByteArray()
		for i in chunks_total:
			if not parts.has(i):
				return {"ok": false, "error": "missing chunk %d" % i}
			z.append_array(parts[i])
		if zsize > 0 and z.size() != zsize:
			return {"ok": false, "error": "size mismatch"}
		var raw := Codec.unzstd(z, raw_size)
		if raw.size() != raw_size:
			return {"ok": false, "error": "decompress failed"}
		if Codec.sha256_hex(raw) != sha:
			return {"ok": false, "error": "sha256 mismatch"}
		var text := raw.get_string_from_utf8()
		var data = JSON.parse_string(text)
		if typeof(data) != TYPE_DICTIONARY:
			return {"ok": false, "error": "not a JSON object"}
		return {"ok": true, "text": text, "data": data, "error": ""}


static func begin_receive(msg: Dictionary) -> Receive:
	var r := Receive.new()
	r.xfer = int(msg.get("xfer", 0))
	r.chunks_total = int(msg.get("chunks", 0))
	r.raw_size = int(msg.get("raw", 0))
	r.zsize = int(msg.get("bytes", 0))
	r.sha = String(msg.get("sha256", ""))
	r.started_ms = Time.get_ticks_msec()
	if r.chunks_total <= 0 or r.chunks_total > 4096 or r.raw_size <= 0 or r.raw_size > Proto.MAX_SNAPSHOT_RAW:
		return null
	return r


## Every key the game restores is present and phase is 1..4 (joins are served only in OPEN).
static func validate(data: Dictionary) -> String:
	for k in KEYS:
		if not data.has(k):
			return "missing key %s" % k
	var p := int(data.get("phase", 0))
	if p < 1 or p > 4:
		return "phase %d is not joinable" % p
	if typeof(data.get("game_state")) != TYPE_DICTIONARY:
		return "game_state is not a Dictionary"
	return ""


## The isolated session file (never slot-like, under the PittAPI user root).
static func session_path(data_dir: String, sid: String) -> String:
	var safe := ""
	for c in sid:
		if (c >= "0" and c <= "9") or (c >= "a" and c <= "f"):
			safe += c
	if safe == "":
		safe = "session"
	return data_dir.path_join("session").path_join("mp_%s.save" % safe)
