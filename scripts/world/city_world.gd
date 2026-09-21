extends Node3D
class_name CityWorld
##
## 城市世界主编排器 —— 对应原版 src/city-world.ts 的 DrivingWorld。
##
## 职责：
##   1. 按原版顺序装配城市图层（顺序会影响替换逻辑，不能随意调换）
##   2. 分块剔除（640m 网格）与立面瓦片流式加载
##   3. 汇总地面高度、碰撞、路网三个地基服务供各子系统查询
##   4. 驱动各子系统的 setup / update
##
## 装配顺序（照搬原版 init()）：
##   terrain → roads → coastal-bridges → coastal-shoreline → opposite-shore
##   → buildings → landmarks → （按前缀 dispose）→ landmark-detail
##   → （按前缀 dispose）→ landmark-candidates → 地标招牌 → 咖啡馆
##   → 植被 / 树冠 / 街具 / 招牌 → 信号灯 / 车流 / 行人 / 电摩
##
## 坐标：Godot 世界 = (x 东, y 上, z −北)。GLB 导入即对齐，不做任何变换。

signal progress(text: String)
signal built()

const BLOCK_SIZE := 640.0

## 原版可见半径（单位：米，数据尺度）
const VIS_DETAIL := 700.0
const VIS_ROAD := 2500.0
const VIS_OTHER := 3300.0
const VIS_AERIAL := 12000.0
const SHADOW_RADIUS := 520.0
const SHADOW_RADIUS_AERIAL := 1650.0
## 立面瓦片
const FACADE_SHOW := 700.0
const FACADE_QUEUE := 1050.0

# --- 地基服务 ---------------------------------------------------------------
var height_field: HeightField
var collision: CityCollision
var graph: RoadGraph

# --- 图层根节点 -------------------------------------------------------------
var terrain_root: Node3D
var roads_root: Node3D
var buildings_root: Node3D
var landmarks_root: Node3D
var facades_root: Node3D
var scenery_root: Node3D
var water_root: Node3D

# --- 分块索引 ---------------------------------------------------------------
## {node:Node3D, x:float, z:float, road:bool, detail:bool}
var blocks: Array = []
var landmark_nodes: Array = []
var _chunk_index: Dictionary = {}  ## "i_j" → Node3D

# --- 子系统（由 main_game 注入）---------------------------------------------
# 注意：`facades` 曾经漏掉声明，导致 _plan_facades / on_quality_changed 里
# 报 "Identifier facades not declared"。新增子系统时记得同步这里。
var sky = null
var lighting = null
var water = null
var weather = null
var scenery = null
var signs = null
var distant = null
var signals = null
var traffic = null
var pedestrians = null
var ebikes = null
var facades = null

var loader := GlbLoader.new()

# --- 运行时状态 -------------------------------------------------------------
## 构建完成标志。
## 注意不能叫 `ready` —— `Node` 已经有一个 `ready` 信号，重名会导致
## "Member 「ready」 redefined (original in native class 'Node3D')" 解析错误。
var city_ready := false
var aerial := false
var focus := Vector3.ZERO
var _focus_data := Vector2.ZERO
var _steps: Array = []
var _step := 0
var _cull_timer := 0.0
var stats_loaded := 0
var stats_failed := 0
var last_failure := ""


func _ready() -> void:
	height_field = HeightField.new()
	collision = CityCollision.new()
	graph = RoadGraph.new()

	for n in ["terrain", "roads", "buildings", "landmarks", "facades", "scenery", "water"]:
		var node := Node3D.new()
		node.name = n
		add_child(node)
		match n:
			"terrain": terrain_root = node
			"roads": roads_root = node
			"buildings": buildings_root = node
			"landmarks": landmarks_root = node
			"facades": facades_root = node
			"scenery": scenery_root = node
			"water": water_root = node

	loader.entry_loaded.connect(_on_entry_loaded)
	loader.entry_failed.connect(func(p: String, r: String): stats_failed += 1)


# ---------------------------------------------------------------------------
# 构建流程：一串可推进的步骤，每步返回 true 表示完成
# ---------------------------------------------------------------------------

func build() -> void:
	_steps = [
		_plan_data,
		_plan_terrain,
		_plan_roads,
		_plan_coastal,
		_plan_buildings,
		_plan_landmarks,
		_plan_facades,
		_plan_water_sky,
		_plan_distant,
		_plan_scenery,
		_plan_signs,
		_plan_life,
		_plan_finish,
	]
	_step = 0
	set_process(true)


func _process(delta: float) -> void:
	# 先推进加载队列
	if not loader.is_idle():
		loader.poll()
		return

	if _step < _steps.size():
		var fn: Callable = _steps[_step]
		progress.emit(_step_label(_step))
		if fn.call():
			_step += 1
			_phase = ""
		return

	# 构建完成后：分块剔除 + 立面流式 + 子系统更新
	_cull_timer -= delta
	if _cull_timer <= 0.0:
		_cull_timer = 0.25
		_cull_chunks()
		if signs != null and signs.has_method("update_signs"):
			signs.update_signs(focus)
	_update_subsystems(delta)


func _update_subsystems(delta: float) -> void:
	for sys in [traffic, pedestrians, ebikes, signals, weather, water, scenery, distant, signs]:
		if sys != null and sys.has_method("update_system"):
			sys.update_system(delta, focus)


## 构建进度 0–1，供加载条使用
func progress_ratio() -> float:
	if _steps.is_empty():
		return 0.0
	return clampf(float(_step) / float(_steps.size()), 0.0, 1.0)


func _step_label(i: int) -> String:
	match i:
		0: return "正在展开深圳地图"
		1: return "正在铺设地形"
		2: return "正在铺设海岸线和城市道路"
		3: return "正在架设跨水桥梁"
		4: return "正在载入南山、福田、罗湖建筑"
		5: return "正在装配深圳地标"
		6: return "正在流式加载近景立面"
		7: return "正在注满深圳湾"
		8: return "正在展开深圳山脊"
		9: return "正在种植榕树、木棉与樟树林冠"
		10: return "正在点亮城市招牌"
		11: return "正在放入车流、行人与电摩"
		12: return "准备出发"
	return "加载中"


# --- 步骤 0：数据 -----------------------------------------------------------
func _plan_data() -> bool:
	CityData.load_core()
	height_field.load_all()
	collision.build()
	graph.build_from_navigation()
	progress.emit("正在整理地图数据")
	return true


# 每个步骤内部用 _phase 记子阶段；步骤推进时自动清空。
# 提交加载后进入 "wait"，等队列空才返回 true。
var _phase := ""


func _enqueue_step(paths: Array, parent: Node, meta: Variant = null) -> bool:
	match _phase:
		"":
			for p in paths:
				loader.enqueue(str(p), parent, meta)
			_phase = "wait"
			return false
		"wait":
			return loader.is_idle()
	return true


# --- 步骤 1：地形 -----------------------------------------------------------
func _plan_terrain() -> bool:
	return _enqueue_step(["res://data/city/terrain.glb"], terrain_root, "terrain")


# --- 步骤 2：道路 -----------------------------------------------------------
func _plan_roads() -> bool:
	return _enqueue_step(["res://data/city/roads.glb"], roads_root, "roads")


# --- 步骤 3：海岸 -----------------------------------------------------------
func _plan_coastal() -> bool:
	return _enqueue_step([
		"res://data/city/coastal-bridges.glb",
		"res://data/city/coastal-shoreline.glb",
		"res://data/city/opposite-shore.glb",
	], landmarks_root, "coastal")


# --- 步骤 4：建筑 -----------------------------------------------------------
func _plan_buildings() -> bool:
	return _enqueue_step(["res://data/city/buildings.glb"], buildings_root, "buildings")


# --- 步骤 5：地标 -----------------------------------------------------------
# 三次装载依次进行：landmarks.glb → 按前缀剔除 → landmark-detail.glb
# → 按前缀剔除 → landmark-candidates.glb。顺序与原版 init() 完全一致。
func _plan_landmarks() -> bool:
	if _phase == "":
		_index_building_chunks()
		_phase = "landmarks"
		loader.enqueue("res://data/city/landmarks.glb", landmarks_root, "landmarks")
		return false
	if _phase == "landmarks":
		if not loader.is_idle():
			return false
		_dispose_replaced("detail")
		_phase = "detail"
		loader.enqueue("res://data/city/landmark-detail.glb", landmarks_root, "landmark-detail")
		return false
	if _phase == "detail":
		if not loader.is_idle():
			return false
		_dispose_replaced("candidates")
		_phase = "candidates"
		loader.enqueue("res://data/city/landmark-candidates.glb", landmarks_root, "landmark-candidates")
		return false
	if _phase == "candidates":
		return loader.is_idle()
	return true


# --- 步骤 6：立面 -----------------------------------------------------------
func _plan_facades() -> bool:
	if facades != null and facades.has_method("init_streaming"):
		# _focus_data 要等 main_game 每帧调 set_focus() 才有值，这一步发生在
		# 城市构建期间，此时它还是 (0,0)。直接用它初始化会让立面瓦片围着
		# 地图原点加载、而不是围着出生点，玩家一落地周围全是空立面。
		var f := _focus_data
		if f == Vector2.ZERO:
			f = CityData.spawn_pos
		return facades.init_streaming(f)
	return true


# --- 步骤 7：水面与天空 -----------------------------------------------------
func _plan_water_sky() -> bool:
	if sky != null and sky.has_method("setup"):
		sky.setup(self)
	if water != null and water.has_method("setup"):
		water.setup(self)
	if weather != null and weather.has_method("setup"):
		weather.setup(self)
	if lighting != null and lighting.has_method("setup"):
		lighting.setup(self)
	return true


# --- 步骤 8：远山与海岸线 ---------------------------------------------------
# build_all 内部会先读 preservedTerrainBounds（供道路贴合用），
# 所以 drape_roads 必须放在它之后，否则边界还是空矩形、会静默跳过。
func _plan_distant() -> bool:
	if distant == null:
		return true
	if distant.has_method("build_all"):
		distant.build_all(self)
	if distant.has_method("drape_roads"):
		distant.drape_roads(roads_root)
	return true


# --- 步骤 9：植被 -----------------------------------------------------------
func _plan_scenery() -> bool:
	if scenery != null and scenery.has_method("setup"):
		scenery.setup(self)
	return true


# --- 步骤 10：招牌与街具 ----------------------------------------------------
func _plan_signs() -> bool:
	if signs != null and signs.has_method("setup"):
		signs.setup(self)
	return true


# --- 步骤 11：城市生命 ------------------------------------------------------
func _plan_life() -> bool:
	if signals != null and signals.has_method("setup"):
		signals.setup(self)
	if traffic != null and traffic.has_method("setup"):
		traffic.setup(self)
	if pedestrians != null and pedestrians.has_method("setup"):
		pedestrians.setup(self)
	if ebikes != null and ebikes.has_method("setup"):
		ebikes.setup(self)
	return true


# --- 步骤 12：收尾 ----------------------------------------------------------
func _plan_finish() -> bool:
	city_ready = true
	built.emit()
	progress.emit("准备出发")
	set_process(true)
	return true


# ---------------------------------------------------------------------------
# 队列回调
# ---------------------------------------------------------------------------

func _on_entry_loaded(path: String, node: Node3D, meta: Variant) -> void:
	stats_loaded += 1
	GlbLoader.configure_meshes(GlbLoader.meshes_of(node), true, true)
	match str(meta):
		"terrain", "roads":
			for mi in GlbLoader.meshes_of(node):
				if mi.material_override == null and mi.get_surface_override_material_count() == 0:
					pass
		"landmark-detail":
			_collect_landmark_chunks(node, true)
		"landmark-candidates":
			_collect_landmark_chunks(node, false)
		"landmarks":
			for mi in GlbLoader.meshes_of(node):
				landmark_nodes.append(mi)
		_:
			for mi in GlbLoader.meshes_of(node):
				if str(meta).begins_with("coastal") or str(meta) == "opposite-shore":
					landmark_nodes.append(mi)


## 从建筑/道路 GLB 里解析 `block_i_j` / `roads_i_j` 分块名，建分块索引
func _index_building_chunks() -> void:
	var re := RegEx.new()
	re.compile("(?:block|roads)_(-?\\d+)_(-?\\d+)_")
	for root in [roads_root, buildings_root]:
		for mi in GlbLoader.meshes_of(root):
			var m := re.search(mi.name)
			if m == null:
				continue
			var i := int(m.get_string(1))
			var j := int(m.get_string(2))
			var is_road: bool = mi.name.begins_with("roads")
			blocks.append({
				"node": mi,
				"i": i, "j": j,
				"x": (i + 0.5) * BLOCK_SIZE,
				"z": (j + 0.5) * BLOCK_SIZE,
				"road": is_road,
			})
			_chunk_index["%d_%d" % [i, j]] = mi
	print("[CityWorld] 分块索引：%d 个" % blocks.size())


func _collect_landmark_chunks(root: Node3D, detail: bool) -> void:
	var re := RegEx.new()
	re.compile("detail_block_(-?\\d+)_(-?\\d+)_")
	for mi in GlbLoader.meshes_of(root):
		var m := re.search(mi.name)
		if m != null:
			var i := int(m.get_string(1))
			var j := int(m.get_string(2))
			blocks.append({
				"node": mi, "i": i, "j": j,
				"x": (i + 0.5) * BLOCK_SIZE, "z": (j + 0.5) * BLOCK_SIZE,
				"road": false, "detail": true,
			})
		else:
			landmark_nodes.append(mi)


## 按 replacedMeshPrefixes 把被地标替换掉的旧网格从场景中移除
func _dispose_replaced(which: String) -> void:
	var prefixes: Array = []
	var src: Dictionary = CityData.landmark_detail if which == "detail" else CityData.landmark_candidates
	prefixes = src.get("replacedMeshPrefixes", [])
	if prefixes.is_empty():
		return
	var removed := 0
	for parent in [buildings_root, landmarks_root]:
		for mi in GlbLoader.meshes_of(parent):
			for p in prefixes:
				if mi.name.begins_with(str(p)):
					mi.queue_free()
					removed += 1
					break
	blocks = blocks.filter(func(b): return is_instance_valid(b["node"]))
	landmark_nodes = landmark_nodes.filter(func(m): return is_instance_valid(m))
	if removed > 0:
		print("[CityWorld] %s：按前缀移除旧地标网格 %d 个" % [which, removed])


# ---------------------------------------------------------------------------
# 分块剔除
# ---------------------------------------------------------------------------

func set_focus(world_pos: Vector3) -> void:
	focus = world_pos
	_focus_data = Vector2(world_pos.x, -world_pos.z)


func _cull_chunks() -> void:
	var max_detail := VIS_AERIAL if aerial else VIS_DETAIL
	var max_road := VIS_AERIAL if aerial else VIS_ROAD
	var max_other := VIS_AERIAL if aerial else VIS_OTHER
	var shadow_r := SHADOW_RADIUS_AERIAL if aerial else SHADOW_RADIUS

	for b in blocks:
		var node: Node3D = b["node"]
		if not is_instance_valid(node):
			continue
		var dx := float(b["x"]) - _focus_data.x
		var dz := float(b["z"]) - _focus_data.y
		var d := sqrt(dx * dx + dz * dz)
		# 显式标 float：b 是字典，三元里混了字典取值会让推断落空
		var limit: float = max_detail if b.get("detail", false) else (max_road if b["road"] else max_other)
		# 局部变量不能叫 visible —— Node3D 已有 visible 属性
		var should_show := d <= limit
		if node.visible != should_show:
			node.visible = should_show
		# 阴影投射体按更紧的半径控制（原版 520m）
		if should_show:
			node.cast_shadow = (
				GeometryInstance3D.SHADOW_CASTING_SETTING_ON if d <= shadow_r
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			)


# ---------------------------------------------------------------------------
# 对外服务
# ---------------------------------------------------------------------------

## 数据坐标下的地面高度
func ground_height_data(east: float, north: float) -> float:
	return height_field.height_at(east, north)


## 世界坐标下的地面高度
func ground_height(x: float, z: float) -> float:
	return height_field.height_at(x, -z)


func is_blocked_data(east: float, north: float) -> bool:
	return collision.blocked(east, north)


func set_aerial(v: bool) -> void:
	aerial = v
	_cull_chunks()


func on_quality_changed(p: Dictionary) -> void:
	if scenery != null and scenery.has_method("set_quality"):
		scenery.set_quality(p)
	if facades != null and facades.has_method("set_quality"):
		facades.set_quality(p)
	if water != null and water.has_method("set_quality"):
		water.set_quality(p)
	if lighting != null and lighting.has_method("set_quality"):
		lighting.set_quality(p)


func counts() -> Dictionary:
	return {
		"blocks": blocks.size(),
		"landmarks": landmark_nodes.size(),
		"glbLoaded": stats_loaded,
		"glbFailed": stats_failed,
		"chunks": _chunk_index.size(),
	}


func diagnostics() -> Dictionary:
	return {
		"ready": city_ready,
		"aerial": aerial,
		"focus": [focus.x, focus.y, focus.z],
		"heightField": height_field.stats(),
		"collision": collision.stats(),
		"graph": graph.stats(),
		"counts": counts(),
		"subsystems": {
			"sky": sky != null, "lighting": lighting != null, "water": water != null,
			"weather": weather != null, "scenery": scenery != null, "signs": signs != null,
			"distant": distant != null, "signals": signals != null,
			"traffic": traffic != null, "pedestrians": pedestrians != null, "ebikes": ebikes != null,
		},
	}
