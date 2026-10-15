extends "res://tests/test_case.gd"

const Serial = preload("res://gamedir/mods/PittAPI/core/serial.gd")


func test_digits() -> void:
	assert_eq(Serial.to_digits(42), "42", "int")
	assert_eq(Serial.to_digits("007"), "7", "leading zeros")
	assert_eq(Serial.to_digits(-1), "", "negative")
	assert_eq(Serial.to_digits("1e5"), "", "not digits")
	assert_eq(Serial.to_digits(3.0), "3", "integral float")
	assert_eq(Serial.digits_add("999", "1"), "1000", "add carry")
	assert_eq(Serial.digits_diff("1000", "1"), {"delta": "999", "sign": 1}, "diff +")
	assert_eq(Serial.digits_diff("5", "12"), {"delta": "7", "sign": -1}, "diff -")
	assert_eq(Serial.digits_compare("10000000000000000000000", "9999999999999999999999"), 1, "big compare")
	assert_true(Serial.digits_fit_int64("9223372036854775807"), "int64 max fits")
	assert_false(Serial.digits_fit_int64("9223372036854775808"), "int64 max+1")


func test_json_safe() -> void:
	assert_eq(Serial.check_json_safe({"a": [1, "x", {"b": null}]}), "", "plain data ok")
	assert_ne(Serial.check_json_safe({"f": NAN}), "", "NaN rejected")
	assert_ne(Serial.check_json_safe({1.5: 2}), "", "non-string key rejected")
	var big = BigInt.from_string("123456789012345678901234567890")
	assert_eq(Serial.to_json_safe({"m": big}).m, "123456789012345678901234567890", "BigInt -> decimal string")
	var t := Transform3D(Basis.IDENTITY, Vector3(1, 2, 3))
	assert_eq(Serial.transform_from(Serial.transform_to_array(t)), t, "transform round trip")
	assert_eq(Serial.vec3_from([1, 2, 3]), Vector3(1, 2, 3), "vec3_from")
	assert_eq(Serial.vec3_from([1, 2]), null, "bad vec3")
