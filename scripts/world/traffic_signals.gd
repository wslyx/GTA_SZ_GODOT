extends Node3D
class_name TrafficSignals
##
## 路口信号灯 —— 逐行移植原版 src/city-traffic-signals.ts。
##
## 相位周期（public/city/signals/traffic-signals.json 的 cycle）：
##   greenA 13 + amber 3 + allRed 1.2 + greenB 10 + amber 3 + allRed 1.2 = 30.4s
## 相位表（原版 signalAspects）：
##   [0, 13)      A 绿 / B 红
##   [13, 16)     A 黄 / B 红
##   [16, 17.2)   全红
##   [17.2, 27.2) A 红 / B 绿
##   [27.2, 30.2) A 红 / B 黄
##   其余          全红
## 每个路口有自己的 offset，灯头按 arm.group（0→A，1→B）归属相位。
##
## signalHold 的语义：给定车辆位置与朝向，返回"前方最近红灯停线还有多远"，
## 没有则返回 INF。交通车流与自动驾驶据此在停线前减速停车。

const CYCLE_FALLBACK := {"greenA": 13.0, "amber": 3.0, "allRed": 1.2, "greenB": 10.0}
const HOLD_REACH := 60.0
const CELL := 60.0
## 可见信号灯数量上限（原版按距离裁剪；这里做等效的"最近 N 个"策略）
const VISIBLE_LIMIT := 140
const RESCAN_INTERVAL := 0.5

enum Aspect { RED, AMBER, GREEN }

var cycle := {}
var cycle_length := 30.4
var junctions: Array = []   ## {x,z,radius,offset,arms:[...]}

var world: CityWorld
var time := 0.0
var _scan_timer := 0.0
var _cells: Dictionary = {}       ## cell key → Array of {arm, junction}
var _multimeshes: Array = []      ## 每个 mesh role 一个 MultiMesh
var _roles: Array = []            ## {name, mesh, material, is_lens, lens_index}
var _instance_transforms: Array = []
var _active_arms: Array = []


func setup(p_world: CityWorld) -> void:
	world = p_world
	var data: Dictionary = CityData.traffic_signals()
	cycle = data.get("cycle", CYCLE_FALLBACK)
	cycle_length = (float(cycle.get("greenA", 13.0)) + float(cycle.get("greenB", 10.0))
		+ 2.0 * (float(cycle.get("amber", 3.0)) + float(cycle.get("allRed", 1.2))))
	junctions = data.get("junctions", [])
	_build_cells()
	_load_signal_asset()
	print("[TrafficSignals] %d 个路口，周期 %.1fs" % [junctions.size(), cycle_length])


# ---------------------------------------------------------------------------
# 相位
# ---------------------------------------------------------------------------

## 返回 [groupA, groupB] 两个 aspect
func aspects_at(t: float) -> Array:
	var x := fposmod(t, cycle_length)
	var g := float(cycle.get("greenA", 13.0))
	var a := float(cycle.get("amber", 3.0))
	var r := float(cycle.get("allRed", 1.2))
	var gb := float(cycle.get("greenB", 10.0))

	if x < g:
		return [Aspect.GREEN, Aspect.RED]
	if x < g + a:
		return [Aspect.AMBER, Aspect.RED]
	if x < g + a + r:
		return [Aspect.RED, Aspect.RED]
	if x < g + a + r + gb:
		return [Aspect.RED, Aspect.GREEN]
	if x < g + a + r + gb + a:
		return [Aspect.RED, Aspect.AMBER]
	return [Aspect.RED, Aspect.RED]


func aspect_for(junction: Dictionary, arm: Dictionary) -> int:
	var offset := float(junction.get("offset", 0.0))
	var pair := aspects_at(time + offset)
	return pair[0] if int(arm.get("group", 0)) == 0 else pair[1]


# ---------------------------------------------------------------------------
# 停线查询（供交通与自动驾驶）
# ---------------------------------------------------------------------------

func _build_cells() -> void:
	for j in junctions:
		for arm in j.get("arms", []):
			var cx := int(floor(float(arm["x"]) / CELL))
			var cz := int(floor(float(arm["z"]) / CELL))
			var k := (cx + 32768) * 65536 + (cz + 32768)
			if not _cells.has(k):
				_cells[k] = []
			_cells[k].append({"arm": arm, "junction": j})


## 原版 signalHold：返回前方红灯停线距离；无则 INF
func signal_hold(x: float, z: float, yaw: float) -> float:
	var fx := sin(yaw)
	var fz := cos(yaw)
	var cx := int(floor(x / CELL))
	var cz := int(floor(z / CELL))
	var best := INF
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var k := (cx + dx + 32768) * 65536 + (cz + dz + 32768)
			if not _cells.has(k):
				continue
			for entry in _cells[k]:
				var arm: Dictionary = entry["arm"]
				var junction: Dictionary = entry["junction"]
				var arm_yaw := float(arm.get("yaw", 0.0))
				# 朝向差太大说明这条臂服务的是对向车流
				if cos(arm_yaw - yaw) > -0.8:
					continue
				var stop: Array = arm.get("stop", [0.0, 0.0])
				var sx := float(stop[0])
				var sz := float(stop[1])
				var ddx := sx - x
				var ddz := sz - z
				var ahead := ddx * fx + ddz * fz
				if ahead < -1.0 or ahead > HOLD_REACH:
					continue
				var lanes := float(arm.get("lanes", 1.0))
				var lateral := absf(ddx * fz - ddz * fx)
				if lateral > lanes + 1.5:
					continue
				var aspect := aspect_for(junction, arm)
				if aspect == Aspect.GREEN:
					continue
				# 黄灯且已在 5m 内 → 放行
				if aspect == Aspect.AMBER and ahead < 5.0:
					continue
				best = minf(best, ahead)
	return best


## 兼容原版 holdDistance 签名（点 + 朝向）
func hold_distance(pos: Vector2, dir: Vector2) -> float:
	return signal_hold(pos.x, pos.y, atan2(dir.x, dir.y))


# ---------------------------------------------------------------------------
# 渲染：每个 mesh role 一个 MultiMesh，按距离只渲染最近的一批
# ---------------------------------------------------------------------------

func _load_signal_asset() -> void:
	var path := "res://data/city/signals/traffic-signal.glb"
	if not ResourceLoader.exists(path):
		push_warning("[TrafficSignals] 缺少信号灯模型，仅保留逻辑")
		return
	var scene := load(path) as PackedScene
	if scene == null:
		return
	var inst := scene.instantiate()
	var srcs := GlbLoader.meshes_of(inst)
	for mi in srcs:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = mi.mesh
		var m := MultiMeshInstance3D.new()
		m.multimesh = mm
		m.name = "signals-" + mi.name
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(m)
		_multimeshes.append(mm)
		_roles.append({
			"name": mi.name,
			"is_lens": "lens" in mi.name.to_lower(),
			"lens": _lens_kind(mi.name),
		})
	inst.queue_free()
	print("[TrafficSignals] 信号灯模型 mesh role %d 个" % _roles.size())


func _lens_kind(mesh_name: String) -> int:
	var n := mesh_name.to_lower()
	if "red" in n:
		return Aspect.RED
	if "amber" in n:
		return Aspect.AMBER
	if "green" in n:
		return Aspect.GREEN
	return -1


func _arm_transform(arm: Dictionary, junction: Dictionary) -> Transform3D:
	# 不能叫 basis —— Node3D 已有 basis 属性
	var arm_basis := Basis(Vector3.UP, CoordinateUtil.node_yaw(float(arm.get("yaw", 0.0))))
	var g := world.ground_height(float(arm["x"]), -float(arm["z"]))
	return Transform3D(arm_basis, CoordinateUtil.to_world(float(arm["x"]), float(arm["z"]), g))


## 挑最近的若干路口重排实例（对应原版的距离裁剪）
func _rescan(focus: Vector3) -> void:
	var cands: Array = []
	var fd := Vector2(focus.x, -focus.z)
	for j in junctions:
		var d := Vector2(float(j["x"]), float(j["z"])).distance_to(fd)
		cands.append({"d": d, "j": j})
	cands.sort_custom(func(a, b): return a["d"] < b["d"])

	_active_arms.clear()
	for i in mini(VISIBLE_LIMIT, cands.size()):
		var j: Dictionary = cands[i]["j"]
		for arm in j.get("arms", []):
			_active_arms.append({"arm": arm, "junction": j})

	for mm in _multimeshes:
		mm.instance_count = _active_arms.size()
		mm.visible_instance_count = _active_arms.size()

	for idx in _active_arms.size():
		var e: Dictionary = _active_arms[idx]
		var xf := _arm_transform(e["arm"], e["junction"])
		for r in _multimeshes.size():
			_multimeshes[r].set_instance_transform(idx, xf)


## 按当前相位刷新灯色（原版每帧改 emissive；这里改 MultiMesh 实例色）
func _refresh_colors() -> void:
	# 注意是遍历 _roles（每个 mesh role 一项），不是 _roles.size()（那是 int）
	for r in _roles.size():
		var role: Dictionary = _roles[r]
		var lens_aspect := int(role["lens"])
		if lens_aspect < 0:
			continue
		var mm: MultiMesh = _multimeshes[r]
		for idx in _active_arms.size():
			var e: Dictionary = _active_arms[idx]
			var aspect := aspect_for(e["junction"], e["arm"])
			var on := aspect == lens_aspect
			var c := Color(0.06, 0.06, 0.06)
			if on:
				match lens_aspect:
					Aspect.RED: c = Color(1.0, 0.12, 0.08)
					Aspect.AMBER: c = Color(1.0, 0.66, 0.10)
					Aspect.GREEN: c = Color(0.20, 1.0, 0.35)
			mm.set_instance_color(idx, c)


func update_system(delta: float, focus: Vector3) -> void:
	time += delta
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = RESCAN_INTERVAL
		_rescan(focus)
		_refresh_colors()


func diagnostics() -> Dictionary:
	return {
		"junctions": junctions.size(),
		"cycleLength": cycle_length,
		"time": time,
		"visibleArms": _active_arms.size(),
		"roles": _roles.size(),
	}
