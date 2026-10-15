extends RefCounted
## Builds the UI stack the way NET's main.gd composes it, with doubles:
## FakeLobbyService (lobby_factory "fake"), FakeSession, a fake api (events,
## hud toasts, contract_check) and a stub MainMenu with the real node paths,
## extended by main_menu_ext.gd. Scripts are loaded from the copied mod folder.

const FakeSession = preload("fake_session.gd")
const MenuStub = preload("menu_stub.gd")
const MENU_SCRIPT := "res://scripts/main_menu.gd"
const VERSION := {"pitt_version": "1.0.8", "pittapi_version": "1.1.0", "mp_proto": 1, "mods_hash": "abcd"}

var core: Node = null
var runner: Node = null
var tree: SceneTree = null
var mod_dir := ""
var api = null
var lobby: Node = null
var session: Node = null
var ui: Node = null
var menu: CanvasLayer = null
var root: Node = null


func _init(p_core: Node, p_runner: Node, p_tree: SceneTree) -> void:
	core = p_core
	runner = p_runner
	tree = p_tree
	mod_dir = String(core.mods_dir).path_join("PittMultiplayer")


func script(rel: String) -> Script:
	return load(mod_dir.path_join(rel))


## The main-menu script with our extension on top (applied by PittAPI when the
## mod's manifest lists it, else loaded directly from the mod folder).
func menu_script() -> Script:
	if core.extensions != null and core.extensions.is_extended(MENU_SCRIPT):
		return load(MENU_SCRIPT)
	return script("extensions/main_menu_ext.gd")


func open(lobby_kind: String = "fake", setup_lobby: Callable = Callable()) -> void:
	script("ui/strings.gd").register()
	TranslationServer.set_locale("en")
	root = Node.new()
	root.name = "MPUITest%d" % Time.get_ticks_usec()
	runner.add_child(root)
	api = FakeApi.new()
	lobby = script("lobby/lobby_factory.gd").make(lobby_kind)
	if setup_lobby.is_valid():
		setup_lobby.call(lobby)
	root.add_child(lobby)
	lobby.setup(api, VERSION, {"scan_interval_s": 10.0})
	session = FakeSession.new()
	session.name = "Session"
	root.add_child(session)
	session.attach(lobby)
	ui = script("ui/mp_ui.gd").new()
	root.add_child(ui)
	ui.setup(api, lobby, session)
	new_menu()
	await tree.process_frame


## A fresh MainMenu instance (as after returning from gameplay), injected.
func new_menu() -> CanvasLayer:
	if menu != null and is_instance_valid(menu):
		menu.queue_free()
		menu = null
	menu = MenuStub.build(menu_script())
	root.add_child(menu)
	ui.inject(menu)
	return menu


func close() -> void:
	if root != null and is_instance_valid(root):
		root.queue_free()
	root = null


func panel(name: String) -> Control:
	return menu.get_node_or_null("Background/" + name)


func button(path: String) -> Button:
	return menu.get_node_or_null("Background/" + path) as Button


## Presses a button like a click (ignore_input cleared first, as after 0.15 s).
func press(b: BaseButton) -> void:
	menu.ignore_input = false
	b.pressed.emit()


func esc() -> void:
	menu.ignore_input = false
	var ev := InputEventAction.new()
	ev.action = "ui_cancel"
	ev.pressed = true
	runner.get_viewport().push_input(ev)
	var up := InputEventAction.new()
	up.action = "ui_cancel"
	up.pressed = false
	runner.get_viewport().push_input(up)


func top() -> String:
	return ui.router.top() if ui.router != null else ""


class FakeApi extends RefCounted:
	var toasts: Array = []
	var contract_result := {"ok": true, "missing": [], "features_off": []}
	var events = FakeEvents.new()
	var hud = null

	func _init() -> void:
		hud = FakeHud.new(self)

	func contract_check(_entries: Array) -> Dictionary:
		return contract_result


class FakeHud extends RefCounted:
	var toasts: Array = []   # shared with FakeApi.toasts (no reference cycle)

	func _init(a) -> void:
		toasts = a.toasts

	func toast(text: String, _opts: Dictionary = {}) -> Control:
		toasts.append(text)
		return null


class FakeEvents extends RefCounted:
	var subs: Dictionary = {}
	var _next := 1

	func on(name: String, handler: Callable, _priority: int = 0, _owner: String = "") -> int:
		var id := _next
		_next += 1
		subs[id] = [name, handler]
		return id

	func off(id: int) -> void:
		subs.erase(id)

	func fire(name: String, payload: Dictionary) -> void:
		var ev := FakeEvent.new()
		ev.name = name
		ev.payload = payload
		for id in subs.keys():
			if subs.has(id) and subs[id][0] == name:
				subs[id][1].call(ev)


class FakeEvent extends RefCounted:
	var name := ""
	var payload: Dictionary = {}
