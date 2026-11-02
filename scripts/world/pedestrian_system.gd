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

## pedestrian.glb 的前向轴 = **-Z**（实测，同 ebikes.glb / 轿车 / 飞机那条资产管线）。
## 证据（从 data/city/pedestrian.glb 的 accessor min/max 量出来，踝在 z≈0 的腿轴上）：
##   shoes  z ∈ [-0.205, +0.095]  —— 脚跟短、脚尖长 ⇒ 脚尖朝 -Z
##   hair   z ∈ [-0.075, +0.092]，颅骨 z ∈ [-0.090, +0.090] —— 头发越过颅骨的
##          一侧是 +Z（后脑）⇒ 脸朝 -Z
##   body_trousers z ∈ [+0.080, +0.210]（y 1.02–1.34 = 背中部）—— 身上唯一在 +Z
##          侧的部件是"背" ⇒ 人朝 -Z
## 原版 Babylon 端做过 bakeTransformIntoVertices(Matrix.Scaling(1,1,-1))，把脚尖
## 翻到 +Z 再配 R_y(yaw)，所以那边默认 +Z 是对的；Godot 直接按 glTF 载入**没有**
## 这次镜像，必须走 MINUS_Z（rotation.y = -yaw），否则整街行人背对行进方向。
const PED_FORWARD := CoordinateUtil.ModelForward.MINUS_Z

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
## 实例变换写入节流：56 行人 × 12 部件 ≈ 670 次 set_instance_transform 太重。
##
## 原实现是"每 PUSH_INTERVAL 全量重写一次"，代价是腿摆只有 10Hz —— 站近看
## 行人就是**抽帧走**（位置在 _advance 里每帧推进，只有摆动角度被节流）。
## 现在按距离分档：
##   NEAR_RADIUS 内 —— 每帧重算并写入（恢复成帧率级摆动）；
##   更远处       —— 仍按 PUSH_INTERVAL 写，省下的调用正好抵掉近处多出来的。
## place() 之后强制全量重写一次（实例数变了，旧的变换缓存全部作废）。
const NEAR_RADIUS := 40.0
const PUSH_INTERVAL := 0.1
## 每个 walker 距上次写入的秒数（与 walkers 同长）
var _push_age := PackedFloat32Array()
## 每个 walker 的 5 个部件变换缓存（与 walkers 同长）：{部件名 → Transform3D}
var _xf_cache: Array = []
var _force_full := true
## MultiMesh 当前已写入的实例数（-1 = 还没写过）
var _mm_count := -1


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
			# ⚠️ 这里**故意**不投影，与原版一致（`pedestrians.ts` 只设了
			# `src.receiveShadows=true`，从未 addShadowCaster）。别当缺陷"修"掉：
			# 开了就是 56×12 个实例进阴影 pass，且偏离 1:1。
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
			## 惊逃计时（GTA化 §4.1）：>0 时沿人行道加速逃离威胁方向
			"panic_t": 0.0,
		})
	origin = p
	_downed = 0
	# 实例表重排了：清空变换缓存并强制下一帧全量重写
	_xf_cache.clear()
	_xf_cache.resize(walkers.size())
	_push_age.resize(walkers.size())
	_push_age.fill(0.0)
	_force_full = true


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


## 惊逃（GTA化 §4.1）：threat（数据坐标）半径 radius 内的行人进入恐慌 ——
## 加速逃离 6 秒，且把行进方向翻成"背离威胁"的一侧（行人只能沿人行道段走，
## 逃跑 = 沿段加速 + 选对方向，视觉上足够"四散奔逃"）。
## 触发源：开枪（main_game._step_weapons）、撞倒行人（_step_car）。
func panic_at(threat: Vector2, radius: float) -> void:
	if not enabled or walkers.is_empty():
		return
	for w in walkers:
		if w["body"] != null:
			continue
		var wp := Vector2(w["x"], w["z"])
		if wp.distance_to(threat) > radius:
			continue
		# 当前行进方向（数据坐标）：段向量 × dir 符号
		var seg: Vector4 = w["seg"]
		var sd := Vector2(seg.z - seg.x, seg.w - seg.y)
		var moving := sd.normalized() * float(w["dir"])
		# 朝着威胁走 → 掉头背向威胁跑
		if moving.dot(wp - threat) < 0.0:
			w["dir"] = -float(w["dir"])
		w["panic_t"] = 6.0


## 射击命中（GTA化 §2.3）：数据坐标射线 from + dir*t（t ∈ [0.5, range_m]），
## 取最近的未倒地行人（命中半径 0.7m）。命中即用小冲量刚体击倒
## （复用车辆撞击的 create_body 链路），返回 {t, pos}，未命中 {}。
func shoot_hit(from: Vector2, dir: Vector2, range_m: float) -> Dictionary:
	if not enabled or not _built or walkers.is_empty():
		return {}
	var best_t := range_m
	var best_w = null
	for w in walkers:
		if w["body"] != null:
			continue
		var rel := Vector2(w["x"], w["z"]) - from
		var t := rel.dot(dir)
		if t < 0.5 or t > best_t:
			continue
		if (rel - dir * t).length() > 0.7:
			continue
		best_t = t
		best_w = w
	if best_w == null:
		return {}
	var px := float(best_w["x"])
	var pz := float(best_w["z"])
	var person := {"x": px, "y": world.ground_height(px, -pz), "z": pz}
	var impact := {
		"velocity": Vector3(dir.x * 3.0, 1.2, dir.y * 3.0),
		"spin": Vector3(dir.y * 4.0, 0.5, -dir.x * 4.0),
	}
	best_w["body"] = IMPACT_SCRIPT.create_body(person, impact)
	_downed = _count_downed()
	return {"t": best_t, "pos": Vector2(px, pz)}


func update_system(delta: float, focus: Vector3) -> void:
	var __hitch_t0 := Time.get_ticks_msec()
	if not enabled or not _built:
		return
	var px := focus.x
	var pz := -focus.z
	if not paths.is_empty() and Vector2(px, pz).distance_to(origin) > REPLACE_RADIUS:
		place(px, pz)
	time += delta
	_advance(delta)
	_push_instances(delta, focus)

	var __hitch_ms := Time.get_ticks_msec() - __hitch_t0
	if __hitch_ms > 15:
		print("[HITCH] %s 本帧 %d ms" % ["Pedestrians", __hitch_ms])

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
		# 惊逃（GTA化 §4.1）：加速 ×2.2，倒计时归零后恢复散步
		var panic := float(w["panic_t"])
		var speed_mult := 1.0
		if panic > 0.0:
			w["panic_t"] = panic - dt
			speed_mult = 2.2
		w["t"] = float(w["t"]) + float(w["dir"]) * float(w["speed"]) * speed_mult * dt / seg_len
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


## 单个行人的 5 个部件变换（{部件名 → Transform3D}，根变换 × 枢轴旋转）
func _walker_xf(w: Dictionary) -> Dictionary:
	var sc := float(w["scale"])
	var root_xf: Transform3D
	var swing := 0.0
	var body = w["body"]
	if body != null:
		# 倒地：位置取质心，姿态取 rx/ry/rz；模型的局部原点在**脚底**，
		# 所以要减去质心偏移（它要跟着 basis 一起转、一起缩放）
		var fall_basis := Basis(Vector3.UP, CoordinateUtil.node_yaw(float(body["ry"]), PED_FORWARD)) \
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
		# 根变换：朝向 + 缩放 + 落位（朝向见 PED_FORWARD 的实测说明）
		root_xf = Transform3D(
			Basis(Vector3.UP, CoordinateUtil.node_yaw(root_yaw, PED_FORWARD)).scaled(
				Vector3(sc, sc, sc)), base)

	var out := {}
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

		out[key] = root_xf * local_xf
	return out


## 只写"该写的那几个"实例。
## 索引稳定：每个 walker 在每张 MultiMesh 里的下标就是它在 walkers 里的下标
## （walkers 顺序只在 place() 时变，那时 _force_full 置真、全量重写）。
func _push_instances(dt: float, focus: Vector3) -> void:
	var n := walkers.size()
	if n == 0:
		# place() 在郊区可能一条人行道段都找不到（near 为空 → walkers 被清空）。
		# 旧实现靠"列表为空 → instance_count = 0"顺便收尾；现在只写脏实例，
		# 必须显式收掉，否则会留下一批钉在上一帧位置的人。
		if _mm_count != 0:
			for key in _parts:
				for entry in _parts[key]:
					var mm: MultiMesh = entry["mm"]
					mm.instance_count = 0
					mm.visible_instance_count = 0
			_mm_count = 0
		return
	# 实例数变了（刚 place 过）→ 这一帧必须全量写
	var full := _force_full or n != _mm_count
	var eye := Vector2(focus.x, -focus.z)
	var near_sq := NEAR_RADIUS * NEAR_RADIUS
	var dirty := PackedByteArray()
	dirty.resize(n)
	dirty.fill(0)
	var any_dirty := false
	for i in n:
		var w: Dictionary = walkers[i]
		var age := _push_age[i] + dt
		_push_age[i] = age
		var is_near := Vector2(float(w["x"]), float(w["z"])).distance_squared_to(eye) <= near_sq
		if not (full or is_near or age >= PUSH_INTERVAL):
			continue
		_push_age[i] = 0.0
		_xf_cache[i] = _walker_xf(w)
		dirty[i] = 1
		any_dirty = true
	if not any_dirty:
		return

	for key in _parts:
		for entry in _parts[key]:
			var mm: MultiMesh = entry["mm"]
			if full:
				mm.instance_count = n
				mm.visible_instance_count = n
			for i in n:
				if dirty[i] == 1:
					var cache: Dictionary = _xf_cache[i]
					var xf: Transform3D = cache[key]
					mm.set_instance_transform(i, xf)
	_mm_count = n
	_force_full = false


func diagnostics() -> Dictionary:
	return {"paths": paths.size(), "walkers": walkers.size(), "parts": _parts.size(),
			"origin": [origin.x, origin.y], "enabled": enabled, "downed": _downed}
