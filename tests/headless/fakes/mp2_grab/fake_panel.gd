extends RigidBody3D
## Stand-in for a sticky panel (decomp panel.gd shape: PanelState enum, state,
## place / force_place / unplace). Records calls.

enum PanelState{FREE, PLACED}

var state: PanelState = PanelState.FREE
var pool_id := "tool_panel"
var calls: Array = []


func _set_placed(on: bool) -> void:
	state = PanelState.PLACED if on else PanelState.FREE
	freeze_mode = FREEZE_MODE_STATIC if on else FREEZE_MODE_KINEMATIC
	freeze = on


func place():
	calls.append("place")
	_set_placed(true)


func force_place():
	calls.append("force_place")
	_set_placed(true)


func unplace():
	calls.append("unplace")
	_set_placed(false)
