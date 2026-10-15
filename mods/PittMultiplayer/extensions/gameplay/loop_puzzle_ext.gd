extends "res://scripts/loop_puzzle.gd"
## MP2 4.6 / D17: the puzzle state (energy, clones, best, solved) lives on the host.
## A run is timed on the runner's own machine; its end goes to the host as interact
## mp_remote_run {time, path}, which credits the run energy and checks the best.

const G = preload("../../gameplay/mp_gate.gd")


const _MP_MIN_BEST_RATIO := 0.5
## a C->H world message is capped at 4 KB (MP2 2.5): the run path is downsampled
const _MP_MAX_PATH := 120


func on_button(action: String) -> void:
	if G.sink(self):
		return
	super(action)
	G.host_after(self)


func _set_new_best(t: float, path: PackedVector3Array) -> void:
	if G.sink(self):
		return
	super(t, path)
	G.host_after(self)


func _check_win() -> void:
	if G.sink(self):
		return
	super()


func _solve() -> void:
	if G.sink(self):
		return
	super()
	G.ach("LOOP")
	G.host_after(self)


func _reset_object(body: Node3D) -> void:
	if G.sink(self):
		return
	super(body)


func _on_end_entered(body: Node3D) -> void:
	if G.is_client() and not G.applying():
		if G.is_local_player(body) and _recording:
			_recording = false
			if _current_path.size() >= 2:
				G.forward(self, "mp_remote_run", [_run_clock, _mp_downsample(_current_path)])
			_refresh_labels()
		return
	super(body)


## Every n-th sample, always keeping the end point (the clones follow the path).
static func _mp_downsample(path: PackedVector3Array) -> PackedVector3Array:
	if path.size() <= _MP_MAX_PATH:
		return path
	var out := PackedVector3Array()
	var step := float(path.size() - 1) / float(_MP_MAX_PATH - 1)
	for i in _MP_MAX_PATH:
		out.append(path[mini(roundi(i * step), path.size() - 1)])
	return out


## Host (interact from the runner).
func mp_remote_run(t: float, path: PackedVector3Array) -> void:
	if not G.is_host():
		return
	energy = energy + player_run_energy   # every finished run feeds the puzzle
	var plausible := best_time == INF or t >= best_time * _MP_MIN_BEST_RATIO
	if plausible and t > 0.0 and t < best_time and path.size() >= 2:
		_set_new_best(t, path)
	_refresh_labels()
	G.host_after(self)
