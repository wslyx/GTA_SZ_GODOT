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
## 场景最高点（米）—— 无人机 nearZ 自适应用。
## 实测数据：`city.json` 地标最高 359.46（平安金融中心），街区网格最高 124.2。
## 取地标值向上取整，宁可高估一点：高估 → clearance 偏小 → near 偏小 → 近处更精细，
## 是安全方向；低估才会把深度精度浪费在远处。
const SCENERY_TOP := 360.0

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

## follow_vehicle 的位移携带状态（原版 oldCarX/oldCarZ 逻辑）。
## false = 尚未跟随过，下一帧直接落位到 desired。
var _has_focus := false
var _last_focus := Vector3.ZERO


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
## look_yaw 为**车头**朝向（数据 yaw）：原版相机位置用滞后的 cameraYaw、
## 注视点却始终锁定车头 yaw 前方 5m —— 转弯时相机甩在车后、视线盯着车头，
## 这是原版追尾视角手感的关键。不传（NAN）时退化为用车头 = 相机 yaw。
func follow_vehicle(target_data: Vector3, speed: float, dt: float, tank := false,
		look_yaw := NAN) -> void:
	var views := TANK_VIEWS if tank else DRIVE_VIEWS
	var v: Dictionary = views[mini(view, views.size() - 1)]
	var f := float(v["f"]) * distance_scale
	var h := float(v["h"])
	# 原版只有驾驶视角 0 的高度受 cameraPitch 影响：1.75 + pitch*2
	if not tank and view == 0:
		h += look_pitch * 2.0

	var ground: float = ground_height_fn.call(target_data.x, target_data.z) if ground_height_fn.is_valid() else 0.0
	var focus := CoordinateUtil.to_world(target_data.x, target_data.z, ground)
	# 相机位置跟随滞后 yaw（原版 desired 用 cameraYaw）
	var cam_dir := CoordinateUtil.yaw_to_direction(yaw)
	var desired := focus + cam_dir * f + Vector3(0.0, h, 0.0)
	# 注视点跟随**车头** yaw（原版 target 用 s.yaw）：车头前方 5m
	var look_dir := CoordinateUtil.yaw_to_direction(yaw if is_nan(look_yaw) else look_yaw)
	var look_height := 2.65 if view == 0 else 1.15
	var look_at := focus + look_dir * 5.0 + Vector3(0.0, look_height, 0.0)

	# 原版：camera.position += 车辆本帧位移（x/z，随车平移不滞后），
	# 再向 desired 指数平滑（view1 用 20，其余 9）。
	# 传送（快速移动/信标落点/换载具）时位移会远超任何帧间移动，直接落位。
	var factor := 1.0 - exp(-dt * (20.0 if view == 1 else 9.0))
	if not _has_focus:
		_has_focus = true
		_last_focus = focus
		global_position = desired
	else:
		var carry := focus - _last_focus
		carry.y = 0.0
		_last_focus = focus
		if carry.length() > 25.0:
			global_position = desired
		else:
			global_position += carry
			global_position = global_position.lerp(desired, factor)
	# ---- 相机贴地钳制（2026-11-03，修复记录 五十二）----
	# 症状：山上行车（尤其朝下坡开 / 停在坡上），画面被绿色糊满、近坡着色
	# 反常，观感"山是透明的，能看到对面山体的内侧面"。
	# 归因：相机 = 车轮处地面高度 + 固定挂高，水平后退 f 米 —— 朝下坡开时
	# 车后是上坡方向，地形比车轮处高数米，相机整个钻进山体网格。ground_field
	# 是双面渲染（背面法线翻转），从网格内部看到的就是"对面内侧面 + 交切线"。
	# diag 实测：车 (1750,1690) hf=24.77，相机 y=27.02 而相机所在 XZ 的地面
	# 高达 30.00 —— 深入地下 3m。
	# 修法：用相机自身 XZ 的高度场做地板，绝不低于地面 0.6m。只抬不降，
	# 不影响原版追尾手感。
	if ground_height_fn.is_valid():
		var cam_min_y: float = float(ground_height_fn.call(
			global_position.x, -global_position.z)) + 0.6
		if global_position.y < cam_min_y:
			global_position.y = cam_min_y
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
	# 近裁剪面随**离场景最高点的净空**放宽（原版 city-observer-depth.ts）：
	#   净空越大说明相机越在"空旷的高处"，此时把深度精度让给远处；
	#   贴着楼飞时净空≈0，退回 0.3 保住近处细节。
	near = observer_near_clip(global_position.y)


## 原版 observerNearClip(distance, cameraHeight, sceneryTop) 的等价式。
## 我们的无人机是自由视角（不是绕焦点环绕），注视点固定在正前 50m，
## 所以 orbitNear = clamp(50*0.003, .3, 4) 恒为 0.3 —— 与游戏内实际观感一致。
func observer_near_clip(camera_height: float) -> float:
	var orbit_near := clampf(50.0 * 0.003, 0.3, 4.0)
	var clearance := maxf(0.0, camera_height - SCENERY_TOP)
	return maxf(orbit_near, minf(128.0, clearance * 0.1))


## 飞机：相机位于机体后上方
##
## ⚠️ 方向别搞反：飞机模型的机头在 −Z，main_game 建基时取的 z 轴是 `-fwd`，
## 所以 **basis.z 指向机尾**，机头方向是 `-basis.z`。
## 之前写成 `- basis.z * 16`（机头前方 16 m）并且 `look_at(origin + basis.z * 30)`
## （看机尾后方 30 m），结果是相机悬在机鼻前面、迎面拍自己，与注释完全相反。
func follow_aircraft(dt: float) -> void:
	var b := aircraft_basis
	# 机尾（+basis.z）后上方
	var back := b.origin + b.basis.z * 16.0 + Vector3(0.0, 4.6, 0.0)
	global_position = global_position.lerp(back, 1.0 - exp(-dt * 6.0))
	# 注视机头前方（−basis.z）
	look_at_target(b.origin - b.basis.z * 30.0)
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
