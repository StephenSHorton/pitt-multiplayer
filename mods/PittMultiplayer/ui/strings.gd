extends RefCounted
## MP_* translation keys. register() adds one Translation per game locale to
## TranslationServer (English is the fallback for keys a locale lacks). It is
## idempotent and works headless. Strings live in ui/i18n/<locale>.json; the
## locale codes are the game's own (translations/translation.csv columns).
## Placeholders use {name} style: Strings.fmt(key, {"name": ...}).

const LOCALES := ["en", "fr", "es", "cn", "de", "jp", "ko", "pl", "pt", "ru"]
const _EN = preload("i18n/en.json")

static var _registered: Array = []   # Translation objects we added
static var _keys: Dictionary = {}


static func dir() -> String:
	return _EN.resource_path.get_base_dir()


static func load_locale(locale: String) -> Dictionary:
	if locale == "en" and _EN != null and typeof(_EN.data) == TYPE_DICTIONARY:
		return _EN.data
	var p := dir().path_join(locale + ".json")
	if not FileAccess.file_exists(p):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(p))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


static func register() -> void:
	unregister()
	var en := load_locale("en")
	_keys = en.duplicate()
	for loc in LOCALES:
		var data := load_locale(loc)
		var t := Translation.new()
		t.locale = loc
		for k in en:
			t.add_message(k, str(data.get(k, en[k])))
		TranslationServer.add_translation(t)
		_registered.append(t)


static func unregister() -> void:
	for t in _registered:
		TranslationServer.remove_translation(t)
	_registered.clear()


static func is_registered() -> bool:
	return not _registered.is_empty()


## Every key in en.json.
static func keys() -> Array:
	if _keys.is_empty():
		_keys = load_locale("en")
	return _keys.keys()


static func has_key(key: String) -> bool:
	if _keys.is_empty():
		_keys = load_locale("en")
	return _keys.has(key)


## tr(key) with {placeholders} filled.
static func fmt(key: String, args: Dictionary = {}) -> String:
	var s := TranslationServer.translate(key)
	return String(s).format(args) if not args.is_empty() else String(s)
