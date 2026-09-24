extends Node3D
class_name WeatherSystem
##
## 降雨与积水 —— 对应原版 city-rain-weather.ts + city-rain-puddles.ts。
##
## 原版参数（照搬）：
##   雨丝 240 条、涟漪 64 个；下落 y = mod(y − t*(13+g*8) + 40, 20) − 6，
##   生成区 28×28 跟随相机，10–15m 外淡出
##   雨压：太阳 ×.48（夜 .78）、半球 ×.82（夜 .92）、环境 ×.84；
##         亮日 .78 / 夜 1.1 / 黄昏 .92
##   积水：rain/puddles-layout.json version 2、stride 10，
##         每 10 元组 = [x, z, dx, dz, length, width, lateral, roadWidth, seed, alpha]
##         水材质 albedo (.025,.036,.045)、metal 0、rough .075、spec .85、env 1.35（昼 .13）
##         湿膜 albedo (.033,.038,.042)、rough .55、spec .28
##         ROAD_Y = .10

const RAIN_STREAK_COUNT := 240
const RIPPLE_COUNT := 64
const RAIN_AREA := 28.0
const PUDDLE_ROAD_Y := 0.10

var world: CityWorld
var raining := false
var intensity := 0.0

var rain_node: Node3D
var puddle_mesh: MeshInstance3D
## 雨丝渲染：单 MultiMesh + 单材质。
## 原实现是 240 个独立 MeshInstance3D，各自 new 一份 StandardMaterial3D ——
## 240 个透明 draw call + 240 个节点 transform 更新，下雨天帧率直接腰斩。
var _rain_mm: MultiMesh
var _rain_seeds := PackedFloat32Array()
var _puddles: Array = []
var _built := false
## 干燥状态的材质快照，只建一次：[{mat, albedo, roughness}]
## 之前没有这份快照：恢复分支读的是"当前色"，而当前色已经是变暗后的值，
## 于是反复下雨会按 0.86ⁿ 越叠越黑，而且雨停根本不会恢复。
var _dry_cache: Array = []
var _wet_applied := false
# --- 积水网格后台构建（62661 个积水片 ≈ 12.5 万三角形，主线程建会卡死）---
var _puddle_thread: Thread
var _puddle_building := false
var _puddle_mesh: Mesh
var _puddle_mat: Material


func setup(p_world: CityWorld) -> void:
	world = p_world
	_build_rain()
	_start_puddle_build()
	_built = true
	set_raining(false)


func _process(_delta: float) -> void:
	if not _puddle_building:
		set_process(false)
		return
	if _puddle_thread.is_alive():
		return
	_puddle_thread.wait_to_finish()
	_puddle_building = false
	if _puddle_mesh != null:
		puddle_mesh = MeshInstance3D.new()
		puddle_mesh.name = "puddles"
		puddle_mesh.mesh = _puddle_mesh
		puddle_mesh.material_override = _puddle_mat
		puddle_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		puddle_mesh.visible = raining
		add_child(puddle_mesh)
		_puddles.append(_puddle_mat)
		print("[WeatherSystem] 积水网格后台构建完成并挂载")


func _build_rain() -> void:
	rain_node = Node3D.new()
	rain_node.name = "rain"
	rain_node.visible = false
	add_child(rain_node)
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.035, 1.6, 0.035)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.72, 0.80, 0.88, 0.42)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.disable_receive_shadows = true
	_rain_mm = MultiMesh.new()
	_rain_mm.transform_format = MultiMesh.TRANSFORM_3D
	_rain_mm.mesh = mesh
	_rain_mm.instance_count = RAIN_STREAK_COUNT
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "rain-streaks"
	mmi.multimesh = _rain_mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rain_node.add_child(mmi)
	_rain_seeds.resize(RAIN_STREAK_COUNT)
	for i in RAIN_STREAK_COUNT:
		_rain_seeds[i] = randf()


## 启动后台线程生成积水网格。
##
## 62661 个积水片 ≈ 12.5 万三角形、37 万顶点，用 GDScript 的 SurfaceTool 逐顶点
## 建要好几秒 —— 放主线程会把画面卡死（用户实测）。所以丢给 Thread，
## 主线程在 _process 里等它完成后才挂到场景树。
func _start_puddle_build() -> void:
	_puddle_building = true
	_puddle_mesh = null
	_puddle_mat = null
	_puddle_thread = Thread.new()
	_puddle_thread.start(_build_puddle_worker)
	set_process(true)


func _build_puddle_worker() -> void:
	var layout: Dictionary = CityData.puddles_layout()
	var values: Array = layout.get("values", [])
	if values.is_empty():
		return
	var stride := int(layout.get("stride", 10))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var count := 0
	var i := 0
	while i + stride <= values.size():
		var x := float(values[i + 0])
		var z := float(values[i + 1])
		var dx := float(values[i + 2])
		var dz := float(values[i + 3])
		var length := float(values[i + 4])
		var width := float(values[i + 5])
		var alpha := float(values[i + 9])
		if alpha <= 0.01:
			i += stride
			continue
		# 沿 (dx, dz) 展开一个矩形薄片
		var fx := dx
		var fz := dz
		var flen := sqrt(fx * fx + fz * fz)
		if flen < 0.0001:
			i += stride
			continue
		fx /= flen
		fz /= flen
		var rx := -fz
		var rz := fx
		var hl := length * 0.5
		var hw := width * 0.5
		var p0 := Vector3(x - fx * hl - rx * hw, PUDDLE_ROAD_Y, -(z - fz * hl - rz * hw))
		var p1 := Vector3(x + fx * hl - rx * hw, PUDDLE_ROAD_Y, -(z + fz * hl - rz * hw))
		var p2 := Vector3(x + fx * hl + rx * hw, PUDDLE_ROAD_Y, -(z + fz * hl + rz * hw))
		var p3 := Vector3(x - fx * hl + rx * hw, PUDDLE_ROAD_Y, -(z - fz * hl + rz * hw))
		_add_tri(st, p0, p1, p2)
		_add_tri(st, p0, p2, p3)
		count += 1
		i += stride
	if count == 0:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.025, 0.036, 0.045, 0.85)
	mat.roughness = 0.075
	mat.metallic = 0.0
	mat.metallic_specular = 0.85
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.rim = 0.2
	_puddle_mesh = st.commit()
	_puddle_mat = mat
	print("[WeatherSystem] 积水片 %d 个（来自 %d 条布局记录）" % [count, values.size() / stride])


static func _add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.set_normal(Vector3.UP)
	st.add_vertex(a)
	st.set_normal(Vector3.UP)
	st.add_vertex(b)
	st.set_normal(Vector3.UP)
	st.add_vertex(c)


func set_raining(v: bool) -> void:
	raining = v
	intensity = 1.0 if v else 0.0
	if rain_node != null:
		rain_node.visible = v
	if puddle_mesh != null:
		puddle_mesh.visible = v
	# 只在"开始下雨"或"雨停需要还原"时才动材质：地面 + 道路共 765+ 个 mesh，
	# 空跑一遍纯属浪费（初始 setup 传的是 false）
	if raining or _wet_applied:
		_apply_wet_materials()
	# 沥青材质单独走原版 RAIN_ROAD_LOOK（反照率/粗糙度/镜面强度三档一起换）
	if world != null and world.road_surface != null:
		world.road_surface.set_weather(raining)
	if world != null and world.lighting != null and world.lighting.has_method("apply_mode"):
		# 雨压：重放当前光照模式
		world.lighting.apply_mode(GameState.light_mode)


func toggle() -> bool:
	set_raining(not raining)
	return raining


## 湿路面：把地面材质调暗、降粗糙度提反光（原版湿膜 albedo .033/.038/.042, rough .55）
func _apply_wet_materials() -> void:
	if _dry_cache.is_empty():
		_build_dry_cache()
	for e in _dry_cache:
		var mat: Material = e["mat"]
		if mat == null or not is_instance_valid(mat):
			continue
		var base: Color = e["albedo"]
		if raining:
			mat.albedo_color = Color(base.r * 0.86, base.g * 0.87, base.b * 0.88)
			if mat is StandardMaterial3D:
				(mat as StandardMaterial3D).roughness = 0.28
		else:
			mat.albedo_color = base
			if mat is StandardMaterial3D:
				(mat as StandardMaterial3D).roughness = float(e["roughness"])
	_wet_applied = raining


## 第一次进入雨/晴切换时把原始材质参数拍下来。
## 注意：GLB 导入的材质通常是**共享资源**，同一个材质可能被多个 mesh 引用，
## 所以这里按 Resource 去重，避免同一份材质被改两次。
func _build_dry_cache() -> void:
	var seen := {}
	for mi in GlbLoader.meshes_of(world.terrain_root) + GlbLoader.meshes_of(world.roads_root):
		var mesh: Mesh = mi.mesh
		if mesh == null:
			continue
		for s in mesh.get_surface_count():
			var mat: Material = mesh.surface_get_material(s)
			if mat == null or mat is ShaderMaterial:
				continue
			if not (mat is StandardMaterial3D or mat is ORMMaterial3D):
				continue
			# asphalt 归 RoadSurface 管（它按原版 RAIN_ROAD_LOOK 整套换反照率/
			# 粗糙度/镜面强度）。这里再插一手会出现两个系统抢同一份材质。
			if mat.resource_name.begins_with("asphalt"):
				continue
			var rid := mat.get_instance_id()
			if seen.has(rid):
				continue
			seen[rid] = true
			var rough := 1.0
			if mat is StandardMaterial3D:
				rough = float((mat as StandardMaterial3D).roughness)
			_dry_cache.append({"mat": mat, "albedo": mat.albedo_color, "roughness": rough})


func update_system(delta: float, focus: Vector3) -> void:
	if not raining or not _built:
		return
	if rain_node != null:
		rain_node.global_position = Vector3(focus.x, focus.y + 12.0, focus.z)
	var t := Time.get_ticks_msec() / 1000.0
	for i in RAIN_STREAK_COUNT:
		var seed_v := _rain_seeds[i]
		# 原版：y = mod(y - t*(13 + g*8) + 40, 20) - 6
		var y := fposmod(seed_v * 20.0 - t * (13.0 + seed_v * 8.0) + 40.0, 20.0) - 6.0
		_rain_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(
			(seed_v * 7.0 - fposmod(seed_v * 3.0, 1.0) * 14.0),
			y,
			(fposmod(seed_v * 11.0, 1.0) * 28.0 - 14.0))))


func diagnostics() -> Dictionary:
	return {"raining": raining, "streaks": _rain_seeds.size(), "puddles": _puddles.size(),
			"built": _built}
