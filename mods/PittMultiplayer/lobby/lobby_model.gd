extends RefCounted
## Lobby models and constants (MP-DESIGN 5.1 / 5.2). Every model is a plain,
## JSON-safe Dictionary; ids are Strings so 64-bit Steam ids survive JSON.
## Readers ignore unknown keys and writers may add keys. NET may read this file.
##
##   LobbyInfo  = {id, owner_id, host_name, members, max, state, pitt_version,
##                 pittapi_version, mp_proto, mods_hash, joinable, compatible,
##                 reason, is_owner}
##   MemberInfo = {id, name, is_owner, is_self}
##   VersionInfo = {pitt_version, pittapi_version, mp_proto, mods_hash}
##   TransportTarget = {kind:"steam", role, lobby_id, host_steam_id}
##                   | {kind:"enet", role, address, port}

const MAX_MEMBERS := 10
const APP_ID := 4026250
const MP_PROTO := 2
const LOBBY_STATES := ["waiting", "starting", "in_game", "ending"]

## Lobby data keys written by the host (Steam lobby metadata, all strings).
const DATA_KEYS := ["host_name", "host_steam_id", "pitt_version", "pittapi_version", "mp_proto", "mods_hash",
	"members", "max", "state"]

const ERR_VERSION := "MP_ERR_VERSION"
const ERR_MODS := "MP_ERR_MODS"
const ERR_FULL := "MP_ERR_FULL"
const ERR_ENDING := "MP_ERR_ENDING"


static func lobby_info(fields: Dictionary = {}) -> Dictionary:
	var d := {"id": "", "owner_id": "", "host_name": "", "members": 0, "max": MAX_MEMBERS, "state": "waiting",
		"pitt_version": "", "pittapi_version": "", "mp_proto": 0, "mods_hash": "",
		"joinable": true, "compatible": true, "reason": "", "is_owner": false}
	for k in fields:
		d[k] = fields[k]
	d.id = str(d.id)
	d.owner_id = str(d.owner_id)
	d.members = int(d.members)
	d.max = int(d.max)
	d.mp_proto = int(d.mp_proto)
	d.state = normalize_state(str(d.state))
	return d


static func member_info(id: Variant, member_name: String, is_owner: bool = false, is_self: bool = false) -> Dictionary:
	return {"id": str(id), "name": member_name, "is_owner": is_owner, "is_self": is_self}


static func version_info(fields: Dictionary = {}) -> Dictionary:
	return {"pitt_version": str(fields.get("pitt_version", "")), "pittapi_version": str(fields.get("pittapi_version", "")),
		"mp_proto": int(fields.get("mp_proto", MP_PROTO)), "mods_hash": str(fields.get("mods_hash", ""))}


static func steam_target(role: String, lobby_id: String, host_steam_id: String) -> Dictionary:
	return {"kind": "steam", "role": role, "lobby_id": lobby_id, "host_steam_id": host_steam_id}


static func enet_target(role: String, address: String, port: int) -> Dictionary:
	return {"kind": "enet", "role": role, "address": address, "port": port}


static func normalize_state(s: String) -> String:
	return s if s in LOBBY_STATES else "waiting"


## Fills compatible / joinable / reason of a LobbyInfo against our VersionInfo.
## Order of reasons: version, mods, ending, full.
static func evaluate(info: Dictionary, version: Dictionary) -> Dictionary:
	var d := info.duplicate()
	d.compatible = true
	d.joinable = true
	d.reason = ""
	if str(d.get("pitt_version", "")) != str(version.get("pitt_version", "")) \
			or str(d.get("pittapi_version", "")) != str(version.get("pittapi_version", "")) \
			or int(d.get("mp_proto", 0)) != int(version.get("mp_proto", MP_PROTO)):
		d.compatible = false
		d.reason = ERR_VERSION
	elif str(d.get("mods_hash", "")) != str(version.get("mods_hash", "")):
		d.compatible = false
		d.reason = ERR_MODS
	if not d.compatible:
		d.joinable = false
		return d
	if str(d.get("state", "")) == "ending":
		d.joinable = false
		d.reason = ERR_ENDING
	elif int(d.get("members", 0)) >= int(d.get("max", MAX_MEMBERS)) and int(d.get("max", 0)) > 0:
		d.joinable = false
		d.reason = ERR_FULL
	return d


## Lobby data (all strings) -> LobbyInfo, evaluated against version.
static func from_lobby_data(lobby_id: String, data: Dictionary, version: Dictionary) -> Dictionary:
	var info := lobby_info({"id": lobby_id, "owner_id": str(data.get("host_steam_id", "")),
		"host_name": str(data.get("host_name", "")), "members": int(str(data.get("members", "0"))),
		"max": int(str(data.get("max", str(MAX_MEMBERS)))), "state": str(data.get("state", "waiting")),
		"pitt_version": str(data.get("pitt_version", "")), "pittapi_version": str(data.get("pittapi_version", "")),
		"mp_proto": int(str(data.get("mp_proto", "0"))), "mods_hash": str(data.get("mods_hash", ""))})
	if info.max <= 0:
		info.max = MAX_MEMBERS
	return evaluate(info, version)


## Lobby data the host writes for a VersionInfo (5.3).
static func host_data(version: Dictionary, host_name: String, host_id: String, members: int, max_members: int,
		state: String) -> Dictionary:
	return {"host_name": host_name, "host_steam_id": host_id, "pitt_version": str(version.get("pitt_version", "")),
		"pittapi_version": str(version.get("pittapi_version", "")), "mp_proto": str(int(version.get("mp_proto", MP_PROTO))),
		"mods_hash": str(version.get("mods_hash", "")), "members": str(members), "max": str(max_members),
		"state": normalize_state(state)}


## Sort for the Join list: joinable first, then host name.
static func sort_rows(list: Array) -> Array:
	var out := list.duplicate()
	out.sort_custom(func(a, b):
		if bool(a.joinable) != bool(b.joinable):
			return bool(a.joinable)
		return str(a.host_name).naturalnocasecmp_to(str(b.host_name)) < 0)
	return out
