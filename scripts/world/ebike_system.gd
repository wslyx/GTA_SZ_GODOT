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
## 骑手实体与停车排**共用同一个 ebikes.glb** —— 原版就是这样：
## 该 GLB 里除了 scooter / bicycle / delivery 三种车，还有一组 `ebike-rider_*`
## 网格（rider_cloth / rider_dark / rider_helmet / rider_skin）。
##
## ⚠️ 逐实例染色：ebikes.glb 的顶点里**没有 COLOR_0**，而 Godot 的
## StandardMaterial3D 默认不把顶点色乘进 albedo。MultiMesh.set_instance_color()
## 在 `vertex_color_use_as_albedo = false` 时是**静默无效**的 —— 所以这里必须
## 显式打开该开关，否则 11 色车身 / 骑手服 / 头盔全都退化成模型自带的白/灰。
## 同时：**只有** paint / cloth / helmet 三类材质参与染色，其余（轮胎、车座、
## 车灯、皮肤）必须显式写白色，否则会被当成同色件涂成车身色。

const NEARBY_RADIUS_STREET := 220.0
const NEARBY_RADIUS_AERIAL := 260.0
const LIMIT_STREET := 700
const LIMIT_AERIAL := 500

## --- 骑手（原版 city-ebikes.ts 的 Rider 常量）------------------------------
const RIDER_COUNT := 18
const RIDER_KERB_OFFSET := 2.15
const RIDER_STOP_SIGNAL := 5.0
const RIDER_STOP_GAP := 3.2
## 原版 `if (Math.hypot(r.x-x,r.z-z)>420) continue;` —— 超出则不渲染（仍然推进）
const RIDER_RENDER_DIST := 420.0
## 原版 `if (...>450) this.place(x,z);` —— 玩家移动超过则重新布骑手
const RIDER_REPLACE_DIST := 450.0
const RIDER_MIN_DIST := 30.0
const RIDER_MAX_DIST := 500.0
## 前 8 个骑手只从最近的 40 个候选节点里挑（原版 `i<8 ? 40 : ...`）
const RIDER_NEAR_POOL := 40
## 骑手推进节流：与车流一致，10Hz 足够（5.5–9 m/s → 0.1s 位移 < 1m）
const RIDER_SYNC_INTERVAL := 0.1
## 贴在路面上，与原版 `heightAt(...)+.01` 一致
const RIDER_GROUND_LIFT := 0.01

var world: CityWorld
var graph: RoadGraph
var signals: TrafficSignals
var enabled := true

var bikes: Array = []          ## {x, z, yaw, type, palette, lean}
var palette: Array = []
var delivery_colours: Array = []
var rider_palette: Array = []
var helmet_palette: Array = []
var riders: Array = []
var origin := Vector2.ZERO

var _multimeshes: Array = []   ## 停车排：每 type × 每 mesh role
var _rider_nodes: Array = []   ## 骑手：ebike-rider_* 的 4 个 mesh role
## 停车排空间索引：21110 辆全量扫太重
var _bike_points := PackedVector2Array()
var _bike_grid: PointGrid
## 路网节点索引（布骑手用：原版是全量扫 42829 个节点 + sort，这里走网格）
var _node_grid: PointGrid
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
## 骑手推进节流状态
var _rider_timer := 0.0
var _rider_acc := 0.0
## 上一轮真的画出来的骑手数（诊断用）
var _riders_visible := 0
## MultiMesh 的 「非染色件」实例色。必须显式写，不能依赖默认值。
const NO_TINT := Color(1.0, 1.0, 1.0)


func setup(p_world: CityWorld) -> void:
	world = p_world
	graph = p_world.graph
	signals = p_world.signals
	_rng.seed = 20250918
	var data: Dictionary = CityData.parked_ebikes()
	palette = data.get("palette", [])
	delivery_colours = data.get("deliveryColours", [])
	# riderPalette / helmetPalette 在 ebikes/manifest.json（原版也从那里读）
	var man: Dictionary = CityData.ebike_manifest()
	rider_palette = man.get("riderPalette", [])
	helmet_palette = man.get("helmetPalette", [])
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
	_build_node_index()
	print("[EbikeSystem] 停车排 %d 辆，配色 %d 种，索引单元 128m" % [bikes.size(), palette.size()])
	# 骑手：原版在 city-world 的 startTraffic 里调 ebikes.place()；这里按出生点补。
	spawn_riders(CityData.spawn_pos.x, CityData.spawn_pos.y)


func _build_node_index() -> void:
	if graph == null or graph.nodes.is_empty():
		return
	_node_grid = PointGrid.new(256.0)
	_node_grid.build(graph.nodes)


# ---------------------------------------------------------------------------
# 资源
# ---------------------------------------------------------------------------

## 材质名 → 染色角色（原版 `tint` Map）。
## ebike_paint → 车身色；rider_cloth → 骑手服色；rider_helmet → 头盔色；其余不染。
static func _tint_role(material_name: String) -> String:
	var n := material_name.to_lower()
	if n.begins_with("ebike_paint"):
		return "paint"
	if n.begins_with("rider_cloth"):
		return "cloth"
	if n.begins_with("rider_helmet"):
		return "helmet"
	return ""


## 网格名 → 角色。原版：`mesh.name.split('_')[0].replace(/^ebike-/,'')`。
## ⚠️ 注意区别：**角色**取网格名（`ebike-scooter_ebike_paint` → `scooter`），
## **染色**取材质名（`ebike_paint`）。旧移植版把两者都当成网格名去判，
## 于是每辆车都"有角色、无染色"。
static func _role_of(mesh_name: String) -> String:
	var i := mesh_name.find("_")
	var head := mesh_name if i < 0 else mesh_name.substr(0, i)
	return head.replace("ebike-", "")


## 一个网格的染色角色（取它第一个参与染色的 surface 材质）
static func _mesh_tint(mesh: Mesh) -> String:
	if mesh == null:
		return ""
	for s in mesh.get_surface_count():
		var mat: Material = mesh.surface_get_material(s)
		if mat == null:
			continue
		var r := _tint_role(str(mat.resource_name))
		if r != "":
			return r
	return ""


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
	for mi in GlbLoader.meshes_of(inst):
		var role := _role_of(mi.name.to_lower())
		var is_vehicle := type_names.has(role)
		var is_rider := role == "rider"
		if not is_vehicle and not is_rider:
			continue
		_enable_instance_tint(mi.mesh)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = mi.mesh
		var node := MultiMeshInstance3D.new()
		node.multimesh = mm
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var entry := {"mm": mm, "mesh_name": mi.name, "tint": _mesh_tint(mi.mesh)}
		if is_vehicle:
			entry["type"] = type_names.find(role)
			node.name = "ebike-%s-%d" % [role, _multimeshes.size()]
			_multimeshes.append(entry)
		else:
			node.name = "ebike-rider-%d" % _rider_nodes.size()
			_rider_nodes.append(entry)
		add_child(node)
	inst.queue_free()
	_built = true
	print("[EbikeSystem] 停车排 mesh %d 个 / 骑手 mesh %d 个（染色开启）"
		% [_multimeshes.size(), _rider_nodes.size()])


## 让逐实例染色真的生效。
##
## 只对参与染色的三类材质打开 `vertex_color_use_as_albedo`：
## 打开后 instance color 会乘进 albedo，因此调用方**必须**给所有实例都写色
## （未染色件写白色），否则会继承 MultiMesh 缓冲区里的初值。
func _enable_instance_tint(mesh: Mesh) -> void:
	if mesh == null:
		return
	for s in mesh.get_surface_count():
		var mat: Material = mesh.surface_get_material(s)
		if mat == null:
			continue
		if _tint_role(str(mat.resource_name)) == "":
			continue
		var sm := mat as StandardMaterial3D
		if sm == null:
			continue
		sm.vertex_color_use_as_albedo = true


## 车身色。
##
## 原版就是 `this.palette[colour]` —— `parked.json` 的 palette 字段本来就是**绝对**
## 调色板下标（0–8 普通色 / 9、10 两个外卖色，实测 type 2 只出现 9 和 10）。
## 旧移植版多绕了一层 `deliveryColours` 查表，等于把外卖车的两个配色对调了。
func _colour_for(_type_idx: int, palette_idx: int) -> Color:
	return _palette_colour(palette, palette_idx, Color(0.6, 0.6, 0.62))


## 调色板取色。palette 元素是 [r,g,b] 或 [r,g,b,a]。
static func _palette_colour(tab: Array, idx: int, fallback: Color) -> Color:
	if tab.is_empty():
		return fallback
	var p = tab[posmod(idx, tab.size())]
	if not (p is Array) or (p as Array).size() < 3:
		return fallback
	var a: Array = p
	return Color(float(a[0]), float(a[1]), float(a[2]))


# ---------------------------------------------------------------------------
# 每帧
# ---------------------------------------------------------------------------

func update_system(delta: float, focus: Vector3) -> void:
	if not enabled or not _built:
		return
	var px := focus.x
	var pz := -focus.z

	# —— 骑手：与车流同样做成定频推进，避免每帧重写 MultiMesh ——
	_rider_acc += delta
	_rider_timer -= delta
	if _rider_timer <= 0.0:
		_rider_timer = RIDER_SYNC_INTERVAL
		_update_riders(px, pz, clampf(_rider_acc, 0.0, 0.5))
		_rider_acc = 0.0

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
	# 供 _flush_vehicles 与骑行中的车合并写入（骑行骑手每 0.1s 刷新，
	# 停车排 0.5s 才重建一次 —— 缓存选中列表让两条路径共用同一批 MultiMesh）
	_parked_chosen = chosen
	_flush_vehicles()


## 把「停车排 + 骑行中的车」合并写进按 type 分组的车辆 MultiMesh。
## ⚠️ 骑行中的车此前**根本没画**：_sync_riders 只推了骑手网格 —— 原版是把
## 同一矩阵同时推给 buffers[r.type]（车）和 rider，缺了车体，路上就只剩
## 悬空坐着的骑手。
var _parked_chosen: Array = []
## 骑行中的车：_riding_by_type[type] = [{xf: Transform3D, paint: int}, ...]
var _riding_by_type: Array = [[], [], []]


func _flush_vehicles() -> void:
	for entry in _multimeshes:
		var t := int(entry["type"])
		var tint: String = str(entry.get("tint", ""))
		var mm: MultiMesh = entry["mm"]
		var parked: Array = []
		for bi in _parked_chosen:
			if int(bikes[bi]["type"]) == t:
				parked.append(bi)
		var riding: Array = _riding_by_type[t] if t >= 0 and t < _riding_by_type.size() else []
		var total := parked.size() + riding.size()
		mm.instance_count = total
		mm.visible_instance_count = total
		var write_i := 0
		# 只有 ebike_paint 面吃车身色；其余件写白色，否则会被当成车漆一起涂
		for bi in parked:
			var xf = _bike_xf[bi]
			if xf == null:
				xf = _compute_bike_xf(bikes[bi])
				_bike_xf[bi] = xf
			mm.set_instance_transform(write_i, xf)
			if tint != "paint":
				mm.set_instance_color(write_i, NO_TINT)
			else:
				var col = _bike_col[bi]
				if col == null:
					col = _colour_for(t, int(bikes[bi]["palette"]))
					_bike_col[bi] = col
				mm.set_instance_color(write_i, col)
			write_i += 1
		for rb in riding:
			mm.set_instance_transform(write_i, rb["xf"])
			mm.set_instance_color(write_i,
					_colour_for(t, int(rb["paint"])) if tint == "paint" else NO_TINT)
			write_i += 1


## 一辆停车电摩的世界变换（数据不变 → 结果不变，算一次缓存在 _bike_xf）
func _compute_bike_xf(b: Dictionary) -> Transform3D:
	# 不能叫 basis —— Node3D 已有 basis 属性，本地变量重名会触发
	# SHADOWED_VARIABLE_BASE_CLASS 告警
	# ⚠️ ebikes.glb 实测前向是 **-Z**（前灯 _lamp z=-0.71 / 尾灯 redlamp z=+0.73，
	# 座垫偏 +Z），与轿车、飞机同一资产管线。此前用默认 PLUS_Z（PI−yaw）
	# 车头朝后 —— 路上的骑手全都"倒着骑"。
	var xf_basis := Basis(Vector3.UP,
			CoordinateUtil.node_yaw(float(b["yaw"]), CoordinateUtil.ModelForward.MINUS_Z))
	# 车身倾角：绕模型**自身前向轴**（局部 -Z）滚转，随车头方向一起转
	# （此前挂在全局 FORWARD 轴上，车头一转倾倒方向就错）
	if absf(float(b["lean"])) > 0.001:
		xf_basis = xf_basis * Basis(Vector3(0.0, 0.0, -1.0), float(b["lean"]))
	var g := world.ground_height(float(b["x"]), -float(b["z"]))
	return Transform3D(xf_basis, CoordinateUtil.to_world(float(b["x"]), float(b["z"]), g))


# ---------------------------------------------------------------------------
# 骑手 NPC（原版默认 18 个）
# ---------------------------------------------------------------------------

## 原版 CityEbikes.place()：在 30–500m、degree>1 的节点里随机撒 18 个骑手。
## 前 8 个只从最近的 40 个候选里挑（保证初期附近有骑手可看）。
func spawn_riders(px: float, pz: float) -> void:
	riders.clear()
	origin = Vector2(px, pz)
	if graph == null or graph.nodes.is_empty():
		return
	var p := Vector2(px, pz)
	# 候选节点：索引可用时只扫半径内；否则退回全量（首次布点前可能还没建好索引）
	var candidates: Array = []
	if _node_grid != null:
		for i in _node_grid.query_radius(p, RIDER_MAX_DIST):
			var d: float = graph.nodes[i].distance_to(p)
			if d > RIDER_MIN_DIST and d < RIDER_MAX_DIST and graph.degree(i) > 1:
				candidates.append(i)
	else:
		for i in graph.nodes.size():
			var d2: float = graph.nodes[i].distance_to(p)
			if d2 > RIDER_MIN_DIST and d2 < RIDER_MAX_DIST and graph.degree(i) > 1:
				candidates.append(i)
	if candidates.is_empty():
		return
	candidates.sort_custom(func(a, b):
		return graph.nodes[a].distance_to(p) < graph.nodes[b].distance_to(p))

	var guard := 0
	while riders.size() < RIDER_COUNT and guard < RIDER_COUNT * 3:
		guard += 1
		var pool := mini(candidates.size(), RIDER_NEAR_POOL) if guard <= 8 else candidates.size()
		if pool <= 0:
			break
		var from: int = int(candidates[_rng.randi_range(0, pool - 1)])
		var nxt := graph.neighbor_ids(from)
		if nxt.is_empty():
			continue
		var to: int = int(nxt[_rng.randi_range(0, nxt.size() - 1)])
		# 原版：type = random()<.5 ? 0 : (random()<.7 ? 1 : 2)
		var type_idx := 0
		if _rng.randf() >= 0.5:
			type_idx = 1 if _rng.randf() < 0.7 else 2
		var paint := 0
		if type_idx == 2:
			paint = [9, 10][_rng.randi_range(0, 1)]
		else:
			paint = _rng.randi_range(0, 8)
		var cloth := 0
		var helmet := 0
		if type_idx == 2:
			cloth = 5 if paint == 9 else 6
			helmet = 2 if paint == 9 else 3
		else:
			cloth = _rng.randi_range(0, 4)
			helmet = _rng.randi_range(0, maxi(helmet_palette.size() - 1, 0))
		riders.append({
			"from": from, "to": to, "t": _rng.randf(),
			"speed": 5.5 + _rng.randf() * 3.5,
			"x": 0.0, "z": 0.0, "yaw": 0.0,
			"type": type_idx, "paint": paint, "cloth": cloth, "helmet": helmet,
		})


func _update_riders(px: float, pz: float, dt: float) -> void:
	if graph == null or graph.nodes.is_empty():
		_riders_visible = 0
		return
	# 原版：`if (graph && Math.hypot(x-origin[0],z-origin[1])>450) this.place(x,z);`
	# 额外一条"空则重试"（原版没有）：首次布点若因附近没有 degree>1 的节点而落空，
	# 用 100 m 门槛重试，避免每 0.1 s 白跑一次半径查询。
	var moved := Vector2(px, pz).distance_to(origin)
	if moved > RIDER_REPLACE_DIST or (riders.is_empty() and moved > 100.0):
		spawn_riders(px, pz)
	_step_riders(dt)
	_sync_riders(px, pz)


## 原版 `step(dt)`：沿边推进，遇红灯停线（<5m）或同向骑手（<3.2m）则停。
func _step_riders(dt: float) -> void:
	for r in riders:
		var a: Vector2 = graph.nodes[int(r["from"])]
		var b: Vector2 = graph.nodes[int(r["to"])]
		var seg_len := a.distance_to(b)
		var hold := INF
		if signals != null:
			hold = signals.signal_hold(float(r["x"]), float(r["z"]), float(r["yaw"]))
		var queued := false
		var fy := sin(float(r["yaw"]))
		var fz := cos(float(r["yaw"]))
		for o in riders:
			if o == r:
				continue
			var dx := float(o["x"]) - float(r["x"])
			var dz := float(o["z"]) - float(r["z"])
			if sqrt(dx * dx + dz * dz) < RIDER_STOP_GAP and dx * fy + dz * fz > 0.0:
				queued = true
				break
		var stopped := hold < RIDER_STOP_SIGNAL or queued
		r["t"] = float(r["t"]) + dt * (0.0 if stopped else float(r["speed"])) / maxf(0.1, seg_len)

		# 到达节点后选下一条边（方向一致性 + 随机扰动 0.9）
		var guard := 0
		while float(r["t"]) >= 1.0 and guard < 12:
			guard += 1
			r["t"] = (float(r["t"]) - 1.0) * seg_len
			var old: int = int(r["from"])
			r["from"] = r["to"]
			a = graph.nodes[int(r["from"])]
			var best_score := -INF
			var best_next: int = old
			var old_pos: Vector2 = graph.nodes[old]
			var dxn := a.x - old_pos.x
			var dzn := a.y - old_pos.y
			for i in graph.neighbor_ids(int(r["from"])):
				if i == old:
					continue
				var p2: Vector2 = graph.nodes[i]
				var l := a.distance_to(p2)
				var score := (dxn * (p2.x - a.x) + dzn * (p2.y - a.y)) / maxf(0.1, seg_len * l) \
					+ _rng.randf() * 0.9
				if score > best_score:
					best_score = score
					best_next = i
			r["to"] = best_next
			b = graph.nodes[best_next]
			seg_len = a.distance_to(b)
			r["t"] = float(r["t"]) / maxf(0.1, seg_len)

		var yaw := atan2(b.x - a.x, b.y - a.y)
		# 原版：靠右偏移 —— x 上加 cos(yaw)*2.15，z 上减 sin(yaw)*2.15
		r["x"] = a.x + (b.x - a.x) * float(r["t"]) + cos(yaw) * RIDER_KERB_OFFSET
		r["z"] = a.y + (b.y - a.y) * float(r["t"]) - sin(yaw) * RIDER_KERB_OFFSET
		r["yaw"] = yaw


func _sync_riders(px: float, pz: float) -> void:
	if _rider_nodes.is_empty():
		_riders_visible = 0
		return
	var eye := Vector2(px, pz)
	var transforms: Array = []
	var cloth_cols: Array = []
	var helmet_cols: Array = []
	# 骑行中的车按 type 归集（与骑手同一矩阵 —— 原版 buffers[r.type] 与 rider
	# 共用一份变换），由 _flush_vehicles 合并停车排一起写入
	for arr in _riding_by_type:
		arr.clear()
	for r in riders:
		if Vector2(float(r["x"]), float(r["z"])).distance_to(eye) > RIDER_RENDER_DIST:
			continue
		var g := world.ground_height(float(r["x"]), -float(r["z"]))
		# ⚠️ ebikes.glb 前向 -Z（见 _compute_bike_xf 的实测记录），用 MINUS_Z
		var xf := Transform3D(
			Basis(Vector3.UP, CoordinateUtil.node_yaw(float(r["yaw"]),
					CoordinateUtil.ModelForward.MINUS_Z)),
			CoordinateUtil.to_world(float(r["x"]), float(r["z"]), g + RIDER_GROUND_LIFT))
		transforms.append(xf)
		cloth_cols.append(_palette_colour(rider_palette, int(r["cloth"]), NO_TINT))
		helmet_cols.append(_palette_colour(helmet_palette, int(r["helmet"]), NO_TINT))
		var ti := int(r["type"])
		if ti >= 0 and ti < _riding_by_type.size():
			_riding_by_type[ti].append({"xf": xf, "paint": int(r["paint"])})
	_riders_visible = transforms.size()
	for entry in _rider_nodes:
		var mm: MultiMesh = entry["mm"]
		var tint: String = str(entry.get("tint", ""))
		var src: Array = cloth_cols if tint == "cloth" else (helmet_cols if tint == "helmet" else [])
		mm.instance_count = transforms.size()
		mm.visible_instance_count = transforms.size()
		for i in transforms.size():
			mm.set_instance_transform(i, transforms[i])
			mm.set_instance_color(i, src[i] if not src.is_empty() else NO_TINT)
	_flush_vehicles()


func diagnostics() -> Dictionary:
	return {"parked": bikes.size(), "multimeshes": _multimeshes.size(),
			"riderMeshes": _rider_nodes.size(),
			"riders": riders.size(), "ridersVisible": _riders_visible,
			"enabled": enabled, "built": _built}
