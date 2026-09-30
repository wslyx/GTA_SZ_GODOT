extends Node3D
class_name PedestrianSystem
##
## 行人系统 —— 逐行移植原版 src/pedestrians.ts 的 CityPedestrians。
##
## 行为要点（照搬原版）：
##   - 路径来自 city/pedestrian-paths.json，每条是 [ax, az, bx, bz] 的短段
##   - 生成：取中点距玩家 <330m 的路径；数量 = min(56, max(可用路径数, 保留槽位))
##   - 每个行人沿段线性往返：t += dir * speed * dt / 段长，到端点反向
##        t = (i * 0.618) % 1        （黄金比例散开，避免同相位）
##        speed = 0.8 + (i % 7) * 0.1 （0.8–1.4 m/s）
##        phase = i * 1.31
##        dir = i % 2 ? 1 : -1
##        scale = 0.94 + (slot % 5) * 0.025
##   - 距生成原点 >220m 重新布点
##   - 动画无骨骼：把模型拆成 5 个部件（body / leftLeg / rightLeg / leftArm / rightArm），
##     按 mesh 名里的 leg_-1 / leg_1 / arm_-1 / arm_1 归类，
##     摆动 gait = sin(time * speed * 6 + phase) * 0.38，手臂 ×0.8
##   - 关节枢轴：腿 [-.105,.89] / [.105,.89]，臂 [±.21,1.35]

const MAX_COUNT := 56
const PATH_RADIUS := 330.0
const REPLACE_RADIUS := 220.0
const GAIT_AMPLITUDE := 0.38
const ARM_SCALE := 0.8

const PIVOT_LEG_L := Vector2(-0.105, 0.89)
const PIVOT_LEG_R := Vector2(0.105, 0.89)
const PIVOT_ARM_L := Vector2(-0.21, 1.35)
const PIVOT_ARM_R := Vector2(0.21, 1.35)

var world: CityWorld
var paths: Array = []     ## Vector4(ax, az, bx, bz)
var walkers: Array = []
var origin := Vector2.ZERO
var time := 0.0
var enabled := true

var _parts: Dictionary = {}     ## "body"/"leftLeg"/... → {mesh, mm}
var _built := false
## 被撞倒地的刚体控制器（原版 pedestrian-impact.ts）
const IMPACT_SCRIPT := preload("res://scripts/world/pedestrian_impact.gd")
## 给 step_body 用的回调（每帧新建 lambda 会白造上百个闭包，这里建一次）
var _height_cb: Callable
var _blocked_cb: Callable
var _downed := 0
## 人行道段中点索引。
## place() 原本每 220m 全量扫 36969 条路径，是行驶中周期性卡顿的另一个来源。
var _path_mids := PackedVector2Array()
var _path_grid: PointGrid
## 实例变换重写节流：56 行人 × 12 部件 ≈ 670 次/帧太重
const PUSH_INTERVAL := 0.1
var _push_timer := 0.0


func setup(p_world: CityWorld) -> void:
	world = p_world
	_height_cb = func(x: float, z: float) -> float: return world.ground_height(x, -z)
	_blocked_cb = func(x: float, z: float) -> bool: return world.collision.blocked(x, z)
	_load_paths()
	_load_asset()
	if not paths.is_empty() and not world.blocks.is_empty():
		place(CityData.spawn_pos.x, CityData.spawn_pos.y)


func _load_paths() -> void:
	var raw: Array = CityData.pedestrian_paths()
	paths.clear()
	for e in raw:
		if e.size() < 4:
			continue
		paths.append(Vector4(float(e[0]), float(e[1]), float(e[2]), float(e[3])))
	_path_mids.resize(paths.size())
	for i in paths.size():
		var s: Vector4 = paths[i]
		_path_mids[i] = Vector2((s.x + s.z) * 0.5, (s.y + s.w) * 0.5)
	_path_grid = PointGrid.new(256.0)
	_path_grid.build(_path_mids)
	print("[PedestrianSystem] 人行道段 %d 条" % paths.size())


func _load_asset() -> void:
	var path := "res://data/city/pedestrian.glb"
	if not ResourceLoader.exists(path):
		push_warning("[PedestrianSystem] 缺少行人模型")
		return
	var scene := load(path) as PackedScene
	if scene == null:
		return
	var inst := scene.instantiate()
	var srcs := GlbLoader.meshes_of(inst)
	var buckets := {"body": [], "leftLeg": [], "rightLeg": [], "leftArm": [], "rightArm": []}
	for mi in srcs:
		buckets[_classify(mi.name)].append(mi)
	for key in buckets:
		for mi in buckets[key]:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.mesh = mi.mesh
			var node := MultiMeshInstance3D.new()
			node.multimesh = mm
			node.name = "ped-%s" % key
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(node)
			if not _parts.has(key):
				_parts[key] = []
			_parts[key].append({"mm": mm, "mesh": mi.mesh})
	inst.queue_free()
	_built = true


## 原版按 mesh 名归类（leg_-1 / leg_1 / arm_-1 / arm_1）
func _classify(mesh_name: String) -> String:
	var n := mesh_name.to_lower()
	if "leg_-1" in n or "leg_1" in n:
		return "leftLeg" if "leg_-1" in n else "rightLeg"
	if "arm_-1" in n or "arm_1" in n:
		return "leftArm" if "arm_-1" in n else "rightArm"
	return "body"


func place(px: float, pz: float) -> void:
	walkers.clear()
	var p := Vector2(px, pz)
	var near: Array = []
	var scan: Array = []
	if _path_grid != null:
		scan = _path_grid.query_radius(p, PATH_RADIUS)
	else:
		scan = range(paths.size())
	for idx in scan:
		if _path_mids[idx].distance_to(p) < PATH_RADIUS:
			near.append(paths[idx])
	if near.is_empty():
		return
	var count := mini(MAX_COUNT, maxi(near.size(), walkers.size()))
	for i in count:
		var seg: Vector4 = near[int(i * near.size() / maxi(1, count)) % near.size()]
		walkers.append({
			"seg": seg,
			"t": fposmod(i * 0.618, 1.0),
			"speed": 0.8 + float(i % 7) * 0.1,
			"phase": i * 1.31,
			"dir": 1.0 if i % 2 == 1 else -1.0,
			"scale": 0.94 + float(i % 5) * 0.025,
			"x": 0.0, "z": 0.0, "yaw": 0.0,
			"body": null,
		})
	origin = p
	_downed = 0


## 把这一帧车的**实际位移**（碰撞回滚之后）交给碰撞检测。
## 由 main_game 在车辆子步结束后调用，入参是数据坐标下的前后两帧车姿。
func apply_car_motion(before: Dictionary, after: Dictionary) -> int:
	if not enabled or not _built or walkers.is_empty():
		return 0
	var hits := 0
	for w in walkers:
		if w["body"] != null:
			continue
		var px := float(w["x"])
		var pz := float(w["z"])
		var person := {"x": px, "y": world.ground_height(px, -pz), "z": pz}
		var impact: Dictionary = IMPACT_SCRIPT.detect(before, after, person)
		if impact.is_empty():
			continue
		w["body"] = IMPACT_SCRIPT.create_body(person, impact)
		hits += 1
	if hits > 0:
		_downed = _count_downed()
	return hits


func _count_downed() -> int:
	var n := 0
	for w in walkers:
		if w["body"] != null:
			n += 1
	return n


func update_system(delta: float, focus: Vector3) -> void:
	if not enabled or not _built:
		return
	var px := focus.x
	var pz := -focus.z
	if not paths.is_empty() and Vector2(px, pz).distance_to(origin) > REPLACE_RADIUS:
		place(px, pz)
	time += delta
	_advance(delta)
	# 节流：56 个行人 × 12 个 mesh 部件 ≈ 670 次 set_instance_transform，
	# 每帧重写太重；走路动画 10Hz 足够流畅
	_push_timer -= delta
	if _push_timer > 0.0:
		return
	_push_timer = PUSH_INTERVAL
	_push_instances()


func _advance(dt: float) -> void:
	for w in walkers:
		# 倒地的人不再走路，改由刚体控制器推进（原版 phase === 'recovering' 后停住）
		var body = w["body"]
		if body != null:
			IMPACT_SCRIPT.step_body(body, dt, _height_cb, _blocked_cb)
			continue
		var seg: Vector4 = w["seg"]
		var a := Vector2(seg.x, seg.y)
		var b := Vector2(seg.z, seg.w)
		var seg_len := maxf(0.1, a.distance_to(b))
		w["t"] = float(w["t"]) + float(w["dir"]) * float(w["speed"]) * dt / seg_len
		if float(w["t"]) > 1.0:
			w["t"] = 1.0 - (float(w["t"]) - 1.0)
			w["dir"] = -1.0
		elif float(w["t"]) < 0.0:
			w["t"] = -float(w["t"])
			w["dir"] = 1.0
		var t: float = w["t"]
		w["x"] = a.x + (b.x - a.x) * t
		w["z"] = a.y + (b.y - a.y) * t
		var dx := (b.x - a.x) * float(w["dir"])
		var dy := (b.y - a.y) * float(w["dir"])
		w["yaw"] = atan2(dx, dy)


func _push_instances() -> void:
	var lists := {}
	for key in _parts:
		for entry in _parts[key]:
			lists[entry["mm"]] = []

	for w in walkers:
		var sc := float(w["scale"])
		var root_xf: Transform3D
		var swing := 0.0
		var body = w["body"]
		if body != null:
			# 倒地：位置取质心，姿态取 rx/ry/rz；模型的局部原点在**脚底**，
			# 所以要减去质心偏移（它要跟着 basis 一起转、一起缩放）
			var fall_basis := Basis(Vector3.UP, CoordinateUtil.node_yaw(float(body["ry"]))) \
				* Basis(Vector3.RIGHT, float(body["rx"])) \
				* Basis(Vector3.FORWARD, float(body["rz"]))
			fall_basis = fall_basis.scaled(Vector3(sc, sc, sc))
			var pos := CoordinateUtil.to_world(float(body["x"]), float(body["z"]), float(body["y"])) \
				- fall_basis * Vector3(0.0, IMPACT_SCRIPT.CENTRE_HEIGHT, 0.0)
			root_xf = Transform3D(fall_basis, pos)
		else:
			var g := world.ground_height(float(w["x"]), -float(w["z"]))
			var base := CoordinateUtil.to_world(float(w["x"]), float(w["z"]), g)
			var root_yaw := float(w["yaw"])
			swing = sin(time * float(w["speed"]) * 6.0 + float(w["phase"])) * GAIT_AMPLITUDE
			# 根变换：朝向 + 缩放 + 落位
			root_xf = Transform3D(
				Basis(Vector3.UP, CoordinateUtil.node_yaw(root_yaw)).scaled(Vector3(sc, sc, sc)), base)

		for key in _parts:
			var angle := 0.0
			var pivot := Vector2.ZERO
			match key:
				"leftLeg":
					angle = swing
					pivot = PIVOT_LEG_L
				"rightLeg":
					angle = -swing
					pivot = PIVOT_LEG_R
				"leftArm":
					angle = -swing * ARM_SCALE
					pivot = PIVOT_ARM_L
				"rightArm":
					angle = swing * ARM_SCALE
					pivot = PIVOT_ARM_R
				_:
					angle = 0.0
					pivot = Vector2.ZERO

			# 绕枢轴旋转：T(pivot) * R(θ) * T(-pivot)，作用在模型局部空间
			var pivot_v := Vector3(pivot.x, pivot.y, 0.0)
			var local_xf := Transform3D.IDENTITY
			if not is_zero_approx(angle):
				var to_pivot := Transform3D(Basis.IDENTITY, pivot_v)
				var rot := Transform3D(Basis(Vector3.RIGHT, angle), Vector3.ZERO)
				var from_pivot := Transform3D(Basis.IDENTITY, -pivot_v)
				local_xf = to_pivot * rot * from_pivot

			var xf := root_xf * local_xf
			for entry in _parts[key]:
				lists[entry["mm"]].append(xf)

	for key in _parts:
		for entry in _parts[key]:
			var list: Array = lists[entry["mm"]]
			var mm: MultiMesh = entry["mm"]
			mm.instance_count = list.size()
			mm.visible_instance_count = list.size()
			for i in list.size():
				mm.set_instance_transform(i, list[i])


func diagnostics() -> Dictionary:
	return {"paths": paths.size(), "walkers": walkers.size(), "parts": _parts.size(),
			"origin": [origin.x, origin.y], "enabled": enabled, "downed": _downed}
