extends RefCounted
## MP2 translation keys (MP2-DESIGN 10.9): MP_PHYSICS_OVERLOADED,
## MP_ERR_WORLD_TOO_BIG, MP_ERR_WORLD_SEND, MP_WORLD_LOADING, MP_HELD_BY ({name}). Same scheme as
## ui/strings.gd (one Translation per game locale, English fallback,
## idempotent, headless-safe), kept apart so the UI files stay untouched.

const LOCALES := ["en", "fr", "es", "cn", "de", "jp", "ko", "pl", "pt", "ru"]
const KEYS := ["MP_PHYSICS_OVERLOADED", "MP_ERR_WORLD_TOO_BIG", "MP_ERR_WORLD_SEND", "MP_WORLD_LOADING", "MP_HELD_BY"]
const _EN = preload("i18n/en.json")

static var _registered: Array = []


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


static func fmt(key: String, args: Dictionary = {}) -> String:
	var s := TranslationServer.translate(key)
	return String(s).format(args) if not args.is_empty() else String(s)
