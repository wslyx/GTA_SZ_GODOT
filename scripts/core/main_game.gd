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
var _last_mouse := Vector2.ZERO
var _walk_first_person := false
var _car_model: Node3D
var _tank_model: Node3D
## 坦克实体炮塔 / 炮管节点（原版 city-tank.ts 的 turretTransform）。
## tank.glb 的层级是 tank_root → tank_turret(→ tank_barrel → 炮身各件)。
## 名称来自 GLB 的 node 表，导入后 Godot 保留原名。
var _tank_turret: Node3D
var _tank_barrel: Node3D
## 飞行导弹（原版 city-flight-missiles.ts）。首次起飞时才实例化，
## 6 个弹位 + 2 组爆炸的节点成本不进启动路径。
var _missiles = null
var _plane_model: Node3D
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
const RIDER_SCRIPT := preload("res://scripts/vehicles/rider.gd")
var _rider = null                   ## RIDER_SCRIPT 实例（untyped：全局类名未注册）
var _rider_yaw := 0.0               ## 角色 yaw 平滑跟随移动方向（原版 riderYaw）
var _pending_level_up_dialogue := {}


func _ready() -> void:
	# ⚠️ 加载界面必须先于任何重活出现。
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

	# 子系统（用 preload 而非 set_script，确保脚本一定被解析）
	world.sky = _add_system(SKY_SCRIPT, "SkySystem")
	world.lighting = _add_system(LIGHTING_SCRIPT, "LightingDirector")
	world.water = _add_system(WATER_SCRIPT, "BayWater")
	world.weather = _add_system(WEATHER_SCRIPT, "WeatherSystem")
	world.scenery = _add_system(SCENERY_SCRIPT, "ScenerySystem")
	world.signs = _add_system(SIGN_SCRIPT, "SignSystem")
	world.distant = _add_system(DISTANT_SCRIPT, "DistantSystem")
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
const SIGNALS_SCRIPT := preload("res://scripts/world/traffic_signals.gd")
const TRAFFIC_SCRIPT := preload("res://scripts/world/traffic_system.gd")
const PED_SCRIPT := preload("res://scripts/world/pedestrian_system.gd")
const EBIKE_SCRIPT := preload("res://scripts/world/ebike_system.gd")
const FACADE_SCRIPT := preload("res://scripts/world/facade_streamer.gd")
## ⚠️ 同 RIDER_SCRIPT：新增脚本的 class_name 要等编辑器重扫全局类缓存，
## 直接写 `FlightMissiles.new()` 会报 "Could not find type"，必须 preload。
const MISSILES_SCRIPT := preload("res://scripts/vehicles/flight_missiles.gd")

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
		if _tank_turret == null or _tank_barrel == null:
			push_warning("[MainGame] tank.glb 缺少炮塔/炮管节点，炮塔姿态不联动")
	if _plane_model != null:
		_plane_model.visible = false
	# 步行角色（原版 city-rider.ts 的久岐忍）。原版是按 F 下车时才异步加载
	# （提示"正在准备步行角色"）；这里文件在本地，直接在加载画面后面同步预载，
	# 首次按 F 不卡顿，12MB 模型的实例化成本也藏进了启动加载。
	_rider = RIDER_SCRIPT.new()
	_rider.name = "PlayerRider"
	add_child(_rider)
	_rider.setup()
	_rider.visible = false
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
	career.setup(world)
	rides.setup(world)
	story.setup(world, career)

	hud.setup(world, self)
	maps.setup(world, self)
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

	session_ready = true
	panels.finish_loading()
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
			_last_mouse = mb.position
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
					g.begin(0, mb.position.x, mb.position.y, mb.button_index,
						true, Input.is_key_pressed(KEY_SHIFT), float(Time.get_ticks_msec()))
				else:
					g.end(0)
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		var d := mm.position - _last_mouse
		_last_mouse = mm.position
		if mode == Mode.WALKING:
			if Input.is_key_pressed(KEY_SHIFT):
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
	elif event is InputEventMouseMotion:
		# 观察模式的长按计步：按住后移动超过 8px 就取消（把位移还给环绕/平移）
		if mode == Mode.OBSERVER and world != null and world.beacons != null \
				and not world.beacons.gesture.pointer.is_empty():
			var mm2 := event as InputEventMouseMotion
			world.beacons.gesture.move(0, mm2.position.x, mm2.position.y)


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
	match code:
		KEY_ESCAPE:
			if panels.dialog_active:
				panels.close_dialogue()
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
			# 于是飞上去之后就再也按不回无人机了）
			if mode == Mode.OBSERVER or mode == Mode.AIRCRAFT:
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


func _toggle_vehicle_entry() -> void:
	if mode == Mode.CAR or mode == Mode.TANK:
		var v := _vehicle_state()
		if absf(float(v["speed"])) > 1.0:
			hud.toast("先停稳再下车")
			return
		var offset := TANK_EXIT_OFFSET if mode == Mode.TANK else WALK_EXIT_OFFSET
		if not walk.exit_car(v, offset):
			hud.toast("车门旁边没有落脚点")
			return
		_last_ground_vehicle = Mode.TANK if mode == Mode.TANK else Mode.CAR
		if mode == Mode.TANK:
			if _tank_model != null:
				_tank_model.visible = false
		elif _car_model != null:
			_car_model.visible = false
		_flush_speed()
		mode = Mode.WALKING
		# 原版 exit-car 时取消自动驾驶
		autopilot.cancel()
		maps.clear_destination()
		_clear_pending()
		_walk_first_person = false
		# 原版 riderYaw = walk.yaw：模型先朝向下车时的视线方向，走起来再转向移动方向
		_rider_yaw = walk.yaw
		camera.set_mode(ChaseCamera.Mode.WALKING, true)
		hud.toast("%s · WASD 行走 / Shift 跑步 / 拖动环视 / 滚轮远近 / F 上车" % RIDER_SCRIPT.CHARACTER_NAME)
	elif mode == Mode.WALKING:
		# 回到下车前那一台（判据是 _last_ground_vehicle，不是模型的 visible）
		var want_tank := _last_ground_vehicle == Mode.TANK and _tank_model != null
		var v2: Dictionary
		if want_tank:
			v2 = {"x": tank.x, "z": tank.z, "yaw": tank.yaw, "speed": tank.speed}
		else:
			v2 = _vehicle_state()
		if not walk.can_enter(v2, 5.0, WALK_EXIT_OFFSET):
			hud.toast("走近车门再按 F 上车")
			return
		mode = Mode.TANK if want_tank else Mode.CAR
		_camera_yaw = walk.yaw
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
		walk.active = false
		if _rider != null:
			_rider.set_enabled(false)
		hud.toast("已上车 · C 切换驾驶镜头")

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

func _enter_observer() -> void:
	_pre_observer_mode = mode
	# 步行进观景：角色本体要收起来。_step_walk 是唯一管理 _rider 的地方，
	# 切到 OBSERVER 后它不再跑，不在这里显式隐藏的话角色会一直杵在地面上。
	if mode == Mode.WALKING:
		walk.active = false
		if _rider != null:
			_rider.set_enabled(false)
	# 飞行中进观景：必须先把飞机停掉，否则 flight 仍 active 而 mode 已不是
	# AIRCRAFT，_step_aircraft 不再跑，飞机模型会挂在天上不动。
	elif mode == Mode.AIRCRAFT:
		flight.stop()
		if _plane_model != null:
			_plane_model.visible = false
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
	hud.toast("观景模式：W/A/S/D 平移，Q/E 升降，Shift 加速，拖动转向；长按左键立光柱（I 前往 / O 收藏 / U 清除）", 6.0)

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
			if _rider != null:
				_rider.set_enabled(true)
			camera.set_mode(ChaseCamera.Mode.WALKING, true)
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
		# 收回飞机 → 回到无人机，并把无人机放到飞机所在的位置
		observer.begin(flight.x, maxf(flight.y, 80.0), flight.z, flight.yaw)
		mode = Mode.OBSERVER
		_pre_observer_mode = Mode.CAR
		camera.set_mode(ChaseCamera.Mode.OBSERVER, true)
		hud.toast("收回飞机，回到无人机")
		return
	flight.start(observer.x, maxf(observer.y, 240.0), observer.z, observer.yaw)
	if _plane_model != null:
		_plane_model.visible = true
	# 飞行期间由 _step_aircraft 接管，无人机先停：否则 observer.step 仍在跑，
	# 退出飞行时无人机会停在"飞机当前所在处"之外的地方。
	observer.end()
	mode = Mode.AIRCRAFT
	camera.set_mode(ChaseCamera.Mode.AIRCRAFT, true)
	hud.toast("飞行：W/S 俯仰，A/D 横滚，Q/E 方向舵，Shift 加速，X 减速")

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

	_update_modes(dt)
	_check_manual_arrival()

	# 焦点与分块剔除
	var focus := camera.global_position
	var p := _player_position_data()
	world.set_focus(CoordinateUtil.to_world(p.x, p.y, 0.0))

	# 光照跟随、路灯、招牌、立面流式
	if world.lighting != null:
		world.lighting.update_system(dt, focus)
	# 天空球跟随相机 —— 原版 atmosphere 是 infiniteDistance（永远在无限远），
	# Godot 里只能每帧把球心搬到相机上。**漏掉这一句的后果**：
	# 天空球（直径 8000）会永远停在世界原点，而玩家出生点距原点 2800m，
	# 于是朝外看时视线只打到球面赤道附近一条极窄的带 —— 着色器的
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
	if Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_ENTER):
		var shot := tank.fire()
		if not shot.is_empty():
			hud.toast("开炮", 1.0)

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
	_camera_yaw = lerp_angle(_camera_yaw, tank.yaw, 1.0 - exp(-dt * 3.0))
	camera.yaw = _camera_yaw
	camera.look_pitch = _look_pitch
	camera.follow_vehicle(Vector3(tank.x, 0.0, tank.z), tank.speed, dt, true, tank.yaw)
	lights.update_brake(handbrake, tank.speed < -0.5)
	lights.place(_tank_model.global_transform if _tank_model != null else camera.global_transform)

func _step_walk(dt: float) -> void:
	var before := Vector2(walk.x, walk.z)
	walk.step({
		"forward": Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP),
		"back": Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN),
		"left": Input.is_key_pressed(KEY_A),
		"right": Input.is_key_pressed(KEY_D),
		"run": Input.is_key_pressed(KEY_SHIFT),
		"left_arrow": Input.is_key_pressed(KEY_LEFT),
		"right_arrow": Input.is_key_pressed(KEY_RIGHT),
		"up_arrow": Input.is_key_pressed(KEY_UP),
		"down_arrow": Input.is_key_pressed(KEY_DOWN),
	}, dt)
	# 角色 yaw 平滑转向**移动方向**（原版 riderYaw，速率 exp(−dt·16)）；
	# 视线方向是 walk.yaw，由相机单独处理
	if walk.moving:
		var target := atan2(walk.x - before.x, walk.z - before.y)
		var delta := atan2(sin(target - _rider_yaw), cos(target - _rider_yaw))
		_rider_yaw += delta * (1.0 - exp(-dt * 16.0))
	var eye := walk.eye()
	walk_eye_world = CoordinateUtil.to_world(eye["x"], eye["z"], eye["y"])
	camera.walk_eye = walk_eye_world
	camera.yaw = walk.yaw
	camera.look_pitch = walk.pitch
	camera.follow_walk(dt, walk.camera_distance, _walk_first_person)
	# 角色本体：第三人称显示、第一人称隐藏（原版 setEnabled(walk.active && !firstPerson)）
	if _rider != null:
		_rider.set_enabled(mode == Mode.WALKING and not _walk_first_person)
		var ground := world.height_field.height_at(walk.x, walk.z)
		_rider.set_pose(
			CoordinateUtil.to_world(walk.x, walk.z, ground).x,
			ground,
			CoordinateUtil.to_world(walk.x, walk.z, ground).z,
			_rider_yaw, 0.0 if paused else walk.speed, dt)

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


## 飞行 / 导弹共用的扫掠回调（原版 city-flight.ts 的 sweep + FlightCityCollision）。
##
## ⚠️ 修过一个坐标 bug：FlightSim 的位姿是**数据坐标**（x 东 / z 北，与
## flight.start(observer.x, observer.z) 同源，机模也用 to_world(flight.x, flight.z)
## 摆放），而这里此前按世界坐标又做了一次 −mid.z 换算、并用 height_at_world
## 取高 —— 等于把撞击点镜像到南北对称的位置，撞楼与撞地都判在错误的一侧。
## 数据坐标直接喂给 collision.blocked 与 height_at 即可。
func _flight_sweep(from: Vector3, to: Vector3) -> Dictionary:
	var mid := (from + to) * 0.5
	if world.collision.blocked(mid.x, mid.z):
		return {"kind": "building", "point": {"x": mid.x, "y": mid.y, "z": mid.z}}
	if mid.y < world.height_field.height_at(mid.x, mid.z):
		return {"kind": "terrain", "point": {"x": mid.x, "y": mid.y, "z": mid.z}}
	return {}


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
		# ⚠️ 水上飞机模型的机头在 **-Z**，不是 +Z。
		# 实测：floatplane_propeller_mesh Z = -4.19（机身一端），
		# floatplane_airframe_fp_glass（座舱玻璃）Z = -0.52 —— 螺旋桨在座舱前方 3.7 m，
		# 是拉进式（tractor）布局，所以 -Z 才是机头。
		# 因此基的 z 轴取 **-fwd**（等价于绕 up 转 180°），y 轴仍取 up；
		# Godot 的 Basis(x, y, z) 要求右手系 x = y × z，cross 会自动把 x 一并翻过来。
		var z_axis := -fwd.normalized()
		var y_axis := (up - z_axis * up.dot(z_axis)).normalized()
		var x_axis := y_axis.cross(z_axis)
		_plane_model.global_transform = Transform3D(
			Basis(x_axis, y_axis, z_axis), world_pos)
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
	hud.toast("俯瞰模式：W/A/S/D 平移，Q/E 升降，Shift 加速，拖动转向")


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
		"facades": world.facades.diagnostics() if world.facades != null else {},
		"weather": world.weather.diagnostics() if world.weather != null else {},
		"career": career.status(),
		"story": story.status(),
		"rides": rides.status(),
		"audio": audio.diagnostics() if audio != null else {},
		"graphics": GraphicsQuality.profile(),
		"fps": Engine.get_frames_per_second(),
	}
