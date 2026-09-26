extends RefCounted
class_name PedestrianImpact
##
## 行人被撞倒地 —— 逐行移植原版 src/pedestrian-impact.ts。
##
## 这是一个**纯数学模块**：不建场景对象、不掷随机数、不改车。调用方给它
## 「碰撞回滚**之后**的前后两帧车姿」与一个行人点，它返回一个碰撞结果
## （速度 / 自旋 / 接触点 / 命中参数），再用 `create_body` + `step_body`
## 推进一个刚体。
##
## 为什么必须用解析扫掠而不是"逐帧测距"：原版注释写得很清楚 ——
## 直线运动用解析扫掠，**再长的帧也不会跳过一个人**；转向则用同一
## 圆角 OBB 做有界区间扫掠（在区间中点冻结朝向 + 按角速度放大半径做保守加宽）。
##
## 坐标：入参全是**数据坐标** (x = 东, z = 北)。

const CAR_HALF_WIDTH := 1.03
const CAR_HALF_LENGTH := 2.5
const CAR_HEIGHT := 1.45
const PERSON_RADIUS := 0.28
const PERSON_HEIGHT := 1.76
const CENTRE_HEIGHT := 0.9
const GRAVITY := 18.0
const MAX_HORIZONTAL_SPEED := 26.0
const MAX_VERTICAL_SPEED := 10.0
const MAX_SPIN := 14.0
const MAX_FRAME_DT := 0.1
const MAX_SUBSTEPS := 6
const REST_SECONDS := 0.8


static func _wrap(v: float) -> float:
	return atan2(sin(v), cos(v))


static func _finite(v: float, fallback: float = 0.0) -> float:
	return v if is_finite(v) else fallback


## 原版 lineBox：返回进入参数，或 NAN 表示不相交
static func _line_box(x: float, z: float, dx: float, dz: float, hx: float, hz: float,
		lo0: float, hi0: float) -> float:
	var lo := lo0
	var hi := hi0
	for pair in [[x, dx, hx], [z, dz, hz]]:
		var p: float = pair[0]
		var d: float = pair[1]
		var h: float = pair[2]
		if absf(d) < 1e-10:
			if absf(p) > h:
				return NAN
			continue
		var a := (-h - p) / d
		var b := (h - p) / d
		lo = maxf(lo, minf(a, b))
		hi = minf(hi, maxf(a, b))
		if lo > hi:
			return NAN
	return lo


## 原版 roundedBoxSweep：对"被行人半径圆角化的矩形"做精确直线扫掠
static func _rounded_box_sweep(x: float, z: float, dx: float, dz: float,
		lo: float, hi: float, r: float = PERSON_RADIUS) -> float:
	var w := CAR_HALF_WIDTH
	var l := CAR_HALF_LENGTH
	var first := INF
	for pair in [[w + r, l], [w, l + r]]:
		var t := _line_box(x, z, dx, dz, pair[0], pair[1], lo, hi)
		if not is_nan(t):
			first = minf(first, t)
	var a := dx * dx + dz * dz
	# ⚠️ 用 PackedFloat32Array 而不是 [..]：普通数组的循环变量是 Variant，
	# `var px := x - cx` 会推断不出来（本项目这一档是当错误看的）
	for cx in PackedFloat32Array([-w, w]):
		for cz in PackedFloat32Array([-l, l]):
			var px := x - cx
			var pz := z - cz
			var at_x := px + dx * lo
			var at_z := pz + dz * lo
			if at_x * at_x + at_z * at_z <= r * r:
				first = minf(first, lo)
				continue
			if a < 1e-12:
				continue
			var b := 2.0 * (px * dx + pz * dz)
			var disc := b * b - 4.0 * a * (px * px + pz * pz - r * r)
			if disc < 0.0:
				continue
			var t2 := (-b - sqrt(disc)) / (2.0 * a)
			if t2 >= lo and t2 <= hi:
				first = minf(first, t2)
	return first if is_finite(first) else NAN


## 原版 `local(t)`：把行人相对车的位置投影到"该时刻朝向"的车体坐标系
static func _local(before: Dictionary, dx: float, dz: float, dyaw: float,
		person_x: float, person_z: float, t: float) -> Dictionary:
	var yaw := float(before["yaw"]) + dyaw * t
	var c := cos(yaw)
	var s := sin(yaw)
	var x := person_x - (float(before["x"]) + dx * t)
	var z := person_z - (float(before["z"]) + dz * t)
	var right := x * c - z * s
	var forward := x * s + z * c
	var qx := clampf(right, -CAR_HALF_WIDTH, CAR_HALF_WIDTH)
	var qz := clampf(forward, -CAR_HALF_LENGTH, CAR_HALF_LENGTH)
	return {"c": c, "s": s, "right": right, "forward": forward, "qx": qx, "qz": qz,
		"distance": sqrt((right - qx) * (right - qx) + (forward - qz) * (forward - qz)) - PERSON_RADIUS}


## 原版 detectPedestrianImpact。命中返回结果字典，未命中返回 {}。
static func detect(before: Dictionary, after: Dictionary, person: Dictionary) -> Dictionary:
	for k in ["x", "z", "yaw", "speed", "groundY"]:
		if not is_finite(float(before.get(k, NAN))) or not is_finite(float(after.get(k, NAN))):
			return {}
	for k in ["x", "y", "z"]:
		if not is_finite(float(person.get(k, NAN))):
			return {}
	var dx := float(after["x"]) - float(before["x"])
	var dz := float(after["z"]) - float(before["z"])
	var travel := sqrt(dx * dx + dz * dz)
	var dyaw := _wrap(float(after["yaw"]) - float(before["yaw"]))
	var car_speed := minf(60.0, (absf(float(before["speed"])) + absf(float(after["speed"]))) * 0.5)
	if car_speed < 0.35 or (travel < 1e-5 and absf(dyaw) < 1e-5):
		return {}
	var px := float(person["x"])
	var py := float(person["y"])
	var pz := float(person["z"])

	# 把扫掠夹到垂直重叠区间：桥上的路撞不到桥下的人
	var lo := 0.0
	var hi := 1.0
	var dy := float(after["groundY"]) - float(before["groundY"])
	var min_y := py - CAR_HEIGHT
	var max_y := py + PERSON_HEIGHT
	if absf(dy) < 1e-9:
		if float(before["groundY"]) < min_y or float(before["groundY"]) > max_y:
			return {}
	else:
		var a := (min_y - float(before["groundY"])) / dy
		var b := (max_y - float(before["groundY"])) / dy
		lo = maxf(lo, minf(a, b))
		hi = minf(hi, maxf(a, b))
		if lo > hi:
			return {}
	var projection := lo
	if travel > 1e-9:
		projection = clampf(((px - float(before["x"])) * dx + (pz - float(before["z"])) * dz)
			/ (travel * travel), lo, hi)
	var broad := sqrt(CAR_HALF_WIDTH * CAR_HALF_WIDTH + CAR_HALF_LENGTH * CAR_HALF_LENGTH) + PERSON_RADIUS
	var cx := float(before["x"]) + dx * projection
	var cz := float(before["z"]) + dz * projection
	if sqrt((px - cx) * (px - cx) + (pz - cz) * (pz - cz)) > broad:
		return {}

	# 精确判定
	var fraction := NAN
	if absf(dyaw) < 1e-7:
		var p := _local(before, dx, dz, dyaw, px, pz, 0.0)
		fraction = _rounded_box_sweep(p["right"], p["forward"],
			-dx * float(p["c"]) + dz * float(p["s"]),
			-dx * float(p["s"]) - dz * float(p["c"]), lo, hi)
	else:
		# 转向：在区间中点冻结朝向，并按最大角速度保守加宽半径；
		# 解析平移随后把区间里空的那段丢掉。
		var pending: Array = [[lo, hi]]
		var corner := sqrt(CAR_HALF_WIDTH * CAR_HALF_WIDTH + CAR_HALF_LENGTH * CAR_HALF_LENGTH)
		var checked := 0
		while not pending.is_empty() and checked < 128:
			checked += 1
			var span: Array = pending.pop_back()
			var start := float(span[0])
			var end := float(span[1])
			var mid := (start + end) * 0.5
			var yaw := float(before["yaw"]) + dyaw * mid
			var c := cos(yaw)
			var s := sin(yaw)
			var lx := px - float(before["x"])
			var lz := pz - float(before["z"])
			var padding := 2.0 * corner * sin(absf(dyaw) * (end - start) / 4.0)
			var entry := _rounded_box_sweep(lx * c - lz * s, lx * s + lz * c,
				-dx * c + dz * s, -dx * s - dz * c, start, end, PERSON_RADIUS + padding)
			if is_nan(entry):
				continue
			if float(_local(before, dx, dz, dyaw, px, pz, entry)["distance"]) <= 1e-4:
				fraction = entry
				break
			var sample := (entry + end) * 0.5
			if float(_local(before, dx, dz, dyaw, px, pz, sample)["distance"]) <= 1e-4:
				var a2 := entry
				var b2 := sample
				for i in 16:
					var t2 := (a2 + b2) * 0.5
					if float(_local(before, dx, dz, dyaw, px, pz, t2)["distance"]) <= 1e-4:
						b2 = t2
					else:
						a2 = t2
				fraction = b2
				break
			if end - entry < 1e-7:
				continue
			pending.append([sample, end])
			pending.append([entry, sample])
	if is_nan(fraction):
		return {}

	var p2 := _local(before, dx, dz, dyaw, px, pz, fraction)
	var sx := float(p2["right"]) - float(p2["qx"])
	var sz := float(p2["forward"]) - float(p2["qz"])
	var length := sqrt(sx * sx + sz * sz)
	var motion_x := sin(float(after["yaw"])) * signf(float(after["speed"]))
	var motion_z := cos(float(after["yaw"])) * signf(float(after["speed"]))
	if travel > 1e-5:
		motion_x = dx / travel
		motion_z = dz / travel
	var nx := motion_x
	var nz := motion_z
	if length > 1e-6:
		nx = (sx * float(p2["c"]) + sz * float(p2["s"])) / length
		nz = (-sx * float(p2["s"]) + sz * float(p2["c"])) / length
	var pvx := clampf(_finite(float(person.get("vx", 0.0))), -10.0, 10.0)
	var pvz := clampf(_finite(float(person.get("vz", 0.0))), -10.0, 10.0)
	var closing := (motion_x * car_speed - pvx) * nx + (motion_z * car_speed - pvz) * nz
	if closing < -0.1 and absf(dyaw) < 1e-7:
		return {}
	var speed := clampf(maxf(closing, car_speed * 0.12), 0.0, 60.0)
	var push_x := nx * 0.65 + motion_x * 0.35
	var push_z := nz * 0.65 + motion_z * 0.35
	var push_len := sqrt(push_x * push_x + push_z * push_z)
	if push_len < 1e-5:
		push_x = motion_x
		push_z = motion_z
		push_len = 1.0
	push_x /= push_len
	push_z /= push_len
	var horizontal := minf(MAX_HORIZONTAL_SPEED, 0.25 + speed * 0.58)
	var lift := minf(MAX_VERTICAL_SPEED, 0.12 + maxf(0.0, speed - 1.2) * 0.22)
	var vx := push_x * horizontal + pvx * 0.15
	var vz := push_z * horizontal + pvz * 0.15
	var scale := minf(1.0, MAX_HORIZONTAL_SPEED / maxf(1e-9, sqrt(vx * vx + vz * vz)))
	var spin := minf(MAX_SPIN, 0.18 + speed * 0.34)
	var side := clampf(float(p2["right"]) / CAR_HALF_WIDTH, -1.0, 1.0)
	var contact_x := float(before["x"]) + dx * fraction + float(p2["qx"]) * float(p2["c"]) + float(p2["qz"]) * float(p2["s"])
	var contact_z := float(before["z"]) + dz * fraction - float(p2["qx"]) * float(p2["s"]) + float(p2["qz"]) * float(p2["c"])
	var gy := lerpf(float(before["groundY"]), float(after["groundY"]), fraction)
	return {
		"velocity": Vector3(vx * scale, lift, vz * scale),
		"spin": Vector3(push_z * spin, side * minf(6.0, speed * 0.12), -push_x * spin),
		"speed": speed,
		"normal": Vector2(nx, nz),
		"contact": Vector3(contact_x, clampf(py + 0.8, gy, gy + CAR_HEIGHT), contact_z),
		"fraction": fraction,
	}


## 原版 pedestrianSupportHeight：半高 .87 / 半宽 .30 / 半深 .22 的旋转 OBB 支撑高度
static func support_height(rx: float, rz: float) -> float:
	var pitch := _finite(rx)
	var roll := _finite(rz)
	return 0.87 * absf(cos(pitch) * cos(roll)) + 0.30 * absf(cos(pitch) * sin(roll)) \
		+ 0.22 * absf(sin(pitch)) + 0.05


## 原版 createPedestrianBody
static func create_body(person: Dictionary, impact: Dictionary) -> Dictionary:
	var ground_y := _finite(float(person.get("y", 0.0)))
	var v: Vector3 = impact["velocity"]
	var s: Vector3 = impact["spin"]
	return {
		"x": _finite(float(person.get("x", 0.0))),
		"y": ground_y + CENTRE_HEIGHT,
		"z": _finite(float(person.get("z", 0.0))),
		"vx": clampf(_finite(v.x), -MAX_HORIZONTAL_SPEED, MAX_HORIZONTAL_SPEED),
		"vy": clampf(_finite(v.y), -MAX_VERTICAL_SPEED, MAX_VERTICAL_SPEED),
		"vz": clampf(_finite(v.z), -MAX_HORIZONTAL_SPEED, MAX_HORIZONTAL_SPEED),
		"rx": 0.0, "ry": 0.0, "rz": 0.0,
		"wx": clampf(_finite(s.x), -MAX_SPIN, MAX_SPIN),
		"wy": clampf(_finite(s.y), -MAX_SPIN, MAX_SPIN),
		"wz": clampf(_finite(s.z), -MAX_SPIN, MAX_SPIN),
		"grounded": false, "phase": "airborne", "age": 0.0, "restTime": 0.0,
		"bounces": 0, "groundY": ground_y,
	}


## 原版 stepPedestrianBody（就地修改 body）
##
## 工作量上限 6 个 60Hz 子步：即使标签页被挂起，多余的帧时间也是**丢弃**而不是
## 让刚性体穿模。`blocked` 是世界的静态墙/陆地边界判定（不含其它 body）。
static func step_body(body: Dictionary, dt: float, height_at: Callable,
		blocked: Callable) -> void:
	if not is_finite(dt) or dt <= 0.0 or str(body["phase"]) == "recovering":
		return
	for key in ["x", "y", "z", "vx", "vy", "vz", "rx", "ry", "rz", "wx", "wy", "wz",
			"age", "restTime", "groundY"]:
		body[key] = _finite(float(body[key]))
	var horizontal := sqrt(float(body["vx"]) * float(body["vx"]) + float(body["vz"]) * float(body["vz"]))
	var vscale := minf(1.0, MAX_HORIZONTAL_SPEED / maxf(1e-9, horizontal))
	body["vx"] = float(body["vx"]) * vscale
	body["vz"] = float(body["vz"]) * vscale
	body["vy"] = clampf(float(body["vy"]), -40.0, MAX_VERTICAL_SPEED)
	for key2 in ["wx", "wy", "wz"]:
		body[key2] = clampf(float(body[key2]), -MAX_SPIN, MAX_SPIN)
	var frame := minf(dt, MAX_FRAME_DT)
	var steps := mini(MAX_SUBSTEPS, int(ceil(frame * 60.0)))
	var h := frame / float(maxi(steps, 1))
	for _i in steps:
		if is_zero_approx(float(body["age"])):
			body["y"] = maxf(float(body["y"]),
				float(body["groundY"]) + support_height(float(body["rx"]), float(body["rz"])))
		body["age"] = float(body["age"]) + h
		if bool(body["grounded"]):
			var pitch := _wrap(float(body["rx"]))
			var target := (PI / 2.0 if pitch >= 0.0 else -PI / 2.0)
			var settle := 1.0 - exp(-9.0 * h)
			body["rx"] = float(body["rx"]) + _wrap(target - float(body["rx"])) * settle
			body["rz"] = float(body["rz"]) + _wrap(-float(body["rz"])) * settle
			body["wx"] = float(body["wx"]) * exp(-10.0 * h)
			body["wz"] = float(body["wz"]) * exp(-10.0 * h)
		else:
			body["vy"] = float(body["vy"]) - GRAVITY * h
			body["rx"] = float(body["rx"]) + float(body["wx"]) * h
			body["rz"] = float(body["rz"]) + float(body["wz"]) * h
		body["ry"] = float(body["ry"]) + float(body["wy"]) * h

		var dx := float(body["vx"]) * h
		var dz := float(body["vz"]) * h
		var segments := maxi(1, int(ceil(sqrt(dx * dx + dz * dz) / 0.18)))
		for _j in segments:
			var nx := float(body["x"]) + dx / float(segments)
			var nz := float(body["z"]) + dz / float(segments)
			if _clear(nx, nz, blocked):
				body["x"] = nx
				body["z"] = nz
				continue
			var along_x := _clear(nx, float(body["z"]), blocked)
			var along_z := _clear(float(body["x"]), nz, blocked)
			if along_x and not along_z:
				body["x"] = nx
				body["vz"] = float(body["vz"]) * -0.12
				body["vx"] = float(body["vx"]) * 0.7
			elif along_z and not along_x:
				body["z"] = nz
				body["vx"] = float(body["vx"]) * -0.12
				body["vz"] = float(body["vz"]) * 0.7
			else:
				body["vx"] = float(body["vx"]) * -0.1
				body["vz"] = float(body["vz"]) * -0.1
			break

		var floor_y := float(height_at.call(float(body["x"]), float(body["z"])))
		body["groundY"] = _finite(floor_y, float(body["groundY"]))
		var support := support_height(float(body["rx"]), float(body["rz"]))
		var bottom := float(body["groundY"]) + support
		if bool(body["grounded"]):
			# 地形往下掉就脱离地面；小坡保持贴地
			if float(body["y"]) > bottom + 0.3:
				body["grounded"] = false
				body["phase"] = "airborne"
				body["vy"] = 0.0
			else:
				body["y"] = bottom
				body["vy"] = 0.0
		else:
			body["y"] = float(body["y"]) + float(body["vy"]) * h
			if float(body["y"]) <= bottom:
				body["y"] = bottom
				if float(body["vy"]) < -2.0 and int(body["bounces"]) == 0:
					body["vy"] = minf(1.25, -float(body["vy"]) * 0.14)
					body["bounces"] = 1
					body["wx"] = float(body["wx"]) * 0.45
					body["wy"] = float(body["wy"]) * 0.45
					body["wz"] = float(body["wz"]) * 0.45
				else:
					body["vy"] = 0.0
					body["grounded"] = true
					body["phase"] = "sliding"
					body["wx"] = float(body["wx"]) * 0.25
					body["wy"] = float(body["wy"]) * 0.25
					body["wz"] = float(body["wz"]) * 0.25
		var damping := exp(-(3.4 if bool(body["grounded"]) else 0.25) * h)
		var spin_damping := exp(-(5.0 if bool(body["grounded"]) else 0.35) * h)
		body["vx"] = float(body["vx"]) * damping
		body["vz"] = float(body["vz"]) * damping
		body["wx"] = float(body["wx"]) * spin_damping
		body["wy"] = float(body["wy"]) * spin_damping
		body["wz"] = float(body["wz"]) * spin_damping
		body["rx"] = _wrap(float(body["rx"]))
		body["ry"] = _wrap(float(body["ry"]))
		body["rz"] = _wrap(float(body["rz"]))
		var resting := bool(body["grounded"]) \
			and sqrt(float(body["vx"]) * float(body["vx"]) + float(body["vz"]) * float(body["vz"])) < 0.18 \
			and absf(absf(float(body["rx"])) - PI / 2.0) < 0.08 \
			and absf(float(body["rz"])) < 0.08
		body["restTime"] = (float(body["restTime"]) + h) if resting else 0.0
		if float(body["restTime"]) >= REST_SECONDS:
			body["phase"] = "recovering"
			body["vx"] = 0.0
			body["vy"] = 0.0
			body["vz"] = 0.0
			body["wx"] = 0.0
			body["wy"] = 0.0
			body["wz"] = 0.0
			break


static func _clear(x: float, z: float, blocked: Callable) -> bool:
	if bool(blocked.call(x, z)):
		return false
	if bool(blocked.call(x + PERSON_RADIUS, z)):
		return false
	if bool(blocked.call(x - PERSON_RADIUS, z)):
		return false
	if bool(blocked.call(x, z + PERSON_RADIUS)):
		return false
	if bool(blocked.call(x, z - PERSON_RADIUS)):
		return false
	return true
