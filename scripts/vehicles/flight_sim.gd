extends RefCounted
class_name FlightSim
##
## 观光飞机飞行模拟 —— 逐行移植原版 city-flight-simulation.ts。
##
## 要点（照搬原版）：
##   - 用 1/120s 固定子步积分，一帧内可跑多步，避免高速穿模
##   - pitch 收敛到 ±.57、roll 收敛到 ±.82，yaw 由 roll 与方向舵共同驱动
##   - 速度向 24 + throttle*53 - pitch*13 指数逼近
##   - 天花板 2100；超出 extent（外扩 15）判定越界并回退
##   - 撞机检测：对机鼻/机尾/浮筒/翼尖共 9 个点做扫掠，外加当前整条翼展
##   - 坠毁后 3000ms 自动恢复（原版 FLIGHT_RECOVERY_MS）
##
## 坐标：数据坐标 (east, y, north)。

const RECOVERY_MS := 3000
const SUBSTEP := 1.0 / 120.0
const MAX_Y := 2100.0
const BOUNDARY_MARGIN := 15.0
const START_SPEED := 48.0
const START_THROTTLE := 0.55

## 碰撞采样点 [right, forward, up]（原版 city-flight-simulation.ts:43）
const CRASH_POINTS := [
	[0.0, 4.7, 0.0],
	[0.0, -5.2, 0.0],
	[-6.9, 0.0, 1.1],
	[6.9, 0.0, 1.1],
	[-3.4, 0.0, 1.1],
	[3.4, 0.0, 1.1],
	[-1.64, 1.0, -1.45],
	[1.64, 1.0, -1.45],
	[0.0, 0.0, 0.0],
]

var phase := "idle"  ## idle | flying | exploding
var x := 0.0
var y := 120.0
var z := 0.0
var yaw := 0.0
var pitch := 0.0
var roll := 0.0
var speed := START_SPEED
var throttle := START_THROTTLE
var crashed_at := 0
var hit: Dictionary = {}
var crashes := 0
var last_safe := {}


func active() -> bool:
	return phase != "idle"


func start(px: float, py: float, pz: float, pyaw: float) -> void:
	x = px
	y = py
	z = pz
	yaw = pyaw
	pitch = 0.0
	roll = 0.0
	speed = START_SPEED
	throttle = START_THROTTLE
	phase = "flying"
	hit = {}
	crashed_at = 0
	last_safe = _pose()


func stop() -> void:
	phase = "idle"
	hit = {}
	crashed_at = 0


func _pose() -> Dictionary:
	return {"x": x, "y": y, "z": z, "yaw": yaw, "pitch": pitch, "roll": roll}


func _restore(p: Dictionary) -> void:
	x = p["x"]
	y = p["y"]
	z = p["z"]
	yaw = p["yaw"]
	pitch = p["pitch"]
	roll = p["roll"]


## 机体基向量（原版 flightBasis）
func basis() -> Dictionary:
	var sy := sin(yaw)
	var cy := cos(yaw)
	var sp := sin(pitch)
	var cp := cos(pitch)
	var sr := sin(roll)
	var cr := cos(roll)
	var forward := Vector3(sy * cp, sp, cy * cp)
	var right := Vector3(cy * cr + sy * sp * sr, -cp * sr, -sy * cr + cy * sp * sr)
	var up := Vector3(
		forward.y * right.z - forward.z * right.y,
		forward.z * right.x - forward.x * right.z,
		forward.x * right.y - forward.y * right.x)
	return {"forward": forward, "right": right, "up": up}


func point_at(right: float, forward: float, up := 0.0) -> Vector3:
	var b := basis()
	return Vector3(x, y, z) + b["right"] * right + b["forward"] * forward + b["up"] * up


func _axis(input: Dictionary, pos_keys: Array, neg_keys: Array) -> float:
	var p := 0.0
	for k in pos_keys:
		if input.get(k, false):
			p = 1.0
	for k in neg_keys:
		if input.get(k, false):
			p -= 1.0
	return p


## 返回 "crashed" / "recovered" / "boundary" / ""
## sweep 回调签名：func(from: Vector3, to: Vector3) -> Dictionary（空字典表示未命中）
func step(input: Dictionary, dt_raw: float, now_ms: int, sweep: Callable, extent: Rect2) -> String:
	if phase == "idle":
		return ""
	if phase == "exploding":
		if now_ms - crashed_at >= RECOVERY_MS:
			phase = "idle"
			return "recovered"
		return ""

	var pitch_in := _axis(input, ["move_forward", "move_forward_alt"], ["move_back", "move_back_alt"])
	var roll_in := _axis(input, ["steer_right", "steer_right_alt"], ["steer_left", "steer_left_alt"])
	var rudder := _axis(input, ["turret_right"], ["turret_left"])
	var thrust := _axis(input, ["run"], ["brake_tank"])

	var left := clampf(dt_raw, 0.0, 0.1)
	while left > 1e-7:
		var h := minf(left, SUBSTEP)
		left -= h
		var before := _pose()

		throttle = clampf(throttle + thrust * h * 0.4, 0.0, 1.0)
		pitch += (pitch_in * 0.57 - pitch) * (1.0 - exp(-h * 1.7))
		roll += (roll_in * 0.82 - roll) * (1.0 - exp(-h * 2.5))
		yaw += h * (tan(roll) * 0.75 + rudder * 0.38)
		speed += (24.0 + throttle * 53.0 - pitch * 13.0 - speed) * (1.0 - exp(-h * 0.6))

		var dir: Vector3 = basis()["forward"]
		x += dir.x * speed * h
		y += dir.y * speed * h
		z += dir.z * speed * h

		if y > MAX_Y:
			y = MAX_Y
			pitch = minf(0.0, pitch)

		if (x < extent.position.x + BOUNDARY_MARGIN or x > extent.end.x - BOUNDARY_MARGIN
				or z < extent.position.y + BOUNDARY_MARGIN or z > extent.end.y - BOUNDARY_MARGIN):
			phase = "idle"
			_restore(before)
			return "boundary"

		var found := {}
		for cp in CRASH_POINTS:
			found = sweep.call(point_at(cp[0], cp[1], cp[2]), _point_from(before, cp[0], cp[1], cp[2]))
			if not found.is_empty():
				break
		if found.is_empty():
			# 整条翼展
			found = sweep.call(point_at(-6.9, 0.0, 1.1), point_at(6.9, 0.0, 1.1))

		if not found.is_empty():
			hit = found
			phase = "exploding"
			crashed_at = now_ms
			crashes += 1
			speed = 0.0
			return "crashed"

		last_safe = _pose()
	return ""


func _point_from(pose: Dictionary, right: float, forward: float, up: float) -> Vector3:
	var saved := _pose()
	_restore(pose)
	var p := point_at(right, forward, up)
	_restore(saved)
	return p


func status() -> Dictionary:
	return {"phase": phase, "active": active(), "position": [x, y, z], "yaw": yaw,
			"pitch": pitch, "roll": roll, "speed": speed, "throttle": throttle,
			"crashes": crashes, "hit": hit}
