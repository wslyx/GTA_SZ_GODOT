extends Node3D
class_name EbikeSystem
##
## 电动摩托 / 电动自行车 —— 逐行移植原版 src/city-ebikes.ts。
##
## 数据：city/ebikes/parked.json
##   bikes: 21110 条 [x, z, yaw, type, palette, lean]
##   type: 0 scooter / 1 bicycle / 2 delivery
##   palette: 11 色车身 + 2 个外卖配色
##
## 渲染：按 type 分组做 MultiMesh，逐实例写 color 实现车身/骑手服/头盔着色。
## 可见范围：原版用 80m 格 3×3 邻域，街道半径 220、上限 700；空中半径 260、上限 500。
##
## 骑手（NPC）：默认 18 个，沿 RoadGraph 边行进，速度 5.5–9，
## 路缘偏移 2.15m；前方 5m 内有红灯停线、或同向骑手在 3.2m 内则停下。

const NEARBY_RADIUS_STREET := 220.0
const NEARBY_RADIUS_AERIAL := 260.0
const LIMIT_STREET := 700
const LIMIT_AERIAL := 500
const RIDER_COUNT := 18
const RIDER_KERB_OFFSET := 2.15
const RIDER_STOP_SIGNAL := 5.0
const RIDER_STOP_GAP := 3.2

var world: CityWorld
var graph: RoadGraph
var signals: TrafficSignals
var enabled := true

var bikes: Array = []          ## Vector4(x, z, yaw, type) + palette + lean
var palette: Array = []
var delivery_colours: Array = []
var riders: Array = []
var origin := Vector2.ZERO

var _multimeshes: Array = []   ## 每 type × 每 mesh role
## 停车排空间索引：21110 辆全量扫太重
var _bike_points := PackedVector2Array()
var _bike_grid: PointGrid
var _rng := RandomNumberGenerator.new()
var _built := false
## 停车排重扫间隔：21110 辆车逐个测距，不能每帧都来
const RESCAN_INTERVAL := 0.5
## 重扫移动阈值：车是静止的，焦点挪动不到 30m 时可见集合几乎不变，
## 跳过整轮「查询 + 排序 + 700 次实例重写」。原实现**没有任何跳过条件**，
## 原地不动也每 0.5s 白付一轮，是最稳定的周期性尖峰。
const REBUILD_MOVE := 30.0
var _rescan_timer := 0.0
var _last_origin := Vector2(INF, INF)
var _last_aerial := false
## 每车缓存：车是静止的，Transform3D / 颜色算一次就够。
## 原实现每次重扫都对选中的 700 辆各调一次 ground_height()（五层采样）
## 并重建 Basis —— 这些结果永远不变，纯浪费。
var _bike_xf: Array = []
var _bike_col: Array = []


func setup(p_world: CityWorld) -> void:
	world = p_world
	graph = p_world.graph
	signals = p_world.signals
	_rng.seed = 20250918
	var data: Dictionary = CityData.parked_ebikes()
	palette = data.get("palette", [])
	delivery_colours = data.get("deliveryColours", [])
	var raw: Array = data.get("bikes", [])
	bikes.clear()
	for e in raw:
		if e.size() < 6:
			continue
		bikes.append({
			"x": float(e[0]), "z": float(e[1]), "yaw": float(e[2]),
			"type": int(e[3]), "palette": int(e[4]), "lean": float(e[5]),
		})
	_load_asset()
	# 网格索引：21110 辆全量扫（每 0.5s）太重
	_bike_points.resize(bikes.size())
	for i in bikes.size():
		_bike_points[i] = Vector2(float(bikes[i]["x"]), float(bikes[i]["z"]))
	_bike_grid = PointGrid.new(128.0)
	_bike_grid.build(_bike_points)
	print("[EbikeSystem] 停车排 %d 辆，配色 %d 种，索引单元 128m" % [bikes.size(), palette.size()])
	# spawn_riders 之前在整个仓库里**没有任何调用点**，riders 恒为空数组，
	# diagnostics() 的 "riders" 永远是 0。这里按出生点补上生成。
	# 注意：骑手目前只有数据、没有渲染实体（本移植未提供骑手模型），
	# 所以这里是"状态正确"，不是"可见的 NPC"。
	spawn_riders(CityData.spawn_pos.x, CityData.spawn_pos.y)


func _load_asset() -> void:
	var path := "res://data/city/ebikes/ebikes.glb"
	if not ResourceLoader.exists(path):
		push_warning("[EbikeSystem] 缺少电摩模型")
		return
	var scene := load(path) as PackedScene
	if scene == null:
		return
	var inst := scene.instantiate()
	var type_names := ["scooter", "bicycle", "delivery"]
	for t in type_names.size():
		for mi in GlbLoader.meshes_of(inst):
			if not mi.name.to_lower().begins_with("ebike-%s" % type_names[t]):
				continue
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.mesh = mi.mesh
			var node := MultiMeshInstance3D.new()
			node.multimesh = mm
			node.name = "ebike-%s-%d" % [type_names[t], _multimeshes.size()]
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(node)
			_multimeshes.append({"mm": mm, "type": t, "mesh_name": mi.name})
	inst.queue_free()
	_built = true


func _colour_for(type_idx: int, palette_idx: int) -> Color:
	if palette.is_empty():
		return Color(0.6, 0.6, 0.62)
	# deliveryColours 的元素是**调色板下标**（如 [9, 10]），不是颜色数组
	var idx := palette_idx
	if type_idx == 2 and not delivery_colours.is_empty():
		idx = int(delivery_colours[palette_idx % delivery_colours.size()])
	var p: Array = palette[idx % palette.size()]
	if p.size() < 3:
		return Color(0.6, 0.6, 0.62)
	return Color(float(p[0]), float(p[1]), float(p[2]))


func update_system(delta: float, focus: Vector3) -> void:
	if not enabled or not _built:
		return
	var px := focus.x
	var pz := -focus.z
	if bikes.is_empty():
		return
	# 节流：_build_parked 每次要扫全部 21110 辆，每帧跑会把主线程拖死
	_rescan_timer -= delta
	if _rescan_timer > 0.0:
		return
	_rescan_timer = RESCAN_INTERVAL
	if origin == Vector2.ZERO:
		origin = Vector2(px, pz)
	# 跳过条件：焦点几乎没动且视角模式没变 → 可见集合不变，直接返回。
	# （traffic / pedestrian / canopy 都有同样的阈值机制，唯独这里原来没有。）
	var cur := Vector2(px, pz)
	if cur.distance_to(_last_origin) < REBUILD_MOVE and _last_aerial == (world != null and world.aerial):
		return
	_last_origin = cur
	_last_aerial = world != null and world.aerial
	_build_parked(px, pz, _last_aerial)


## 只渲染焦点附近的停车排（对应原版 80m 格 3×3 邻域 + 上限）。
## 用网格索引取半径内的车，不再全量扫 21110 辆。
## Transform3D / 颜色按车缓存：车是静止的，重复计算毫无意义。
func _build_parked(px: float, pz: float, aerial: bool) -> void:
	var radius := NEARBY_RADIUS_AERIAL if aerial else NEARBY_RADIUS_STREET
	var limit := LIMIT_AERIAL if aerial else LIMIT_STREET
	var chosen: Array = []
	if _bike_grid != null:
		var center := Vector2(px, pz)
		# 距离升序取前 limit 辆（Vector2 承载 idx/dist，不建临时字典）
		var scored := _bike_grid.query_radius_sorted2(center, radius, _bike_points)
		for i in mini(limit, scored.size()):
			chosen.append(int(scored[i].x))
	if _bike_xf.size() != bikes.size():
		_bike_xf.resize(bikes.size())
		_bike_col.resize(bikes.size())
	var by_type := [[], [], []]
	for idx in chosen:
		by_type[int(bikes[idx]["type"])].append(idx)

	for entry in _multimeshes:
		var t := int(entry["type"])
		var list: Array = by_type[t]
		var mm: MultiMesh = entry["mm"]
		mm.instance_count = list.size()
		mm.visible_instance_count = list.size()
		for i in list.size():
			var bi: int = list[i]
			var xf = _bike_xf[bi]
			if xf == null:
				xf = _compute_bike_xf(bikes[bi])
				_bike_xf[bi] = xf
			mm.set_instance_transform(i, xf)
			var col = _bike_col[bi]
			if col == null:
				col = _colour_for(t, int(bikes[bi]["palette"]))
				_bike_col[bi] = col
			mm.set_instance_color(i, col)


## 一辆停车电摩的世界变换（数据不变 → 结果不变，算一次缓存在 _bike_xf）
func _compute_bike_xf(b: Dictionary) -> Transform3D:
	# 不能叫 basis —— Node3D 已有 basis 属性，本地变量重名会触发
	# SHADOWED_VARIABLE_BASE_CLASS 告警
	var xf_basis := Basis(Vector3.UP, CoordinateUtil.node_yaw(float(b["yaw"])))
	# 车身倾角
	if absf(float(b["lean"])) > 0.001:
		xf_basis = xf_basis.rotated(Vector3.FORWARD, float(b["lean"]))
	var g := world.ground_height(float(b["x"]), -float(b["z"]))
	return Transform3D(xf_basis, CoordinateUtil.to_world(float(b["x"]), float(b["z"]), g))


## 骑手 NPC（原版默认 18 个）
func spawn_riders(px: float, pz: float) -> void:
	riders.clear()
	if graph == null or graph.nodes.is_empty():
		return
	for i in RIDER_COUNT:
		var node := graph.nearest_node_in_range(Vector2(px, pz), 30.0, 500.0, true)
		if node < 0:
			continue
		var nxt := graph.neighbor_ids(node)
		if nxt.is_empty():
			continue
		riders.append({
			"from": node, "to": nxt[_rng.randi_range(0, nxt.size() - 1)],
			"t": _rng.randf(),
			"speed": 5.5 + _rng.randf() * 3.5,
			"x": 0.0, "z": 0.0, "yaw": 0.0,
		})


func diagnostics() -> Dictionary:
	return {"parked": bikes.size(), "multimeshes": _multimeshes.size(),
			"riders": riders.size(), "enabled": enabled, "built": _built}
