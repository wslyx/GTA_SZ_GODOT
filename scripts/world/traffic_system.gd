extends Node3D
class_name TrafficSystem
##
## AI 车流 —— 逐行移植原版 src/traffic.ts 的 CityTraffic。
##
## 行为要点（照搬原版）：
##   - 40 辆车，分 3 个车身颜色组（灰绿 / 暗红 / 深青）
##   - 只在 degree>1 且距玩家 14–600m 的路网节点上生成，彼此间隔 ≥12m
##   - 沿当前边以 speed 7–13 m/s 前进；到节点后在邻接边里按
##     "方向一致性 + 随机扰动 0.7" 打分选下一条
##   - 前方 8m 内有同向车、或前方 6m 内有红灯停线 → 原地等待
##   - 靠右行驶：横向偏移 1.15m（原版 cos(yaw)*1.15 / -sin(yaw)*1.15）
##   - 离玩家 >950m 不渲染；玩家移动 >450m 重新布车

const CAR_COUNT := 40
const MIN_SPAWN_DIST := 14.0
const MAX_SPAWN_DIST := 600.0
const MIN_CAR_GAP := 12.0
const REPLACE_DIST := 450.0
const RENDER_DIST := 950.0
const HOLD_BLOCK_DIST := 8.0
const HOLD_SIGNAL_DIST := 6.0
const KERB_OFFSET := 1.15
const CAR_HEIGHT := 0.14

const CAR_COLORS := [
	Color(0.52, 0.56, 0.53),
	Color(0.28, 0.06, 0.038),
	Color(0.028, 0.25, 0.18),
]

var world: CityWorld
var graph: RoadGraph
var signals: TrafficSignals

var cars: Array = []      ## {from,to,t,speed,x,z,yaw,group}
var origin := Vector2.ZERO
var enabled := true

var _source_meshes: Array = []
var _multimeshes: Array = []   ## 每 group × 每个源 mesh 一个 MultiMesh
var _mesh_built := false
var _rng := RandomNumberGenerator.new()
## 实例变换重写节流：69 个 MultiMesh 节点，每帧重写太重
const SYNC_INTERVAL := 0.1
var _sync_timer := 0.0


func setup(p_world: CityWorld) -> void:
	world = p_world
	graph = p_world.graph
	signals = p_world.signals
	_rng.seed = 77  # 原版 seed=77
	_load_car_asset()
	if not world.blocks.is_empty():
		place(CityData.spawn_pos.x, CityData.spawn_pos.y)


func _load_car_asset() -> void:
	var path := "res://data/city/traffic-car.glb"
	if not ResourceLoader.exists(path):
		path = "res://data/city/car.glb"
	if not ResourceLoader.exists(path):
		push_warning("[TrafficSystem] 缺少车流车辆模型")
		return
	var scene := load(path) as PackedScene
	if scene == null:
		return
	var inst := scene.instantiate()
	_source_meshes = GlbLoader.meshes_of(inst)
	inst.queue_free()
	_build_multimeshes()


func _build_multimeshes() -> void:
	for g in CAR_COLORS.size():
		for mi in _source_meshes:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			# MultiMeshInstance3D **没有**逐 surface 材质（那是 MeshInstance3D 的
			# set_surface_override_material），所以给每个 group 复制一份网格、
			# 在副本上把车漆面换成对应颜色。
			mm.mesh = _mesh_for_group(mi.mesh, g)
			var node := MultiMeshInstance3D.new()
			node.multimesh = mm
			node.name = "traffic-%d" % _multimeshes.size()
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(node)
			_multimeshes.append({"mm": mm, "group": g})
	_mesh_built = true


## 给某个颜色组复制一份网格，并把「车漆面」的 albedo 换成组色。
func _mesh_for_group(src_mesh: Mesh, group: int) -> Mesh:
	if src_mesh == null:
		return null
	var dup: Mesh = src_mesh.duplicate(true)
	for s in dup.get_surface_count():
		var mat: Material = dup.surface_get_material(s)
		if mat == null:
			continue
		var lower := str(mat.resource_name).to_lower()
		# 约定：材质名带 paint 的是车漆；只有 1 个 surface 时整个 mesh 就是车身
		if not ("paint" in lower or dup.get_surface_count() == 1):
			continue
		var copy := mat.duplicate()
		if copy is StandardMaterial3D:
			(copy as StandardMaterial3D).albedo_color = CAR_COLORS[group]
		dup.surface_set_material(s, copy)
	return dup


# ---------------------------------------------------------------------------
# 布车（原版 place）
# ---------------------------------------------------------------------------

func place(px: float, pz: float) -> void:
	cars.clear()
	if graph == null or graph.nodes.is_empty():
		return
	var p := Vector2(px, pz)
	var candidates: Array = []
	for i in graph.nodes.size():
		var d := graph.nodes[i].distance_to(p)
		if d > MIN_SPAWN_DIST and d < MAX_SPAWN_DIST and graph.degree(i) > 1:
			candidates.append(i)
	if candidates.is_empty():
		return
	candidates.sort_custom(func(a, b):
		return graph.nodes[a].distance_to(p) < graph.nodes[b].distance_to(p))

	for i in CAR_COUNT:
		if candidates.is_empty():
			break
		var pool_size := mini(candidates.size(), 45 if i < 10 else candidates.size())
		var from: int = candidates[_rng.randi_range(0, pool_size - 1)]
		var next: Array = []
		for to in graph.neighbor_ids(from):
			next.append(to)
		if next.is_empty():
			continue
		var to: int = next[_rng.randi_range(0, next.size() - 1)]
		var node_pos: Vector2 = graph.nodes[from]
		var clash := false
		for c in cars:
			if Vector2(c["x"], c["z"]).distance_to(node_pos) < MIN_CAR_GAP:
				clash = true
				break
		if clash:
			continue
		cars.append({
			"from": from, "to": to, "t": 0.0,
			"speed": 7.0 + _rng.randf() * 6.0,
			"x": node_pos.x, "z": node_pos.y, "yaw": 0.0,
			"group": i % 3,
		})
	origin = p
	_sync_instances(px, pz)


# ---------------------------------------------------------------------------
# 每帧推进（原版 update）
# ---------------------------------------------------------------------------

func update_system(delta: float, focus: Vector3) -> void:
	if not enabled or cars.is_empty():
		return
	var px := focus.x
	var pz := -focus.z
	if Vector2(px, pz).distance_to(origin) > REPLACE_DIST:
		place(px, pz)
		return
	# 节流：3 组 × 23 个 mesh = 69 个 MultiMesh 节点，每帧重写实例变换
	# （约 900 次 set_instance_transform）在 GDScript 里太重，降到 10Hz。
	# 车速 7–13 m/s，0.1s 位移不到 1.3m，视觉上可接受。
	_sync_timer -= delta
	if _sync_timer > 0.0:
		return
	_sync_timer = SYNC_INTERVAL
	_sync_instances(px, pz)


func _sync_instances(px: float, pz: float) -> void:
	var buffers := {}
	for b in _multimeshes:
		buffers[b["mm"]] = []

	for c in cars:
		var a: Vector2 = graph.nodes[c["from"]]
		var b: Vector2 = graph.nodes[c["to"]]
		var seg_len := a.distance_to(b)

		# 阻塞判定：红灯或前车
		var hold := INF
		if signals != null:
			hold = signals.signal_hold(c["x"], c["z"], c["yaw"])
		var blocked := hold < HOLD_SIGNAL_DIST
		if not blocked:
			var fx := sin(c["yaw"])
			var fz := cos(c["yaw"])
			for o in cars:
				if o == c:
					continue
				var dx := float(o["x"]) - float(c["x"])
				var dz := float(o["z"]) - float(c["z"])
				if sqrt(dx * dx + dz * dz) < HOLD_BLOCK_DIST and dx * fx + dz * fz > 0.0:
					blocked = true
					break

		var dt := clampf(world.get_process_delta_time(), 0.0, 0.05)
		c["t"] = float(c["t"]) + dt * (0.0 if blocked else float(c["speed"])) / maxf(0.1, seg_len)

		# 到达节点后选下一条边
		var guard := 0
		while float(c["t"]) >= 1.0 and guard < 12:
			guard += 1
			c["t"] = (float(c["t"]) - 1.0) * seg_len
			var old: int = c["from"]
			c["from"] = c["to"]
			a = graph.nodes[c["from"]]
			var best_score := -INF
			var best_next := old
			var old_pos: Vector2 = graph.nodes[old]
			var dxn := a.x - old_pos.x
			var dzn := a.y - old_pos.y
			for i in graph.neighbor_ids(c["from"]):
				if i == old:
					continue
				var p2: Vector2 = graph.nodes[i]
				var l := a.distance_to(p2)
				var score := (dxn * (p2.x - a.x) + dzn * (p2.y - a.y)) / maxf(0.1, seg_len * l) + _rng.randf() * 0.7
				if score > best_score:
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

		if Vector2(c["x"], c["z"]).distance_to(Vector2(px, pz)) > RENDER_DIST:
			continue
		var g := world.ground_height(float(c["x"]), -float(c["z"]))
		var xf := Transform3D(
			# 车流模型（traffic-car.glb）同样是 -Z 前向：
			# car_led（前灯）Z = -2.24 ／ car_redled（尾灯）Z = +1.62。
			Basis(Vector3.UP, CoordinateUtil.node_yaw(yaw, CoordinateUtil.ModelForward.MINUS_Z)),
			CoordinateUtil.to_world(float(c["x"]), float(c["z"]), g + CAR_HEIGHT))
		for entry in _multimeshes:
			if int(entry["group"]) == int(c["group"]):
				buffers[entry["mm"]].append(xf)

	for entry in _multimeshes:
		var list: Array = buffers[entry["mm"]]
		var mm: MultiMesh = entry["mm"]
		mm.instance_count = list.size()
		mm.visible_instance_count = list.size()
		for i in list.size():
			mm.set_instance_transform(i, list[i])


## 供自动驾驶查询：其他车辆位置（数据坐标）
func positions() -> Array:
	var out: Array = []
	for c in cars:
		out.append(Vector2(c["x"], c["z"]))
	return out


func car_poses() -> Array:
	return cars


func diagnostics() -> Dictionary:
	return {"cars": cars.size(), "origin": [origin.x, origin.y],
			"multimeshes": _multimeshes.size(), "enabled": enabled}
