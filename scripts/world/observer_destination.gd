extends RefCounted
class_name ObserverDestination
##
## 观察模式落点解算 —— 逐行移植原版 src/city-observer-destination.ts。
##
## 解决的问题：在观察模式里点一个风景点，**观察点保持精确**，
## 但只有附近一条「安全、可落车」的道路才能接收车辆 ——
## 并且绝不能变成"跨海湾全局就近吸附"（点在水面上时不许把玩家丢到对岸）。
##
## 安全判据（原版 `safeArrival`，用 9 个车身采样点）：
##   · 9 点全在城区范围内；
##   · 每点到该路段的距离 ≤ 路面半宽 − .35；
##   · 每点地面高度有限、高于水面 +.06、且与中心点高差 ≤ .75（不许横跨高差）；
##   · 水面上的点必须有**真实桥面**支撑（高度 ≥ 水面 + 1）；
##   · 不被建筑 / 道具阻挡。

const ROAD_RADIUS := 300.0
## ⚠️ 新脚本的 `class_name` 要等编辑器重扫才进全局类缓存，静态函数里更不能直接
## 引用类名 —— 用 preload 拿。
const BEACON_STATE := preload("res://scripts/life/observer_beacon_state.gd")
const ROAD_NAMES := preload("res://scripts/core/road_names.gd")
## 原版 DRIVABLE_KINDS
const DRIVABLE_KINDS := ["motorway", "trunk", "primary", "secondary", "tertiary",
	"unclassified", "residential", "service", "living_street"]
## 原版 BODY_SAMPLES：[前, 右]
const BODY_SAMPLES := [
	Vector2(0.0, 0.0), Vector2(2.5, 0.0), Vector2(-2.5, 0.0),
	Vector2(0.0, 1.1), Vector2(0.0, -1.1),
	Vector2(2.5, 1.1), Vector2(2.5, -1.1), Vector2(-2.5, 1.1), Vector2(-2.5, -1.1),
]

var collision: CityCollision
var ground_height: Callable       ## func(x, z) -> float（数据坐标）
var prop_blocked: Callable        ## func(x, z) -> bool，没有就传空
var water_height := CoordinateUtil.WATER_HEIGHT

var _extent := Rect2()
var _land_groups: Array = []      ## 每组 = [外环, 洞...]，环是 [[x,z], ...]
var _water_rings: Array = []      ## 每个 = [外环, 洞...]
var _land_boxes: Array = []
var _water_boxes: Array = []


func setup(p_collision: CityCollision, p_ground_height: Callable) -> void:
	collision = p_collision
	ground_height = p_ground_height
	_extent = CityData.extent
	# land / water 的多边形结构要保留「外环 + 洞」——CityData.land_rings 是拍平过的，
	# 用它会丢掉洞，于是洞里的点会被误判成陆地。所以这里直接读 city.json。
	var city: Dictionary = DataLoader.json_dict("/city/city.json")
	for g in city.get("land", []):
		var rings := _normalize_group(g)
		if rings.is_empty():
			continue
		_land_groups.append(rings)
		_land_boxes.append(_rings_box(rings))
	for w in CityData.water:
		var rings2 := _normalize_group((w as Dictionary).get("rings", []))
		if rings2.is_empty():
			continue
		_water_rings.append(rings2)
		_water_boxes.append(_rings_box(rings2))
	print("[ObserverDestination] 陆地块 %d / 水域 %d" % [_land_groups.size(), _water_rings.size()])


## city.json 的 land 既可能是「分组（含若干环）」也可能是「单个环」
static func _normalize_group(g) -> Array:
	if not (g is Array) or (g as Array).is_empty():
		return []
	var a: Array = g
	if a[0] is Array and not (a[0] as Array).is_empty() and (a[0] as Array)[0] is Array:
		return a            # 分组：内层每个元素才是一个环
	return [a]              # 直接就是环


static func _rings_box(rings: Array) -> Array:
	var min_x := INF
	var min_z := INF
	var max_x := -INF
	var max_z := -INF
	for p in (rings[0] as Array):
		min_x = minf(min_x, float(p[0]))
		min_z = minf(min_z, float(p[1]))
		max_x = maxf(max_x, float(p[0]))
		max_z = maxf(max_z, float(p[1]))
	return [min_x, min_z, max_x, max_z]


## 原版 polygonContains：外环内 且 不在任何洞里
static func _group_contains(rings: Array, box: Array, x: float, z: float) -> bool:
	if x < box[0] or x > box[2] or z < box[1] or z > box[3]:
		return false
	if not _in_ring(rings[0], x, z):
		return false
	for i in range(1, rings.size()):
		if _in_ring(rings[i], x, z):
			return false
	return true


## 射线法（数据坐标，环是 [[x,z], ...]；末点可与首点重复，与原版 inRing 一致）
static func _in_ring(ring, x: float, z: float) -> bool:
	var n: int = (ring as Array).size() - 1
	if n < 3:
		return false
	var inside := false
	var j := n - 1
	for i in n:
		var pi: Array = ring[i]
		var pj: Array = ring[j]
		var xi := float(pi[0])
		var zi := float(pi[1])
		var xj := float(pj[0])
		var zj := float(pj[1])
		if (zi > z) != (zj > z) and x < (xj - xi) * (z - zi) / (zj - zi) + xi:
			inside = not inside
		j = i
	return inside


func _within_extent(x: float, z: float) -> bool:
	return is_finite(x) and is_finite(z) \
		and x >= _extent.position.x and x <= _extent.end.x \
		and z >= _extent.position.y and z <= _extent.end.y


## 原版 isWater：不在任何陆地块里，或落在某个水域环里
func is_water(x: float, z: float) -> bool:
	var on_land := false
	for i in _land_groups.size():
		if _group_contains(_land_groups[i], _land_boxes[i], x, z):
			on_land = true
			break
	if not on_land:
		return true
	for i in _water_rings.size():
		if _group_contains(_water_rings[i], _water_boxes[i], x, z):
			return true
	return false


## 原版 nearbyRoads：碰撞模块的 90m 格索引里找 300m 内的可行车路段，按距离升序
func _nearby_roads(x: float, z: float) -> Array:
	var out: Array = []
	if collision == null:
		return out
	var size := CityCollision.CELL
	var seen := {}
	var lo_x := int(floor((x - ROAD_RADIUS) / size))
	var hi_x := int(floor((x + ROAD_RADIUS) / size))
	var lo_z := int(floor((z - ROAD_RADIUS) / size))
	var hi_z := int(floor((z + ROAD_RADIUS) / size))
	for cx in range(lo_x, hi_x + 1):
		for cz in range(lo_z, hi_z + 1):
			var list = collision._cells.get(CityCollision._key(cx, cz), null)
			if list == null:
				continue
			for seg in list:
				var s: Dictionary = seg
				var road: Dictionary = s["road"]
				var a: Vector2 = s["a"]
				var b: Vector2 = s["b"]
				# 同一个路段会被登记进多个格；用 road.id + 端点做身份键去重
				# （Dictionary 不是 Object，没有 get_instance_id()）
				var key := "%s|%.3f|%.3f" % [str(road.get("id", "")), a.x, a.y]
				if seen.has(key):
					continue
				seen[key] = true
				var kind := str(road.get("kind", "")).trim_suffix("_link")
				if not DRIVABLE_KINDS.has(kind):
					continue
				var grade := str(road.get("grade", "")).to_float()
				if not is_finite(grade) or grade < 0.0:
					continue
				var width := float(road.get("width", 0.0))
				if not is_finite(width) or width < 3.0:
					continue
				if not (is_finite(a.x) and is_finite(a.y) and is_finite(b.x) and is_finite(b.y)):
					continue
				var length := a.distance_to(b)
				if length < 0.1:
					continue
				var proj: Dictionary = CityCollision.closest_point(x, z, a, b)
				if float(proj["d"]) <= ROAD_RADIUS:
					out.append({"segment": s, "distance": float(proj["d"]),
						"t": float(proj["t"]), "length": length})
	out.sort_custom(func(p, q): return float(p["distance"]) < float(q["distance"]))
	return out


## 原版 safeArrival
func _safe_arrival(x: float, z: float, yaw: float, segment: Dictionary) -> bool:
	var center_height := float(ground_height.call(x, z))
	if not is_finite(center_height):
		return false
	var fwd_x := sin(yaw)
	var fwd_z := cos(yaw)
	var road: Dictionary = segment["road"]
	var half := float(road.get("width", 0.0)) * 0.5 - 0.35
	var a: Vector2 = segment["a"]
	var b: Vector2 = segment["b"]
	for raw_sample in BODY_SAMPLES:
		# ⚠️ 常量数组的循环变量是 Variant，`sample.x` 取出来也是 Variant，
		# 后面 `var px := …` 会推断不出来 —— 先落到显式 Vector2。
		var sample: Vector2 = raw_sample
		var px := x + fwd_x * sample.x + fwd_z * sample.y
		var pz := z + fwd_z * sample.x - fwd_x * sample.y
		if not _within_extent(px, pz):
			return false
		if float(CityCollision.closest_point(px, pz, a, b)["d"]) > half:
			return false
		var h := float(ground_height.call(px, pz))
		if not is_finite(h) or h <= water_height + 0.06 or absf(h - center_height) > 0.75:
			return false
		# 碰撞模块对路面脚印豁免水面判定，所以这里还要单独要求真实桥面支撑
		if is_water(px, pz) and h < water_height + 1.0:
			return false
		if collision != null and collision.blocked(px, pz):
			return false
		if prop_blocked.is_valid() and bool(prop_blocked.call(px, pz)):
			return false
	return true


## 原版返回的闭包：`resolve(point, name) -> 目的地`（找不到就返回 {}）
##
## ⚠️ 这里**只**校验「在城区范围内 + y 有限」，与原版一致 —— 不要改成
## `valid_beacon_point()`：那个判据还要求带 name，而解算的入参是纯 {x,y,z}
## （名字是后加的）。本轮自检就是这么抓出这个错的。
func resolve(point: Dictionary, name := "") -> Dictionary:
	if point.is_empty():
		return {}
	var px := float(point.get("x", NAN))
	var py := float(point.get("y", NAN))
	var pz := float(point.get("z", NAN))
	if not _within_extent(px, pz) or not is_finite(py):
		return {}

	var roads := _nearby_roads(px, pz)
	# 命名优先级：显式名字 > 250m 内最近地标 > 最近道路的"附近"式名字 > 兜底
	var nearby_name := ""
	var nearby_d := 250.0
	for lm in CityData.all_landmarks():
		var d: Dictionary = lm
		var dist := Vector2(float(d.get("x", 0.0)) - px, float(d.get("z", 0.0)) - pz).length()
		if dist <= nearby_d:
			nearby_d = dist
			nearby_name = str(d.get("name", ""))
	var fallback := "城市风景"
	if not roads.is_empty():
		fallback = ROAD_NAMES.vicinity_name((roads[0]["segment"] as Dictionary)["road"])
	var destination := {"x": px, "y": py, "z": pz,
		"name": name if name != "" else (nearby_name if nearby_name != "" else fallback)}

	# 点在水面上时**绝不**把玩家挪到附近的岸或看不见的路上
	if py <= water_height + 0.06:
		return destination

	# 沿路段前后各试几个落点（0 / ±8 / ±16 m）
	for entry in roads:
		var seg: Dictionary = entry["segment"]
		var a: Vector2 = seg["a"]
		var b: Vector2 = seg["b"]
		var length := maxf(float(entry["length"]), 0.001)
		var yaw := atan2(b.x - a.x, b.y - a.y)
		var checked := {}
		for offset in [0.0, 8.0, -8.0, 16.0, -16.0]:
			var at := clampf(float(entry["t"]) + offset / length, 0.0, 1.0)
			var at_key := snappedf(at, 0.0001)
			if checked.has(at_key):
				continue
			checked[at_key] = true
			var x := a.x + (b.x - a.x) * at
			var z := a.y + (b.y - a.y) * at
			if Vector2(x - px, z - pz).length() > ROAD_RADIUS:
				continue
			if not _safe_arrival(x, z, yaw, seg):
				continue
			var out := destination.duplicate()
			out["arrival"] = [x, z]
			out["yaw"] = yaw
			return out
	return destination


static func valid_beacon_point(p: Dictionary) -> bool:
	return BEACON_STATE.valid_point(p)
