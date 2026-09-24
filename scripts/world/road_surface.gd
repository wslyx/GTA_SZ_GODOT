extends Node3D
class_name RoadSurface
##
## 沥青路面标定 —— 对应原版 src/city-road-surface.ts 的 `applyCinematicRoad`。
##
## 原版做三件事，本文件逐项照搬：
##
##   1. 只改材质名匹配 `/^asphalt(?:\.\d+)?$/` 的 PBR 材质；
##   2. 换反照率 / 镜面强度 / 环境强度（ROAD_LOOK 三档 + RAIN_ROAD_LOOK 三档）；
##   3. 把 ORM 贴图的**绿通道**当作真实粗糙度来源：
##        roughness = .83 + .12 * orm.g        （sunset / night）
##        roughness = .66 + .19 * orm.g        （day）
##
## ⚠️ 为什么必须做：`data/city/roads.glb` 自带的 asphalt 材质是
## `roughness=0.29 / metallic=0.18`，也就是**半金属镜面**。原版靠这一遍覆盖把它
## 压成 rough=0.92 / metallic=0 / specular=0.22 的漫反射沥青；移植版漏掉了这一步，
## 于是黄昏时路面把天空与太阳整个镜像回来 —— 实测路面区域 #fef3e8（纯白），
## 原版同一位置 #292021。
##
## 关于「不做逐像素 ORM 采样」：实测 asphalt-orm.webp 的绿通道
## mean 0.731 / p5 0.616 / p95 0.796，对应粗糙度区间只有 **0.904 ~ 0.926**
## （极差 0.022）。Godot 的 StandardMaterial3D 只能做 `roughness × texture.g`
## 乘法，无法表达 `a + b·g` 的仿射式，所以这里取区间中值 **0.918** 作为常量，
## 与逐像素结果的偏差不超过 0.012 —— 视觉上不可分辨。

## 原版 ROAD_LOOK（sunset / night 共用一档）
const LOOK := {
	GameContent.LightMode.DAY: {
		"albedo": Color(1.02, 1.03, 1.04), "specular": 0.55,
		"roughness": 0.803,   ## .66 + .19 × 0.731（ORM 绿通道均值）
	},
	GameContent.LightMode.SUNSET: {
		"albedo": Color(0.72, 0.76, 0.79), "specular": 0.22,
		"roughness": 0.918,   ## .83 + .12 × 0.731
	},
	GameContent.LightMode.NIGHT: {
		"albedo": Color(0.72, 0.76, 0.79), "specular": 0.22,
		"roughness": 0.918,
	},
}
## 原版 RAIN_ROAD_LOOK
const RAIN_LOOK := {
	GameContent.LightMode.DAY: {
		"albedo": Color(0.88, 0.91, 0.94), "specular": 0.72, "roughness": 0.478,
	},
	GameContent.LightMode.SUNSET: {
		"albedo": Color(0.70, 0.75, 0.79), "specular": 0.68, "roughness": 0.455,
	},
	GameContent.LightMode.NIGHT: {
		"albedo": Color(0.70, 0.75, 0.79), "specular": 0.68, "roughness": 0.455,
	},
}

## 原版 city-landscape.ts 的 `applyLandscapeSurfaces` 对 **roadline**（车道线）也有一套
## 参数：albedo (.59,.61,.57) / metallic 0 / roughness .85 / emissive 0。
## roads.glb 自带的是 albedo (0.896,0.901,0.854) / rough 0.54 —— 明显偏亮偏亮白，
## 在暗色沥青上会显得刺眼。这里一并照搬。
const ROADLINE_ALBEDO := Color(0.59, 0.61, 0.57)
const ROADLINE_ROUGHNESS := 0.85

## 原版 city-canopy.ts 对林冠材质的统一处理：
##   metallic 0 / roughness = max(.86, 原值) / specularIntensity .28
const CANOPY_SPECULAR := 0.28
const CANOPY_ROUGHNESS_FLOOR := 0.86

## 原版 city-world.ts 对跨海对岸（opposite-shore.glb）的单独处理：
##   albedoColor = (.10,.15,.14)，用来把对岸压成一条暗色剪影。
## 移植版漏了这步，`distant-shore` 保持 GLB 自带的 (.373,.461,.424)，
## 黄昏时在地平线上糊成一条明显偏亮偏灰绿的带。
const OPPOSITE_SHORE_MAT := "distant-shore"
const OPPOSITE_SHORE_ALBEDO := Color(0.10, 0.15, 0.14)

## 原版：UV_WORLD_PERIOD 14 / SCAN_GAME_METRES(= 2.35 × .60 = 1.41) = 9.93
const NORMAL_UV_SCALE := 9.93
## 原版 normal.level = NORMAL_STRENGTH = .13
const NORMAL_STRENGTH := 0.13
const NORMAL_PATH := "res://data/city/textures/road-cinematic/asphalt-normal-gl.webp"

var world: CityWorld
var mode: int = GameContent.LightMode.SUNSET
var raining := false

## 按材质名去重后的目标材质（GLB 材质是共享资源，同一份可能被多个 mesh 引用）
var _materials: Array[BaseMaterial3D] = []
var _roadline: Array[BaseMaterial3D] = []
var _canopy: Array[BaseMaterial3D] = []
var _shore: Array[BaseMaterial3D] = []
var _built := false


func setup(p_world: CityWorld) -> void:
	world = p_world
	_built = true


## 收集 asphalt / roadline / canopy 材质并套用当前档位。
## 必须在 terrain / roads / 植被都进场景之后调用。
func apply_now() -> int:
	_materials.clear()
	_roadline.clear()
	_canopy.clear()
	var seen := {}
	if world == null:
		return 0
	# 林冠挂在 ScenerySystem 自己身上（MultiMeshInstance3D 子节点），
	# 不在 scenery_root 下；跨海对岸（opposite-shore.glb）在 landmarks_root 下
	# —— 这几个根都要扫。
	var roots: Array = [world.roads_root, world.terrain_root, world.scenery_root,
		world.scenery, world.landmarks_root]
	for root in roots:
		if root == null:
			continue
		for mat in _collect_from(root):
			# 显式标注：`_collect_from` 返回的是无类型 Array，直接用 `:=` 推断
			# 会报 "Cannot infer the type of nm variable"。
			var nm: String = mat.resource_name
			var bucket := ""
			if _is_asphalt(nm):
				bucket = "_materials"
			elif nm == "roadline":
				bucket = "_roadline"
			elif nm == OPPOSITE_SHORE_MAT:
				bucket = "_shore"
			elif nm.begins_with("canopy_") or nm.begins_with("landscape_foliage"):
				bucket = "_canopy"
			if bucket == "":
				continue
			var rid: int = mat.get_instance_id()
			if seen.has(rid):
				continue
			seen[rid] = true
			match bucket:
				"_materials": _materials.append(mat)
				"_roadline": _roadline.append(mat)
				"_canopy": _canopy.append(mat)
				"_shore": _shore.append(mat)
	_apply_normal_map()
	_apply_canopy()
	_apply_look()
	print("[RoadSurface] asphalt %d / roadline %d / canopy %d / shore %d" % [
		_materials.size(), _roadline.size(), _canopy.size(), _shore.size()])
	return _materials.size() + _roadline.size() + _canopy.size() + _shore.size()


## 收集一棵子树里所有 BaseMaterial3D。
##
## 注意不能只用 `GlbLoader.meshes_of()` —— 它只认 MeshInstance3D，而林冠是
## **MultiMeshInstance3D**（40927 棵树共用几十个画布），材质挂在
## `multimesh.mesh` 的各个 surface 上，那是另一条路径。
func _collect_from(root: Node) -> Array[BaseMaterial3D]:
	var out: Array[BaseMaterial3D] = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mesh: Mesh = null
		var mi_override: Material = null
		if n is MeshInstance3D:
			mesh = (n as MeshInstance3D).mesh
		elif n is MultiMeshInstance3D:
			var mmi := n as MultiMeshInstance3D
			if mmi.multimesh != null:
				mesh = mmi.multimesh.mesh
			mi_override = mmi.material_override
		if mesh != null:
			for s in mesh.get_surface_count():
				var mat: Material = mesh.surface_get_material(s)
				if mat == null and n is MeshInstance3D:
					mat = (n as MeshInstance3D).get_active_material(s)
				if mat == null:
					mat = mi_override
				if mat is BaseMaterial3D:
					out.append(mat)
		for c in n.get_children():
			stack.append(c)
	return out


## 原版：/^asphalt(?:\.\d+)?$/
func _is_asphalt(name: String) -> bool:
	if not name.begins_with("asphalt"):
		return false
	var rest := name.substr(7)
	if rest == "":
		return true
	if not rest.begins_with("."):
		return false
	return rest.substr(1).is_valid_int()


func _apply_normal_map() -> void:
	if not ResourceLoader.exists(NORMAL_PATH):
		push_warning("[RoadSurface] 缺少法线贴图 %s" % NORMAL_PATH)
		return
	var tex: Texture2D = load(NORMAL_PATH)
	if tex == null:
		return
	for i in _materials.size():
		var b: BaseMaterial3D = _materials[i]
		b.normal_enabled = true
		b.normal_texture = tex
		b.normal_scale = NORMAL_STRENGTH
		# 原版 texture.uScale = UV_WORLD_PERIOD / SCAN_GAME_METRES
		b.uv1_scale = Vector3(NORMAL_UV_SCALE, NORMAL_UV_SCALE, 1.0)


func _apply_canopy() -> void:
	for i in _canopy.size():
		var b: BaseMaterial3D = _canopy[i]
		b.metallic = 0.0
		b.roughness = maxf(CANOPY_ROUGHNESS_FLOOR, b.roughness)
		b.metallic_specular = CANOPY_SPECULAR


func _apply_look() -> void:
	var table := RAIN_LOOK if raining else LOOK
	var look: Dictionary = table.get(mode, table[GameContent.LightMode.SUNSET])
	for i in _materials.size():
		var b: BaseMaterial3D = _materials[i]
		b.albedo_color = look["albedo"]
		b.roughness = float(look["roughness"])
		b.metallic = 0.0
		# Babylon 的 specularIntensity 直接对应 Godot 的 metallic_specular
		#（两者都是 F0 = 0.04 × 该值）
		b.metallic_specular = float(look["specular"])
	# 车道线不随光照/天气换档（原版只在 applyLandscapeSurfaces 里设一次）
	for i in _roadline.size():
		var b2: BaseMaterial3D = _roadline[i]
		b2.albedo_color = ROADLINE_ALBEDO
		b2.roughness = ROADLINE_ROUGHNESS
		b2.metallic = 0.0
		b2.emission_enabled = false
	# 跨海对岸：压成暗剪影（不随档位变）
	for i in _shore.size():
		_shore[i].albedo_color = OPPOSITE_SHORE_ALBEDO


func set_mode(m: int) -> void:
	mode = m
	if _built:
		_apply_look()


func set_weather(wet: bool) -> void:
	if raining == wet:
		return
	raining = wet
	if _built:
		_apply_look()


func diagnostics() -> Dictionary:
	var table := RAIN_LOOK if raining else LOOK
	return {
		"applied": _built,
		"materials": _materials.size(),
		"mode": mode,
		"raining": raining,
		"look": table.get(mode, table[GameContent.LightMode.SUNSET]),
	}
