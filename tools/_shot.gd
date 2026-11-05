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

## ⚠️ 路径**不要写绝对盘符**：项目从 D:\CodePro\game_ws 迁到 E:\CodePro\godot_fps_demo
## 之后，写死的 "D:/CodePro/game_ws/..." 会让 make_dir_recursive_absolute 直接失败、
## save_png 静默不落盘 —— 截完一堆图却一个文件都没有。用 res:// 全局化跟随项目根。
var _out_dir := ""
var _plan_path := "res://tools/shot_plan.json"
var _fps_probe := false

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
	# 方案文件可用环境变量覆盖，方便一份探针跑多套计划（不必反复改 shot_plan.json）
	var plan_env := OS.get_environment("SHOT_PLAN")
	if not plan_env.is_empty():
		_plan_path = plan_env
	_out_dir = ProjectSettings.globalize_path("res://tools/shots")
	DirAccess.make_dir_recursive_absolute(_out_dir)
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
	if not FileAccess.file_exists(_plan_path):
		push_warning("[shot] 无 shot_plan.json，用默认单张")
		return {}
	var f := FileAccess.open(_plan_path, FileAccess.READ)
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
		# 用 `== true` 而不是 bool(...)：主场景脚本解析失败时 get() 会返回 null，
		# 而 GDScript 的 bool(null) 会直接抛 "Nonexistent 'bool' constructor"，
		# 每帧抛一次 —— 实测刷了 43 万行、把 700s 超时耗光才停。
		if main.get("session_ready") != true:
			t += delta
			if t > warmup + 90.0:
				push_error("[shot] 等 session_ready 超时（%.0fs）：主场景可能没装载成功"
					% (warmup + 90.0))
				get_tree().quit(1)
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
		# fps_probe：截图前先量 2 秒平均帧率（定点性能复现用）
		if _fps_probe:
			var __f0 := Engine.get_frames_per_second()
			var __acc := 0.0
			var __n := 0
			var __t0 := Time.get_ticks_msec()
			while Time.get_ticks_msec() - __t0 < 2000:
				await get_tree().process_frame
				__acc += float(Engine.get_frames_per_second())
				__n += 1
			print("[fps-probe] %s 平均 FPS=%.1f（采样 %d 帧）" % [
				str(shots[idx].get("name", "?")), __acc / maxf(1.0, float(__n)), __n])
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
	# 诊断（截图时刻打印，此时物理/相机已落位）
	if overrides.has("diag"):
		var car_d = main.get("car")
		var model_d = main.get("_car_model")
		var cam_d = get_viewport().get_camera_3d()
		var hf = main.get("world")
		var walk_o = main.get("walk")
		var walk_x := -1.0
		var walk_z := -1.0
		var walk_spd := 0.0
		if walk_o != null:
			walk_x = float(walk_o.get("x"))
			walk_z = float(walk_o.get("z"))
			walk_spd = float(walk_o.get("speed"))
		if car_d != null and cam_d != null and hf != null:
			var cx: float = float(car_d.get("x"))
			var cz: float = float(car_d.get("z"))
			var spd: float = float(car_d.get("speed")) if car_d.get("speed") != null else 0.0
			var apph: int = int(main.get("autopilot").get("phase")) if main.get("autopilot") != null else -1
			var my: float = model_d.global_position.y if model_d != null else -999.0
			var cp: Vector3 = cam_d.global_position
			var hf_h: float = float(hf.call("ground_height_data", cx, cz))
			var hf_hc: float = float(hf.call("ground_height_data", cp.x, -cp.z))
			print("[diag] car data=(%.1f,%.1f) 速度=%.1f ap相位=%d | walk=(%.1f,%.1f) w速度=%.1f | cam world=(%.1f, %.2f, %.1f) hf=%.2f 相机-hf=%.2f | mouse_mode=%d | obj=%d nodes=%d stat=%.0fMB vram=%.0fMB" % [
				cx, cz, spd, apph,
				walk_x, walk_z, walk_spd,
				cp.x, cp.y, cp.z, hf_hc, cp.y - hf_hc,
				Input.mouse_mode,
				Performance.get_monitor(Performance.OBJECT_COUNT),
				get_tree().get_node_count(),
				Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
				float(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)) / 1048576.0])
			# ---- 碰撞/物理自动验收（grep [ANOMALY]）----
			# 1) 车辆悬浮/陷地：模型 y 与高度场差 >0.5m（悬挂行程 ~0.1-0.3m）
			if my > -900.0 and absf(my - hf_h) > 0.5:
				print("[ANOMALY] 车辆悬浮/陷地 Δy=%.2f (模型y=%.2f hf=%.2f) @ (%.0f,%.0f)"
					% [my - hf_h, my, hf_h, cx, cz])
			# 2) 车辆位置在碰撞格内（穿墙/穿建筑）
			var col = hf.get("collision")
			if col != null and col.call("blocked", cx, cz):
				print("[ANOMALY] 车辆位于碰撞格内 @ (%.0f,%.0f)" % [cx, cz])
			# 3) 速度突变（碰撞弹飞/穿透回弹）
			if _prev_speed >= 0.0 and absf(spd - _prev_speed) > 15.0:
				print("[ANOMALY] 速度突变 %.1f→%.1f @ (%.0f,%.0f)" % [_prev_speed, spd, cx, cz])
			_prev_speed = spd
			# 4) ALS 角色悬浮/陷地（步行中才查；walk_spd>0.5 视为在动）
			if walk_spd > 0.5:
				var host4 = main.get("_als_host")
				if host4 != null:
					var mp = host4.get("MotorPosition")
					if mp != null:
						var gy := float(hf.call("ground_height_data", mp.x, -mp.z))
						if absf(mp.y - 0.9 - gy) > 0.6:
							print("[ANOMALY] ALS 角色悬浮/陷地 Δy=%.2f (马达y=%.2f 地面=%.2f)"
								% [mp.y - 0.9 - gy, mp.y, gy])
	# 长焦：截图前一刻暂停物理（相机不再被追尾逻辑每帧改写）再改 fov，
	# 用来把远处地标的细节拉近看。
	if overrides.has("zoom") and main.has_method("get"):
		main.set("paused", true)
		var cam = main.get("camera")
		if cam != null:
			cam.set("fov", float(overrides["zoom"]))
			print("[shot] fov -> %.1f（已暂停物理）" % float(overrides["zoom"]))
	# 座舱仪表注值：[speed_mps, steer, trip_m] —— 截图前一刻写入并暂停物理，
	# 否则下一帧就被真实值（停车 0 km/h）覆盖，只能拍到 000
	if overrides.has("cockpit_probe") and main.has_method("debug_cockpit_telemetry"):
		var v: Array = overrides["cockpit_probe"]
		if v.size() >= 3:
			main.call("debug_cockpit_telemetry", float(v[0]), float(v[1]), float(v[2]))


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
			"hide_world":
				# 终局二分：把整个 CityWorld 藏掉，看白板是否还在（区分 world 内/外）
				var w3 = main.get("world")
				if w3 is Node3D:
					(w3 as Node3D).visible = false
					print("[shot] CityWorld 已整体隐藏")
			"hide_named":
				# 按名字前缀隐藏网格（找遮挡物/验证"白板是谁"用）：搜 world 各根 + main 直挂
				if value is String and not value.is_empty():
					var w2 = main.get("world")
					var n_hidden := 0
					var stk: Array = []
					for root_name in ["landmarks_root", "terrain_root", "buildings_root",
						"facades_root", "chunks_root", "scenery_root"]:
						var rt = w2.get(root_name)
						if rt != null:
							stk.append(rt)
					for ch0 in main.get_children():
						stk.append(ch0)
					while not stk.is_empty():
						var nd: Node = stk.pop_back()
						for ch in nd.get_children():
							stk.append(ch)
						if nd is MeshInstance3D and String(nd.name).to_lower().begins_with(value):
							(nd as MeshInstance3D).visible = false
							n_hidden += 1
					print("[shot] 已隐藏 %s × %d" % [value, n_hidden])
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
			"quality":
				# 逐项画质覆盖（键同 GraphicsQuality.overrides），设置后按当前
				# 档位整套重套 —— 对照实验用：{"shadows":0} 关阴影、{"ao":false} 关 SSAO。
				if value is Dictionary:
					var qd: Dictionary = value
					for qk in qd.keys():
						GraphicsQuality.set_override(str(qk), qd[qk])
					GraphicsQuality.apply_to_world(world)
					print("[shot] quality 覆盖 %s 已重套" % JSON.stringify(value))
			"debug_draw":
				# 视口调试渲染模式（0 正常 / 1 unshaded / 2 lighting / 3 overdraw）。
				# unshaded 一刀切分"着色差异 vs 几何/贴图差异"。
				get_viewport().debug_draw = int(value)
				print("[shot] debug_draw -> %d" % int(value))
			"vehicle_probe":
				# 车漆反射探针开关（同一次运行内 A/B，排除运行间天空差异）。
				# true=启用（默认），false=set_enabled(false) 关掉探针影响。
				var vr = main.get("_vehicle_reflections")
				if vr != null and vr.has_method("set_enabled"):
					vr.set_enabled(bool(value))
					print("[shot] vehicle_probe -> %s" % str(bool(value)))
				else:
					print("[shot] vehicle_probe: 未找到 VehicleReflections 节点")
			"tree_stat":
				# 全树节点名直方图（查节点泄露：前后两次对比 diff）
				var w7 = main.get("world")
				if w7 != null:
					var hist := {}
					var total7 := 0
					var stk7: Array = [w7]
					while not stk7.is_empty():
						var nd7: Node = stk7.pop_back()
						for ch7 in nd7.get_children():
							stk7.append(ch7)
						total7 += 1
						var nm := String(nd7.name)
						var nkey := nm
						var p7 := nm.find("-")
						if p7 > 0:
							nkey = nm.substr(0, p7 + 1)
						hist[nkey] = int(hist.get(nkey, 0)) + 1
					var keys := hist.keys()
					keys.sort()
					for hk in keys:
						if int(hist[hk]) >= 3:
							print("[tree] %-28s × %d" % [str(hk), int(hist[hk])])
					print("[tree] (总节点 %d)" % total7)
			"tree_dump":
				# chunks_root 全路径清单（精确 diff 区块重载泄露：hop1 vs hopN）
				var w8 = main.get("world")
				var cr = w8.get("chunks_root") if w8 != null else null
				if cr != null:
					var cnt8 := 0
					var stk8: Array = [[cr, ""]]
					while not stk8.is_empty():
						var e8: Array = stk8.pop_back()
						var nd8: Node = e8[0]
						var path8: String = e8[1] + "/" + String(nd8.name)
						print("[tree-dump] " + path8)
						cnt8 += 1
						for ch8 in nd8.get_children():
							stk8.append([ch8, path8])
					print("[tree-dump] (chunks_root 节点 %d)" % cnt8)
			"autopilot_drive":
				# 自动跑图：交给游戏自带的自动驾驶（路径规划+避障+红绿灯），
				# 物理/车流/行人全真实运行 —— 复现"行车 2km 卡死"用。
				# value = [dest_east, dest_north]（数据坐标）。走正式入口
				# start_autopilot（内含 _prepare_autopilot 的依赖接线）。
				var car_d2 = main.get("car")
				if car_d2 != null and value is Array and (value as Array).size() >= 2:
					var dest := Vector2(float(value[0]), float(value[1]))
					var ok2: bool = main.call("start_autopilot", dest)
					print("[shot] autopilot_drive ok=%s dest=%s" % [str(ok2), str(dest)])
				else:
					print("[shot] autopilot_drive: car 不可用或参数缺失")
			"walk_toggle":
				# F 键等价：下车进步行（ALS 角色）/ 上车。需车已停稳。
				# （_toggle_vehicle_entry 返回 void → call 得 null，不能赋给 typed bool）
				main.call("_toggle_vehicle_entry")
				var wmode = main.get("mode")
				print("[shot] walk_toggle 完成，mode=%s" % str(wmode))
			"keys_hold":
				# 按键注入：value = ["W","SHIFT",...]（模拟 ALS 行走输入）。
				# 先释放上一批，再按下这一批 —— 长按跨多个机位持续生效。
				_keys_release_all()
				var codes := _parse_keynames(value)
				for kc in codes:
					var ev := InputEventKey.new()
					ev.keycode = kc
					ev.physical_keycode = kc
					ev.pressed = true
					Input.parse_input_event(ev)
					_held_keys.append(kc)
				print("[shot] keys_hold %s（已按 %d 键）" % [str(value), _held_keys.size()])
			"keys_release":
				_keys_release_all()
				print("[shot] keys_release（全部松开）")
			"diag":
				# 诊断：打印车/相机世界坐标 vs 高度场（排查"钻进山体"类问题）
				var car_d = main.get("car")
				var model_d = main.get("_car_model")
				var cam_d = get_viewport().get_camera_3d()
				var hf = main.get("world")
				if car_d != null and cam_d != null and hf != null:
					var cx: float = float(car_d.get("x"))
					var cz: float = float(car_d.get("z"))
					var my: float = model_d.global_position.y if model_d != null else -999.0
					var cp: Vector3 = cam_d.global_position
					var hf_h: float = float(hf.call("ground_height_data", cx, cz))
					var hf_hc: float = float(hf.call("ground_height_data", cp.x, -cp.z))
					print("[diag] car data=(%.1f,%.1f) 模型y=%.2f hf=%.2f | cam world=(%.1f, %.2f, %.1f) hf=%.2f 相机-hf=%.2f" % [
						cx, cz, my, hf_h, cp.x, cp.y, cp.z, hf_hc, cp.y - hf_hc])
				# 步行穿楼诊断：角色位置是否落在建筑足迹内（CityCollision 2D），
				# 以及 ALS 物理代理当前持有多少建筑碰撞体。
				var walk_d = main.get("walk")
				var wld2 = main.get("world")
				if walk_d != null and wld2 != null:
					var wx: float = float(walk_d.get("x"))
					var wz: float = float(walk_d.get("z"))
					var blk: bool = bool(wld2.collision.blocked(wx, wz))
					var gnd = main.get("_als_ground")
					var nbody := 0
					if gnd != null:
						nbody = int(gnd.get("_building_bodies").size())
					print("[walk-diag] pos=(%.1f,%.1f) 建筑足迹内=%s 物理建筑格=%d" % [
						wx, wz, str(blk), nbody])
			"hide_mesh":
				# 全局按名字子串隐藏 MeshInstance3D（跨根，定位"这块面是谁"）。
				# 值可为 String 或 String[]（一次隐藏多组）。
				var hide_list: Array = []
				if value is String and not (value as String).is_empty():
					hide_list = [value]
				elif value is Array:
					hide_list = value
				for hv in hide_list:
					var w5 = main.get("world")
					var n5 := 0
					var stk5: Array = [w5]
					while not stk5.is_empty():
						var nd5: Node = stk5.pop_back()
						for ch5 in nd5.get_children():
							stk5.append(ch5)
						if nd5 is MeshInstance3D and String(nd5.name).to_lower().contains(str(hv)):
							(nd5 as MeshInstance3D).visible = false
							n5 += 1
					print("[shot] 已隐藏 *%s* × %d" % [str(hv), n5])
			"probe_mesh":
				# 三角面级探测：列出该 XZ 上每一层表面的网格名与高度。
				# 用于定位共面 z-fighting —— AABB 命中不一定是真覆盖。
				# 值为数据坐标 [east, north]。
				if value is Array and (value as Array).size() >= 2:
					var pm: Array = value
					var wx: float = float(pm[0])
					var wz: float = float(pm[1])
					var wpos := CoordinateUtil.to_world(wx, wz, 0.0)
					var w = main.get("world")
					if w != null:
						var stk6: Array = [w]
						while not stk6.is_empty():
							var nd6: Node = stk6.pop_back()
							for ch6 in nd6.get_children():
								stk6.append(ch6)
							if not (nd6 is MeshInstance3D) or (nd6 as MeshInstance3D).mesh == null:
								continue
							var mi3 := nd6 as MeshInstance3D
							var xf := mi3.global_transform
							var aabb3 := xf * mi3.mesh.get_aabb()
							if wpos.x < aabb3.position.x or wpos.x > aabb3.end.x \
									or wpos.z < aabb3.position.z or wpos.z > aabb3.end.z:
								continue
							for s3 in mi3.mesh.get_surface_count():
								var arrays3 := mi3.mesh.surface_get_arrays(s3)
								if arrays3[Mesh.ARRAY_VERTEX] == null:
									continue
								var verts3: PackedVector3Array = arrays3[Mesh.ARRAY_VERTEX]
								var idx3 = arrays3[Mesh.ARRAY_INDEX]
								var count3: int = verts3.size() / 3 if idx3 == null else idx3.size() / 3
								for t3 in count3:
									var ia: int = t3 * 3 if idx3 == null else int(idx3[t3 * 3])
									var ib: int = t3 * 3 + 1 if idx3 == null else int(idx3[t3 * 3 + 1])
									var ic: int = t3 * 3 + 2 if idx3 == null else int(idx3[t3 * 3 + 2])
									var a3 := xf * verts3[ia]
									var b3 := xf * verts3[ib]
									var c3 := xf * verts3[ic]
									# XZ 点在三角形内？标准叉积同号测试
									var w1 := (b3.x - a3.x) * (wpos.z - a3.z) - (b3.z - a3.z) * (wpos.x - a3.x)
									var w2 := (c3.x - b3.x) * (wpos.z - b3.z) - (c3.z - b3.z) * (wpos.x - b3.x)
									var w3 := (a3.x - c3.x) * (wpos.z - c3.z) - (a3.z - c3.z) * (wpos.x - c3.x)
									var has_neg := w1 < 0.0 or w2 < 0.0 or w3 < 0.0
									var has_pos := w1 > 0.0 or w2 > 0.0 or w3 > 0.0
									if has_neg and has_pos:
										continue
									var y3 := (a3.y + b3.y + c3.y) / 3.0
									print("[probe-mesh] (%.0f,%.0f) %s surf%d y≈%.3f" % [wx, wz, mi3.name, s3, y3])
				print("[probe-mesh] done")
			"probe_point":
				# 枚举 AABB 包含该世界坐标的所有 MeshInstance3D —— 定位
				# "这个屏幕位置到底画的是谁"。值为数据坐标 [east, north, y]。
				if value is Array and (value as Array).size() >= 3:
					var pv: Array = value
					var wp: Vector3 = CoordinateUtil.to_world(float(pv[0]), float(pv[1]), float(pv[2]))
					var w = main.get("world")
					var hits: Array = []
					if w != null:
						var stk: Array = [w]
						while not stk.is_empty():
							var nd: Node = stk.pop_back()
							for ch in nd.get_children():
								stk.append(ch)
							if nd is MeshInstance3D and (nd as MeshInstance3D).mesh != null:
								var mi2 := nd as MeshInstance3D
								var aabb := mi2.global_transform * mi2.mesh.get_aabb()
								if aabb.has_point(wp):
									var mat_name := "?"
									if mi2.mesh.get_surface_count() > 0:
										var m0 := mi2.mesh.surface_get_material(0)
										if m0 != null:
											mat_name = m0.resource_name
									hits.append("%s (mat=%s)" % [mi2.name, mat_name])
					print("[probe] %s 命中 %d:" % [str(wp), hits.size()])
					for h2 in hits:
						print("   - " + str(h2))
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
			"goto":
				# 把车瞬移到**数据坐标** [x, z]（可选第三项 yaw），用来拍远处地标。
				# 追尾相机会检测到大位移并直接落位（follow_vehicle 的 carry>25 分支）。
				if value is Array and (value as Array).size() >= 2:
					var v: Array = value
					var car = main.get("car")
					if car != null:
						car.set("x", float(v[0]))
						car.set("z", float(v[1]))
						if v.size() >= 3:
							car.set("yaw", float(v[2]))
						print("[shot] 车已移到数据坐标 (%.0f, %.0f) yaw=%s" % [
							float(v[0]), float(v[1]), str(car.get("yaw"))])
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
			"view":
				# 驾驶视角档位：0/1/2 = 追尾三档，3 = 座舱（原版 CITY_DRIVER_POSE）。
				# 走游戏自己的 _cycle_camera_view()，与按 C 键完全同一条路径，
				# 避免探针自己拼一套相机再"验证"相机。
				var want := int(value)
				if int(main.get("mode")) != 0:
					push_warning("[shot] view 需要在驾驶模式（先设 \"mode\":\"car\"）")
				else:
					var guard := 0
					while guard < 8 and int(main.get("_cam_phase")) != want:
						main.call("_cycle_camera_view")
						guard += 1
					print("[shot] cam_phase -> %d" % int(main.get("_cam_phase")))
			"fire":
				# 发射一枚导弹（实际执行时机见 _late_env —— 必须在截图前一刻）
				if main.has_method("fire_missile"):
					main.call("fire_missile")
			"onfoot":
				# 下车步行（等价于按 F）：切到 WALKING，让 ALS 角色进入世界。
				# 只有这一档才看得到 mannequin —— 座舱/追尾视角里角色是禁用的。
				if bool(value) and int(main.get("mode")) == 0:
					main.call("_toggle_vehicle_entry")
					print("[shot] 已切到步行（mode=%d）" % int(main.get("mode")))
			"fps_probe":
				# 定点测帧率：等场景稳定后采样 2 秒平均 FPS（配合 goto/observer_at 用）
				if bool(value):
					_fps_probe = true
			"help":
				# 打开按键帮助页（= 按 ?），用于检查帮助表排版 / 内容是否与实际按键一致
				if bool(value):
					var pn = main.get("panels")
					if pn != null:
						# 与游戏内按键同路径：先同步当前模式（决定高亮哪节）再开页
						pn.call("set_help_mode", int(main.get("mode")))
						pn.call("toggle_help")
						print("[shot] 帮助页已打开（模式 %d）" % int(main.get("mode")))
			"observer_at":
				# 无人机定点俯视：[x_data, z_data, y, yaw_rad, pitch_deg]
				# 直接摆相机并冻结物理，用来检查地面材质/铺装这类需要俯视的细节。
				if value is Array and (value as Array).size() >= 5:
					var v: Array = value
					main.call("_enter_observer")
					var cam = main.get("camera")
					var p3: Vector3 = CoordinateUtil.to_world(float(v[0]), float(v[1]), float(v[2]))
					cam.set("observer_position", p3)
					cam.set("observer_yaw", float(v[3]))
					cam.set("observer_pitch", deg_to_rad(float(v[4])))
					cam.set("global_position", p3)
					main.set("paused", true)
					cam.call("follow_observer", 1.0)   # dt=1 → 直接落位
					print("[shot] 无人机定点 (%.0f, %.0f, %.0f) pitch=%.0f°" % [
						float(v[0]), float(v[1]), float(v[2]), float(v[4])])
			"zoom":
				# 只认领这个键名（实际在 _late_env 里执行：必须暂停后再改 fov）
				pass
			"cockpit_probe":
				# 座舱仪表注值 [speed_mps, steer, trip_m]：只在 _late_env 执行
				# （必须在截图前一刻，否则下一帧就被真实车速覆盖）。这里显式
				# 认领这个键，免得落到下面的兜底分支去 set() 一个不存在的属性。
				pass
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
	# ---- 画面自动验收（渲染失效 / 帧冻结检测，grep [VIEW]/[ANOMALY]）----
	var w := img.get_width()
	var h := img.get_height()
	var n := 0
	var sr := 0.0
	var sg := 0.0
	var sb := 0.0
	var hash_acc := 0
	var samples: Array = []
	for yy in range(0, h, 16):
		for xx in range(0, w, 16):
			var c := img.get_pixel(xx, yy)
			var lum := c.r * 0.3 + c.g * 0.6 + c.b * 0.1
			sr += c.r
			sg += c.g
			sb += c.b
			samples.append(lum)
			hash_acc = (hash_acc * 31 + int(lum * 63.0)) % 2147483647
			n += 1
	if n > 0:
		var mr := sr / n
		var mg := sg / n
		var mb := sb / n
		var var_acc := 0.0
		for lum in samples:
			var d := float(lum) - (mr * 0.3 + mg * 0.6 + mb * 0.1)
			var_acc += d * d
		var sigma := sqrt(var_acc / n)
		print("[VIEW] %s 均色=(%.2f,%.2f,%.2f) 亮度σ=%.1f 采样=%d" % [name, mr, mg, mb, sigma, n])
		if sigma < 0.02:   # 亮度为 0-1 量纲：正常画面 σ≈0.1-0.25,纯色 <0.02
			print("[ANOMALY] 画面纯色（渲染失效?）均色=(%.2f,%.2f,%.2f) σ=%.3f" % [mr, mg, mb, sigma])
		if _prev_view_hash == hash_acc:
			print("[ANOMALY] 画面与上一张逐点一致（帧冻结?）")
		_prev_view_hash = hash_acc
	var path := "%s/%s.png" % [_out_dir, name]
	var err := img.save_png(path)
	print("[shot] %s  %dx%d  err=%d" % [path, w, h, err])

var _prev_view_hash := -1


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

# ---------------------------------------------------------------------------
# 按键注入（ALS 步行自动化）：_keys_hold/_keys_release env 用
# ---------------------------------------------------------------------------

var _held_keys: Array = []
var _prev_speed := -1.0


func _parse_keynames(value: Variant) -> Array:
	var out: Array = []
	if not (value is Array):
		return out
	var table := {
		"W": KEY_W, "A": KEY_A, "S": KEY_S, "D": KEY_D,
		"SHIFT": KEY_SHIFT, "SPACE": KEY_SPACE, "E": KEY_E, "F": KEY_F,
	}
	for nm in value:
		if table.has(String(nm).to_upper()):
			out.append(table[String(nm).to_upper()])
	return out


func _keys_release_all() -> void:
	for kc in _held_keys:
		var ev := InputEventKey.new()
		ev.keycode = kc
		ev.physical_keycode = kc
		ev.pressed = false
		Input.parse_input_event(ev)
	_held_keys.clear()
