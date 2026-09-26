extends RefCounted
class_name BeaconState
##
## 观察信标状态机 —— 逐行移植原版 src/city-observer-beacon-state.ts。
##
## 纯逻辑：没有场景对象、没有 UI，只负责「什么算合法落点」「收藏怎么编码解码」
## 「长按手势什么时候算触发」。这样它可以单独验证（本轮就是这么做的）。
##
## ⚠️ 浏览器存的是**不可信数据**：解码时要把每个字段重建一遍、丢掉坏行，
## 不能直接 JSON.parse 完就用。

const STORAGE_KEY := "shenchengji-observer-places-v1.json"
const LIMIT := 24
const HOLD_MS := 650
const DRAG_TOLERANCE := 8.0


## 原版 beaconName：去掉控制字符、trim、截到 48 字，空则用兜底名
static func beacon_name(value: String, fallback := "我的地点") -> String:
	var out := ""
	for i in value.length():
		var c := value.unicode_at(i)
		if c >= 0 and c <= 31:
			continue
		if c == 127:
			continue
		out += String.chr(c)
	out = out.strip_edges()
	if out.length() > 48:
		out = out.substr(0, 48)
	return out if out != "" else fallback


static func _finite(v: float, limit: float) -> bool:
	return is_finite(v) and absf(v) <= limit


## 原版 validBeaconPoint
static func valid_point(p) -> bool:
	if not (p is Dictionary):
		return false
	var d: Dictionary = p
	if not d.has("x") or not d.has("y") or not d.has("z") or not d.has("name"):
		return false
	if not _finite(float(d["x"]), 1e6) or not _finite(float(d["z"]), 1e6) \
			or not _finite(float(d["y"]), 1e4):
		return false
	var nm = d["name"]
	if not (nm is String) or (nm as String).length() > 256:
		return false
	if d.has("arrival") and d["arrival"] != null:
		var a = d["arrival"]
		if not (a is Array) or (a as Array).size() != 2:
			return false
		for n in a:
			if not _finite(float(n), 1e6):
				return false
	if d.has("yaw") and d["yaw"] != null and not _finite(float(d["yaw"]), 1e5):
		return false
	return true


## 原版 copyBeaconPoint
static func copy_point(p: Dictionary) -> Dictionary:
	var out := {
		"x": float(p.get("x", 0.0)),
		"y": float(p.get("y", 0.0)),
		"z": float(p.get("z", 0.0)),
		"name": beacon_name(str(p.get("name", ""))),
	}
	if p.get("arrival", null) != null:
		var a: Array = p["arrival"]
		out["arrival"] = [float(a[0]), float(a[1])]
	if p.get("yaw", null) != null:
		out["yaw"] = float(p["yaw"])
	return out


## 原版 decodeBeaconFavorites：存的是不可信数据，逐字段重建 + 丢坏行
static func decode(raw: String) -> Array:
	if raw == "" or raw.length() > 100000:
		return []
	# ⚠️ 用 JSON.new().parse() 而不是 JSON.parse_string()：后者在存档损坏时
	# 会往日志里打一条 ERROR（"Parse JSON failed"），而这里本来就是"坏数据要静默丢弃"。
	var json := JSON.new()
	if json.parse(raw) != OK:
		return []
	var parsed = json.data
	if not (parsed is Dictionary):
		return []
	var data: Dictionary = parsed
	if int(data.get("version", 0)) != 1:
		return []
	var rows = data.get("places", null)
	if not (rows is Array):
		return []
	var out: Array = []
	var ids := {}
	for row in rows:
		if not valid_point(row):
			continue
		var d: Dictionary = row
		var id := str(d.get("id", ""))
		var created := float(d.get("createdAt", -1.0))
		if id == "" or id.length() > 80 or ids.has(id) or not _finite(created, 1e14) or created < 0.0:
			continue
		var p := copy_point(d)
		p["id"] = id
		p["createdAt"] = created
		out.append(p)
		ids[id] = true
		if out.size() == LIMIT:
			break
	return out


## 原版 encodeBeaconFavorites
static func encode(places: Array) -> String:
	var rows: Array = []
	for i in mini(places.size(), LIMIT):
		var p: Dictionary = places[i]
		var row := copy_point(p)
		row["id"] = str(p.get("id", ""))
		row["createdAt"] = float(p.get("createdAt", 0.0))
		rows.append(row)
	return JSON.stringify({"version": 1, "places": rows})


## 原版 matchingBeacon：3m 平面距离 + 8m 高度差内算同一个点
static func matching(places: Array, point: Dictionary) -> Dictionary:
	for p in places:
		var d: Dictionary = p
		var dx := float(d.get("x", 0.0)) - float(point.get("x", 0.0))
		var dz := float(d.get("z", 0.0)) - float(point.get("z", 0.0))
		if sqrt(dx * dx + dz * dz) < 3.0 \
				and absf(float(d.get("y", 0.0)) - float(point.get("y", 0.0))) < 8.0:
			return d
	return {}


## 新建一个收藏（补 id 与时间戳）。原版是 crypto.randomUUID，这里用计数器 + 时间。
static func make_favorite(point: Dictionary, seq: int) -> Dictionary:
	var p := copy_point(point)
	p["id"] = "place-%d-%d" % [Time.get_unix_time_from_system(), seq]
	p["createdAt"] = Time.get_unix_time_from_system() * 1000.0
	return p


# ---------------------------------------------------------------------------
# 长按手势（原版 BeaconHoldGesture）
# ---------------------------------------------------------------------------

## 只消费「按住不动」：一旦取消，正常环绕/平移会拿到从按下点起的完整位移。
class HoldGesture:
	extends RefCounted
	var pointer: Dictionary = {}     ## {id, x, y, started, phase}

	## 原版 begin：只接受左键、主指针、不按 Shift
	func begin(id: int, x: float, y: float, button: int, primary: bool, shift: bool,
			now_ms: float) -> bool:
		if not pointer.is_empty() or button != MOUSE_BUTTON_LEFT or not primary or shift:
			cancel()
			return false
		pointer = {"id": id, "x": x, "y": y, "started": now_ms, "phase": "pending"}
		return true

	## 原版 move：返回 true 表示「手势仍在，调用方应当吞掉这次移动」
	func move(id: int, x: float, y: float) -> bool:
		if pointer.is_empty() or int(pointer["id"]) != id:
			return false
		if str(pointer["phase"]) == "held":
			return true
		var dx := x - float(pointer["x"])
		var dy := y - float(pointer["y"])
		if sqrt(dx * dx + dy * dy) > DRAG_TOLERANCE:
			cancel()
			return false
		return true

	## 原版 fire：按住够久才算触发，然后把 phase 锁成 held
	func fire(now_ms: float) -> Vector2:
		if pointer.is_empty() or str(pointer["phase"]) != "pending":
			return Vector2(INF, INF)
		if now_ms - float(pointer["started"]) < HOLD_MS:
			return Vector2(INF, INF)
		pointer["phase"] = "held"
		return Vector2(float(pointer["x"]), float(pointer["y"]))

	func progress(now_ms: float) -> float:
		if pointer.is_empty() or str(pointer["phase"]) != "pending":
			return 0.0
		return clampf((now_ms - float(pointer["started"])) / HOLD_MS, 0.0, 1.0)

	## 原版 end：返回「这次按压是否已被手势消费」
	func end(id: int) -> bool:
		if pointer.is_empty() or int(pointer["id"]) != id:
			return false
		var consumed := str(pointer["phase"]) == "held"
		cancel()
		return consumed

	func cancel() -> void:
		pointer = {}
