extends Node
## Headless fake of UnlockManager.

signal milestone_unlocked(milestone_id: String, milestone_data: Dictionary)

var unlocked_milestones: Array[String] = []
var milestones: Dictionary = {
	"unlock_luck": {"type": "stat_threshold", "stat": "total_money_gained", "threshold": 0,
		"action": {"unlock_upgrade": "luck"}, "category": "cant_miss"},
}


func force_unlock(milestone_id: String) -> void:
	if milestone_id not in milestones or milestone_id in unlocked_milestones:
		return
	unlocked_milestones.append(milestone_id)
	milestone_unlocked.emit(milestone_id, milestones[milestone_id])


func is_unlocked(milestone_id: String) -> bool:
	return unlocked_milestones.has(milestone_id)


func _get_stat(stat_path: String):
	return null
