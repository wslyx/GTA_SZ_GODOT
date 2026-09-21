extends RefCounted
class_name Observer
##
## 无人机观察模式 —— 对应原版 src/city-observer.ts（原版另有一份状态模块
## city-observer-beacon-state.ts 记录信标）。
##
## 行为（依 README 操作速查与键位表）：
##   - WASD / 方向键：相对当前朝向前后左右平移
##   - Q / E：下降 / 上升
##   - Shift：加速
##   - 拖动 / Shift+拖动：环绕与平移视点
##   - 记录最近一次安全位置，飞机坠毁或越界后在这里重建无人机
##
## 坐标：数据坐标 (east, y, north)。

const SPEED := 26.0
const BOOST := 2.6
const VERTICAL_SPEED := 16.0
const MIN_HEIGHT_ABOVE_GROUND := 1.2
const MAX_ALTITUDE := 900.0

var active := false
var x := 0.0
var y := 40.0
var z := 0.0
var yaw := 0.0
var pitch := -0.25
var last_safe := Vector3.ZERO

## 外部注入：func(x: float, z: float) -> float 地面高度（数据坐标）
var ground_height: Callable = Callable()
## 外部注入：func(x: float, z: float) -> bool 是否被建筑阻挡
var blocked: Callable = Callable()


func begin(px: float, py: float, pz: float, pyaw: float) -> void:
	x = px
	y = py
	z = pz
	yaw = pyaw
	pitch = -0.25
	active = true
	last_safe = Vector3(x, y, z)


func end() -> void:
	active = false


func look(dx: float, dy: float) -> void:
	yaw -= dx * 0.004
	pitch = clampf(pitch - dy * 0.003, -1.35, 0.6)


func pan(dx: float, dz: float) -> void:
	# Shift + 拖动 = 平移视点（沿相机右方与前方）
	var right := Vector3(cos(yaw), 0.0, sin(yaw))
	var fwd := Vector3(sin(yaw), 0.0, -cos(yaw))
	x += (right.x * dx + fwd.x * dz) * 0.35
	z += (right.z * dx + fwd.z * dz) * 0.35


## input: {move_forward, move_back, steer_left, steer_right, up(turret_right), down(turret_left), boost}
func step(input: Dictionary, dt_raw: float) -> void:
	if not active:
		return
	var dt := clampf(dt_raw, 0.0, 0.05)
	var boost := BOOST if input.get("boost", false) else 1.0

	var f := (1.0 if input.get("move_forward", false) else 0.0) - (1.0 if input.get("move_back", false) else 0.0)
	var s := (1.0 if input.get("steer_right", false) else 0.0) - (1.0 if input.get("steer_left", false) else 0.0)
	var v := (1.0 if input.get("up", false) else 0.0) - (1.0 if input.get("down", false) else 0.0)

	var len := sqrt(f * f + s * s)
	if len > 0.0:
		f /= len
		s /= len
	var dx := (sin(yaw) * f + cos(yaw) * s) * SPEED * boost * dt
	var dz := (cos(yaw) * f - sin(yaw) * s) * SPEED * boost * dt

	var nx := x + dx
	var nz := z + dz
	if blocked.is_valid() and blocked.call(nx, nz):
		if not blocked.call(nx, z):
			nz = z
		elif not blocked.call(x, nz):
			nx = x
		else:
			nx = x
			nz = z
	x = nx
	z = nz

	y += v * VERTICAL_SPEED * boost * dt
	var g: float = ground_height.call(x, z) if ground_height.is_valid() else 0.0
	y = clampf(y, g + MIN_HEIGHT_ABOVE_GROUND, g + MAX_ALTITUDE)
	last_safe = Vector3(x, y, z)


## 相机注视方向（数据坐标 → 世界方向）
func view_direction() -> Vector3:
	var cp := cos(pitch)
	return Vector3(sin(yaw) * cp, sin(pitch), -cos(yaw) * cp)


func status() -> Dictionary:
	return {"active": active, "x": x, "y": y, "z": z, "yaw": yaw, "pitch": pitch,
			"lastSafe": [last_safe.x, last_safe.y, last_safe.z]}
