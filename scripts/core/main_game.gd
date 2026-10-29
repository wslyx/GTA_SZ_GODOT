extends Node3D
class_name MainGame
##
## 主控制器 —— 对应原版 src/main.ts 的驱动器 + city-world.ts 的模式状态机部分。
##
## 模式优先级（原版 controlMode）：aircraft > observer > walking > tank > car
##
## 模式切换的前置条件（原版 city-world.ts:299 起）：
##   T  car ↔ tank   需要坦克占位空间（9 点检测）；不满足时先吸附最近道路，仍不满足则拒绝
##   F  car → walking 需要 |speed| ≤ 1 且车门旁 1.9m 内有高度一致的落脚点
##   F  walking → car 需要 canEnter（5m 内 + 到车门沿途可走）
##   G  → observer    进入拍照/观景（paused = true，keys.clear）
##   B  observer → aircraft 需要 photoTarget 不是车、且起飞空间足够
##   Esc 退出观景 → 关手账 → 退拍照 → 关地图 → 暂停
##
## 碰撞（原版 update 的子步）：steps = ceil(|speed| * dt / 0.7)，车头 1.45m，
## 命中则回滚位置，速度取 0 或 -speed * 0.15。

enum Mode { CAR, TANK, WALKING, OBSERVER, AIRCRAFT }

const COLLISION_STEP := 0.7
const NOSE := 1.45
const TANK_NOSE := 3.4
const WALK_EXIT_OFFSET := 1.9
const TANK_EXIT_OFFSET := 3.0

var world: CityWorld
var camera: ChaseCamera
var hud: GameHUD
var maps: MapUI
var panels: PanelsUI

var car := CarDrive.new()
var tank := TankSim.new()
var flight := FlightSim.new()
var walk: CityWalk
var observer := Observer.new()
var autopilot := Autopilot.new()
var lights: VehicleLights
var rides: Rides
var career: CareerSystem
var story: StorySystem
var audio: ProceduralAudio

var mode: int = Mode.CAR
## 上次乘坐的地面载具（Mode.CAR / Mode.TANK）：下车时记录，上车时据此回到那一台。
##
## ⚠️ 不能改用 `_tank_model.visible` 来判断该回哪种车 —— 下车那一刻已经把
## 坦克模型设为不可见，visible 恒为 false，于是从坦克上下来后按 F 永远只回轿车，
## 还会把轿车瞬移到脚下，坦克就此丢失（_toggle_tank 在 WALKING 下直接 return，
## 也切不回去）。
var _last_ground_vehicle: int = Mode.CAR
## 进入观景前的模式，退出观景时据此还原。
## 之前 _exit_observer 固定回到"车"，于是步行中按 G 再退出会被凭空塞进车里。
var _pre_observer_mode: int = Mode.CAR
## 会话就绪标志。不能叫 `ready` —— `Node` 已有同名 `ready` 信号，会报
## "Member 「ready」 redefined (original in native class 'Node3D')"。
var session_ready := false
var paused := false
var _keys := {}
var _camera_yaw := 0.0
var _look_pitch := 0.25
var _dragging := false
## 捕获模式下观察模式长按手势的"虚拟光标"：屏幕中心 + 捕获期间累计的
## motion.relative（捕获时真实 position 失真，见 _update_mouse_capture 注释）。
var _beacon_cursor := Vector2.ZERO
var _walk_first_person := false
var _car_model: Node3D
var _tank_model: Node3D
## 坦克实体炮塔 / 炮管节点（原版 city-tank.ts 的 turretTransform）。
## tank.glb 的层级是 tank_root → tank_turret(→ tank_barrel → 炮身各件)。
## 名称来自 GLB 的 node 表，导入后 Godot 保留原名。
var _tank_turret: Node3D
var _tank_barrel: Node3D
## 炮口锚点（tank.glb 自带 tank_muzzle）：开炮原点用它的世界位置
var _tank_muzzle: Node3D
## 炮管的原始局部位置（GLB 实测 [0, 0.296, 1.884]），后坐回抽以此为基准
var _tank_barrel_home := Vector3.ZERO
## 飞行导弹（原版 city-flight-missiles.ts）。首次起飞时才实例化，
## 6 个弹位 + 2 组爆炸的节点成本不进启动路径。
var _missiles = null
var _plane_model: Node3D
## 螺旋桨节点（floatplane.glb 里的 floatplane_propeller，桨叶网格 floatplane_propeller_mesh
## 是它的子节点）。原版 city-flight.ts:48 旋转的就是这个父节点。
var _plane_propeller: Node3D
## 螺旋桨累计转角（rad）。原版是每帧 rotation.z += 增量，这里累计后整体赋值，
## 免得 glTF 导入器给节点带任何基础旋转时增量写法叠错轴。
var _propeller_angle := 0.0
## 车轮滚动/转向动画（原版 city-world.ts 的 wheelSpin 逻辑）。
## ⚠️ 同 RIDER_SCRIPT：新增脚本的 class_name 要等编辑器重扫全局类缓存，
## 直接用 `CarWheels` 会报 "Could not find type CarWheels"，必须 preload。
const CAR_WHEELS_SCRIPT := preload("res://scripts/vehicles/car_wheels.gd")
var _car_wheels = null               ## CAR_WHEELS_SCRIPT 实例（untyped：全局类名未注册）
var _wheel_spin := 0.0
## 世界时钟（原版 world.time，永不停表：悬挂起伏用它驱动）
var _game_time := 0.0
## 步行时的角色本体（原版 city-rider.ts）。
## ⚠️ 用 preload 而不是全局类名 Rider：新增脚本的 class_name 要等编辑器
## 重扫一次才会进全局类缓存，运行时直接跑会报 "Could not find type Rider"。
const RIDER_SCRIPT := preload("res://scripts/vehicles/rider.gd")  ## 仅取 CHARACTER_NAME 做提示文案
## ALS 步行角色（Godot-Locomotion 迁移的 C# 运行时，见 GtaSzAlsPlayerHost.cs）。
## ⚠️ C# 脚本用 load() 而非 preload：.NET 程序集未编译时 preload 会让整个
## main_game.gd 加载失败；load() 返回 null 则启动阶段直接报错退出（无回退）。
const ALS_HOST_SCRIPT_PATH := "res://src/Als.Godot/Locomotion/GtaSzAlsPlayerHost.cs"
const ALS_GROUND_SCRIPT := preload("res://scripts/world/als_physics_ground.gd")
var _als_host = null               ## GtaSzAlsPlayerHost（C#，untyped：可能未编译）
var _als_orbit = null              ## OrbitCamera 节点（C#，缓存引用给 _update_mouse_capture）
var _als_ground = null             ## AlsPhysicsGround（角色周围的动态物理代理）
var _als_walk_active := false      ## 本轮步行是否由 ALS 角色驱动
var _walk_error_shown := false     ## 步行缺 ALS 驱动的报错只弹一次（_step_walk 每帧跑）
var _pending_level_up_dialogue := {}


## 多人战局：把当前出行模式翻译成协议模式串（经 NetSession 上报，
## 远程玩家昵称牌据此显示"（车）/（坦克）/（飞机）"徽标）
func _net_mode_string() -> String:
	match mode:
		Mode.WALKING:
			return "walk"
		Mode.CAR:
			return "car"
		Mode.TANK:
			return "tank"
		Mode.AIRCRAFT:
			return "plane"
		_:
			return "observer"


func _ready() -> void:	# ⚠️ 加载界面必须先于任何重活出现。
	# PanelsUI._ready() 会在 add_child 的瞬间建好加载画面，但那一帧还没画到屏幕上；
	# 如果紧接着就在同一帧里跑 CityData.load_core() / collision.build() 这类
	# 秒级的同步活，玩家看到的仍然是白屏。所以这里先让出一到两帧，等加载画面
	# 真正渲染出来再开工。
	panels = PanelsUI.new()
	panels.name = "PanelsUI"
	add_child(panels)
	panels.show_loading()
	panels.set_loading_text("深城纪 · 正在展开深圳")
	panels.set_loading_progress(0.0)
	await get_tree().process_frame
	await get_tree().process_frame
	_build_world()

func _build_world() -> void:
	# 先建世界（walk 的两个回调会在运行时读 world，但 GDScript 的 lambda 是
	# 创建时按值捕获，所以必须等 world 有效之后再建 walk）
	world = CityWorld.new()
	world.name = "CityWorld"
	add_child(world)

	walk = CityWalk.new(
		func(x: float, z: float) -> bool: return world.collision.blocked(x, z),
		func(x: float, z: float) -> float: return world.height_field.height_at(x, z))

	# ALS 步行角色：物理地面代理（角色周围的动态 StaticBody）+ C# 角色宿主。
	# 宿主 _Ready 里预热动画资源 —— 此刻还在加载画面后面，玩家无感。
	# ⚠️ 不再静默回退旧步行角色：程序集缺失时直接报错退出。静默回退曾让
	# "换电脑后按 F 下车不是 mannequin"极难排查（load(.cs) 返回 null，
	# 玩家只看到旧角色，控制台没有任何线索）。
	var host_script = load(ALS_HOST_SCRIPT_PATH)
	if host_script == null:
		push_error("[MainGame] ALS C# 程序集加载失败，步行角色不可用。" +
			"修复：装 .NET SDK 8、用 Godot .NET 版打开项目并构建 GodotALS.csproj" +
			"（编辑器菜单 Project → Tools → C# → Build，或命令行 dotnet build）。")
		get_tree().quit(1)
		return
	_als_ground = ALS_GROUND_SCRIPT.new()
	_als_ground.name = "AlsPhysicsGround"
	add_child(_als_ground)
	_als_ground.setup(world)
	_als_host = host_script.new()
	_als_host.name = "AlsPlayerHost"
	add_child(_als_host)
	_als_orbit = _als_host.get_node_or_null("OrbitCamera")
	# 多人战局：把 ALS 角色宿主绑定为本地玩家，NetSession 据此上报位置（未连接时零开销）
	NetSession.bind_local_player(_als_host)
	NetSession.bind_mode_provider(_net_mode_string)
	# 预热：首次 EnterWorld 才构造角色（动画图等，耗时数秒）—— 在加载画面内
	# 完成，避免首次 F 下车时游戏长时间卡死。构造后立刻停用隐藏，
	# 之后每次下车取现成角色（EnterWorld 检测到已配置会跳过构造）。
	var prewarm_feet := CoordinateUtil.to_world(0.0, 0.0, 0.0)
	_als_ground.update_around(prewarm_feet)   # 地面代理（含首批建筑体）随加载预铺
	_als_host.EnterWorld(prewarm_feet, 0.0)
	_als_host.ExitWorld()

	# 子系统（用 preload 而非 set_script，确保脚本一定被解析）
	world.sky = _add_system(SKY_SCRIPT, "SkySystem")
	world.lighting = _add_system(LIGHTING_SCRIPT, "LightingDirector")
	world.water = _add_system(WATER_SCRIPT, "BayWater")
	world.weather = _add_system(WEATHER_SCRIPT, "WeatherSystem")
	world.scenery = _add_system(SCENERY_SCRIPT, "ScenerySystem")
	world.signs = _add_system(SIGN_SCRIPT, "SignSystem")
	world.distant = _add_system(DISTANT_SCRIPT, "DistantSystem")
	world.distant_city = _add_system(DISTANT_CITY_SCRIPT, "DistantCity")
	world.signals = _add_system(SIGNALS_SCRIPT, "TrafficSignals")
	world.traffic = _add_system(TRAFFIC_SCRIPT, "TrafficSystem")
	world.pedestrians = _add_system(PED_SCRIPT, "PedestrianSystem")
	world.ebikes = _add_system(EBIKE_SCRIPT, "EbikeSystem")
	world.facades = _add_system(FACADE_SCRIPT, "FacadeStreamer")

	# 相机与灯光架
	camera = ChaseCamera.new()
	camera.name = "MainCamera"
	camera.ground_height_fn = func(x: float, z: float) -> float: return world.height_field.height_at(x, z)
	add_child(camera)
	camera.current = true

	lights = VehicleLights.new()
	lights.name = "VehicleLightRig"
	add_child(lights)
	lights.build()

	# 玩法系统
	career = CareerSystem.new()
	rides = Rides.new()
	story = StorySystem.new()

	audio = ProceduralAudio.new()
	audio.name = "ProceduralAudio"
	add_child(audio)
	# BGM 离线预渲染（~1.5s）：此时还在加载画面后面，玩家无感。
	# 不预渲染的话，BGM 要在运行时逐样本合成 —— 实测是自动驾驶掉帧的元凶。
	audio.prepare_bgm()

	# UI
	hud = GameHUD.new()
	hud.name = "HUD"
	add_child(hud)
	maps = MapUI.new()
	maps.name = "MapUI"
	add_child(maps)

	# 车辆模型
	_load_vehicle_models()

	# 构建城市（各子系统的 setup 由 CityWorld 的步骤按原版顺序调用）
	world.progress.connect(_on_progress)
	world.built.connect(_on_built)
	world.failed.connect(_on_failed)
	world.build()

const SKY_SCRIPT := preload("res://scripts/world/sky_system.gd")
const LIGHTING_SCRIPT := preload("res://scripts/world/lighting_director.gd")
const WATER_SCRIPT := preload("res://scripts/world/bay_water.gd")
const WEATHER_SCRIPT := preload("res://scripts/world/weather_system.gd")
const SCENERY_SCRIPT := preload("res://scripts/world/scenery_system.gd")
const SIGN_SCRIPT := preload("res://scripts/world/sign_system.gd")
const DISTANT_SCRIPT := preload("res://scripts/world/distant_system.gd")
## 远景城市壳（原版 city-distant-city.ts + city-distant-geometry.ts 的远景层级）
const DISTANT_CITY_SCRIPT := preload("res://scripts/world/distant_city.gd")
const SIGNALS_SCRIPT := preload("res://scripts/world/traffic_signals.gd")
const TRAFFIC_SCRIPT := preload("res://scripts/world/traffic_system.gd")
const PED_SCRIPT := preload("res://scripts/world/pedestrian_system.gd")
const EBIKE_SCRIPT := preload("res://scripts/world/ebike_system.gd")
const FACADE_SCRIPT := preload("res://scripts/world/facade_streamer.gd")
## ⚠️ 同 RIDER_SCRIPT：新增脚本的 class_name 要等编辑器重扫全局类缓存，
## 直接写 `FlightMissiles.new()` 会报 "Could not find type"，必须 preload。
const MISSILES_SCRIPT := preload("res://scripts/vehicles/flight_missiles.gd")
## 飞行碰撞（原版 city-flight-collision.ts）：建筑三维棱柱 + 地形采样。
## ⚠️ 飞行不能用驾驶的 CityCollision.blocked(x,z) —— 那是纯二维足迹判定，
## 没有高度概念：飞多高都撞建筑投影，且 blocked() 对水面/非陆地返回 true，
## 海湾上空全是"墙"。见 world/flight_collision.gd 头部说明。
const FLIGHT_COLLISION_SCRIPT := preload("res://scripts/world/flight_collision.gd")
## 坦克炮弹（原版 city-tank.ts 的 tracer 池 + 命中爆炸）
const TANK_SHELLS_SCRIPT := preload("res://scripts/vehicles/tank_shells.gd")

func _add_system(script: GDScript, node_name: String) -> Node3D:
	var n: Node3D = script.new()
	n.name = node_name
	add_child(n)
	return n

func _load_vehicle_models() -> void:
	_car_model = _load_glb("res://data/city/car.glb", "PlayerCar")
	_tank_model = _load_glb("res://data/city/tank/tank.glb", "PlayerTank")
	_plane_model = _load_glb("res://data/city/floatplane.glb", "PlayerPlane")
	if _tank_model != null:
		_tank_model.visible = false
		_tank_turret = _find_child_by_name(_tank_model, "tank_turret")
		_tank_barrel = _find_child_by_name(_tank_model, "tank_barrel")
		_tank_muzzle = _find_child_by_name(_tank_model, "tank_muzzle")
		if _tank_barrel != null:
			_tank_barrel_home = _tank_barrel.position
		if _tank_turret == null or _tank_barrel == null:
			push_warning("[MainGame] tank.glb 缺少炮塔/炮管节点，炮塔姿态不联动")
	if _plane_model != null:
		_plane_model.visible = false
		# 螺旋桨是独立节点（translation [0,0,-4.09]，无基础旋转），
		# 飞行中按油门转速旋转 —— 见 _step_aircraft 末尾。
		_plane_propeller = _find_child_by_name(_plane_model, "floatplane_propeller")
		if _plane_propeller == null:
			push_warning("[MainGame] floatplane.glb 缺少 floatplane_propeller 节点，螺旋桨不转")
	# 步行角色：只有 ALS mannequin（C# 运行时，_build_world 里强校验程序集）。
	# 旧版 city-rider 的程序化步行角色（久岐忍）已随回退逻辑一起移除。
	# 主角车辆的车漆 / 玻璃 / 轮毂材质标定（原版 refineHeroVehicleMaterials）。
	# 必须在实例化之后做：GLB 材质是共享资源，改的正是那些共享实例。
	if _car_model != null:
		_vehicle_materials = VehicleMaterials.new()
		_vehicle_materials.apply(_car_model)
		# 运动套件（尾翼 / 后扩散器 / 四出排气）—— 原版 createCitySportDetails。
		# ⚠️ 这些零件**不在 car.glb 里**，是运行时程序化生成后挂到车根上的，
		# 所以必须在材质标定之后、且挂在 _car_model 之下（随车移动）。
		_sport_details = SportDetails.new()
		_sport_details.apply(_car_model)
		# 车轮滚动/转向动画：收集 wheel_* / brake_* 网格并读 vehicle-manifest.json
		# 的 wheelRadius / wheelCentresGltf（原版 init 里 setPivotPoint 那段）。
		_car_wheels = CAR_WHEELS_SCRIPT.new()
		_car_wheels.setup(_car_model)

var _vehicle_materials: VehicleMaterials = null
var _sport_details: SportDetails = null

func _load_glb(path: String, node_name: String) -> Node3D:
	if not ResourceLoader.exists(path):
		push_warning("[MainGame] 缺少模型 %s" % path)
		return null
	var scene := load(path) as PackedScene
	if scene == null:
		return null
	var inst := scene.instantiate()
	inst.name = node_name
	add_child(inst)
	GlbLoader.configure_meshes(GlbLoader.meshes_of(inst), true, true)
	return inst

func _on_progress(text: String) -> void:
	panels.set_loading_text(text)
	panels.set_loading_progress(world.progress_ratio())


## 致命失败 → 加载画面切到原版的 error 态（城市暂时没有载入 + 重新载入）
func _on_failed(reason: String) -> void:
	panels.fail_loading(reason)

## 城市构建完成后的收尾。
## 注意：各子系统（sky / lighting / water / weather / distant / scenery / signs /
## signals / traffic / pedestrians / ebikes / facades）的 setup 已经由 CityWorld
## 的装配步骤按原版 init() 的顺序调用过了，这里**不能**重复 setup。
func _on_built() -> void:
	print("[MainGame] 城市构建完成，启动累计 %d ms" % Time.get_ticks_msec())
	MemProbe.mark("on_built入口")
	career.setup(world)
	rides.setup(world)
	story.setup(world, career)
	MemProbe.mark("career/rides/story 后")

	hud.setup(world, self)
	MemProbe.mark("hud.setup 后")
	maps.setup(world, self)
	MemProbe.mark("maps.setup 后")
	# 观察信标：构建期 HUD 还不存在，提示回调在这里补注入
	if world.beacons != null and world.beacons.has_method("set_toast"):
		world.beacons.set_toast(func(m: String, t := 3.0): hud.toast(m, t))
	# HUD 比 MapUI 先建，_build() 里那次排版问不到小地图尺寸。
	# MapUI 就绪后补一次排版，否则圆形小地图停在 0×0 不显示。
	hud.refresh_layout()
	# 大地图点选地标 → 自动驾驶前往（原版 city-map.ts 的 onAutoDrive）
	maps.destination_picked.connect(_on_destination_picked)
	maps.quick_travel_requested.connect(_on_map_quick_travel)
	maps.photo_requested.connect(_on_map_photo)
	# 大地图上「自动驾驶前往 / 自己开过去」两个按钮
	maps.route_mode_chosen.connect(_on_route_mode_chosen)
	# 大地图开/关：开图时丢掉相机拖拽状态（见 _on_big_map_toggled）
	maps.big_map_toggled.connect(_on_big_map_toggled)
	maps.pick_failed.connect(func(reason: String): hud.toast(reason, 2.5))
	panels.setup(world, self, career, story)
	MemProbe.mark("panels.setup 后")
	# 设置页的「帧率显示」行要操作 HUD
	panels.hud = hud
	# 暂停页的声音滑杆要操作程序化音频
	panels.audio_player = audio
	panels.resume_requested.connect(func():
		paused = false
		panels.show_pause(false))

	# 出生点
	var sp := CityData.spawn_pos
	car.reset_to(sp.x, sp.y, CityData.spawn_yaw)
	_camera_yaw = CityData.spawn_yaw
	walk.active = false
	_apply_light_mode()
	GraphicsQuality.apply_to_world(world)

	# —— mannequin 着色器预热（首次按 F 下车卡顿的主因之一）——
	# 原预热 EnterWorld 同帧就 ExitWorld 藏掉，角色从没真正画过一帧，
	# 皮肤/动画着色器全部推迟到首次下车现编译（数百毫秒级卡顿）。
	# 现在：出生点 = 最可能的首次下车点，角色在初始相机视野里真渲染
	# 一帧，着色器编译藏进加载画面。期间 ALS 轨道相机会抢 Current，
	# 结束后把主相机抢回来。headless 无绘制事件，frame_post_draw 永不
	# 触发，必须跳过等待。
	if _als_host != null and _als_host.RuntimeReady \
			and DisplayServer.get_name() != "headless":
		var feet := CoordinateUtil.to_world(sp.x, sp.y,
			world.height_field.height_at(sp.x, sp.y))
		if _als_ground != null:
			_als_ground.update_around(feet)   # 出生点的地面/建筑碰撞格顺手预铺
		_als_host.EnterWorld(feet, CityData.spawn_yaw)
		# 必须等**物理帧**：首次 Active 的惰性初始化（并行动画 worker 握手、
		# 动画生命周期就绪、蒙皮缓冲）发生在 ALS 的 _PhysicsProcess 里，
		# 实测要吃掉 149ms + 67ms 两帧 —— 只等 frame_post_draw 时 240Hz 下
		# 一个物理帧都跑不到，预热等于没做（disount 探针实测结论）。
		for i in 8:
			await get_tree().physics_frame
		# 着色器同理：保证至少一次真实绘制，皮肤/动画管线在加载画面后面编译
		await RenderingServer.frame_post_draw
		_als_host.ExitWorld()
		camera.current = true

	session_ready = true
	MemProbe.mark("finish_loading 前")
	panels.finish_loading()
	MemProbe.mark("finish_loading 后")
	hud.toast("深城纪 · F10 图像设置 · P 帧率 · Esc 暂停", 5.0)

# ---------------------------------------------------------------------------
# 输入
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not session_ready:
		return
	# 大地图展开时，鼠标完全归地图：这里整体不改相机、不缩放。
	#
	# map_ui 那边已经在 gui_input 里 accept_event()，正常情况事件根本到不了这里；
	# 这道闸是兜底 —— 万一有事件从别的控件（地图里的按钮、将来新增的面板）漏下来，
	# 也不会把相机/步行视距带着一起动。
	if maps != null and maps.big_map_visible and event is InputEventMouse:
		_dragging = false
		return
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo:
			_on_key(k)
		_keys[k.keycode] = k.pressed
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			if mode == Mode.WALKING:
				walk.zoom(120.0)
			camera.distance_scale = clampf(camera.distance_scale * 1.08, 0.5, 6.0)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			if mode == Mode.WALKING:
				walk.zoom(-120.0)
			camera.distance_scale = clampf(camera.distance_scale / 1.08, 0.5, 6.0)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			# 观察模式：左键按下开始计长按（光标 id 用 0，鼠标没有 pointerId）
			if mode == Mode.OBSERVER and world != null and world.beacons != null:
				var g = world.beacons.gesture
				if mb.pressed:
					# 捕获模式下没有自由光标，落点取屏幕中心（准星语义）；
					# 可见模式（UI 开着时理论上到不了这里）仍用真实位置。
					if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
						_beacon_cursor = get_viewport().get_visible_rect().size * 0.5
					else:
						_beacon_cursor = mb.position
					g.begin(0, _beacon_cursor.x, _beacon_cursor.y, mb.button_index,
						true, Input.is_key_pressed(KEY_SHIFT), float(Time.get_ticks_msec()))
				else:
					g.end(0)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		# 观察模式的长按计步：按住后移动超过 8px 就取消。
		# 捕获模式下 position 失真（被扳回中心），改喂"中心 + 累计 relative"
		# 的虚拟光标，"移动超 8px 取消"的判定语义不变。
		if mode == Mode.OBSERVER and world != null and world.beacons != null \
				and not world.beacons.gesture.pointer.is_empty():
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				_beacon_cursor += mm.relative
				world.beacons.gesture.move(0, _beacon_cursor.x, _beacon_cursor.y)
			else:
				world.beacons.gesture.move(0, mm.position.x, mm.position.y)
		# 视角增量的两个来源：
		#   · 捕获模式（gameplay 常态）：移动鼠标直接转视角，FPS 式，不用按键；
		#   · 光标可见（理论只在 UI 打开时出现）：保留旧的"按住右键拖动"兜底。
		# 增量一律用 relative 而不是位置差：捕获模式下 position 会被扳回中心
		# 绕圈回绕，位置差会出跳变；relative 与可见模式下的位置差数值等价，
		# 两种模式通吃。
		if _dragging or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			var d := mm.relative
			if mode == Mode.WALKING:
				if _als_walk_active and _als_orbit != null:
					# ALS 轨道相机环视：捕获期间鼠标即转，灵敏度由
					# OrbitCamera 内部 0.0025 决定
					_als_orbit.ApplyMouseMotion(Vector2(d.x, d.y))
				elif Input.is_key_pressed(KEY_SHIFT):
					walk.yaw += d.x * 0.004
				else:
					_camera_yaw -= d.x * 0.004
					_look_pitch = clampf(_look_pitch - d.y * 0.003, -1.0, 1.05)
			elif mode == Mode.OBSERVER:
				if Input.is_key_pressed(KEY_SHIFT):
					observer.pan(d.x, d.y)
				else:
					observer.look(d.x, d.y)
			else:
				_camera_yaw -= d.x * 0.004
				_look_pitch = clampf(_look_pitch - d.y * 0.003, -0.2, 1.0)


## 大地图展开 → 主动清掉相机拖拽状态。
##
## 场景：玩家正按着右键拖视角时按 M 开图，之后的右键松开落在图上、被地图吞掉，
## main_game 就再也收不到那个"松开"，`_dragging` 卡在 true —— 关图后不按任何键
## 移动鼠标，视角也会跟着转。开图瞬间把它归零即可。
func _on_big_map_toggled(visible: bool) -> void:
	if visible:
		_dragging = false


func _on_key(k: InputEventKey) -> void:
	var code := k.keycode
	# 图像设置页（F10）打开时接管按键：↑↓ 选择、←→ 调整、F10/Esc 关闭。
	# 其余按键一律吞掉（此时游戏处于暂停态，不该误触车辆或其它面板）。
	if panels.settings_visible:
		if panels.handle_settings_key(k):
			paused = panels.settings_visible
		return
	# "?"（Shift+/，多数键盘 / 与 ? 同键）完整按键帮助：打开时接管按键，
	# 只认 Esc / ? 关闭 —— 与设置页一样是模态的，期间不该误触载具或其它面板。
	if panels.help_visible:
		if code == KEY_ESCAPE or code == KEY_SLASH:
			panels.toggle_help()
		return
	match code:
		KEY_ESCAPE:
			if panels.dialog_active:
				panels.close_dialogue()
			elif panels.help_visible:
				panels.toggle_help()
			elif panels.journal_visible:
				panels.toggle_journal()
			elif maps.big_map_visible:
				maps.toggle_big_map()
			elif mode == Mode.OBSERVER:
				_exit_observer()
			else:
				paused = not paused
				# 原版 #pause：歇一会儿。 + 继续驾驶 + 按键表 + 声音与音乐
				panels.show_pause(paused)
		KEY_F10:
			# CS2 风格图像设置页：打开即暂停，关闭即恢复
			panels.toggle_settings()
			paused = panels.settings_visible
		KEY_C:
			if mode == Mode.WALKING:
				# ALS 角色暂无第一人称入口：给个提示而不是撒谎的切换 toast
				if _als_walk_active and _als_available():
					hud.toast("ALS 步行为第三人称，暂不支持第一人称")
				else:
					_walk_first_person = not _walk_first_person
					hud.toast("步行 · 第一人称" if _walk_first_person else "步行 · 第三人称")
			else:
				camera.next_view()
		KEY_F:
			# 原版飞行 HUD 的按键表写明「G / F 返回驾驶」：飞行中 F 要能从飞机
			# 一路退回驾驶，而不是落进 _toggle_vehicle_entry（它只认 CAR/TANK，
			# 在 AIRCRAFT 下是空操作，飞行中按 F 此前毫无反应）。
			if mode == Mode.AIRCRAFT:
				_toggle_aircraft()      # 飞机 → 无人机
				_exit_observer()        # 无人机 → 驾驶
			else:
				_toggle_vehicle_entry()
		KEY_T:
			_toggle_tank()
		KEY_G:
			if mode == Mode.AIRCRAFT:
				_toggle_aircraft()
				_exit_observer()
			elif mode == Mode.OBSERVER:
				_exit_observer()
			else:
				_enter_observer()
		KEY_B:
			# B 是"无人机 ⇄ 飞机"的开关，两个方向都要认（此前只认 OBSERVER，
			# 于是飞上去之后就再也按不回无人机了）。
			# 驾驶 / 坦克 / 步行里按 B：先进无人机（_enter_observer 会记下来源
			# 模式），随即切飞机 —— 不用再记"先按 G 再按 B"两步。
			if mode == Mode.OBSERVER or mode == Mode.AIRCRAFT:
				_toggle_aircraft()
			elif not panels.dialog_active:
				_enter_observer()
				_toggle_aircraft()
		KEY_I:
			# 观察模式：移动到信标选中的落点（原版"移动到此地"按钮）
			if mode == Mode.OBSERVER:
				_beacon_travel()
		KEY_O:
			# 观察模式：收藏 / 更新收藏
			if mode == Mode.OBSERVER and world != null and world.beacons != null:
				world.beacons.save_selected()
		KEY_U:
			# 观察模式：清除光柱
			if mode == Mode.OBSERVER and world != null and world.beacons != null:
				world.beacons.clear()
				hud.toast("已清除光柱", 2.0)
		KEY_L:
			world.lighting.cycle_mode()
			_apply_light_mode()
			hud.toast("光照：%s" % _light_mode_name())
		KEY_SLASH:
			# "?"（Shift+/）完整按键帮助：各模式（驾驶 / 步行 / 坦克 / 无人机 /
			# 飞机）的全部按键分组列出，Esc 或 ? 关闭。
			panels.toggle_help()
		KEY_Y:
			var on: bool = world.weather.toggle()
			GameState.rain = on
			hud.toast("天气：%s" % ("雨天（路面湿滑已开启）" if on else "放晴"))
		KEY_M:
			maps.toggle_big_map()
		KEY_J:
			panels.toggle_journal()
		KEY_P:
			hud.toggle_fps()
			# 与设置页的「帧率显示」行保持同步（overrides 持久化）
			GraphicsQuality.set_override("fps", hud.is_fps_visible())
			GraphicsQuality.save()
		KEY_E:
			_interact()
		KEY_H:
			if audio != null:
				audio.cue("horn")
			hud.toast("鸣笛", 1.0)
		KEY_R:
			_reset_to_road()
		KEY_1, KEY_2, KEY_3:
			# Godot 4 的数字键常量是 KEY_1 / KEY_2 / KEY_3（不是 KEY_ONE）。
			var ordinal := code - KEY_1 + 1
			if panels.dialog_active:
				var idx := panels.choose_dialogue(ordinal)
				if idx >= 0:
					_resolve_dialogue(idx)
			elif panels.journal_visible:
				# 手账里按显示顺序编号（1 起），与 available_contracts() 的顺序一致
				var contracts: Array = career.available_contracts()
				if ordinal >= 1 and ordinal <= contracts.size():
					if career.accept(int(contracts[ordinal - 1])):
						hud.toast("已接下合约：%s" % career.status()["contract"], 3.0)
						panels.refresh_journal()

func _light_mode_name() -> String:
	match GameState.light_mode:
		GameContent.LightMode.DAY: return "晴日"
		GameContent.LightMode.NIGHT: return "夜色"
	return "日落"

func _apply_light_mode() -> void:
	if world.sky != null:
		world.sky.apply_mode(GameState.light_mode)
	if world.water != null:
		world.water.on_light_mode(GameState.light_mode)
	if lights != null:
		lights.set_light_mode(GameState.light_mode)

# ---------------------------------------------------------------------------
# 模式切换
# ---------------------------------------------------------------------------

func _snap_to_road(x: float, z: float) -> Vector3:
	var near := world.collision.nearest(x, z)
	if near.is_empty():
		return Vector3(x, z, car.yaw)
	var road: Dictionary = near["road"]
	var road_name := str(road.get("display_name", road.get("name", "")))
	_last_road_message = "已回到 %s" % road_name if road_name != "" else "已回到最近道路"
	return Vector3(near["point"].x, near["point"].y, near["yaw"])

var _last_road_message := ""

func _reset_to_road() -> void:
	# 原版 reset-road 时取消自动驾驶
	if autopilot.active:
		autopilot.cancel()
		maps.clear_destination()
	_clear_pending()
	if mode == Mode.TANK:
		var t := _snap_to_road(tank.x, tank.z)
		tank.x = t.x
		tank.z = t.y
		tank.yaw = t.z
		tank.speed = 0.0
		_camera_yaw = t.z
	elif mode == Mode.CAR:
		var c := _snap_to_road(car.x, car.z)
		car.reset_to(c.x, c.y, c.z)
		_camera_yaw = c.z
	else:
		return
	hud.toast(_last_road_message)

func _toggle_tank() -> void:
	if mode == Mode.WALKING or mode == Mode.OBSERVER or mode == Mode.AIRCRAFT:
		return
	if mode == Mode.CAR:
		if not tank.footprint_clear(car.x, car.z, car.yaw,
				func(x: float, z: float) -> bool: return world.collision.blocked(x, z)):
			var s := _snap_to_road(car.x, car.z)
			if not tank.footprint_clear(s.x, s.y, s.z,
					func(x: float, z: float) -> bool: return world.collision.blocked(x, z)):
				hud.toast("这里放不下坦克，先开到开阔路面")
				return
			tank.x = s.x
			tank.z = s.y
			tank.yaw = s.z
		else:
			tank.x = car.x
			tank.z = car.z
			tank.yaw = car.yaw
		tank.speed = 0.0
		tank.steer = 0.0
		mode = Mode.TANK
		autopilot.cancel()
		_clear_pending()
		car.speed = 0.0
		if _car_model != null:
			_car_model.visible = false
		if _tank_model != null:
			_tank_model.visible = true
		camera.set_mode(ChaseCamera.Mode.TANK, true)
		_camera_yaw = tank.yaw
		hud.toast("切换为坦克：Q/E 炮塔，PgUp/PgDn 炮管，Space 开炮")
	else:
		if not _tank_safe_for_car():
			hud.toast("坦克太宽，旁边没有空间换车")
			return
		car.reset_to(tank.x, tank.z, tank.yaw)
		mode = Mode.CAR
		if _car_model != null:
			_car_model.visible = true
		if _tank_model != null:
			_tank_model.visible = false
		# 切出坦克：收回在飞的炮弹与爆炸（原版 setActive(false) → clearEffects）
		if _tank_shells != null:
			_tank_shells.clear_effects()
		camera.set_mode(ChaseCamera.Mode.DRIVING, true)
		_camera_yaw = tank.yaw
		hud.toast("切换为轿车")

## 换车空间检测的采样偏移。
##
## 两点限制：
##   1) `const X := PackedFloat32Array([...])` **非法** —— Packed*Array 的构造
##      不是常量表达式（只有 Vector2 / Vector3 / Color 这类值类型的构造才会被常量折叠）。
##   2) 退回普通数组字面量后，遍历出的循环变量是 Variant，会让下面
##      `tank.x + cos(...) * side + ...` 也变成 Variant、`var sx := ...` 推断失败。
##
## 解法：const 放普通数组，在**函数体内**转成 PackedFloat32Array 再遍历。
const CAR_SWAP_SIDE := [-1.0, 0.0, 1.0]
const CAR_SWAP_ALONG := [-3.0, 0.0, 3.0]

func _tank_safe_for_car() -> bool:
	var sides := PackedFloat32Array(CAR_SWAP_SIDE)
	var alongs := PackedFloat32Array(CAR_SWAP_ALONG)
	for side in sides:
		for along in alongs:
			var sx := tank.x + cos(tank.yaw) * side + sin(tank.yaw) * along
			var sz := tank.z - sin(tank.yaw) * side + cos(tank.yaw) * along
			if world.collision.blocked(sx, sz):
				return false
	return true

## 在子树里按名字找节点（GLB 导入后节点名保留，层级可能多一层根）。
func _find_child_by_name(root: Node, wanted: String) -> Node3D:
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.name == wanted and n is Node3D:
			return n as Node3D
		for c in n.get_children():
			stack.append(c)
	return null


## 把炮塔/炮管的姿态落到实体节点上（原版 city-tank.ts 里炮塔实体跟着 aim 转）。
##
## 推导：车体 rotation.y = node_yaw(tank.yaw) = PI − yaw；炮塔要指向
## 世界角 a = yaw + turret_yaw，对应 node_yaw(a) = PI − yaw − turret_yaw。
## 炮塔是车体的子节点，其**局部** rotation.y = node_yaw(a) − node_yaw(yaw)
## = −turret_yaw。
## 炮管绕自身 X 轴俯仰：局部 +Z 要转向 +Y（fire() 里 dir.y = sin(barrel_pitch)
## 为正即抬高），绕 X 转 θ 时 (0,0,1) → (0,−sinθ,cosθ)，故 θ = −barrel_pitch。
func _apply_tank_pose() -> void:
	if _tank_turret != null:
		_tank_turret.rotation.y = -tank.turret_yaw
	if _tank_barrel != null:
		_tank_barrel.rotation.x = -tank.barrel_pitch
		# 后坐：炮管沿自身 -Z 回抽 tank.recoil（原版 home + (0,0,-recoil)），
		# 回抽量由 tick_cooldown 里的 exp(−dt·12) 衰减
		_tank_barrel.position = _tank_barrel_home + Vector3(0.0, 0.0, -tank.recoil)


## —— 下车链路微秒级打点（临时诊断，配合 tools/_perf.gd 的 dismount 模式）——
## 只打印 >1ms 的步骤。2026-10-19 定位结论：同步链路全程 <1ms，卡顿在 C#
## 侧首次 Active 物理帧的惰性初始化（见修复记录十七节），已用物理帧预热解决。
## 保留开关便于以后复发时一键打开。
const DISMOUNT_TRACE := false

func _trace_mark(label: String, t0: int) -> void:
	if not DISMOUNT_TRACE:
		return
	var us := Time.get_ticks_usec() - t0
	if us > 1000:
		print("[dismount-trace] %6.2fms  %s" % [us / 1000.0, label])


func _toggle_vehicle_entry() -> void:
	if mode == Mode.CAR or mode == Mode.TANK:
		var v := _vehicle_state()
		if absf(float(v["speed"])) > 1.0:
			hud.toast("先停稳再下车")
			return
		var _t := Time.get_ticks_usec()
		var offset := TANK_EXIT_OFFSET if mode == Mode.TANK else WALK_EXIT_OFFSET
		if not walk.exit_car(v, offset):
			hud.toast("车门旁边没有落脚点")
			return
		_trace_mark("walk.exit_car", _t)
		_last_ground_vehicle = Mode.TANK if mode == Mode.TANK else Mode.CAR
		if mode == Mode.TANK:
			# 下车（坦克）：收回在飞的炮弹与爆炸
			if _tank_shells != null:
				_tank_shells.clear_effects()
		# ⚠️ 载具模型不再隐藏：下车后车/坦克应停在原地可见（GTA 式停车）。
		# 模型 transform 停留在 _place_car_model/_apply_tank_pose 的最后姿态，
		# 上车时 reset_to 会重新对齐到角色位置。
		_flush_speed()
		# 停着的载具进入 ALS 物理代理 —— 载具体系没有物理体，不补这个盒
		# mannequin 胶囊会直接从停着的车里穿过去（修复记录二十节）。
		if _als_ground != null:
			_als_ground.set_vehicle_obstacle(
				_tank_model if _last_ground_vehicle == Mode.TANK else _car_model)
		mode = Mode.WALKING
		# 原版 exit-car 时取消自动驾驶
		autopilot.cancel()
		maps.clear_destination()
		_clear_pending()
		_walk_first_person = false
		_t = Time.get_ticks_usec()
		camera.set_mode(ChaseCamera.Mode.WALKING, true)
		_trace_mark("camera.set_mode(WALKING)", _t)
		# ALS 角色接管步行（不可用会在内部报错，不回退）
		_als_enter_world()
		_t = Time.get_ticks_usec()
		hud.toast("%s · WASD 行走 / Shift 跑步 / 移动鼠标环视 / 滚轮远近 / F 上车" % RIDER_SCRIPT.CHARACTER_NAME)
		_trace_mark("hud.toast(F 提示)", _t)
	elif mode == Mode.WALKING:
		# ⚠️ 必须先判"能不能上车"，判定通过才收角色！
		# 旧流程先 _als_exit_world 再 can_enter —— 走远了按 F 被拒时角色已被
		# 停用隐藏、mode 仍是 WALKING，移除旧步行回退后就变成"当场卡死、
		# 人和车都不显示"（修复记录十七期间的硬 bug）。walk.x/z 由 ALS 分支
		# 每帧镜像，距离判定不需要先收角色。
		var want_tank := _last_ground_vehicle == Mode.TANK and _tank_model != null
		var v2: Dictionary
		if want_tank:
			v2 = {"x": tank.x, "z": tank.z, "yaw": tank.yaw, "speed": tank.speed}
		else:
			v2 = _vehicle_state()
		var _t := Time.get_ticks_usec()
		if not walk.can_enter(v2, 5.0, WALK_EXIT_OFFSET):
			hud.toast("走近车门再按 F 上车")
			_trace_mark("walk.can_enter=拒绝", _t)
			return
		_trace_mark("walk.can_enter", _t)
		_als_exit_world()
		_trace_mark("als_exit_world", _t)
		# 载具即将重新移动，移除停泊障碍盒
		if _als_ground != null:
			_als_ground.clear_vehicle_obstacle()
		mode = Mode.TANK if want_tank else Mode.CAR
		_camera_yaw = walk.yaw
		_t = Time.get_ticks_usec()
		if mode == Mode.TANK:
			tank.x = walk.x
			tank.z = walk.z
			if _tank_model != null:
				_tank_model.visible = true
			camera.set_mode(ChaseCamera.Mode.TANK, true)
		else:
			car.reset_to(walk.x, walk.z, walk.yaw)
			if _car_model != null:
				_car_model.visible = true
			camera.set_mode(ChaseCamera.Mode.DRIVING, true)
		_trace_mark("reset_to + set_mode(DRIVING)", _t)
		walk.active = false
		_t = Time.get_ticks_usec()
		hud.toast("已上车 · C 切换驾驶镜头")
		_trace_mark("hud.toast(已上车)", _t)

func _vehicle_state() -> Dictionary:
	if mode == Mode.TANK:
		return {"x": tank.x, "z": tank.z, "yaw": tank.yaw, "speed": tank.speed}
	return {"x": car.x, "z": car.z, "yaw": car.yaw, "speed": car.speed}

func _flush_speed() -> void:
	car.speed = 0.0
	car.steer = 0.0
	tank.speed = 0.0
	tank.steer = 0.0
	_keys.clear()

## —— ALS 步行角色衔接（GtaSzAlsPlayerHost 的 enter/exit 契约）——
##
## enter_world：下车/退出观景时把角色放到 CityWalk 记录的落脚点，接管步行模式
## （轨道相机换 Current、隐藏旧 Rider 模型）；exit_world：上车/进观景前把马达
## 位置写回 CityWalk（x/z/yaw），再停用角色、交还 ChaseCamera。
## 坐标契约：GTA 数据 yaw = -Godot 节点 yaw（见 coordinate_util.gd）。

func _als_available() -> bool:
	return _als_host != null and _als_host.RuntimeReady


## 载具行进中预热 ALS 物理地面代理：下车点 = 停车点，开车路上就把瓦片与
## 建筑碰撞格增量铺好（代理内部增量：位移 2m 才重排瓦片、跨 160m 格才建
## 新格），按 F 下车那一帧不再整批现做 —— 下车卡顿的另一主因。
func _warm_als_ground(data_x: float, data_z: float) -> void:
	if _als_ground != null:
		_als_ground.update_around(CoordinateUtil.to_world(data_x, data_z, 0.0))


## —— 光标策略：默认"捕获 + 隐藏"（FPS 式），只有"需要鼠标的 UI"打开时可见 ——
## gameplay 画面（驾驶 / 坦克 / 步行 / 无人机 / 飞机 / 观景）一律
## MOUSE_MODE_CAPTURED：光标隐藏、鼠标锁在窗口内（移动到屏幕边缘不会丢，
## 也不会误点窗口外）。以下界面打开时切回 MOUSE_MODE_VISIBLE：
##   - Esc 暂停页（继续驾驶 / 声音按钮要靠鼠标点）；
##   - F10 图像设置页；
##   - 大地图（M / Esc 开关，点选目的地、拖拽全靠鼠标）；
##   - 加载页 / 失败重试页（session 未就绪，重试按钮要靠鼠标点）。
##
## 捕获带来的两处输入适配（见 _unhandled_input）：
##   1. 视角改为"移动鼠标直接转"（FPS 式，无需按住右键）——捕获只藏/锁
##      光标，不会自动把位移接到相机上，必须在 _unhandled_input 显式接线；
##      增量用 motion.relative —— 捕获模式下 position 会被扳回中心（绕圈
##      回绕），按位置差算会出跳变；relative 在可见 / 捕获两种模式下都
##      成立，且数值上与位置差等价，光标可见时的右键拖动兜底照旧；
##   2. 观察模式"长按左键立光柱"的落点改用屏幕中心（准星语义）——捕获
##      模式下没有自由光标，屏幕中心即瞄准点；"移动超 8px 取消长按"的
##      计步用"中心 + 捕获期间累计 relative"的虚拟光标喂给手势。
## OrbitCamera.InputEnabled 恒 false —— C# 侧的点击捕获 / Esc 切换彻底
## 退场（原先 Esc 还绑着暂停菜单，一键两义），视角仍由 GDScript 喂
## ApplyMouseMotion 驱动。
func _update_mouse_capture() -> void:
	if _als_orbit == null:
		return
	_als_orbit.InputEnabled = false
	# 需要光标的界面（任一成立即显示）：
	#   session 未就绪 → 加载页 / 失败重试页；
	#   settings_visible → F10 图像设置页（打开即 paused）；
	#   pause_overlay.visible → Esc 暂停页；
	#   big_map_visible → 大地图。
	var want_cursor: bool = not session_ready \
		or (panels != null and (panels.settings_visible \
			or (panels.pause_overlay != null and panels.pause_overlay.visible))) \
		or (maps != null and maps.big_map_visible)
	var target := Input.MOUSE_MODE_VISIBLE if want_cursor else Input.MOUSE_MODE_CAPTURED
	if Input.mouse_mode != target:
		Input.mouse_mode = target


func _als_enter_world() -> void:
	if _als_walk_active:
		return
	if not _als_available():
		# 启动时程序集已强制校验，这里只可能是运行时异常（如 RuntimeReady=false）。
		# 报错而不是静默换人 —— 旧回退路径已移除，宁可红字也别让角色"变脸"。
		push_error("[MainGame] ALS 角色不可用（RuntimeReady=false），下车后没有 mannequin。")
		return
	var _t := Time.get_ticks_usec()
	var ground_y := world.height_field.height_at(walk.x, walk.z)
	var feet := CoordinateUtil.to_world(walk.x, walk.z, ground_y)
	_trace_mark("height_at(落脚点)", _t)
	if _als_ground != null:
		_t = Time.get_ticks_usec()
		_als_ground.update_around(feet)   # 先把地面瓦片铺到落脚点，避免首帧下坠
		_trace_mark("als_ground.update_around", _t)
	# ⚠️ GDScript 调 C# 方法用 C# 原名（PascalCase），不做 snake_case 转换。
	_t = Time.get_ticks_usec()
	_als_host.EnterWorld(feet, walk.yaw)
	_trace_mark("ALS EnterWorld(C# 全部)", _t)
	_als_walk_active = true


func _als_exit_world() -> void:
	if not _als_walk_active:
		return
	var _t := Time.get_ticks_usec()
	var motor: Vector3 = _als_host.MotorPosition
	var d := CoordinateUtil.from_world(motor)
	walk.x = d.x
	walk.z = d.y
	walk.yaw = -_als_host.ViewYaw
	_als_host.ExitWorld()
	_trace_mark("ALS ExitWorld(C# 全部)", _t)
	_als_walk_active = false
	camera.current = true

func _enter_observer() -> void:
	_pre_observer_mode = mode
	# 步行进观景：ALS 角色停用（exit_world 会停马达并交还相机）
	if mode == Mode.WALKING:
		_als_exit_world()      # 马达位置写回 walk，停用 ALS 角色
		walk.active = false
	# 飞行中进观景：必须先把飞机停掉，否则 flight 仍 active 而 mode 已不是
	# AIRCRAFT，_step_aircraft 不再跑，飞机模型会挂在天上不动。
	elif mode == Mode.AIRCRAFT:
		flight.stop()
		if _plane_model != null:
			_plane_model.visible = false
	elif mode == Mode.TANK:
		# 进观景：坦克停止操控，收走在飞的炮弹与爆炸
		if _tank_shells != null:
			_tank_shells.clear_effects()
	var p := _player_position_data()
	observer.begin(p.x, world.height_field.height_at(p.x, p.y) + 60.0, p.y, _camera_yaw)
	observer.ground_height = func(x: float, z: float) -> float: return world.height_field.height_at(x, z)
	observer.blocked = func(x: float, z: float) -> bool: return world.collision.blocked(x, z)
	mode = Mode.OBSERVER
	# 原版 observer 进入时取消自动驾驶
	autopilot.cancel()
	maps.clear_destination()
	_clear_pending()
	# ⚠️ 不能 paused = true：_update_modes 遇 paused 直接 return，_step_observer
	# 不跑，观景相机就冻在切模式前的位置（原版 G 处理里 paused = world.aerial，
	# 观景期间世界照常运转、相机由 _step_observer 每帧跟随）。
	paused = false
	_flush_speed()
	camera.set_mode(ChaseCamera.Mode.OBSERVER, true)
	world.set_aerial(true)
	hud.toast("观景模式：W/A/S/D 平移，Q/E 升降，Shift 加速，移动鼠标转向；长按左键立光柱（I 前往 / O 收藏 / U 清除）", 6.0)

func _exit_observer() -> void:
	observer.end()
	# 还原进观景前的模式。之前这里固定回到车：从坦克进观景再退出会掉回轿车，
	# 步行进观景再退出则被凭空塞进车里、且角色模型还留在外面。
	match _pre_observer_mode:
		Mode.TANK:
			mode = Mode.TANK
			if _tank_model != null:
				_tank_model.visible = true
			camera.set_mode(ChaseCamera.Mode.TANK, true)
		Mode.WALKING:
			mode = Mode.WALKING
			camera.set_mode(ChaseCamera.Mode.WALKING, true)
			# ALS 角色重新接管步行（不可用时会 push_error，不再回退旧 rider）
			_als_enter_world()
		_:
			mode = Mode.CAR
			if _car_model != null:
				_car_model.visible = true
			camera.set_mode(ChaseCamera.Mode.DRIVING, true)
	if _plane_model != null:
		_plane_model.visible = false
	flight.stop()
	paused = false
	world.set_aerial(false)
	hud.toast("已退出观景")

## 无人机 ⇄ 观光水上飞机。
##
## ⚠️ 这里此前**从来没有写过 `mode = Mode.AIRCRAFT`**（全仓搜不到任何一处对
## AIRCRAFT 的赋值）——按 B 之后只是启了 flight 状态机、切了相机、显示了飞机模型，
## 但 `_update_modes` 仍然按 OBSERVER 分支跑 `_step_observer`：
##   · 飞机完全不受控（`_step_aircraft` 不执行，W/S/A/D 只让无人机平移）；
##   · `flight_hud_state` 也不被调用，飞行仪表盘永远不显示（`mode != AIRCRAFT`）。
## 无头模式发现不了（它不进飞行模式），是"应用参数 → 等过渡 → 截图"的探针
## 在 v_aircraft 与 v_observer 两张图逐像素相同（差 0.0055）时暴露的。
func _toggle_aircraft() -> void:
	if flight.active():
		flight.stop()
		if _plane_model != null:
			_plane_model.visible = false
		# 收回飞机 → 回到无人机，并把无人机放到飞机所在的位置。
		# ⚠️ 不要在这里写 _pre_observer_mode = Mode.CAR：它会把 _enter_observer
		# 记下的真实来源（坦克 / 步行 / 轿车）覆盖成轿车 —— 现在驾驶 / 步行里
		# 也能按 B 直达飞机，收回后按 G 应该回到出发时那种载具。
		observer.begin(flight.x, maxf(flight.y, 80.0), flight.z, flight.yaw)
		mode = Mode.OBSERVER
		camera.set_mode(ChaseCamera.Mode.OBSERVER, true)
		hud.toast("收回飞机，回到无人机")
		return
	# 起飞净空搜索（原版 start()：p.y ≥ max(80, 地形+65)，向上每 25m 探测，
	# 机身两侧 ±7m 的三条 "前 60m" 探测线都不撞才起飞；找不到就拒绝起飞）。
	# ⚠️ 不能省：直接在观测点起爆式开飞，出生点若在楼群里第一子步就撞毁。
	_ensure_flight_collision()
	var spawn_y := maxf(maxf(observer.y, 240.0),
			world.height_field.height_at(observer.x, observer.z) + 65.0)
	var spawn_ok := false
	for i in 60:
		if spawn_y > 2050.0:
			break
		spawn_ok = true
		for side in [-7.0, 0.0, 7.0]:
			var from := _flight_spawn_point(observer.x, spawn_y, observer.z,
					observer.yaw, side, -6.0, -1.5)
			var to := _flight_spawn_point(observer.x, spawn_y, observer.z,
					observer.yaw, side, 60.0, 2.4)
			if not _flight_collision.sweep(from, to, world.height_field.height_at).is_empty():
				spawn_ok = false
				break
		if spawn_ok:
			break
		spawn_y += 25.0
	if not spawn_ok:
		hud.toast("此处净空不足，无法起飞 —— 挪个位置再按 B", 3.0)
		return
	flight.start(observer.x, spawn_y, observer.z, observer.yaw)
	if _plane_model != null:
		_plane_model.visible = true
	# 飞行期间由 _step_aircraft 接管，无人机先停：否则 observer.step 仍在跑，
	# 退出飞行时无人机会停在"飞机当前所在处"之外的地方。
	observer.end()
	mode = Mode.AIRCRAFT
	camera.set_mode(ChaseCamera.Mode.AIRCRAFT, true)
	hud.toast("飞行：W/S 俯仰，A/D 横滚，Q/E 方向舵，Shift 加速，X 减速")


## 起飞探测线的采样点：yaw 平飞姿态下的 (right·side + forward·forward + up·up)。
## 数据坐标（与 FlightSim.point_at 同一套基）。
func _flight_spawn_point(px: float, py: float, pz: float, yaw: float,
		side: float, forward: float, up: float) -> Vector3:
	var b := FlightSim.basis_from(yaw, 0.0, 0.0)
	return Vector3(px, py, pz) \
			+ (b["right"] as Vector3) * side \
			+ (b["forward"] as Vector3) * forward \
			+ (b["up"] as Vector3) * up

# ---------------------------------------------------------------------------
# 主循环
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not session_ready:
		# _ready() 里有两帧的 await，这两帧 _process 会先于 world 创建跑进来
		if world != null:
			panels.set_loading_progress(world.progress_ratio())
			panels.set_loading_detail(world.progress_detail())
		return

	var dt := clampf(delta, 0.0, 0.05)
	# 原版 update() 第一行：this.time += dt（暂停也不停表）
	_game_time += dt

	# ALS 宿主有自己的 _PhysicsProcess，不吃 _update_modes 的 `if paused` 守卫
	# —— 暂停期间禁用其处理（含子节点轨道相机），恢复时再放开。
	if _als_host != null:
		_als_host.process_mode = Node.PROCESS_MODE_DISABLED if paused else Node.PROCESS_MODE_INHERIT

	_update_mouse_capture()
	_update_modes(dt)
	_check_manual_arrival()

	# 焦点与分块剔除
	var focus := camera.global_position
	var p := _player_position_data()
	world.set_focus(CoordinateUtil.to_world(p.x, p.y, 0.0))

	# 光照跟随、路灯、招牌、立面流式
	if world.lighting != null:
		world.lighting.update_system(dt, focus)
	# 天空推进（Sky 着色器的光照档过渡）—— 主路径下 Sky 本身就在无限远，
	# 没有球体要搬；这里传focus 只是为了兜底路径（缺 sky_sky.gdshader 时的
	# 两个 8000 直径球）能每帧把球心搬到相机上。
	# ⚠️ 兜底路径曾经有个真实 bug：球心停在世界原点，而出生点距原点 2800m，
	# 于是朝外看时视线只打到球面赤道附近一条极窄的带，着色器的
	# h = smoothstep(-0.05, 0.85, p.y) 恒在 0.0~0.2，整屏都是 horizon_color，
	# 表现为"从路面一直顶到天空的一整片纯色幕布"，把远处城市切成一刀。
	if world.sky != null:
		world.sky.update_system(dt, focus)
	world.facades.update_system(dt, focus)

	# 玩法
	# ⚠️ 暂停时必须整段跳过：_update_modes() 开头有 `if paused: return`，但这段
	# 在它之后、不受那个守卫管。于是打开暂停菜单后 rides.step() / career.step()
	# 仍每帧执行，合约的 elapsed 照常累加、评分照常随时间衰减 —— 暂停没真暂停，
	# 挂机在暂停界面里也能把合约"拖"到超时。
	var speed := float(_vehicle_state()["speed"]) if mode in [Mode.CAR, Mode.TANK] else walk.speed
	var res: Dictionary = {}
	if not paused:
		rides.step(p, speed, absf(float(_vehicle_state()["speed"])) * dt if mode in [Mode.CAR, Mode.TANK] else 0.0)
		res = career.step(dt, p, speed, false, false)
		story.note_position(p)
	if res.get("completed", false):
		hud.toast(str(res["message"]), 4.0)
		if audio != null:
			audio.cue("arrival")
		if not res["dialogue"].is_empty():
			_pending_level_up_dialogue = res["dialogue"]
			var opts: Array = res["dialogue"].get("options", [])
			panels.show_dialogue(str(res["dialogue"]["line"]), opts, "career")

	# UI
	hud.update_hud(dt)
	maps.update_ui(dt)

	# 音频：把驾驶状态喂给程序化合成器
	if audio != null:
		audio.enabled = GameState.audio_enabled
		var slipping := false
		if mode == Mode.CAR:
			slipping = Input.is_key_pressed(KEY_SPACE) and absf(car.speed) > 6.0
		audio.set_drive_state(speed, 0.55 if mode in [Mode.CAR, Mode.TANK] else 0.0, slipping)

func _update_modes(dt: float) -> void:
	if paused:
		return
	match mode:
		Mode.CAR:
			_step_car(dt)
		Mode.TANK:
			_step_tank(dt)
		Mode.WALKING:
			_step_walk(dt)
		Mode.OBSERVER:
			_step_observer(dt)
		Mode.AIRCRAFT:
			_step_aircraft(dt)

func _axis_key(pos_keys: Array, neg_keys: Array) -> float:
	var v := 0.0
	for k in pos_keys:
		if Input.is_key_pressed(k):
			v += 1.0
	for k in neg_keys:
		if Input.is_key_pressed(k):
			v -= 1.0
	return clampf(v, -1.0, 1.0)

func _step_car(dt: float) -> void:

	var throttle := _axis_key([KEY_W, KEY_UP], [KEY_S, KEY_DOWN])
	var steer_in := _axis_key([KEY_D, KEY_RIGHT], [KEY_A, KEY_LEFT])
	# 自动驾驶的人工接管：任何驾驶按键一按就交还控制权
	# （原版提示语"方向键 / WASD 随时接管"）
	var manual_drive := absf(throttle) > 0.0 or absf(steer_in) > 0.0
	steer_in = CarDrive.manual_steering(steer_in, car.speed)
	var handbrake := Input.is_key_pressed(KEY_SPACE)

	if autopilot.active:
		if manual_drive:
			autopilot.cancel()
			maps.clear_destination()
			hud.toast("已切换为手动驾驶", 2.5)
		else:
			var ap := autopilot.compute(Vector2(car.x, car.z), car.yaw, car.speed, dt)
			throttle = float(ap["throttle"])
			steer_in = float(ap["steer"])
			_autopilot_phase_toasts()

	# 物理推进：只更新速度/转角/朝向，位置由下面的固定子步负责
	car.step({"throttle": throttle, "steer": steer_in, "handbrake": handbrake}, dt, 1.0, false)

	# 子步碰撞（原版 steps = ceil(|speed| * dt / 0.7)）
	var speed_before := car.speed
	# 行人撞击要的是"碰撞回滚之后"的前后两帧车姿，所以在这一段前后各拍一次
	var impact_before := {
		"x": car.x, "z": car.z, "yaw": car.yaw, "speed": speed_before,
		"groundY": world.height_field.height_at(car.x, car.z),
	}
	var steps := maxi(1, int(ceil(absf(speed_before) * dt / COLLISION_STEP)))
	var sub := dt / float(steps)
	for i in steps:
		var nx := car.x + sin(car.yaw) * car.speed * sub
		var nz := car.z + cos(car.yaw) * car.speed * sub
		var nose_x := nx + sin(car.yaw) * NOSE
		var nose_z := nz + cos(car.yaw) * NOSE
		if world.collision.blocked(nose_x, nose_z):
			# 命中：不再前进，按原版回弹规则处理速度
			car.speed = 0.0 if absf(speed_before) < 3.0 else -speed_before * 0.15
			break
		car.distance += absf(car.speed) * sub
		car.x = nx
		car.z = nz

	# 行人被撞倒地（原版 pedestrian-impact.ts）：把这一帧车的实际位移交出去
	if world.pedestrians != null and world.pedestrians.has_method("apply_car_motion"):
		world.pedestrians.apply_car_motion(impact_before, {
			"x": car.x, "z": car.z, "yaw": car.yaw, "speed": car.speed,
			"groundY": world.height_field.height_at(car.x, car.z),
		})

	_place_car_model()
	# 车轮滚动：原版 wheelSpin += s.speed*dt/wheelRadius（用碰撞回滚后的 speed，
	# 撞墙时轮子同步停转/倒转）；转向用物理转角 car.steer（前轮 + 刹车盘）。
	if _car_wheels != null and _car_wheels.part_count > 0:
		_wheel_spin += car.speed * dt / _car_wheels.wheel_radius
		_car_wheels.apply(_wheel_spin, car.steer)
	# 相机偏航以 1-exp(-dt*3) 追车头（原版 cameraYaw 慢速跟随，转弯时相机甩在车后）
	_camera_yaw = lerp_angle(_camera_yaw, car.yaw, 1.0 - exp(-dt * 3.0))
	camera.yaw = _camera_yaw
	camera.look_pitch = _look_pitch
	# 注视点传**车头** yaw（原版 target 用 s.yaw，转弯时锁定车头而非相机方向）
	camera.follow_vehicle(Vector3(car.x, 0.0, car.z), car.speed, dt, false, car.yaw)
	lights.update_brake(throttle < 0.0 and car.speed > 0.5, car.speed < -0.5)
	lights.place(_car_model.global_transform if _car_model != null else camera.global_transform)
	_warm_als_ground(car.x, car.z)

func _step_tank(dt: float) -> void:
	var throttle := _axis_key([KEY_W, KEY_UP], [KEY_S, KEY_DOWN])
	var steer_in := _axis_key([KEY_D, KEY_RIGHT], [KEY_A, KEY_LEFT])
	var handbrake := Input.is_key_pressed(KEY_X)
	tank.step({"throttle": throttle, "steer": steer_in, "handbrake": handbrake}, dt, false)
	tank.aim({
		"turret": _axis_key([KEY_E], [KEY_Q]),
		"barrel": _axis_key([KEY_PAGEUP], [KEY_PAGEDOWN]),
	}, dt)
	tank.tick_cooldown(dt)

	# 车体碰撞子步（与汽车同一套 0.7m 步长规则）
	var tank_steps := maxi(1, int(ceil(absf(tank.speed) * dt / COLLISION_STEP)))
	var tank_sub := dt / float(tank_steps)
	for i in tank_steps:
		var nx := tank.x + sin(tank.yaw) * tank.speed * tank_sub
		var nz := tank.z + cos(tank.yaw) * tank.speed * tank_sub
		var nose_x := nx + sin(tank.yaw) * TANK_NOSE
		var nose_z := nz + cos(tank.yaw) * TANK_NOSE
		if world.collision.blocked(nose_x, nose_z):
			tank.speed = 0.0
			break
		tank.distance += absf(tank.speed) * tank_sub
		tank.x = nx
		tank.z = nz

	if _tank_model != null:
		var g := world.height_field.height_at(tank.x, tank.z)
		_tank_model.global_transform = Transform3D(
			Basis(Vector3.UP, CoordinateUtil.node_yaw(tank.yaw)),
			CoordinateUtil.to_world(tank.x, tank.z, g + 0.05))
		_apply_tank_pose()
	# 炮弹推进（原版 tank.step 后半段；先推进已有弹，再处理开火 ——
	# 本帧刚射出的弹下一帧才开始飞，与原版一致）
	if _tank_shells != null:
		_tank_shells.step(dt, _flight_sweep)
	# 开炮。放在姿态更新之后：tank_muzzle 的世界位置要用本帧的
	# 炮塔/炮管变换，原版 fire() 里也是先 syncModel 再取炮口。
	if Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_ENTER):
		_ensure_tank_shells()
		# 原版先确认 tracer 池有空位、再消耗装填（池满时按住空格不空转装填）
		if _tank_shells.has_free() and tank.can_fire():
			var shot := tank.fire()
			if not shot.is_empty():
				# 原版优先用 tank_muzzle 节点的世界位置当炮口原点
				# （fallback 公式 dir·5 + 2.1 已在 TankSim.fire 里兜底）
				if _tank_muzzle != null and _tank_model != null:
					var wp: Vector3 = _tank_muzzle.global_position
					var o: Dictionary = shot["origin"]
					o["x"] = wp.x
					o["y"] = wp.y
					o["z"] = -wp.z          # 世界 → 数据（z = −北）
				if _tank_shells.fire_shot(shot, _flight_sweep, tank.yaw + tank.turret_yaw):
					hud.toast("开炮", 1.0)
					# 原版 fire() 里的 onExplosion：炮口爆音
					if audio != null:
						audio.explosion()
	_camera_yaw = lerp_angle(_camera_yaw, tank.yaw, 1.0 - exp(-dt * 3.0))
	camera.yaw = _camera_yaw
	camera.look_pitch = _look_pitch
	camera.follow_vehicle(Vector3(tank.x, 0.0, tank.z), tank.speed, dt, true, tank.yaw)
	lights.update_brake(handbrake, tank.speed < -0.5)
	lights.place(_tank_model.global_transform if _tank_model != null else camera.global_transform)
	_warm_als_ground(tank.x, tank.z)

func _step_walk(dt: float) -> void:
	# ALS 角色驱动：物理地面跟随马达；CityWalk 只做状态镜像（HUD/地图/上车判定
	# 继续读 walk.x/z）。旧 CityWalk + rider 步行回退已移除 —— ALS 角色是
	# 唯一步行实现，到这里还没接管就是 bug，报错并停帧（防每帧刷屏）。
	if _als_walk_active and _als_host != null and _als_host.RuntimeReady:
		var motor: Vector3 = _als_host.MotorPosition
		if _als_ground != null:
			_als_ground.update_around(motor)
		var d := CoordinateUtil.from_world(motor)
		walk.x = d.x
		walk.z = d.y
		walk.yaw = -_als_host.ViewYaw
		walk.speed = _als_host.HorizontalSpeed
		walk.moving = walk.speed > 0.1
		walk_eye_world = motor
		return
	if not _walk_error_shown:
		_walk_error_shown = true
		push_error("[MainGame] 步行模式没有 ALS 角色驱动（旧步行回退已移除），" +
			"角色将静止。请检查 ALS C# 程序集是否构建成功。")

var walk_eye_world := Vector3.ZERO

func _step_observer(dt: float) -> void:
	observer.step({
		"move_forward": Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP),
		"move_back": Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN),
		"steer_left": Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT),
		"steer_right": Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT),
		"up": Input.is_key_pressed(KEY_E),
		"down": Input.is_key_pressed(KEY_Q),
		"boost": Input.is_key_pressed(KEY_SHIFT),
	}, dt)
	camera.observer_position = CoordinateUtil.to_world(observer.x, observer.z, observer.y)
	camera.observer_yaw = observer.yaw
	camera.observer_pitch = observer.pitch
	camera.follow_observer(dt)
	_step_beacons(dt)


## 观察信标：长按判定 + 光柱跟随相机
##
## 长按的判定分两段 —— 定时器只在「按住不动够久」时才落地（原版 BeaconHoldGesture）：
##   · 按下：gesture.begin，记下按下点；
##   · 移动：超过 8px 就 cancel（把位移让给正常的环绕/平移）；
##   · 每帧：fire() 检查是否已经按够 650ms。
func _step_beacons(dt: float) -> void:
	if world == null or world.beacons == null:
		return
	var b = world.beacons
	if not b.gesture.pointer.is_empty() and str(b.gesture.pointer["phase"]) == "pending":
		var hit: Vector2 = b.gesture.fire(float(Time.get_ticks_msec()))
		if is_finite(hit.x):
			_beacon_place(hit)
	b.update_system(dt, mode == Mode.OBSERVER, camera.global_position)


## 把屏幕坐标投射到地形上落一根光柱
func _beacon_place(screen: Vector2) -> void:
	var b = world.beacons
	var origin := camera.project_ray_origin(screen)
	var dir := camera.project_ray_normal(screen)
	var point: Dictionary = b.pick(origin, dir)
	if point.is_empty():
		hud.toast("长按地面或建筑选点，天空中无法放置光柱", 3.0)
		return
	if not b.select(point):
		return
	var spot_name := str(b.selected.get("name", ""))
	hud.toast("已选点 · %s　I 移动到此地 · O 收藏 · U 清除" % spot_name, 4.0)


## I：移动到选中的落点（原版"移动到此地"）
func _beacon_travel() -> void:
	var b = world.beacons
	if b.selected.is_empty():
		hud.toast("先在观察模式里长按地面选一个落点", 3.0)
		return
	var dest: Dictionary = b.resolve_selected()
	if dest.is_empty():
		return
	if not dest.has("arrival"):
		hud.toast("%s：附近没有适合车辆落地的道路" % str(dest.get("name", "")), 3.5)
		return
	var arr: Array = dest["arrival"]
	car.reset_to(float(arr[0]), float(arr[1]), float(dest.get("yaw", 0.0)))
	_camera_yaw = float(dest.get("yaw", 0.0))
	# 这里是把**车**挪到落点，所以退出观景必须落到 CAR，
	# 不能沿用"进观景前是步行/坦克"的还原逻辑。
	_pre_observer_mode = Mode.CAR
	_exit_observer()
	hud.toast("已移动到 %s" % str(dest.get("name", "")), 3.0)

## 发射一枚导弹（空格 / 截图探针都用这一个入口）。
##
## ⚠️ 必须传 `flight.pose()` 而不是 `flight.status()`：status() 的位置字段是
## `"position": [x,y,z]` 数组，没有 x/y/z 键，直接喂给 fire() 会抛
## "Invalid access to property or key 'x' on a base object of type 'Dictionary'"
## —— 无头模式按不到空格，这个错误是靠开窗截图（探针调 fire）才暴露的。
func fire_missile() -> bool:
	if flight.phase != "flying":
		return false
	_ensure_missiles()
	if _missiles == null:
		return false
	var fired: bool = _missiles.fire(flight.pose(), flight.speed)
	if fired and audio != null:
		audio.cue("engage")
	return fired


## 从飞行模式回到无人机：飞机收起、无人机落到指定位置、模式与相机一起还原。
## 越界与坠毁恢复两条分支共用（此前两处都只切了相机、没动 mode）。
func _return_to_observer_from_flight(px: float, py: float, pz: float) -> void:
	if _plane_model != null:
		_plane_model.visible = false
	if _missiles != null:
		_missiles.clear()
	flight.stop()
	observer.begin(px, py, pz, flight.yaw)
	mode = Mode.OBSERVER
	_pre_observer_mode = Mode.CAR
	camera.set_mode(ChaseCamera.Mode.OBSERVER, true)


## 首次起飞时建导弹节点（原版是在 loadFlight() 里建的）。
func _ensure_missiles() -> void:
	if _missiles != null:
		return
	_missiles = MISSILES_SCRIPT.new()
	_missiles.name = "FlightMissiles"
	add_child(_missiles)


## 首次开炮时建炮弹节点（4 发曳光弹 + 2 个共用的 FlightExplosion）
var _tank_shells = null


func _ensure_tank_shells() -> void:
	if _tank_shells != null:
		return
	_tank_shells = TANK_SHELLS_SCRIPT.new()
	_tank_shells.name = "TankShells"
	if audio != null:
		_tank_shells.on_explosion = audio.explosion
	add_child(_tank_shells)


## 飞行 / 导弹共用的扫掠回调（原版 city-flight.ts 的 sweep + FlightCityCollision）。
##
## 历史坑（保留警示）：FlightSim 的位姿是**数据坐标**（x 东 / z 北），与
## flight.start(observer.x, observer.z) 同源 —— 早先这里按世界坐标又做了一次
## −mid.z 换算，把撞击点镜像到南北对称的位置。现在喂给 FlightCollision 的
## from/to 本身就是数据坐标，内部不要再做任何换算。
##
## ⚠️ 此前这里直接用驾驶的 collision.blocked(x,z)（二维足迹，无高度概念）：
## 飞多高都撞建筑投影，且 blocked() 对水面/非陆地返回 true，海湾上空全是"墙"。
## 已换成专门的 FlightCollision（建筑棱柱 + 地形采样，原版同款）。
func _flight_sweep(from: Vector3, to: Vector3) -> Dictionary:
	_ensure_flight_collision()
	return _flight_collision.sweep(from, to, world.height_field.height_at)


var _flight_collision = null


func _ensure_flight_collision() -> void:
	if _flight_collision != null:
		return
	_flight_collision = FLIGHT_COLLISION_SCRIPT.new()
	_flight_collision.build(CityData.buildings)


func _step_aircraft(dt: float) -> void:
	_ensure_missiles()
	# 原版 city-flight.ts:85：phase==='flying' && keys.has('Space') → fire()
	if flight.phase == "flying" and Input.is_key_pressed(KEY_SPACE):
		fire_missile()
	var result: String = flight.step({
		"move_forward": Input.is_key_pressed(KEY_W),
		"move_back": Input.is_key_pressed(KEY_S),
		"steer_left": Input.is_key_pressed(KEY_A),
		"steer_right": Input.is_key_pressed(KEY_D),
		"turret_left": Input.is_key_pressed(KEY_Q),
		"turret_right": Input.is_key_pressed(KEY_E),
		"run": Input.is_key_pressed(KEY_SHIFT),
		"brake_tank": Input.is_key_pressed(KEY_X),
	}, dt, Time.get_ticks_msec(), _flight_sweep, CityData.extent)

	# 导弹推进（原版 city-flight.ts:89：只在 phase==='flying' 时 step）
	if _missiles != null:
		if flight.phase == "flying":
			# ⚠️ _missiles 是 Variant（preload 出来的脚本），`var impacts :=`
			# 会推断失败（无头实跑抓到：Cannot infer the type of "impacts"）
			var impacts: Array = _missiles.step(dt, _flight_sweep)
			_missiles.update_visuals(dt, impacts)
			if impacts.size() > 0 and audio != null:
				audio.impact(0.6)
		else:
			# 坠毁 / 待机时把在飞的导弹与爆炸一起收掉（原版 crashed → missiles.clear()）
			_missiles.clear()

	if result == "crashed":
		hud.toast("飞机坠毁，3 秒后恢复为无人机", 3.0)
		# 原版 city-flight.ts:88：撞毁瞬间在命中点起爆 + onExplosion 音效
		if _missiles != null:
			var hp: Dictionary = flight.hit.get("point", {})
			_missiles.burst_at(Vector3(float(hp.get("x", flight.x)),
				float(hp.get("y", flight.y)), float(hp.get("z", flight.z))), flight.yaw)
		if audio != null:
			audio.explosion()
	elif result == "boundary":
		# 越界自动回无人机（原版 boundary 分支）。⚠️ 光把相机切回 OBSERVER 不够：
		# mode 还停在 AIRCRAFT，_step_aircraft 会继续跑（flight 已 idle），
		# 飞行仪表盘与模式文案都还是"飞行"。必须把模式与无人机状态一起还原。
		hud.toast("已到城市边界，自动返回")
		_return_to_observer_from_flight(flight.x, maxf(flight.y, 120.0), flight.z)
	elif result == "recovered":
		_return_to_observer_from_flight(
			float(flight.last_safe.get("x", observer.x)),
			maxf(float(flight.last_safe.get("y", 120.0)), 80.0),
			float(flight.last_safe.get("z", observer.z)))

	if _plane_model != null:
		var b := flight.basis()
		var fwd: Vector3 = b["forward"]
		var up: Vector3 = b["up"]
		var world_pos := CoordinateUtil.to_world(flight.x, flight.z, flight.y)
		# ⚠️⚠️ basis() 的向量是**数据坐标**（z=北），摆机模必须先翻成世界坐标
		# （z=−北），否则整个模型被南北镜像：机头指向运动方向的反侧，
		# 相机跟着"机尾"悬到运动路径前方迎面拍机鼻，横滚 A/D 与方向舵 Q/E
		# 看起来全反了。导弹 _draw() 早就做了同样的翻转（dir.x, dir.y, -dir.z），
		# 这里是同一坐标系契约 —— 别再漏。
		var fwd_w := Vector3(fwd.x, fwd.y, -fwd.z).normalized()
		var up_w := Vector3(up.x, up.y, -up.z)
		# ⚠️ 水上飞机模型的机头在 **-Z**，不是 +Z。
		# 实测：floatplane_propeller_mesh Z = -4.19（机身一端），
		# floatplane_airframe_fp_glass（座舱玻璃）Z = -0.52 —— 螺旋桨在座舱前方 3.7 m，
		# 是拉进式（tractor）布局，所以 -Z 才是机头。
		# 因此基的 z 轴取 **-fwd_w**（等价于绕 up 转 180°），y 轴仍取 up_w；
		# Godot 的 Basis(x, y, z) 要求右手系 x = y × z，cross 会自动把 x 一并翻过来。
		var z_axis := -fwd_w
		var y_axis := (up_w - z_axis * up_w.dot(z_axis)).normalized()
		var x_axis := y_axis.cross(z_axis)
		_plane_model.global_transform = Transform3D(
			Basis(x_axis, y_axis, z_axis), world_pos)
		# 螺旋桨旋转（原版 city-flight.ts:106 syncModel）：
		#   this.propeller.rotation.z += dt * (45 + this.sim.throttle * 70)
		# 转速 = 45 + 油门×70 rad/s（≈7~19 圈/秒）。只在 phase == "flying" 时转：
		# 坠毁（exploding）即熄火，收起（idle）时模型本来就不可见。
		# 桨节点在模型局部 -Z 端、无基础旋转，绕局部 Z 轴转即为绕桨轴。
		if _plane_propeller != null and flight.phase == "flying":
			_propeller_angle = fposmod(_propeller_angle + dt * (45.0 + flight.throttle * 70.0), TAU)
			_plane_propeller.rotation = Vector3(0.0, 0.0, _propeller_angle)
	camera.aircraft_basis = _plane_model.global_transform if _plane_model != null else Transform3D.IDENTITY
	camera.follow_aircraft(dt)

func _place_car_model() -> void:
	if _car_model == null:
		return
	var g := world.height_field.height_at(car.x, car.z)
	# ⚠️ 轿车模型的前向轴是 **-Z**，不是 +Z。
	# 实测（按各零件几何包围盒中心，模型局部坐标）：
	#   前轮 wheel_lf_rubber / wheel_rf_rubber  Z = -1.43
	#   后轮 wheel_lr_rubber / wheel_rr_rubber  Z = +1.78
	# 之前统一按 PLUS_Z 处理（rotation.y = PI − yaw），结果是车头朝后、倒着开。
	#
	# 车体姿态三件套（原版 city-world.ts update()，在 car.rotation 上合成
	# R = Ry(yaw)·Rx(pitch)·Rz(roll)，这里按本空间前向轴换算后逐项照抄）：
	#   悬挂起伏  sin(time*7)·min(.008, |speed|·.0004)
	#   俯仰      前后 ±1.5m 处地面高差 atan2(front−rear, 3)（本空间车头 −Z，
	#             抬头为正，与原版 −atan2(front−rear,3) 的抬头效果一致）
	#   侧倾      −steer·speed·.0025（转弯压向弯内的街机侧倾）
	var bob := sin(_game_time * 7.0) * minf(0.008, absf(car.speed) * 0.0004)
	var h_front := world.height_field.height_at(car.x + sin(car.yaw) * 1.5, car.z + cos(car.yaw) * 1.5)
	var h_rear := world.height_field.height_at(car.x - sin(car.yaw) * 1.5, car.z - cos(car.yaw) * 1.5)
	var pitch := atan2(h_front - h_rear, 3.0)
	var roll := -car.steer * car.speed * 0.0025
	var car_basis := Basis(Vector3.UP, CoordinateUtil.node_yaw(car.yaw, CoordinateUtil.ModelForward.MINUS_Z)) \
		* Basis(Vector3.RIGHT, pitch) * Basis(Vector3.BACK, roll)
	_car_model.global_transform = Transform3D(car_basis,
		CoordinateUtil.to_world(car.x, car.z, g + 0.02 + bob))

# ---------------------------------------------------------------------------
# 交互
# ---------------------------------------------------------------------------

func _player_position_data() -> Vector2:
	match mode:
		Mode.TANK:
			return Vector2(tank.x, tank.z)
		Mode.WALKING:
			return Vector2(walk.x, walk.z)
		Mode.OBSERVER:
			return Vector2(observer.x, observer.z)
		Mode.AIRCRAFT:
			return Vector2(flight.x, flight.z)
	return Vector2(car.x, car.z)

func _interact() -> void:
	if panels.dialog_active:
		return
	var p := _player_position_data()
	var speed := 0.0
	if mode == Mode.CAR:
		speed = car.speed
	elif mode == Mode.TANK:
		speed = tank.speed
	elif mode == Mode.WALKING:
		speed = walk.speed

	# 故事优先
	var on_foot := mode == Mode.WALKING
	var sres: Dictionary = story.interact(p, speed, on_foot)
	if sres.get("ok", false):
		# 台词由 story_system 按原版 lines 拼好（步骤里不再有静态 text 字段）
		panels.show_dialogue(str(sres["message"]), sres.get("options", []), "story")
		return

	var rres: Dictionary = rides.interact(p, speed)
	if rres.get("ok", false):
		hud.toast(str(rres["message"]), 3.0)

	# 手账里可接单：靠近生活驿站时按 E 打开手账
	for site in rides.sites:
		if p.distance_to(Vector2(site["x"], site["z"])) < 16.0:
			if not panels.journal_visible:
				panels.toggle_journal()
			return

func _resolve_dialogue(idx: int) -> void:
	var kind := panels.dialog_kind()
	panels.close_dialogue()
	if kind == "story":
		var r: Dictionary = story.choose(idx)
		if r.get("advanced", false):
			panels.show_dialogue(str(r["message"]), r.get("options", []), "story")
		elif r.get("completed", false):
			hud.toast(str(r["message"]), 5.0)
	elif kind == "career":
		if not _pending_level_up_dialogue.is_empty():
			career.choose_dialogue_option(_pending_level_up_dialogue, idx)
			hud.toast("关系 +%d" % int(_pending_level_up_dialogue["options"][idx].get("relationship", 0)), 3.0)
			_pending_level_up_dialogue = {}

# ---------------------------------------------------------------------------
# 供 HUD / 地图查询的接口
# ---------------------------------------------------------------------------

func speed() -> float:
	match mode:
		Mode.TANK: return tank.speed
		Mode.WALKING: return walk.speed
		Mode.OBSERVER: return 0.0
		Mode.AIRCRAFT: return flight.speed
	return car.speed

func gear_text() -> String:
	if paused:
		return "P"
	if mode == Mode.CAR and car.speed < -0.5:
		return "R"
	if mode == Mode.WALKING:
		return "走"
	return "D"

func odometer() -> float:
	match mode:
		Mode.TANK: return tank.distance
		Mode.WALKING: return walk.distance
	return car.distance

func data_position() -> Vector2:
	return _player_position_data()

func data_yaw() -> float:
	match mode:
		Mode.TANK: return tank.yaw
		Mode.WALKING: return walk.yaw
		Mode.OBSERVER: return observer.yaw
		Mode.AIRCRAFT: return flight.yaw
	return car.yaw

## 飞行 HUD 的状态快照 —— 原版 city-flight.ts:36 的 `get stats()`。
## altitude 是**离地高度**：`Math.max(0, sim.pose.y - heightAt(x, z))`，
## 与飞行碰撞用的是同一套高度场，仪表与"撞地"判定才不会互相打脸。
## missiles 由 FlightMissiles 提供（未启用时为空字典，HUD 会显示就绪）。
func flight_hud_state() -> Dictionary:
	var s := flight.status()
	var agl := flight.y
	if world != null and world.height_field != null:
		agl = flight.y - world.height_field.height_at(flight.x, flight.z)
	s["altitude"] = maxf(0.0, agl)
	s["crashed_at"] = flight.crashed_at
	s["recovery_ms"] = FlightSim.RECOVERY_MS
	if _missiles != null and _missiles.has_method("stats"):
		s["missiles"] = _missiles.stats()
	return s


func mode_text() -> String:
	match mode:
		Mode.CAR: return "驾驶 · 轿车"
		Mode.TANK: return "驾驶 · 坦克"
		Mode.WALKING: return "步行" + ("（第一人称）" if _walk_first_person else "（第三人称）")
		Mode.OBSERVER: return "无人机观景"
		Mode.AIRCRAFT: return "飞行 · 观光水上飞机"
	return "未知"

func route_text() -> String:
	if not _pending_dest.is_empty():
		return "待出发 · %s · 按 M 打开地图选择驾驶方式" % _pending_dest["name"]
	if autopilot.active:
		var st := autopilot.status()
		return "自动导航 · %s · 剩余 %d 个路点" % [st["phase"], int(st["remaining"])]
	if rides.active_ride >= 0:
		var hint: Dictionary = rides.interaction_hint(_player_position_data(), speed())
		return str(hint.get("text", ""))
	var hint2: Dictionary = story.interaction_hint(_player_position_data(), speed(), mode == Mode.WALKING)
	if str(hint2.get("text", "")) != "":
		return str(hint2["text"])
	var hint3: Dictionary = rides.interaction_hint(_player_position_data(), speed())
	return str(hint3.get("text", ""))

func is_observer() -> bool:
	return mode == Mode.OBSERVER

## 地图是否要画浅绿路线：自动驾驶中，或已选好目的地正在等玩家选驾驶方式
## （原版两种情况下小地图都显示同一条浅绿线）
func has_route() -> bool:
	if autopilot.active:
		return true
	return _pending_route.size() >= 2

func route_points() -> PackedVector2Array:
	if autopilot.active:
		return autopilot.route_points()
	return _pending_route

## 接好自动驾驶的依赖（路网与三个回调），本身不启动
func _prepare_autopilot() -> void:
	autopilot.setup(world)
	autopilot.signal_hold = func(pos: Vector2, dir: Vector2) -> float:
		return world.signals.hold_distance(pos, dir) if world.signals != null else INF
	autopilot.blocked_fn = func(pos: Vector2) -> bool: return world.collision.blocked(pos.x, pos.y)
	autopilot.traffic_positions = func() -> Array:
		return world.traffic.positions() if world.traffic != null else []


func start_autopilot(target: Vector2) -> bool:
	_prepare_autopilot()
	_ap_arrived_toast = false
	_ap_blocked_toast = false
	var ok := autopilot.start(target, Vector2(car.x, car.z))
	if not ok:
		hud.toast("无法规划到该目的地的路线", 3.0)
	return ok


## 大地图上点选了目的地。
##
## 原版不是"点一下就开"：city-map 的 `onSelect` 会立刻算出 route 并在地图上
## 画出浅绿预览线，面板底部出现两个按钮「自动驾驶前往 ↗」/「自己开过去 →」，
## 玩家**点按钮**才走哪条路（main.ts onAutoDrive / onManualRoute，两者都先
## selectDestination 再 openMap(false)）—— 也就是地图保持打开，点了按钮才关。
## 这里同构：规划出预览线 → 地图留在屏幕上等玩家点按钮。
## 到达过的目的地（原版 visited 集合，地图侧栏「已发现」与「城市足迹」用）
var _last_dest_name := ""

func _on_destination_picked(pos: Vector2, dest_name: String) -> void:
	_last_dest_name = dest_name
	match mode:
		Mode.TANK:
			hud.toast("坦克使用手动驾驶，按 T 换回轿车再规划路线")
			return
		Mode.WALKING:
			hud.toast("走回车旁，按 F 上车后再规划路线")
			return
		Mode.OBSERVER, Mode.AIRCRAFT:
			hud.toast("退出当前视角后才能规划路线")
			return
		Mode.CAR:
			pass

	_prepare_autopilot()
	var preview := autopilot.plan(Vector2(car.x, car.z), pos)
	if preview.size() < 2:
		hud.toast("无法规划到该目的地的路线", 3.0)
		maps.clear_destination()
		return

	_pending_dest = {"pos": pos, "name": dest_name}
	_pending_route = preview
	# 地图不关：把两个按钮亮出来等玩家点（原版 .atlas-route-actions）
	maps.show_route_choice(dest_name)


## 玩家点了「自动驾驶前往 ↗」或「自己开过去 →」——关地图并执行
func _on_route_mode_chosen(auto_drive: bool) -> void:
	if maps.big_map_visible:
		maps.toggle_big_map()
	_choose_route_mode(auto_drive)


## 待选中的目的地与预览路线（原版 main.ts 的 `selected` / `route`）
var _pending_dest: Dictionary = {}
var _pending_route: PackedVector2Array = PackedVector2Array()
## 手动模式下判定"到达"的半径（比自动驾驶宽松，玩家自己停车）
const MANUAL_ARRIVE_RADIUS := 22.0


## 玩家点了「自动驾驶前往 ↗」（true）或「自己开过去 →」（false）
func _choose_route_mode(auto_drive: bool) -> void:
	if _pending_dest.is_empty():
		return
	var dest: Vector2 = _pending_dest["pos"]
	var dest_name := str(_pending_dest["name"])
	if auto_drive:
		_prepare_autopilot()
		_ap_arrived_toast = false
		_ap_blocked_toast = false
		# 预览线是从**选点那一刻**的车位算的。玩家若先自己开了一段再按 1，
		# 旧线起点已经对不上了 —— 这时让它重新规划（传空即触发重算）。
		var route := _pending_route
		if route.size() >= 2 and Vector2(car.x, car.z).distance_to(route[0]) > 50.0:
			route = PackedVector2Array()
		var ok := autopilot.start(dest, Vector2(car.x, car.z), route)
		if not ok:
			hud.toast("无法规划到该目的地的路线", 3.0)
			maps.clear_destination()
			_clear_pending()
			return
		# 路线交给 autopilot 显示，避免预览线与行驶线重复叠加
		_clear_pending()
		hud.toast("自动驾驶 · %s · WASD 随时接管" % dest_name, 4.0)
	else:
		# 自己开：确保没在自动驾驶（原版 cancelAutoDrive('manual-route')），
		# 但预览路线保留 —— 玩家沿它开
		if autopilot.active:
			autopilot.cancel()
		hud.toast("沿小地图上的浅绿路线行驶 · %s" % dest_name, 5.0)


func _clear_pending() -> void:
	_pending_dest = {}
	_pending_route = PackedVector2Array()


## 手动模式下开到目的地附近就算到达（自动驾驶由 autopilot 自己判定）
func _check_manual_arrival() -> void:
	if _pending_dest.is_empty() or autopilot.active:
		return
	if mode != Mode.CAR:
		return
	var dest: Vector2 = _pending_dest["pos"]
	if Vector2(car.x, car.z).distance_to(dest) < MANUAL_ARRIVE_RADIUS:
		hud.toast("已到达 %s" % _pending_dest["name"], 4.0)
		if not GameState.visited_destinations.has(_last_dest_name):
			GameState.visited_destinations.append(_last_dest_name)
			hud.toast("城市足迹 +1 · %s" % _last_dest_name, 3.0)
		maps.clear_destination()
		_clear_pending()

## 自动驾驶的阶段性提示（到达 / 受阻），每次启动只报一次
var _ap_arrived_toast := false
var _ap_blocked_toast := false

## 大地图「移动到附近道路」：把车挪到目的地附近的道路点（原版 quick-travel）
func _on_map_quick_travel(pos: Vector2) -> void:
	if mode != Mode.CAR:
		return
	var near: Dictionary = world.collision.nearest(pos.x, pos.y)
	var yaw := car.yaw
	if not near.is_empty():
		yaw = float(near.get("yaw", yaw))
	car.reset_to(pos.x, pos.y, yaw)
	_camera_yaw = yaw
	_flush_speed()
	if maps.big_map_visible:
		maps.toggle_big_map()
	hud.toast("已移动到附近道路")


## 大地图「俯瞰此处」：观景相机直接落在目的地上空（原版 photo-view）
func _on_map_photo(pos: Vector2) -> void:
	if maps.big_map_visible:
		maps.toggle_big_map()
	observer.begin(pos.x, world.height_field.height_at(pos.x, pos.y) + 60.0, pos.y, _camera_yaw)
	observer.ground_height = func(x: float, z: float) -> float: return world.height_field.height_at(x, z)
	observer.blocked = func(x: float, z: float) -> bool: return world.collision.blocked(x, z)
	# 与 _enter_observer 一样记录来源，退出时才能还原（大地图里点"俯瞰此处"时
	# 玩家可能是步行或开着坦克，不能一律退回车里）
	_pre_observer_mode = mode if mode != Mode.OBSERVER else _pre_observer_mode
	mode = Mode.OBSERVER
	autopilot.cancel()
	_clear_pending()
	# ⚠️ 不能在这里 paused = true：_update_modes 遇 paused 直接 return，
	# _step_observer 不跑、相机永远停在按按钮前的位置（原版观景也不暂停）。
	paused = false
	_flush_speed()
	camera.set_mode(ChaseCamera.Mode.OBSERVER, true)
	world.set_aerial(true)
	hud.toast("俯瞰模式：W/A/S/D 平移，Q/E 升降，Shift 加速，移动鼠标转向")


## 自动驾驶的阶段性提示（到达 / 受阻），每次启动只报一次
func _autopilot_phase_toasts() -> void:
	if autopilot.phase == Autopilot.Phase.ARRIVED and not _ap_arrived_toast:
		_ap_arrived_toast = true
		if _last_dest_name != "" and not GameState.visited_destinations.has(_last_dest_name):
			GameState.visited_destinations.append(_last_dest_name)
		maps.clear_destination()
		hud.toast("已到达目的地 · 自动驾驶结束", 4.0)
	elif autopilot.phase == Autopilot.Phase.BLOCKED and not _ap_blocked_toast:
		_ap_blocked_toast = true
		hud.toast("前方暂时无法通过，已尝试重新规划路线", 4.0)

func diagnostics() -> Dictionary:
	return {
		"ready": session_ready,
		"mode": mode_text(),
		"paused": paused,
		"position": [_player_position_data().x, _player_position_data().y],
		"speed": speed(),
		"camera": {"view": camera.view, "fov": camera.fov, "near": camera.near},
		"world": world.diagnostics(),
		"lighting": world.lighting.diagnostics() if world.lighting != null else {},
		"water": world.water.diagnostics() if world.water != null else {},
		"traffic": world.traffic.diagnostics() if world.traffic != null else {},
		"pedestrians": world.pedestrians.diagnostics() if world.pedestrians != null else {},
		"ebikes": world.ebikes.diagnostics() if world.ebikes != null else {},
		"signals": world.signals.diagnostics() if world.signals != null else {},
		"signs": world.signs.diagnostics() if world.signs != null else {},
		"scenery": world.scenery.diagnostics() if world.scenery != null else {},
		"distant": world.distant.diagnostics() if world.distant != null else {},
		"distantCity": world.distant_city.diagnostics() if world.distant_city != null else {},
		"facades": world.facades.diagnostics() if world.facades != null else {},
		"weather": world.weather.diagnostics() if world.weather != null else {},
		"career": career.status(),
		"story": story.status(),
		"rides": rides.status(),
		"audio": audio.diagnostics() if audio != null else {},
		"graphics": GraphicsQuality.profile(),
		"fps": Engine.get_frames_per_second(),
	}
