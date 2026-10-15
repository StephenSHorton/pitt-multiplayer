extends Node
## ExampleMod: a small, complete PittAPI mod.
##   - shows a toast when it loads (also on the main menu)
##   - F7 (rebindable, saved in user://pittapi/keybinds.cfg) prints current money
##   - listens to phase.changed and money.changed
##   - adds a "+API" floating text after each combo payout, through a thin
##     script extension of hud.gd (extensions/hud_ext.gd)
##   - registers a cheat command and a console command
## Rules followed here: no class_name, only the `api` handle (no bare PittAPI
## global), all state changes through api.commands, JSON-safe payloads.

var api = null   # PittAPIContext, set before _ready and passed to _mod_init

var money_events := 0
var phase_events := 0
var last_money := ""
var last_phase := -1


func _mod_init(p_api) -> void:
	api = p_api
	api.config.define("show_money_toasts", false, {"description": "Toast on every money change"})
	api.config.define("money_key_toast", true, {"description": "Show a toast when the money key is pressed"})

	api.input.register_action("print_money", KEY_F7, "Print money")

	api.events.on("input.action", _on_input_action)
	api.events.on("money.changed", _on_money_changed)
	api.events.on("phase.changed", _on_phase_changed)
	api.events.on("world.ready", _on_world_ready)
	api.events.on("mod.ExampleMod.hud_result", _on_hud_result)

	api.commands.register("ExampleMod.double_money", _cmd_double_money, {
		"cheat": true, "schema": {}, "description": "Doubles your money (cheat)"})
	api.console.register("hello", func(args): return "hi " + " ".join(args), "say hi")

	api.hud.toast("ExampleMod %s loaded (PittAPI %s). Press %s to print money." % [
		api.version, api.api_version, api.input.get_key_name("print_money")])
	api.log.info("ExampleMod ready", {"key": api.input.get_key_name("print_money")})


func _mod_shutdown() -> void:
	pass


## Other mods can call api.get_mod_api("ExampleMod").
func get_public_api() -> Object:
	return self


func get_counts() -> Dictionary:
	return {"money_events": money_events, "phase_events": phase_events}


func _on_input_action(ev) -> void:
	if ev.payload.get("mod", "") != "ExampleMod" or ev.payload.get("name", "") != "print_money":
		return
	if not ev.payload.get("pressed", false):
		return
	var money: String = api.state.get_money()
	api.log.info("money = %s (phase %s)" % [money, api.state.get_phase_name()])
	print("[ExampleMod] money = %s" % money)
	if api.config.get_value("money_key_toast"):
		api.hud.toast("Money: $%s" % money)


func _on_money_changed(ev) -> void:
	money_events += 1
	last_money = ev.payload.money
	if api.config.get_value("show_money_toasts"):
		var sign_str := "+" if ev.payload.sign > 0 else "-"
		api.hud.toast("%s%s ($%s)" % [sign_str, ev.payload.delta, ev.payload.money], {"duration": 1.5})


func _on_phase_changed(ev) -> void:
	phase_events += 1
	last_phase = int(ev.payload.to)
	api.log.info("phase %s -> %s (%s)" % [ev.payload.from, ev.payload.to, ev.payload.source])
	if ev.payload.source == "transition":
		api.hud.toast("Phase %d: %s" % [last_phase, api.state.get_phase_name(last_phase)])


func _on_world_ready(ev) -> void:
	api.log.info("world ready", ev.payload)


func _on_hud_result(ev) -> void:
	# emitted by extensions/hud_ext.gd after the game paid a combo bonus
	api.hud.floating_text("+API x%s" % str(ev.payload.get("level", "?")), Color(1.0, 0.85, 0.2))


func _cmd_double_money(_args: Dictionary, ctx) -> Variant:
	var now: String = api.state.get_money()
	# commands may call other commands; the result is checked with `done`
	var r = api.commands.execute("money.add", {"amount": now})
	if r.done and not r.ok:
		return ctx.fail(r.error)
	return {"money": api.state.get_money()}
