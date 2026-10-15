extends "res://scripts/remote.gd"
## MP2 4.5: channel toggles and links run on the host (states and links come back
## through the mirror field); channel selection is predicted locally and sent to
## the host so both copies agree on current_channel.

const G = preload("../../gameplay/mp_gate.gd")


func _toggle_channel(channel_idx: int):
	if G.sink(self):
		return
	super(channel_idx)


func _toggle_all_channels():
	if G.sink(self):
		return
	super()


func try_link_tool(tool_node: Node3D) -> bool:
	if G.sink(self):
		return false
	return super(tool_node)


func unlink_tool(tool_node: Node3D):
	if G.sink(self):
		return
	super(tool_node)


func unlink_all():
	if G.sink(self):
		return
	super()


func remote_lmb_pressed():
	if G.is_client() and not G.applying():
		if G.in_input_scope():
			var all := int(G.gs("remote_max_channels", 1)) > 1 and InputMap.has_action("remote_toggle_all") \
				and Input.is_action_pressed("remote_toggle_all")
			G.forward(self, "mp_remote_lmb", [all])
		return
	super()


## Host (tool_in): the client's button state instead of the host's Input.
func mp_remote_lmb(all: bool) -> void:
	if not G.is_host():
		return
	if all:
		_toggle_all_channels()
		return
	var ch: int = current_channel
	_toggle_channel(ch)


func cycle_channel(direction: int = 1):
	if G.input_predict(self, "cycle_channel", [direction]):
		return
	super(direction)


func try_interact_with_target(target: Node3D) -> bool:
	if G.is_client() and not G.applying():
		# only toggles link; the host does the linking
		var linkable := is_instance_valid(target) and target.is_in_group("toggle")
		if linkable and G.in_input_scope():
			G.forward(self, "try_interact_with_target", [target])
		return linkable
	return super(target)


func remote_toggle(on: bool) -> void:
	if G.replay(self):
		return
	super(on)
