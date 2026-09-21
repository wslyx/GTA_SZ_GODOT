extends Node
##
## 画质档位管理（autoload: GraphicsQuality）。
## 一比一对应原版 src/city-graphics-quality.ts 的三档参数与切档行为。
##
## 原版切档会重建阴影尺寸、镜面尺寸、挂/卸 SSAO、调整植被与剔除预算；
## Godot 里对应：DirectionalLight3D.shadow_enabled / shadow_bias、
## ReflectionProbe 尺寸、WorldEnvironment 的 SSAO、以及各系统的可见半径与实例预算。

signal tier_changed(tier: String)

const TIERS := ["low", "medium", "high"]

## 原版 PROFILE 表
const PROFILES := {
	"low": {
		"max_pixels": Vector2i(1600, 900),
		"shadow_size": 1024,
		"ao": false,
		"ao_samples": 4,
		"mirror_size": 256,
		"msaa": 1,
		"bloom_scale": 0.25,
		"lens_effects": false,
		"detail_scale": 0.5,
		"near_trees": 18,
		"canopy_full": 20,
	},
	"medium": {
		"max_pixels": Vector2i(1920, 1080),
		"shadow_size": 2048,
		"ao": true,
		"ao_samples": 4,
		"mirror_size": 384,
		"msaa": 2,
		"bloom_scale": 0.5,
		"lens_effects": false,
		"detail_scale": 0.75,
		"near_trees": 36,
		"canopy_full": 36,
	},
	"high": {
		"max_pixels": Vector2i(1920, 1080),
		"shadow_size": 2048,
		"ao": true,
		"ao_samples": 8,
		"mirror_size": 512,
		"msaa": 4,
		"bloom_scale": 0.5,
		"lens_effects": true,
		"detail_scale": 1.0,
		"near_trees": 48,
		"canopy_full": 56,
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


func _ready() -> void:
	_tier = GameState.graphics_tier if TIERS.has(GameState.graphics_tier) else "medium"


func tier() -> String:
	return _tier


## 当前档位的参数表。
##
## 注意：不能写 `var p := PROFILES[_tier]` —— `PROFILES` 是 const 字典，
## 下标取值返回 Variant，`:=` 无法推断类型（Godot 会报
## "Cannot infer the type of p variable"）。所有从字典取值的地方都要显式标注类型。
func profile() -> Dictionary:
	return PROFILES[_tier]


func p(key: String, fallback = null) -> Variant:
	return PROFILES[_tier].get(key, fallback)


func set_tier(t: String) -> void:
	if not TIERS.has(t) or t == _tier:
		return
	_tier = t
	GameState.graphics_tier = t
	SaveSystem.save_graphics_quality(t)
	apply_resolution_scale()
	tier_changed.emit(t)


func cycle() -> String:
	var i := TIERS.find(_tier)
	set_tier(TIERS[(i + 1) % TIERS.size()])
	return _tier


## 分辨率缩放：原版 min(dpr, 1.5, sqrt(maxPixels / (w*h)))，再 setHardwareScalingLevel(1/ratio)。
## Godot 对应 Viewport.scaling_3d_scale。
func apply_resolution_scale() -> void:
	var vp := get_viewport()
	if vp == null:
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


## 把档位参数套到世界节点上。world 需提供 light / environment 等引用。
func apply_to_world(world: Node) -> void:
	if world == null:
		return
	var p: Dictionary = PROFILES[_tier]
	if world.has_method("on_quality_changed"):
		world.on_quality_changed(p)
	apply_resolution_scale()
