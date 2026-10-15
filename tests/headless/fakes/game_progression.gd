extends Node
## Headless fake of GameProgression.

signal phase_changed(new_phase: int)

enum Phase { PHASE_0 = 0, PHASE_1 = 1, PHASE_2 = 2, PHASE_3 = 3, PHASE_4 = 4, PHASE_5 = 5 }

var current_phase: Phase = Phase.PHASE_0
var ending_active := false
var change_calls: Array = []


## records every call; emits only on an actual change
func change_phase(phase: Phase) -> void:
	change_calls.append(phase)
	if current_phase == phase:
		return
	current_phase = phase
	phase_changed.emit(phase)


func reset_run_state() -> void:
	ending_active = false
