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

var world: CityWorld
var water_height := -0.25
var horizon_mesh: MeshInstance3D
var shader_material: ShaderMaterial
var raised_vertices := 0
var _built := false


func setup(p_world: CityWorld) -> void:
	world = p_world
	water_height = float(world.height_field.water_height)
	_raise_terrain_water()
	_create_horizon()
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

		if not any_change:
			continue
		mi.mesh = rebuilt
		if shader_material != null:
			mi.material_override = shader_material
	if raised_vertices > 0:
		print("[BayWater] 抬升地形水面顶点 %d 个到 y=%.2f" % [raised_vertices, water_height])


func _make_water_material() -> ShaderMaterial:
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
	add_child(horizon_mesh)


func set_quality(p: Dictionary) -> void:
	if shader_material == null:
		return
	# 低画质降低波形细节（原版通过 mirrorSize 控制反射成本，这里退化为波幅）
	shader_material.set_shader_parameter("wave_scale", 1.0 if int(p.get("msaa", 2)) >= 2 else 0.5)


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


func diagnostics() -> Dictionary:
	return {
		"waterHeight": water_height,
		"raisedVertices": raised_vertices,
		"horizonInner": HORIZON_INNER,
		"horizonOuter": HORIZON_OUTER,
	}
