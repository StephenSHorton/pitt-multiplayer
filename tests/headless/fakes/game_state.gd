extends Node
## Headless fake of the GameState autoload (only what PittAPI touches).

signal stat_changed(stat_name: String, new_value)
signal money_updated(new_amount)
signal bank_updated(new_amount)

var money: BigInt = BigInt.from_int(0)
var total_money_gained: BigInt = BigInt.from_int(0)
var total_money_spent: BigInt = BigInt.from_int(0)
var total_bonus_earned: BigInt = BigInt.from_int(0)
var bank: float = 0.0
var is_game_started := false
var sandbox_mode := false
var products_crafted := {"duck": 0, "lucky_duck": 0}
var products_consumed := {"duck": 0}
var upgrades := {
	"luck": {"level": 0, "prices": [100, 200, 400], "enabled": true},
	"sprint": {"level": 0, "prices": [50], "enabled": true},
}
var tools := {"broom": {"level": 0, "prices": [99999], "buy_prices": [500], "enabled": false}}
var toys := {"bumper": {"level": 0, "buy_prices": [1000], "enabled": false}}
var products := {"duck": {"enabled": true,
	"craft_speed": {"level": 0, "prices": [10, 20], "enabled": true},
	"craft_value": {"enabled": true, "level": 0, "prices": [30]},
	"auto_machine": {"enabled": false, "level": 0, "prices": [1000]}}}
var combos := {"time_extension": {"level": 0, "prices": [500], "enabled": false}}
var buy_calls: Array = []


## income: money and the lifetime total grow; a bonus also counts as bonus
func _gain(n: int, is_bonus: bool) -> void:
	for counter in ([money, total_money_gained, total_bonus_earned] if is_bonus else [money, total_money_gained]):
		counter.add_int(n)
	emit_signal("money_updated", money)


func add_money(amount, product_type: String = "") -> void:
	_gain(roundi(float(amount)), false)
	emit_signal("stat_changed", "total_money_gained", total_money_gained)


func add_bonus(amount) -> void:
	_gain(roundi(float(amount)), true)


func can_afford(amount) -> bool:
	return money.compare_int(roundi(float(amount))) != -1


func spend(amount) -> void:
	var n := roundi(float(amount))
	money.sub_int(n)
	total_money_spent.add_int(n)
	emit_signal("money_updated", money)


## the leveled entry a buy() call addresses (products are keyed one level deeper)
func _entry(category: String, key: String, subkey: String) -> Dictionary:
	var table: Dictionary = get(category)
	return table[key][subkey] if category == "products" else table[key]


func buy(category: String, key: String, subkey := "") -> bool:
	buy_calls.append([category, key, subkey])
	var entry := _entry(category, key, subkey)
	var lvl: int = entry["level"]
	var prices: Array = entry["prices"]
	if lvl >= prices.size() or not can_afford(prices[lvl]):
		return false
	spend(prices[lvl])
	entry["level"] = lvl + 1
	return true


## test helper: the golden-statue bypass (money changes, only stat_changed fires)
func fake_statue_bless(amount: int) -> void:
	money.add_int(amount)
	stat_changed.emit("money", money)


## test helper: a silent direct write (no signal at all)
func fake_silent_add(amount: int) -> void:
	money.add_int(amount)
