extends RefCounted
## PittAuthority: decides where commands run. This base class IS the local
## (single-player) authority: it dispatches every envelope immediately on this
## machine. A future SteamAuthority extends this script, sends client envelopes
## to the host and calls complete() when the host's reply arrives.
##
## Envelope (wire format):
##   {"v":1, "id":int, "name":String, "args":Dictionary, "mod":String, "origin":int, "t":int}

signal peers_changed()

## Set by Commands when the authority is installed.
var commands: Object = null


func get_kind() -> String:
	return "local"


func is_authority() -> bool:
	return true


func local_peer_id() -> int:
	return 1


func get_peers() -> Array[int]:
	return [1]


func is_multiplayer() -> bool:
	return false


## Runs (or forwards) an envelope. Local: validate + dispatch now, then complete.
func submit(envelope: Dictionary) -> void:
	if commands == null:
		return
	var result: Dictionary = commands.dispatch_envelope(envelope)
	complete(envelope, result)


## result: {"ok": bool, "value": Variant, "error": String, "code": String}
func complete(envelope: Dictionary, result: Dictionary) -> void:
	if commands != null:
		commands.complete_envelope(envelope, result)
