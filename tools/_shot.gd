extends Node
##
## 截图探针（可批量扫参数）。
##
## 一次启动即可抓多组：读 tools/shot_plan.json，按 shots[] 顺序逐项
## 覆盖环境参数 → 等 gap 秒 → 抓图。避免「改一次参数重跑 40 秒」。
##
## 用法：
##   Godot_v4.7.1-stable_win64_console.exe --path . --resolution 1920x1124 \
##       res://tools/_shot.tscn
##
## shot_plan.json 结构：
##   { "warmup": 6.0, "gap": 1.2,
##     "shots": [ {"name":"baseline"}, {"name":"noglow","env":{"glow_enabled":false}} ] }

const OUT_DIR := "D:/CodePro/game_ws/GTA_SZ_GODOT/tools/shots"
const PLAN_PATH := "D:/CodePro/game_ws/GTA_SZ_GODOT/tools/shot_plan.json"

var main: Node = null
var plan: Dictionary = {}
var shots: Array = []
var warmup := 6.0
var gap := 1.2

var started := false
var t := 0.0
var idx := 0
var finished := false


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	plan = _read_plan()
	warmup = float(plan.get("warmup", 6.0))
	gap = float(plan.get("gap", 1.2))
	shots = plan.get("shots", [])
	if shots.is_empty():
		shots = [{"name": "shot"}]
	var scene: PackedScene = load("res://scenes/main.tscn")
	if scene == null:
		printerr("[shot] 主场景加载失败")
		get_tree().quit(1)
		return
	main = scene.instantiate()
	add_child(main)
	print("[shot] 主场景已加入，窗口 %dx%d，方案 %d 张，warmup %.1fs gap %.1fs" % [
		get_viewport().get_visible_rect().size.x,
		get_viewport().get_visible_rect().size.y, shots.size(), warmup, gap])


func _read_plan() -> Dictionary:
	if not FileAccess.file_exists(PLAN_PATH):
		push_warning("[shot] 无 shot_plan.json，用默认单张")
		return {}
	var f := FileAccess.open(PLAN_PATH, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[shot] shot_plan.json 解析失败")
		return {}
	return parsed


func _process(delta: float) -> void:
	if finished or main == null:
		return
	if not started:
		if not bool(main.get("session_ready")):
			return
		started = true
		t = 0.0
		print("[shot] session_ready 达成")
		return
	t += delta
	if idx == 0 and t < warmup:
		return
	if idx >= shots.size():
		finished = true
		print("[shot] 全部完成")
		get_tree().quit(0)
		return
	if idx > 0:
		# 每张之间还要等 gap（第一张已经等过 warmup）
		if t < warmup + gap * idx:
			return
	var shot: Dictionary = shots[idx]
	_apply_env(shot.get("env", {}))
	print("[shot] #%d %s <- %s" % [idx + 1, str(shot.get("name", "")), JSON.stringify(shot.get("env", {}))])
	if bool(shot.get("dump_ui", false)):
		dump_ui()
	idx += 1
	_capture(str(shot.get("name", "shot")))


## 覆盖环境参数。键名直接对应 Environment 的属性名，另外支持几个快捷键：
##   sun_energy  → DirectionalLight3D.light_energy
##   sky_energy  → PanoramaSkyMaterial.energy_multiplier
##   sky_gain    → 天空球着色器的显示增益
##
## ⚠️ 每张图都会**先重置**再覆盖。否则覆盖是累积的：第 2 张关了太阳，
## 第 3 张只改天空时太阳仍然是关的，扫出来的曲线会互相污染。
func _apply_env(overrides: Dictionary) -> void:
	_reset_env()
	if overrides.is_empty():
		return
	var world = main.get("world")
	if world == null:
		push_warning("[shot] world 尚未就绪，忽略覆盖")
		return
	var lighting = world.get("lighting")
	if lighting == null:
		return
	var env_node = lighting.get("env_node")
	if env_node == null:
		return
	var env: Environment = env_node.environment
	if env == null:
		return
	for k in overrides.keys():
		var key := str(k)
		var value = overrides[k]
		match key:
			"sun_energy":
				var sun = lighting.get("sun")
				if sun != null:
					sun.light_energy = float(value)
			"sky_energy":
				if env.sky != null and env.sky.sky_material is PanoramaSkyMaterial:
					(env.sky.sky_material as PanoramaSkyMaterial).energy_multiplier = float(value)
			"sky_gain":
				var sky = world.get("sky")
				if sky != null and sky.get("sky_material") != null:
					(sky.get("sky_material") as ShaderMaterial).set_shader_parameter(
						"sky_gain", float(value))
			"tier":
				# 画质档位（low/medium/high）。存档里的档位会改阴影/SSAO/路灯池，
				# 想和原版截图（画质·中）对齐就得显式指定。
				GraphicsQuality.set_tier(str(value))
				GraphicsQuality.apply_to_world(world)
			"exposure":
				GraphicsQuality.set_override("exposure", float(value))
				lighting.call("apply_mode", GameState.light_mode)
			_:
				if key in env:
					env.set(key, value)
				else:
					push_warning("[shot] Environment 无此属性：%s" % key)


## 恢复"出厂状态"：重放当前光照模式（会把太阳能量、曝光、辉光、全景能量
## 一起按 LOOK 表重新赋值），并把天空增益复位。
func _reset_env() -> void:
	var world = main.get("world")
	if world == null:
		return
	var lighting = world.get("lighting")
	if lighting != null and lighting.has_method("apply_mode"):
		lighting.call("apply_mode", GameState.light_mode)
	var sky = world.get("sky")
	# 调 sky.apply_mode 而不是直接写 uniform —— 增益常量在 SkySystem 里，
	# 这样"重置"永远等于游戏的真实出厂状态，不会和代码里的值脱节。
	if sky != null and sky.has_method("apply_mode"):
		sky.call("apply_mode", GameState.light_mode)


func _capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, name]
	var err := img.save_png(path)
	print("[shot] %s  %dx%d  err=%d" % [path, img.get_width(), img.get_height(), err])


## 把关键 UI 节点的可见性 / 位置 / 尺寸 / 文本打到日志。
## 截图里"某个元素没出现"时，靠这个区分是没建、还是建了但尺寸为 0。
func dump_ui() -> void:
	dump_state()
	var maps = main.get("maps")
	if maps == null:
		print("[ui] maps 为 null")
		return
	for prop in ["minimap_holder", "minimap", "minimap_overlay", "_road_label"]:
		var n = maps.get(prop)
		if n == null:
			print("[ui] %s = null" % prop)
			continue
		var line := "[ui] %s visible=%s pos=%s size=%s" % [
			prop, str(n.visible), str(n.position), str(n.size)]
		if n is Label:
			line += " text='%s' font=%s" % [str((n as Label).text), str((n as Label).get_theme_font("font"))]
		print(line)


## 出生点体检：把"数据侧的出生点"与"运行时车/相机的实际位姿"并排打出来。
## 判定"启动位置是否与原版一致"就靠这一段。
func dump_state() -> void:
	var car = main.get("car")
	var camera = main.get("camera")
	print("[state] 数据出生点 spawn = (%.3f, %.3f) yaw=%.4f road=%s" % [
		CityData.spawn_pos.x, CityData.spawn_pos.y, CityData.spawn_yaw, CityData.spawn_road])
	if car == null:
		print("[state] car 为 null")
		return
	print("[state] 车 数据坐标 = (%.3f, %.3f) yaw=%.4f  speed=%.3f" % [
		car.x, car.z, car.yaw, car.speed])
	print("[state] 车 世界坐标 = %s" % str(CoordinateUtil.to_world(car.x, car.z, 0.0)))
	print("[state] 车 世界朝向 = %s  (数据 yaw → world 方向)" % str(CoordinateUtil.yaw_to_direction(car.yaw)))
	if camera != null:
		# camera 是 `main.get()` 拿到的 Variant，属性访问也都是 Variant，
		# 所以这里每一步都显式标注类型，否则 `:=` 会被判为编译错误。
		var cam_pos: Vector3 = camera.global_position
		var cam_basis: Basis = camera.global_transform.basis
		var fwd: Vector3 = -cam_basis.z
		var cam_fov: float = camera.fov
		var cam_near: float = camera.near
		print("[state] 相机 世界位置 = %s" % str(cam_pos))
		print("[state] 相机 世界前向 = (%.3f, %.3f, %.3f)  fov=%.2f°  near=%.3f" % [
			fwd.x, fwd.y, fwd.z, cam_fov, cam_near])
		var car_world := CoordinateUtil.to_world(car.x, car.z, 0.0)
		var back: Vector3 = cam_pos - car_world
		print("[state] 相机相对车 = %s  水平距离 %.2f m  高度差 %.2f m" % [
			str(back), Vector2(back.x, back.z).length(), cam_pos.y - car_world.y])
	var world = main.get("world")
	if world != null:
		var hf = world.get("height_field")
		if hf != null:
			print("[state] 车所在处地面高度 = %.3f" % hf.call("height_at", car.x, car.z))
