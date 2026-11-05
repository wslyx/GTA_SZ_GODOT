extends Node3D
##
## 深圳湾水体 —— 移植原版 city-world.ts 的水面装配 + city-bay-water.ts 的材质。
##
## 原版做两件事：
##   1. 把 `terrain.glb` 里名为 terrain_water 的网格顶点**统一抬到世界高度 −0.25**，
##      让地形自带的水面成为一张平的镜面（positionsOnWorldWaterPlane）。
##   2. 另建 `bay-horizon-water` 环形平面，外扩到 ±50000，补上地形之外的"远海"。
##
## Godot 里第 1 步同样可行：直接改写 Mesh 的顶点数组（需要 Mesh 可写，
## 即不能用共享的导入资源 —— 所以这里先 duplicate() 再改）。

const HORIZON_INNER := 7000.0
const HORIZON_OUTER := 50000.0
const HORIZON_Y := -0.25

## 水面网格专用层位（planar_mirror 的镜像相机剔除该位，防自反射）
const WATER_LAYER_VALUE := 1 << 20

## 平面镜（B1，2026-10-21）。⚠️ 新脚本的 class_name 不在全局类缓存，
## 必须 preload（项目已知坑 #1）
const PLANAR_MIRROR_SCRIPT := preload("res://scripts/world/planar_mirror.gd")

var world: CityWorld
var water_height := -0.25
var horizon_mesh: MeshInstance3D
var shader_material: ShaderMaterial
var raised_vertices := 0
var _built := false
var planar_mirror = null

## ---- 水面查询表（2026-11-05 落水判定用）----
## 体检 s07/s08：车开进深圳湾直接悬浮在水面上行驶 —— 水面纯视觉、无碰撞。
## 高度场在水面上返回 0.0（原生层全 0），与岸边陆地 0.04m 只差 4cm，没法用
## 高度判水。这里把 terrain_water/terrain_sea 网格的三角形收进 64m 格桶，
## is_water() 做 XZ 点包含测试 —— 与水面网格严格同源，不会误判陆地。
const WCELL := 64.0
var _water_tris := PackedFloat32Array()   ## 6 floats/tri（数据坐标 e1,n1,e2,n2,e3,n3）
var _water_bins: Dictionary = {}          ## Vector2i → PackedInt32Array


func setup(p_world: CityWorld) -> void:
	world = p_world
	water_height = float(world.height_field.water_height)
	# ⚠️ 顺序敏感：先建材质再抬水面 —— _raise_terrain_water 要用 shader_material
	# 接管水面网格。旧顺序（先 raise 后建材质）+ any_change 短路导致
	# 水面 shader/平面镜从未生效（修复记录 二十八）。
	_make_water_material()
	_raise_terrain_water()
	_create_horizon()
	_setup_mirror()
	_build_water_lookup()
	_built = true


## 把 terrain.glb 里的水面顶点抬到统一高度
##
## 逐 surface 取 arrays，只改水面 surface 的 VERTEX.y，然后把**全部 surface** 重建成
## 一个新 ArrayMesh（不能只替换被改的那一个，否则会丢掉其它 surface）。
func _raise_terrain_water() -> void:
	if world == null or world.terrain_root == null:
		return
	var target_y := water_height
	for mi in GlbLoader.meshes_of(world.terrain_root):
		var lname := mi.name.to_lower()
		if not ("water" in lname or "sea" in lname):
			continue
		var src: Mesh = mi.mesh
		if src == null or src.get_surface_count() == 0:
			continue

		var rebuilt := ArrayMesh.new()
		var any_change := false
		for s in src.get_surface_count():
			var arrays := src.surface_get_arrays(s)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var changed := false
			for i in verts.size():
				if verts[i].y < target_y:
					verts[i].y = target_y
					changed = true
					raised_vertices += 1
			if changed:
				arrays[Mesh.ARRAY_VERTEX] = verts
				any_change = true
			var flags := 0
			rebuilt.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
			# 逐 surface 继承原材质
			var mat: Material = src.surface_get_material(s)
			if mat != null:
				rebuilt.surface_set_material(s, mat)

		# ⚠️ 无论顶点是否改动都要接管：数据侧水面可能已夷平（any_change=false），
		# 但它仍是水面 —— 旧代码在此 continue，导致水面 shader 从未生效
		# （修复记录 二十八：近岸 turquoise 平涂的根因）。
		if any_change:
			mi.mesh = rebuilt
		mi.layers = WATER_LAYER_VALUE
		if shader_material != null:
			mi.material_override = shader_material
	if raised_vertices > 0:
		print("[BayWater] 抬升地形水面顶点 %d 个到 y=%.2f" % [raised_vertices, water_height])


func _make_water_material() -> ShaderMaterial:
	# 幂等：地形水面与远海环必须共用同一份 ShaderMaterial（镜面参数只 set 一份）
	if shader_material != null:
		return shader_material
	shader_material = ShaderMaterial.new()
	if ResourceLoader.exists("res://shaders/water.gdshader"):
		shader_material.shader = load("res://shaders/water.gdshader")
	else:
		push_warning("[BayWater] 缺少水面色者器")
	var shore_path := "res://data/city/coastal/shore-distance.png"
	if ResourceLoader.exists(shore_path):
		shader_material.set_shader_parameter("shore_distance", load(shore_path))
	var infra: Dictionary = CityData.coastal_infrastructure
	var extent: Array = infra.get("shoreDistance", {}).get("extent", [-10000.0, -13000.0, 10000.0, 3000.0])
	shader_material.set_shader_parameter("shore_extent", Vector4(extent[0], extent[1], extent[2], extent[3]))
	shader_material.set_shader_parameter("shore_max_distance",
		float(infra.get("shoreDistance", {}).get("maxDistance", 120.0)))
	return shader_material


## 远海：内方 7000、外方 50000 的环形平面
func _create_horizon() -> void:
	var mat := _make_water_material()
	var mesh := GeomUtil.ring_plane(HORIZON_INNER, HORIZON_OUTER, HORIZON_Y)
	horizon_mesh = MeshInstance3D.new()
	horizon_mesh.name = "bay-horizon-water"
	horizon_mesh.mesh = mesh
	horizon_mesh.material_override = mat
	horizon_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	horizon_mesh.extra_cull_margin = 1.0e8
	horizon_mesh.layers = WATER_LAYER_VALUE
	add_child(horizon_mesh)


## 平面镜（B1）：SubViewport 镜像相机 + 水面着色器投影采样
func _setup_mirror() -> void:
	planar_mirror = PLANAR_MIRROR_SCRIPT.new()
	planar_mirror.name = "PlanarMirror"
	add_child(planar_mirror)
	planar_mirror.setup(water_height)
	_apply_mirror_to_material()


func _apply_mirror_to_material() -> void:
	if shader_material == null or planar_mirror == null:
		return
	shader_material.set_shader_parameter("mirror_tex", planar_mirror.get_texture())
	shader_material.set_shader_parameter("mirror_enabled", planar_mirror.enabled)


## 收集水面三角形 → 数据坐标（east=x, north=-z）64m 格桶
func _build_water_lookup() -> void:
	if world == null or world.terrain_root == null:
		return
	for mi in GlbLoader.meshes_of(world.terrain_root):
		var lname := mi.name.to_lower()
		if not ("water" in lname or "sea" in lname):
			continue
		if mi.mesh == null:
			continue
		var faces := mi.mesh.get_faces()
		var xf := mi.global_transform
		var i := 0
		while i + 2 < faces.size():
			var a := xf * faces[i]
			var b := xf * faces[i + 1]
			var c := xf * faces[i + 2]
			_water_tri(a.x, -a.z, b.x, -b.z, c.x, -c.z)
			i += 3
	if _water_tris.size() > 0:
		print("[BayWater] 水面查询表 %d 三角形 / %d 格桶" % [
			_water_tris.size() / 6, _water_bins.size()])


func _water_tri(e1: float, n1: float, e2: float, n2: float, e3: float, n3: float) -> void:
	var idx := _water_tris.size() / 6
	for v in [e1, n1, e2, n2, e3, n3]:
		_water_tris.append(v)
	var minx := minf(e1, minf(e2, e3))
	var maxx := maxf(e1, maxf(e2, e3))
	var minz := minf(n1, minf(n2, n3))
	var maxz := maxf(n1, maxf(n2, n3))
	var x0 := int(floor(minx / WCELL))
	var x1 := int(floor(maxx / WCELL))
	var z0 := int(floor(minz / WCELL))
	var z1 := int(floor(maxz / WCELL))
	for gx in range(x0, x1 + 1):
		for gz in range(z0, z1 + 1):
			var k := Vector2i(gx, gz)
			var arr: PackedInt32Array = _water_bins.get(k, PackedInt32Array())
			arr.append(idx)
			_water_bins[k] = arr


## 该数据坐标点是否在水面上（XZ 点包含测试；只测水平投影 —— 水面是平的）。
## 没建表（世界未就绪）时返回 false，宁可不判定也不要误传送。
func is_water(east: float, north: float) -> bool:
	if _water_tris.is_empty():
		return false
	var gx := int(floor(east / WCELL))
	var gz := int(floor(north / WCELL))
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var arr = _water_bins.get(Vector2i(gx + dx, gz + dz))
			if arr == null:
				continue
			for ti in arr:
				var base: int = int(ti) * 6
				var r := _bary2(east, north,
					_water_tris[base], _water_tris[base + 1],
					_water_tris[base + 2], _water_tris[base + 3],
					_water_tris[base + 4], _water_tris[base + 5])
				if r.x >= -0.001 and r.y >= -0.001 and r.z >= -0.001:
					return true
	return false


static func _bary2(px: float, pz: float, ax: float, az: float, bx: float, bz: float,
		cx: float, cz: float) -> Vector3:
	var d := (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
	if absf(d) < 1e-9:
		return Vector3(-1, -1, -1)
	var l1 := ((bz - cz) * (px - cx) + (cx - bx) * (pz - cz)) / d
	var l2 := ((cz - az) * (px - cx) + (ax - cx) * (pz - cz)) / d
	return Vector3(l1, l2, 1.0 - l1 - l2)


func set_quality(p: Dictionary) -> void:
	if shader_material == null:
		return
	# 低画质降低波形细节（原版通过 mirrorSize 控制反射成本，这里退化为波幅）
	shader_material.set_shader_parameter("wave_scale", 1.0 if int(p.get("msaa", 2)) >= 2 else 0.5)
	# 平面镜随 SSR 档位：中/高档开，低档关（低档维持 IBL+SSR 旧路径）
	if planar_mirror != null:
		planar_mirror.set_quality(p)
		_apply_mirror_to_material()


## 夜间反射变暗（原版 envIntensity 夜 .78）
func on_light_mode(mode: int) -> void:
	if shader_material == null:
		return
	var night := mode == GameContent.LightMode.NIGHT
	shader_material.set_shader_parameter("deep_color",
		Color(0.018, 0.062, 0.070) if night else Color(0.025, 0.095, 0.105))


func update_system(_delta: float, focus: Vector3) -> void:
	# 环形远海跟随焦点，保证视野内永远有海平线
	if horizon_mesh != null:
		horizon_mesh.global_position = Vector3(focus.x, HORIZON_Y, focus.z)
	# 平面镜逐帧跟随主相机（mirror 视角 = 主相机跨水面镜像）
	if planar_mirror != null:
		planar_mirror.update_mirror(get_viewport().get_camera_3d())


func diagnostics() -> Dictionary:
	var d := {
		"waterHeight": water_height,
		"raisedVertices": raised_vertices,
		"horizonInner": HORIZON_INNER,
		"horizonOuter": HORIZON_OUTER,
	}
	if planar_mirror != null and planar_mirror.has_method("diagnostics"):
		d.merge(planar_mirror.diagnostics())
	return d
