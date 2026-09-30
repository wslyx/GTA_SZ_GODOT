extends Node3D
class_name FlightMissiles
##
## 飞行导弹 —— 对应原版 src/city-flight-missiles.ts + city-flight-missile-simulation.ts。
##
## 参数逐字照搬 FLIGHT_MISSILE_LIMITS：
##   capacity 6 / reload .85s / lifetime 6s / launchSpeed 135 / maxSpeed 290 /
##   acceleration 95
##
## 坐标系：**数据坐标**（x 东 / y 上 / z 北），与 FlightSim 一致 —— 导弹的
## 出生点由 flightPoint(pose, right, forward, up) 算出，方向取 flightBasis 的
## forward，两者都在数据坐标里。只有画到 3D 节点时才转世界坐标
## （CoordinateUtil.to_world，z = −北）。
##
## ⚠️ 与已知的简化：原版的爆炸是体积光线步进着色器，本移植用 9 个自发光球体
## 近似（见 flight_explosion.gd 头部的说明）。

## ⚠️ 同项目里所有"新增脚本的 class_name"：全局类缓存要等编辑器重扫，
## 直接写 `FlightExplosion.new()` 会报 "Identifier not declared"（无头实跑抓到），
## 必须 preload。
const EXPLOSION_SCRIPT := preload("res://scripts/vehicles/flight_explosion.gd")

const CAPACITY := 6
const RELOAD := 0.85
const LIFETIME := 6.0
const LAUNCH_SPEED := 135.0
const MAX_SPEED := 290.0
const ACCELERATION := 95.0

## 原版 fire() 的挂点偏移：右 3.4（左右翼交替）/ 上 2.2 / 前 −0.35
const WING_OFFSET := 3.4
const VERTICAL_OFFSET := 2.2
const FORWARD_OFFSET := -0.35

var cooldown := 0.0
var shots := 0
var hits := 0

## {slot, position: Vector3, direction: Vector3, speed, age, yaw, pitch, roll, travel}
var _missiles: Array = []
## [{root: Node3D, flame: MeshInstance3D, wake: MeshInstance3D}]
var _visuals: Array = []
var _effects: Array = []      ## [{fx: FlightExplosion, age: float}]
var _wing := 1


func _ready() -> void:
	var body := _mat("ceramic", Color(0.66, 0.70, 0.73), 1.0)
	var dark := _mat("fins", Color(0.10, 0.14, 0.18), 1.0)
	var hot := _mat("exhaust", Color(1.0, 0.42, 0.035), 2.5)
	var smoke := _mat("wake", Color(0.34, 0.39, 0.44), 0.0, 0.22)
	smoke.no_depth_test = true

	var barrel_mesh := CylinderMesh.new()
	barrel_mesh.top_radius = 0.12
	barrel_mesh.bottom_radius = 0.12
	barrel_mesh.height = 1.85
	barrel_mesh.radial_segments = 10
	var nose_mesh := CylinderMesh.new()
	nose_mesh.top_radius = 0.0
	nose_mesh.bottom_radius = 0.12
	nose_mesh.height = 0.5
	nose_mesh.radial_segments = 10
	var fin_mesh := BoxMesh.new()
	fin_mesh.size = Vector3(0.40, 0.025, 0.38)
	var flame_mesh := CylinderMesh.new()
	flame_mesh.top_radius = 0.015
	flame_mesh.bottom_radius = 0.12
	flame_mesh.height = 1.0
	flame_mesh.radial_segments = 8
	var wake_mesh := CylinderMesh.new()
	wake_mesh.top_radius = 0.35
	wake_mesh.bottom_radius = 0.055
	wake_mesh.height = 1.0
	wake_mesh.radial_segments = 8

	for slot in CAPACITY:
		var root := Node3D.new()
		root.name = "flight-missile-%d" % slot
		add_child(root)
		# 弹体局部 +Z 是弹头：圆柱默认沿 Y，绕 X 转 90° 后沿 Z
		var barrel := _part(root, "missile-body", barrel_mesh, body)
		barrel.rotation.x = PI * 0.5
		var nose := _part(root, "missile-nose", nose_mesh, dark)
		nose.rotation.x = PI * 0.5
		nose.position.z = 1.175
		for i in 4:
			var angle := float(i) * PI * 0.5
			var fin := _part(root, "missile-fin-%d" % i, fin_mesh, dark)
			fin.rotation.z = angle
			fin.position = Vector3(cos(angle) * 0.22, sin(angle) * 0.22, -0.67)
		var flame := _part(root, "missile-exhaust", flame_mesh, hot)
		flame.rotation.x = -PI * 0.5
		var wake := _part(root, "missile-wake", wake_mesh, smoke)
		wake.rotation.x = -PI * 0.5
		root.visible = false
		_visuals.append({"root": root, "flame": flame, "wake": wake})

	# 原版：两个爆炸效果轮着用（effects = [new FlightExplosion(), ...]）
	for i in 2:
		var fx = EXPLOSION_SCRIPT.new()
		fx.name = "flight-explosion-%d" % i
		add_child(fx)
		_effects.append({"fx": fx, "age": 99.0})


func _mat(_name: String, color: Color, glow: float, alpha := 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	# ⚠️ Resource 在 Godot 4 里叫 resource_name（没有 name 属性）：
	# 写 m.name 会落进 3.x 兼容层报
	# "Godot 3.x SpatialMaterial remapped parameter not found: name"。
	m.resource_name = "flight-missile-%s" % _name
	# 原版 disableLighting = true + emissiveColor = color.scale(glow)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(color.r * glow, color.g * glow, color.b * glow, alpha)
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


func _part(root: Node3D, name: String, mesh: Mesh, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)
	return mi


# ---------------------------------------------------------------------------
# 仿真（原版 FlightMissileSimulation）
# ---------------------------------------------------------------------------

## pose: {x,y,z,yaw,pitch,roll}（数据坐标）；air_speed 是载机空速。
## 返回是否成功发射（冷却中或池满时返回 false，与原版一致）。
func fire(pose: Dictionary, air_speed: float) -> bool:
	if cooldown > 0.0 or _missiles.size() >= CAPACITY:
		return false
	if not is_finite_pose(pose) or not is_finite(air_speed):
		return false
	var slot := -1
	for i in CAPACITY:
		var taken := false
		for m in _missiles:
			if int(m["slot"]) == i:
				taken = true
				break
		if not taken:
			slot = i
			break
	var b := FlightSim.basis_from(float(pose["yaw"]), float(pose["pitch"]),
		float(pose["roll"]))
	var fwd: Vector3 = b["forward"]
	var right: Vector3 = b["right"]
	var up: Vector3 = b["up"]
	var pos := Vector3(float(pose["x"]), float(pose["y"]), float(pose["z"])) \
		+ right * (float(_wing) * WING_OFFSET) \
		+ up * VERTICAL_OFFSET + fwd * FORWARD_OFFSET
	_missiles.append({
		"slot": slot,
		"position": pos,
		"direction": fwd,
		"speed": minf(MAX_SPEED, LAUNCH_SPEED + maxf(0.0, air_speed)),
		"age": 0.0,
		"yaw": float(pose["yaw"]),
		"pitch": float(pose["pitch"]),
		"roll": float(pose["roll"]),
		"up": up,
		"travel": 0.0,
	})
	_wing *= -1
	cooldown = RELOAD
	shots += 1
	return true


## 推进一帧。sweep(from: Vector3, to: Vector3) -> Dictionary，空字典表示未命中
##（数据坐标，与 FlightSim.step 用的是同一个回调）。
## 返回命中列表 [{hit: Dictionary, yaw: float}]。
func step(dt: float, sweep: Callable) -> Array:
	var impacts: Array = []
	if not is_finite(dt) or dt <= 0.0:
		return impacts
	var h := minf(0.1, dt)
	cooldown = maxf(0.0, cooldown - h)
	for i in range(_missiles.size() - 1, -1, -1):
		var m: Dictionary = _missiles[i]
		var time: float = minf(h, LIFETIME - float(m["age"]))
		var accelerating: float = minf(time,
			maxf(0.0, (MAX_SPEED - float(m["speed"])) / ACCELERATION))
		var spd: float = float(m["speed"]) + ACCELERATION * accelerating
		var travel: float = float(m["speed"]) * accelerating \
			+ 0.5 * ACCELERATION * accelerating * accelerating \
			+ spd * (time - accelerating)
		var dir: Vector3 = m["direction"]
		var from: Vector3 = m["position"]
		var next := from + dir * travel
		var hit: Dictionary = sweep.call(from, next)
		m["age"] = float(m["age"]) + time
		m["speed"] = spd
		m["travel"] = float(m["travel"]) + travel
		if (not hit.is_empty()) or float(m["age"]) >= LIFETIME - 1e-8:
			_missiles.remove_at(i)
			if not hit.is_empty():
				hits += 1
				impacts.append({"hit": hit, "yaw": float(m["yaw"])})
		else:
			m["position"] = next
	return impacts


## 原版 FlightMissiles.step 的下半段：爆炸推进 + 视觉同步
func update_visuals(dt: float, impacts: Array) -> void:
	if is_finite(dt) and dt > 0.0:
		var h := minf(0.1, dt)
		for e in _effects:
			if float(e["age"]) < 3.2:
				e["age"] = float(e["age"]) + h
				var fx = e["fx"]
				fx.step(float(e["age"]))
				if float(e["age"]) >= 3.2:
					fx.reset()
	for im in impacts:
		var best: Dictionary = {}
		for e in _effects:
			if best.is_empty() or float(e["age"]) > float(best["age"]):
				best = e
		if best.is_empty():
			continue
		var hit: Dictionary = im["hit"]
		var p: Dictionary = hit.get("point", {})
		# 命中点在数据坐标，爆点抬 0.15 m（原版 p.y + .15）
		var world_pos := CoordinateUtil.to_world(float(p.get("x", 0.0)),
			float(p.get("z", 0.0)), float(p.get("y", 0.0)) + 0.15)
		var fx2 = best["fx"]
		fx2.burst(world_pos, float(im["yaw"]))
		best["age"] = 0.0
	# 池里已不存在的槽位收起
	for i in _visuals.size():
		var alive := false
		for m in _missiles:
			if int(m["slot"]) == i:
				alive = true
				break
		if not alive:
			var v: Dictionary = _visuals[i]
			(v["root"] as Node3D).visible = false
	for m in _missiles:
		_draw(m)


func _draw(m: Dictionary) -> void:
	var v: Dictionary = _visuals[int(m["slot"])]
	var root: Node3D = v["root"]
	root.visible = true
	var dir: Vector3 = m["direction"]
	var up: Vector3 = m["up"] if m.has("up") else Vector3.UP
	var pos: Vector3 = m["position"]
	# 数据坐标 → 世界坐标，并把弹头（局部 +Z）对准飞行方向
	var z_axis := Vector3(dir.x, dir.y, -dir.z).normalized()
	var up_w := Vector3(up.x, up.y, -up.z)
	if up_w.length_squared() < 1e-6 or absf(up_w.dot(z_axis)) > 0.999:
		up_w = Vector3.UP
	var y_axis := (up_w - z_axis * up_w.dot(z_axis)).normalized()
	var x_axis := y_axis.cross(z_axis)
	root.global_transform = Transform3D(Basis(x_axis, y_axis, z_axis),
		CoordinateUtil.to_world(pos.x, pos.z, pos.y))

	var flame: MeshInstance3D = v["flame"]
	var flicker := 1.0 + sin(float(m["age"]) * 83.0 + float(m["slot"])) * 0.13
	var flame_len := 1.8 * flicker
	flame.scale.y = flame_len
	flame.position.z = -0.93 - flame_len * 0.5

	var wake: MeshInstance3D = v["wake"]
	var wake_len := minf(17.0, float(m["travel"]))
	wake.scale.y = maxf(0.0001, wake_len)
	wake.position.z = -1.9 - wake_len * 0.5
	wake.visible = wake_len > 0.01


## 载机坠毁时的爆点（原版 city-flight.ts:88 的 this.burst(vector(hit.point))）
func burst_at(data_point: Vector3, yaw: float) -> void:
	var best: Dictionary = {}
	for e in _effects:
		if best.is_empty() or float(e["age"]) > float(best["age"]):
			best = e
	if best.is_empty():
		return
	var fx = best["fx"]
	fx.burst(CoordinateUtil.to_world(data_point.x, data_point.z, data_point.y + 0.15), yaw)
	best["age"] = 0.0


func clear() -> void:
	_missiles.clear()
	cooldown = 0.0
	_wing = 1
	for v in _visuals:
		(v["root"] as Node3D).visible = false
	for e in _effects:
		var fx = e["fx"]
		fx.reset()
		e["age"] = 99.0


func stats() -> Dictionary:
	var firing := 0
	for e in _effects:
		if float(e["age"]) < 3.2:
			firing += 1
	var fireballs := 0
	for e in _effects:
		var fx = e["fx"]
		fireballs += int(fx.stats()["fireballs"])
	return {
		"shots": shots, "hits": hits, "active": _missiles.size(),
		"cooldown": cooldown, "effects": firing, "fireballs": fireballs,
	}


func is_finite_pose(pose: Dictionary) -> bool:
	for k in ["x", "y", "z", "yaw", "pitch", "roll"]:
		if not is_finite(float(pose.get(k, 0.0))):
			return false
	return true


func is_finite(v: float) -> bool:
	return not (is_nan(v) or is_inf(v))
