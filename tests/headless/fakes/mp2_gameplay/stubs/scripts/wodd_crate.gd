extends RigidBody3D
## Headless stand-in for res://scripts/wodd_crate.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/wodd_crate_ext.gd compile
## and be exercised headless.

var pool_id = "toy_gambling_wodden_crate"
var mesh: MeshInstance3D = null
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready():
	pass

func _physics_process(_delta: float) -> void:
	pass

func _process(delta):
	pass

func _on_body_entered(_body):
	_stub("_on_body_entered")

func calculate_collision_volume(impact_force: float) -> float:
	_stub("calculate_collision_volume")
	return 0.0

func break_crate():
	_stub("break_crate")

func _detach_audio_players() -> Dictionary:
	_stub("_detach_audio_players")
	return {}

func _spawn_floating_rarity_text(rarity: String, color: Color):
	_stub("_spawn_floating_rarity_text")

func _spawn_break_effects(rarity_color: Color, rarity: String, detached_audio_players: Dictionary):
	_stub("_spawn_break_effects")

func _setup_particle_cleanup(particles: GPUParticles3D) -> void:
	_stub("_setup_particle_cleanup")

func _spawn_loot(_rarity: String, loot_data: Dictionary, force_buff: bool = false):
	_stub("_spawn_loot")

func _spawn_products(count: int, is_lucky: bool):
	_stub("_spawn_products")

func _spawn_tool(tool_name: String):
	_stub("_spawn_tool")

func _apply_buff():
	_stub("_apply_buff")

func _spawn_floating_buff_text(buff_name: String):
	_stub("_spawn_floating_buff_text")

func _setup_audio_cleanup(audio_player: AudioStreamPlayer3D):
	_stub("_setup_audio_cleanup")

func set_highlight(active: bool, grabbed: bool = false) -> void:
	_stub("set_highlight")

func object_name() -> String:
	_stub("object_name")
	return ""

func on_pool_spawn():
	_stub("on_pool_spawn")

func on_pool_recycle():
	_stub("on_pool_recycle")

func on_whacked(_force: float) -> void:
	_stub("on_whacked")
