class_name BigInt
extends RefCounted
## Headless stand-in for the game's BigInt (our own implementation: a decimal
## digit string). Same method names; never negative (subtraction floors at 0).

var limbs: Array = [0]   # present only so duck-typed checks see the same member
var _d := "0"


static func from_int(v: int) -> BigInt:
	var b := BigInt.new()
	b._d = str(maxi(v, 0))
	return b


static func from_string(s: String) -> BigInt:
	var b := BigInt.new()
	s = s.strip_edges().trim_prefix("-")
	if s.is_valid_int():
		b._d = _norm(s)
	elif s.is_valid_float():
		b._d = _norm(String.num(floor(absf(float(s))), 0))
	else:
		b._d = "0"
	return b


static func _norm(s: String) -> String:
	s = s.lstrip("0")
	return "0" if s.is_empty() else s


func clone() -> BigInt:
	var b := BigInt.new()
	b._d = _d
	return b


func is_zero() -> bool:
	return _d == "0"


func add_int(v: int) -> void:
	if v > 0:
		add_big(from_int(v))


func add_big(other: BigInt) -> void:
	var a := _d
	var b := other._d
	var out := ""
	var i := a.length() - 1
	var j := b.length() - 1
	var carry := 0
	while i >= 0 or j >= 0 or carry > 0:
		var s := carry
		if i >= 0:
			s += a.unicode_at(i) - 48
		if j >= 0:
			s += b.unicode_at(j) - 48
		out = str(s % 10) + out
		carry = s / 10
		i -= 1
		j -= 1
	_d = _norm(out)


func sub_int(v: int) -> void:
	if v > 0:
		sub_big(from_int(v))


func sub_big(other: BigInt) -> void:
	if compare(other) <= 0:
		_d = "0"
		return
	var a := _d
	var b := other._d
	var out := ""
	var i := a.length() - 1
	var j := b.length() - 1
	var borrow := 0
	while i >= 0:
		var d := a.unicode_at(i) - 48 - borrow
		if j >= 0:
			d -= b.unicode_at(j) - 48
		if d < 0:
			d += 10
			borrow = 1
		else:
			borrow = 0
		out = str(d) + out
		i -= 1
		j -= 1
	_d = _norm(out)


func compare(other: BigInt) -> int:
	if _d.length() != other._d.length():
		return 1 if _d.length() > other._d.length() else -1
	if _d == other._d:
		return 0
	return 1 if _d > other._d else -1


func compare_int(v: int) -> int:
	return compare(from_int(v))


func to_plain_string() -> String:
	return _d


func to_float() -> float:
	return float(_d)
