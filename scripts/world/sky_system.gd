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
##   程序化天空仍用手写着色器（szSky 的 GLSL 逐行搬成 .gdshader）。
##   ⚠️ 2026-09-26 起改成 **Godot 的 Sky 着色器**（`shaders/sky_sky.gdshader`），
##   不再是 8000 直径的球体网格。原因见那个着色器的头部：Sky 是"方向 → 颜色"的函数，
##   不需要几何体，辐照度立方图只在参数变化时重渲，而且能用半分辨率子通道把云的
##   fbm 成本降到 1/4。球体网格只作为**拿不到 sky 着色器时的兜底**保留。

const SKY_DIAMETER := 8000.0
## Sky 着色器（三档天空合一个；原版是同一个天空球换三份材质）
const SKY_SHADER := "res://shaders/sky_sky.gdshader"

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

## —— 光照档平滑切换（sky_mode 连续轴）——
## 轴序：0 夜晚 — 1 日落 — 2 白天。夜→白天会掠过日落色（= 黎明），
## 日落→夜直接淡入星空，与 cycle_mode 的循环顺序一一相邻。
const MODE_POS := {
	GameContent.LightMode.NIGHT: 0.0,
	GameContent.LightMode.SUNSET: 1.0,
	GameContent.LightMode.DAY: 2.0,
}
## 一档切换的过渡时长（秒）
const TRANSITION_TIME := 1.8

var world: CityWorld
var sky_mesh: MeshInstance3D
var sky_material: ShaderMaterial
var night_mesh_ref: MeshInstance3D
var night_material: ShaderMaterial
var mode: int = GameContent.LightMode.SUNSET
var _built := false
var _hdr_cache: Dictionary = {}
## 复用的 Sky / 材质（见 _apply_environment_hdr）
var _sky_cache: Sky = null
var _pano_cache: PanoramaSkyMaterial = null
## 主路径：Sky + sky 着色器（三档共用一份材质，靠连续 sky_mode 混合）
var _sky_shader_mat: ShaderMaterial = null
var _use_sky_shader := false

## —— 过渡状态机 ——
var _mode_target: int = GameContent.LightMode.SUNSET  ## 过渡目标档
var _sky_mode := 1.0            ## 当前连续 sky_mode（静止时为整数档位）
var _sky_mode_from := 1.0       ## 本次过渡起点
var _trans_t := 1.0             ## 过渡进度 0..1；>=1 表示静止
## IBL 交叉淡化：可见环境 = mix(A, B, blend)。静止时 A=B 且 blend=0。
var _env_tex: Texture2D = null
var _env_energy := 0.40
var _env_tex_b: Texture2D = null
var _env_energy_b := 0.40
var _env_blend := 0.0
## A/B 槽的档位（着色器据此决定该槽走 HDR 全景还是夜晚中性环境）
var _slot_a_idx := 1.0
var _slot_b_idx := 1.0
## environment.sky 是否已挂接成功（启动顺序兜底用）
var _env_bound := false


func setup(p_world: CityWorld) -> void:
	world = p_world
	_build_sky()
	_built = true
	apply_mode(mode)


## 优先建 Sky + sky 着色器；拿不到着色器才退回球体网格。
func _build_sky() -> void:
	_sky_cache = Sky.new()
	_sky_cache.radiance_size = Sky.RADIANCE_SIZE_512
	# AUTOMATIC 让引擎自己决定何时重渲立方图：静止时本shader不用 TIME/POSITION，
	# 立方图是静态的；过渡期间 uniform 每帧变化，引擎会自动逐帧重渲（过渡只有 ~2s）。
	_sky_cache.process_mode = Sky.PROCESS_MODE_AUTOMATIC
	if ResourceLoader.exists(SKY_SHADER):
		var sh := load(SKY_SHADER) as Shader
		if sh != null:
			_sky_shader_mat = ShaderMaterial.new()
			_sky_shader_mat.shader = sh
			_use_sky_shader = true
	if _use_sky_shader:
		# 三档共用这一份材质：可见天空由连续 sky_mode 混合，
		# IBL 由 A/B 双采样器交叉淡化（见 sky_sky.gdshader 头部）
		_sky_cache.sky_material = _sky_shader_mat
		print("[SkySystem] 使用 Sky 着色器（全分辨率逐像素 + 立方图缓存 + 三档连续混合）")
		return
	push_warning("[SkySystem] 缺少 %s，退回球体网格天空" % SKY_SHADER)
	_pano_cache = PanoramaSkyMaterial.new()
	_sky_cache.sky_material = _pano_cache
	_build_procedural_sky()


## 兜底路径：两个 8000 直径的球（改造前的实现）
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


## 切换光照档。
##
## Sky 着色器路径：**平滑过渡** —— 可见天空沿 夜0—日落1—白天2 连续混合，
## IBL 环境在 A/B 双采样器间交叉淡化（~1.8s，见 MODE_POS / TRANSITION_TIME）。
## 幂等：过渡途中重复 apply 同一目标档不会重置进度。
##
## 兜底球体路径保持原版的瞬时切换。
func apply_mode(m: int) -> void:
	mode = m
	if not _built:
		return
	if _use_sky_shader and _sky_shader_mat != null:
		_apply_mode_sky(m)
		return
	# —— 兜底：球体网格路径（硬切） ——
	var is_night := m == GameContent.LightMode.NIGHT
	var is_day := m == GameContent.LightMode.DAY
	if sky_material != null:
		sky_material.set_shader_parameter("night", 1.0 if is_night else 0.0)
		sky_material.set_shader_parameter("sky_gain", SKY_GAIN)
	if sky_mesh != null:
		sky_mesh.visible = not is_night and not is_day
	if night_mesh_ref != null:
		night_mesh_ref.visible = is_night
	_apply_environment_hdr(m)


## Sky 着色器路径的档位切换（连续混合）
func _apply_mode_sky(m: int) -> void:
	# ⚠️ 先确保 environment.sky 已挂接：sky.setup() 在 lighting.setup() 之前运行，
	# 首次 apply 时 lighting.env_node 还不存在，_ensure_env_sky 会静默失败；
	# 幂等早退若跳过补挂，environment.sky 将永远是 null → 天空一片黑。
	_ensure_env_sky()
	var target_pos := float(MODE_POS.get(m, 1.0))
	var tex := _load_hdr(m)
	var energy := float(ENV_INTENSITY.get(m, 0.5))
	# 过渡途中再次切换：环境槽先收尾到上一个目标（sky_mode 保持连续，不回跳）
	if _trans_t < 1.0 and _mode_target != m:
		if _env_tex_b != null:
			_env_tex = _env_tex_b
			_env_energy = _env_energy_b
			_env_blend = 0.0
	if _mode_target == m and _trans_t >= 1.0 and _env_tex == tex:
		return  # 已在该档且静止：幂等返回
	if _env_tex == null:
		# 首次套用：直接落位，不做过渡
		_env_tex = tex
		_env_energy = energy
		_env_tex_b = tex
		_env_energy_b = energy
		_env_blend = 0.0
		_sky_mode = target_pos
		_sky_mode_from = target_pos
		_trans_t = 1.0
		_mode_target = m
		_slot_a_idx = target_pos
		_slot_b_idx = target_pos
	else:
		# 新过渡：A 槽定格在上一个目标档（若刚打断，环境槽已烘到那里），
		# sky_mode 从当前连续值滑向新目标（中途打断不回跳）。
		_slot_a_idx = float(MODE_POS.get(_mode_target, 1.0))
		_sky_mode_from = _sky_mode
		_mode_target = m
		_trans_t = 0.0
		_env_tex_b = tex
		_env_energy_b = energy
		_slot_b_idx = target_pos
	_sky_shader_mat.set_shader_parameter("sky_mode", _sky_mode)
	_sky_shader_mat.set_shader_parameter("sky_gain", SKY_GAIN)
	_sky_shader_mat.set_shader_parameter("base_sky", _env_tex)
	_sky_shader_mat.set_shader_parameter("base_energy", _env_energy)
	if _env_tex_b != null:
		_sky_shader_mat.set_shader_parameter("base_sky_b", _env_tex_b)
		_sky_shader_mat.set_shader_parameter("base_energy_b", _env_energy_b)
	_sky_shader_mat.set_shader_parameter("env_blend", _env_blend)
	_sky_shader_mat.set_shader_parameter("mode_a", _slot_a_idx)
	_sky_shader_mat.set_shader_parameter("mode_b", _slot_b_idx)
	_ensure_env_sky()


## 把复用的 Sky 挂到 WorldEnvironment 上（幂等；对应旧 _apply_environment_hdr 的挂接）
func _ensure_env_sky() -> void:
	var environment := _environment()
	if environment == null:
		return
	_env_bound = environment.sky == _sky_cache
	if not _env_bound:
		environment.sky = _sky_cache
		environment.background_mode = Environment.BG_SKY


## 过渡推进（update_system 每帧调用）。静止时直接返回，立方图零开销。
func _advance_transition(delta: float) -> void:
	if not _use_sky_shader or _sky_shader_mat == null or _trans_t >= 1.0:
		return
	_trans_t = minf(_trans_t + delta / TRANSITION_TIME, 1.0)
	var k := smoothstep(0.0, 1.0, _trans_t)
	var target_pos := float(MODE_POS.get(_mode_target, 1.0))
	_sky_mode = lerpf(_sky_mode_from, target_pos, k)
	_env_blend = k
	_sky_shader_mat.set_shader_parameter("sky_mode", _sky_mode)
	_sky_shader_mat.set_shader_parameter("env_blend", _env_blend)
	if _trans_t >= 1.0:
		# 收尾：把 B 槽烘进 A 槽 —— 输出逐位不变，此后立方图恢复静态
		if _env_tex_b != null:
			_env_tex = _env_tex_b
			_env_energy = _env_energy_b
		_slot_a_idx = _slot_b_idx
		_env_blend = 0.0
		_sky_shader_mat.set_shader_parameter("base_sky", _env_tex)
		_sky_shader_mat.set_shader_parameter("base_energy", _env_energy)
		_sky_shader_mat.set_shader_parameter("mode_a", _slot_a_idx)
		_sky_shader_mat.set_shader_parameter("env_blend", 0.0)


func _load_hdr(m: int) -> Texture2D:
	var path: String = HDR.get(m, HDR[GameContent.LightMode.SUNSET])
	if not ResourceLoader.exists(path):
		push_warning("[SkySystem] 缺少 HDR：%s（环境反射保持上一档）" % path)
		return null
	var tex = _hdr_cache.get(path)
	if tex == null:
		tex = load(path)
		_hdr_cache[path] = tex
	return tex


## 环境反射与背景（IBL）：把对应 HDR 装进 WorldEnvironment 的 Sky。
##
## 仅兜底球体路径使用（Sky 着色器路径的 IBL 由 _apply_mode_sky 管理）。
## 这一层同时是**天空可见背景**与**镜面反射来源**，对应原版「天空与反射共用一个
## HDR 立方图」的结构；能量就是原版的 `scene.environmentIntensity`（.78/.40/.55）。
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
	var energy := float(ENV_INTENSITY.get(m, 0.5))
	if _pano_cache != null:
		_pano_cache.panorama = tex
		_pano_cache.energy_multiplier = energy
	# Sky / 材质只建一次并复用。
	# 之前每次切模式或切雨都 new 一对再赋给 environment.sky —— 换掉 Sky 对象会
	# 让引擎重算 IBL 辐照度立方体贴图，而 set_raining()/apply_mode() 会频繁调用这里。
	environment.sky = _sky_cache
	environment.background_mode = Environment.BG_SKY
	# 刻意不改 ambient_light_source：它由 LightingDirector 维护（当前是 SKY）


func _environment() -> Environment:
	if world != null and world.lighting != null and world.lighting.env_node != null:
		return world.lighting.env_node.environment
	return null


## 天空球跟随相机（保持永远在无限远）。
## ⚠️ 走 Sky 着色器时**没有球**：Sky 本身就是无限远的，这里只剩兜底路径要用。
func follow(cam_pos: Vector3) -> void:
	if sky_mesh != null:
		sky_mesh.global_position = cam_pos
	if night_mesh_ref != null:
		night_mesh_ref.global_position = cam_pos


func update_system(delta: float, focus: Vector3) -> void:
	# 光照档过渡推进（静止时零开销，立方图不会重渲）
	_advance_transition(delta)
	# 启动顺序兜底：sky.setup 早于 lighting.setup，首次挂接可能失败；
	# 未绑定成功前每帧重试（成功后 _env_bound=true，零开销）
	if not _env_bound:
		_ensure_env_sky()
	follow(focus)
