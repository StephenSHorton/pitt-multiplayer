extends "res://scripts/main_camera.gd"
## MP2 1.1 / 6.11: the camera's input dispatchers (handle_input, _do_interact,
## _input, _handle_dpad_context) set the input scope; on a client
## the panel rack goes through the host (rack_store / rack_withdraw). Grab and
## release are GRAB's extension (extensions/grab/main_camera_grab_ext.gd).

const G = preload("../../gameplay/mp_gate.gd")


func handle_input():
	G.begin_input_scope()
	super()
	G.end_input_scope()


## Mouse wheel / right click on a machine (scroll_tune_up/down/cycle) and the
## remote's channel cycle are dispatched from _input; the D-pad equivalents from
## _handle_dpad_context (physics). Both are local-player input.
func _input(event: InputEvent) -> void:
	G.begin_input_scope()
	super(event)
	G.end_input_scope()


func _handle_dpad_context(delta: float) -> void:
	G.begin_input_scope()
	super(delta)
	G.end_input_scope()


func _do_interact() -> bool:
	G.begin_input_scope()
	var r: bool = super()
	G.end_input_scope()
	return r


func _rack_panel(panel: RigidBody3D) -> bool:
	if G.is_client() and not G.applying():
		return _mp_rack_on_host(panel)
	return super(panel)


## Client: the host stores the panel (its world owns the rack); locally the
## carry ends, the pickup sound plays and the control hints refresh.
func _mp_rack_on_host(panel: RigidBody3D) -> bool:
	var stored := G.rack_store(panel)
	if stored:
		if picked_object == panel:
			_release_carry_state()
		var sfx = get("pickup_audio")
		if sfx and sfx.stream:
			sfx.play()
		var ray = interact_ray
		if ray:
			ray.refresh_controls()
	return stored


func _refill_from_panel_stack() -> void:
	if not G.is_client() or G.applying():
		super()
	elif picked_object == null and equipped_item == null:
		G.rack_withdraw()   # hands free: the host pops the rack
