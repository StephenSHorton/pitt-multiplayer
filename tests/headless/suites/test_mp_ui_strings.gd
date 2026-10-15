extends "res://tests/test_case.gd"
## Every MP_* key used in ui/ and lobby/ and every key NET needs (5.5) is
## registered in English; the other locales only carry known keys.

const END_REASONS := ["left", "host_left", "connection_lost", "version", "mods", "full", "kicked", "ending",
	"timeout", "protocol", "error"]
const LOBBY_REASONS := ["left", "host_left", "kicked", "join_failed", "error"]
const NET_KEYS := ["MP_PEER_JOINED", "MP_PEER_LEFT", "MP_HOST_ONLY", "MP_HOST_SAVES", "MP_NOT_IN_MULTIPLAYER",
	"MP_CONFIRM_END_SESSION", "MP_SHOP_UNAVAILABLE", "MP_MP1_PRIVATE_WORLD", "MP_SANDBOX_UNSUPPORTED"]

var Strings = null


func before_all() -> void:
	Strings = load(String(core.mods_dir).path_join("PittMultiplayer/ui/strings.gd"))
	Strings.register()


func test_register_and_translate() -> void:
	var prev := TranslationServer.get_locale()
	TranslationServer.set_locale("en")
	assert_eq(String(TranslationServer.translate("MP_MULTIPLAYER")), "Multiplayer", "en")
	Strings.register()   # idempotent
	assert_eq(String(TranslationServer.translate("MP_HOST")), "Host", "still registered once")
	TranslationServer.set_locale("fr")
	assert_eq(String(TranslationServer.translate("MP_MULTIPLAYER")), "Multijoueur", "fr")
	assert_eq(String(TranslationServer.translate("MP_ERR_START_FAILED")), "Impossible de lancer la partie", "fr dialog strings translated")
	TranslationServer.set_locale("de")
	assert_eq(String(TranslationServer.translate("MP_LEAVE")), "Verlassen", "de")
	TranslationServer.set_locale(prev)


func test_net_keys_registered() -> void:
	for k in NET_KEYS:
		assert_true(Strings.has_key(k), "NET key " + k)
	for r in END_REASONS:
		assert_true(Strings.has_key("MP_END_" + r.to_upper()), "end reason " + r)
	for r in LOBBY_REASONS:
		assert_true(Strings.has_key("MP_LOBBY_" + r.to_upper()), "lobby reason " + r)
	for s in ["waiting", "starting", "in_game", "ending"]:
		assert_true(Strings.has_key("MP_STATE_" + s.to_upper()), "state " + s)


func test_every_used_key_registered() -> void:
	var re := RegEx.new()
	re.compile("\"(MP_[A-Z0-9_]*[A-Z0-9])\"")
	var base := String(core.mods_dir).path_join("PittMultiplayer")
	var used: Dictionary = {}
	for sub in ["ui", "lobby", "extensions"]:
		var dir := base.path_join(sub)
		var da := DirAccess.open(dir)
		if da == null:
			continue
		for f in da.get_files():
			if not f.ends_with(".gd"):
				continue
			if sub == "extensions" and f != "main_menu_ext.gd":
				continue   # NET's extensions are checked by NET
			var src := FileAccess.get_file_as_string(dir.path_join(f))
			for m in re.search_all(src):
				used[m.get_string(1)] = f
	assert_true(used.size() > 20, "found keys in sources (%d)" % used.size())
	for k in used:
		assert_true(Strings.has_key(k), "%s (used in %s) is registered" % [k, used[k]])


func test_locales_only_known_keys() -> void:
	var en: Dictionary = Strings.load_locale("en")
	for loc in Strings.LOCALES:
		var d: Dictionary = Strings.load_locale(loc)
		assert_true(not d.is_empty(), "locale %s parses" % loc)
		for k in d:
			assert_true(en.has(k), "%s.%s exists in en" % [loc, k])
		for k in d:
			if String(en.get(k, "")).contains("{"):
				for ph in ["{n}", "{max}", "{name}", "{state}"]:
					if String(en[k]).contains(ph):
						assert_true(String(d[k]).contains(ph), "%s.%s keeps %s" % [loc, k, ph])


func test_fmt() -> void:
	var prev := TranslationServer.get_locale()
	TranslationServer.set_locale("en")
	assert_eq(Strings.fmt("MP_PEER_JOINED", {"name": "Ann"}), "Ann joined", "placeholder")
	assert_eq(Strings.fmt("MP_PLAYERS", {"n": 2, "max": 10}), "Players 2/10", "numbers")
	TranslationServer.set_locale(prev)


func test_every_locale_complete() -> void:
	var dir := "res://gamedir/mods/PittMultiplayer/ui/i18n"
	var en = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("en.json")))
	assert_true(typeof(en) == TYPE_DICTIONARY and en.size() > 0, "en.json readable")
	for loc in ["cn", "de", "es", "fr", "jp", "ko", "pl", "pt", "ru"]:
		var d = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join(loc + ".json")))
		assert_true(typeof(d) == TYPE_DICTIONARY, "%s.json readable" % loc)
		if typeof(d) != TYPE_DICTIONARY:
			continue
		var missing: Array = []
		for k in en:
			if not d.has(k):
				missing.append(k)
			elif String(en[k]).contains("{") and String(d[k]).count("{") != String(en[k]).count("{"):
				missing.append(k + " (placeholders)")
		assert_eq(missing, [], "%s has every MP_ string" % loc)
