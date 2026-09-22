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

## blocked() 是每帧被调若干次的热路径（车子步碰撞、自动驾驶、飞行判定…），
## 原来每次都把上千条地标 / 312 个水域外环全量走一遍射线法。
## 这里预打包成扁平数组 + 包围盒，先做 O(1) 的盒子剔除再决定是否进射线法。
var _block_r := PackedFloat32Array()   ## 每 3 个一组：x, z, radius
var _land_box := PackedFloat32Array()  ## 每 4 个一组：minx, maxx, minz, maxz
var _water_box := PackedFloat32Array()
var _hole_box := PackedFloat32Array()

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
	# 预打包地标阻挡圈：原实现是每帧在 blocked() 里重复做 dict.get / bool 判断
	_block_r.clear()
	for lm in _landmarks:
		if bool(lm.get("detailCollision", false)):
			continue
		var h := float(lm.get("height", 0.0))
		if h <= 0.0:
			continue
		var id := str(lm.get("id", ""))
		var radius := 24.0
		if id == "civic":
			radius = 65.0
		elif id == "tencent":
			radius = 46.0
		_block_r.append(float(lm.get("x", 0.0)))
		_block_r.append(float(lm.get("z", 0.0)))
		_block_r.append(radius)

	for r in CityData.land_rings:
		if r.size() >= 3:
			var ring := _pack(r)
			_land_box.append_array(_ring_box(ring))
			_land_rings.append(ring)

	for w in CityData.water:
		var rings: Array = w.get("rings", [])
		if rings.is_empty():
			continue
		var outer := _pack(rings[0])
		_water_box.append_array(_ring_box(outer))
		_water_outer.append(outer)
		for i in range(1, rings.size()):
			var hole := _pack(rings[i])
			_hole_box.append_array(_ring_box(hole))
			_water.append(hole)

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


## 求一个环的包围盒，返回 [minx, maxx, minz, maxz]
static func _ring_box(ring: PackedVector2Array) -> PackedFloat32Array:
	var minx := INF
	var minz := INF
	var maxx := -INF
	var maxz := -INF
	for p in ring:
		minx = minf(minx, p.x)
		maxx = maxf(maxx, p.x)
		minz = minf(minz, p.y)
		maxz = maxf(maxz, p.y)
	return PackedFloat32Array([minx, maxx, minz, maxz])


## 包围盒命中测试（i 为环序号）
static func _box_hit(box: PackedFloat32Array, i: int, x: float, z: float) -> bool:
	var o := i * 4
	return x >= box[o] and x <= box[o + 1] and z >= box[o + 2] and z <= box[o + 3]


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


## 点到线段距离（数据坐标）。blocked() 对建筑环的**每条边**都要测距，
## 原来每一次都走 closest_point() 新建一个 Dictionary（内含 Vector2），
## 建筑密集区每帧产生几十上百个临时字典 → GDScript GC 压力 → 偶发卡顿。
## 这个纯数值版本零分配，专给 blocked() 的逐边判定用。
static func seg_distance(x: float, north: float, a: Vector2, b: Vector2) -> float:
	var dx := b.x - a.x
	var dz := b.y - a.y
	var len2 := dx * dx + dz * dz
	var t := 0.0
	if len2 > 0.0:
		t = ((x - a.x) * dx + (north - a.y) * dz) / len2
	if t < 0.0:
		t = 0.0
	elif t > 1.0:
		t = 1.0
	var px := x - (a.x + dx * t)
	var pz := north - (a.y + dz * t)
	return sqrt(px * px + pz * pz)


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
			# 零分配版本：这里原来是 closest_point()，每条边建一个临时字典
			if seg_distance(x, z, r[i - 1], r[i]) < WALL_MARGIN:
				return true

	# 地标阻挡圈：扁平数组 + 距离平方比较，不再逐条做 dict.get
	for i in range(0, _block_r.size(), 3):
		var mx := _block_r[i]
		var mz := _block_r[i + 1]
		var radius := _block_r[i + 2]
		var dx := x - mx
		var dz := z - mz
		if dx * dx + dz * dz < radius * radius:
			return true

	# 陆地 / 水域：先过包围盒，命中才走 O(n) 的射线法
	var on_land := false
	for i in _land_rings.size():
		if _box_hit(_land_box, i, x, z) and in_ring(x, z, _land_rings[i]):
			on_land = true
			break
	if not on_land:
		return true

	for i in _water_outer.size():
		if not _box_hit(_water_box, i, x, z):
			continue
		if not in_ring(x, z, _water_outer[i]):
			continue
		var in_hole := false
		for j in _water.size():
			if _box_hit(_hole_box, j, x, z) and in_ring(x, z, _water[j]):
				in_hole = true
				break
		if not in_hole:
			return true

	return false


func stats() -> Dictionary:
	return {"roadCells": _cells.size(), "buildingCells": _bcells.size(),
			"landRings": _land_rings.size(), "waterRings": _water_outer.size()}
