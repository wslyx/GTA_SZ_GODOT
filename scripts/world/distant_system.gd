extends Node3D
class_name DistantSystem
##
## 远景与地形补面 —— 对应原版 city-mountains.ts + city-ground-relief.ts
## + city-coastal-horizon.ts + city-distant-geometry.ts。
##
## 三个网格来源：
##   1. 远山 / 近山：mountain-relief/manifest.json 的 tiles 指定
##      "heights.bin / near-heights.bin 网格里的哪一块"，逐块生成高度场网格。
##      网格参数：far x0=−6804, z0=−2628, step=36, 379×324
##                near 同原点，step=12，1135×439
##      原版块三角形总量 far 127944 + near 53510 ≈ 18 万。
##   2. 公园缓坡：ground-relief/relief-mesh.bin，46 块，每块带
##      positions/normals/indices 的字节偏移与长度（float32 × 3 / uint32 索引）。
##   3. 海岸裙边：把 coastal-shoreline 的边界边向下封到 waterHeight − 1，
##      避免正射视角看到薄壳的背面空洞。
##
## **必须在后台线程生成**：如果按整格逐格建，近山会膨胀到 74 万三角形、
## 远山 14 万 —— 用 GDScript 的 SurfaceTool 逐顶点建，主线程会卡死一两分钟
## （用户实测"画面卡死无响应"）。所以这里：
##   - 近山用 NEAR_STRIDE 抽稀，把总量拉回原版预算量级；
##   - 全部网格在 Thread 里生成，主线程每帧检查完成后才挂到场景树。

const SKIRT_DROP_BELOW_WATER := 1.0
## 近山抽稀步长。实测：整格生成 741938 三角形（GDScript 建网格会卡死主线程），
## stride=3 → 5482、stride=2 → 约 1.2 万。近山是玩家能看到的主体，取 2 保细节，
## 代价仍然很小（后台线程生成，不占主线程）。
const NEAR_STRIDE := 2

var world: CityWorld
var terrain_preserved := Rect2()
var built := false

var mountain_nodes: Array = []
var relief_node: MeshInstance3D
var skirt_node: MeshInstance3D

# --- 后台构建 ---
var _thread: Thread
var _building := false
var _pending: Array = []   ## [{name, mesh, albedo, roughness, texture}]


func build_all(p_world: CityWorld) -> void:
	world = p_world
	_read_preserved_bounds()
	# 裙边很小、且依赖已加载的 shoreline 网格，留在主线程
	build_coastal_skirt()
	# 重活交给后台线程
	_pending.clear()
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
	for e in _pending:
		var node := MeshInstance3D.new()
		node.name = e["name"]
		node.mesh = e["mesh"]
		var mat := StandardMaterial3D.new()
		mat.albedo_color = e["albedo"]
		mat.roughness = e["roughness"]
		mat.metallic = 0.0
		if e["texture"] != "" and ResourceLoader.exists(e["texture"]):
			mat.albedo_texture = load(e["texture"])
			mat.uv1_scale = Vector3(600.0, 600.0, 600.0)
		node.material_override = mat
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.extra_cull_margin = 1.0e7
		add_child(node)
		if str(e["name"]).begins_with("mountain-"):
			mountain_nodes.append(node)
		else:
			relief_node = node
	_pending.clear()
	built = true
	var mounted := mountain_nodes.size() + (1 if relief_node != null else 0)
	print("[DistantSystem] 远景网格后台构建完成并挂载：%d 项" % mounted)


# ---------------------------------------------------------------------------
# 后台线程：生成全部网格（不碰场景树）
# ---------------------------------------------------------------------------

func _build_worker() -> void:
	var out: Array = []
	out.append_array(_build_mountain_layer(
		"/city/mountain-relief/manifest.json", "heights.bin", true, 1,
		Color(0.11, 0.16, 0.14), "mountain-far"))
	out.append_array(_build_mountain_layer(
		"/city/mountain-relief/near-manifest.json", "near-heights.bin", false, NEAR_STRIDE,
		Color(0.16, 0.22, 0.17), "mountain-near"))
	var relief := _build_relief_mesh()
	if relief != null:
		out.append({"name": "ground-relief", "mesh": relief,
			"albedo": Color(0.92, 0.99, 0.88), "roughness": 0.96,
			"texture": "res://data/city/ground-relief/ground-cover.png"})
	_pending = out


func _read_preserved_bounds() -> void:
	var mm: Dictionary = DataLoader.json_dict("/city/mountain-relief/manifest.json")
	var b: Array = mm.get("preservedTerrainBounds", [])
	if b.size() >= 4:
		terrain_preserved = Rect2(b[0], b[1], b[2] - b[0], b[3] - b[1])


## 山地角点的坡度法线 + 逐顶点色（原版 city-mountains.ts attachVisuals 逐字）：
##   法线 = 高程网格中心差分坡度（数据 z=北，世界 z 取反）；
##   颜色 = 双尺度树冠簇噪声 × 细噪声 × 高地压暗 + 陡坡暖灰岩石。
## 以前整层只给 UP 法线 + 平色橄榄 —— 山坡像一层"反着看的壳"，即用户报告的
## "山坡可见面反了"（修复记录 五十五）。
static func _mountain_corner(heights: PackedFloat32Array, cols: int, rows: int,
		x0: float, z0: float, step: float, gc: int, gr: int) -> Array:
	var sx := float(heights[gr * cols + mini(gc + 1, cols - 1)]
		- heights[gr * cols + maxi(gc - 1, 0)]) / (2.0 * step)
	var sz := float(heights[mini(gr + 1, rows - 1) * cols + gc]
		- heights[maxi(gr - 1, 0) * cols + gc]) / (2.0 * step)
	var ln := sqrt(sx * sx + 1.0 + sz * sz)
	# 噪声用数据坐标（原版 wx/wz），与 world z 无关
	var wx := x0 + gc * step
	var wz := z0 + gr * step
	var clumps := (sin(wx / 91.0 + wz / 137.0) * cos(wz / 83.0 - wx / 211.0)) * 0.5 + 0.5
	var fine := 0.93 + 0.07 * sin(wx / 37.0 + 1.3) * cos(wz / 41.0)
	var hh := float(heights[gr * cols + gc])
	var highland := clampf((hh - 30.0) / 200.0, 0.0, 1.0)
	var stone := minf(0.45, maxf(0.0, sqrt(sx * sx + sz * sz) - 0.40) * 0.75)
	var shade := (0.78 + 0.22 * clumps) * fine * (1.0 - 0.20 * highland)
	# 世界 z=-北：法线 z 分量跟着翻
	var n := Vector3(-sx / ln, 1.0 / ln, sz / ln)
	var c := Color(shade * (1.0 + stone * 0.60), shade * (1.0 - stone * 0.22),
		shade * (1.0 + stone * 0.48), 1.0)
	return [n, c]


static func _add_vc_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		na: Array, nb: Array, nc: Array) -> void:
	var pts: Array = [a, b, c]
	var nrm: Array = [na, nb, nc]
	for k in 3:
		st.set_normal(nrm[k][0])
		st.set_color(nrm[k][1])
		st.add_vertex(pts[k])


## 生成一层山体网格。stride 用于近层抽稀（1 = 全精度）。
func _build_mountain_layer(manifest_path: String, bin_name: String, far_layer: bool,
		stride: int, col: Color, node_name: String) -> Array:
	var man: Dictionary = DataLoader.json_dict(manifest_path)
	if man.is_empty():
		return []
	var grid: Dictionary = man.get("grid", {})
	if grid.is_empty():
		return []
	var x0 := float(grid["x0"])
	var z0 := float(grid["z0"])
	var step := float(grid["step"])
	var cols := int(grid["columns"])
	var rows := int(grid["rows"])
	var raw := DataLoader.bytes("/city/mountain-relief/" + str(man.get("file", bin_name)))
	if raw.size() < cols * rows * 4:
		return []
	# 一次性转成 float32 数组，比逐个 decode_float 快一个数量级
	var heights := raw.to_float32_array()
	var offset := float(man.get("surfaceOffset", 0.04))
	# 注意：不能写 `var stride := maxi(1, stride)` —— 与形参同名会被判重复声明
	var stride_step := maxi(1, stride)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tris := 0
	for tile in man.get("tiles", []):
		var tc := int(tile["column"])
		var tr := int(tile["row"])
		var tcols := int(tile["columns"])
		var trows := int(tile["rows"])
		var r := tr
		while r < mini(tr + trows, rows - 1):
			var c := tc
			while c < mini(tc + tcols, cols - 1):
				var ex0 := x0 + c * step
				var ex1 := x0 + (c + stride_step) * step
				var nz0 := z0 + r * step
				var nz1 := z0 + (r + stride_step) * step
				var ci := mini(c + stride_step, cols - 1)
				var ri := mini(r + stride_step, rows - 1)
				var h00 := heights[r * cols + c] + offset
				var h10 := heights[r * cols + ci] + offset
				var h01 := heights[ri * cols + c] + offset
				var h11 := heights[ri * cols + ci] + offset
				# 数据 (east, north) → 世界 (x=east, z=-north)
				var v00 := Vector3(ex0, h00, -nz0)
				var v10 := Vector3(ex1, h10, -nz0)
				var v11 := Vector3(ex1, h11, -nz1)
				var v01 := Vector3(ex0, h01, -nz1)
				# 角点法线 + 逐顶点色（原版 city-mountains.ts：树冠簇/高地/岩石）
				var k00 := _mountain_corner(heights, cols, rows, x0, z0, step, c, r)
				var k10 := _mountain_corner(heights, cols, rows, x0, z0, step, ci, r)
				var k11 := _mountain_corner(heights, cols, rows, x0, z0, step, ci, ri)
				var k01 := _mountain_corner(heights, cols, rows, x0, z0, step, c, ri)
				_add_vc_tri(st, v00, v10, v11, k00, k10, k11)
				_add_vc_tri(st, v00, v11, v01, k00, k11, k01)
				tris += 2
				c += stride_step
			r += stride_step
	var mesh := st.commit()
	print("[DistantSystem] %s：%d 三角形（stride=%d）" % [node_name, tris, stride_step])
	return [{"name": node_name, "mesh": mesh, "albedo": col, "roughness": 0.95, "texture": ""}]


static func _add_up_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.set_normal(Vector3.UP)
	st.add_vertex(a)
	st.set_normal(Vector3.UP)
	st.add_vertex(b)
	st.set_normal(Vector3.UP)
	st.add_vertex(c)


# ---------------------------------------------------------------------------
# 2) 公园缓坡（后台线程）
# ---------------------------------------------------------------------------

func _build_relief_mesh() -> Mesh:
	var man: Dictionary = DataLoader.json_dict("/city/ground-relief/manifest.json")
	if man.is_empty():
		return null
	var raw := DataLoader.bytes("/city/ground-relief/" + str(man.get("mesh", "relief-mesh.bin")))
	if raw.is_empty():
		return null
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tri_total := 0
	for tile in man.get("tiles", []):
		var vc := int(tile["vertexCount"])
		var po := int(tile["positions"]["offset"])
		var no := int(tile["normals"]["offset"])
		var io := int(tile["indices"]["offset"])
		var icount := int(tile["indices"]["bytes"]) / 4
		var pos_f := raw.slice(po, po + vc * 12).to_float32_array()
		var nrm_f := raw.slice(no, no + vc * 12).to_float32_array()
		var verts := PackedVector3Array()
		verts.resize(vc)
		var norms := PackedVector3Array()
		norms.resize(vc)
		# ---- 坐标换轴（2026-11-03，修复记录 五十四）----
		# 二进制 positions 是**数据坐标**（z=北）：原版 TS 把它直接喂 Babylon
		# 场景（原版数据系=世界系），baseHeightAt(x,z) 也按 (east,north) 采样。
		# Godot 世界 z=-北，必须在这里翻 z，否则土坡南北镜像。
		# 而镜像本身会翻转绕序手性 —— Godot 正面=CCW，镜像后原绕序的"正面"
		# 变成背面，双面着色下就是用户看到的"小土坡单面可见、可见的面反了"
		# （背面法线被 ground_field 翻转，坡面明暗/受光全部颠倒）。
		# 所以三件套一起改：位置 z 取反 + 法线 z 取反 + 索引倒序。
		# 物理侧 height_field.load_relief() 把 z 当北用（数据系采样），本来就
		# 是对的，不要跟着改。
		for i in vc:
			verts[i] = Vector3(pos_f[i * 3], pos_f[i * 3 + 1], -pos_f[i * 3 + 2])
			norms[i] = Vector3(nrm_f[i * 3], nrm_f[i * 3 + 1], -nrm_f[i * 3 + 2])
		var t := 0
		while t + 2 < icount:
			var i0 := raw.decode_u32(io + t * 4)
			var i1 := raw.decode_u32(io + (t + 1) * 4)
			var i2 := raw.decode_u32(io + (t + 2) * 4)
			if i0 < vc and i1 < vc and i2 < vc:
				for k in [i2, i1, i0]:
					st.set_normal(norms[k])
					st.add_vertex(verts[k])
				tri_total += 1
			t += 3
	if tri_total == 0:
		return null
	print("[DistantSystem] 公园缓坡 %d 面" % tri_total)
	return st.commit()


# ---------------------------------------------------------------------------
# 3) 海岸裙边（主线程，代价小）
# ---------------------------------------------------------------------------

## 找出 shoreline 网格的边界边（只被一个三角形使用的边），沿边向下拉出裙面。
func build_coastal_skirt() -> void:
	if world == null:
		return
	var target: MeshInstance3D = null
	for mi in GlbLoader.meshes_of(world.landmarks_root):
		if mi.name.to_lower().contains("shoreline"):
			target = mi
			break
	if target == null or target.mesh == null:
		return
	var bottom := float(world.height_field.water_height) - SKIRT_DROP_BELOW_WATER
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var made := 0
	for s in target.mesh.get_surface_count():
		var arrays := target.mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx = arrays[Mesh.ARRAY_INDEX]
		if idx == null:
			continue
		var edge_count := {}
		var i := 0
		while i + 2 < idx.size():
			var tri := [int(idx[i]), int(idx[i + 1]), int(idx[i + 2])]
			for e in 3:
				var a: int = tri[e]
				var b: int = tri[(e + 1) % 3]
				var key := "%d,%d" % [mini(a, b), maxi(a, b)]
				edge_count[key] = int(edge_count.get(key, 0)) + 1
			i += 3
		for key in edge_count:
			if int(edge_count[key]) != 1:
				continue
			var key_str: String = key
			var parts := key_str.split(",")
			var va: Vector3 = verts[int(parts[0])]
			var vb: Vector3 = verts[int(parts[1])]
			if va.y <= bottom and vb.y <= bottom:
				continue
			var a_down := Vector3(va.x, bottom, va.z)
			var b_down := Vector3(vb.x, bottom, vb.z)
			_add_up_tri(st, va, vb, b_down)
			_add_up_tri(st, va, b_down, a_down)
			made += 2
	if made == 0:
		return
	skirt_node = MeshInstance3D.new()
	skirt_node.name = "coastal-horizon"
	skirt_node.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.30, 0.33, 0.28)
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	skirt_node.material_override = mat
	skirt_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(skirt_node)
	print("[DistantSystem] 海岸裙边 %d 面" % made)


# ---------------------------------------------------------------------------
# 道路贴合地形（原版 mountains.drapePaths）
# ---------------------------------------------------------------------------

func drape_roads(roads_root: Node3D) -> void:
	if world == null or roads_root == null or terrain_preserved.size == Vector2.ZERO:
		return
	var draped := 0
	for mi in GlbLoader.meshes_of(roads_root):
		var src: Mesh = mi.mesh
		if src == null:
			continue
		var rebuilt := ArrayMesh.new()
		var changed := false
		for s in src.get_surface_count():
			var arrays := src.surface_get_arrays(s)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for i in verts.size():
				var p := verts[i]
				var east := p.x
				var north := -p.z
				if not terrain_preserved.has_point(Vector2(east, north)):
					continue
				var h := world.ground_height_data(east, north)
				if h > p.y:
					verts[i] = Vector3(p.x, h + 0.10, p.z)
					changed = true
					draped += 1
			arrays[Mesh.ARRAY_VERTEX] = verts
			rebuilt.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			var m: Material = src.surface_get_material(s)
			if m != null:
				rebuilt.surface_set_material(s, m)
		if changed:
			mi.mesh = rebuilt
	if draped > 0:
		print("[DistantSystem] 道路贴合地形：移动顶点 %d 个" % draped)


func diagnostics() -> Dictionary:
	return {
		"built": built,
		"building": _building,
		"mountains": mountain_nodes.size(),
		"relief": relief_node != null,
		"skirt": skirt_node != null,
		"preservedBounds": [terrain_preserved.position.x, terrain_preserved.position.y,
			terrain_preserved.end.x, terrain_preserved.end.y],
	}
