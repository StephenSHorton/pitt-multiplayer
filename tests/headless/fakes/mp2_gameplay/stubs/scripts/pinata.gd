extends RigidBody3D
## Headless stand-in for res://scripts/pinata.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/pinata_ext.gd compile
## and be exercised headless.


var pool_id = "pinata"
var value = 15
var count: int = 0
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _physics_process(_delta: float) -> void:
	pass

func _process(delta):
	pass

func _on_body_entered(body):
	_stub("_on_body_entered")

func _is_cushioned_contact(body: Node) -> bool:
	_stub("_is_cushioned_contact")
	return false

func _process_impact_deferred(impact_force: float, is_tool: bool, is_cushion) -> void:
	_stub("_process_impact_deferred")

func _burst(impact_force: float = 0.0, overide: bool = false) -> void:
	_stub("_burst")

func _detach_audio_players() -> Dictionary:
	_stub("_detach_audio_players")
	return {}

func _spawn_burst_effects(detached_audio: Dictionary) -> void:
	_stub("_spawn_burst_effects")

func _setup_audio_cleanup(audio_player: AudioStreamPlayer3D) -> void:
	_stub("_setup_audio_cleanup")

func _setup_particle_cleanup(particles: GPUParticles3D) -> void:
	_stub("_setup_particle_cleanup")

func _spawn_candies(impact_force: float = 0.0) -> void:
	_stub("_spawn_candies")

func _calculate_collision_volume(impact_force: float) -> float:
	_stub("_calculate_collision_volume")
	return 0.0

func set_highlight(active: bool, grabbed: bool = false) -> void:
	_stub("set_highlight")

func object_name() -> String:
	_stub("object_name")
	return ""

func on_pool_spawn():
	_stub("on_pool_spawn")

func on_pool_recycle():
	_stub("on_pool_recycle")

func _is_on_cushion() -> bool:
	_stub("_is_on_cushion")
	return false

func on_whacked(force: float) -> void:
	_stub("on_whacked")
