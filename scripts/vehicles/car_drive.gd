extends RefCounted
class_name CarDrive
##
## 汽车驾驶物理 —— 逐行移植原版 src/driving.ts 的 stepCar。
##
## 原版是纯街机式运动学，不是刚体物理：转向角由速度衰减、油门/阻力/手刹三项合成，
## 再由 yaw 积分得到位移。数值全部照抄，改动会直接改变手感。
##
## 坐标：内部状态用数据坐标 (x=east, z=north)，方向 (sin yaw, cos yaw)。

const MAX_SPEED := 53.0
const MIN_SPEED := -10.0
const WHEELBASE := 3.2
const MAX_DT := 0.05
## 车头碰撞检测点距车心的距离（原版 1.45m）
const NOSE_OFFSET := 1.45
## 手推车样式的固定障碍物由 main_game 注入

var x := 0.0
var z := 0.0
var yaw := 0.0
var speed := 0.0
var steer := 0.0
var distance := 0.0


## 键盘转向输入随速度衰减（原版 manualSteeringInput）
static func manual_steering(direction: float, spd: float) -> float:
	return clampf(direction, -1.0, 1.0) * (0.76 - 0.22 * minf(1.0, absf(spd) / 26.0))


## 原版 stepCar
## input: {throttle: float, steer: float, handbrake: bool}
##
## integrate_position = false 时只推进速度/转角/朝向，不移动位置 ——
## 主控制器需要在外部用固定子步做碰撞推进（原版 update 的
## steps = ceil(|speed| * dt / 0.7) 逻辑），否则位置会被积分两次。
func step(input: Dictionary, dt_raw: float, grip := 1.0, integrate_position := true) -> void:
	var dt := clampf(dt_raw, 0.0, MAX_DT)
	var throttle := float(input.get("throttle", 0.0))
	var steer_input := float(input.get("steer", 0.0))
	var handbrake := bool(input.get("handbrake", false))

	var v := speed
	# 1) 前轮转角朝目标值指数逼近，目标值随速度衰减
	var desired := steer_input * 0.48 / (1.0 + absf(v) * 0.026)
	steer += (desired - steer) * minf(1.0, dt * 7.0)

	# 2) 驱动力：正向油门 9；倒车时速度>1 用 18，否则 5
	var force := 0.0
	if throttle >= 0.0:
		force = throttle * 9.0
	elif v > 1.0:
		force = throttle * 18.0
	else:
		force = throttle * 5.0
	if throttle > 0.0 and v < -0.5:
		force = 18.0

	# 3) 阻力：线性 + 二次
	force -= v * 0.038 + v * absf(v) * 0.0022

	# 4) 松开油门时的滑行制动
	if is_zero_approx(throttle) and dt > 0.0:
		force -= signf(v) * minf(absf(v) / maxf(0.001, dt), 0.8)

	# 5) 手刹
	if handbrake and dt > 0.0:
		force -= signf(v) * minf(absf(v) / maxf(0.001, dt), 10.0)

	speed = clampf(v + force * dt, MIN_SPEED, MAX_SPEED * grip)

	# 6) 自行车模型积分 yaw（手刹时转向增益 1.3）
	var yaw_gain := 1.3 if handbrake else 1.0
	yaw += speed / WHEELBASE * tan(steer) * dt * yaw_gain

	# 7) 位移
	if integrate_position:
		var moved := speed * dt
		x += sin(yaw) * moved
		z += cos(yaw) * moved
		distance += absf(moved)


func state() -> Dictionary:
	return {"x": x, "z": z, "yaw": yaw, "speed": speed, "steer": steer, "distance": distance}


## 预测若干秒后的位置（用于自动驾驶前滚评分）
func predict(seconds: float, step_dt: float, input: Dictionary, grip := 1.0) -> Dictionary:
	var s := CarDrive.new()
	s.x = x
	s.z = z
	s.yaw = yaw
	s.speed = speed
	s.steer = steer
	var t := 0.0
	while t < seconds:
		s.step(input, step_dt, grip)
		t += step_dt
	return s.state()


## 车头检测点（数据坐标）
func nose() -> Vector2:
	return Vector2(x + sin(yaw) * NOSE_OFFSET, z + cos(yaw) * NOSE_OFFSET)


func reset_to(px: float, pz: float, pyaw: float, snapped_road_name := "") -> void:
	x = px
	z = pz
	yaw = pyaw
	speed = 0.0
	steer = 0.0
