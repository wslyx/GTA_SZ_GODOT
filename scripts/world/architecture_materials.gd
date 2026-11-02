extends Node3D
class_name ArchitectureMaterials
##
## 建筑立面材质 —— 逐行移植原版 src/city-architecture-materials.ts。
##
## 原版用 28 个 PBR profile（`PROFILES`）按「材质角色」给普通楼体与地标换材质：
##   ORDINARY：office / residential / stone / concrete / roof / darkglass→橱窗 /
##             steel / silver
##   GLASS   ：tencent / kk100 / pingan / diwang / mixc-world / qijie-gongguan /
##             fortune-plaza / bamboo / civic，再按角色细分出 window / render /
##             ribs / band / champagne 等
##
## 本文件与原文的关键结构一致：**按 profile 键共享材质**（键 = profileId，
## 带贴图的再分 `:uv` / `:solid`），所以材质总数被压在 31 个以内 —— 也就是原版
## stats 里的 `materialBudget: 31`。普通楼体有 16089 个、区块文件 1464 个，
## 若按"源材质"建材质会直接爆掉。
##
## ⚠️ 与原版无对应的一项：`profile.environment`（Babylon 的 environmentIntensity）。
## Godot 的 StandardMaterial3D 没有这个属性，直接跳过 —— 这也是 README 里
## "建筑比原版亮约 1.7 倍"之所以还在的原因之一。
##
## 贴图：3 组（curtain-glass / warm-residential / light-stone）各一张 512² 反照率
## + 一张 256² 的 `<kind>-windows.png` 窗格掩码。掩码挂到 `emission_texture`，
## 白天不发光、黄昏 ×.45、夜里 ×1.35（原版 emissiveIntensity）。

const ARCH := "res://data/city/textures/architecture/"
## 原版 TEXTURE_URLS
const TEXTURE_URLS := {
	"curtain-glass": "curtain-glass.png",
	"warm-residential": "warm-residential.png",
	"light-stone": "light-stone.png",
}
## 原版 PROFILES（28 项，颜色是**线性**美术参数，不要再做 sRGB 解码）
const PROFILES := {
	"city-office": {"color": Color(0.80, 0.88, 0.94), "roughness": 0.33, "metallic": 0.035,
		"texture": "curtain-glass", "environment": 1.05},
	"city-residential": {"color": Color(0.97, 0.94, 0.88), "roughness": 0.72, "metallic": 0.0,
		"texture": "warm-residential"},
	"city-stone": {"color": Color(0.93, 0.92, 0.89), "roughness": 0.79, "metallic": 0.0,
		"texture": "light-stone"},
	"city-concrete": {"color": Color(0.72, 0.69, 0.63), "roughness": 0.84, "metallic": 0.0},
	"city-roof": {"color": Color(0.25, 0.28, 0.29), "roughness": 0.88, "metallic": 0.0},
	"city-shopfront": {"color": Color(0.28, 0.36, 0.39), "roughness": 0.34, "metallic": 0.025},
	"city-steel": {"color": Color(0.43, 0.49, 0.53), "roughness": 0.46, "metallic": 0.66},
	"city-silver": {"color": Color(0.67, 0.70, 0.70), "roughness": 0.43, "metallic": 0.64},
	"tencent-glass": {"color": Color(0.20, 0.31, 0.36), "roughness": 0.38, "metallic": 0.035,
		"environment": 0.85},
	"tencent-window": {"color": Color(0.13, 0.21, 0.25), "roughness": 0.36, "metallic": 0.025,
		"environment": 0.85},
	"tencent-champagne": {"color": Color(0.55, 0.51, 0.43), "roughness": 0.44, "metallic": 0.56},
	"kk100-glass": {"color": Color(0.55, 0.67, 0.75), "roughness": 0.29, "metallic": 0.04,
		"environment": 1.05},
	"pingan-glass": {"color": Color(0.61, 0.66, 0.69), "roughness": 0.31, "metallic": 0.055,
		"environment": 1.08},
	"diwang-glass": {"color": Color(0.38, 0.61, 0.57), "roughness": 0.31, "metallic": 0.03,
		"environment": 1.04},
	"mixc-glass": {"color": Color(0.60, 0.67, 0.70), "roughness": 0.37, "metallic": 0.025},
	"qijie-glass": {"color": Color(0.39, 0.48, 0.54), "roughness": 0.35, "metallic": 0.025},
	"fortune-glass": {"color": Color(0.38, 0.55, 0.66), "roughness": 0.34, "metallic": 0.03},
	"fortune-window": {"color": Color(0.26, 0.38, 0.46), "roughness": 0.32, "metallic": 0.02},
	"bamboo-glass": {"color": Color(0.44, 0.62, 0.66), "roughness": 0.30, "metallic": 0.04},
	"bamboo-ribs": {"color": Color(0.72, 0.76, 0.77), "roughness": 0.40, "metallic": 0.67,
		"line_emission": Color(0.78, 0.90, 1.0)},
	"recess-glass": {"color": Color(0.28, 0.35, 0.40), "roughness": 0.34, "metallic": 0.02},
	"qijie-render": {"color": Color(0.66, 0.68, 0.67), "roughness": 0.78, "metallic": 0.0},
	"neutral-concrete": {"color": Color(0.73, 0.74, 0.72), "roughness": 0.81, "metallic": 0.0},
	"fortune-band": {"color": Color(0.83, 0.85, 0.84), "roughness": 0.42, "metallic": 0.46},
	"brushed-aluminum": {"color": Color(0.72, 0.76, 0.77), "roughness": 0.40, "metallic": 0.67},
	"landmark-steel": {"color": Color(0.47, 0.53, 0.56), "roughness": 0.43, "metallic": 0.69},
	"landmark-stone": {"color": Color(0.79, 0.77, 0.71), "roughness": 0.77, "metallic": 0.0},
	"civic-gold": {"color": Color(0.68, 0.50, 0.30), "roughness": 0.47, "metallic": 0.53},
}
## 原版 ORDINARY
const ORDINARY := {
	"office": "city-office", "residential": "city-residential", "stone": "city-stone",
	"concrete": "city-concrete", "roof": "city-roof", "darkglass": "city-shopfront",
	"steel": "city-steel", "silver": "city-silver",
}
## 原版 GLASS
const GLASS := {
	"tencent": "tencent-glass", "kk100": "kk100-glass", "pingan": "pingan-glass",
	"diwang": "diwang-glass", "mixc-world": "mixc-glass", "qijie-gongguan": "qijie-glass",
	"fortune-plaza": "fortune-glass", "bamboo": "bamboo-glass", "civic": "recess-glass",
}
## 普通楼体的网格名前缀（原版 `/^(?:block|facade)_-?\d+_-?\d+_/`）
const ORDINARY_MESH_RE := "^(?:block|facade)_-?\\d+_-?\\d+_"
## 原版贴图尺寸闸门
const MAX_ALBEDO := 1024
const MAX_MASK := 256
## 区块是流式的，立面材质要长期补扫
const SCAN_INTERVAL := 1.5
## 建筑立面着色器（含逐材质环境光强度，StandardMaterial3D 表达不了）
const SHADER_PATH := "res://shaders/architecture_pbr.gdshader"
## 原版 `profile.environment ?? .96`
const DEFAULT_ENV := 0.96
## 立面多样性（原版 city-facade-diversity.ts）：整楼主题 + 图集窗格。
## 两张图集被所有 :fv 材质共享（原版 shared atlas），不加 draw call。
const FACADE_ATLAS_PATH := ARCH + "facade-atlas.png"
const FACADE_WINDOWS_PATH := ARCH + "facade-windows.png"
## 只对 buildings.glb 的 block_* 网格启用（原版 /^block_-?\d+_-?\d+_/）
const BLOCK_MESH_RE := "^block_-?\\d+_-?\\d+_"

# ---------------------------------------------------------------------------
# 分区染色（GTA化 §3.1）：按城市象限给楼体一个 tint（instance uniform，
# 材质数零增长）。中央不染色保持原版观感，四个分区各有身份：
#   东 = 金融（冷蓝白）／西 = 工业（灰暗去饱和）／北中带 = 老城暖砖／南中带 = 海滨
# ---------------------------------------------------------------------------
const CITY_EXTENT_X := 6788.1
const CITY_EXTENT_Z := 2604.89
const DISTRICT_TINTS := {
	"finance": Color(0.88, 0.94, 1.06),
	"old_town": Color(1.09, 0.97, 0.86),
	"waterfront": Color(1.02, 1.04, 0.97),
	"industrial": Color(0.82, 0.82, 0.80),
}
## 中央保护区（归一化半径内不染色）
const DISTRICT_CORE_X := 0.30
const DISTRICT_CORE_Z := 0.55
## 诊断计数：各分区已染色的 MeshInstance 数
var _district_counts := {"finance": 0, "old_town": 0, "waterfront": 0, "industrial": 0, "core": 0}

## 世界坐标 → 数据坐标（世界 z = -数据北，同 TrafficSystem 约定）→ 分区 tint。
## 中央区返回白色 = 不染（保持原版观感）；其余查表（线性 RGB，shader 里直接乘）。
static func district_tint_for(world_pos: Vector3) -> Color:
	var d := district_name_for(world_pos)
	return Color(1.0, 1.0, 1.0) if d == "core" else DISTRICT_TINTS[d]


static func district_name_for(world_pos: Vector3) -> String:
	var nx := world_pos.x / CITY_EXTENT_X
	var nz := -world_pos.z / CITY_EXTENT_Z
	if absf(nx) < DISTRICT_CORE_X and absf(nz) < DISTRICT_CORE_Z:
		return "core"
	if nx >= DISTRICT_CORE_X:
		return "finance"
	if nx <= -DISTRICT_CORE_X:
		return "industrial"
	return "old_town" if nz > 0.0 else "waterfront"



var world: CityWorld
var enabled := true

## 共享材质：key → ShaderMaterial（上限 31）
var _materials: Dictionary = {}
## kind → {albedo: Texture2D, mask: Texture2D}
var _slots: Dictionary = {}
var _shader: Shader = null
var _ordinary_re: RegEx = null
var _block_re: RegEx = null
var _mode := -1
var _scan_timer := 0.0
## 立面多样性图集（缺任一张则整体回退普通材质，同原版 shared.ready）
var _facade_atlas: Texture2D = null
var _facade_windows: Texture2D = null
## :fv 材质列表（set_mode 时同步 facade_night / facade_glow）
var _fv_materials: Array = []
var _stats := {"materials": 0, "assignments": 0, "withoutUV": 0, "retired": 0, "facadeVariety": 0}


func setup(p_world: CityWorld) -> void:
	world = p_world
	_ordinary_re = RegEx.new()
	_ordinary_re.compile(ORDINARY_MESH_RE)
	_block_re = RegEx.new()
	_block_re.compile(BLOCK_MESH_RE)
	if ResourceLoader.exists(SHADER_PATH):
		_shader = load(SHADER_PATH) as Shader
	if _shader == null:
		push_warning("[ArchMaterials] 缺少 %s，立面材质不套用" % SHADER_PATH)
	for kind in TEXTURE_URLS:
		var albedo := _load_texture(ARCH + str(TEXTURE_URLS[kind]), MAX_ALBEDO)
		var mask := _load_texture(ARCH + kind + "-windows.png", MAX_MASK)
		_slots[kind] = {"albedo": albedo, "mask": mask}
	# 立面多样性图集（1024²；任一缺失就回退普通材质——同原版 shared.ready）
	_facade_atlas = _load_texture(FACADE_ATLAS_PATH, MAX_ALBEDO)
	_facade_windows = _load_texture(FACADE_WINDOWS_PATH, MAX_ALBEDO)
	print("[ArchMaterials] 立面 profile %d 个 / 贴图组 %d（%s）"
		% [PROFILES.size(), _slots.size(), "齐" if _slots_ready("curtain-glass") else "缺"])
	_apply_all()
	print("[ArchMaterials] 接管网格 surface %d 个 / 共享材质 %d 个（预算 31 + 立面多样性 :fv 变体）/ 无 UV %d / 立面多样性 %d"
		% [_stats["assignments"], _materials.size(), _stats["withoutUV"], _stats["facadeVariety"]])
	# ⚠️ `"...%s" % 数组` 会把数组当成参数列表 → "not all arguments converted"。
	# 要套一层中括号，或先 str()。
	print("[ArchMaterials] 逐材质环境光强度 env_scale 取值：%s" % [str(_env_values())])


## 供诊断：列出实际生效的 env_scale 取值（原版 profile.environment ?? .96）
func _env_values() -> Array:
	var seen := {}
	for k in _materials:
		var m: ShaderMaterial = _materials[k]
		seen[snappedf(float(m.get_shader_parameter("env_scale")), 0.001)] = true
	var out: Array = seen.keys()
	out.sort()
	return out


## 原版的两道尺寸闸门：>1024 的反照率与 >256 的掩码都判为不合格，退回不换贴图
func _load_texture(path: String, max_size: int) -> Texture2D:
	if not ResourceLoader.exists(path):
		push_warning("[ArchMaterials] 缺少贴图 %s" % path)
		return null
	var tex := load(path) as Texture2D
	if tex == null:
		return null
	if tex.get_width() > max_size or tex.get_height() > max_size:
		push_warning("[ArchMaterials] %s 尺寸 %d×%d 超过 %d，按失败处理"
			% [path.get_file(), tex.get_width(), tex.get_height(), max_size])
		return null
	return tex


func _slots_ready(kind: String) -> bool:
	var slot: Dictionary = _slots.get(kind, {})
	return slot.get("albedo", null) != null and slot.get("mask", null) != null


# ---------------------------------------------------------------------------
# 逐条判定（原版 assetKind / sourceRole / profileFor）
# ---------------------------------------------------------------------------

## 原版 assetKind：普通楼体 / 地标 / 地标细节
static func _asset_kind(asset_name: String) -> String:
	var base := asset_name.get_file().get_basename().to_lower()
	if base == "buildings" or base == "facades":
		return "ordinary"
	if base == "landmarks" or base == "landmark-candidates":
		return "landmark"
	if base == "landmark-detail":
		return "detail"
	return ""


## 原版 sourceRole：材质名小写、剥掉 Godot 的 `.001` 后缀
static func _source_role(mat_name: String) -> String:
	var out := mat_name.to_lower()
	var dot := out.rfind(".")
	if dot > 0:
		var tail := out.substr(dot + 1)
		if tail.is_valid_int():
			out = out.substr(0, dot)
	return out


## 原版 profileFor（非静态：普通楼体的判据正则只编译一次）
func _profile_for(mesh_name: String, kind: String, role: String) -> String:
	if kind == "ordinary":
		if _ordinary_re.search(mesh_name) == null:
			return ""
		return str(ORDINARY.get(role, ""))
	# 细节文件里还有地形、步道和树；必须同时命中已知地标 id **与**白名单角色，
	# 否则会把植物一起染色。
	var prefix := "detail_" if kind == "detail" else "landmark_"
	if not mesh_name.begins_with(prefix):
		return ""
	var id := ""
	for candidate in GLASS:
		if mesh_name.begins_with(prefix + str(candidate) + "_"):
			id = str(candidate)
			break
	if id == "":
		return ""
	if role == "landmarkglass" or role == "office":
		return str(GLASS[id])
	if role == "darkglass":
		if id == "tencent":
			return "tencent-window"
		if id == "fortune-plaza":
			return "fortune-window"
		if id == "qijie-gongguan":
			return "qijie-glass"
		return "recess-glass"
	if role == "concrete":
		return "qijie-render" if id == "qijie-gongguan" else "neutral-concrete"
	if role == "silver":
		if id == "bamboo":
			return "bamboo-ribs"
		if id == "fortune-plaza":
			return "fortune-band"
		return "brushed-aluminum"
	if role == "steel":
		return "landmark-steel"
	if role == "stone":
		return "landmark-stone"
	if role == "gold":
		return "tencent-champagne" if id == "tencent" else "civic-gold"
	# 地标自带的屋顶系数与灯 / 市政红一律保留（原版 return null）
	return ""


# ---------------------------------------------------------------------------
# 材质
# ---------------------------------------------------------------------------

## 原版 materialFor：按 profile 键共享材质（不是按源材质！）
##
## ⚠️ 这里返回的是 **ShaderMaterial**，不是 StandardMaterial3D —— 因为
## `profile.environment` 只能靠 shader 的 `AO` 复刻（见 architecture_pbr.gdshader 头部）。
## facade=True 时建 `:fv` 变体：整楼主题 + 图集窗格（原版 facade-diversity 插件）。
func _material_for(src: StandardMaterial3D, id: String, has_uv: bool,
		facade: bool = false) -> ShaderMaterial:
	var profile: Dictionary = PROFILES.get(id, {})
	if profile.is_empty() or _shader == null:
		return null
	var tex_kind := str(profile.get("texture", ""))
	var textured := tex_kind != "" and has_uv
	var facade_ok := facade and _facade_atlas != null and _facade_windows != null
	var key := id
	if facade_ok:
		key = id + ":fv"
	elif tex_kind != "":
		key = id + (":uv" if textured else ":solid")
	if _materials.has(key):
		var cached: ShaderMaterial = _materials[key]
		if not facade_ok and textured \
				and not bool(cached.get_shader_parameter("use_albedo_tex")) \
				and src.albedo_texture != null:
			_attach_albedo(tex_kind, cached, src.albedo_texture)
		return cached
	var mat := ShaderMaterial.new()
	mat.resource_name = "architecture:" + key
	mat.shader = _shader
	var color: Color = profile["color"]
	# 实体玻璃 / 幕墙 / 橱窗：压暗底色 + 收紧粗糙度，天空菲涅尔才读得出来
	var solid_glazing := id.ends_with("glass") or id.ends_with("window") or id == "city-shopfront"
	var rough := float(profile["roughness"])
	var metal := float(profile["metallic"])
	if solid_glazing and not facade_ok:
		color = color * 0.42
		metal = 0.0
		rough = clampf(rough * 0.55, 0.14, 0.23)
	mat.set_shader_parameter("albedo_tint", color)
	mat.set_shader_parameter("uv_scale", Vector2(src.uv1_scale.x, src.uv1_scale.y))
	mat.set_shader_parameter("roughness_value", rough)
	mat.set_shader_parameter("metallic_value", metal)
	# 原版 `material.specularIntensity = 1`
	mat.set_shader_parameter("specular_value", 1.0)
	# 原版 disableBumpMap = true（之后才会由贴图流程重新打开）
	mat.set_shader_parameter("use_normal_tex", false)
	mat.set_shader_parameter("normal_depth", src.normal_scale)
	mat.set_shader_parameter("use_albedo_tex", false)
	mat.set_shader_parameter("use_emission_tex", false)
	mat.set_shader_parameter("emission_energy", 0.0)
	# 逐材质环境光强度（原版 `profile.environment ?? .96`）
	mat.set_shader_parameter("env_scale", float(profile.get("environment", DEFAULT_ENV)))
	if facade_ok:
		# 立面多样性：着色器内部吃图集（albedo/粗糙度/窗光全部由 UV2 主题决定）
		mat.set_shader_parameter("use_facade_variety", true)
		mat.set_shader_parameter("facade_atlas", _facade_atlas)
		mat.set_shader_parameter("facade_windows", _facade_windows)
		_apply_fv_mode(mat)
		_fv_materials.append(mat)
		_materials[key] = mat
		return mat
	if textured:
		_attach_albedo(tex_kind, mat, src.albedo_texture)
	_apply_night(mat, profile, tex_kind, textured)
	_materials[key] = mat
	return mat


## 立面多样性的光照档（原版 bindForSubMesh）：
## 夜 facade_night=1 / glow=(1,.08)；黄昏 night=0 / glow=(.55,.08)；白天 glow=0。
## glow.y 是窗光互反照增益（bounce，本版未搬，仅保留占位）。
func _apply_fv_mode(mat: ShaderMaterial) -> void:
	var night := _mode == GameContent.LightMode.NIGHT
	var day := _mode == GameContent.LightMode.DAY
	var gain := 0.0
	if not day:
		gain = 1.0 if night else 0.55
	mat.set_shader_parameter("facade_night", 1.0 if night else 0.0)
	mat.set_shader_parameter("facade_glow", Vector2(gain, 0.08))


## 原版 attachAlbedo：反照率 + 窗格掩码（掩码只在两个贴图都合格时才挂）
func _attach_albedo(kind: String, mat: ShaderMaterial, fallback: Texture2D) -> void:
	var slot: Dictionary = _slots.get(kind, {})
	var albedo: Texture2D = slot.get("albedo", null)
	var mask: Texture2D = slot.get("mask", null)
	if albedo != null:
		mat.set_shader_parameter("albedo_tex", albedo)
		mat.set_shader_parameter("use_albedo_tex", true)
	elif fallback != null:
		mat.set_shader_parameter("albedo_tex", fallback)
		mat.set_shader_parameter("use_albedo_tex", true)
	else:
		mat.set_shader_parameter("use_albedo_tex", false)
	if albedo != null and mask != null:
		mat.set_shader_parameter("emission_tex", mask)
		mat.set_shader_parameter("use_emission_tex", true)
	else:
		mat.set_shader_parameter("use_emission_tex", false)


## 原版 applyNight：白天 0 / 黄昏 .45 / 夜里 1.35；线发光 profile 用 0 / 1.2 / 2.8
func _apply_night(mat: ShaderMaterial, profile: Dictionary, tex_kind: String,
		textured: bool) -> void:
	var night := _mode == GameContent.LightMode.NIGHT
	var day := _mode == GameContent.LightMode.DAY
	if profile.has("line_emission"):
		mat.set_shader_parameter("emission_color", profile["line_emission"])
		mat.set_shader_parameter("use_emission_tex", false)
		mat.set_shader_parameter("emission_energy", 0.0 if day else (2.8 if night else 1.2))
		return
	var aligned := textured and tex_kind != "" \
		and bool(mat.get_shader_parameter("use_emission_tex"))
	if aligned:
		mat.set_shader_parameter("emission_color", Color(1.0, 0.94, 0.83))
		mat.set_shader_parameter("emission_energy", 0.0 if day else (1.35 if night else 0.45))
	else:
		# 只有与新反照率对齐的稀疏掩码才允许发光；旧图集一律不发光
		mat.set_shader_parameter("emission_energy", 0.0)


## 原版 setMode
func set_mode(mode: int) -> void:
	_mode = mode
	for key in _materials:
		var mat: ShaderMaterial = _materials[key]
		# ⚠️ 循环变量是 Variant，`var id := key` 推断不出来 —— 必须显式标类型
		var id: String = str(key)
		var colon: int = id.find(":")
		if colon > 0:
			id = id.substr(0, colon)
		var profile: Dictionary = PROFILES.get(id, {})
		if profile.is_empty():
			continue
		# 立面多样性材质的窗光由 facade_night/glow 驱动，不走旧发光路径
		if str(key).ends_with(":fv"):
			_apply_fv_mode(mat)
			continue
		var tex_kind := str(profile.get("texture", ""))
		_apply_night(mat, profile, tex_kind,
			bool(mat.get_shader_parameter("use_albedo_tex")))


# ---------------------------------------------------------------------------
# 套用
# ---------------------------------------------------------------------------

## 抓一棵子树里所有建筑网格。
##
## 用 `set_surface_override_material` 而不是改网格自带的材质资源：GLB 的材质是
## 跨 mesh 共享的，直接改会波及 road_surface.gd 的收集与其它同类网格。
func apply_meshes(root: Node, asset_name: String) -> int:
	if root == null:
		return 0
	var kind := _asset_kind(asset_name)
	if kind == "":
		return 0
	var n := 0
	# 立面多样性只认 buildings.glb 的 block_* 网格（原版 assetName 闸门）
	var fv_asset := kind == "ordinary" \
		and asset_name.get_file().get_basename().to_lower() == "buildings"
	for mi in GlbLoader.meshes_of(root):
		var mesh: Mesh = mi.mesh
		if mesh == null:
			continue
		# landmarks_root 下同时挂着 landmarks.glb / landmark-detail.glb /
		# landmark-candidates.glb，按网格名前缀就地分档
		var mesh_kind := kind
		if kind == "landmark" and mi.name.begins_with("detail_"):
			mesh_kind = "detail"
		var fv_mesh := fv_asset and _block_re.search(mi.name) != null
		# 分区染色（§3.1）：只染普通楼体/立面（landmark 有自己的独有配色）。
		# 必须在树里才能取 global_position；不在树就先不标 meta，下轮扫描再染。
		if kind == "ordinary" and not mi.has_meta("district_tinted") \
				and mi.is_inside_tree():
			var dn := district_name_for(mi.global_transform.origin)
			mi.set_meta("district_tinted", dn)
			if dn != "core":
				_district_counts[dn] = int(_district_counts[dn]) + 1
			else:
				_district_counts["core"] = int(_district_counts["core"]) + 1
			mi.set_instance_shader_parameter("district_tint",
				district_tint_for(mi.global_transform.origin))
		for s in mesh.get_surface_count():
			# 已经挂了 override 的 surface 一律不碰：既避免重复套用，也避免把
			# ground_field.gd 的屋顶 surface override 顶掉（它在更早的步骤里挂上）。
			if mi.get_surface_override_material(s) != null:
				continue
			var src := mesh.surface_get_material(s) as StandardMaterial3D
			if src == null:
				continue
			var role := _source_role(str(src.resource_name))
			var id := _profile_for(mi.name, mesh_kind, role)
			if id == "":
				continue
			# `BitField[ArrayFormat]` 与常量做位与后的类型推断不出来，显式转 int
			var fmt: int = int(mesh.surface_get_format(s))
			var has_uv: bool = (fmt & Mesh.ARRAY_FORMAT_TEX_UV) != 0
			# UV2 才有 主题/种子 输入；同网格里 office/residential 带、
			# concrete/darkglass 不带（已实测），按 surface 就地分档
			var has_uv2: bool = (fmt & Mesh.ARRAY_FORMAT_TEX_UV2) != 0
			var mat := _material_for(src, id, has_uv, fv_mesh and has_uv2)
			if mat == null:
				continue
			mi.set_surface_override_material(s, mat)
			_stats["assignments"] = int(_stats["assignments"]) + 1
			if fv_mesh and has_uv2:
				_stats["facadeVariety"] = int(_stats["facadeVariety"]) + 1
			if not has_uv and str(PROFILES[id].get("texture", "")) != "":
				_stats["withoutUV"] = int(_stats["withoutUV"]) + 1
			n += 1
	_stats["materials"] = _materials.size()
	return n


func _apply_all() -> void:
	if world == null:
		return
	if _mode < 0:
		_mode = GameState.light_mode
	apply_meshes(world.chunks_root, "buildings")
	apply_meshes(world.buildings_root, "buildings")
	apply_meshes(world.facades_root, "facades")
	apply_meshes(world.landmarks_root, "landmarks")


func update_system(delta: float, focus: Vector3) -> void:
	if not enabled or world == null:
		return
	# 光照档变了要重刷发光
	if GameState.light_mode != _mode:
		set_mode(GameState.light_mode)
	# 区块 / 立面瓦片是流式的，新出现的建筑要持续接管
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = SCAN_INTERVAL
		_apply_all()


func diagnostics() -> Dictionary:
	return {
		"profiles": PROFILES.size(),
		"materials": _materials.size(),
		"materialBudget": 31,
		"districts": _district_counts.duplicate(),
		"facadeVariety": {
			"ready": _facade_atlas != null and _facade_windows != null,
			"materials": _fv_materials.size(),
			"assignments": _stats["facadeVariety"],
		},
		"textureGroups": _slots.size(),
		"texturesReady": _slots_ready("curtain-glass"),
		"mode": _mode,
		"stats": _stats,
	}
