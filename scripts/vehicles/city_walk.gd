extends RefCounted
class_name CityWalk
##
## 步行控制 —— 逐行移植原版 src/city-walk.ts。
##
## 要点：
##   - 走 1.6 m/s、跑 4.2 m/s；人物半径 .23m
##   - 上下车要检查"门旁有没有落脚点"：以车门为圆心做 8 方向 × .23m 的空地检查
##   - 移动时对完整位移、仅 X、仅 Z 三级降级尝试（贴墙滑行）
##   - 上坡/下坡落差 > .48m 视为不可通行；上下车时 > .55m 视为桥沿/悬空
##   - 相机距离 1.5–7，滚轮指数缩放

const WALK_SPEED := 1.6
const RUN_SPEED := 4.2
const WALK_RADIUS := 0.23
const STEP_MAX := 0.48
const EXIT_MAX_DROP := 0.55

var active := false
var x := 0.0
var z := 0.0
var yaw := 0.0
var pitch := 0.0
var distance := 0.0
var moving := false
var speed := 0.0
var camera_distance := 3.7

var _blocked: Callable
var _height_at: Callable


func _init(blocked_fn: Callable, height_fn: Callable) -> void:
	_blocked = blocked_fn
	_height_at = height_fn


func _h(px: float, pz: float) -> float:
	return _height_at.call(px, pz)


func _is_blocked(px: float, pz: float) -> bool:
	return _blocked.call(px, pz)


## 该点是否站得住：本身空 + 8 方向一圈也空
func clear(px: float, pz: float) -> bool:
	if not is_finite(_h(px, pz)) or _is_blocked(px, pz):
		return false
	for i in 8:
		var a := i * PI / 4.0
		if _is_blocked(px + cos(a) * WALK_RADIUS, pz + sin(a) * WALK_RADIUS):
			return false
	return true


## 回落到四扇车门（左右两侧各两处）。
## 返回 **Array[Vector2]**：调用方会写 `for p in _doors(...)` 再用 `p.x` 做算术，
## 如果返回无类型数组，`p` 就是 Variant，算术结果也是 Variant、`:=` 推断失败。
func _doors(car: Dictionary, offset: float) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var cx := float(car["x"])
	var cz := float(car["z"])
	var cy := float(car.get("yaw", 0.0))
	for side in [offset, -offset, offset + 0.9, -offset - 0.9]:
		out.append(Vector2(cx + cos(cy) * side, cz - sin(cy) * side))
	return out


## 原版 exitCar：必须停稳，且门旁有高度一致的落脚点
func exit_car(car: Dictionary, door_offset := 1.9) -> bool:
	if absf(float(car.get("speed", 0.0))) > 1.0:
		return false
	var floor_h := _h(float(car["x"]), float(car["z"]))
	for p in _doors(car, door_offset):
		if not clear(p.x, p.y):
			continue
		if absf(_h(p.x, p.y) - floor_h) > EXIT_MAX_DROP:
			continue
		x = p.x
		z = p.y
		yaw = float(car.get("yaw", 0.0))
		pitch = 0.06
		active = true
		moving = false
		speed = 0.0
		return true
	return false


## 原版 canEnter：靠近车门、且从当前位置到车门每一步都可走
func can_enter(car: Dictionary, radius := 5.0, door_offset := 1.9) -> bool:
	if absf(float(car.get("speed", 0.0))) > 1.0:
		return false
	var cx := float(car["x"])
	var cz := float(car["z"])
	if sqrt((x - cx) * (x - cx) + (z - cz) * (z - cz)) >= radius:
		return false
	if absf(_h(x, z) - _h(cx, cz)) > 0.8:
		return false
	for p in _doors(car, door_offset):
		var d := Vector2(p.x - x, p.y - z).length()
		if d > 2.7 or not clear(p.x, p.y):
			continue
		var steps := maxi(1, int(ceil(d / 0.15)))
		var prev_h := _h(x, z)
		var ok := true
		for i in range(1, steps + 1):
			var sx := x + (p.x - x) * float(i) / float(steps)
			var sz := z + (p.y - z) * float(i) / float(steps)
			var h := _h(sx, sz)
			if not clear(sx, sz) or absf(h - prev_h) > STEP_MAX:
				ok = false
				break
			prev_h = h
		if ok:
			return true
	return false


func zoom(delta: float) -> void:
	camera_distance = clampf(
		camera_distance * exp(clampf(delta, -400.0, 400.0) * 0.0014), 1.5, 7.0)


func look(dx: float, dy: float) -> void:
	yaw += dx * 0.004
	pitch = clampf(pitch + dy * 0.003, -1.0, 1.05)


## 原版 step()。input: {forward, back, left, right, run, left_arrow, right_arrow, up_arrow, down_arrow}
func step(input: Dictionary, dt_raw: float) -> void:
	if not active:
		return
	var dt := clampf(dt_raw, 0.0, 0.05)
	speed = 0.0

	yaw += ((1.0 if input.get("right_arrow", false) else 0.0)
		- (1.0 if input.get("left_arrow", false) else 0.0)) * dt * 1.6
	pitch = clampf(pitch + ((1.0 if input.get("down_arrow", false) else 0.0)
		- (1.0 if input.get("up_arrow", false) else 0.0)) * dt, -1.0, 1.05)

	var f := (1.0 if input.get("forward", false) else 0.0) - (1.0 if input.get("back", false) else 0.0)
	var s := (1.0 if input.get("right", false) else 0.0) - (1.0 if input.get("left", false) else 0.0)
	var length := sqrt(f * f + s * s)
	moving = length > 0.0
	if length == 0.0:
		return
	f /= length
	s /= length

	var spd := RUN_SPEED if input.get("run", false) else WALK_SPEED
	var dx := (sin(yaw) * f + cos(yaw) * s) * spd * dt
	var dz := (cos(yaw) * f - sin(yaw) * s) * spd * dt

	var base_h := _h(x, z)
	var ox := x
	var oz := z
	if clear(x + dx, z + dz) and absf(_h(x + dx, z + dz) - base_h) < STEP_MAX:
		x += dx
		z += dz
	elif clear(x + dx, z) and absf(_h(x + dx, z) - base_h) < STEP_MAX:
		x += dx
	elif clear(x, z + dz) and absf(_h(x, z + dz) - base_h) < STEP_MAX:
		z += dz

	var moved := sqrt((x - ox) * (x - ox) + (z - oz) * (z - oz))
	distance += moved
	speed = moved / dt if dt > 0.0 else 0.0
	moving = moved > 0.0


## 眼位（数据坐标）
func eye() -> Dictionary:
	var bob := sin(distance * 7.0) * 0.008 if moving else 0.0
	return {"x": x, "y": _h(x, z) + 1.53 + bob, "z": z}
