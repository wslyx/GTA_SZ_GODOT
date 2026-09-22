extends Node3D
##
## 天空系统 —— 对应原版 city-world.ts 的 szSky 着色器 + city-night-sky.ts + 三套 HDR 环境。
##
## 原版结构：
##   - `atmosphere` 球体（直径 8000，infiniteDistance，不参与雾）承载程序化天空着色器，
##     uniform `night` 在 0/1 之间切换昼夜。
##   - 夜晚另有一套 city-night-sky 着色器：方向性银河、星群、月球盘
##     （月亮方向 (.72,.48,-.5)，盘亮度 .0082）。
##   - 环境反射贴图（IBL）按模式换 HDR：日落 belfast-sunset-4k / 白天 rustig-blue-sky-4k /
##     夜晚 rooftop-night-2k，各自带一个绕 Y 的旋转角。
##
## Godot 对应做法：
##   程序化天空仍用手写着色器（szSky 的 GLSL 逐行搬成 .gdshader），
##   挂在直径 8000 的球上；HDR 环境反射交给 Sky 的 PanoramaSkyMaterial。

const SKY_DIAMETER := 8000.0

## HDR 环境贴图（Poly Haven，见 data/licenses/daylight-environment.md）
const HDR := {
	GameContent.LightMode.DAY: "res://data/city/environment/rustig-blue-sky-4k.hdr",
	GameContent.LightMode.SUNSET: "res://data/city/environment/belfast-sunset-4k.hdr",
	GameContent.LightMode.NIGHT: "res://data/city/environment/rooftop-night-2k.hdr",
}
const HDR_ROTATION := {
	GameContent.LightMode.DAY: 1.85,
	GameContent.LightMode.SUNSET: 2.80,
	GameContent.LightMode.NIGHT: 0.65,
}
## 环境反射强度（CINEMATIC_LOOK.environment）
## 这份能量同时是 HDR 全景的背景亮度与 IBL 镜面反射强度。背景被程序化
## 天空球挡住（玩家看到的是 mesh 不是 pano），真正起作用的是**反射**：
## 原值（0.78/0.40/0.55）会让湿滑路面与玻璃幕墙把天空镜像得过亮
## （实测白天 46% 像素过曝的一部分），按实测压低昼/夜两档。
const ENV_INTENSITY := {
	GameContent.LightMode.DAY: 0.45,
	GameContent.LightMode.SUNSET: 0.32,
	GameContent.LightMode.NIGHT: 0.55,
}

var world: CityWorld
var sky_mesh: MeshInstance3D
var sky_material: ShaderMaterial
var night_mesh_ref: MeshInstance3D
var night_material: ShaderMaterial
var mode: int = GameContent.LightMode.SUNSET
var _built := false
var _hdr_cache: Dictionary = {}
## 复用的 Sky / PanoramaSkyMaterial（见 _apply_environment_hdr）
var _sky_cache: Sky = null
var _pano_cache: PanoramaSkyMaterial = null


func setup(p_world: CityWorld) -> void:
	world = p_world
	_build_procedural_sky()
	_built = true
	apply_mode(mode)


func _build_procedural_sky() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = SKY_DIAMETER * 0.5
	sphere.height = SKY_DIAMETER
	sphere.radial_segments = 24
	sphere.rings = 12
	sky_mesh = MeshInstance3D.new()
	sky_mesh.name = "atmosphere"
	sky_mesh.mesh = sphere
	sky_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sky_mesh.extra_cull_margin = 1.0e8
	sky_material = _make_material("res://shaders/sky.gdshader")
	sky_mesh.material_override = sky_material
	add_child(sky_mesh)

	var night_mesh := MeshInstance3D.new()
	night_mesh.name = "night-sky"
	night_mesh.mesh = sphere
	night_mesh.visible = false
	night_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	night_mesh.extra_cull_margin = 1.0e8
	night_material = _make_material("res://shaders/night_sky.gdshader")
	night_mesh.material_override = night_material
	add_child(night_mesh)
	night_mesh_ref = night_mesh


func _make_material(path: String) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	if ResourceLoader.exists(path):
		mat.shader = load(path)
	else:
		push_warning("[SkySystem] 缺少着色器 %s" % path)
	return mat


## 切换光照模式：昼夜天空球互换 + 环境反射贴图换 HDR
func apply_mode(m: int) -> void:
	mode = m
	if not _built:
		return
	var is_night := m == GameContent.LightMode.NIGHT
	if sky_material != null:
		sky_material.set_shader_parameter("night", 1.0 if is_night else 0.0)
		_apply_sky_params(sky_material, m)
	if night_mesh_ref != null:
		night_mesh_ref.visible = is_night
	_apply_environment_hdr(m)


func _apply_sky_params(mat: ShaderMaterial, m: int) -> void:
	match m:
		GameContent.LightMode.DAY:
			mat.set_shader_parameter("horizon_color", Color(0.79, 0.79, 0.68))
			mat.set_shader_parameter("zenith_color", Color(0.36, 0.54, 0.66))
			mat.set_shader_parameter("sun_glow", 0.0)
		GameContent.LightMode.SUNSET:
			mat.set_shader_parameter("horizon_color", Color(0.86, 0.55, 0.36))
			mat.set_shader_parameter("zenith_color", Color(0.20, 0.30, 0.52))
			mat.set_shader_parameter("sun_glow", 1.0)
		_:
			mat.set_shader_parameter("horizon_color", Color(0.10, 0.13, 0.24))
			mat.set_shader_parameter("zenith_color", Color(0.02, 0.03, 0.08))
			mat.set_shader_parameter("sun_glow", 0.0)


## 环境反射（IBL）：把对应 HDR 装进 WorldEnvironment 的 Sky。
##
## 只让 Sky 负责**背景与反射**，环境漫射仍由 LightingDirector 的
## AMBIENT_SOURCE_COLOR（半球光等效）主导 —— 这样才与原版
## "HemisphericLight + environmentTexture" 的双通道结构对应。
func _apply_environment_hdr(m: int, env: Environment = null) -> void:
	var environment := env if env != null else _environment()
	if environment == null:
		return
	var path: String = HDR.get(m, HDR[GameContent.LightMode.SUNSET])
	if not ResourceLoader.exists(path):
		push_warning("[SkySystem] 缺少 HDR：%s（环境反射回退为程序化天空）" % path)
		return
	var tex = _hdr_cache.get(path)
	if tex == null:
		tex = load(path)
		_hdr_cache[path] = tex
	# Sky / PanoramaSkyMaterial 只建一次并复用。
	# 之前每次切模式或切雨都 new 一对再赋给 environment.sky —— 换掉 Sky 对象会
	# 让引擎重算 IBL 辐照度立方体贴图，而 set_raining()/apply_mode() 会频繁调用这里。
	if _sky_cache == null:
		_sky_cache = Sky.new()
		_pano_cache = PanoramaSkyMaterial.new()
		_sky_cache.sky_material = _pano_cache
		_sky_cache.radiance_size = Sky.RADIANCE_SIZE_512
	_pano_cache.panorama = tex
	_pano_cache.energy_multiplier = float(ENV_INTENSITY.get(m, 0.5))
	environment.sky = _sky_cache
	environment.background_mode = Environment.BG_SKY
	# 刻意不改 ambient_light_source：半球光颜色由 LightingDirector 维护


func _environment() -> Environment:
	if world != null and world.lighting != null and world.lighting.env_node != null:
		return world.lighting.env_node.environment
	return null


## 天空球跟随相机（保持永远在无限远）
func follow(cam_pos: Vector3) -> void:
	if sky_mesh != null:
		sky_mesh.global_position = cam_pos
	if night_mesh_ref != null:
		night_mesh_ref.global_position = cam_pos


func update_system(_delta: float, focus: Vector3) -> void:
	follow(focus)
