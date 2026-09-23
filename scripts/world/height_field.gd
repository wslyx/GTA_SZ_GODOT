extends RefCounted
class_name HeightField
##
## 地面高度场 —— 一比一复刻原版的 `world.groundHeight(x, z)` 管线。
##
## 原版按顺序层层包裹，后一层在前一层结果上叠加：
##   base = 0                                      城市基准平面
##   → 莲花山高程场        (city/terrain-detail.json)
##   → 远山 / 近山 delta    (mountain-relief/{heights,near-heights}.bin)
##   → 公园缓坡            (ground-relief/relief-mesh.bin)
##   → 跨海桥梁引桥         (coastal/infrastructure.json 的 crossings)
##   → 咖啡馆地板 / 露台    (bamboo-cafe)
##
## 所有网格都是 float32 行主序，(east, north) 平面，north 随行号增大。
##
## 注意：这里的坐标是**数据坐标** (east, north)，不是 Godot 世界坐标。
## 世界侧调用请用 CityWorld.ground_height_world(Vector3) 包装。

## 莲花山：terrain-detail.json 的 grid
var _lh_x0 := 0.0
var _lh_z0 := 0.0
var _lh_dx := 1.0
var _lh_dz := 1.0
var _lh_cols := 0
var _lh_rows := 0
var _lh_heights := PackedFloat32Array()
var _has_lianhua := false

## 远山 / 近山 delta
var _mt_x0 := 0.0
var _mt_z0 := 0.0
var _mt_step := 36.0
var _mt_cols := 0
var _mt_rows := 0
var _mt_heights := PackedFloat32Array()
var _has_mountain := false

var _nr_x0 := 0.0
var _nr_z0 := 0.0
var _nr_step := 12.0
var _nr_cols := 0
var _nr_rows := 0
var _nr_heights := PackedFloat32Array()
var _has_near := false

## 公园缓坡：每块地形的三角面（数据坐标 + 高度）
var _relief_tris: Array = []  ## [Vector3 a, Vector3 b, Vector3 c]（x=east, y=高度, z=north）
## 三角形的 XZ 网格桶：Vector2i → PackedInt32Array（三角形下标）。
## 54973 个三角形线性扫的话，单次 ground_height 就是几万次运算。
const RELIEF_CELL := 64.0
var _relief_grid: Dictionary = {}
var _has_relief := false

## 跨水桥梁（原版 src/city-coastal-infrastructure.ts 的 createBridgeHeightSampler）
##
## crossings 的 points 是**折线**，要按相邻点对拆成段来登记 —— 原版：
##   `for (let i=1;i<b.points.length;i++) add(crossings,{a:points[i-1],b:points[i],...}, b.ramp)`
var _bridge_segs: Array = []          ## [{a:Vector2, b:Vector2, width, height, ramp}]
var _bridge_cells: Dictionary = {}    ## 格键 → Array(int)，_bridge_segs 下标
## 原版还有一个 roads 索引：桥面标高**只在路面上生效**（onRoad 闸门）。
## 全量索引 1.2 万条道路要跑几万次格子登记，而桥面标高只在桥附近非零，
## 所以只收录"外扩 width/2+8 之后能碰到某个已登记桥格"的路段。
var _gate_segs: Array = []            ## [{a:Vector2, b:Vector2, margin}]
var _gate_cells: Dictionary = {}
var water_height := -0.25

## 桥梁索引网格边长（原版 `const size = 100`）
const BRIDGE_CELL := 100.0
## 原版 onRoad 判据里的固定余量：`closest(x,z,s.a,s.b).d <= s.width/2 + 8`
const BRIDGE_ROAD_SLACK := 8.0

## 咖啡馆地板回调（由 bamboo_cafe 注入）
var cafe_floor: Callable = Callable()

var loaded_layers: Array[String] = []


func load_all() -> void:
	# 防重入护栏：load_all 跑在 CityWorld 的构建步骤里，一旦中途出错返回 falsy，
	# 步骤不前进就会**每帧重试**（实测因此刷出 137 万行错误日志、内存耗尽）。
	# 所以标记在开头置位 —— 无论成败都只跑一次。
	if _loaded_all:
		return
	_loaded_all = true
	load_lianhua()
	load_mountains()
	load_relief()
	load_crossings()


var _loaded_all := false


# ---------------------------------------------------------------------------
# 1) 莲花山高程（原 terrainHeight()，逐行照搬其 SW→NE 剖分）
# ---------------------------------------------------------------------------

func load_lianhua() -> void:
	var td: Dictionary = CityData.terrain_detail
	if td.is_empty():
		td = DataLoader.json_dict("/city/terrain-detail.json")
	var grid: Dictionary = td.get("grid", {})
	if grid.is_empty():
		return
	_lh_x0 = float(grid["x0"])
	_lh_z0 = float(grid["z0"])
	_lh_dx = float(grid["dx"])
	_lh_dz = float(grid["dz"])
	_lh_cols = int(grid["columns"])
	_lh_rows = int(grid["rows"])
	var h: Array = grid["heights"]
	if h.size() != _lh_cols * _lh_rows:
		push_warning("[HeightField] 莲花山高程网格尺寸不符，跳过")
		return
	_lh_heights.resize(h.size())
	for i in h.size():
		_lh_heights[i] = float(h[i])
	_has_lianhua = true
	loaded_layers.append("lianhua(%dx%d @%.0fm)" % [_lh_cols, _lh_rows, _lh_dx])


func lianhua_height(east: float, north: float) -> float:
	if not _has_lianhua:
		return 0.0
	# 原版：网格外一律 0（只有这一片补了高程）
	var c := (east - _lh_x0) / _lh_dx
	var r := (north - _lh_z0) / _lh_dz
	if c < 0.0 or r < 0.0 or c > _lh_cols - 1 or r > _lh_rows - 1:
		return 0.0
	var i := mini(int(floor(c)), _lh_cols - 2)
	var j := mini(int(floor(r)), _lh_rows - 2)
	var u := c - i
	var v := r - j
	var k := j * _lh_cols + i
	# 每个格子按 SW->NE 剖分（与 build_landmark_details.py 导出的三角面一致）
	if u >= v:
		return _lh_heights[k] * (1.0 - u) + _lh_heights[k + 1] * (u - v) + _lh_heights[k + _lh_cols + 1] * v
	return _lh_heights[k] * (1.0 - v) + _lh_heights[k + _lh_cols + 1] * u + _lh_heights[k + _lh_cols] * (v - u)


# ---------------------------------------------------------------------------
# 2) 远山 / 近山
# ---------------------------------------------------------------------------

func _load_float_grid(rel: String, x0: float, z0: float, step: float, cols: int, rows: int) -> PackedFloat32Array:
	var raw := DataLoader.bytes(rel)
	var want := cols * rows
	if raw.size() < want * 4:
		push_warning("[HeightField] %s 长度不足（%d < %d）" % [rel, raw.size(), want])
		return PackedFloat32Array()
	# 用 to_float32_array() 一次性转换（62 万次逐字节 decode_float 在 GDScript
	# 里要好几秒，是启动卡顿的元凶之一）
	var all := raw.to_float32_array()
	if all.size() < want:
		return PackedFloat32Array()
	return all.slice(0, want)


func load_mountains() -> void:
	var mm: Dictionary = DataLoader.json_dict("/city/mountain-relief/manifest.json")
	var grid: Dictionary = mm.get("grid", {})
	if not grid.is_empty():
		_mt_x0 = float(grid["x0"])
		_mt_z0 = float(grid["z0"])
		_mt_step = float(grid["step"])
		_mt_cols = int(grid["columns"])
		_mt_rows = int(grid["rows"])
		_mt_heights = _load_float_grid("/city/mountain-relief/" + str(mm.get("file", "heights.bin")),
			_mt_x0, _mt_z0, _mt_step, _mt_cols, _mt_rows)
		_has_mountain = _mt_heights.size() == _mt_cols * _mt_rows
		if _has_mountain:
			loaded_layers.append("mountain(%dx%d @%.0fm)" % [_mt_cols, _mt_rows, _mt_step])

	var nm: Dictionary = DataLoader.json_dict("/city/mountain-relief/near-manifest.json")
	var ng: Dictionary = nm.get("grid", {})
	if not ng.is_empty():
		_nr_x0 = float(ng["x0"])
		_nr_z0 = float(ng["z0"])
		_nr_step = float(ng["step"])
		_nr_cols = int(ng["columns"])
		_nr_rows = int(ng["rows"])
		_nr_heights = _load_float_grid("/city/mountain-relief/" + str(nm.get("file", "near-heights.bin")),
			_nr_x0, _nr_z0, _nr_step, _nr_cols, _nr_rows)
		_has_near = _nr_heights.size() == _nr_cols * _nr_rows
		if _has_near:
			loaded_layers.append("near-mountain(%dx%d @%.0fm)" % [_nr_cols, _nr_rows, _nr_step])


## 双线性 + 对角线 b–d（与原版 mountain-relief 的采样一致）
func _sample_grid(h: PackedFloat32Array, x0: float, z0: float, step: float, cols: int, rows: int, east: float, north: float) -> float:
	var c := (east - x0) / step
	var r := (north - z0) / step
	if c < 0.0 or r < 0.0 or c > cols - 1 or r > rows - 1:
		return 0.0
	var i := mini(int(floor(c)), cols - 2)
	var j := mini(int(floor(r)), rows - 2)
	var u := c - i
	var v := r - j
	var a := h[j * cols + i]
	var b := h[j * cols + i + 1]
	var d := h[(j + 1) * cols + i]
	var e := h[(j + 1) * cols + i + 1]
	# 对角线 a–e：u+v<=1 走 a/b/d，否则走 e/b/d
	if u + v <= 1.0:
		return a + (b - a) * u + (d - a) * v
	return e + (d - e) * (1.0 - u) + (b - e) * (1.0 - v)


func mountain_delta(east: float, north: float) -> float:
	var d := 0.0
	if _has_mountain:
		d += _sample_grid(_mt_heights, _mt_x0, _mt_z0, _mt_step, _mt_cols, _mt_rows, east, north)
	if _has_near:
		d += _sample_grid(_nr_heights, _nr_x0, _nr_z0, _nr_step, _nr_cols, _nr_rows, east, north)
	return d


# ---------------------------------------------------------------------------
# 3) 公园缓坡（三角形网格采样）
# ---------------------------------------------------------------------------

func load_relief() -> void:
	var man: Dictionary = DataLoader.json_dict("/city/ground-relief/manifest.json")
	if man.is_empty():
		return
	var raw := DataLoader.bytes("/city/ground-relief/" + str(man.get("mesh", "relief-mesh.bin")))
	if raw.is_empty():
		return
	var offset := float(man.get("surfaceOffset", 0.012))
	_relief_tris.clear()
	for tile in man.get("tiles", []):
		var vc := int(tile["vertexCount"])
		var pc: Dictionary = tile["positions"]
		var po := int(pc["offset"])
		# 切片 + to_float32_array()，比逐字节 decode_float 快一个数量级
		var pos_f := raw.slice(po, po + vc * 12).to_float32_array()
		var verts := PackedVector3Array()
		verts.resize(vc)
		for i in vc:
			verts[i] = Vector3(pos_f[i * 3], pos_f[i * 3 + 1], pos_f[i * 3 + 2])
		var ic: Dictionary = tile["indices"]
		var io := int(ic["offset"])
		var icount := int(ic["bytes"]) / 4
		var t := 0
		while t + 2 < icount:
			var i0 := raw.decode_u32(io + (t + 0) * 4)
			var i1 := raw.decode_u32(io + (t + 1) * 4)
			var i2 := raw.decode_u32(io + (t + 2) * 4)
			if i0 < vc and i1 < vc and i2 < vc:
				var a := verts[i0]
				var b := verts[i1]
				var c := verts[i2]
				_relief_tris.append([a, b, c])
				# 按 XZ 网格分桶：relief_height 每次查询原本要**线性扫全部三角形**
				#（54973 个），而 ground_height 又被林冠（9000 棵/2s）、行人、车流、
				# 电摩反复调用 —— 不建索引的话这是全项目最大的热点。
				# 三个顶点各登记一次，保证跨格三角形也能被查到。
				#
				# 注：历史上这里报过 `Parameter "mem" is null. at: realloc_static`，
				# 曾被误判为"Dictionary 下标取出的是 COW 副本"，实际上是下面的 while
				# 漏了 t += 3 造成死循环、把内存撑爆了。Array 是引用类型，
				# `_relief_grid[ck].append(idx)` 本身是可以的；这里保留先取再写回的
				# 写法，行为一致，不影响正确性。
				var idx := _relief_tris.size() - 1
				for v in [a, b, c]:
					var ck := Vector2i(int(floor(v.x / RELIEF_CELL)), int(floor(v.z / RELIEF_CELL)))
					if _relief_grid.has(ck):
						var arr: Array = _relief_grid[ck]
						arr.append(idx)
						_relief_grid[ck] = arr
					else:
						_relief_grid[ck] = [idx]
			# ⚠️ 之前这里漏了 t += 3 —— while 条件永远成立，死循环不断
			# _relief_tris.append()，直到内存耗尽刷满
			#   Parameter "mem" is null. at: realloc_static
			# 表现就是启动后内存直线飙升、永远加载不完、最后以 exit=1 退出。
			t += 3
	_has_relief = _relief_tris.size() > 0
	if _has_relief:
		loaded_layers.append("relief(%d tris, %d cells)" % [_relief_tris.size(), _relief_grid.size()])


## 在三角形网格上取高度：XZ 平面点落三角形 → 重心插值。
## 先按网格桶取出候选三角形，再做重心测试 —— 不再线性扫全部三角形。
func relief_height(east: float, north: float) -> float:
	if not _has_relief:
		return 0.0
	var ck := Vector2i(int(floor(east / RELIEF_CELL)), int(floor(north / RELIEF_CELL)))
	var cands = _relief_grid.get(ck)
	if cands == null:
		return 0.0
	var p := Vector2(east, north)
	for ti in cands:
		var tri: Array = _relief_tris[ti]
		var a: Vector3 = tri[0]
		var b: Vector3 = tri[1]
		var c: Vector3 = tri[2]
		var r := _barycentric(p, Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z))
		if r.x >= -0.0005 and r.y >= -0.0005 and r.z >= -0.0005:
			return a.y * r.x + b.y * r.y + c.y * r.z
	return 0.0


static func _barycentric(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> Vector3:
	var v0 := b - a
	var v1 := c - a
	var v2 := p - a
	var den := v0.x * v1.y - v1.x * v0.y
	if absf(den) < 1e-9:
		return Vector3(-1, -1, -1)
	var inv := 1.0 / den
	var u := (v2.x * v1.y - v1.x * v2.y) * inv
	var v := (v0.x * v2.y - v2.x * v0.y) * inv
	return Vector3(1.0 - u - v, u, v)


# ---------------------------------------------------------------------------
# 4) 跨水桥梁（原版 createBridgeHeightSampler）
# ---------------------------------------------------------------------------

static func _cell_key(cx: int, cz: int) -> int:
	return (cx + 32768) * 65536 + (cz + 32768)


## 把线段 a-b 的包围盒（外扩 margin）覆盖到的格子全部登记上 idx（原版 add()）。
## 大线段会跨多格，所以两端都要登记 —— 否则跨格查询会漏。
func _index_segment(cells: Dictionary, a: Vector2, b: Vector2, margin: float, idx: int) -> void:
	var x0 := int(floor((minf(a.x, b.x) - margin) / BRIDGE_CELL))
	var x1 := int(floor((maxf(a.x, b.x) + margin) / BRIDGE_CELL))
	var z0 := int(floor((minf(a.y, b.y) - margin) / BRIDGE_CELL))
	var z1 := int(floor((maxf(a.y, b.y) + margin) / BRIDGE_CELL))
	for cx in range(x0, x1 + 1):
		for cz in range(z0, z1 + 1):
			var k := _cell_key(cx, cz)
			if cells.has(k):
				var arr: Array = cells[k]
				arr.append(idx)
			else:
				cells[k] = [idx]


func _touches_bridge_cells(a: Vector2, b: Vector2, margin: float) -> bool:
	var x0 := int(floor((minf(a.x, b.x) - margin) / BRIDGE_CELL))
	var x1 := int(floor((maxf(a.x, b.x) + margin) / BRIDGE_CELL))
	var z0 := int(floor((minf(a.y, b.y) - margin) / BRIDGE_CELL))
	var z1 := int(floor((maxf(a.y, b.y) + margin) / BRIDGE_CELL))
	for cx in range(x0, x1 + 1):
		for cz in range(z0, z1 + 1):
			if _bridge_cells.has(_cell_key(cx, cz)):
				return true
	return false


func load_crossings() -> void:
	var infra: Dictionary = CityData.coastal_infrastructure
	if infra.is_empty():
		infra = DataLoader.json_dict("/city/coastal/infrastructure.json")
	water_height = float(infra.get("waterHeight", -0.25))

	_bridge_segs.clear()
	_bridge_cells.clear()
	for c in infra.get("crossings", []):
		var pts: Array = c.get("points", [])
		if pts.size() < 2:
			continue
		var h := float(c.get("height", 2.8))
		var ramp := float(c.get("ramp", 70.0))
		var w := float(c.get("width", 6.0))
		# ⚠️ 逐段登记，不能只取 pts[0]/pts[1]：crossings 里 164 条里有不少是
		# 3~9 个点的折线（笋岗东立交 9 点 74m、人民公园路 5 点 61m），
		# 只认第一段的话，折线后半截完全没有桥面标高。
		for i in range(1, pts.size()):
			var a := Vector2(float(pts[i - 1][0]), float(pts[i - 1][1]))
			var b := Vector2(float(pts[i][0]), float(pts[i][1]))
			var idx := _bridge_segs.size()
			_bridge_segs.append({"a": a, "b": b, "width": w, "height": h, "ramp": ramp})
			_index_segment(_bridge_cells, a, b, ramp, idx)

	_build_gate_index()
	if not _bridge_segs.is_empty():
		loaded_layers.append("crossings(%d 段, 路面门 %d 段)"
			% [_bridge_segs.size(), _gate_segs.size()])


## 原版 `roads` 索引。判定用的格子与查询用的格子是同一套，不会漏段。
##
## ⚠️ 必须带 `grade >= 0` 过滤：原版是
##   `for(const r of data.roads) if(Number(r.grade) >= 0) ... add(roads, ...)`
## 本城 12202 条道路里有 **177 条负 grade**（grade=-1/-2/-3/-4，地下/下穿路段）。
## 它们不算"路面上"，所以不参与 onRoad 闸门 —— 否则桥底下穿的道路会把本该
## 只在桥面上的抬升漏给整片地面。
func _build_gate_index() -> void:
	_gate_segs.clear()
	_gate_cells.clear()
	if _bridge_segs.is_empty():
		return
	for road in CityData.roads:
		if str(road.get("grade", "0")).to_float() < 0.0:
			continue
		var margin := float(road["width"]) * 0.5 + BRIDGE_ROAD_SLACK
		var pts: PackedVector2Array = road["points"]
		for i in range(1, pts.size()):
			var a := pts[i - 1]
			var b := pts[i]
			if not _touches_bridge_cells(a, b, margin):
				continue
			var idx := _gate_segs.size()
			_gate_segs.append({"a": a, "b": b, "margin": margin})
			_index_segment(_gate_cells, a, b, margin, idx)


## 原版 bridgeRamp：t = clamp(d / ramp, 0, 1)，抬升 height * (1 - t²(3 - 2t))
static func bridge_ramp(distance: float, height: float, ramp: float) -> float:
	var t := clampf(distance / maxf(ramp, 0.001), 0.0, 1.0)
	return height * (1.0 - t * t * (3.0 - 2.0 * t))


## 原版 `bridgeHeight(x, z)`。
##
## ⚠️⚠️ 这里的 `d` 必须是**到桥段线段的最短距离**（原版 `closest(x,z,s.a,s.b).d`），
## 不是"到折线首点的距离"。桥面在 d≈0 处取满高 height(2.8m)，然后沿**横向**
## 在 ramp(70m) 内三次平滑衰减到 0。这条衰减带同时就是**引桥**：
## 车辆沿路驶近桥头时，到桥段的距离从 70m 连续递减到 0，路面高度随之从地面
## 平滑抬到桥面 —— 桥头不会出现 2.8m 的台阶。
##
## 旧实现把 `d` 传成了 `p.distance_to(a)`（到**首点 a** 的距离），又把门限写成
## `lateral <= width/2 + 6`，于是"桥面"变成以 a 为圆心、半径 70m、宽仅 9m 的
## 一个窄条：桥中段和整条引桥的标高都是 0。车开上桥 → 车身掉回地面 →
## 直接钻到桥面底下（用户反馈的"过桥穿模到桥下"）。
func bridge_lift(east: float, north: float) -> float:
	if _bridge_segs.is_empty():
		return 0.0
	var k := _cell_key(int(floor(east / BRIDGE_CELL)), int(floor(north / BRIDGE_CELL)))
	var cands = _bridge_cells.get(k)
	if cands == null:
		return 0.0
	var h := 0.0
	for i in cands:
		var s: Dictionary = _bridge_segs[i]
		var d := CityCollision.seg_distance(east, north, s["a"], s["b"])
		h = maxf(h, bridge_ramp(d, float(s["height"]), float(s["ramp"])))
	if h <= 0.0:
		return 0.0
	# 原版 onRoad 闸门：只有落在路面（距路中心线 ≤ width/2+8）上的点才抬。
	# 去掉这道门，桥两侧 70m 范围内的水面/绿地/人行道都会一起鼓起来。
	var rcands = _gate_cells.get(k)
	if rcands == null:
		return 0.0
	for i in rcands:
		var r: Dictionary = _gate_segs[i]
		if CityCollision.seg_distance(east, north, r["a"], r["b"]) <= float(r["margin"]):
			return h
	return 0.0


# ---------------------------------------------------------------------------
# 总入口
# ---------------------------------------------------------------------------

## 数据坐标下的地面高度。
##
## ⚠️ 桥梁是 **max** 不是加法：原版是
##   `heightAt: (x, z) => Math.max(base(x, z), bridgeHeight(x, z))`
## 桥面是**固定标高**（crossings 的 height，本城 2.8m），不是"在起伏地形上
## 再叠 2.8m"。旧实现写成 `base += bridge_lift(...)`，桥下水深为负 / 地形抬高
## 时车身高度会跟着漂，而且和 `roads.glb` 里已经烘好的桥面几何对不上。
func height_at(east: float, north: float) -> float:
	var base := 0.0
	base += lianhua_height(east, north)
	base += mountain_delta(east, north)
	base += relief_height(east, north)
	base = maxf(base, bridge_lift(east, north))
	if cafe_floor.is_valid():
		base = cafe_floor.call(east, north, base)
	return base


## 世界坐标（Godot）下的地面高度
func height_at_world(pos: Vector3) -> float:
	return height_at(pos.x, -pos.z)


func stats() -> Dictionary:
	return {
		"layers": loaded_layers,
		"reliefTriangles": _relief_tris.size(),
		"crossings": _bridge_segs.size(),
		"bridgeGateSegments": _gate_segs.size(),
		"waterHeight": water_height,
	}
