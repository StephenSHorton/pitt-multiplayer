extends RefCounted
## Entity meta registry (MP2-DESIGN 3.5). Meta travels as {kind: {field: value}}:
## kind "g" is the built-in save-schema adapter (entity_meta.gd); GAMEPLAY adds
## kind-specific adapters with register(kind, matcher, read, apply, rate_hz).
##   matcher(node) -> bool, read(node) -> Dictionary (JSON-safe),
##   apply(node, changed: Dictionary) on clients, always inside apply scope
##   (the caller holds api.net.begin_apply / end_apply).
## The host polls each reader at its rate for awake / recently interacted
## entities and fixtures, diffs against the last sent dictionary and sends only
## changed fields; meta_dirty pushes at once.

const EntityMeta = preload("entity_meta.gd")


class Adapter extends RefCounted:
	var kind := ""
	var matcher: Callable
	var read: Callable
	var apply: Callable
	var rate_ms := 250
	var builtin := false


var adapters: Array = []          # [Adapter], registration order ("g" first)
var _by_kind: Dictionary = {}
var errors := 0


func _init() -> void:
	var g := Adapter.new()
	g.kind = EntityMeta.KIND
	g.builtin = true
	g.rate_ms = 250
	adapters.append(g)
	_by_kind[g.kind] = g


func register(kind: String, matcher: Callable, read: Callable, apply: Callable, rate_hz: float = 4.0) -> void:
	if kind == "" or kind == EntityMeta.KIND:
		return
	var a: Adapter = _by_kind.get(kind, null)
	if a == null:
		a = Adapter.new()
		a.kind = kind
		adapters.append(a)
		_by_kind[kind] = a
	a.matcher = matcher
	a.read = read
	a.apply = apply
	a.rate_ms = maxi(16, roundi(1000.0 / maxf(rate_hz, 0.1)))


func has_kind(kind: String) -> bool:
	return _by_kind.has(kind)


func rate_ms(kind: String) -> int:
	var a: Adapter = _by_kind.get(kind, null)
	return a.rate_ms if a != null else 250


## The adapter kinds that apply to a node. ent_kind "fixture" (state-only
## fixtures) skips the generic save-schema adapter.
func kinds_for(node: Object, ent_kind: String) -> Array:
	var out: Array = []
	for a in adapters:
		if a.builtin:
			if ent_kind != "fixture":
				out.append(a.kind)
			continue
		if a.matcher.is_valid():
			var ok = a.matcher.call(node)
			if typeof(ok) == TYPE_BOOL and ok:
				out.append(a.kind)
	return out


func read_kind(node: Object, kind: String) -> Dictionary:
	var a: Adapter = _by_kind.get(kind, null)
	if a == null:
		return {}
	if a.builtin:
		return EntityMeta.read(node)
	if not a.read.is_valid():
		return {}
	var d = a.read.call(node)
	if typeof(d) != TYPE_DICTIONARY:
		errors += 1
		return {}
	return d


func read_all(node: Object, kinds: Array) -> Dictionary:
	var out := {}
	for k in kinds:
		var d := read_kind(node, String(k))
		if not d.is_empty():
			out[k] = d
	return out


## Client: applies {kind: changed fields} (generic first, then the adapters in
## registration order). The caller holds the apply scope.
func apply(node: Object, meta: Dictionary, pool_id: String = "") -> void:
	if node == null or not is_instance_valid(node):
		return
	for a in adapters:
		if not meta.has(a.kind) or typeof(meta[a.kind]) != TYPE_DICTIONARY:
			continue
		if a.builtin:
			EntityMeta.apply(node, meta[a.kind], pool_id)
		elif a.apply.is_valid():
			a.apply.call(node, meta[a.kind])


## {kind: {field: v}} merge of `changed` into `base` (in place); returns base.
static func merge_into(base: Dictionary, changed: Dictionary) -> Dictionary:
	for k in changed:
		if typeof(changed[k]) != TYPE_DICTIONARY:
			continue
		if not base.has(k) or typeof(base[k]) != TYPE_DICTIONARY:
			base[k] = {}
		for f in changed[k]:
			base[k][f] = changed[k][f]
	return base
