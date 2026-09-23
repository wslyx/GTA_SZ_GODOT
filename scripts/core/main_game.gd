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
var _plane_model: Node3D
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
	if _plane_model != null:
		_plane_model.visible = false

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
	# 大地图点选地标 → 自动驾驶前往（原版 city-map.ts 的 onAutoDrive）
	maps.destination_picked.connect(_on_destination_picked)
	# 大地图上「自动驾驶前往 / 自己开过去」两个按钮
	maps.route_mode_chosen.connect(_on_route_mode_chosen)
	maps.pick_failed.connect(func(reason: String): hud.toast(reason, 2.5))
	panels.setup(world, self, career, story)
	# 设置页的「帧率显示」行要操作 HUD
	panels.hud = hud

	# 出生点
	var sp := CityData.spawn_pos
	car.reset_to(sp.x, sp.y, CityData.spawn_yaw)
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
		KEY_F10:
			# CS2 风格图像设置页：打开即暂停，关闭即恢复
			panels.toggle_settings()
			paused = panels.settings_visible
		KEY_C:
			if mode == Mode.WALKING:
				_walk_first_person = not _walk_first_person
			else:
				camera.next_view()
		KEY_F:
			_toggle_vehicle_entry()
		KEY_T:
			_toggle_tank()
		KEY_G:
			if mode == Mode.OBSERVER:
				_exit_observer()
			else:
				_enter_observer()
		KEY_B:
			if mode == Mode.OBSERVER:
				_toggle_aircraft()
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
	elif mode == Mode.CAR:
		var c := _snap_to_road(car.x, car.z)
		car.reset_to(c.x, c.y, c.z)
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
		camera.set_mode(ChaseCamera.Mode.WALKING, true)
		hud.toast("步行：W/A/S/D 走，Shift 跑，C 换人称")
	elif mode == Mode.WALKING:
		var v2 := _vehicle_state()
		if not walk.can_enter(v2, 5.0, WALK_EXIT_OFFSET):
			hud.toast("走近车门再按 F 上车")
			return
		mode = Mode.TANK if _tank_model != null and _tank_model.visible else Mode.CAR
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
		hud.toast("上车")

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
	var p := _player_position_data()
	observer.begin(p.x, world.height_field.height_at(p.x, p.y) + 60.0, p.y, _camera_yaw)
	observer.ground_height = func(x: float, z: float) -> float: return world.height_field.height_at(x, z)
	observer.blocked = func(x: float, z: float) -> bool: return world.collision.blocked(x, z)
	mode = Mode.OBSERVER
	# 原版 observer 进入时取消自动驾驶
	autopilot.cancel()
	maps.clear_destination()
	_clear_pending()
	paused = true
	_flush_speed()
	camera.set_mode(ChaseCamera.Mode.OBSERVER, true)
	world.set_aerial(true)
	hud.toast("观景模式：W/A/S/D 平移，Q/E 升降，Shift 加速，拖动转向")

func _exit_observer() -> void:
	observer.end()
	mode = Mode.CAR if _car_model == null or _car_model.visible else Mode.TANK
	if _plane_model != null:
		_plane_model.visible = false
	flight.stop()
	paused = false
	world.set_aerial(false)
	camera.set_mode(ChaseCamera.Mode.DRIVING, true)
	hud.toast("已退出观景")

func _toggle_aircraft() -> void:
	if flight.active():
		flight.stop()
		if _plane_model != null:
			_plane_model.visible = false
		camera.set_mode(ChaseCamera.Mode.OBSERVER, true)
		hud.toast("收回飞机，回到无人机")
		return
	flight.start(observer.x, maxf(observer.y, 240.0), observer.z, observer.yaw)
	if _plane_model != null:
		_plane_model.visible = true
	camera.set_mode(ChaseCamera.Mode.AIRCRAFT, true)
	hud.toast("飞行：W/S 俯仰，A/D 横滚，Q/E 方向舵，Shift 加速，Space 导弹，X 减速")

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
	var speed := float(_vehicle_state()["speed"]) if mode in [Mode.CAR, Mode.TANK] else walk.speed
	rides.step(p, speed, absf(float(_vehicle_state()["speed"])) * dt if mode in [Mode.CAR, Mode.TANK] else 0.0)
	var res: Dictionary = career.step(dt, p, speed, false, false)
	if res.get("completed", false):
		hud.toast(str(res["message"]), 4.0)
		if audio != null:
			audio.cue("arrival")
		if not res["dialogue"].is_empty():
			_pending_level_up_dialogue = res["dialogue"]
			var opts: Array = res["dialogue"].get("options", [])
			panels.show_dialogue(str(res["dialogue"]["line"]), opts, "career")
	story.note_position(p)

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

	_place_car_model()
	_camera_yaw = lerp_angle(_camera_yaw, car.yaw, 0.08)
	camera.yaw = _camera_yaw
	camera.look_pitch = _look_pitch
	camera.follow_vehicle(Vector3(car.x, 0.0, car.z), car.speed, dt, false)
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
	_camera_yaw = lerp_angle(_camera_yaw, tank.yaw, 0.06)
	camera.yaw = _camera_yaw
	camera.look_pitch = _look_pitch
	camera.follow_vehicle(Vector3(tank.x, 0.0, tank.z), tank.speed, dt, true)
	lights.update_brake(handbrake, tank.speed < -0.5)
	lights.place(_tank_model.global_transform if _tank_model != null else camera.global_transform)

func _step_walk(dt: float) -> void:
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
	var eye := walk.eye()
	walk_eye_world = CoordinateUtil.to_world(eye["x"], eye["z"], eye["y"])
	camera.walk_eye = walk_eye_world
	camera.yaw = walk.yaw
	camera.look_pitch = walk.pitch
	camera.follow_walk(dt, walk.camera_distance, _walk_first_person)

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

func _step_aircraft(dt: float) -> void:
	var result: String = flight.step({
		"move_forward": Input.is_key_pressed(KEY_W),
		"move_back": Input.is_key_pressed(KEY_S),
		"steer_left": Input.is_key_pressed(KEY_A),
		"steer_right": Input.is_key_pressed(KEY_D),
		"turret_left": Input.is_key_pressed(KEY_Q),
		"turret_right": Input.is_key_pressed(KEY_E),
		"run": Input.is_key_pressed(KEY_SHIFT),
		"brake_tank": Input.is_key_pressed(KEY_X),
	}, dt, Time.get_ticks_msec(),
		func(from: Vector3, to: Vector3) -> Dictionary:
			var mid := (from + to) * 0.5
			var d := Vector2(mid.x, -mid.z)
			if world.collision.blocked(d.x, d.y):
				return {"kind": "building", "point": {"x": mid.x, "y": mid.y, "z": mid.z}}
			if mid.y < world.height_field.height_at_world(mid):
				return {"kind": "terrain", "point": {"x": mid.x, "y": mid.y, "z": mid.z}}
			return {},
		CityData.extent)

	if result == "crashed":
		hud.toast("飞机坠毁，3 秒后恢复为无人机", 3.0)
	elif result == "boundary":
		hud.toast("已到城市边界，自动返回")
		observer.x = flight.x
		observer.y = maxf(flight.y, 120.0)
		observer.z = flight.z
		camera.set_mode(ChaseCamera.Mode.OBSERVER, true)
	elif result == "recovered":
		observer.x = flight.last_safe.get("x", observer.x)
		observer.y = maxf(float(flight.last_safe.get("y", 120.0)), 80.0)
		observer.z = flight.last_safe.get("z", observer.z)
		if _plane_model != null:
			_plane_model.visible = false
		camera.set_mode(ChaseCamera.Mode.OBSERVER, true)

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
	_car_model.global_transform = Transform3D(
		Basis(Vector3.UP, CoordinateUtil.node_yaw(car.yaw, CoordinateUtil.ModelForward.MINUS_Z)),
		CoordinateUtil.to_world(car.x, car.z, g + 0.02))

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
		var s: Dictionary = sres["step"]
		panels.show_dialogue(str(s["text"]), s.get("options", []), "story")
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
			var s: Dictionary = r["step"]
			panels.show_dialogue(str(s["text"]), s.get("options", []), "story")
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
func _on_destination_picked(pos: Vector2, dest_name: String) -> void:
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
		maps.clear_destination()
		_clear_pending()

## 自动驾驶的阶段性提示（到达 / 受阻），每次启动只报一次
var _ap_arrived_toast := false
var _ap_blocked_toast := false

func _autopilot_phase_toasts() -> void:
	if autopilot.phase == Autopilot.Phase.ARRIVED and not _ap_arrived_toast:
		_ap_arrived_toast = true
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
