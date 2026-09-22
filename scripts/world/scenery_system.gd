extends Node3D
class_name ScenerySystem
##
## 植被与街具 —— 对应原版 city-canopy.ts + city-landscape.ts
## + city-roadside-planting.ts + city-street-furniture.ts。
##
## 数据分工：
##   landscape/canopy-trees.json  40927 棵高大林冠，[east, north, species, scale, yaw]
##                                6 个树种（大叶榕 / 木棉 / 樟 / 小叶榄仁 / 凤凰木 / 芒果），
##                                每种 3 级 LOD（full / mid / far）
##   landscape/planting.json      trees 7933、details 64010、roadDetails 16971
##   street/manifest.json         urban-bench.glb 的 63 个摆放点
##
## LOD 距离（原版 CANOPY_LOD）：full 170m / mid 650m；空中 mid 阈值降到 520m。

const CANOPY_LOD_FULL := 170.0
const CANOPY_LOD_MID := 650.0
const CANOPY_LOD_AERIAL_MID := 520.0
const STREET_RADIUS := 1100.0
## 街具：只摆 150m 内的前 12 个
const FURNITURE_RADIUS := 150.0
const FURNITURE_LIMIT := 12

## 原版树木总量上限（三级 LOD 各自的实例预算）
const TREE_BUDGET := {"low": 4000, "medium": 9000, "high": 16000}

var world: CityWorld
var enabled := true
var quality := {"near_trees": 36, "canopy_full": 36}

var _species: Array = []        ## [{id, name, height, crown, lods: {full,mid,far}}]
var _canopy_instances: Array = []
## 林冠空间索引：40927 棵全量扫 + 排序（每 2s）太重
var _canopy_points := PackedVector2Array()
var _canopy_grid: PointGrid
var _canopy_nodes: Dictionary = {}   ## "species|lod" → MeshInstance3D
var _furniture_nodes: Array = []
var _detail_nodes: Array = []
var _timer := 0.0
var _built := false
## 林冠分帧重建状态：phase 0=空闲，1=筛选候选，2=写入 MultiMesh
var _canopy_job: Dictionary = {"phase": 0}
var _canopy_last_focus := Vector2.ZERO
## 林冠每帧最多处理的候选树数（计算 + 写入都计入），把上万次 set_instance_transform 摊到多帧
const CANOPY_CHUNK := 2600
## 每棵树的最终 Transform3D 缓存（树是静止的）。
## 原来每次重建都对每棵候选树调一次 ground_height()（五层串行采样）再重建 Basis，
## 预算 9000–16000 棵时这是重建开销的大头；缓存后重扫只剩查表 + 追加。
var _canopy_xf: Array = []


func setup(p_world: CityWorld) -> void:
	world = p_world
	_load_canopy_asset()
	_load_planting_details()
	_load_furniture()
	_built = true
	# 首次布点
	if not world.blocks.is_empty():
		update_system(0.0, world.focus)


func set_quality(p: Dictionary) -> void:
	quality = {
		"near_trees": int(p.get("near_trees", 36)),
		"canopy_full": int(p.get("canopy_full", 36)),
	}


# ---------------------------------------------------------------------------
# 林冠
# ---------------------------------------------------------------------------

func _load_canopy_asset() -> void:
	var man: Dictionary = CityData.canopy_manifest()
	if man.is_empty():
		push_warning("[ScenerySystem] 缺少林冠清单")
		return
	for sp in man.get("species", []):
		_species.append({"id": str(sp["id"]), "name": str(sp.get("name", "")),
			"height": float(sp.get("height", 15.0)), "crown": float(sp.get("crown", 8.0)),
			"lods": {}})
	# 模型条目里带 species / lod / file
	for m in man.get("models", []):
		var sid := str(m.get("species", ""))
		var lod := int(m.get("lod", 0))
		var sp := _find_species(sid)
		if sp.is_empty():
			continue
		var key := "full" if lod == 0 else ("mid" if lod == 1 else "far")
		sp["lods"][key] = str(m.get("file", ""))

	for sp in _species:
		for key in sp["lods"]:
			var rel: String = sp["lods"][key]
			var path := "res://data/city/landscape/" + rel
			if not ResourceLoader.exists(path):
				continue
			var scene := load(path) as PackedScene
			if scene == null:
				continue
			var inst := scene.instantiate()
			var mi_list := GlbLoader.meshes_of(inst)
			for mi in mi_list:
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.mesh = mi.mesh
				var node := MultiMeshInstance3D.new()
				node.multimesh = mm
				node.name = "canopy-%s-%s" % [sp["id"], key]
				node.cast_shadow = (
					GeometryInstance3D.SHADOW_CASTING_SETTING_ON if key == "full"
					else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
				add_child(node)
				_canopy_nodes["%s|%s|%s" % [sp["id"], key, mi.name]] = node
			inst.queue_free()

	var trees: Array = CityData.canopy_trees().get("trees", [])
	_canopy_instances.clear()
	for t in trees:
		if t.size() < 5:
			continue
		_canopy_instances.append({
			"x": float(t[0]), "z": float(t[1]),
			"species": int(t[2]), "scale": float(t[3]), "yaw": float(t[4]),
		})
	# 网格索引：40927 棵树全量扫 + 排序（每 2s 一次）太重，改成只取半径内的
	_canopy_points.resize(_canopy_instances.size())
	for i in _canopy_instances.size():
		_canopy_points[i] = Vector2(float(_canopy_instances[i]["x"]), float(_canopy_instances[i]["z"]))
	_canopy_grid = PointGrid.new(256.0)
	_canopy_grid.build(_canopy_points)
	print("[ScenerySystem] 林冠 %d 棵 / 树种 %d 个 / 节点 %d / 索引单元 256m"
		% [_canopy_instances.size(), _species.size(), _canopy_nodes.size()])


func _find_species(id: String) -> Dictionary:
	for sp in _species:
		if sp["id"] == id:
			return sp
	return {}


func _species_id(index: int) -> String:
	# canopy-trees.json 的 species 是下标
	if index >= 0 and index < _species.size():
		return _species[index]["id"]
	return ""


## 按距离把树分到三级 LOD（原版 canopyTier）
func _canopy_tier(d: float, aerial: bool) -> String:
	if d <= CANOPY_LOD_FULL:
		return "full"
	var mid_limit := CANOPY_LOD_AERIAL_MID if aerial else CANOPY_LOD_MID
	return "mid" if d <= mid_limit else "far"


## 启动一次林冠重建任务：只筛选候选树（网格索引 + 距离升序），
## 真正的实例写入在 _canopy_step 里分帧进行，避免单帧重写上万实例造成卡顿。
func _canopy_start(focus: Vector3, aerial: bool) -> void:
	if _canopy_instances.is_empty() or _canopy_nodes.is_empty():
		return
	var fx := focus.x
	var fz := -focus.z
	var budget: int = TREE_BUDGET.get(GameState.graphics_tier, 9000)
	var near: Array[Vector2] = []
	if _canopy_grid != null:
		near = _canopy_grid.query_radius_sorted2(Vector2(fx, fz), STREET_RADIUS, _canopy_points)
	if _canopy_xf.size() != _canopy_instances.size():
		_canopy_xf.resize(_canopy_instances.size())
	_canopy_job = {
		"phase": 1, "buckets": {}, "node_list": [], "node_idx": 0, "write_i": 0,
		"cand": near, "ci": 0, "used": 0, "budget": budget, "aerial": aerial,
	}


## 每帧处理量的自适应：帧率掉到 50 以下时把分帧量减半，
## 高速行驶时宁可林冠多铺几帧，也不把单帧时间撑爆。
func _current_chunk() -> int:
	if Engine.get_frames_per_second() >= 50.0:
		return CANOPY_CHUNK
	return int(CANOPY_CHUNK * 0.5)


## 分帧推进林冠重建：
##   phase 1 —— 把候选树分到各 LOD 桶（查缓存的变换矩阵，首次才算地面高度）
##   phase 2 —— 把桶写入各 MultiMesh
## 每帧只处理一小块，把「上万次 set_instance_transform」摊到多帧，
## 消除原来每 2 秒一次的主线程尖峰（1.6 万实例单帧重写）。
func _canopy_step(focus: Vector3) -> void:
	var job: Dictionary = _canopy_job
	if int(job["phase"]) == 0:
		return
	var chunk := _current_chunk()

	if int(job["phase"]) == 1:
		var near: Array[Vector2] = job["cand"]
		var processed := 0
		while int(job["ci"]) < near.size() and int(job["used"]) < int(job["budget"]) and processed < chunk:
			var it: Vector2 = near[int(job["ci"])]
			job["ci"] = int(job["ci"]) + 1
			processed += 1
			var idx: int = int(it.x)
			var d: float = it.y
			var sid := _species_id(int(_canopy_instances[idx]["species"]))
			if sid.is_empty():
				continue
			var tier := _canopy_tier(d, bool(job["aerial"]))
			var key := "%s|%s" % [sid, tier]
			if not job["buckets"].has(key):
				job["buckets"][key] = []
			var xf = _canopy_xf[idx]
			if xf == null:
				var t: Dictionary = _canopy_instances[idx]
				var tx := float(t["x"])
				var tz := float(t["z"])
				var g := world.ground_height(tx, -tz)
				xf = Transform3D(
					Basis(Vector3.UP, CoordinateUtil.node_yaw(float(t["yaw"]))).scaled(
						Vector3(float(t["scale"]), float(t["scale"]), float(t["scale"]))),
					CoordinateUtil.to_world(tx, tz, g))
				_canopy_xf[idx] = xf
			job["buckets"][key].append(xf)
			job["used"] = int(job["used"]) + 1
		if int(job["ci"]) >= near.size() or int(job["used"]) >= int(job["budget"]):
			job["node_list"] = []
			for nk in _canopy_nodes:
				job["node_list"].append(nk)
			job["phase"] = 2
			job["node_idx"] = 0
			job["write_i"] = 0
		return

	if int(job["phase"]) == 2:
		var written := 0
		while int(job["node_idx"]) < job["node_list"].size() and written < chunk:
			var nk: String = job["node_list"][int(job["node_idx"])]
			var node: MultiMeshInstance3D = _canopy_nodes[nk]
			var parts: Array = nk.split("|")
			var bucket_key := "%s|%s" % [parts[0], parts[1]]
			var list: Array = job["buckets"].get(bucket_key, [])
			var mm: MultiMesh = node.multimesh
			if int(job["write_i"]) == 0:
				mm.instance_count = list.size()
			while int(job["write_i"]) < list.size() and written < chunk:
				mm.set_instance_transform(int(job["write_i"]), list[int(job["write_i"])])
				job["write_i"] = int(job["write_i"]) + 1
				written += 1
			# 只显示已写入的有效实例（未写入的暂留在原点不能显示），随写入平滑增长
			mm.visible_instance_count = int(job["write_i"])
			if int(job["write_i"]) >= list.size():
				job["node_idx"] = int(job["node_idx"]) + 1
				job["write_i"] = 0
		if int(job["node_idx"]) >= job["node_list"].size():
			_canopy_job = {"phase": 0}


# ---------------------------------------------------------------------------
# 灌木 / 草叶 / 井盖等细节
# ---------------------------------------------------------------------------

func _load_planting_details() -> void:
	var man: Dictionary = CityData.landscape_manifest()
	var models: Array = man.get("models", [])
	if models.is_empty():
		return
	var planting: Dictionary = CityData.planting()
	var raw: Array = planting.get("details", [])
	# 每类模型一个 MultiMesh
	var by_model := {}
	for d in raw:
		if d.size() < 5:
			continue
		var kind := int(d[3]) if d[3] is float or d[3] is int else 0
		if not by_model.has(kind):
			by_model[kind] = []
		by_model[kind].append(d)

	var nodes: Array = []
	for kind in by_model.keys():
		if kind < 0 or kind >= models.size():
			continue
		var m: Dictionary = models[kind]
		var path := "res://data/city/landscape/" + str(m.get("file", ""))
		if not ResourceLoader.exists(path):
			continue
		var scene := load(path) as PackedScene
		if scene == null:
			continue
		var inst := scene.instantiate()
		for mi in GlbLoader.meshes_of(inst):
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = mi.mesh
			var node := MultiMeshInstance3D.new()
			node.multimesh = mm
			node.name = "detail-%d" % kind
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(node)
			nodes.append({"mm": mm, "kind": kind, "entries": by_model[kind], "built": false})
		inst.queue_free()
	_detail_nodes = nodes
	print("[ScenerySystem] 细节种类 %d，条目 %d" % [_detail_nodes.size(), raw.size()])


func _update_details(focus: Vector3) -> void:
	for entry in _detail_nodes:
		if entry["built"]:
			continue
		entry["built"] = true
		var list: Array = []
		for d in entry["entries"]:
			if d.size() < 5:
				continue
			var x := float(d[0])
			var z := float(d[1])
			if Vector2(x - focus.x, z + focus.z).length() > 400.0:
				continue
			var sc := float(d[2]) if d[2] is float or d[2] is int else 1.0
			var yaw := float(d[4]) if d[4] is float or d[4] is int else 0.0
			var g := world.ground_height(x, -z)
			list.append(Transform3D(
				Basis(Vector3.UP, CoordinateUtil.node_yaw(yaw)).scaled(Vector3(sc, sc, sc)),
				CoordinateUtil.to_world(x, z, g)))
			if list.size() >= 900:
				break
		var mm: MultiMesh = entry["mm"]
		mm.instance_count = list.size()
		mm.visible_instance_count = list.size()
		for i in list.size():
			mm.set_instance_transform(i, list[i])


# ---------------------------------------------------------------------------
# 街头家具（长椅）
# ---------------------------------------------------------------------------

## 街具：GLB **只加载一次**（建 MultiMesh 节点），
## 之后每次只重算「150m 内最近的 12 个摆放点」的实例变换。
## 原来 update_system 每 2s 就把整个 GLB 重新 instantiate 一遍，纯属浪费。
func _load_furniture() -> void:
	var man: Dictionary = CityData.street_manifest()
	var placements: Array = man.get("placements", [])
	if placements.is_empty():
		return
	var path := "res://data/city/street/" + str(man.get("file", "urban-bench.glb"))
	if not ResourceLoader.exists(path):
		return

	# —— 一次性：加载 GLB，为每个 mesh 建一个 MultiMeshInstance3D ——
	if _furniture_nodes.is_empty():
		var scene := load(path) as PackedScene
		if scene == null:
			return
		var inst := scene.instantiate()
		for mi in GlbLoader.meshes_of(inst):
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = mi.mesh
			var node := MultiMeshInstance3D.new()
			node.multimesh = mm
			node.name = "bench-%d" % _furniture_nodes.size()
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			add_child(node)
			_furniture_nodes.append({"mm": mm, "mesh": mi.mesh})
		inst.queue_free()

	# —— 每次调用：按焦点重摆 ——
	var focus := world.focus
	var fx := focus.x
	var fz := -focus.z
	var scored: Array = []
	for p in placements:
		var d := Vector2(float(p["x"]) - fx, float(p["z"]) - fz).length()
		if d <= FURNITURE_RADIUS:
			scored.append({"d": d, "p": p})
	scored.sort_custom(func(a, b): return a["d"] < b["d"])
	var list: Array = []
	for i in mini(FURNITURE_LIMIT, scored.size()):
		var p: Dictionary = scored[i]["p"]
		var g := world.ground_height(float(p["x"]), -float(p["z"])) + 0.045
		list.append(Transform3D(
			Basis(Vector3.UP, CoordinateUtil.node_yaw(float(p.get("yaw", 0.0)))),
			CoordinateUtil.to_world(float(p["x"]), float(p["z"]), g)))
	for entry in _furniture_nodes:
		var mm: MultiMesh = entry["mm"]
		mm.instance_count = list.size()
		mm.visible_instance_count = list.size()
		for i in list.size():
			mm.set_instance_transform(i, list[i])


# ---------------------------------------------------------------------------

func update_system(delta: float, focus: Vector3) -> void:
	if not enabled or not _built:
		return
	# 林冠分帧重建：进行中的任务每帧只做一小块，避免一次重写上万实例导致卡顿
	if int(_canopy_job["phase"]) != 0:
		_canopy_step(focus)
		return
	_timer -= delta
	var f2 := Vector2(focus.x, -focus.z)
	var moved := INF
	if not _canopy_last_focus.is_zero_approx():
		moved = f2.distance_to(_canopy_last_focus)
	# 静止或慢速移动（<120m）时跳过重建：树是静态的，LOD 不会因此变化，
	# 这样原地不动时不再每 2 秒卡一下。
	if _timer > 0.0 and moved < 120.0:
		return
	_canopy_start(focus, world.aerial)
	_timer = 2.0
	_canopy_last_focus = f2
	_canopy_step(focus)
	_update_details(focus)
	_load_furniture()


func diagnostics() -> Dictionary:
	var counts := {}
	for k in _canopy_nodes:
		# _canopy_nodes 里存的是 MultiMeshInstance3D（见 _build_canopy）。
		# 它和 MeshInstance3D 是 GeometryInstance3D 下的**兄弟类**，不是继承关系，
		# `as MeshInstance3D` 恒为 null，再取 .multimesh 就是空引用崩溃。
		var mmi := _canopy_nodes[k] as MultiMeshInstance3D
		if mmi == null or mmi.multimesh == null:
			continue
		counts[k] = mmi.multimesh.instance_count
	return {"species": _species.size(), "canopyInstances": _canopy_instances.size(),
			"detailKinds": _detail_nodes.size(), "furniture": _furniture_nodes.size(),
			"lodCounts": counts, "quality": quality}
