extends RefCounted
## One replicated body on a client (MP2-DESIGN 3.4): a record, not a node. The
## node is the game's own pooled object (or fixture body), frozen KINEMATIC and
## driven by the client replicator from a ring of host states.

const Interp = preload("interp.gd")

var eid := 0
var ref: WeakRef = null
var kind := "pooled"            # pooled | fixture_body
var pool_id := ""
var key := ""
var ring: Array = []            # host states, sorted by t (Interp.ring_push)
var last_rx_ms := 0
var last_flags := 0
var last_epoch := -1
var owner := 1
var owner_kind := ""
var meta: Dictionary = {}       # last applied {kind: {field: value}}
# driving
var idle := false               # SLEEP placed exactly; not driven until the next record
var has_out := false
var out_p := Vector3.ZERO
var prev_target := Vector3.ZERO
var prev_vel := Vector3.ZERO
var corr0 := Vector3.ZERO
var corr_start_ms := 0
var force_snap := false
var was_snap_wait := false
# local simulation (GRAB carry / equip)
var local_sim := false
var release_wait := false
var min_epoch := 0
var release_until_ms := 0
# riders (a crate carried with ducks in it): see replicator_client._carry_riders
var rider_of := 0               # eid of the carried body this one rides in / on
var riders: Dictionary = {}     # carried body: eid -> true
var box := AABB()               # carried body: its shapes (local frame) + room above
var has_box := false
# collision state
var hidden := false
var nocollide := false
var layers_saved := false
var saved_layer := 0
var saved_mask := 0
var exception := false


func node() -> Node3D:
	var n = ref.get_ref() if ref != null else null
	return n if n != null and is_instance_valid(n) else null


## last_flags follow the newest record only: an older record inserted behind it
## (reordered on the unreliable lane) must not bring back a HELD of a carry that
## already ended (GRAB's local refusal reads it through bodies.flags_of).
func push(state: Dictionary) -> bool:
	var ok := Interp.ring_push(ring, state)
	if ok:
		idle = false
		if is_same(ring[ring.size() - 1], state):
			last_flags = int(state.get("flags", 0))
	return ok


func newest() -> Dictionary:
	return ring[ring.size() - 1] if not ring.is_empty() else {}


## True when a record with an epoch at or past `want` (u16, compared on the low
## byte with wrap-around) is in the ring.
func has_epoch_at_least(want: int) -> bool:
	for s in ring:
		if epoch_reached(int(s.get("epoch", 0)), want):
			return true
	return false


static func epoch_reached(rec_epoch_low: int, want: int) -> bool:
	return ((rec_epoch_low - (want & 0xFF)) & 0xFF) < 128
