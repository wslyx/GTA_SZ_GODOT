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

## 天空球的显示增益 —— 对**色调映射肩部差异**的实测补偿。
##
## 天空着色器输出 0.42~0.94 的线性色，直接吃进 Godot 的 ACES 后显示端几乎不衰减
## （实测地平线朝日处 #fab493）；而原版 Babylon 的 ACES 在同一个 1.0 曝光下把这段
## 压得很狠（原版截图同位置 #a8613b）。这不是天空着色器的问题 —— 着色器已经逐行
## 照搬，差的是两家 ACES 肩部的压缩量。
##
## 标定方法：tools/compare_shots.py 逐档扫 sky_gain，比对截图天空中央列（y 0~305）
## 的三段均值。0.40 时三段同时落位：
##   y  0- 30  原版 #976451 / 复刻 #87504f
##   y150-190  原版 #9f5c39 / 复刻 #a15c4c
##   y270-305  原版 #a8613b / 复刻 #b16349
## 取 0.42（略保守，避免暗部压过头）。
const SKY_GAIN := 0.42

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
## 环境全景能量 = 原版 CINEMATIC_LOOK 的 `environment`（0.78 / 0.40 / 0.55）。
##
## 这个值现在同时是 **IBL 漫射辐照度** 与 **镜面反射强度**：LightingDirector 把
## 环境光来源切到 SKY，HDR 全景既供给 ambient 也供给 reflection —— 对应原版
## `scene.environmentTexture` + `scene.environmentIntensity` 的单一份能量。
## （旧版这里被压到 0.45/0.32/0.55，是因为当时它只做反射，漫射另由放大 2.2 倍的
## 半球光提供，两条路径的能量对不上，全图亮度是原版的两倍。）
const ENV_INTENSITY := {
	GameContent.LightMode.DAY: 0.78,
	GameContent.LightMode.SUNSET: 0.40,
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
	# 天空球只有 `night` / `sky_gain` 两个 uniform —— 原版 szSky 的 horizon / zenith
	# 是写死在着色器里的常量，且按 `west`（是否朝阳）做方向混合，不接受外部覆盖。
	if sky_material != null:
		sky_material.set_shader_parameter("night", 1.0 if is_night else 0.0)
		sky_material.set_shader_parameter("sky_gain", SKY_GAIN)
	if night_mesh_ref != null:
		night_mesh_ref.visible = is_night
	_apply_environment_hdr(m)


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
