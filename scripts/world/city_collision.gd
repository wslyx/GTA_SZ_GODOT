extends RefCounted
class_name CityCollision
##
## 城市碰撞 —— 一比一移植原版 src/driving.ts 的 CityCollision。
##
## 特点：**不是物理引擎碰撞**，而是基于 OSM 环与路段的解析式判定：
##   - 站在某条路上（离路中心线足够近）→ 不阻挡
##   - 落在建筑环内，或距建筑外墙 < 1.15m → 阻挡
##   - 距某些地标中心 < 特定半径 → 阻挡（civic 65 / tencent 46 / 其他 24）
##   - 不在陆地内，或在水面内 → 阻挡
## 原版用边长 90 的均匀网格做索引，这里保持一致。
##
## 坐标一律为**数据坐标** (east, north)。

const CELL := 90.0
const ROAD_CLEARANCE := 0.65
const WALL_MARGIN := 1.15

var _cells: Dictionary = {}   ## cell key → Array of {a:Vector2, b:Vector2, road:Dictionary}
var _bcells: Dictionary = {}  ## cell key → Array of PackedVector2Array
var _landmarks: Array = []
var _land_rings: Array = []
var _water: Array = []
var _water_outer: Array = []

var _seg_cache: Dictionary = {}
var _ring_cache: Dictionary = {}


func _init() -> void:
	pass


func build(data_hint: Node = null) -> void:
	var roads: Array = CityData.roads
	var buildings: Array = CityData.buildings
	var t0 := Time.get_ticks_msec()

	for road in roads:
		var pts: PackedVector2Array = road["points"]
		for i in range(1, pts.size()):
			var a := pts[i - 1]
			var b := pts[i]
			var seg := {"a": a, "b": b, "road": road}
			var x0 := int(floor(minf(a.x, b.x) / CELL))
			var x1 := int(floor(maxf(a.x, b.x) / CELL))
			var z0 := int(floor(minf(a.y, b.y) / CELL))
			var z1 := int(floor(maxf(a.y, b.y) / CELL))
			for cx in range(x0 - 1, x1 + 2):
				for cz in range(z0 - 1, z1 + 2):
					var k := _key(cx, cz)
					if not _cells.has(k):
						_cells[k] = []
					_cells[k].append(seg)

	for b in buildings:
		var rings: Array = b["rings"]
		if rings.is_empty():
			continue
		var ring: PackedVector2Array = rings[0]
		var minx := INF
		var minz := INF
		var maxx := -INF
		var maxz := -INF
		for p in ring:
			minx = minf(minx, p.x)
			maxx = maxf(maxx, p.x)
			minz = minf(minz, p.y)
			maxz = maxf(maxz, p.y)
		for cx in range(int(floor(minx / CELL)), int(floor(maxx / CELL)) + 1):
			for cz in range(int(floor(minz / CELL)), int(floor(maxz / CELL)) + 1):
				var k := _key(cx, cz)
				if not _bcells.has(k):
					_bcells[k] = []
				_bcells[k].append(ring)

	_landmarks = CityData.all_landmarks()
	for lm in _landmarks:
		if bool(lm.get("detailCollision", false)):
			continue

	for r in CityData.land_rings:
		if r.size() >= 3:
			_land_rings.append(_pack(r))

	for w in CityData.water:
		var rings: Array = w.get("rings", [])
		if rings.is_empty():
			continue
		var outer := _pack(rings[0])
		_water_outer.append(outer)
		for i in range(1, rings.size()):
			_water.append(_pack(rings[i]))

	# 注意：water 的洞（内环）在原版里是**排除**水面的，见 blocked() 的最后一行
	print("[CityCollision] 构建完成 %d ms：路段格 %d / 建筑格 %d / 陆地环 %d / 水域 %d"
		% [Time.get_ticks_msec() - t0, _cells.size(), _bcells.size(), _land_rings.size(), _water_outer.size()])


static func _pack(ring: Array) -> PackedVector2Array:
	var pts := PackedVector2Array()
	pts.resize(ring.size())
	for i in ring.size():
		var p = ring[i]
		if p is Vector2:
			pts[i] = p
		else:
			pts[i] = Vector2(float(p[0]), float(p[1]))
	return pts


static func _key(cx: int, cz: int) -> int:
	return (cx + 32768) * 65536 + (cz + 32768)


## 最近路段：返回 {point:Vector2, d:float, yaw:float, road:Dictionary} 或空字典
func nearest(east: float, north: float) -> Dictionary:
	var k := _key(int(floor(east / CELL)), int(floor(north / CELL)))
	if not _cells.has(k):
		return {}
	var best := {}
	var best_d := INF
	for s in _cells[k]:
		var p := closest_point(east, north, s["a"], s["b"])
		if p["d"] < best_d:
			best_d = p["d"]
			var a: Vector2 = s["a"]
			var b: Vector2 = s["b"]
			best = {"point": p["point"], "d": p["d"], "yaw": atan2(b.x - a.x, b.y - a.y), "road": s["road"]}
	return best


## 点到线段最近点（数据坐标）
static func closest_point(x: float, north: float, a: Vector2, b: Vector2) -> Dictionary:
	var dx := b.x - a.x
	var dz := b.y - a.y
	var len2 := dx * dx + dz * dz
	var t := 0.0
	if len2 > 0.0:
		t = clamp(((x - a.x) * dx + (north - a.y) * dz) / len2, 0.0, 1.0)
	var px := a.x + dx * t
	var pz := a.y + dz * t
	return {"point": Vector2(px, pz), "d": sqrt((x - px) * (x - px) + (north - pz) * (north - pz)), "t": t}


## 射线法环包含测试（数据坐标）
static func in_ring(x: float, z: float, ring: PackedVector2Array) -> bool:
	var yes := false
	var n := ring.size()
	var j := n - 1
	for i in n:
		var a := ring[i]
		var b := ring[j]
		if (a.y > z) != (b.y > z):
			if x < (b.x - a.x) * (z - a.y) / (b.y - a.y) + a.x:
				yes = not yes
		j = i
	return yes


## 原版 blocked(x, z)
func blocked(x: float, z: float) -> bool:
	var near := nearest(x, z)
	if not near.is_empty():
		if near["d"] < float(near["road"]["width"]) * 0.5 - ROAD_CLEARANCE:
			return false

	var k := _key(int(floor(x / CELL)), int(floor(z / CELL)))
	for r in _bcells.get(k, []):
		if in_ring(x, z, r):
			return true
		for i in range(1, r.size()):
			if closest_point(x, z, r[i - 1], r[i])["d"] < WALL_MARGIN:
				return true

	for m in _landmarks:
		if bool(m.get("detailCollision", false)):
			continue
		var h := float(m.get("height", 0.0))
		if h <= 0.0:
			continue
		var id := str(m.get("id", ""))
		var radius := 24.0
		if id == "civic":
			radius = 65.0
		elif id == "tencent":
			radius = 46.0
		var mx := float(m.get("x", 0.0))
		var mz := float(m.get("z", 0.0))
		if sqrt((x - mx) * (x - mx) + (z - mz) * (z - mz)) < radius:
			return true

	var on_land := false
	for ring in _land_rings:
		if in_ring(x, z, ring):
			on_land = true
			break
	if not on_land:
		return true

	for ring in _water_outer:
		if in_ring(x, z, ring):
			var in_hole := false
			for hole in _water:
				if in_ring(x, z, hole):
					in_hole = true
					break
			if not in_hole:
				return true

	return false


func stats() -> Dictionary:
	return {"roadCells": _cells.size(), "buildingCells": _bcells.size(),
			"landRings": _land_rings.size(), "waterRings": _water_outer.size()}
