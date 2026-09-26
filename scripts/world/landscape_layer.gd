extends Node3D
class_name LandscapeLayer
##
## 种植层 —— 逐行移植原版 src/city-landscape.ts 的 CityLandscape（Tree / Detail /
## RoadDetail 三层 + open-vegetation 替换）。
##
## ⚠️ 这一层与「林冠层」（scenery_system.gd 的 canopy）是**两套互不相干的树**。
## 实测本城数据：
##   planting.json   trees  7933 棵，[x, z, species, scale, yaw]，3 个树种
##   canopy-trees.json trees 40927 棵，[x, z, species, scale, yaw]，6 个树种
##   两者坐标集合**零重叠**（按 0.1m 取整比对，重合 0 个）。
## 也就是说原版同时画这两层；移植版只画了林冠层，把种植层整个漏掉了 ——
## 结果是「少了 7933 棵行道树 / 公园树」，以及下面这 6.4 万条细节。
##
## 三层内容：
##   trees        7933  → 落到 y = 地面 + 0.05，按 440m 半径 / 近 48 近端 + 220 远端预算
##   details     64010  → lawn-tuft / flower-shrub / fountain-grass，95m 内，
##                        预算 [520,110,120]×detailScale，总三角形 ≤ 15 万
##   roadDetails 16971  → drain-grate / manhole，70m 内取最近 28 个，
##                        落到 y = 地面 + 0.12（比其它高三公分，避免与路面 z-fighting）
##
## open-vegetation（A4）：原版把 planting.json 的 SHA-256 与
## open-vegetation/manifest.json 的 plantingSHA256 对账，命中后按
## eligibleIndices 把对应的树**换成** CC0 的 open-island-tree / open-palm。
## 本城哈希实测命中（95eeec54…dae5），合格 6261 / 7933 棵。

const BASE := "res://data/city/landscape/"
const OPEN_BASE := "res://data/city/open-vegetation/"

## 原版 TREE_NAMES / OPEN_TREE_NAMES / DETAIL_NAMES / ROAD_NAMES
const TREE_NAMES := ["banyan", "palm", "orchid-tree"]
const OPEN_TREE_NAMES := ["open-island-tree", "open-palm"]
const DETAIL_NAMES := ["lawn-tuft", "flower-shrub", "fountain-grass"]
const ROAD_NAMES := ["drain-grate", "manhole"]

## 原版 update() 的静止阈值：相机移动 < 22m 且未切空中 → 不重建
const REBUILD_MOVE := 22.0
## 细节：95m 半径（来自 3×3 个 100m 格），总三角形上限 15 万
const DETAIL_RADIUS := 95.0
const DETAIL_TRIANGLE_BUDGET := 150000
## 原版 `[520,110,120].map(n=>Math.floor(n*quality.detailScale))`
const DETAIL_CAPS := [520, 110, 120]
## 路面细节：70m 内最近的 28 个
const ROAD_RADIUS := 70.0
const ROAD_LIMIT := 28
## 近端树的最远距离（原版 `dist(p)<150*150`）
const NEAR_DIST := 150.0
## 空中视角下，开放植被回到普通树的距离（原版 550）
const OPEN_AERIAL_DIST := 550.0
## 近端 open-island-tree 的硬上限（原版 24）
const OPEN_NEAR_LIMIT := 24
## 落地抬升（原版 `ROAD_NAMES.includes(name) ? .12 : .05`）
const ROAD_LIFT := 0.12
const DETAIL_LIFT := 0.05

var world: CityWorld
var enabled := true

## 原型：name → {model: Dictionary, nodes: [{mm, local}]}
var _protos: Dictionary = {}
## 种植树数据：{x, z, species, scale, yaw, open}
var _trees: Array = []
var _tree_points := PackedVector2Array()
var _tree_grid: PointGrid
## 细节：{x, z, kind, scale, yaw}
var _details: Array = []
var _detail_points := PackedVector2Array()
var _detail_grid: PointGrid
var _detail_tris: Array = [0, 0, 0]
## 路面细节：{x, z, kind, scale, yaw}
var _road_details: Array = []
var _road_points := PackedVector2Array()
var _road_grid: PointGrid

## open-vegetation 对账结果
var _open_matched := false
var _open_eligible := 0
var _open_visible := 0

## 画质
var _near_trees := 48
var _far_trees := 220
var _aerial_trees := 1200
var _tree_radius := 440.0
var _aerial_tree_radius := 1200.0
var _detail_scale := 1.0

var _last_focus := Vector2.ZERO
var _has_focus := false
var _last_aerial := false
## 草叶层引用（只用来问"就绪了吗"，见 set_meadow）
var _meadow = null
var _built := false
## 最近一次统计，供 HUD/诊断用
var _stats := {"nearTrees": 0, "farTrees": 0, "lawnTufts": 0, "shrubs": 0,
	"ornamentalGrass": 0, "roadDetails": 0, "drawCalls": 0}


func setup(p_world: CityWorld) -> void:
	world = p_world
	_load_landscape()
	_built = true
	if world != null and not world.blocks.is_empty():
		# 首次布点用出生点，而不是 world.focus —— 构建期 set_focus() 还没被调用，
		# focus 还是世界原点（与 CityWorld 给区块/立面预载用 spawn_pos 同一个理由）。
		var sp := CityData.spawn_pos
		update_system(0.0, CoordinateUtil.to_world(sp.x, sp.y, 0.0))


func set_quality(p: Dictionary) -> void:
	_near_trees = int(p.get("near_trees", _near_trees))
	_far_trees = int(p.get("far_trees", _far_trees))
	_aerial_trees = int(p.get("aerial_trees", _aerial_trees))
	_tree_radius = float(p.get("tree_radius", _tree_radius))
	_aerial_tree_radius = float(p.get("aerial_tree_radius", _aerial_tree_radius))
	_detail_scale = float(p.get("detail_scale", _detail_scale))
	# 原版 setGraphicsQuality 会重置 lastX/lastZ，强制下一次 update 重建
	_has_focus = false


## 草叶层就绪后停摆 lawn-tuft 细节（原版 `p[2]===0 && this.meadow?.ready`）：
## 同一片草不该既由细节网格画一遍、又由草叶层画一遍。
func set_meadow(m) -> void:
	_meadow = m


# ---------------------------------------------------------------------------
# 装载
# ---------------------------------------------------------------------------

func _load_landscape() -> void:
	var man: Dictionary = CityData.landscape_manifest()
	var models: Array = man.get("models", [])
	if models.is_empty():
		push_warning("[LandscapeLayer] 缺少 landscape/manifest.json")
		return

	# ---- 原型清单（原版：manifest.models + 命中时的 open-vegetation.models）----
	var proto_list: Array = []
	for m in models:
		proto_list.append({"name": str(m.get("id", "")), "path": BASE + str(m.get("file", ""))})
	var open_man: Dictionary = DataLoader.json_dict("/city/open-vegetation/manifest.json")
	_open_matched = _verify_planting_hash(open_man)
	if _open_matched:
		for m in open_man.get("models", []):
			proto_list.append({
				"name": "open-" + str(m.get("id", "")),
				"path": OPEN_BASE + str(m.get("file", "")),
			})

	# ---- 装载原型（每个 GLB 的每个 mesh 一个 MultiMesh）----
	for pm in proto_list:
		var path: String = pm["path"]
		if not ResourceLoader.exists(path):
			push_warning("[LandscapeLayer] 缺少模型 %s" % path)
			continue
		var scene := load(path) as PackedScene
		if scene == null:
			continue
		var inst := scene.instantiate()
		var nodes: Array = []
		for mi in GlbLoader.meshes_of(inst):
			if mi.mesh == null or mi.mesh.get_surface_count() == 0:
				continue
			# 逐实例颜色（原版 thinInstanceSetBuffer('color')）。ebikes 的教训：
			# Godot 默认不把顶点色乘进 albedo，不打开这个开关着色是静默无效的。
			_enable_instance_tint(mi.mesh)
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.mesh = mi.mesh
			var node := MultiMeshInstance3D.new()
			node.multimesh = mm
			node.name = "ls-%s-%d" % [str(pm["name"]), nodes.size()]
			# 原版 casters 只包含近端（非 -lod）的树原型；细节与路面细节都不投影
			var pname := str(pm["name"])
			var can_cast := (TREE_NAMES.has(pname) or OPEN_TREE_NAMES.has(pname))
			node.cast_shadow = (GeometryInstance3D.SHADOW_CASTING_SETTING_ON if can_cast
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
			add_child(node)
			nodes.append({"mm": mm, "local": _relative_transform(inst, mi)})
		inst.queue_free()
		_protos[str(pm["name"])] = {"nodes": nodes}

	_load_planting()
	print("[LandscapeLayer] 种植树 %d 棵 / 细节 %d / 路面细节 %d / 原型 %d / open 对账 %s（%d 棵）"
		% [_trees.size(), _details.size(), _road_details.size(), _protos.size(),
			"命中" if _open_matched else "未命中", _open_eligible])


## 原版：把 planting.json 的 SHA-256 与 open-vegetation 清单里的哈希对账。
## 不命中就整层退回原版 Blender 树（绝不半替换，否则坐标与间距证明失效）。
func _verify_planting_hash(open_man: Dictionary) -> bool:
	if open_man.is_empty():
		return false
	var expect := str(open_man.get("plantingSHA256", "")).to_lower()
	if expect.length() != 64:
		return false
	var text := DataLoader.text("/city/landscape/planting.json")
	if text == "":
		return false
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(text.to_utf8_buffer())
	return ctx.finish().hex_encode().to_lower() == expect


static func _relative_transform(root: Node, n: Node3D) -> Transform3D:
	var xf := n.transform
	var p: Node = n.get_parent()
	while p != null and p != root:
		if p is Node3D:
			xf = (p as Node3D).transform * xf
		p = p.get_parent()
	return xf


## 逐实例染色生效开关（本层所有原型都写颜色，所以可以整体打开）
func _enable_instance_tint(mesh: Mesh) -> void:
	for s in mesh.get_surface_count():
		var mat: Material = mesh.surface_get_material(s)
		if mat is StandardMaterial3D:
			# ⚠️ 属性名是 vertex_color_use_**as_**albedo。写成不带 `_as_` 的
			# Godot 3.x 旧名（vertex_color_use_albedo）不会报错，只会静默走
			# SpatialMaterial 兼容层并刷 "remapped parameter not found" 警告，
			# 逐实例染色则完全不生效。
			(mat as StandardMaterial3D).vertex_color_use_as_albedo = true


## 读 planting.json 的 trees / details / roadDetails 三层 + open 替换表
func _load_planting() -> void:
	var planting: Dictionary = CityData.planting()
	# open-vegetation 的合格下标 → 目标名字（原版 openKinds WeakMap）
	var open_kinds := {}
	if _open_matched:
		var open_man: Dictionary = DataLoader.json_dict("/city/open-vegetation/manifest.json")
		var elig: Dictionary = open_man.get("eligibleIndices", {})
		for idx in elig.get("islandTree", []):
			open_kinds[int(idx)] = "open-island-tree"
		for idx in elig.get("palm", []):
			open_kinds[int(idx)] = "open-palm"
		_open_eligible = open_kinds.size()

	var raw: Array = planting.get("trees", [])
	_trees.clear()
	for i in raw.size():
		var t: Array = raw[i]
		if t.size() < 5:
			continue
		_trees.append({
			"x": float(t[0]), "z": float(t[1]), "species": int(t[2]),
			"scale": float(t[3]), "yaw": float(t[4]),
			"open": str(open_kinds.get(i, "")),
		})
	_tree_points.resize(_trees.size())
	for i in _trees.size():
		_tree_points[i] = Vector2(float(_trees[i]["x"]), float(_trees[i]["z"]))
	_tree_grid = PointGrid.new(100.0)
	_tree_grid.build(_tree_points)

	# ⚠️ 数据布局是 [x, z, kind, scale, yaw]（原版 p[2]=kind, p[3]=scale, p[4]=yaw）。
	# 旧移植版把 kind 读成了下标 3、scale 读成了下标 2 —— 于是所有细节都被当成
	# models[0]（banyan）且缩放到 0，等于这一层从来没画对过。
	_details.clear()
	var dmodels := _detail_model_index()
	for d in planting.get("details", []):
		var a: Array = d
		if a.size() < 5:
			continue
		_details.append({"x": float(a[0]), "z": float(a[1]), "kind": int(a[2]),
			"scale": float(a[3]), "yaw": float(a[4])})
	_detail_points.resize(_details.size())
	for i in _details.size():
		_detail_points[i] = Vector2(float(_details[i]["x"]), float(_details[i]["z"]))
	_detail_grid = PointGrid.new(100.0)
	_detail_grid.build(_detail_points)
	for k in DETAIL_NAMES.size():
		_detail_tris[k] = int(dmodels.get(k, {}).get("triangles", 0))

	_road_details.clear()
	for d in planting.get("roadDetails", []):
		var a2: Array = d
		if a2.size() < 5:
			continue
		_road_details.append({"x": float(a2[0]), "z": float(a2[1]), "kind": int(a2[2]),
			"scale": float(a2[3]), "yaw": float(a2[4])})
	_road_points.resize(_road_details.size())
	for i in _road_details.size():
		_road_points[i] = Vector2(float(_road_details[i]["x"]), float(_road_details[i]["z"]))
	_road_grid = PointGrid.new(100.0)
	_road_grid.build(_road_points)


## DETAIL_NAMES 下标 → manifest 里对应的模型条目
func _detail_model_index() -> Dictionary:
	var man: Dictionary = CityData.landscape_manifest()
	var out := {}
	for m in man.get("models", []):
		var id := str(m.get("id", ""))
		var k := DETAIL_NAMES.find(id)
		if k >= 0:
			out[k] = m
		var kr := ROAD_NAMES.find(id)
		if kr >= 0:
			out["road-%d" % kr] = m
	return out


# ---------------------------------------------------------------------------
# 每帧
# ---------------------------------------------------------------------------

func update_system(_delta: float, focus: Vector3) -> void:
	if not enabled or not _built:
		return
	var aerial := world != null and world.aerial
	var f2 := Vector2(focus.x, -focus.z)
	var moved := INF
	if _has_focus:
		moved = f2.distance_to(_last_focus)
	if moved < REBUILD_MOVE and aerial == _last_aerial:
		return
	_has_focus = true
	_last_focus = f2
	_last_aerial = aerial
	_rebuild(focus, aerial)


func _rebuild(focus: Vector3, aerial: bool) -> void:
	if _protos.is_empty():
		return
	var center := Vector2(focus.x, -focus.z)
	var radius := _aerial_tree_radius if aerial else _tree_radius
	var far_limit := _aerial_trees if aerial else _far_trees

	var groups := {}
	var near_count := 0
	var far_count := 0
	_open_visible = 0
	var open_near := 0

	# ---- 树（远端先到预算为止；距离升序）----
	if _tree_grid != null:
		for it in _tree_grid.query_radius_sorted2(center, radius, _tree_points):
			var t: Dictionary = _trees[int(it.x)]
			var d: float = it.y
			var near := (not aerial) and d < NEAR_DIST and near_count < _near_trees
			var qualified := str(t.get("open", ""))
			var is_open := qualified != "" and ((not aerial) or d < OPEN_AERIAL_DIST)
			if is_open and near and qualified == "open-island-tree" and open_near >= OPEN_NEAR_LIMIT:
				near = false
			if not near and far_count >= far_limit:
				continue
			# ⚠️ 显式标 String：三元里一边是字典取值（Variant），`:=` 推断不出来，
			# 会报 "Cannot infer the type of base variable"。
			var base: String = qualified if is_open else TREE_NAMES[clampi(int(t["species"]), 0, TREE_NAMES.size() - 1)]
			_append(groups, base + ("" if near else "-lod"), t)
			if near:
				near_count += 1
			else:
				far_count += 1
			if is_open:
				_open_visible += 1
				if near and qualified == "open-island-tree":
					open_near += 1

	# ---- 细节（仅街面视角）----
	var counts := [0, 0, 0]
	var caps := [
		int(DETAIL_CAPS[0] * _detail_scale),
		int(DETAIL_CAPS[1] * _detail_scale),
		int(DETAIL_CAPS[2] * _detail_scale),
	]
	var used_tris := 0
	if not aerial and _detail_grid != null:
		for it in _detail_grid.query_radius_sorted2(center, DETAIL_RADIUS, _detail_points):
			var e: Dictionary = _details[int(it.x)]
			var kind := clampi(int(e["kind"]), 0, DETAIL_NAMES.size() - 1)
			# 原版：草叶层就绪后不再摆 lawn-tuft（同一片草不画两遍）
			if kind == 0 and _meadow != null and _meadow.is_ready():
				continue
			var tris := int(_detail_tris[kind])
			if counts[kind] >= caps[kind] or used_tris + tris > DETAIL_TRIANGLE_BUDGET:
				continue
			_append(groups, DETAIL_NAMES[kind], e)
			counts[kind] += 1
			used_tris += tris

	# ---- 路面细节（仅街面视角，最近 28 个）----
	var road_count := 0
	if not aerial and _road_grid != null:
		var rl := _road_grid.query_radius_sorted2(center, ROAD_RADIUS, _road_points)
		for i in mini(ROAD_LIMIT, rl.size()):
			var e2: Dictionary = _road_details[int(rl[i].x)]
			var k2 := clampi(int(e2["kind"]), 0, ROAD_NAMES.size() - 1)
			_append(groups, ROAD_NAMES[k2], e2)
			road_count += 1

	_write_groups(groups)
	_stats = {
		"nearTrees": near_count, "farTrees": far_count,
		"lawnTufts": counts[0], "shrubs": counts[1], "ornamentalGrass": counts[2],
		"roadDetails": road_count, "openVisible": _open_visible,
		"drawCalls": groups.size(), "aerial": aerial,
	}


static func _append(groups: Dictionary, name: String, plant: Dictionary) -> void:
	if not groups.has(name):
		groups[name] = []
	(groups[name] as Array).append(plant)


func _write_groups(groups: Dictionary) -> void:
	# ⚠️ 循环变量不能叫 `name` —— Node 已有 name 属性，会触发
	# SHADOWED_VARIABLE_BASE_CLASS 告警（本项目这一档是当错误看的）
	for gname in _protos:
		var proto: Dictionary = _protos[gname]
		var plants: Array = groups.get(gname, [])
		var lift: float = ROAD_LIFT if ROAD_NAMES.has(gname) else DETAIL_LIFT
		for nd in proto["nodes"]:
			var mm: MultiMesh = nd["mm"]
			var local: Transform3D = nd["local"]
			var n := plants.size()
			mm.instance_count = n
			mm.visible_instance_count = n
			for i in n:
				var p: Dictionary = plants[i]
				mm.set_instance_transform(i, _plant_xf(p, lift) * local)
				mm.set_instance_color(i, _plant_col(p))


## 一棵植物/一个细节的世界变换。
##
## 原版每次重建都重算 `Matrix.Compose` + `heightAt()`；Godot 这边
## `HeightField.height_at()` 是五层串行采样，每 22m 重建一次、每次上千个实例
## 的话就是重建开销的大头（林冠那边已经因为同一原因加了 `_canopy_xf` 缓存）。
## 这些植物是静止的，结果永远不变 —— 算一次写进字典即可。
func _plant_xf(p: Dictionary, lift: float) -> Transform3D:
	var xf = p.get("xf", null)
	if xf != null:
		return xf
	var x := float(p["x"])
	var z := float(p["z"])
	var sc := float(p["scale"])
	var yaw := float(p["yaw"])
	var g := world.ground_height(x, -z)
	xf = Transform3D(
		Basis(Vector3.UP, CoordinateUtil.node_yaw(yaw)).scaled(Vector3(sc, sc, sc)),
		CoordinateUtil.to_world(x, z, g + lift))
	p["xf"] = xf
	return xf


## 原版：`seed = |sin(x*.713 + z*.519)|`，暖色/明度微扰
func _plant_col(p: Dictionary) -> Color:
	var c = p.get("col", null)
	if c != null:
		return c
	var seed := absf(sin(float(p["x"]) * 0.713 + float(p["z"]) * 0.519))
	c = Color(0.83 + seed * 0.22, 0.91 + seed * 0.15, 0.80 + seed * 0.23, 1.0)
	p["col"] = c
	return c


func diagnostics() -> Dictionary:
	return {
		"prototypes": _protos.size(),
		"trees": _trees.size(),
		"details": _details.size(),
		"roadDetails": _road_details.size(),
		"openMatched": _open_matched,
		"openEligible": _open_eligible,
		"openVisible": _open_visible,
		"stats": _stats,
	}
