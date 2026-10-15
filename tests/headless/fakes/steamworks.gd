extends Node
## Headless fake of the Steamworks autoload: records unlocks instead of calling Steam.

var is_steam_initialized := false
var _probe_ids: Array = ["ACH_A", "ACH_B", "END_MAIN"]
var _granted: Dictionary = {}
var unlock_calls: Array = []
var _presence_accum: float = 0.0
var presence_clears := 0


func clear_presence() -> void:
	presence_clears += 1


## each id is recorded once
func unlock_achievement(api_name: String) -> void:
	if _granted.get(api_name) == true:
		return
	_granted.merge({api_name: true}, true)
	unlock_calls.append(api_name)
