extends Camera3D
class_name ChaseCamera
##
## 多模式相机 —— 移植原版 city-world.ts 里的相机分支与 camera 参数。
##
## 原版是单个 FreeCamera，按模式改 fov / near / 跟随距离：
##   驾驶      fov = 0.80 + |speed| * 0.00045, nearZ .75
##             view0: forward -8.6, height 1.75 + pitch*2
##             view1: forward  0.75, height 1.35
##             view2: forward -18,   height 9
##             目标点 = (x + sin(yaw)*5, ground + 2.65 / 1.15, z + cos(yaw)*5)
##             位置指数平滑系数 1 - exp(-dt*9)，驾驶舱 20
##   驾驶舱    position [0,1.12,.05]，lookAhead [0,1.08,18]，nearZ .04，fov .90
##   无人机    fov .85，nearZ 自适应
##   飞机      fov .88，nearZ .5
##   步行      fov .88，nearZ .12
##   坦克      forward -13/-5/-22，height 5.2/4/11
##
## 注意：这里统一把"forward"解释为朝车头方向的偏移，"height"为相机高度。

enum Mode { DRIVING, COCKPIT, OBSERVER, AIRCRAFT, WALKING, TANK }

const NEAR_DRIVING := 0.75
const NEAR_COCKPIT := 0.04
const NEAR_AIRCRAFT := 0.5
const NEAR_WALKING := 0.12
const FOV_BASE := 0.80
const FOV_SPEED_GAIN := 0.00045
const FOV_OBSERVER := 0.85
const FOV_AIRCRAFT := 0.88
const FOV_WALKING := 0.88
const FOV_COCKPIT := 0.90

## 三种驾驶视角的 (forward, height)
const DRIVE_VIEWS := [
	{"f": -8.6, "h": 1.75},
	{"f": 0.75, "h": 1.35},
	{"f": -18.0, "h": 9.0},
]
const TANK_VIEWS := [
	{"f": -13.0, "h": 5.2},
	{"f": -5.0, "h": 4.0},
	{"f": -22.0, "h": 11.0},
]
## 驾驶舱固定位姿（原版 CITY_DRIVER_POSE）
const COCKPIT_POSITION := Vector3(0.0, 1.12, 0.05)
const COCKPIT_LOOK_AHEAD := Vector3(0.0, 1.08, 18.0)

const MAX_DISTANCE := 18000.0

var mode: int = Mode.DRIVING
var view := 0
var distance_scale := 1.0

var ground_height_fn: Callable = Callable()   ## func(x: float, z: float) -> float（数据坐标）
var look_pitch := 0.0                          ## 相机俯仰（-1..1）
var yaw := 0.0                                 ## 跟随时用的朝向（数据 yaw）
var observer_position := Vector3.ZERO          ## 无人机世界位置（Godot 坐标）
var observer_yaw := 0.0
var observer_pitch := 0.0
var aircraft_basis := Transform3D.IDENTITY
var walk_eye := Vector3.ZERO


func _ready() -> void:
	fov = 70.0
	near = NEAR_DRIVING
	far = MAX_DISTANCE


func set_mode(m: int, reset_view := false) -> void:
	mode = m
	if reset_view:
		view = 0
	match m:
		Mode.DRIVING:
			near = NEAR_DRIVING
		Mode.COCKPIT:
			near = NEAR_COCKPIT
		Mode.OBSERVER:
			near = 0.3
		Mode.AIRCRAFT:
			near = NEAR_AIRCRAFT
		Mode.WALKING:
			near = NEAR_WALKING
		Mode.TANK:
			near = NEAR_DRIVING


func next_view() -> int:
	view = (view + 1) % DRIVE_VIEWS.size()
	return view


## 驾驶/坦克跟随。target_data 为数据坐标 (east, north) + 地面高度。
func follow_vehicle(target_data: Vector3, speed: float, dt: float, tank := false) -> void:
	var views := TANK_VIEWS if tank else DRIVE_VIEWS
	var v: Dictionary = views[mini(view, views.size() - 1)]
	var f := float(v["f"]) * distance_scale
	var h := float(v["h"])

	var ground: float = ground_height_fn.call(target_data.x, target_data.z) if ground_height_fn.is_valid() else 0.0
	# 数据 yaw → 世界方向；相机位于车后（-forward）
	var dir := CoordinateUtil.yaw_to_direction(yaw)
	var focus := CoordinateUtil.to_world(target_data.x, target_data.z, ground)
	# f 已经是"沿车头方向的偏移"（view0 = -8.6 即车后 8.6m），直接相乘即可。
	# 之前写成 dir * -f，把负号抵消掉了，相机会跑到车头**前方**。
	var desired := focus + dir * f + Vector3(0.0, h + look_pitch * 2.0, 0.0)
	# 目标点：车头前方 5m，高度按视角
	var look_height := 2.65 if view == 0 else 1.15
	var look_at := focus + dir * 5.0 + Vector3(0.0, look_height, 0.0)

	var factor := 1.0 - exp(-dt * 9.0)
	if mode == Mode.COCKPIT:
		factor = 1.0 - exp(-dt * 20.0)
	global_position = global_position.lerp(desired, factor)
	look_at_target(look_at)
	fov = rad_to_deg(FOV_BASE + absf(speed) * FOV_SPEED_GAIN)


## 驾驶舱视角
func follow_cockpit(target_data: Vector3) -> void:
	var ground: float = ground_height_fn.call(target_data.x, target_data.z) if ground_height_fn.is_valid() else 0.0
	var origin := CoordinateUtil.to_world(target_data.x, target_data.z, ground)
	var b := Basis(Vector3.UP, CoordinateUtil.node_yaw(yaw))
	var local := COCKPIT_POSITION
	var look_local := COCKPIT_LOOK_AHEAD
	global_transform = Transform3D(b, origin + b * local)
	var look_point := origin + b * look_local
	look_at_target(look_point)
	fov = rad_to_deg(FOV_COCKPIT)


## 无人机（观察模式）
func follow_observer(dt: float) -> void:
	var factor := 1.0 - exp(-dt * 12.0)
	global_position = global_position.lerp(observer_position, factor)
	var dir := Vector3(sin(observer_yaw) * cos(observer_pitch),
		sin(observer_pitch),
		-cos(observer_yaw) * cos(observer_pitch))
	look_at_target(observer_position + dir * 50.0)
	fov = rad_to_deg(FOV_OBSERVER)


## 飞机：相机位于机体后上方
func follow_aircraft(dt: float) -> void:
	var b := aircraft_basis
	var back := b.origin - b.basis.z * 16.0 + Vector3(0.0, 4.6, 0.0)
	global_position = global_position.lerp(back, 1.0 - exp(-dt * 6.0))
	look_at_target(b.origin + b.basis.z * 30.0)
	fov = rad_to_deg(FOV_AIRCRAFT)


## 步行：第三人称环绕。walk_yaw 为数据 yaw，pitch 为俯仰
func follow_walk(dt: float, camera_distance: float, first_person: bool) -> void:
	if first_person:
		global_position = walk_eye
		var dir := Vector3(sin(yaw) * cos(look_pitch), sin(look_pitch),
			-cos(yaw) * cos(look_pitch))
		look_at_target(walk_eye + dir * 20.0)
		fov = rad_to_deg(FOV_WALKING)
		return
	var dir := Vector3(sin(yaw) * cos(look_pitch), sin(look_pitch),
		-cos(yaw) * cos(look_pitch))
	var desired := walk_eye - dir * camera_distance + Vector3(0.0, 0.35, 0.0)
	global_position = global_position.lerp(desired, 1.0 - exp(-dt * 10.0))
	look_at_target(walk_eye + dir * 6.0)
	fov = rad_to_deg(FOV_WALKING)


## 空中掠过（俯瞰）：等效于拉高视距
func set_aerial_scale(aerial: bool) -> void:
	distance_scale = 1.0 if not aerial else 3.2


func look_at_target(p: Vector3) -> void:
	if global_position.distance_to(p) < 0.001:
		return
	look_at(p, Vector3.UP)
