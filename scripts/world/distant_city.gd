extends Node3D
class_name DistantCity
##
## 远景城市壳 —— 对应原版 city-distant-city.ts + city-distant-geometry.ts
## 的远景几何层级（未完成项清单 A1）。
##
## 原版做什么：用 buildDistantCityGeometry() 给每栋**已存在**的建筑生成一个
## "墙壳 + 平顶"的极简代理（无底面、无道具、无碰撞），按 640m 分块；高空
## （aerial）模式下，距焦点 ≥ CITY_BUILDING_DETAIL_RADIUS(3300) 的块启用、
## 其余隐藏，与近处真楼互补 —— 不重叠、也不留"空距环"；地面驾驶时整层禁用。
## 远景窗格夜间点亮由 distant_city.gdshader（原版 DistantWindows 插件）负责。
##
## 实现要点：
##   · 16076 栋建筑的耳切三角化 + 打包在**后台线程**做（同 distant_system 的
##     教训：GDScript 逐顶点建网格放主线程会卡死）；
##   · 顶点色 RGB = 稳定立面色调（按种子从调色板取色，封顶 0.70），
##     **A 通道 = 建筑种子 0..1，不是透明度**（着色器拿它做窗格哈希）；
##   · 数据 (east, north) → 世界 (x=east, z=-north)，见 coordinate_util.gd；
##   · 网格用 cull_disabled：绕序随 z 镜像翻转，远景壳不值得为此较真；
##   · 显隐判定用**相机**的数据坐标（原版 update 传的是场景焦点），
##     每 0.25s 一次，与 city_world 的分块剔除同节拍。

const CITY_SHADER := preload("res://shaders/distant_city.gdshader")

## 原版 CITY_BUILDING_DETAIL_RADIUS
const DETAIL_RADIUS := 3300.0
## 与 facade-tiles / buildings.glb 同款 640m 分块
const TILE_SIZE := 640.0
const EPSILON := 1e-7
## 显隐重算节拍（与 city_world._cull_timer 一致）
const UPDATE_INTERVAL := 0.25

## 原版 palettes：深圳常见类型学的远景墙面色调
const PALETTES := {
	"office": [
		Color(0.49, 0.57, 0.64), Color(0.43, 0.55, 0.59),
		Color(0.64, 0.64, 0.61), Color(0.59, 0.55, 0.51),
	],
	"residential": [
		Color(0.67, 0.63, 0.55), Color(0.56, 0.61, 0.60),
		Color(0.65, 0.57, 0.51), Color(0.60, 0.63, 0.62),
	],
}
const STONE_PALETTE := [
	Color(0.63, 0.60, 0.54), Color(0.52, 0.57, 0.63), Color(0.64, 0.53, 0.48),
]

var world: CityWorld
var built := false

## [{node: MeshInstance3D, cx: float, cz: float}] —— cx/cz 是 640m 块中心（数据坐标）
var _tiles: Array = []
var _material: ShaderMaterial

# --- 后台构建（模式照搬 distant_system）---
var _thread: Thread
var _building := false
var _pending: Array = []   ## [{name, mesh, cx, cz}]
## 构建期统计（挂载时打印）
var _stat := {"buildings": 0, "skipped": 0, "skippedRoofs": 0, "triangles": 0}


func build_all(p_world: CityWorld) -> void:
	world = p_world
	_material = ShaderMaterial.new()
	_material.shader = CITY_SHADER
	# 初值取当前光照档（apply_mode 可能早于本系统挂载就发生过了）
	if world.lighting != null:
		set_mode(world.lighting.mode)
	_building = true
	_thread = Thread.new()
	_thread.start(_build_worker)
	set_process(true)


func _process(_delta: float) -> void:
	if not _building:
		set_process(false)
		return
	if _thread.is_alive():
		return
	_thread.wait_to_finish()
	_building = false
	var t0 := Time.get_ticks_msec()
	for e in _pending:
		var node := MeshInstance3D.new()
		node.name = e["name"]
		node.mesh = e["mesh"]
		node.material_override = _material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.visible = false   # 地面驾驶默认整层禁用（原版 setEnabled(false)）
		add_child(node)
		_tiles.append({"node": node, "cx": e["cx"], "cz": e["cz"]})
	_pending.clear()
	built = true
	print("[DistantCity] 远景城市壳 %d 块 / 建筑 %d（跳过 %d，屋顶失败 %d），三角形 %d，挂载 %d ms"
		% [_tiles.size(), int(_stat["buildings"]), int(_stat["skipped"]),
		int(_stat["skippedRoofs"]), int(_stat["triangles"]), Time.get_ticks_msec() - t0])


func update_system(delta: float, _focus: Vector3) -> void:
	if not built or _tiles.is_empty():
		return
	_timer -= delta
	if _timer > 0.0 and _last_aerial == world.aerial:
		return
	_timer = UPDATE_INTERVAL
	_last_aerial = world.aerial
	# 原版 update(x, z, aerial) 传场景焦点 —— 这里跟相机（观景/飞行时相机
	# 会离玩家很远，用玩家坐标会留出错误的空距环）
	var cam := get_viewport().get_camera_3d()
	var f := Vector2.ZERO
	if cam != null:
		f = Vector2(cam.global_position.x, -cam.global_position.z)
	elif world != null:
		f = Vector2(world.focus.x, -world.focus.z)
	var aerial: bool = world.aerial
	for t in _tiles:
		var node: MeshInstance3D = t["node"]
		var d := Vector2(float(t["cx"]), float(t["cz"])).distance_to(f)
		# 高空才启用；近处的块由真楼负责（互补，不重叠）
		var should_show: bool = aerial and d >= DETAIL_RADIUS
		if node.visible != should_show:
			node.visible = should_show


## 原版 setMode：夜 2.4 / 黄昏 .85 / 白天 0（DistantWindows 的 night.gain）
func set_mode(mode: int) -> void:
	var gain := 0.85
	if mode == GameContent.LightMode.NIGHT:
		gain = 2.4
	elif mode == GameContent.LightMode.DAY:
		gain = 0.0
	_gain = gain
	if _material != null:
		_material.set_shader_parameter("night_gain", gain)


var _timer := 0.0
var _last_aerial := false
var _gain := 0.85


# ---------------------------------------------------------------------------
# 后台线程：几何生成（不碰场景树）
# ---------------------------------------------------------------------------

func _build_worker() -> void:
	var t0 := Time.get_ticks_msec()
	# key("ix_iz") -> {pos, nrm, col, idx}
	var tiles := {}
	for b in CityData.buildings:
		var style: String = b["style"]
		if style == "landmark-detail":
			continue   # 原版：地标替换行不进远景壳
		var height: float = b["height"]
		var rings: Array = b["rings"]
		if not is_finite(height) or height <= 0.0 or rings.is_empty():
			_stat["skipped"] = int(_stat["skipped"]) + 1
			continue
		var source: PackedVector2Array = rings[0]
		if source.size() < 3:
			_stat["skipped"] = int(_stat["skipped"]) + 1
			continue
		var ring := _dedup_ring(source)
		if ring.size() < 3 or absf(_ring_area(ring)) <= EPSILON or _self_intersects(ring):
			_stat["skipped"] = int(_stat["skipped"]) + 1
			continue
		var area := _ring_area(ring)
		if area < 0.0:
			ring.reverse()
		# 质心（原版照搬 build_city_facades.py 的顶点平均，不含重复收尾点）
		var cx := 0.0
		var cz := 0.0
		for p in ring:
			cx += p.x
			cz += p.y
		cx /= ring.size()
		cz /= ring.size()
		var ix := floori(cx / TILE_SIZE)
		var iz := floori(cz / TILE_SIZE)
		var key := "%d_%d" % [ix, iz]
		var tile: Dictionary = tiles.get(key, {})
		if tile.is_empty():
			tile = {"pos": PackedVector3Array(), "nrm": PackedVector3Array(),
				"col": PackedColorArray(), "idx": PackedInt32Array()}
			tiles[key] = tile
		_emit_building(tile, ring, height, b, _stat)
	var out: Array = []
	var tri := 0
	for key in tiles:
		var tile: Dictionary = tiles[key]
		var idx: PackedInt32Array = tile["idx"]
		if idx.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = tile["pos"]
		arrays[Mesh.ARRAY_NORMAL] = tile["nrm"]
		arrays[Mesh.ARRAY_COLOR] = tile["col"]
		arrays[Mesh.ARRAY_INDEX] = idx
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		tri += idx.size() / 3
		# ⚠️ key 来自字典遍历是 Variant，:= 推断会失败（本项目已踩过的坑）
		var parts: PackedStringArray = str(key).split("_")
		out.append({
			"name": "distant-block-%s" % key,
			"mesh": mesh,
			# 块中心（数据坐标），与原版 (ix+.5)*TILE_SIZE 一致
			"cx": (float(parts[0]) + 0.5) * TILE_SIZE,
			"cz": (float(parts[1]) + 0.5) * TILE_SIZE,
		})
	_stat["triangles"] = tri
	_pending = out
	print("[DistantCity] 几何后台构建 %d ms：%d 块 / %d 三角形"
		% [Time.get_ticks_msec() - t0, out.size(), tri])


## 一栋楼的墙壳 + 平顶（逐行对应 buildDistantCityGeometry 的循环体）
func _emit_building(tile: Dictionary, ring: PackedVector2Array, height: float,
		b: Dictionary, stat: Dictionary) -> void:
	var seed_v: int = b["seed"]
	var palette: Array = PALETTES.get(str(b["style"]), STONE_PALETTE)
	var base: Color = palette[seed_v % palette.size()]
	var gain := 0.94 + float((seed_v >> 8) & 255) / 255.0 * 0.12
	var wall_col := Color(
		minf(base.r * gain, 0.70), minf(base.g * gain, 0.70), minf(base.b * gain, 0.70),
		float(seed_v & 65535) / 65535.0)
	var pos: PackedVector3Array = tile["pos"]
	var nrm: PackedVector3Array = tile["nrm"]
	var col: PackedColorArray = tile["col"]
	var idx: PackedInt32Array = tile["idx"]
	var n := ring.size()
	for i in n:
		var a: Vector2 = ring[i]
		var b2: Vector2 = ring[(i + 1) % n]
		var dx := b2.x - a.x
		var dz := b2.y - a.y
		var dist := sqrt(dx * dx + dz * dz)
		if dist <= EPSILON:
			continue
		# 数据法线 (dz/d, 0, -dx/d) → 世界 (dz/d, 0, dx/d)
		var wn := Vector3(dz / dist, 0.0, dx / dist)
		var offset := pos.size()
		pos.append(Vector3(a.x, 0.0, -a.y))
		pos.append(Vector3(b2.x, 0.0, -b2.y))
		pos.append(Vector3(b2.x, height, -b2.y))
		pos.append(Vector3(a.x, height, -a.y))
		for j in 4:
			nrm.append(wn)
			col.append(wall_col)
		idx.append(offset)
		idx.append(offset + 1)
		idx.append(offset + 2)
		idx.append(offset)
		idx.append(offset + 2)
		idx.append(offset + 3)
	var roof := _triangulate(ring)
	if roof.is_empty():
		stat["skippedRoofs"] = int(stat["skippedRoofs"]) + 1
	else:
		var roof_col := Color(wall_col.r * 0.78, wall_col.g * 0.78, wall_col.b * 0.78, wall_col.a)
		var offset := pos.size()
		for p in ring:
			pos.append(Vector3(p.x, height, -p.y))
			nrm.append(Vector3.UP)
			col.append(roof_col)
		for k in roof:
			idx.append(offset + int(k))
	stat["buildings"] = int(stat["buildings"]) + 1


# ---------------------------------------------------------------------------
# 几何工具（逐行对应 city-distant-geometry.ts）
# ---------------------------------------------------------------------------

static func _cross(a: Vector2, b: Vector2, c: Vector2) -> float:
	return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)


static func _same(a: Vector2, b: Vector2) -> bool:
	return absf(a.x - b.x) < EPSILON and absf(a.y - b.y) < EPSILON


## 去掉收尾重复点 + 相邻重复点（原版 while 循环两段）
static func _dedup_ring(source: PackedVector2Array) -> PackedVector2Array:
	var length := source.size()
	while length > 1 and _same(source[0], source[length - 1]):
		length -= 1
	var ring := PackedVector2Array()
	for i in length:
		if ring.is_empty() or not _same(ring[ring.size() - 1], source[i]):
			ring.append(source[i])
	return ring


static func _ring_area(ring: PackedVector2Array) -> float:
	var area := 0.0
	var origin := ring[0]
	for i in range(1, ring.size() - 1):
		area += _cross(origin, ring[i], ring[i + 1])
	return area * 0.5


static func _on_segment(a: Vector2, b: Vector2, p: Vector2) -> bool:
	return absf(_cross(a, b, p)) <= EPSILON \
		and p.x >= minf(a.x, b.x) - EPSILON and p.x <= maxf(a.x, b.x) + EPSILON \
		and p.y >= minf(a.y, b.y) - EPSILON and p.y <= maxf(a.y, b.y) + EPSILON


static func _self_intersects(ring: PackedVector2Array) -> bool:
	var n := ring.size()
	for i in n:
		for j in range(i + 2, n):
			if i == 0 and j == n - 1:
				continue
			var a := ring[i]
			var b := ring[(i + 1) % n]
			var c := ring[j]
			var d := ring[(j + 1) % n]
			if maxf(a.x, b.x) < minf(c.x, d.x) or maxf(c.x, d.x) < minf(a.x, b.x) \
					or maxf(a.y, b.y) < minf(c.y, d.y) or maxf(c.y, d.y) < minf(a.y, b.y):
				continue
			var ab_c := _cross(a, b, c)
			var ab_d := _cross(a, b, d)
			var cd_a := _cross(c, d, a)
			var cd_b := _cross(c, d, b)
			if ((ab_c > EPSILON and ab_d < -EPSILON) or (ab_c < -EPSILON and ab_d > EPSILON)) \
					and ((cd_a > EPSILON and cd_b < -EPSILON) or (cd_a < -EPSILON and cd_b > EPSILON)):
				return true
			if _on_segment(a, b, c) or _on_segment(a, b, d) or _on_segment(c, d, a) or _on_segment(c, d, b):
				return true
	return false


## 耳切三角化。失败返回空数组 —— 原版"失败绝不退化成扇形三角化"。
static func _triangulate(ring: PackedVector2Array) -> PackedInt32Array:
	var remaining := PackedInt32Array()
	remaining.resize(ring.size())
	for i in ring.size():
		remaining[i] = i
	var triangles := PackedInt32Array()
	# 共线墙顶点留在墙网格里，但不需要屋顶三角形
	var changed := true
	while changed and remaining.size() > 3:
		changed = false
		var i := 0
		while i < remaining.size() and remaining.size() > 3:
			var ia: int = remaining[(i + remaining.size() - 1) % remaining.size()]
			var ib: int = remaining[i]
			var ic: int = remaining[(i + 1) % remaining.size()]
			if absf(_cross(ring[ia], ring[ib], ring[ic])) <= EPSILON:
				remaining.remove_at(i)
				changed = true
				# 不 i++（与原版 i-- 后 continue 等价）
			else:
				i += 1
	while remaining.size() > 3:
		var clipped := false
		for i in remaining.size():
			var ia: int = remaining[(i + remaining.size() - 1) % remaining.size()]
			var ib: int = remaining[i]
			var ic: int = remaining[(i + 1) % remaining.size()]
			var a := ring[ia]
			var b := ring[ib]
			var c := ring[ic]
			if _cross(a, b, c) <= EPSILON:
				continue
			var occupied := false
			for index in remaining:
				if index == ia or index == ib or index == ic:
					continue
				var p := ring[index]
				if _cross(a, b, p) >= -EPSILON and _cross(b, c, p) >= -EPSILON and _cross(c, a, p) >= -EPSILON:
					occupied = true
					break
			if occupied:
				continue
			triangles.append(ia)
			triangles.append(ib)
			triangles.append(ic)
			remaining.remove_at(i)
			clipped = true
			break
		if not clipped:
			return PackedInt32Array()
	if remaining.size() != 3 or _cross(ring[remaining[0]], ring[remaining[1]], ring[remaining[2]]) <= EPSILON:
		return PackedInt32Array()
	triangles.append(remaining[0])
	triangles.append(remaining[1])
	triangles.append(remaining[2])
	# 面积校验：切出来的三角形总面积必须等于环面积
	var area := 0.0
	for i in range(0, triangles.size(), 3):
		area += _cross(ring[triangles[i]], ring[triangles[i + 1]], ring[triangles[i + 2]]) * 0.5
	if absf(area - _ring_area(ring)) > maxf(EPSILON, absf(area) * 1e-7):
		return PackedInt32Array()
	return triangles


func diagnostics() -> Dictionary:
	return {
		"built": built,
		"building": _building,
		"tiles": _tiles.size(),
		"detailRadius": DETAIL_RADIUS,
		"gain": _gain,
	}
