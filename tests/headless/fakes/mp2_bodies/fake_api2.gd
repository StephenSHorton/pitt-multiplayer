extends "res://tests/fakes/mp_net/fake_api.gd"
## FakeApi + what the BODIES module needs: a real loader entity registry per
## peer (api.entities = its mod View) and the PittAPI 1.2 provider calls of
## api.net (adopt_entity, release_entity, set_reconcile_mode, track_fixture,
## is_applying).

const Entities = preload("res://gamedir/mods/PittAPI/core/entities.gd")
const FakeEntityCore = preload("fake_entity_core.gd")
const FakeApiBase = preload("res://tests/fakes/mp_net/fake_api.gd")


class FakeNet2 extends FakeApiBase.FakeNet:
	var modes: Array = []
	var adopts := 0
	var releases := 0

	func adopt_entity(node: Node, eid: int, pool_id_or_key: String) -> Error:
		adopts += 1
		return api.entities_reg.adopt(node, eid, pool_id_or_key)

	func release_entity(eid: int) -> void:
		releases += 1
		api.entities_reg.release(eid)

	func set_reconcile_mode(mode: Dictionary) -> void:
		modes.append(mode.duplicate())
		api.entities_reg.set_reconcile_mode(mode)

	func track_fixture(node: Node, key: String) -> int:
		return api.entities_reg.track(node, key, "PittMultiplayer")

	func is_applying() -> bool:
		return applying > 0


var entities_reg = null
var entities = null
var entity_core = null


func _init(p_name: String = "peer") -> void:
	super(p_name)
	net = FakeNet2.new()
	net.api = self


func attach_pools(pm: Object) -> void:
	entity_core = FakeEntityCore.new(self, pm)
	entities_reg = Entities.new(entity_core)
	entities = Entities.View.new(entities_reg, "PittMultiplayer")
