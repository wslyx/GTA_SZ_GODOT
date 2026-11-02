extends Node3D
##
## 通缉与警察系统 —— GTA 式星级通缉 + 警车追捕。
##
## 设计要点（详见 docs/GTA化改进方案.md §2.1）：
##   - 通缉值 wanted_level 0–5 星 + 星内进度 heat 0–1；犯罪经 report_crime() 上报，
##     heat 溢出升星，脱离视野后逐档冷却降星。
##   - 警车是**数据字典**（与 TrafficSystem 的 cars 同款风格）：沿 RoadGraph 边行走，
##     到节点后贪心选"离玩家最近"的邻边，不跑全量 A*；渲染走 MultiMesh（10Hz 同步）。
##   - 逻辑全部在**数据坐标**（x=东，z=北），渲染前经 CoordinateUtil 转世界坐标
##     （与 traffic_system.gd 同一转换：世界 z = -数据北）。
##   - 本系统不直接改玩家载具：撞停效果经 `rammed` 信号交给 main_game 处理；
##     被捕/脱捕只发信号，重生循环留给 save_system 接入。
##
## 触发方（main_game.gd）：
##   - apply_car_motion 击倒数 > 0 → report_crime("hit_ped", pos, severity)
##   - 撞 AI 车 / 警车 → report_crime("hit_car"/"hit_cop")（内部自带冷却）
##   - 每帧 set_player_state(数据坐标, 速度) 供追捕/被捕判定

signal wanted_changed(level: int)
signal busted
signal escaped
signal rammed(force: float)
signal player_shot(dmg: float)

# ---------------------------------------------------------------------------
# 调参区（都按可玩性拍的中等值，接手后随便调）
# ---------------------------------------------------------------------------

## 每星警车数（下标=星级）
const COPS_BY_LEVEL := [0, 2, 3, 4, 6, 8]
## 每星警车极速 m/s（下标=星级；1 星比车流略快，5 星明显快）
const COP_SPEED_BY_LEVEL := [0.0, 14.0, 15.0, 16.0, 18.0, 20.0]
## 脱离视野后每档冷却时间（秒，下标=星级）：heat −0.25/档
const COOL_BY_LEVEL := [0.0, 12.0, 16.0, 20.0, 26.0, 34.0]
## 视野距离：最近警车超过它视为"脱离视野"
const SIGHT_DIST := 250.0
## 各犯罪类型的升星进度
const CRIME_HEAT := {
	"hit_ped": 0.45, "hit_car": 0.18, "hit_cop": 0.30, "carjack": 1.0, "weapon": 0.30,
}
## 同种犯罪冷却（秒）+ 收益递减
const CRIME_COOLDOWN := 2.0
const CRIME_DECAY := 0.6
## 警车生成距离带与间距
const SPAWN_MIN := 80.0
const SPAWN_MAX := 200.0
const COP_GAP := 15.0
## 丢弃半径：警车离玩家太远直接回收重刷
const COP_RECYCLE_DIST := 400.0
## 被捕判定：N 辆警车 8m 内 + 玩家几乎不动，持续 BUSTED_HOLD 秒
const BUSTED_COPS := 2
const BUSTED_RADIUS := 8.0
const BUSTED_SPEED := 2.0
const BUSTED_HOLD := 4.0
## 警车顶撞玩家：相对速度与距离阈值
const RAM_DIST := 4.0
const RAM_SPEED := 8.0
## 3 星以上无视红灯（追捕强度）
const RUN_SIGNAL_LEVEL := 3
## 警察开火：3 星起、70m 内、每警车 1.3s 一发（命中率随距离衰减）。
## 命中只发 player_shot 信号，掉血/死亡结算在 main_game（车载免伤，v1 只打步行玩家）。
const COP_FIRE_MIN_LEVEL := 3
const COP_FIRE_RANGE := 70.0
const COP_FIRE_INTERVAL := 1.3

## 渲染（与 TrafficSystem 同款节流）
const SYNC_INTERVAL := 0.1
const KERB_OFFSET := 1.15
const CAR_HEIGHT := 0.14

## 警用涂装：白车身（traffic-car.glb 的 paint 面重染）
const POLICE_PAINT := Color(0.93, 0.94, 0.95)

# ---------------------------------------------------------------------------
# 状态
# ---------------------------------------------------------------------------

var world: CityWorld
var enabled := true

## 通缉值（0–5 星；heat 为当前星内进度 0–1）
var wanted_level := 0
var heat := 0.0
## 是否处于"已被捕"流程（捕后等待重生接线，期间不再追捕）
var busted_handled := false

## 警车列表：{from,to,t,speed,x,z,yaw}（数据坐标）
var cops: Array = []

## 玩家状态（main_game 每帧喂；数据坐标）
var _player_pos := Vector2.ZERO
var _player_speed := 0.0
var _player_valid := false

var _crime_cd := {}            ## kind → 剩余冷却秒
var _crime_repeat := {}        ## kind → 连续次数（收益递减）
var _out_of_sight := 0.0       ## 脱离视野累计秒
var _busted_t := 0.0           ## 被捕条件持续秒
var _cop_dirty := false        ## 警力数量需重算

## 渲染
var _source_meshes: Array = []
var _multimeshes: Array = []   ## [{mm, mesh_index}]
var _mesh_built := false
var _sync_timer := 0.0
var _sync_acc := 0.0
var _manage_timer := 0.0

var _rng := RandomNumberGenerator.new()


func setup(p_world: CityWorld) -> void:
	world = p_world
	_rng.seed = 20261102
	_load_car_asset()
	if world.pedestrians == null:
		push_warning("[WantedSystem] world.pedestrians 缺失，撞人触发要靠 main_game 上报")


# ---------------------------------------------------------------------------
# 犯罪上报
# ---------------------------------------------------------------------------

## severity 0–1（如撞击速度归一）；pos 数据坐标。
func report_crime(kind: String, pos: Vector2, severity := 1.0) -> void:
	if not enabled:
		return
	if _crime_cd.get(kind, 0.0) > 0.0:
		return
	_crime_cd[kind] = CRIME_COOLDOWN
	var n := int(_crime_repeat.get(kind, 0))
	_crime_repeat[kind] = n + 1
	var base := float(CRIME_HEAT.get(kind, 0.2))
	add_heat(base * severity * pow(CRIME_DECAY, float(n)))
	# 犯罪地点附近的警力立刻有了目标感：重算一次部署
	_cop_dirty = true


func add_heat(amount: float) -> void:
	if amount <= 0.0:
		return
	heat += amount
	while heat >= 1.0 and wanted_level < 5:
		heat -= 1.0
		_set_level(wanted_level + 1)
	if wanted_level >= 5:
		heat = minf(heat, 0.99)
	_out_of_sight = 0.0


func _set_level(lv: int) -> void:
	if lv == wanted_level:
		return
	wanted_level = clampi(lv, 0, 5)
	_cop_dirty = true
	wanted_changed.emit(wanted_level)


# ---------------------------------------------------------------------------
# 玩家状态喂入
# ---------------------------------------------------------------------------

func set_player_state(pos_data: Vector2, speed: float) -> void:
	_player_pos = pos_data
	_player_speed = speed
	_player_valid = true


# ---------------------------------------------------------------------------
# 每帧
# ---------------------------------------------------------------------------

func update_system(delta: float, focus: Vector3) -> void:
	if not enabled:
		return
	# 冷却与衰减（无条件推进，即使还没建好也能走）
	for k in _crime_cd:
		_crime_cd[k] = maxf(0.0, float(_crime_cd[k]) - delta)
	if wanted_level <= 0:
		_crime_repeat.clear()
	if not _player_valid:
		# 没喂过玩家状态时兜底用相机位置（世界 z = -数据北，同 TrafficSystem 约定）
		_player_pos = Vector2(focus.x, -focus.z)
	_step_wanted(delta)
	_manage_timer -= delta
	# _cop_dirty：升星/犯罪上报后立即重算部署，不等 0.5s 周期
	if _manage_timer <= 0.0 or _cop_dirty:
		_manage_timer = 0.5
		_cop_dirty = false
		_manage_cops()
	_step_cops(delta)

	# 渲染同步节流
	_sync_timer -= delta
	_sync_acc += delta
	if _sync_timer > 0.0:
		return
	_sync_timer = SYNC_INTERVAL
	_sync_instances()
	_sync_acc = 0.0


func _step_wanted(delta: float) -> void:
	if wanted_level <= 0 or busted_handled:
		return
	# 脱离视野判定：最近警车距离
	var nearest := INF
	for c in cops:
		nearest = minf(nearest, Vector2(c["x"], c["z"]).distance_to(_player_pos))
	if nearest > SIGHT_DIST:
		_out_of_sight += delta
		# 冷却只在脱离视野后走
		var cool := float(COOL_BY_LEVEL[wanted_level])
		if cool > 0.0 and _out_of_sight >= cool:
			_out_of_sight = 0.0
			heat -= 0.25
			if heat <= 0.0:
				if wanted_level > 1:
					heat = 0.75
					_set_level(wanted_level - 1)
				else:
					heat = 0.0
					_set_level(0)
					escaped.emit()
	else:
		_out_of_sight = 0.0

	# 被捕判定
	var near_cops := 0
	for c in cops:
		if Vector2(c["x"], c["z"]).distance_to(_player_pos) < BUSTED_RADIUS:
			near_cops += 1
	if near_cops >= BUSTED_COPS and _player_speed < BUSTED_SPEED:
		_busted_t += delta
		if _busted_t >= BUSTED_HOLD and not busted_handled:
			busted_handled = true
			busted.emit()
	else:
		_busted_t = 0.0


## 被捕流程收尾：由 main_game 处理完重生/扣罚后调用
func clear_busted() -> void:
	busted_handled = false
	heat = 0.0
	_set_level(0)
	_busted_t = 0.0


# ---------------------------------------------------------------------------
# 警力部署
# ---------------------------------------------------------------------------

func _manage_cops() -> void:
	if world == null or world.graph == null or world.graph.nodes.is_empty():
		return
	var desired: int = COPS_BY_LEVEL[wanted_level]
	# 距离过远的先回收
	for i in range(cops.size() - 1, -1, -1):
		var c: Dictionary = cops[i]
		if Vector2(c["x"], c["z"]).distance_to(_player_pos) > COP_RECYCLE_DIST:
			cops.remove_at(i)
	# 超编：从最远的开始丢
	while cops.size() > desired:
		var worst := 0
		var worst_d := -1.0
		for i in cops.size():
			var d: float = Vector2(cops[i]["x"], cops[i]["z"]).distance_to(_player_pos)
			if d > worst_d:
				worst_d = d
				worst = i
		cops.remove_at(worst)
	# 缺编：补刷。⚠️ 每次 manage 最多补 2 辆 —— _pick_spawn_node 是线性扫
	# 4.3 万节点，一帧补 8 辆会有一次百毫秒级卡顿；0.5s 一批，2s 内补齐。
	var spawned := 0
	while cops.size() < desired and spawned < 2:
		var nid := _pick_spawn_node()
		if nid < 0:
			break
		_spawn_cop(nid)
		spawned += 1


## 在 80–200m 带内找一个 degree≥2 的生成节点（线性扫，仅补刷时偶发，可接受）
func _pick_spawn_node() -> int:
	var graph := world.graph
	var best := -1
	var best_d := INF
	# 避开已有警车聚集：候选点离现有警车至少 COP_GAP
	for i in graph.nodes.size():
		if graph.degree(i) < 2:
			continue
		var d := graph.nodes[i].distance_to(_player_pos)
		if d < SPAWN_MIN or d > SPAWN_MAX:
			continue
		if d >= best_d:
			continue
		var ok := true
		for c in cops:
			if Vector2(c["x"], c["z"]).distance_to(graph.nodes[i]) < COP_GAP:
				ok = false
				break
		if not ok:
			continue
		best_d = d
		best = i
	return best


func _spawn_cop(node_id: int) -> void:
	var graph := world.graph
	var from := node_id
	var nxt := graph.neighbor_ids(from)
	if nxt.is_empty():
		return
	var to := nxt[_rng.randi_range(0, nxt.size() - 1)]
	var pos: Vector2 = graph.nodes[from]
	cops.append({
		"from": from, "to": to, "t": 0.0,
		"speed": COP_SPEED_BY_LEVEL[maxi(wanted_level, 1)],
		"x": pos.x, "z": pos.y, "yaw": 0.0,
	})


func _step_cops(delta: float) -> void:
	if cops.is_empty():
		return
	var graph := world.graph
	if graph == null or graph.nodes.is_empty():
		return
	var max_speed: float = COP_SPEED_BY_LEVEL[maxi(wanted_level, 1)]
	for c in cops:
		var a: Vector2 = graph.nodes[c["from"]]
		var b: Vector2 = graph.nodes[c["to"]]
		var seg_len := a.distance_to(b)
		# 警车速度随追捕态势：贴近玩家时略降（留出"别一下顶死"的手感），
		# 远时拉满极速。
		var dist_to_p := Vector2(c["x"], c["z"]).distance_to(_player_pos)
		var cruise: float = max_speed * (0.55 if dist_to_p < 15.0 else 1.0)
		c["t"] = float(c["t"]) + delta * cruise / maxf(0.1, seg_len)

		# 到节点 → 贪心选"离玩家最近"的邻边（偶尔带回退扰动防死循环抖动）
		var guard := 0
		while float(c["t"]) >= 1.0 and guard < 8:
			guard += 1
			c["t"] = (float(c["t"]) - 1.0) * seg_len
			var old: int = c["from"]
			c["from"] = c["to"]
			a = graph.nodes[c["from"]]
			var best_next := old
			var best_score := INF
			for i in graph.neighbor_ids(c["from"]):
				if i == old and graph.degree(c["from"]) > 1:
					continue
				var p2: Vector2 = graph.nodes[i]
				var score := p2.distance_to(_player_pos) + _rng.randf() * 8.0
				if score < best_score:
					best_score = score
					best_next = i
			c["to"] = best_next
			b = graph.nodes[best_next]
			seg_len = a.distance_to(b)
			c["t"] = float(c["t"]) / maxf(0.1, seg_len)

		var yaw := atan2(b.x - a.x, b.y - a.y)
		c["x"] = a.x + (b.x - a.x) * float(c["t"]) + cos(yaw) * KERB_OFFSET
		c["z"] = a.y + (b.y - a.y) * float(c["t"]) - sin(yaw) * KERB_OFFSET
		c["yaw"] = yaw

	# 顶撞判定：警车贴身且双方都在动 → 发 rammed，由 main_game 打折玩家车速
	if wanted_level > 0 and not busted_handled:
		for c in cops:
			if Vector2(c["x"], c["z"]).distance_to(_player_pos) < RAM_DIST \
					and _player_speed > RAM_SPEED:
				rammed.emit(0.55)
				break

	# 警察开火（3 星起）：每辆警车独立冷却；命中率随距离衰减，伤害 8–14。
	# 是否真的掉血由 main_game 按模式裁决（v1 车内免伤，只有步行会中弹）。
	if wanted_level >= COP_FIRE_MIN_LEVEL and not busted_handled:
		for c in cops:
			var dist := Vector2(c["x"], c["z"]).distance_to(_player_pos)
			if dist > COP_FIRE_RANGE:
				continue
			c["fire_t"] = float(c.get("fire_t", _rng.randf() * COP_FIRE_INTERVAL)) - delta
			if float(c["fire_t"]) > 0.0:
				continue
			c["fire_t"] = COP_FIRE_INTERVAL
			var hit_chance := clampf(0.55 - dist / 200.0, 0.08, 0.5)
			if _rng.randf() < hit_chance:
				player_shot.emit(_rng.randf_range(8.0, 14.0))


## 警车数据坐标位置（main_game 的撞警车判定用）
func cop_poses() -> Array:
	return cops


## 警笛强度 0–1（procedural_audio.set_siren 用）：1 星起有底噪，最近警车越近越响
func siren_level() -> float:
	if wanted_level <= 0:
		return 0.0
	var nearest := INF
	for c in cops:
		nearest = minf(nearest, Vector2(c["x"], c["z"]).distance_to(_player_pos))
	if not is_finite(nearest):
		return 0.3
	return clampf(0.3 + 0.7 * (1.0 - nearest / 300.0), 0.0, 1.0)


# ---------------------------------------------------------------------------
# 渲染（MultiMesh，白警涂装；同 TrafficSystem 的装配方式）
# ---------------------------------------------------------------------------

func _load_car_asset() -> void:
	var path := "res://data/city/traffic-car.glb"
	if not ResourceLoader.exists(path):
		path = "res://data/city/car.glb"
	if ResourceLoader.exists(path):
		var scene := load(path) as PackedScene
		if scene != null:
			var inst := scene.instantiate()
			_source_meshes = GlbLoader.meshes_of(inst)
			inst.queue_free()
	if _source_meshes.is_empty():
		push_warning("[WantedSystem] 缺少警车车辆模型，警灯仍可见（逻辑照跑）")
	_build_lightbars()
	for mi in _source_meshes:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _police_mesh(mi.mesh)
		var node := MultiMeshInstance3D.new()
		node.multimesh = mm
		node.name = "police-%d" % _multimeshes.size()
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(node)
		_multimeshes.append({"mm": mm})
	_mesh_built = true


## 警灯频闪（§2.1 v1.1）：车顶灯条用**程序化 BoxMesh**（无模型资产），
## 红/蓝两组 MultiMesh 在 10Hz 同步时交替写入 —— 单色 5Hz 闪烁、整体 10Hz，
## 与车身同步同一个 tick，不增加每帧成本。
const LIGHTBAR_SIZE := Vector3(0.92, 0.13, 0.36)
const LIGHTBAR_HEIGHT := 1.02   ## 车顶上方（traffic-car.glb 车高约 1.4m，灯条贴顶）
var _bar_red_mm: MultiMesh = null
var _bar_blue_mm: MultiMesh = null
var _bar_toggle := false


func _build_lightbars() -> void:
	_bar_red_mm = MultiMesh.new()
	_bar_red_mm.transform_format = MultiMesh.TRANSFORM_3D
	_bar_red_mm.mesh = _bar_mesh(Color(1.0, 0.08, 0.05))
	var red_node := MultiMeshInstance3D.new()
	red_node.multimesh = _bar_red_mm
	red_node.name = "police-bar-red"
	red_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(red_node)
	_bar_blue_mm = MultiMesh.new()
	_bar_blue_mm.transform_format = MultiMesh.TRANSFORM_3D
	_bar_blue_mm.mesh = _bar_mesh(Color(0.08, 0.30, 1.0))
	var blue_node := MultiMeshInstance3D.new()
	blue_node.multimesh = _bar_blue_mm
	blue_node.name = "police-bar-blue"
	blue_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(blue_node)


## 自发光灯条网格：暗底色 + 强自发光（昼夜都醒目）
func _bar_mesh(color: Color) -> Mesh:
	var box := BoxMesh.new()
	box.size = LIGHTBAR_SIZE
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color * 0.3
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 3.0
	box.material = mat
	return box


## 复制一份网格，把「车漆面」染成警用白
func _police_mesh(src_mesh: Mesh) -> Mesh:
	if src_mesh == null:
		return null
	var dup: Mesh = src_mesh.duplicate(true)
	for s in dup.get_surface_count():
		var mat: Material = dup.surface_get_material(s)
		if mat == null:
			continue
		var lower := str(mat.resource_name).to_lower()
		if not ("paint" in lower or dup.get_surface_count() == 1):
			continue
		var copy := mat.duplicate()
		if copy is StandardMaterial3D:
			(copy as StandardMaterial3D).albedo_color = POLICE_PAINT
		dup.surface_set_material(s, copy)
	return dup


func _sync_instances() -> void:
	var visible_xfs: Array = []
	for c in cops:
		if Vector2(c["x"], c["z"]).distance_to(_player_pos) > 950.0:
			continue
		var g := world.ground_height(float(c["x"]), -float(c["z"]))
		var yaw := float(c["yaw"])
		var xf := Transform3D(
			# traffic-car.glb 同款：-Z 前向
			Basis(Vector3.UP, CoordinateUtil.node_yaw(yaw, CoordinateUtil.ModelForward.MINUS_Z)),
			CoordinateUtil.to_world(float(c["x"]), float(c["z"]), g + CAR_HEIGHT))
		visible_xfs.append(xf)
	# 每个 MultiMesh（一个源 mesh 部件）都要有每车一个实例
	# 本系统所有 mesh 共享同一份实例列表（每车每个源 mesh 一个实例）
	if _mesh_built:
		for e in _multimeshes:
			var mm: MultiMesh = e["mm"]
			mm.instance_count = visible_xfs.size()
			mm.visible_instance_count = visible_xfs.size()
			for i in visible_xfs.size():
				mm.set_instance_transform(i, visible_xfs[i])
	# 警灯频闪：本次 tick 写入其中一色（10Hz 同步 → 单色 5Hz 闪烁），另一色清空
	if _bar_red_mm != null and _bar_blue_mm != null:
		_bar_toggle = not _bar_toggle
		var active: MultiMesh = _bar_red_mm if _bar_toggle else _bar_blue_mm
		var idle: MultiMesh = _bar_blue_mm if _bar_toggle else _bar_red_mm
		active.instance_count = visible_xfs.size()
		active.visible_instance_count = visible_xfs.size()
		for i in visible_xfs.size():
			var xf: Transform3D = visible_xfs[i]
			active.set_instance_transform(i, Transform3D(
				xf.basis, xf.origin + Vector3.UP * LIGHTBAR_HEIGHT))
		idle.instance_count = 0
		idle.visible_instance_count = 0


# ---------------------------------------------------------------------------
# 诊断
# ---------------------------------------------------------------------------

func diagnostics() -> Dictionary:
	var nearest := -1.0
	for c in cops:
		var d := Vector2(c["x"], c["z"]).distance_to(_player_pos)
		if nearest < 0.0 or d < nearest:
			nearest = d
	return {
		"level": wanted_level,
		"heat": snappedf(heat, 0.01),
		"cops": cops.size(),
		"nearest_cop_m": -1 if nearest < 0.0 else int(nearest),
		"busted": busted_handled,
	}
