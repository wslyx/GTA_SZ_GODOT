extends RefCounted
class_name FlightCollision
##
## 飞行碰撞 —— 移植原版 src/city-flight-collision.ts。
##
## ⚠️ 为什么不复用驾驶的 CityCollision.blocked(x, z)：那是**纯二维足迹**判定
## （建筑环 / 地标圈 / 陆地水域），没有高度概念。飞行若用它，飞多高都会撞建筑
## 投影，而且 blocked() 对水面与非陆地返回 true —— 海湾上空全是"墙"，
## 水上飞机根本没法贴海观光。原版同样是另起一套：建筑 = 带 height 的三维棱柱，
## 地形 = 沿线采样。
##
## 判定内容（与原版一致）：
##   - 建筑：rings[0] 外环 + 其余内环（院子洞）挤出至 height 的棱柱，
##     对线段做进洞/出洞求交；跳过 style=="landmark-detail" 与 height<=1.1
##     （替换地标由精确网格负责，本移植无逐网格射线，接受该简化）。
##   - 地形 / 水面：线段每 1.5m 采样，p.y <= max(-0.1, heightAt) + 0.25 即撞
##     （海面上 ~0.15m 以下算撞水）。
##   - 没有道路 / 地标圆柱 / 陆地围合 —— 空中只有楼和地能撞你。
##
## 坐标：数据坐标 (x 东, y 上, z 北)，与 FlightSim 一致。

const CELL := 160.0
const TERRAIN_STEP := 1.5
const TERRAIN_PAD := 0.25

## 建筑棱柱 {rings: Array[PackedVector2Array], height: float, x0,x1,z0,z1}
var _cells: Dictionary = {}   ## cell key → Array of Solid
var _solid_count := 0


## buildings 传 CityData.buildings（做成参数而非直读 autoload，便于无头探针测试）
func build(buildings: Array) -> void:
	var t0 := Time.get_ticks_msec()
	_cells.clear()
	_solid_count = 0
	for b in buildings:
		var height := float(b.get("height", 0.0))
		if str(b.get("style", "")) == "landmark-detail" or height <= 1.1:
			continue
		var raw: Array = b.get("rings", [])
		if raw.is_empty():
			continue
		var rings: Array = []
		for r in raw:
			var packed := _pack_ring(r)
			if packed.size() >= 3:
				rings.append(packed)
		if rings.is_empty():
			continue
		var outer: PackedVector2Array = rings[0]
		var minx := INF
		var minz := INF
		var maxx := -INF
		var maxz := -INF
		for p in outer:
			minx = minf(minx, p.x)
			maxx = maxf(maxx, p.x)
			minz = minf(minz, p.y)
			maxz = maxf(maxz, p.y)
		var solid := {"rings": rings, "height": height,
				"x0": minx, "x1": maxx, "z0": minz, "z1": maxz}
		_solid_count += 1
		for cx in range(int(floor(minx / CELL)), int(floor(maxx / CELL)) + 1):
			for cz in range(int(floor(minz / CELL)), int(floor(maxz / CELL)) + 1):
				var k := (cx + 32768) * 65536 + (cz + 32768)
				if not _cells.has(k):
					_cells[k] = []
				_cells[k].append(solid)
	print("[FlightCollision] 建筑棱柱 %d 个 / 索引格 %d，构建 %d ms"
			% [_solid_count, _cells.size(), Time.get_ticks_msec() - t0])


## rings 可能是 PackedVector2Array，也可能是 [[x,z], ...]（city_data 两种都有）
static func _pack_ring(r) -> PackedVector2Array:
	if r is PackedVector2Array:
		return r
	var pts := PackedVector2Array()
	pts.resize(r.size())
	for i in r.size():
		var p = r[i]
		if p is Vector2:
			pts[i] = p
		else:
			pts[i] = Vector2(float(p[0]), float(p[1]))
	return pts


## 线段扫描：返回 {point:{x,y,z}, kind:"building"|"terrain"} 或空字典。
## height_at: func(east, north) -> float（数据坐标，注入 world.height_field.height_at）。
func sweep(a: Vector3, b: Vector3, height_at: Callable) -> Dictionary:
	# 1) 建筑棱柱：沿线段 AABB 收集候选格
	var best_t := INF
	var candidates: Array = []
	var seen := {}
	for cx in range(int(floor(minf(a.x, b.x) / CELL)), int(floor(maxf(a.x, b.x) / CELL)) + 1):
		for cz in range(int(floor(minf(a.z, b.z) / CELL)), int(floor(maxf(a.z, b.z) / CELL)) + 1):
			for s in _cells.get((cx + 32768) * 65536 + (cz + 32768), []):
				if not seen.has(s):
					seen[s] = true
					candidates.append(s)
	for s in candidates:
		# 高度 / 包围盒剪枝（原版同款四个不等式）
		if minf(a.y, b.y) > float(s["height"]):
			continue
		if maxf(a.x, b.x) < float(s["x0"]) or minf(a.x, b.x) > float(s["x1"]):
			continue
		if maxf(a.z, b.z) < float(s["z0"]) or minf(a.z, b.z) > float(s["z1"]):
			continue
		var t := _intersect_prism(a, b, s["rings"], float(s["height"]))
		if t >= 0.0 and t < best_t:
			best_t = t
	# 2) 地形 / 水面：每 1.5m 采样，先于建筑的命中优先（原版 u>=t 即停）
	var steps := maxi(1, int(ceil(Vector3(b.x - a.x, b.y - a.y, b.z - a.z).length() / TERRAIN_STEP)))
	for i in steps + 1:
		var u := float(i) / float(steps)
		if u >= best_t:
			break
		var p := a.lerp(b, u)
		if p.y <= maxf(-0.1, float(height_at.call(p.x, p.z))) + TERRAIN_PAD:
			return {"point": {"x": p.x, "y": p.y, "z": p.z}, "kind": "terrain"}
	if best_t < INF:
		var ph := a.lerp(b, best_t)
		return {"point": {"x": ph.x, "y": ph.y, "z": ph.z}, "kind": "building"}
	return {}


## t ∈ [0,1] 命中参数；未命中返回 -1.0
static func _intersect_prism(a: Vector3, b: Vector3, rings: Array, height: float) -> float:
	var dy := b.y - a.y
	var lo := 0.0
	var hi := 1.0
	if absf(dy) < 1e-9:
		if a.y < 0.0 or a.y > height:
			return -1.0
	else:
		var p := -a.y / dy
		var q := (height - a.y) / dy
		lo = maxf(0.0, minf(p, q))
		hi = minf(1.0, maxf(p, q))
		if lo > hi:
			return -1.0
	if _inside(a.lerp(b, lo), rings):
		return lo
	var dx := b.x - a.x
	var dz := b.z - a.z
	var cuts: Array = [lo, hi]
	for ring in rings:
		for i in range(1, ring.size()):
			var pv: Vector2 = ring[i - 1]
			var qv: Vector2 = ring[i]
			var ex := qv.x - pv.x
			var ez := qv.y - pv.y
			var den := dx * ez - dz * ex
			if absf(den) < 1e-9:
				continue
			var px := pv.x - a.x
			var pz := pv.y - a.z
			var t := (px * ez - pz * ex) / den
			var u := (px * dz - pz * dx) / den
			if t >= lo and t <= hi and u >= 0.0 and u <= 1.0:
				cuts.append(t)
	cuts.sort()
	for i in range(cuts.size() - 1):
		if _inside(a.lerp(b, (float(cuts[i]) + float(cuts[i + 1])) * 0.5), rings):
			return float(cuts[i])
	if _inside(a.lerp(b, hi), rings):
		return hi
	return -1.0


## 外环内且不在任何内环（院子洞）里
static func _inside(p: Vector3, rings: Array) -> bool:
	if not CityCollision.in_ring(p.x, p.z, rings[0]):
		return false
	for i in range(1, rings.size()):
		if CityCollision.in_ring(p.x, p.z, rings[i]):
			return false
	return true
