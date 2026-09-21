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

## 跨海桥梁
var _crossings: Array = []  ## {a: Vector2, b: Vector2, height, ramp, width}
var water_height := -0.25

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
# 4) 跨海桥梁引桥
# ---------------------------------------------------------------------------

func load_crossings() -> void:
	var infra: Dictionary = CityData.coastal_infrastructure
	if infra.is_empty():
		infra = DataLoader.json_dict("/city/coastal/infrastructure.json")
	water_height = float(infra.get("waterHeight", -0.25))
	_crossings.clear()
	for c in infra.get("crossings", []):
		var pts: Array = c.get("points", [])
		if pts.size() < 2:
			continue
		_crossings.append({
			"a": Vector2(float(pts[0][0]), float(pts[0][1])),
			"b": Vector2(float(pts[1][0]), float(pts[1][1])),
			"height": float(c.get("height", 2.8)),
			"ramp": float(c.get("ramp", 70.0)),
			"width": float(c.get("width", 6.0)),
		})
	if not _crossings.is_empty():
		loaded_layers.append("crossings(%d)" % _crossings.size())


## 原版 bridgeRamp：t = d / ramp，抬升 height * (1 - t²(3-2t))
func bridge_lift(east: float, north: float) -> float:
	if _crossings.is_empty():
		return 0.0
	var p := Vector2(east, north)
	var best := 0.0
	for c in _crossings:
		var a: Vector2 = c["a"]
		var b: Vector2 = c["b"]
		var ab := b - a
		var len2 := ab.length_squared()
		var t := 0.0
		if len2 > 0.0:
			t = clamp((p - a).dot(ab) / len2, 0.0, 1.0)
		var q := a + ab * t
		var along := p.distance_to(a)
		var lateral := p.distance_to(q)
		if lateral > c["width"] * 0.5 + 6.0:
			continue
		var ramp: float = c["ramp"]
		if along > ramp:
			continue
		# 用 maxf 而不是 max：max() 是无类型通用函数，返回 Variant，`:=` 推断不出来
		var u := along / maxf(ramp, 0.001)
		var lift: float = c["height"] * (1.0 - u * u * (3.0 - 2.0 * u))
		best = maxf(best, lift)
	return best


# ---------------------------------------------------------------------------
# 总入口
# ---------------------------------------------------------------------------

## 数据坐标下的地面高度
func height_at(east: float, north: float) -> float:
	var base := 0.0
	base += lianhua_height(east, north)
	base += mountain_delta(east, north)
	base += relief_height(east, north)
	base += bridge_lift(east, north)
	base += 0.0  # 咖啡馆地板在下面单独叠加
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
		"crossings": _crossings.size(),
		"waterHeight": water_height,
	}
