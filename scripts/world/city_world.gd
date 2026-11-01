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
## 致命失败（对应原版 city-loading 的 error 态）：加载画面据此切到「载入中断 + 重新载入」
signal failed(reason: String)

## 幕墙逐窗格亮灯（A4）。⚠️ 新脚本的 class_name 不在全局类缓存，一律 preload。
const TENCENT_WINDOWS_SCRIPT := preload("res://scripts/world/tencent_windows.gd")
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

## 候选地标的「地面平板」判据（原版 landmark-details.ts 的 isCandidateGroundSlab）。
##
## 候选块模型把公园画成 `_park` / `_water` 平板（深圳湾公园 874×235 m、人才公园
## 414×351 m、红树林 1123×126 m …），它们只高出地面 0～0.8 m、无视地形起伏、
## 也不走海面着色器，平视/正射下就是一张发亮的蓝片把路面盖住（实测深圳湾公园那块
## 正好压住滨海大道辅路，车身下缘被切在轮子高度）。原版运行时**全部丢弃**：
##   - 任何候选 `_water` 平板；
##   - `candidateKind === 'park'` 且高度跨度 < 1.5 m 的 `_park` 平板
##     （笔架山那块跨度 49 m，是真地形，必须保留）。
const CANDIDATE_SLAB_RE := "^landmark_(.+)_(water|park)$"
const CANDIDATE_PARK_SLAB_MAX_SPAN := 1.5

# --- 地基服务 ---------------------------------------------------------------
## 桥面投影关闭只做一次
var _bridge_shadow_done := false
var height_field: HeightField
var collision: CityCollision
var graph: RoadGraph

# --- 图层根节点 -------------------------------------------------------------
var terrain_root: Node3D
var roads_root: Node3D
var buildings_root: Node3D
var landmarks_root: Node3D
## 腾讯滨海逐窗格亮灯（原版 city-landmark-lighting.ts）。detail 装载完成后建一次。
var tencent_windows = null
var facades_root: Node3D
var scenery_root: Node3D
var water_root: Node3D
## 流式建筑区块挂这里（与 buildings_root 分离，便于整体剔除/统计）
var chunks_root: Node3D

# --- 分块索引 ---------------------------------------------------------------
## {node:Node3D, x:float, z:float, road:bool, detail:bool}
var blocks: Array = []
var landmark_nodes: Array = []
var _chunk_index: Dictionary = {}  ## "i_j" → Node3D
## 候选地标 id（下划线形式）→ candidateKind，判据 isCandidateGroundSlab 用
var _candidate_kinds: Dictionary = {}

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
## 远景城市壳（原版 city-distant-city.ts）：高空模式下远处 ≥3300m 的
## 极简楼壳，与近处真楼互补。⚠️ 用 preload 引用（新 class_name 不在全局缓存）
const DISTANT_CITY_SCRIPT := preload("res://scripts/world/distant_city.gd")
var distant_city = null
var signals = null
var traffic = null
var pedestrians = null
var ebikes = null
var facades = null
## 建筑区块动态流式（buildings.glb 切块后按 640m 区块加载/卸载）
var chunk_streamer = null
## 沥青路面标定（原版 applyCinematicRoad）
var road_surface: RoadSurface = null
## 地面材质注入（公共照明场 clipmap + 烘焙 AO + 草地分层）
##
## ⚠️ 与 main_game.gd 对 Rider 的处理同理：新增脚本的 `class_name` 要等编辑器
## 重扫一次才会进全局类缓存，直接写 `var ground_field: GroundField` 会在运行时
## 报 "Could not find type GroundField"。所以这里用 preload + 无类型变量。
const GROUND_FIELD_SCRIPT := preload("res://scripts/world/ground_field.gd")
var ground_field = null
## 屋顶设备层（停机坪 / 设备房 / 冷却塔 / 水箱 / 天线 / 光伏 / 天窗 / 通风管）
const ROOFTOP_SCRIPT := preload("res://scripts/world/rooftop_layer.gd")
var rooftop_layer = null
## 建筑立面材质（原版 city-architecture-materials.ts 的 28 个 profile）
const ARCH_MATERIALS_SCRIPT := preload("res://scripts/world/architecture_materials.gd")
var arch_materials = null
## 观察模式信标（原版 city-observer-beacons.ts 的 3D 部分 + 落点解算）
const BEACONS_SCRIPT := preload("res://scripts/world/observer_beacons.gd")
var beacons = null

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
## 地标步骤内部有 3 段装载，用它算步骤内进度
var _landmark_stage := 0
## 地面材质注入是否已跑过（_plan_ground_field 只做一次）
var _ground_field_done := false
## 屋顶设备层是否已装载（_plan_rooftops 只做一次）
var _rooftops_done := false
## 建筑立面材质是否已套用（_plan_arch_materials 只做一次）
var _arch_materials_done := false
## 观察信标是否已建立（_plan_beacons 只做一次）
var _beacons_done := false
var stats_loaded := 0
var stats_failed := 0
var last_failure := ""


func _ready() -> void:
	height_field = HeightField.new()
	collision = CityCollision.new()
	graph = RoadGraph.new()

	for n in ["terrain", "roads", "buildings", "landmarks", "facades", "scenery", "water", "chunks"]:
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
			"chunks": chunks_root = node

	chunk_streamer = ChunkStreamer.new()
	chunk_streamer.name = "ChunkStreamer"
	add_child(chunk_streamer)
	chunk_streamer.setup(self)

	road_surface = RoadSurface.new()
	road_surface.name = "RoadSurface"
	add_child(road_surface)

	# 地面材质注入层。必须在 road_surface 之后创建并接管：
	# road_surface 先按原版把 asphalt / roadline / 对岸 标定好，本层再把这些
	# 参数抄进自己的着色器（之后每 0.25s 回抄一次，昼夜/干湿切换仍由前者决定）。
	ground_field = GROUND_FIELD_SCRIPT.new()
	ground_field.name = "GroundField"
	add_child(ground_field)

	# 屋顶设备层。挂在场景根部：它的实例是 MultiMesh，不参与区块剔除。
	rooftop_layer = ROOFTOP_SCRIPT.new()
	rooftop_layer.name = "RooftopLayer"
	add_child(rooftop_layer)

	# 建筑立面材质。放在 ground_field 之后建，让屋顶的 surface override 先挂上，
	# 本层扫描时就能跳过它们（见 architecture_materials.gd 的说明）。
	arch_materials = ARCH_MATERIALS_SCRIPT.new()
	arch_materials.name = "ArchMaterials"
	add_child(arch_materials)

	# 观察模式信标：3 件光柱网格 + 落点解算，只在观察模式下工作
	beacons = BEACONS_SCRIPT.new()
	beacons.name = "ObserverBeacons"
	add_child(beacons)

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
		_plan_chunks,
		_plan_facades,
		_plan_water_sky,
		_plan_distant,
		_plan_scenery,
		_plan_road_surface,
		_plan_ground_field,
		_plan_rooftops,
		_plan_arch_materials,
		_plan_beacons,
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
		# 只在阶段文案变化时广播：Label.text 每帧重写会触发 CJK 重排版，
		# 加载期白白吃掉几毫秒。
		if _step != _last_label_step:
			_last_label_step = _step
			progress.emit(_step_label(_step))
		if fn.call():
			_step += 1
			_phase = ""
		return

	# 构建完成后：分块剔除 + 立面流式 + 子系统更新
	_cull_timer -= delta
	if _cull_timer <= 0.0:
		_cull_timer = 0.25
		# 流式激活时由 chunk_streamer 负责加载/卸载与阴影；否则走原 visibility 剔除。
		if chunk_streamer != null and chunk_streamer.active:
			chunk_streamer.update_system(delta, focus)
		else:
			_cull_chunks()
	_update_subsystems(delta)


func _update_subsystems(delta: float) -> void:
	for sys in [traffic, pedestrians, ebikes, signals, weather, water, scenery, distant, distant_city, signs, ground_field, rooftop_layer, arch_materials]:
		if sys != null and sys.has_method("update_system"):
			sys.update_system(delta, focus)



## 构建进度 0–1，供加载条使用。
## 粗粒度（只算第几步）会导致 buildings.glb 这种 266MB 的大件加载时进度条
## 长时间一动不动，所以这里把「当前步骤内部」的进度也算进去。
func progress_ratio() -> float:
	if _steps.is_empty():
		return 0.0
	var base := float(_step) / float(_steps.size())
	var frac := 0.0
	if _step < _steps.size():
		frac = _step_fraction()
	return clampf(base + frac / float(_steps.size()), 0.0, 1.0)


## 当前步骤的内部进度 0–1
func _step_fraction() -> float:
	match _step:
		5:  # 地标：landmarks → detail → candidates 三段
			return clampf(float(_landmark_stage) / 3.0, 0.0, 1.0)
		6:  # 建筑区块预加载
			if chunk_streamer != null and chunk_streamer.active:
				return float(chunk_streamer.preload_progress())
			return 1.0
		7:  # 立面瓦片预加载
			if facades != null and facades.has_method("preload_progress"):
				return float(facades.call("preload_progress"))
			return 1.0
		_:
			if not loader.is_idle():
				return loader.progress()
			return 0.0


## 加载界面下方的明细文案
func progress_detail() -> String:
	if _step == 7:
		if facades != null and facades.has_method("preload_detail"):
			return str(facades.call("preload_detail"))
	var c := loader.counters()
	if c.y > 0 and c.x < c.y:
		return "资源 %d / %d" % [c.x, c.y]
	return ""


var _last_label_step := -1


func _step_label(i: int) -> String:
	match i:
		0: return "正在展开深圳地图"
		1: return "正在铺设地形"
		2: return "正在铺设海岸线和城市道路"
		3: return "正在架设跨水桥梁"
		4: return "正在载入南山、福田、罗湖建筑"
		5: return "正在装配深圳地标"
		6: return "正在流式加载建筑区块"
		7: return "正在流式加载近景立面"
		8: return "正在注满深圳湾"
		9: return "正在展开深圳山脊"
		10: return "正在种植榕树、木棉与樟树林冠"
		11: return "正在标定沥青路面"
		12: return "正在点亮城市照明与环境遮蔽"
		13: return "正在装配屋顶设备与停机坪"
		14: return "正在套用建筑立面材质"
		15: return "正在点亮观察信标"
		16: return "正在放入车流、行人与电摩"
		17: return "准备出发"
	return "加载中"


# --- 步骤 0：数据 -----------------------------------------------------------
func _plan_data() -> bool:
	CityData.load_core()
	# city.json 是整座城市的地基（路网、建筑环、地标）。它读不到时后续每一步都会
	# 拿到空集合，与其在几十个系统里分别报错，不如在这里就停住并让加载画面报错。
	if not CityData.is_loaded():
		push_error("[CityWorld] city.json 载入失败，城市无法构建")
		set_process(false)
		failed.emit("城市数据载入失败：找不到或无法解析 city.json。")
		return true
	height_field.load_all()
	collision.build()
	# navigation.json 是预计算路网（42829 节点）；万一它没加载成功，
	# 退回按 roads 现场建图。否则 graph 为空 → 自动驾驶一律
	# "无法规划到该目的地的路线"，而控制台上只有一句 DataLoader 警告。
	if not graph.build_from_navigation():
		push_warning("[CityWorld] navigation.json 不可用，改用 roads 现场建图")
		graph.build_from_roads(CityData.roads)
	progress.emit("正在整理地图数据")
	return true


# 每个步骤内部用 _phase 记子阶段；步骤推进时自动清空。
# 提交加载后进入 "wait"，等队列空才返回 true。
var _phase := ""


func _enqueue_step(paths: Array, parent: Node, meta: Variant = null) -> bool:
	match _phase:
		"":
			# 启动性能打点：每批 GLB 的入队/完成时间（grep [BOOT-T]）
			print("[BOOT-T] 装载开始 %s t=%.1fs" % [str(paths), _boot_clock()])
			for p in paths:
				loader.enqueue(str(p), parent, meta)
			_phase = "wait"
			return false
		"wait":
			if loader.is_idle():
				print("[BOOT-T] 装载完成 %s t=%.1fs" % [str(paths), _boot_clock()])
				return true
			return false
	return true


## 进程启动以来的秒数（启动性能归因用）
func _boot_clock() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


# --- 步骤 1：地形 -----------------------------------------------------------
func _plan_terrain() -> bool:
	return _enqueue_step(["res://data/city/terrain.glb"], terrain_root, "terrain")


# --- 步骤 2：道路 -----------------------------------------------------------
func _plan_roads() -> bool:
	return _enqueue_step(["res://data/city/roads.glb"], roads_root, "roads")


# --- 步骤 2.5：路面 / 车道线 / 林冠材质标定 ---------------------------------
# 对应原版 init() 末尾的 `this.roadSurface = applyCinematicRoad(...)` 与
# `applyLandscapeSurfaces`、`CityCanopy` 的材质统一处理（见 road_surface.gd）。
# **必须放在 _plan_scenery 之后**：林冠是 MultiMeshInstance3D，只有植被建好
# 才能扫到 canopy_* 材质。
func _plan_road_surface() -> bool:
	if road_surface == null:
		return true
	road_surface.setup(self)
	road_surface.set_mode(GameState.light_mode)
	road_surface.set_weather(GameState.rain)
	road_surface.apply_now()
	return true


# --- 步骤 3：海岸 -----------------------------------------------------------
func _plan_coastal() -> bool:
	var done := _enqueue_step([
		"res://data/city/coastal-bridges.glb",
		"res://data/city/coastal-shoreline.glb",
		"res://data/city/opposite-shore.glb",
	], landmarks_root, "coastal")
	if done and not _bridge_shadow_done:
		_bridge_shadow_done = true
		_disable_bridge_shadows()
	return done


## 深圳湾大桥的桥面不投影：12km 长、离水仅 2–4m 的超大 casting 体，阴影贴图
## 完全解析不动 —— 它的影子会变成一条横跨海湾/广场的锯齿黑带（实测把整个
## 中湾广场盖住）。现实里这么低的桥面影子只是贴水细线，没有比有更好。
func _disable_bridge_shadows() -> void:
	var n := 0
	var stk: Array = [landmarks_root]
	while not stk.is_empty():
		var nd: Node = stk.pop_back()
		for ch in nd.get_children():
			stk.append(ch)
		if nd is MeshInstance3D and String(nd.name).to_lower().begins_with("coastal_bridge_"):
			(nd as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			n += 1
	print("[CityWorld] 桥面投影已关闭 ×%d（超大 casting 体，阴影贴图解析不动）" % n)


func _plan_buildings() -> bool:
	if ChunkStreamer.manifest_available():
		return true
	return _enqueue_step(["res://data/city/buildings.glb"], buildings_root, "buildings")


## 腾讯滨海幕墙：按索引拓扑恢复每块窗格，写 UV + 顶点色，换逐格发光着色器。
## 只在 detail 那批网格还在的场景里建一次；候选地标阶段不重复。
func _build_tencent_windows() -> void:
	if tencent_windows != null or landmarks_root == null:
		return
	tencent_windows = TENCENT_WINDOWS_SCRIPT.new()
	tencent_windows.name = "TencentWindows"
	add_child(tencent_windows)
	var report: Dictionary = tencent_windows.setup(landmarks_root)
	print("[CityWorld] 腾讯幕墙窗格数据：%s" % str(report))


# --- 步骤 5：地标 -----------------------------------------------------------
# 三次装载依次进行：landmarks.glb → 按前缀剔除 → landmark-detail.glb
# → 按前缀剔除 → landmark-candidates.glb。顺序与原版 init() 完全一致。
func _plan_landmarks() -> bool:
	if _phase == "":
		# 流式模式下建筑区块索引由 chunk_streamer 维护（按加载情况动态增减），
		# 这里只在回退路径里索引 monolithic 建筑/道路 mesh。
		if not ChunkStreamer.manifest_available():
			_index_building_chunks()
		_landmark_stage = 0
		_phase = "landmarks"
		loader.enqueue("res://data/city/landmarks.glb", landmarks_root, "landmarks")
		return false
	if _phase == "landmarks":
		if not loader.is_idle():
			return false
		_dispose_replaced("detail")
		_landmark_stage = 1
		_phase = "detail"
		loader.enqueue("res://data/city/landmark-detail.glb", landmarks_root, "landmark-detail")
		return false
	if _phase == "detail":
		if not loader.is_idle():
			return false
		_build_tencent_windows()
		_dispose_replaced("candidates")
		_landmark_stage = 2
		_phase = "candidates"
		loader.enqueue("res://data/city/landmark-candidates.glb", landmarks_root, "landmark-candidates")
		return false
	if _phase == "candidates":
		if not loader.is_idle():
			return false
		_landmark_stage = 3
		return true
	return true


# --- 步骤 6：建筑区块流式（出生点预加载）------------------------------------
## 仅当 blocks-manifest.json 存在时激活。此时 buildings.glb 已被 _plan_buildings 跳过，
## 由 chunk_streamer 按 640m 区块加载：先把出生点 LOAD_RADIUS(3000m) 内一次性铺满，
## 保证角色落地即"离边界约 3km"；运行时再随移动加载/卸载（见 chunk_streamer.update_system）。
## manifest 缺失则整步跳过，退化回 monolithic 老路径，工程照常可跑。
func _plan_chunks() -> bool:
	if chunk_streamer == null or not ChunkStreamer.manifest_available():
		return true
	if not chunk_streamer.active:
		chunk_streamer.setup(self)
		if not chunk_streamer.init_manifest():
			return true
	var f := _focus_data
	if f == Vector2.ZERO:
		f = CityData.spawn_pos
	match _phase:
		"":
			chunk_streamer.begin_preload(f)
			_phase = "wait"
			return false
		"wait":
			chunk_streamer.poll_preload()
			return bool(chunk_streamer.preload_done())
	return true


# --- 步骤 7：立面 -----------------------------------------------------------
## 出生点附近的立面瓦片在**加载阶段**一次性预载完。
## 原实现只在 init_streaming 里建清单就返回 true，剩下的瓦片留给行驶途中
## 逐个加载 —— 每块 5~7MB 的 GLB 在开车时入队会在那一帧砸出明显卡顿。
func _plan_facades() -> bool:
	if facades == null:
		return true
	if facades.has_method("setup"):
		facades.call("setup", self)
	if not facades.has_method("init_streaming"):
		return true
	# _focus_data 要等 main_game 每帧调 set_focus() 才有值，这一步发生在
	# 城市构建期间，此时它还是 (0,0)。直接用它初始化会让立面瓦片围着
	# 地图原点加载、而不是围着出生点，玩家一落地周围全是空立面。
	var f := _focus_data
	if f == Vector2.ZERO:
		f = CityData.spawn_pos
	match _phase:
		"":
			facades.call("init_streaming", f)
			facades.call("begin_preload", f)
			_phase = "wait"
			return false
		"wait":
			facades.call("poll_preload")
			return bool(facades.call("preload_done"))
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
	# 远景城市壳：同样在后台线程建网格，这里只负责点火
	if distant_city != null and distant_city.has_method("build_all"):
		distant_city.build_all(self)
	return true


# --- 步骤 9：植被 -----------------------------------------------------------
func _plan_scenery() -> bool:
	if scenery != null and scenery.has_method("setup"):
		scenery.setup(self)
	return true


# --- 步骤 12：地面材质注入 ----------------------------------------------
## 公共照明场 clipmap + 烘焙 AO + 草地分层。必须在 _plan_road_surface **之后**：
## 本层接管路面材质时要把 road_surface 标定好的反照率/粗糙度抄进自己的着色器。
func _plan_ground_field() -> bool:
	if ground_field == null or _ground_field_done:
		return true
	ground_field.setup(self)
	_ground_field_done = true
	return true


# --- 步骤 13：屋顶设备 ------------------------------------------------------
## 停机坪 / 设备房 / 冷却塔 / 水箱 / 天线 / 光伏 / 天窗 / 通风管。
## 数据是离线生成的 7.7 万条实例，这里只做半径 + 预算筛选与分帧写入。
func _plan_rooftops() -> bool:
	if rooftop_layer == null or _rooftops_done:
		return true
	rooftop_layer.setup(self)
	_rooftops_done = true
	return true


# --- 步骤 14：建筑立面材质 --------------------------------------------------
## 28 个 profile 按材质角色套到普通楼体与地标上（原版 city-architecture-materials.ts）。
func _plan_arch_materials() -> bool:
	if arch_materials == null or _arch_materials_done:
		return true
	arch_materials.setup(self)
	_arch_materials_done = true
	return true


# --- 步骤 15：观察模式信标 --------------------------------------------------
## 需要碰撞索引与高度场，所以放在两者的宿主（CityWorld）里建。
func _plan_beacons() -> bool:
	if beacons == null or _beacons_done:
		return true
	beacons.setup(self)
	_beacons_done = true
	return true


# --- 步骤 16：招牌与街具 ----------------------------------------------------
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

func _on_entry_loaded(path: String, node: Node3D, meta: Variant, _scene: Resource = null) -> void:
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


## 从 landmark-detail / landmark-candidates 里解析 `detail_block_i_j_` 分块名。
##
## `detail == false`（候选地标）时，还要先过一道 isCandidateGroundSlab 闸门：
## 候选模型里的 `_water` / 扁平 `_park` 平板不属于地标本体，留着重则盖住路面
## （原版是 `m.dispose(false,false)` 直接销毁，见 city-world.ts 的候选装载循环）。
## 候选去重：同一网格被实例化两份、完全共面（AABB 逐位相同）→ z-fighting
## 闪烁。实测 landmark_baypark_concrete（4mm 薄板、841×182m）就有两份拷贝，
## 叠在一起整片广场闪烁。键 = 名字 + 归一化变换；首份保留，后续释放。
var _candidate_dedupe := {}


func _collect_landmark_chunks(root: Node3D, detail: bool) -> void:
	var re := RegEx.new()
	re.compile("detail_block_(-?\\d+)_(-?\\d+)_")
	var slab_re := RegEx.new()
	if not detail:
		slab_re.compile(CANDIDATE_SLAB_RE)
		_ensure_candidate_kinds()
	var slabs := 0
	var dups := 0
	for mi in GlbLoader.meshes_of(root):
		if not detail and _is_candidate_ground_slab(mi, slab_re):
			mi.queue_free()
			slabs += 1
			continue
		# 中湾广场的水泥薄板（4mm 厚、y=0.134）与下方 terrain_pavement /
		# coastal_shore 条带（y≈0.1–0.4）只差几厘米，远距离深度精度分不开
		# → 整片闪烁。terrain_pavement 现在是同款石材铺装（kind=1）且覆盖它，
		# 这块板是冗余的，直接丢。
		if not detail and mi.name.begins_with("landmark_baypark_concrete"):
			mi.queue_free()
			slabs += 1
			continue
		# 共面拷贝去重（只对候选做；变换取 0.01m/0.001rad 精度防浮点噪声）
		var xf := mi.global_transform
		var dup_key := "%s|%s" % [mi.name,
			"%s|%s" % [xf.origin.snapped(Vector3(0.01, 0.01, 0.01)),
				xf.basis.get_rotation_quaternion().get_euler().snapped(
					Vector3(0.001, 0.001, 0.001))]]
		if _candidate_dedupe.has(dup_key):
			mi.queue_free()
			dups += 1
			continue
		_candidate_dedupe[dup_key] = true
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
	if slabs > 0:
		print("[CityWorld] 候选地标：丢弃地面平板 %d 个" % slabs)
	if dups > 0:
		print("[CityWorld] 候选地标：去重共面拷贝 %d 个" % dups)


## 原版 isCandidateGroundSlab()：候选地标的 `_water` 平板一律丢；`_park` 平板
## 只在它属于 park 类候选、且世界高度跨度 < 1.5 m（即"平板"而非地形）时丢。
func _is_candidate_ground_slab(mi: MeshInstance3D, re: RegEx) -> bool:
	var m := re.search(mi.name)
	if m == null:
		return false
	if m.get_string(2) == "water":
		return true
	if str(_candidate_kinds.get(m.get_string(1), "")) != "park":
		return false
	# 跨度取世界空间包围盒高度（原版用 boundingBox.maximumWorld − minimumWorld）。
	# 用 Mesh 资源自己的 AABB（确定是网格本地空间）再乘实例的世界变换，
	# 不依赖 MeshInstance3D.get_aabb() 的坐标空间约定。
	if mi.mesh == null:
		return false
	var box := mi.global_transform * mi.mesh.get_aabb()
	return box.size.y < CANDIDATE_PARK_SLAB_MAX_SPAN


## 候选地标 id → candidateKind。原版是
## `manifest.landmarks.find(l => l.id.replace(/-/g,'_') === match[1])`，
## 这里预先摊平成字典，避免每个平板都线性扫 37 条。
func _ensure_candidate_kinds() -> void:
	if not _candidate_kinds.is_empty():
		return
	for lm in CityData.landmark_candidates.get("landmarks", []):
		_candidate_kinds[str(lm.get("id", "")).replace("-", "_")] = str(lm.get("candidateKind", ""))


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
	if chunk_streamer != null and chunk_streamer.active:
		chunk_streamer.set_aerial(v)
	else:
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
	var c := {
		"blocks": blocks.size(),
		"landmarks": landmark_nodes.size(),
		"glbLoaded": stats_loaded,
		"glbFailed": stats_failed,
		"chunks": _chunk_index.size(),
	}
	if chunk_streamer != null:
		c["chunkStreamer"] = chunk_streamer.diagnostics()
	return c


func diagnostics() -> Dictionary:
	return {
		"ready": city_ready,
		"aerial": aerial,
		"focus": [focus.x, focus.y, focus.z],
		"heightField": height_field.stats(),
		"collision": collision.stats(),
		"graph": graph.stats(),
		"counts": counts(),
		"chunkStreamer": chunk_streamer.diagnostics() if chunk_streamer != null else {},
		"groundField": ground_field.diagnostics() if ground_field != null else {},
		"rooftops": rooftop_layer.diagnostics() if rooftop_layer != null else {},
		"archMaterials": arch_materials.diagnostics() if arch_materials != null else {},
		"beacons": beacons.diagnostics() if beacons != null else {},
		"subsystems": {
			"sky": sky != null, "lighting": lighting != null, "water": water != null,
			"weather": weather != null, "scenery": scenery != null, "signs": signs != null,
			"distant": distant != null, "signals": signals != null,
			"traffic": traffic != null, "pedestrians": pedestrians != null, "ebikes": ebikes != null,
			"groundField": ground_field != null,
		},
	}
