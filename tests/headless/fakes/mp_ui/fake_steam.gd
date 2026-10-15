extends RefCounted
## FakeSteam: stands in for the GodotSteam singleton in SteamLobbyService tests.
## Same method names, argument order and signal arities as the bundled GodotSteam
## (checked with ClassDB in the decomp instance). Records calls; test code fires
## the callbacks.

signal lobby_created(connect: int, lobby_id: int)
signal lobby_joined(lobby: int, permissions: int, locked: bool, response: int)
signal lobby_chat_update(lobby_id: int, changed_id: int, making_change_id: int, chat_state: int)
signal lobby_data_update(success: int, lobby_id: int, member_id: int)
signal persona_state_change(steam_id: int, flags: int)
signal join_requested(lobby_id: int, steam_id: int)

var calls: Array = []
var me := 76561190000000001
var persona := "Me"
var names: Dictionary = {}          # steam id -> persona name
var friends: Array = []             # steam ids
var playing: Dictionary = {}        # friend id -> {id, lobby}
var lobby_data: Dictionary = {}     # lobby id -> {key: value}
var lobby_members: Dictionary = {}  # lobby id -> [steam ids]
var lobby_owner: Dictionary = {}    # lobby id -> steam id
var presence: Dictionary = {}
var launch_line := ""


func called(name: String) -> Array:
	var out: Array = []
	for c in calls:
		if c[0] == name:
			out.append(c[1])
	return out


func _rec(name: String, args: Array) -> void:
	calls.append([name, args])


func createLobby(lobby_type: int, max_members: int) -> void:
	_rec("createLobby", [lobby_type, max_members])


func joinLobby(steam_lobby_id: int) -> void:
	_rec("joinLobby", [steam_lobby_id])


func leaveLobby(steam_lobby_id: int) -> void:
	_rec("leaveLobby", [steam_lobby_id])


func setLobbyData(steam_lobby_id: int, key: String, value: String) -> bool:
	_rec("setLobbyData", [steam_lobby_id, key, value])
	if not lobby_data.has(steam_lobby_id):
		lobby_data[steam_lobby_id] = {}
	lobby_data[steam_lobby_id][key] = value
	return true


func getLobbyData(steam_lobby_id: int, key: String) -> String:
	return str(lobby_data.get(steam_lobby_id, {}).get(key, ""))


func setLobbyJoinable(steam_lobby_id: int, joinable: bool) -> bool:
	_rec("setLobbyJoinable", [steam_lobby_id, joinable])
	return true


func requestLobbyData(steam_lobby_id: int) -> bool:
	_rec("requestLobbyData", [steam_lobby_id])
	return true


func getLobbyOwner(steam_lobby_id: int) -> int:
	return int(lobby_owner.get(steam_lobby_id, 0))


func getNumLobbyMembers(steam_lobby_id: int) -> int:
	return lobby_members.get(steam_lobby_id, []).size()


func getLobbyMemberByIndex(steam_lobby_id: int, member: int) -> int:
	var m: Array = lobby_members.get(steam_lobby_id, [])
	return int(m[member]) if member < m.size() else 0


func getFriendCount(friend_flags: int = 65535) -> int:
	return friends.size()


func getFriendByIndex(friend_number: int, friend_flags: int) -> int:
	return int(friends[friend_number]) if friend_number < friends.size() else 0


func getFriendGamePlayed(steam_id: int) -> Dictionary:
	return playing.get(steam_id, {})


func getFriendPersonaName(steam_id: int) -> String:
	return str(names.get(steam_id, ""))


func getPersonaName() -> String:
	return persona


func getSteamID() -> int:
	return me


func requestUserInformation(steam_id: int, require_name_only: bool) -> bool:
	_rec("requestUserInformation", [steam_id, require_name_only])
	return true


func setRichPresence(key: String, value: String) -> bool:
	_rec("setRichPresence", [key, value])
	if value == "":
		presence.erase(key)
	else:
		presence[key] = value
	return true


func clearRichPresence() -> void:
	_rec("clearRichPresence", [])
	presence.clear()


func activateGameOverlayInviteDialog(lobby_id: int) -> void:
	_rec("activateGameOverlayInviteDialog", [lobby_id])


func getLaunchCommandLine() -> String:
	return launch_line
