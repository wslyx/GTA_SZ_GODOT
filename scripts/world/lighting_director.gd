extends Node3D
##
## 光照导演 —— 对应原版 src/city-cinematic.ts 的 CINEMATIC_LOOK + city-local-lighting.ts
## + city-public-lighting.ts。
##
## 三档光照的参数是**逐字抄的**原版常量（见 CINEMATIC_LOOK），不是调出来的近似值。
## 原版 setMode() 直接赋值、不做插值；这里保持一致，切换是瞬时的。
##
## 局部照明：原版用 2 个池化 SpotLight 扫描相机附近路灯，另有 ~600 盏 OmniLight。
## 这里用 Godot 的 OmniLight3D 池（按距离分配最近灯位）实现同样效果：
## 每帧/每 0.4s 重扫一次，把池中的灯分配给最近的灯位，避免创建上千个光源节点。

# ---------------------------------------------------------------------------
# CINEMATIC_LOOK（原版 city-cinematic.ts:74-84 的数值，逐字照抄）
# ---------------------------------------------------------------------------
const LOOK := {
	GameContent.LightMode.SUNSET: {
		"sun_energy": 1.4,
		"sun_color": Color(1.00, 0.60, 0.33),
		"hemi_energy": 0.12,
		"hemi_sky": Color(0.55, 0.62, 0.95),
		"hemi_ground": Color(0.20, 0.16, 0.17),
		"environment": 0.40,
		"fog_density": 0.00011,
		"fog_color": Color(0.44, 0.27, 0.31),
		"exposure": 0.78,
		"contrast": 1.09,
		"bloom_threshold": 1.35,
		"bloom_weight": 0.19,
		"bloom_kernel": 56.0,
		## 阴影色相/密度/饱和（ColorCurves 分离调色）
		"shadow_hue": 235.0, "shadow_density": 0.28, "shadow_sat": -0.06,
		"highlight_hue": 32.0, "highlight_density": 0.18,
		## 太阳方向（数据坐标 east/north/up），原版 sunset = normalize(.95,-.19,.31)
		"sun_dir_data": Vector3(0.934, -0.187, 0.305),
	},
	GameContent.LightMode.NIGHT: {
		"sun_energy": 0.30,
		"sun_color": Color(0.70, 0.79, 1.00),
		"hemi_energy": 0.08,
		"hemi_sky": Color(0.42, 0.50, 0.82),
		"hemi_ground": Color(0.06, 0.06, 0.09),
		"environment": 0.55,
		"fog_density": 0.00010,
		"fog_color": Color(0.055, 0.05, 0.095),
		"exposure": 0.83,
		"contrast": 1.09,
		"bloom_threshold": 1.30,
		"bloom_weight": 0.24,
		"bloom_kernel": 56.0,
		"shadow_hue": 225.0, "shadow_density": 0.30, "shadow_sat": -0.10,
		"highlight_hue": 45.0, "highlight_density": 0.10,
		## 原版 night = -CITY_MOON_DIRECTION，CITY_MOON_DIRECTION = normalize(.72,.48,-.5)
		"sun_dir_data": Vector3(-0.720, -0.480, 0.500),
	},
	GameContent.LightMode.DAY: {
		"sun_energy": 3.0,
		"sun_color": Color(1.00, 0.91, 0.78),
		"hemi_energy": 0.28,
		"hemi_sky": Color(0.74, 0.80, 0.94),
		"hemi_ground": Color(0.30, 0.27, 0.22),
		"environment": 0.78,
		"fog_density": 0.000045,
		"fog_color": Color(0.57, 0.70, 0.84),
		"exposure": 0.74,
		"contrast": 1.10,
		"bloom_threshold": 2.5,
		"bloom_weight": 0.045,
		"bloom_kernel": 36.0,
		"shadow_hue": 215.0, "shadow_density": 0.05, "shadow_sat": 0.03,
		"highlight_hue": 42.0, "highlight_density": 0.02,
		## 白天太阳方向由 HDR 太阳向量绕 Y 转 -1.85 后取负
		"sun_dir_data": Vector3(0.833, -0.474, -0.286),
	},
}

## 路灯（city-local-lighting.ts）
const LAMP_RANGE := 46.0
const LAMP_ANGLE := 2.6
const LAMP_COLOR := Color(1.0, 0.82, 0.61)
const LAMP_NIGHT_ENERGY := 600.0
const LAMP_DUSK_ENERGY := 60.0
const LAMP_ROAD_HEIGHT := 8.27
const LAMP_PARK_HEIGHT := 11.56
const LAMP_FULL_DISTANCE := 30.0
const LAMP_END_DISTANCE := 72.0
const LAMP_LATERAL := 1.5

## —— 光照强度单位换算（实测标定）——
## LOOK 表里的数值是 Babylon 的光照单位，直接搬进 Godot 后总入光量严重超标：
## 实测白天 mean 亮度 0.79、46% 像素过曝（>0.95），路面接近纯白；
## 黄昏路面被太阳镜面反射糊成一片白斑。按「反照率 0.75 的表面落在
## ACES 输出 ~0.8」重新标定：太阳 ×0.55、半球环境 ×2.2（原 ×4）。
const SUN_ENERGY_SCALE := 0.55
const AMBIENT_ENERGY_SCALE := 2.2

## 池大小：原版是 2 个 SpotLight 轮转；Godot 里给多一点让近处路灯都能亮
const LAMP_POOL := 24

var world: CityWorld
var sun: DirectionalLight3D
var env_node: WorldEnvironment
var mode: int = GameContent.LightMode.SUNSET

var _lamps: Array = []                ## {pos: Vector3, height: float}
## 灯位空间索引：20409 个灯位全量扫一遍（每 0.4s）在 GDScript 里太重，
## 改成网格索引后每次只查半径内的那一小撮。
var _lamp_points := PackedVector2Array()
var _lamp_grid: PointGrid
var _lamp_pool: Array = []
var _scan_timer := 0.0
var _built := false
var lamp_lit := false
## 阴影绘制距离随街面/高空切换（原版 SHADOW_ORTHO_NORMAL 260 / AERIAL 1050）
const SHADOW_DIST_STREET := 260.0
const SHADOW_DIST_AERIAL := 1050.0
var _last_aerial_shadow := false
var _shadow_dist_ready := false


## 把阴影最大距离套到太阳上；只在切换时赋值，避免每帧重设触发阴影重画
func _apply_shadow_distance() -> void:
	if sun == null:
		return
	var aerial := world != null and world.aerial
	if _shadow_dist_ready and aerial == _last_aerial_shadow:
		return
	_last_aerial_shadow = aerial
	_shadow_dist_ready = true
	sun.directional_shadow_max_distance = SHADOW_DIST_AERIAL if aerial else SHADOW_DIST_STREET
	sun.directional_shadow_fade_start = 0.8
## 实际参与分配的灯数（低画质档会调小）。Forward+ 下每盏 OmniLight 都是
## 逐像素开销，24 盏铺满夜景城区并不便宜。
var _active_lamps := LAMP_POOL


func setup(p_world: CityWorld) -> void:
	world = p_world
	_create_environment()
	_create_sun()
	_load_lamps()
	_create_lamp_pool()
	_built = true
	apply_mode(mode)


# ---------------------------------------------------------------------------
# WorldEnvironment
# ---------------------------------------------------------------------------

func _create_environment() -> void:
	env_node = WorldEnvironment.new()
	env_node.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.fog_enabled = true
	env.ssao_enabled = true
	env.ssao_radius = 2.5
	env.ssao_intensity = 0.65
	env.ssao_detail = 0.1
	env.glow_enabled = true
	env_node.environment = env
	add_child(env_node)


func _create_sun() -> void:
	sun = DirectionalLight3D.new()
	sun.name = "city-sun"
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_blend_splits = true
	# 原版 shadow map 2048（low 1024），normalBias 街 .10 / 空中 .8
	sun.shadow_bias = 0.10
	sun.shadow_normal_bias = 1.0
	# 太阳镜面反射从默认 0.5 降到 0.35：路面在日落低角度下会被镜面高光
	# 糊成一片白斑（实测），漫反射亮度不受影响
	sun.light_specular = 0.35
	add_child(sun)


# ---------------------------------------------------------------------------
# 模式切换
# ---------------------------------------------------------------------------

func apply_mode(m: int) -> void:
	mode = m
	if not _built:
		return
	var look: Dictionary = LOOK.get(m, LOOK[GameContent.LightMode.SUNSET])
	var env := env_node.environment

	# 太阳：方向、颜色、强度
	var d: Vector3 = look["sun_dir_data"]
	# 数据 (east, up, north) → Godot (east, up, -north)
	var dir_world := Vector3(d.x, d.y, -d.z).normalized()
	# 基准点取世界原点即可：这里只需定方向，位置由 update_system() 每帧
	# 跟着视野中心调整（原版 sun.position = focus − dir*800）。
	# 不要写 get_parent().global_position —— get_parent() 返回 Node，
	# 上面没有 global_position，会退化成 Variant 导致推断失败。
	var origin := Vector3.ZERO
	sun.global_position = origin - dir_world * 800.0
	sun.look_at(origin, Vector3.UP)
	sun.light_color = look["sun_color"]
	sun.light_energy = float(look["sun_energy"]) * SUN_ENERGY_SCALE

	# 半球光 → Godot 的环境光（颜色取天空色，能量取半球强度 × 单位换算）
	env.ambient_light_color = look["hemi_sky"]
	env.ambient_light_energy = float(look["hemi_energy"]) * AMBIENT_ENERGY_SCALE
	env.ambient_light_sky_contribution = 0.0

	# 雾
	env.fog_enabled = true
	env.fog_light_color = look["fog_color"]
	# ⚠️ 这里原来写 `× 100.0`，是按"Godot 用线性指数、Babylon 用 EXP2"去换算的，
	# 但两种解释下原版数值都能直接对上：
	#   原版 FOGMODE_EXP2 density=0.00011 → 50% 雾约在 7570 m（城市对角约 7 km 量级）
	#   Godot exponential（exp2 或 exp）用同一个 0.00011 → 50% 雾约在 6.3~7.6 km
	# 乘 100 之后 50% 雾距离缩到 ~76 m —— 整座城市在百米外就被雾糊成一片，
	# 配合天空球的深度 bug，画面就只剩"天空色"。
	env.fog_density = float(look["fog_density"])
	env.fog_sky_affect = 0.0

	# 曝光 / 对比度（曝光补偿来自图像设置页，默认 1.0）
	env.tonemap_exposure = float(look["exposure"]) * GraphicsQuality.exposure_scale()
	env.adjustment_enabled = true
	env.adjustment_contrast = look["contrast"]
	env.adjustment_saturation = 1.0 + float(look["shadow_sat"]) * 0.5

	# Bloom
	env.glow_intensity = float(look["bloom_weight"]) * 2.0
	env.glow_hdr_threshold = float(look["bloom_threshold"])
	env.glow_bloom = 0.05
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE

	# 夜间：点亮路灯
	lamp_lit = m != GameContent.LightMode.DAY
	for l in _lamp_pool:
		l.visible = lamp_lit

	if world != null and world.sky != null and world.sky.has_method("apply_mode"):
		world.sky.apply_mode(m)


func cycle_mode() -> int:
	match mode:
		GameContent.LightMode.SUNSET: apply_mode(GameContent.LightMode.NIGHT)
		GameContent.LightMode.NIGHT: apply_mode(GameContent.LightMode.DAY)
		_: apply_mode(GameContent.LightMode.SUNSET)
	GameState.set_light_mode(mode)
	return mode


func set_quality(p: Dictionary) -> void:
	# —— 路灯池数量（设置页可调 8/16/24；低画质档默认 8）——
	var lamps := int(p.get("lamps", 8 if float(p.get("detail_scale", 1.0)) <= 0.5 else LAMP_POOL))
	_active_lamps = clampi(lamps, 0, LAMP_POOL)
	var env := env_node.environment
	env.ssao_enabled = bool(p.get("ao", true))
	# Bloom：显式开关（设置页）优先，回退到档位的 bloom_scale
	if p.has("bloom"):
		env.glow_enabled = bool(p["bloom"])
	else:
		env.glow_enabled = float(p.get("bloom_scale", 0.5)) > 0.0
	# —— 阴影：0 关 / 1 低（1024, 2-split）/ 2 高（2048, 4-split）——
	# （早期版本这里无条件 shadow_enabled = true，低档也跑 4-split 全尺寸
	# 阴影图，是 Forward+ 下最大的单项 GPU 开销之一。）
	if sun != null:
		var opt := clampi(int(p.get("shadows", 2)), 0, GraphicsQuality.SHADOW_STEPS.size() - 1)
		var step: Dictionary = GraphicsQuality.SHADOW_STEPS[opt]
		var splits: int = step["splits"]
		sun.shadow_enabled = splits > 0
		match splits:
			0:
				pass
			2:
				sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
				sun.directional_shadow_blend_splits = false
			4:
				sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
				sun.directional_shadow_blend_splits = true
		if splits > 0:
			# 阴影图集尺寸是引擎级设置（默认 4096），按档位降到 1024/2048
			RenderingServer.directional_shadow_atlas_set_size(int(step["size"]), true)
	# 阴影绘制距离：街面 260m / 高空 1050m（原版 SHADOW_ORTHO_*），比默认省一大截
	_apply_shadow_distance()


# ---------------------------------------------------------------------------
# 路灯池
# ---------------------------------------------------------------------------

func _load_lamps() -> void:
	_lamps.clear()
	var raw: Array = CityData.lamps()
	for e in raw:
		if e.size() < 4:
			continue
		var x := float(e[0])
		var z := float(e[1])
		var dx := float(e[2])
		var dz := float(e[3])
		# 原版：灯位 = 数据点 - 朝向 * 1.5
		var lx := x - dx * LAMP_LATERAL
		var lz := z - dz * LAMP_LATERAL
		_lamps.append({"pos": CoordinateUtil.to_world(lx, lz, LAMP_ROAD_HEIGHT), "height": LAMP_ROAD_HEIGHT})
	# 公园灯（coastal/infrastructure.json）
	for e in CityData.coastal_infrastructure.get("parkLights", []):
		var h := float(e.get("height", 12.0))
		_lamps.append({
			"pos": CoordinateUtil.to_world(float(e.get("x", 0.0)), float(e.get("z", 0.0)), h),
			"height": h,
		})
	# 建灯位网格索引：20409 个灯位全量扫太重
	_lamp_points.resize(_lamps.size())
	for i in _lamps.size():
		var p: Vector3 = _lamps[i]["pos"]
		_lamp_points[i] = Vector2(p.x, p.z)
	_lamp_grid = PointGrid.new(96.0)
	_lamp_grid.build(_lamp_points)
	print("[LightingDirector] 灯位 %d 个（道路灯 + 公园灯），网格单元 96m" % _lamps.size())


func _create_lamp_pool() -> void:
	for i in LAMP_POOL:
		var l := OmniLight3D.new()
		l.name = "lamp-%d" % i
		l.omni_range = LAMP_RANGE
		l.light_color = LAMP_COLOR
		l.light_energy = LAMP_NIGHT_ENERGY / 100.0
		# ⚠️ 原来前 4 盏开了阴影。点光源阴影是立方体/双抛物面贴图，
		# 一盏就要把半径 46m 内的所有几何重画一遍（双抛物面 2 个 pass），
		# 4 盏 = 每帧 8 次额外的深度 pass，夜景下直接吃掉十几毫秒。
		# 路灯离地 8m、照的是地面，有没有阴影在观感上几乎看不出来。
		l.shadow_enabled = false
		l.visible = false
		add_child(l)
		_lamp_pool.append(l)


## 把池中灯位分配给离焦点最近的若干个灯位（原版每 0.4s 扫一次）
func _assign_lamps(focus: Vector3) -> void:
	if _lamps.is_empty() or not lamp_lit:
		return
	# 网格索引：只取 LAMP_END_DISTANCE 内的灯位，不再全量扫 20409 个。
	# Vector2(idx, dist) 承载结果，不建临时字典。
	var scored: Array[Vector2] = []
	if _lamp_grid != null:
		scored = _lamp_grid.query_radius_sorted2(Vector2(focus.x, focus.z),
			LAMP_END_DISTANCE, _lamp_points)
	var n := mini(mini(_active_lamps, _lamp_pool.size()), scored.size())
	for i in _lamp_pool.size():
		var l: OmniLight3D = _lamp_pool[i]
		if i < n:
			var e: Vector2 = scored[i]
			var p: Vector3 = _lamps[int(e.x)]["pos"]
			l.global_position = p
			l.visible = true
			# 距离越远越弱（原版 full 30 / end 72 的线性过渡）
			var t: float = clamp((e.y - LAMP_FULL_DISTANCE) /
				maxf(LAMP_END_DISTANCE - LAMP_FULL_DISTANCE, 1.0), 0.0, 1.0)
			l.light_energy = lerpf(LAMP_NIGHT_ENERGY, LAMP_DUSK_ENERGY, t) / 100.0
		else:
			l.visible = false


func update_system(delta: float, focus: Vector3) -> void:
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = 0.4
		_assign_lamps(focus)
		_apply_shadow_distance()
	# 太阳跟随视野中心，保证阴影贴图覆盖玩家附近（原版 sun.position = p - dir*800）
	if sun != null:
		var look: Dictionary = LOOK.get(mode, LOOK[GameContent.LightMode.SUNSET])
		var d: Vector3 = look["sun_dir_data"]
		var dir_world := Vector3(d.x, d.y, -d.z).normalized()
		sun.global_position = focus - dir_world * 800.0
		sun.look_at(focus, Vector3.UP)


func diagnostics() -> Dictionary:
	return {
		"mode": mode,
		"lamps": _lamps.size(),
		"lampPool": _lamp_pool.size(),
		"lampLit": lamp_lit,
		"sunEnergy": sun.light_energy if sun != null else 0.0,
	}
