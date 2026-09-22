extends Node
##
## 画质档位管理（autoload: GraphicsQuality）。
## 一比一对应原版 src/city-graphics-quality.ts 的三档参数与切档行为。
##
## 原版切档会重建阴影尺寸、镜面尺寸、挂/卸 SSAO、调整植被与剔除预算；
## Godot 里对应：DirectionalLight3D.shadow_enabled / shadow_bias、
## ReflectionProbe 尺寸、WorldEnvironment 的 SSAO、以及各系统的可见半径与实例预算。
##
## 用户逐项设置（CS2 风格）：overrides 里存玩家手动改过的项，优先级高于
## 当前档位的默认值。preset 预设行会清空 overrides（选预设 = 重置高级选项）。

signal tier_changed(tier: String)

const TIERS := ["low", "medium", "high"]

## 渲染缩放的档位表（settings 面板与 overrides 共用）
const SCALING_STEPS := [0.5, 0.65, 0.75, 0.88, 1.0, 1.25, 1.5]

## 逐项设置的可选值表（下标即选项序号）
const SHADOW_STEPS := [
	{"label": "关", "size": 1024, "splits": 0},
	{"label": "低 (1024)", "size": 1024, "splits": 2},
	{"label": "高 (2048)", "size": 2048, "splits": 4},
]
const LAMP_STEPS := [8, 16, 24]
const TREE_STEPS := [4000, 9000, 16000]
## 曝光补偿档位（乘在 tonemap_exposure 上）
const EXPOSURE_STEPS := [0.7, 0.85, 1.0, 1.15, 1.3]

## 原版 PROFILE 表
## shadows：0 关 / 1 低（1024, 2-split）/ 2 高（2048, 4-split）
## lamps：夜间路灯池数量；tree_budget：林冠重建实例预算
const PROFILES := {
	"low": {
		"max_pixels": Vector2i(1600, 900),
		"shadow_size": 1024,
		"shadows": 1,
		"ao": false,
		"ao_samples": 4,
		"mirror_size": 256,
		"msaa": 1,
		"bloom_scale": 0.25,
		"lens_effects": false,
		"detail_scale": 0.5,
		"near_trees": 18,
		"canopy_full": 20,
		"lamps": 8,
		"tree_budget": 4000,
	},
	"medium": {
		"max_pixels": Vector2i(1920, 1080),
		"shadow_size": 2048,
		"shadows": 2,
		"ao": true,
		"ao_samples": 4,
		"mirror_size": 384,
		"msaa": 2,
		"bloom_scale": 0.5,
		"lens_effects": false,
		"detail_scale": 0.75,
		"near_trees": 36,
		"canopy_full": 36,
		"lamps": 24,
		"tree_budget": 9000,
	},
	"high": {
		"max_pixels": Vector2i(1920, 1080),
		"shadow_size": 2048,
		"shadows": 2,
		"ao": true,
		"ao_samples": 8,
		"mirror_size": 512,
		"msaa": 4,
		"bloom_scale": 0.5,
		"lens_effects": true,
		"detail_scale": 1.0,
		"near_trees": 48,
		"canopy_full": 56,
		"lamps": 24,
		"tree_budget": 16000,
	},
}

## 高空特效阈值（原版 125m / 165m）
const AERIAL_TRIGGER_HEIGHT := 125.0
const AERIAL_RELEASE_HEIGHT := 165.0
const SHADOW_ORTHO_NORMAL := 260.0
const SHADOW_ORTHO_AERIAL := 1050.0
const SHADOW_MAX_Z_NORMAL := 1200.0
const SHADOW_MAX_Z_AERIAL := 3200.0

var _tier := "medium"
## 玩家手动改过的设置（覆盖档位默认）。键：
##   scaling: float        渲染缩放 0.35–1.5
##   aa: int               0 关 / 1 FXAA
##   shadows: int          0 关 / 1 低 / 2 高（下标进 SHADOW_STEPS）
##   ao / bloom: bool      SSAO / Bloom 开关
##   lamps: int            夜间路灯池数量
##   tree_budget: int      林冠实例预算
##   exposure: float       曝光补偿（乘在 tonemap_exposure 上）
##   fps: bool             帧率显示
var overrides := {}


func _ready() -> void:
	# 从存档拉取档位 + 逐项覆盖（SaveSystem 只返回数据，不反向引用本类，
	# 避免 autoload 循环引用）。方向永远是 GraphicsQuality → SaveSystem。
	var d := SaveSystem.load_graphics_quality()
	overrides = d.get("overrides", {})
	var t := str(d.get("tier", "medium"))
	if TIERS.has(t):
		GameState.graphics_tier = t
		_tier = t
	apply_aa()


## 曝光补偿系数（设置页可调；光照 apply_mode 每次套用时乘上去）
func exposure_scale() -> float:
	return clampf(float(overrides.get("exposure", 1.0)), 0.5, 1.6)


## 最近的曝光补偿档位下标（设置页高亮当前值用）
func exposure_step_index() -> int:
	var cur := exposure_scale()
	var best := 2
	var best_d := INF
	for i in EXPOSURE_STEPS.size():
		var d2: float = absf(float(EXPOSURE_STEPS[i]) - cur)
		if d2 < best_d:
			best_d = d2
			best = i
	return best


func tier() -> String:
	return _tier


## 当前档位的参数表。
##
## 注意：不能写 `var p := PROFILES[_tier]` —— `PROFILES` 是 const 字典，
## 下标取值返回 Variant，`:=` 无法推断类型（Godot 会报
## "Cannot infer the type of p variable"）。所有从字典取值的地方都要显式标注类型。
func profile() -> Dictionary:
	return PROFILES[_tier]


## 档位默认 + 玩家覆盖后的**生效参数表**。
## 所有实际下发到渲染 / 子系统的路径都应该用这份。
func effective() -> Dictionary:
	var p: Dictionary = PROFILES[_tier].duplicate()
	for k in overrides:
		p[k] = overrides[k]
	return p


func p(key: String, fallback = null) -> Variant:
	return effective().get(key, fallback)


func set_override(key: String, value) -> void:
	overrides[key] = value


func clear_overrides() -> void:
	overrides.clear()


## 预设档位字串 → 选项下标（settings 面板用）
func tier_index() -> int:
	return TIERS.find(_tier)


## 当前渲染缩放：手动覆盖优先；否则按档位 max_pixels 与窗口大小推。
func current_scaling() -> float:
	if overrides.has("scaling"):
		return clampf(float(overrides["scaling"]), 0.35, 1.5)
	var win := DisplayServer.window_get_size()
	var entry: Dictionary = PROFILES[_tier]
	var max_px: Vector2i = entry["max_pixels"]
	var area := float(win.x * win.y)
	if area <= 0.0:
		return 1.0
	var cap := sqrt(float(max_px.x * max_px.y) / area)
	return clampf(minf(1.5, cap), 0.35, 1.0)


## 最近的缩放档位下标（settings 面板高亮当前值用）
func scaling_step_index() -> int:
	var cur := current_scaling()
	var best := 0
	var best_d := INF
	for i in SCALING_STEPS.size():
		var d: float = absf(float(SCALING_STEPS[i]) - cur)
		if d < best_d:
			best_d = d
			best = i
	return best


func set_tier(t: String) -> void:
	if not TIERS.has(t) or t == _tier:
		return
	_tier = t
	GameState.graphics_tier = t
	SaveSystem.save_graphics_quality(_tier, overrides)
	apply_resolution_scale()
	apply_aa()
	tier_changed.emit(t)


func cycle() -> String:
	var i := TIERS.find(_tier)
	set_tier(TIERS[(i + 1) % TIERS.size()])
	return _tier


## 分辨率缩放：原版 min(dpr, 1.5, sqrt(maxPixels / (w*h)))，再 setHardwareScalingLevel(1/ratio)。
## Godot 对应 Viewport.scaling_3d_scale。手动覆盖（overrides.scaling）优先。
func apply_resolution_scale() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	if overrides.has("scaling"):
		vp.scaling_3d_scale = clampf(float(overrides["scaling"]), 0.35, 1.5)
		return
	var win := DisplayServer.window_get_size()
	# 显式标注类型：字典下标返回 Variant
	var entry: Dictionary = PROFILES[_tier]
	var max_px: Vector2i = entry["max_pixels"]
	var area := float(win.x * win.y)
	var ratio := 1.0
	if area > 0.0:
		var cap := sqrt(float(max_px.x * max_px.y) / area)
		ratio = minf(1.5, cap)
	ratio = clampf(ratio, 0.35, 1.0)
	vp.scaling_3d_scale = ratio


## 抗锯齿：项目层已弃 MSAA 改 FXAA，这里在**视口级**给玩家开关
## （ViewPort.screen_space_aa 是运行时属性，改了立即生效）。
func apply_aa() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var want_fxaa := int(overrides.get("aa", 1)) == 1
	vp.screen_space_aa = (Viewport.SCREEN_SPACE_AA_FXAA if want_fxaa
		else Viewport.SCREEN_SPACE_AA_DISABLED)


## 把生效参数套到世界节点上。world 需提供 light / environment 等引用。
func apply_to_world(world: Node) -> void:
	if world == null:
		return
	var p := effective()
	if world.has_method("on_quality_changed"):
		world.on_quality_changed(p)
	apply_resolution_scale()
	apply_aa()


## 持久化（设置页每次改动都会调）
func save() -> void:
	SaveSystem.save_graphics_quality(_tier, overrides)
