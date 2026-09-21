extends RefCounted
class_name TankSim
##
## 坦克运动学与炮弹弹道 —— 逐行移植原版 city-tank-simulation.ts。
##
## 注意：坦克**不是**用 stepCar 驾驶，而是独立的加速度模型（target speed + rate 限幅），
## 转向是原地/低速普遍可用的 yaw 积分，不依赖车速。开火另有装填冷却与抛物线弹道。

const FORWARD := 14.0
const REVERSE := 5.0
const ACCELERATION := 3.3
const TURN_RATE := 0.60
const HALF_WIDTH := 1.72
const HALF_LENGTH := 3.4
const RELOAD := 1.8
const SHELL_SPEED := 145.0
const GRAVITY := 9.81
const SHELL_LIFETIME := 6.0
## 炮塔/炮管限制（原版 city-tank.ts aim()）
const TURRET_RATE := 0.65
const BARREL_RATE := 0.22
const BARREL_MIN := -0.06
const BARREL_MAX := 0.38

var x := 0.0
var z := 0.0
var yaw := 0.0
var speed := 0.0
var steer := 0.0
var distance := 0.0

var turret_yaw := 0.0
var barrel_pitch := 0.06
var cooldown := 0.0
var shots := 0
var hits := 0


## 原版 stepTank
## integrate_position = false 时只推进速度/转角/朝向，位置由调用方用固定子步推进
## （避免与主控制器的子步碰撞积分重复累加）。
func step(input: Dictionary, dt_raw: float, integrate_position := true) -> void:
	var dt := clampf(dt_raw, 0.0, 0.05)
	var throttle := clampf(float(input.get("throttle", 0.0)), -1.0, 1.0)
	var handbrake := bool(input.get("handbrake", false))
	var v := speed
	var target := throttle * (REVERSE if throttle < 0.0 else FORWARD)
	var rate := ACCELERATION
	if handbrake:
		rate = 14.0
	elif throttle * v < 0.0:
		rate = 8.0
	var desired_speed := 0.0 if handbrake else target
	speed += clampf(desired_speed - v, -rate * dt, rate * dt)
	steer += (clampf(float(input.get("steer", 0.0)), -1.0, 1.0) * 0.6 - steer) * (1.0 - exp(-dt * 7.0))
	yaw += steer / 0.6 * TURN_RATE * dt
	if integrate_position:
		var moved := speed * dt
		x += sin(yaw) * moved
		z += cos(yaw) * moved
		distance += absf(moved)


## 车体占位检测用的采样偏移。
##
## 同样的两条限制：`const X := PackedFloat32Array([...])` 非法（Packed*Array 构造
## 不是常量表达式），而普通数组字面量遍历出的循环变量是 Variant、会让
## `px + cos(pyaw) * side + ...` 推断失败。
## 解法：const 放普通数组，函数体内转成 PackedFloat32Array 再遍历。
const SIDE_OFFSETS := [-HALF_WIDTH, 0.0, HALF_WIDTH]
const ALONG_OFFSETS := [-HALF_LENGTH, 0.0, HALF_LENGTH]


## 原版 tankFootprintClear：9 个采样点全部通畅才算坦克放得下
func footprint_clear(px: float, pz: float, pyaw: float, blocked: Callable) -> bool:
	var sides := PackedFloat32Array(SIDE_OFFSETS)
	var alongs := PackedFloat32Array(ALONG_OFFSETS)
	for side in sides:
		for along in alongs:
			var sx := px + cos(pyaw) * side + sin(pyaw) * along
			var sz := pz - sin(pyaw) * side + cos(pyaw) * along
			if blocked.call(sx, sz):
				return false
	return true


## 原版 aim()
func aim(input: Dictionary, dt: float) -> void:
	turret_yaw += (float(input.get("turret", 0.0))) * dt * TURRET_RATE
	barrel_pitch = clampf(barrel_pitch + float(input.get("barrel", 0.0)) * dt * BARREL_RATE,
		BARREL_MIN, BARREL_MAX)


func can_fire() -> bool:
	return cooldown <= 0.0


## 返回炮弹初值 {origin:Dictionary, velocity:Dictionary}；未开火返回空
func fire() -> Dictionary:
	if cooldown > 0.0:
		return {}
	var a := yaw + turret_yaw
	var cp := cos(barrel_pitch)
	var dir := Vector3(sin(a) * cp, sin(barrel_pitch), cos(a) * cp)
	var origin := Vector3(x, 0.0, z) + dir * 5.0
	origin.y = 2.1
	cooldown = RELOAD
	shots += 1
	return {
		"origin": {"x": origin.x, "y": origin.y, "z": origin.z},
		"velocity": {"x": dir.x * SHELL_SPEED, "y": dir.y * SHELL_SPEED, "z": dir.z * SHELL_SPEED},
	}


func tick_cooldown(dt: float) -> void:
	cooldown = maxf(0.0, cooldown - maxf(0.0, minf(0.05, dt)))


## 原版 advanceTankShell：位置用二阶项、速度用一阶项
static func advance_shell(pos: Dictionary, vel: Dictionary, dt_raw: float) -> Dictionary:
	var h := clampf(dt_raw, 0.0, 0.05)
	var next := {
		"x": float(pos["x"]) + float(vel["x"]) * h,
		"y": float(pos["y"]) + float(vel["y"]) * h - 0.5 * GRAVITY * h * h,
		"z": float(pos["z"]) + float(vel["z"]) * h,
	}
	vel["y"] = float(vel["y"]) - GRAVITY * h
	return next


func stats() -> Dictionary:
	return {"shots": shots, "hits": hits, "cooldown": cooldown, "speed": speed,
			"turretYaw": turret_yaw, "barrelPitch": barrel_pitch}
