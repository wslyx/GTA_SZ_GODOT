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
## 应用参数后到截图之间的等待（光照档是约 2s 的插值过渡，必须等它收敛）
var settle := 2.5
## 已应用的张数（与 idx = 下一张要应用的下标 配合，把"应用"和"截图"分成两步）
var _applied := 0
var _apply_t := 0.0

var started := false
var t := 0.0
var idx := 0
var finished := false


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	plan = _read_plan()
	warmup = float(plan.get("warmup", 6.0))
	gap = float(plan.get("gap", 1.2))
	settle = float(plan.get("settle", 2.5))
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


## ⚠️ 时序：**应用参数 → 等 settle 秒 → 再截图**。
##
## 此前是"应用完立刻截"，而光照档（L）是约 2 秒的连续过渡（太阳/雾/曝光/辉光
## 都是插值），于是每张图拍到的其实是**上一档**的画面 —— 实测证据：一张
## light_mode=0 与一张 light_mode=2 的截图逐像素差只有 0.073，而 light_mode=0
## 的图与 light_mode=1 的图差了 0.19（v_day 拍到的是日落）。
## settle 默认 2.5s（> 过渡时长），可在 shot_plan.json 里覆盖。
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
	if idx >= shots.size():
		if _applied >= shots.size():
			finished = true
			print("[shot] 全部完成")
			get_tree().quit(0)
		return
	# 1) 到点就应用这一张的参数
	if _applied == idx and t >= warmup + gap * float(idx):
		var shot: Dictionary = shots[idx]
		_apply_env(shot.get("env", {}))
		print("[shot] #%d %s <- %s" % [idx + 1, str(shot.get("name", "")),
			JSON.stringify(shot.get("env", {}))])
		if bool(shot.get("dump_ui", false)):
			dump_ui()
		if bool(shot.get("dump_materials", false)):
			dump_materials()
		_applied = idx + 1
		_apply_t = t
		return
	# 2) 过渡收敛后再截图（顺带处理"必须在曝光前一刻发生"的项）
	if _applied == idx + 1 and t >= _apply_t + settle:
		_late_env(shots[idx].get("env", {}))
		_capture(str(shots[idx].get("name", "shot")))
		idx += 1


## 建筑材质体检：按 (材质类, 反照率, 是否有贴图) 聚合，看空中/街面看到的
## 建筑到底用的什么材质 —— "白天建筑洗白"这类问题靠它定位。
func dump_materials() -> void:
	var w = main.get("world")
	if w == null:
		print("[mat] world 为 null")
		return
	var stat := {}
	for root_name in ["buildings_root", "facades_root", "landmarks_root", "chunks_root"]:
		var root = w.get(root_name)
		if root == null:
			continue
		var stack: Array = [root]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			var mesh: Mesh = null
			var override_mat: Material = null
			if n is MeshInstance3D:
				mesh = (n as MeshInstance3D).mesh
				override_mat = (n as MeshInstance3D).material_override
			# ⚠️ 实际渲染用的是**逐 surface 的 override**（architecture_materials.gd
			# 用 set_surface_override_material 接管），源材质只是底稿。第一版探针
			# 只读了 material_override / surface_get_material，量到的是"白底稿"，
			# 得出了错误结论。
			var mat: Material = override_mat
			if mesh != null and mesh.get_surface_count() > 0:
				var so := (n as MeshInstance3D).get_surface_override_material(0)
				if so != null:
					mat = so
				elif mat == null:
					mat = mesh.surface_get_material(0)
			if mat != null:
				var vc := "-"
				if mat is StandardMaterial3D:
					vc = "%s/uvc=%s" % [
						str((mat as StandardMaterial3D).albedo_color),
						str((mat as StandardMaterial3D).vertex_color_use_as_albedo)]
				elif mat is ShaderMaterial:
					vc = "tex=%s" % str((mat as ShaderMaterial).get_shader_parameter("use_albedo_tex"))
				var key := "%s|%s" % [mat.get_class(), vc]
				stat[key] = int(stat.get(key, 0)) + 1
			for c in n.get_children():
				stack.append(c)
	var by_class := {}
	for k in stat.keys():
		var cls := str(k).split("|")[0]
		by_class[cls] = int(by_class.get(cls, 0)) + int(stat[k])
	for cls in by_class.keys():
		print("[mat-class] %s = %d" % [cls, int(by_class[cls])])
	var keys: Array = stat.keys()
	keys.sort_custom(func(a, b): return int(stat[a]) > int(stat[b]))
	for k in keys.slice(0, min(12, keys.size())):
		print("[mat] %4d  %s" % [int(stat[k]), k])


## 必须在**截图前一刻**执行的动作。
## `fire` 走这里：导弹 6 秒就寿终，若在应用参数时就发射，settle 2.5s 后它已经
## 飞出 700m，画面里什么都没有。
func _late_env(overrides: Dictionary) -> void:
	if bool(overrides.get("fire", false)) and main.has_method("fire_missile"):
		main.call("fire_missile")


## 覆盖环境参数。键名直接对应 Environment 的属性名，另外支持几个快捷键：
##   sun_energy  → DirectionalLight3D.light_energy
##   sky_energy  → PanoramaSkyMaterial.energy_multiplier
##   sky_gain    → 天空球着色器的显示增益（只影响程序化兜底路径）
##   sunset_bg_gain → 日落档摄影 HDR 可见天空的显示增益（原版 primaryColor）
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
			"light_mode":
				# 光照档（0 白天 / 1 日落 / 2 夜晚）：瞬时套用并同步 GameState，
				# 让后续 _reset_env 重放同档（过渡要等 gap 秒后再抓下一张）
				GameState.set_light_mode(int(value))
				lighting.call("apply_mode", int(value))
			"hide":
				# 隐藏 world 上的子系统节点（distant / facades / traffic …）定位遮挡物
				var w = main.get("world")
				if w != null:
					var nd = w.get(str(value))
					if nd is Node3D:
						(nd as Node3D).visible = false
					else:
						push_warning("[shot] world 上没有 %s" % str(value))
			"fxaa":
				# 屏幕空间抗锯齿开关（FXAA 会影响全屏细节观感）
				GraphicsQuality.set_override("aa", 1 if bool(value) else 0)
				GraphicsQuality.apply_aa()
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
			"mode":
				# 玩家模式切换（car / tank / observer / aircraft），用来截坦克炮塔
				# 与飞行 HUD —— 这两个都是"只在特定模式下才画"的东西。
				# 走游戏自己的入口（不直接改 mode 字段，免得漏掉相机同步），
				# 但入口是 **toggle**：已经在目标模式里就不要点了，否则会切回去
				# （本轮实测：连续两张 "mode":"aircraft" 的第二张其实切回了无人机，
				#  于是"带导弹的图"与"飞行图"逐像素相同）。
				# Mode 枚举：CAR 0 / TANK 1 / WALKING 2 / OBSERVER 3 / AIRCRAFT 4
				var want := {"car": 0, "tank": 1, "walking": 2, "observer": 3, "aircraft": 4}
				var target := str(value)
				if not want.has(target):
					push_warning("[shot] 未知模式 %s" % target)
				elif int(main.get("mode")) != int(want[target]):
					match target:
						"tank": main.call("_toggle_tank")
						"observer": main.call("_enter_observer")
						"aircraft": main.call("_toggle_aircraft")
						_: pass
			"aim":
				# 坦克炮塔/炮管指向 [turret_yaw, barrel_pitch]，用来验证
				# "炮塔节点联动"是否真的转到了模型上（默认炮口朝前，看不出来）。
				var tk = main.get("tank")
				if tk != null and value is Array and (value as Array).size() >= 2:
					tk.set("turret_yaw", float(value[0]))
					tk.set("barrel_pitch", float(value[1]))
			"vertex_colors":
				# 诊断用：把顶点色开关强行设成指定值，用于 A/B 量化
				# "blocks 的 COLOR_0 到底影响了多少亮度"。
				var w3 = main.get("world")
				var n3 := 0
				var visited := 0
				var colored := 0
				for rn in ["buildings_root", "chunks_root", "facades_root", "landmarks_root"]:
					var rt = w3.get(rn)
					if rt == null:
						continue
					for mi in GlbLoader.meshes_of(rt):
						visited += 1
						if mi.mesh == null:
							continue
						for s2 in mi.mesh.get_surface_count():
							if (int(mi.mesh.surface_get_format(s2)) & Mesh.ARRAY_FORMAT_COLOR) == 0:
								continue
							colored += 1
							var mm: Material = mi.get_surface_override_material(s2)
							if mm == null:
								mm = mi.mesh.surface_get_material(s2)
							if mm is StandardMaterial3D:
								(mm as StandardMaterial3D).vertex_color_use_as_albedo = bool(value)
								n3 += 1
				print("[shot] vertex_colors -> %s (改了 %d 材质 / 扫过 %d 网格 / 命中 COLOR 的表面 %d)" % [
					str(value), n3, visited, colored])
			"rain":
				# 雨天开关（走 WeatherSystem.toggle，会顺带切 RAIN_ROAD_LOOK
				# 与低画质档的 SSR 兜底）
				var wx = world.get("weather")
				if wx != null and bool(value) != bool(wx.get("raining")):
					wx.call("toggle")
			"fire":
				# 发射一枚导弹（实际执行时机见 _late_env —— 必须在截图前一刻）
				if main.has_method("fire_missile"):
					main.call("fire_missile")
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
	# 天空诊断：所有 WorldEnvironment / 天空球网格 / Sky 材质
	var w = main.get("world")
	if w == null:
		return
	for we in find_children("*", "WorldEnvironment", true, false):
		var env: Environment = (we as WorldEnvironment).environment
		if env == null:
			continue
		var mat_desc := "null"
		if env.sky != null and env.sky.sky_material != null:
			var sm = env.sky.sky_material
			if sm is ShaderMaterial:
				var sh: Shader = (sm as ShaderMaterial).shader
				mat_desc = "ShaderMaterial(%s)" % (sh.resource_path if sh != null else "null")
				var sp: ShaderMaterial = sm as ShaderMaterial
				print("[sky-uniform] sky_mode=%s sky_gain=%s sunset_bg_gain=%s sunset_uses_hdr=%s env_blend=%s mode_a=%s mode_b=%s base_energy=%s" % [
					str(sp.get_shader_parameter("sky_mode")),
					str(sp.get_shader_parameter("sky_gain")),
					str(sp.get_shader_parameter("sunset_bg_gain")),
					str(sp.get_shader_parameter("sunset_uses_hdr")),
					str(sp.get_shader_parameter("env_blend")),
					str(sp.get_shader_parameter("mode_a")),
					str(sp.get_shader_parameter("mode_b")),
					str(sp.get_shader_parameter("base_energy"))])
			else:
				mat_desc = sm.get_class()
		print("[sky] %s bg=%d sky_mat=%s ambient_src=%d" % [
			we.name, env.background_mode, mat_desc, env.ambient_light_source])
	for mi in find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		var n := String(mi.name).to_lower()
		if "sky" in n or "atmosphere" in n or "night" in n:
			var mesh_desc := "null"
			if m.mesh is SphereMesh:
				var sp := m.mesh as SphereMesh
				mesh_desc = "SphereMesh r=%.0f seg=%d rings=%d" % [sp.radius, sp.radial_segments, sp.rings]
			print("[sky-mesh] %s visible=%s mesh=%s pos=%s" % [mi.name, m.visible, mesh_desc, m.global_position])
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
