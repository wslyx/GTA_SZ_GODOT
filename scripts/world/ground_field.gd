extends Node3D
class_name GroundField
##
## 地面材质注入层 —— 复刻原版三个材质插件的作用效果：
##   city-public-lighting.ts  → 2048m 公共照明场 clipmap（A2）
##   city-ambient-occlusion.ts → 烘焙环境光遮蔽（A6）
##   city-grass-material.ts   → 草地分层材质（A5 的材质部分）
##
## 为什么要「整体替换材质」：Godot 没有 Babylon 的 MaterialPluginBase，
## 无法往任意 PBR 材质的片元里插一段代码。所以这里把命中的网格的材质换成
## shaders/ground_field.gdshader，把原材质的底色 / 法线 / 粗糙度等抄成 uniform，
## 再在那个着色器里叠加三项注入。
##
## 与 road_surface.gd 的分工：
##   road_surface.gd 仍是**唯一**决定"路面长什么样"的地方（昼夜 / 干湿 / 车道线 /
##   对岸压暗），它改的是原始 StandardMaterial3D。本层每 0.25s 把那份参数回抄到
##   着色器 uniform 上，因此两边的行为不会打架。
##
## clipmap 计算放在 WorkerThreadPool 上：1024×1024 的径向光斑叠加在 GDScript 里
## 约 40 万次内层循环，放主线程会造成每 256m 一次的可感卡顿。

const SHADER_PATH := "res://shaders/ground_field.gdshader"

## 原版 attach 判据（对 mesh.name 做匹配）。
## ⚠️ 结尾多留了 `ground-relief`：原版那块地形补面在 Babylon 里叫 `ground_relief_*`，
## 移植版由 distant_system.gd 程序化生成、节点名是 `ground-relief`（连字符）。
const GROUND_MESH_RE := "^(?:roads_|terrain_(?:land|park|pavement)|ground_relief_|ground-relief|detail_lianhua_|rain-|rain_|coastal_bridge_|city_meadow_)"
## 原版 applyLandscapeSurfaces 的草地判据（材质名）
const GRASS_MAT_NAMES := ["land", "park"]
## C 屋顶表面：只对 `block_<i>_<j>_roof` 生效（原版 city-roof-surface.ts 的同名判据）
const ROOF_MESH_RE := "^block_-?\\d+_-?\\d+_roof$"
## 屋顶 AO 强度（原版 CITY_AMBIENT_LOOK.roof）
const ROOF_AO_STRENGTH := 0.70
## 细节瓦片的世界周期（原版 DETAIL_PERIOD = 8）
const ROOF_DETAIL_PERIOD := 8.0
## 屋顶补扫间隔：建筑区块是流式的，屋顶网格会随区块加载/卸载不断出现
const ROOF_SCAN_INTERVAL := 1.5

## clipmap 参数（原版：1024×1024、2m/texel、2048m 覆盖、每 256m 重画）
const CLIP_RES := 1024
const CLIP_TEXEL := 2.0
const CLIP_CELL := 256.0
const CLIP_WORLD := 2048.0
## 路面灯（原版半径 20 / 色 [1,.65,.34] / 功率 .72）
const ROAD_LAMP_RADIUS := 20.0
const ROAD_LAMP_COLOR := Color(1.0, 0.65, 0.34)
const ROAD_LAMP_POWER := 0.72
## 原版 `l.color.map(v=>Math.round(v*l.power*150))`
const LAMP_GAIN := 150.0
## 参数回抄间隔（秒）
const SYNC_INTERVAL := 0.25

## 原版 NIGHT_GROUND_FLOOR（city-landscape-lighting.ts）
const NIGHT_FLOOR_TERRAIN := 0.07
const NIGHT_GROUND_DIFFUSE_GAIN := 1.12
const NIGHT_GROUND_ROUGHNESS_DROP := 0.12
## 草地材质的 environmentIntensity（city-grass-material.ts:112）
const GRASS_ENV := 0.75
## 屋顶 profile 的 environment（architecture-materials 的 `?? .96`）
const ROOF_ENV := 0.96

const GRASS_BASE := "res://data/city/grassland-v2/"

var world: CityWorld

## 被替换的材质：{mat: ShaderMaterial, src: BaseMaterial3D, lawn: bool}
var _entries: Array = []
## 载入的着色器（屋顶材质也要用）
var _shader: Shader = null
var _ambient_tex: ImageTexture = null
## 缓存下来的静态 uniform（避免每次 sync 都重算）
var _ambient_meta: Dictionary = {}
var _lawn_tex: Array = []

## C 屋顶表面：查表 + 细节瓦片 + 一个**共享**的屋顶材质
var _roof_lookup: ImageTexture = null
var _roof_detail: ImageTexture = null
var _roof_mat: ShaderMaterial = null
var _roof_origin := Vector2.ZERO
var _roof_size := Vector2.ONE
var _roof_scan_timer := 0.0
var _roof_live := 0
var _roof_printed := false
## 当前沥青的环境光强度（由 road_surface 的档位决定，_sync 里刷新）
var _asphalt_env := 1.0

## 灯位场（世界坐标，扁平数组以便工作线程只读访问）
var _fx := PackedFloat32Array()
var _fz := PackedFloat32Array()
var _fr := PackedFloat32Array()
var _fc := PackedByteArray()   ## r,g,b × 灯数（已乘 功率×150）
var _field_points := PackedVector2Array()
var _field_grid: PointGrid

## clipmap 状态
var _clip_tex: ImageTexture = null
var _clip_task := -1
var _clip_slot: Dictionary = {}
var _want_x := INF
var _want_z := INF
var _have_x := INF
var _have_z := INF
var _clip_night := -1.0

var _sync_timer := 0.0
var _scan_timer := 0.0
## 已补扫次数（上限 8，覆盖 distant_system 的异步挂载）
var _scan_count := 0
var _shader_failed := false
var _built := false


func setup(p_world: CityWorld) -> void:
	world = p_world
	if not _load_ambient():
		push_warning("[GroundField] 烘焙 AO 未载入，该层关闭")
	if not _load_grass():
		push_warning("[GroundField] 草地贴图未载入，草地分层关闭")
	if not _load_roof():
		push_warning("[GroundField] 屋顶查表/细节贴图未载入，屋顶 finish 关闭")
	_build_light_fields()
	_build_materials()
	_build_roof_material()
	_built = true


# ---------------------------------------------------------------------------
# 资源
# ---------------------------------------------------------------------------

## A6：occlusion.png（3399×1307 RGB8，4m/px）+ occlusion.json
func _load_ambient() -> bool:
	var meta: Dictionary = DataLoader.json_dict("/city/ambient/occlusion.json")
	if meta.is_empty():
		return false
	var file := str(meta.get("file", "occlusion.png"))
	var res_path := DataLoader.path_for("/city/ambient/" + file)
	if not FileAccess.file_exists(res_path):
		return false
	var abs_path := ProjectSettings.globalize_path(res_path)
	var img := Image.load_from_file(abs_path)
	if img == null:
		return false
	var w := int(meta.get("width", 0))
	var h := int(meta.get("height", 0))
	if w > 0 and h > 0 and (img.get_width() != w or img.get_height() != h):
		push_warning("[GroundField] AO 图尺寸 %d×%d 与清单 %d×%d 不符"
			% [img.get_width(), img.get_height(), w, h])
	if img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGB8)
	_ambient_tex = ImageTexture.create_from_image(img)
	# 高度与淡出上限在这里就摊成 Vector4 —— 构造器参数必须是静态 float，
	# 写成 `Vector4(float(hs[0]) if ... else ..., ...)` 在解析期过不了。
	var hs: Array = meta.get("heights", [0.0, 12.0, 40.0])
	var h0: float = float(hs[0]) if hs.size() > 0 else 0.0
	var h1: float = float(hs[1]) if hs.size() > 1 else 12.0
	var h2: float = float(hs[2]) if hs.size() > 2 else 40.0
	_ambient_meta = {
		"origin": Vector2(float(meta.get("minX", 0.0)), float(meta.get("minZ", 0.0))),
		"size": Vector2(float(w) * float(meta.get("cell", 4.0)), float(h) * float(meta.get("cell", 4.0))),
		"heights": Vector4(h0, h1, h2, float(meta.get("fadeTop", 150.0))),
	}
	print("[GroundField] 烘焙 AO %s %d×%d cell=%s m" % [file, w, h, str(meta.get("cell", 4.0))])
	return true


## A5：草地六张贴图（lawn / soil / litter 各一套 颜色+法线）
func _load_grass() -> bool:
	var files := [
		"lawn-color.jpg", "lawn-normal-roughness.png",
		"soil-color.jpg", "soil-normal-roughness.png",
		"litter-color.jpg", "litter-normal-roughness.png",
	]
	for f in files:
		var p: String = GRASS_BASE + f
		if not ResourceLoader.exists(p):
			return false
		var t := load(p) as Texture2D
		if t == null:
			return false
		_lawn_tex.append(t)
	return true


## 原版 createPublicLighting 的 `fields`
func _build_light_fields() -> void:
	for e in CityData.lamps():
		if e.size() < 4:
			continue
		# 原版：灯位 = 数据点 − 朝向 × 2.5（注意与局部照明的 1.5 不同）
		var dx := float(e[2])
		var dz := float(e[3])
		_add_field(float(e[0]) - dx * 2.5, -(float(e[1]) - dz * 2.5),
			ROAD_LAMP_RADIUS, ROAD_LAMP_COLOR, ROAD_LAMP_POWER)
	for e in CityData.coastal_infrastructure.get("parkLights", []):
		var c: Array = e.get("color", [0.76, 0.84, 1.0])
		var col := Color(0.76, 0.84, 1.0)
		if c.size() >= 3:
			col = Color(float(c[0]), float(c[1]), float(c[2]))
		_add_field(float(e.get("x", 0.0)), -float(e.get("z", 0.0)),
			float(e.get("radius", 34.0)), col, float(e.get("power", 0.9)))
	_field_grid = PointGrid.new(256.0)
	_field_grid.build(_field_points)
	print("[GroundField] 公共照明场灯位 %d 个（道路灯 + 公园灯）" % _fx.size())


func _add_field(wx: float, wz: float, radius: float, c: Color, power: float) -> void:
	_fx.append(wx)
	_fz.append(wz)
	_fr.append(radius)
	_fc.append(int(round(c.r * power * LAMP_GAIN)))
	_fc.append(int(round(c.g * power * LAMP_GAIN)))
	_fc.append(int(round(c.b * power * LAMP_GAIN)))
	_field_points.append(Vector2(wx, wz))


# ---------------------------------------------------------------------------
# 材质替换
# ---------------------------------------------------------------------------

func _build_materials() -> void:
	if _shader_failed:
		return
	if not ResourceLoader.exists(SHADER_PATH):
		push_warning("[GroundField] 缺少 %s，保持原材质" % SHADER_PATH)
		_shader_failed = true
		return
	var shader := load(SHADER_PATH) as Shader
	if shader == null:
		push_warning("[GroundField] 着色器无法载入，保持原材质")
		_shader_failed = true
		return
	_shader = shader
	var re := RegEx.new()
	re.compile(GROUND_MESH_RE)
	var by_src := {}
	var roots: Array = [world.roads_root, world.terrain_root, world.landmarks_root,
		world.distant, world.scenery]
	for root in roots:
		if root == null:
			continue
		for mi in GlbLoader.meshes_of(root):
			if re.search(mi.name) == null:
				continue
			var mesh: Mesh = mi.mesh
			if mesh == null:
				continue
			for s in mesh.get_surface_count():
				# 已经被本层接管的 surface 直接跳过（补扫是幂等的）
				if mi.get_surface_override_material(s) is ShaderMaterial:
					continue
				var src := mi.get_active_material(s) as BaseMaterial3D
				if src == null:
					src = mesh.surface_get_material(s) as BaseMaterial3D
				if src == null:
					continue
				if by_src.has(src.get_instance_id()):
					mi.set_surface_override_material(s, by_src[src.get_instance_id()])
					continue
				var mat := ShaderMaterial.new()
				mat.shader = shader
				# 草地分支要求六张贴图都在；缺任意一张时宁可退回普通材质，
				# 否则 `is_lawn` 会去采样未赋值的 sampler（法线会是垃圾值）。
				var lawn := GRASS_MAT_NAMES.has(str(src.resource_name)) and _lawn_tex.size() == 6
				_init_material(mat, src, lawn)
				by_src[src.get_instance_id()] = mat
				_entries.append({"mat": mat, "src": src, "lawn": lawn})
				mi.set_surface_override_material(s, mat)
	_sync()
	if _scan_count == 0:
		print("[GroundField] 接管地面材质 %d 个（草地 %d）env_scale：沥青 %.2f / 草地 %.2f / 其余 1.00"
			% [_entries.size(), _entries.filter(func(e): return bool(e["lawn"])).size(),
				_asphalt_env, GRASS_ENV])


func _init_material(mat: ShaderMaterial, src: BaseMaterial3D, lawn: bool) -> void:
	mat.set_shader_parameter("albedo_tint", src.albedo_color)
	mat.set_shader_parameter("uv_scale", Vector2(src.uv1_scale.x, src.uv1_scale.y))
	mat.set_shader_parameter("roughness_value", src.roughness)
	mat.set_shader_parameter("metallic_value", src.metallic)
	mat.set_shader_parameter("specular_value", src.metallic_specular)
	mat.set_shader_parameter("normal_depth", src.normal_scale)
	_copy_textures(mat, src)
	mat.set_shader_parameter("is_lawn", lawn)
	if lawn:
		for i in _lawn_tex.size():
			mat.set_shader_parameter([
				"lawn_color", "lawn_normal", "soil_color", "soil_normal",
				"litter_color", "litter_normal"][i], _lawn_tex[i])
		mat.set_shader_parameter("grass_park", 1.0)


## 贴图参数只在非空时才写：把 null 灌进 sampler2D 参数会在控制台刷警告
func _copy_textures(mat: ShaderMaterial, src: BaseMaterial3D) -> void:
	mat.set_shader_parameter("use_albedo_tex", src.albedo_texture != null)
	if src.albedo_texture != null:
		mat.set_shader_parameter("albedo_tex", src.albedo_texture)
	var has_n := src.normal_enabled and src.normal_texture != null
	mat.set_shader_parameter("use_normal_tex", has_n)
	if has_n:
		mat.set_shader_parameter("normal_tex", src.normal_texture)


## C 屋顶表面：building-lookup.png 是**数据**（R 通道 = 1 + finish*16 + tint），
## roof-detail.png 是**原始数值**（原版 `gammaSpace:false`）。
## 两者都必须走 `Image.load_from_file` 按原始字节读 —— 走 Godot 的资源导入
## 会被当成颜色做 sRGB 转换，码图会被彻底破坏（和 A6 的 AO 图同一个理由）。
func _load_roof() -> bool:
	var plan: Dictionary = DataLoader.json_dict("/city/rooftops/plan.json")
	var lk: Dictionary = plan.get("lookup", {})
	if lk.is_empty():
		return false
	_roof_lookup = _load_raw_texture(
		"res://data/city/rooftops/" + str(lk.get("file", "building-lookup.png")), false)
	_roof_detail = _load_raw_texture(
		"res://data/city/textures/architecture/roof-detail.png", true)
	if _roof_lookup == null or _roof_detail == null:
		return false
	var w := int(lk.get("width", 0))
	var h := int(lk.get("height", 0))
	var cell := float(lk.get("cell", 4.0))
	_roof_origin = Vector2(float(lk.get("minX", 0.0)), float(lk.get("minZ", 0.0)))
	_roof_size = Vector2(float(w) * cell, float(h) * cell)
	print("[GroundField] 屋顶查表 %d×%d cell=%s m + 细节瓦片（%d 种 finish）"
		% [w, h, str(cell), 8])
	return true


func _load_raw_texture(path: String, mipmaps: bool) -> ImageTexture:
	if not FileAccess.file_exists(path):
		push_warning("[GroundField] 缺少 %s" % path)
		return null
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	if img == null:
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	if mipmaps:
		img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## 屋顶材质是**一个共享实例**：finish 完全由世界坐标查表决定，与被替换材质的
## 底色无关（原版直接 `surfaceAlbedo = ...`），因此用 material_override 挂到
## 每个 `block_*_roof` 网格上即可，不必按区块复制材质（那边最多 1464 个）。
func _build_roof_material() -> void:
	if _roof_lookup == null or _shader == null:
		return
	var m := ShaderMaterial.new()
	m.shader = _shader
	m.set_shader_parameter("is_roof", true)
	m.set_shader_parameter("city_roof_lookup", _roof_lookup)
	m.set_shader_parameter("city_roof_detail", _roof_detail)
	m.set_shader_parameter("city_roof_origin", _roof_origin)
	m.set_shader_parameter("city_roof_size", _roof_size)
	m.set_shader_parameter("city_roof_detail_period", ROOF_DETAIL_PERIOD)
	# 屋顶不在公共照明场的注入名单里（原版判据只含 roads_/terrain_/city_meadow_）
	m.set_shader_parameter("city_light_field", Vector4(0.0, 0.0, CLIP_WORLD, 0.0))
	m.set_shader_parameter("metallic_value", 0.0)
	m.set_shader_parameter("roughness_value", 0.86)
	m.set_shader_parameter("specular_value", 0.5)
	# 查表没覆盖到的屋面退回 `city-roof` profile 的颜色（原版 city-roof-surface
	# 是挂在 city-roof 材质上的，未被查表覆盖时保留该材质的底色）。
	# 颜色来自 city-architecture-materials.ts 的 PROFILES['city-roof']。
	m.set_shader_parameter("albedo_tint", Color(0.25, 0.28, 0.29))
	m.set_shader_parameter("uv_scale", Vector2(1.0, 1.0))
	m.set_shader_parameter("use_albedo_tex", false)
	m.set_shader_parameter("env_scale", ROOF_ENV)
	if _ambient_tex != null and not _ambient_meta.is_empty():
		m.set_shader_parameter("use_city_ambient", true)
		m.set_shader_parameter("city_ambient", _ambient_tex)
		m.set_shader_parameter("city_ambient_origin", _ambient_meta["origin"])
		m.set_shader_parameter("city_ambient_size", _ambient_meta["size"])
		m.set_shader_parameter("city_ambient_params", Vector3(ROOF_AO_STRENGTH, 0.0, _ambient_direct()))
		m.set_shader_parameter("city_ambient_heights", _ambient_meta["heights"])
	_roof_mat = m


## 建筑区块是流式的：屋顶网格会随区块加载/卸载不断出现/消失。
## material_override 随节点一起消失，所以这里只需周期性地把"还没挂上的"挂上。
func _scan_roofs() -> void:
	if _roof_mat == null or world == null or world.chunks_root == null:
		return
	var re := RegEx.new()
	re.compile(ROOF_MESH_RE)
	var live := 0
	for mi in GlbLoader.meshes_of(world.chunks_root):
		if mi.material_override == _roof_mat:
			live += 1
			continue
		if not mi.name.ends_with("_roof"):
			continue
		if re.search(mi.name) == null:
			continue
		mi.material_override = _roof_mat
		live += 1
	_roof_live = live
	if live > 0 and not _roof_printed:
		_roof_printed = true
		print("[GroundField] 屋顶 finish 已接管 %d 个 block_*_roof 网格" % live)


# ---------------------------------------------------------------------------
# 每帧
# ---------------------------------------------------------------------------

func update_system(delta: float, focus: Vector3) -> void:
	if not _built:
		return
	_clipmap_step(focus)
	_sync_timer -= delta
	if _sync_timer <= 0.0:
		_sync_timer = SYNC_INTERVAL
		_sync()
	# 补扫：distant_system 的地形补面是在**后台线程**建好后异步挂载的
	# （见 distant_system.gd 的 _process），本层建立时它可能还不存在。
	# 前若干次补扫把后到的地面网格也接管进来。
	if _scan_count < 8:
		_scan_timer -= delta
		if _scan_timer <= 0.0:
			_scan_timer = 2.0
			_scan_count += 1
			_build_materials()
	# 屋顶网格随建筑区块流式加载，必须**长期**补扫（不是前 8 次就停）
	if _roof_mat != null:
		_roof_scan_timer -= delta
		if _roof_scan_timer <= 0.0:
			_roof_scan_timer = ROOF_SCAN_INTERVAL
			_scan_roofs()


## 原版 setNight / setMode 的 state.night
func _night_factor() -> float:
	match GameState.light_mode:
		GameContent.LightMode.NIGHT: return 1.0
		GameContent.LightMode.SUNSET: return 0.17
		_: return 0.0


## 原版 CITY_AMBIENT_LOOK.direct
func _ambient_direct() -> float:
	match GameState.light_mode:
		GameContent.LightMode.DAY: return 0.30
		GameContent.LightMode.SUNSET: return 0.24
		_: return 0.0


## 把源材质（road_surface / 光照档可能刚改过的）参数回抄到着色器
func _sync() -> void:
	var night := _night_factor()
	var direct := _ambient_direct()
	# A6b：植被夜间地面补光只在夜里生效（原版 NIGHT_GROUND_FLOOR）
	var night_on := 1.0 if GameState.light_mode == GameContent.LightMode.NIGHT else 0.0
	var night_vec := Vector4(night_on, NIGHT_FLOOR_TERRAIN, NIGHT_GROUND_DIFFUSE_GAIN,
		NIGHT_GROUND_ROUGHNESS_DROP)
	# 沥青的环境光强度直接问 road_surface —— 昼夜 / 干湿的真值只有一处，
	# 免得两边各维护一份表（雨天 1.18/1.10，晴天 1/0.55）
	var asphalt_env := 1.0
	if world != null and world.road_surface != null:
		asphalt_env = float(world.road_surface.current_look().get("environment", 1.0))
	_asphalt_env = asphalt_env
	for e in _entries:
		var src: BaseMaterial3D = e["src"]
		var mat: ShaderMaterial = e["mat"]
		if not is_instance_valid(src):
			continue
		var role := str(src.resource_name)
		var env_scale := 1.0
		if bool(e["lawn"]):
			env_scale = GRASS_ENV
		elif role.begins_with("asphalt"):
			env_scale = asphalt_env
		mat.set_shader_parameter("env_scale", env_scale)
		mat.set_shader_parameter("albedo_tint", src.albedo_color)
		mat.set_shader_parameter("uv_scale", Vector2(src.uv1_scale.x, src.uv1_scale.y))
		mat.set_shader_parameter("roughness_value", src.roughness)
		mat.set_shader_parameter("metallic_value", src.metallic)
		mat.set_shader_parameter("specular_value", src.metallic_specular)
		mat.set_shader_parameter("normal_depth", src.normal_scale)
		_copy_textures(mat, src)
		if bool(e["lawn"]):
			mat.set_shader_parameter("city_landscape_night", night_vec)
		# A2：贴图还没就绪时把强度置 0，避免着色器拿到 INF 中心算出 NaN uv
		if _clip_tex != null:
			mat.set_shader_parameter("city_light_field",
				Vector4(_have_x, _have_z, CLIP_WORLD, night))
			mat.set_shader_parameter("public_irradiance", _clip_tex)
		else:
			mat.set_shader_parameter("city_light_field",
				Vector4(0.0, 0.0, CLIP_WORLD, 0.0))
		# A6
		if _ambient_tex != null and not _ambient_meta.is_empty():
			mat.set_shader_parameter("use_city_ambient", true)
			mat.set_shader_parameter("city_ambient", _ambient_tex)
			mat.set_shader_parameter("city_ambient_origin", _ambient_meta["origin"])
			mat.set_shader_parameter("city_ambient_size", _ambient_meta["size"])
			# 地面强度 .85 / 内缩 0（原版 CITY_AMBIENT_LOOK.ground）
			mat.set_shader_parameter("city_ambient_params", Vector3(0.85, 0.0, direct))
			mat.set_shader_parameter("city_ambient_heights", _ambient_meta["heights"])
	# 屋顶材质的 AO 直射份额同样随光照档变（屋顶不在 _entries 里）
	if _roof_mat != null and _ambient_tex != null and not _ambient_meta.is_empty():
		_roof_mat.set_shader_parameter("city_ambient_params",
			Vector3(ROOF_AO_STRENGTH, 0.0, direct))
	_clip_night = night


# ---------------------------------------------------------------------------
# 公共照明场 clipmap
# ---------------------------------------------------------------------------

func _clipmap_step(focus: Vector3) -> void:
	# 1) 有任务在跑就等它；完成后在主线程上传贴图
	if _clip_task >= 0:
		if not WorkerThreadPool.is_task_completed(_clip_task):
			return
		WorkerThreadPool.wait_for_task_completion(_clip_task)
		_clip_task = -1
		_upload_clipmap()
	# 2) 焦点跨到新的 256m 格 → 排一次重算
	var cx := roundf(focus.x / CLIP_CELL) * CLIP_CELL
	var cz := roundf(focus.z / CLIP_CELL) * CLIP_CELL
	if cx == _want_x and cz == _want_z:
		return
	_want_x = cx
	_want_z = cz
	_clip_slot = {}
	# 用显式 Callable(self, "…").bind(...)：绑定后的可调用对象在工作线程上执行，
	# 只读共享数组 + 写自己那份 slot 字典，不碰场景树。
	_clip_task = WorkerThreadPool.add_task(
		Callable(self, "_compute_clipmap").bind(cx, cz, _clip_slot))


## 工作线程：把 2048m 场内的所有灯位按「径向渐变 + 加性叠加」画进 RGB8 缓冲。
## 完全对应原版 DynamicTexture 里
##   ctx.globalCompositeOperation='lighter' + createRadialGradient 的那段。
func _compute_clipmap(cx: float, cz: float, slot: Dictionary) -> void:
	var buf := PackedByteArray()
	buf.resize(CLIP_RES * CLIP_RES * 3)
	var center := Vector2(cx, cz)
	var reach := CLIP_WORLD * 0.7072 + 40.0
	var cand := _field_grid.query_radius(center, reach)
	var half := CLIP_RES * 0.5
	for i in cand:
		var wx := _fx[i]
		var wz := _fz[i]
		var radius := _fr[i]
		var px := int(round((wx - cx) / CLIP_TEXEL + half))
		var pz := int(round((wz - cz) / CLIP_TEXEL + half))
		var rp := int(radius * 0.5)      # 半径 / 2m 每 texel
		if rp <= 0:
			continue
		if px < -rp or px > CLIP_RES + rp or pz < -rp or pz > CLIP_RES + rp:
			continue
		var cr := _fc[i * 3]
		var cg := _fc[i * 3 + 1]
		var cb := _fc[i * 3 + 2]
		var r2 := rp * rp
		var inv_rp := 1.0 / float(rp)
		for dy in range(-rp, rp + 1):
			var yy := pz + dy
			if yy < 0 or yy >= CLIP_RES:
				continue
			var row := yy * CLIP_RES
			for dx in range(-rp, rp + 1):
				var dd := dx * dx + dy * dy
				if dd > r2:
					continue
				var xx := px + dx
				if xx < 0 or xx >= CLIP_RES:
					continue
				# 原版渐变停靠点：0→1, .35→.75, .72→.20, 1→0（线性插值）
				var w := _gradient(sqrt(float(dd)) * inv_rp)
				var o := (row + xx) * 3
				# 饱和加：先算成 int 再夹到 255，避免把 Variant 三元写进 PackedByteArray
				buf[o] = mini(buf[o] + int(cr * w), 255)
				buf[o + 1] = mini(buf[o + 1] + int(cg * w), 255)
				buf[o + 2] = mini(buf[o + 2] + int(cb * w), 255)
	slot["x"] = cx
	slot["z"] = cz
	slot["bytes"] = buf


## canvas createRadialGradient 的四个停靠点，线性插值
static func _gradient(t: float) -> float:
	if t <= 0.0:
		return 1.0
	if t >= 1.0:
		return 0.0
	if t < 0.35:
		return lerpf(1.0, 0.75, t / 0.35)
	if t < 0.72:
		return lerpf(0.75, 0.20, (t - 0.35) / 0.37)
	return lerpf(0.20, 0.0, (t - 0.72) / 0.28)


func _upload_clipmap() -> void:
	if _clip_slot.is_empty():
		return
	var bytes: PackedByteArray = _clip_slot.get("bytes", PackedByteArray())
	if bytes.size() != CLIP_RES * CLIP_RES * 3:
		return
	var img := Image.create_from_data(CLIP_RES, CLIP_RES, false, Image.FORMAT_RGB8, bytes)
	if img == null:
		return
	if _clip_tex == null:
		_clip_tex = ImageTexture.create_from_image(img)
	else:
		_clip_tex.update(img)
	_have_x = float(_clip_slot.get("x", 0.0))
	_have_z = float(_clip_slot.get("z", 0.0))
	_sync_timer = 0.0
	_clip_count += 1
	if _clip_count == 1:
		print("[GroundField] 公共照明场 clipmap 首帧上传完成（%d×%d，中心 %.0f,%.0f）"
			% [CLIP_RES, CLIP_RES, _have_x, _have_z])


var _clip_count := 0


func diagnostics() -> Dictionary:
	return {
		"materials": _entries.size(),
		"lawnMaterials": _entries.filter(func(e): return bool(e["lawn"])).size(),
		"lampFields": _fx.size(),
		"clipmapReady": _clip_tex != null,
		"clipmapUploads": _clip_count,
		"clipmapCell": [_have_x, _have_z],
		"ambientReady": _ambient_tex != null,
		"roofReady": _roof_mat != null,
		"roofMeshes": _roof_live,
	}
