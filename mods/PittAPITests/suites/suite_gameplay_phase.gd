extends RefCounted
## Opt-in suite ("gameplay_phase" in the flag): phase.set runs the real phase
## transition (cinematic, music, checkpoint_save - which save isolation blocks).


func run(t, api, host: Node) -> void:
	var tree: SceneTree = host.get_tree()
	var root := tree.root
	var sm = root.get_node("SaveManager")
	var changed: Array = []
	var sid: int = api.events.on("phase.changed", func(e): changed.append(e))
	var r = api.state.set_phase(5)
	t.check("phase.refuses_ending", r.done and not r.ok and r.code == "ERR_DENIED", r.error)
	r = api.state.set_phase(2)
	t.check("phase.set_2_ok", r.ok, r.error)
	await tree.process_frame
	await tree.process_frame
	var started := false
	for e in changed:
		if int(e.payload.to) == 2:
			started = true
	t.check("phase.changed_event", started, str(changed.size()))
	var settled = await api.events.wait("phase.settled", 45.0)
	t.check("phase.settled_event", settled != null and int(settled.payload.phase) == 2,
		JSON.stringify(settled.payload) if settled != null else "timeout")
	t.check("phase.save_still_locked", bool(sm.save_locked), "")
	t.check("phase.no_test_save_written", not FileAccess.file_exists("user://pittapi/test/run.save"), "")
	api.events.off(sid)
