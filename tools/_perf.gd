extends Node
##
## 性能探针（配置矩阵）—— 一次启动量出「这一帧到底花在哪」。
##
## 为什么要它：GTA_SZ_GODOT 的 CPU 侧节流（电摩/信号灯/林冠/招牌的
## 移动阈值 + 缓存）在 2026-09-22 那轮已经做过，再凭"看起来重"去改代码
## 只会白改。这里用**同一次启动**逐项关掉一个开销源，比较帧时间差值，
## 得到可归因的分解；同时打印 draw call / 图元数 / 显存，判断是 CPU 还是 GPU 瓶颈。
##
## 只做两件事：读取引擎计数器 + 临时改「环境开关 / 节点可见性」，改完立即还原，
## 不碰任何游戏逻辑。测完自己退出。
##
## 用法：
##   Godot_v4.7.1-stable_win64_console.exe --path . --resolution 1920x1080 \
##       res://tools/_perf.tscn
##
## 输出（stdout）：
##   [perf] 基线            fps=52.3 frame=19.12ms cpu=3.42ms draws=2418 prims=3.1M vram=812MB
##   ...
##   [perf] ── 归因（相对基线省下的帧时间）──
##   [perf] no-shadow       -3.10ms  (-16.2%)

## 模式：
##   "trace"  —— 按**用户实际配置**（vsync 开，不改任何开关）逐帧打印
##               delta / draw call / 图元数 / 引擎自测的渲染 CPU·GPU 时间。
##               用来判断「40fps」到底是丢帧（>16.7ms 的帧）还是被别的节奏压住，
##               以及哪个计数器可用作后面矩阵的度量。
##   "matrix" —— 逐项关掉一个开销源做归因。注意：**必须保持 vsync 开**，
##               否则渲染线程与主线程解耦，delta 只反映主线程跑得有多快
##               （实测主线程 2ms/帧、屏幕却 40fps），差值全被吞掉。
##   "tree"   —— 遍历场景树，按「父路径」汇总 MeshInstance3D 实例数 × surface 数
##               （≈ 提交的 draw call）与三角面数，用来定位 draw call 的真正来源，
##               顺便验证上面那些开关到底关对了没有。
##   "both"   —— 先逐帧追踪，再跑矩阵（一次启动拿齐两样）。
##   "rounds" —— 多轮对照：每轮 120 帧（vsync 保持开），只改一处，
##               量「长帧（>50ms）次数」和分桶直方图。
##               这是决定性实验：若某一项关掉后 90~110ms 的长帧消失，就是它。
##   "loadshot" —— 启动后按固定时刻抓图（含**加载画面**阶段），用于人工比对版式。
##               加载画面在 ~11s 内存在，所以 2~10.5s 的几张都是加载画面。
##   "drive"  —— 真开起来量：合成按住 W（必要时转向），跑 DRIVE_FRAMES 帧。
##               静止不动测不出流式加载/小地图平移带来的卡顿，而用户是开着车玩的。
##   "mapshot" —— 按 M 打开大地图，等 1.5s 抓一张（验证烘焙改动没破坏大地图路径）
const MODE := "matrix"
var _map_phase := 0
const DRIVE_FRAMES := 600

## loadshot 的抓图时刻（秒，自启动算起）
const LOADSHOT_TIMES := [0.4, 1.2, 2.0, 2.8, 3.6, 6.0]
const SHOT_DIR := "D:/CodePro/game_ws/GTA_SZ_GODOT/tools/shots"

const SCENE := "res://scenes/main.tscn"
const TRACE_FRAMES := 120

## 多轮对照表（MODE == "rounds"）
const TRACE_ROUNDS := [
	{"name": "baseline", "mods": {}},
	{"name": "no-minimap", "mods": {"minimap": false}},
	{"name": "no-minimap-hud", "mods": {"minimap": false, "hud": false}},
	{"name": "baseline2", "mods": {}},
]

## 每项的稳定时间与采样时长（秒）
const SETTLE_TIME := 0.45
const SAMPLE_TIME := 2.5
## session_ready 之前的额外等待（等加载画面收尾、流式加载喘息）
const READY_WARMUP := 2.5

## 配置矩阵：每项只改一处，便于归因
const CONFIGS := [
	{"name": "baseline", "mods": {}},
	{"name": "no-ssao", "mods": {"ssao": false}},
	{"name": "no-glow", "mods": {"glow": false}},
	{"name": "no-shadow", "mods": {"shadow": false}},
	{"name": "no-fxaa", "mods": {"fxaa": false}},
	{"name": "scale-0.88", "mods": {"scale": 0.88}},
	{"name": "scale-0.75", "mods": {"scale": 0.75}},
	{"name": "scale-0.5", "mods": {"scale": 0.5}},
	{"name": "no-sky", "mods": {"sky": false}},
	{"name": "no-water", "mods": {"water": false}},
	{"name": "no-roads", "mods": {"roads": false}},
	{"name": "no-terrain", "mods": {"terrain": false}},
	{"name": "no-landmarks", "mods": {"landmarks": false}},
	{"name": "no-chunks", "mods": {"chunks": false}},
	{"name": "no-facades", "mods": {"facades": false}},
	{"name": "no-lamps", "mods": {"lamps": false}},
	{"name": "no-scenery", "mods": {"scenery": false}},
	{"name": "no-signs", "mods": {"signs": false}},
	{"name": "no-pedestrians", "mods": {"pedestrians": false}},
	{"name": "no-traffic", "mods": {"traffic": false}},
	{"name": "no-ebikes", "mods": {"ebikes": false}},
	{"name": "no-signals", "mods": {"signals": false}},
	{"name": "all-off", "mods": {"ssao": false, "glow": false, "shadow": false, "fxaa": false,
		"sky": false, "water": false, "roads": false, "terrain": false, "landmarks": false,
		"chunks": false, "facades": false, "lamps": false,
		"scenery": false, "signs": false, "pedestrians": false, "traffic": false,
		"ebikes": false, "signals": false}},
]

enum Phase { BOOT, WARMUP, TRACE, SETTLE, SAMPLE, DONE }

var main: Node = null
var world: Node = null
var lighting: Node = null

var phase: int = Phase.BOOT
var phase_t := 0.0
var cfg_i := -1

# 采样累加
var _frames := 0
var _sum_ms := 0.0
var _min_ms := 1e9
var _max_ms := 0.0
var _sum_cpu := 0.0
var _sum_phys := 0.0
var _slow_frames := 0          ## >16.7ms 的帧数
var _slow_frames_33 := 0       ## >33.3ms 的帧数（vsync 下会掉到 30fps 的那些帧）

var results: Array = []
var baseline_ms := 0.0
var round := 0                 ## 0 = vsync 开（用户配置）／1 = vsync 关（真实成本）
var _stalls := 0               ## 本轮 >50ms 的长帧数
var _buckets := [0, 0, 0, 0, 0]
var _sum_fps := 0.0
var _boot_time := 0.0
var _shot_i := 0

# 原始状态（用于还原）
var _orig_ssao := false
var _orig_glow := false
var _orig_shadow := true
var _orig_fxaa := 0
var _orig_scale := 1.0
var _orig_lamp_dist := 0.0
var _toggles: Array = []       ## [{node: Node, visible: bool}]


func _ready() -> void:
	# **不要关 vsync**：渲染线程与主线程解耦后 delta 只反映主线程速率，
	# 首轮就是这么被骗的（主线程 2ms/帧，屏幕实际 40fps）。
	# 保留 vsync 时 delta 就等于真实呈现间隔，与用户看到的一致。
	print("[perf] 模式 %s  窗口 %s  适配器 %s  驱动 %s" % [
		MODE, str(DisplayServer.window_get_size()),
		RenderingServer.get_video_adapter_name(),
		RenderingServer.get_video_adapter_api_version()])
	print("[perf] vsync=%d  显示器刷新 %.1fHz" % [
		DisplayServer.window_get_vsync_mode(), DisplayServer.screen_get_refresh_rate()])
	var scene: PackedScene = load(SCENE)
	if scene == null:
		printerr("[perf] 主场景加载失败")
		get_tree().quit(1)
		return
	main = scene.instantiate()
	add_child(main)
	print("[perf] 主场景已加入，等待 session_ready …")


func _process(delta: float) -> void:
	if MODE == "loadshot":
		_loadshot_tick(delta)
		return
	if MODE == "mapshot":
		_mapshot_tick(delta)
		return
	match phase:
		Phase.BOOT:
			_tick_boot(delta)
		Phase.WARMUP:
			phase_t += delta
			if phase_t >= READY_WARMUP:
				_capture_orig()
				if MODE == "trace" or MODE == "vs":
					print("[perf] 逐帧追踪开始（%d 帧）：i  delta_ms  fps  draws  prims" % TRACE_FRAMES)
					phase = Phase.TRACE
					phase_t = 0.0
				elif MODE == "rounds":
					_start_round(0)
				elif MODE == "drive":
					print("[perf] 合成按住 W 开始行驶（%d 帧），同时统计长帧" % DRIVE_FRAMES)
					_press_key(KEY_W, true)
					_frames = 0
					_sum_ms = 0.0
					_min_ms = 1e9
					_max_ms = 0.0
					_slow_frames = 0
					_slow_frames_33 = 0
					_stalls = 0
					_sum_fps = 0.0
					_buckets = [0, 0, 0, 0, 0]
					phase = Phase.TRACE
					phase_t = 0.0
				elif MODE == "tree":
					_dump_tree()
					get_tree().quit(0)
				else:
					_next_config()
		Phase.TRACE:
			_trace_frame(delta)
		Phase.SETTLE:
			phase_t += delta
			if phase_t >= SETTLE_TIME:
				_begin_sample()
		Phase.SAMPLE:
			_accumulate(delta)
			phase_t += delta
			if phase_t >= SAMPLE_TIME:
				_finish_sample()
		Phase.DONE:
			pass


## loadshot：按启动时刻抓图（不进入状态机、不等 session_ready）
func _loadshot_tick(delta: float) -> void:
	_boot_time += delta
	if _shot_i >= LOADSHOT_TIMES.size():
		return
	if _boot_time < float(LOADSHOT_TIMES[_shot_i]):
		return
	var t := float(LOADSHOT_TIMES[_shot_i])
	_shot_i += 1
	_capture_shot("load_%04.1fs" % t)
	if _shot_i >= LOADSHOT_TIMES.size():
		print("[perf] loadshot 完成")
		get_tree().quit(0)


func _capture_shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	var path := "%s/%s.png" % [SHOT_DIR, shot_name]
	var err := img.save_png(path)
	print("[perf] shot %s  %dx%d  err=%d" % [path, img.get_width(), img.get_height(), err])


func _tick_boot(delta: float) -> void:
	if main == null:
		return
	if not bool(main.get("session_ready")):
		return
	world = main.get("world")
	if world == null:
		return
	lighting = world.get("lighting")
	print("[perf] session_ready 达成，预热 %.1fs" % READY_WARMUP)
	phase = Phase.WARMUP
	phase_t = 0.0


## 场景树归属统计：draw call 是按「MeshInstance 实例 × surface 数」提交的，
## 所以这里按祖先路径聚合，直接看出是谁在刷 draw call、以及节点到底挂在哪。
func _dump_tree() -> void:
	print("")
	print("[tree] world.counts() = %s" % str(world.call("counts")))
	print("[tree] 场景树 MeshInstance/MultiMesh 归属（按 可见实例×surface 排序）")
	var groups := {}
	var total_mi := 0
	var total_mmi := 0
	var total_draws := 0
	var total_tris := 0
	var stack: Array = [main]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D:
			total_mi += 1
			var mi := n as MeshInstance3D
			var surfaces := 0
			var tris := 0
			if mi.mesh != null:
				surfaces = mi.mesh.get_surface_count()
				for s in surfaces:
					# 只用 O(1) 的计数接口：surface_get_arrays 会把整个网格拷出来，
					# 对 266MB 的 GLB 是不可接受的开销。
					# 注意：surface_get_array_* 只在 ArrayMesh 上，PrimitiveMesh 没有。
					var ilen := 0
					var alen := 0
					var am := mi.mesh as ArrayMesh
					if am != null:
						ilen = am.surface_get_array_index_len(s)
						alen = am.surface_get_array_len(s)
					tris += (ilen / 3) if ilen > 0 else (alen / 3)
			var vis := mi.is_visible_in_tree()
			var key := _group_key(mi)
			var g: Dictionary = groups.get(key, {"mi": 0, "mmi": 0, "draws": 0, "tris": 0, "visible_draws": 0})
			g["mi"] = int(g["mi"]) + 1
			g["draws"] = int(g["draws"]) + surfaces
			g["tris"] = int(g["tris"]) + tris
			if vis:
				g["visible_draws"] = int(g["visible_draws"]) + surfaces
			groups[key] = g
			total_draws += surfaces
			total_tris += tris
		elif n is MultiMeshInstance3D:
			total_mmi += 1
			var mm := n as MultiMeshInstance3D
			var inst := 0
			if mm.multimesh != null:
				inst = mm.multimesh.visible_instance_count
				if inst < 0:
					inst = mm.multimesh.instance_count
			var key := _group_key(mm)
			var g2: Dictionary = groups.get(key, {"mi": 0, "mmi": 0, "draws": 0, "tris": 0, "visible_draws": 0})
			g2["mmi"] = int(g2["mmi"]) + 1
			g2["draws"] = int(g2["draws"]) + 1
			g2["tris"] = int(g2["tris"]) + inst
			if mm.is_visible_in_tree():
				g2["visible_draws"] = int(g2["visible_draws"]) + 1
			groups[key] = g2
			total_draws += 1

	var arr: Array = []
	for k in groups:
		arr.append({"key": k, "g": groups[k]})
	arr.sort_custom(func(a, b): return int(a["g"]["draws"]) > int(b["g"]["draws"]))
	print("[tree] 合计：MeshInstance %d 个 / MultiMesh %d 个 / surface 合计 %d / 三角面合计 %.2fM" % [
		total_mi, total_mmi, total_draws, float(total_tris) / 1e6])
	print("[tree] 前 24 组：")
	for i in mini(24, arr.size()):
		var k := str(arr[i]["key"])
		var g: Dictionary = arr[i]["g"]
		print("[tree]   draws=%5d (可见 %5d)  mi=%4d mmi=%3d  tris=%9.0f   %s" % [
			int(g["draws"]), int(g["visible_draws"]), int(g["mi"]), int(g["mmi"]),
			float(g["tris"]), k])


## 归属键：取父节点的 2 级路径（够区分「区块 / 地标 / 立面 / 信号灯 …」）
func _group_key(n: Node) -> String:
	var p := n.get_parent()
	if p == null:
		return "(root)"
	var path := str(p.name)
	var gp := p.get_parent()
	if gp != null:
		path = str(gp.name) + "/" + path
	return "%s  [%s]" % [path, n.get_class()]


## 逐帧追踪：把每一帧的呈现间隔与引擎计数器打出来，
## 用来分辨「稳定的 20ms」和「16.6/33.3 交替的 vsync 丢帧」，
## 以及是否存在周期性长帧（那通常是主线程同步加载什么东西）。
func _trace_frame(delta: float) -> void:
	_frames += 1
	var ms := delta * 1000.0
	if ms > 16.7:
		_slow_frames += 1
	if ms > 33.3:
		_slow_frames_33 += 1
	_sum_ms += ms
	if ms < _min_ms:
		_min_ms = ms
	if ms > _max_ms:
		_max_ms = ms
	_buckets[_bucket(ms)] = int(_buckets[_bucket(ms)]) + 1
	_sum_fps += float(Engine.get_frames_per_second())
	if ms > 50.0:
		_stalls += 1
	if MODE == "trace" or MODE == "vs":
		print("[trace] %3d  r%d  delta=%7.2fms  fps=%5.1f  draws=%5d  prims=%7.2fM  nodes=%5d" % [
			_frames, round, ms, Engine.get_frames_per_second(),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			float(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)) / 1e6,
			int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))])
	# 长帧归因：把当时的世界状态打出来，看是不是流式加载/节点挂载引起的
	if ms > 50.0:
		print("[stall] 第%d轮 frame=%d delta=%.1fms  %s" % [round, _frames, ms, _world_state()])
## 每秒给一行汇总，方便一眼看出长帧分布
	if _frames % 60 == 0:
		print("[trace] ── 前 %d 帧：均值 %.2fms 最小 %.2f 最大 %.2f  >16.7ms %d  >33.3ms %d" % [
			_frames, _sum_ms / float(_frames), _min_ms, _max_ms,
			_slow_frames, _slow_frames_33])
		if MODE == "drive":
			print("[drive] %s" % _world_state())
	var limit := DRIVE_FRAMES if MODE == "drive" else TRACE_FRAMES
	if _frames >= limit:
		_round_summary()
		if MODE == "drive":
			_press_key(KEY_W, false)
			print("[perf] 行驶结束  %s" % _world_state())
			get_tree().quit(0)
			return
		if MODE == "rounds":
			if round + 1 < TRACE_ROUNDS.size():
				_start_round(round + 1)
				return
			print("[perf] 全部完成")
			get_tree().quit(0)
			return
		if MODE == "vs" and round == 0:
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
			print("[trace] → 关 vsync 测真实每帧成本（这一轮 delta 不再等于呈现间隔，看分布）")
			round = 1
			_frames = 0
			_sum_ms = 0.0
			_min_ms = 1e9
			_max_ms = 0.0
			_slow_frames = 0
			_slow_frames_33 = 0
			phase_t = 0.0
			return
		if MODE == "both":
			print("[trace] 转入配置矩阵")
			_frames = 0
			_sum_ms = 0.0
			_slow_frames = 0
			_slow_frames_33 = 0
			_next_config()
			return
		get_tree().quit(0)
	phase_t += delta


func _start_round(i: int) -> void:
	round = i
	_reset()
	_apply(TRACE_ROUNDS[i]["mods"])
	_frames = 0
	_sum_ms = 0.0
	_min_ms = 1e9
	_max_ms = 0.0
	_slow_frames = 0
	_slow_frames_33 = 0
	_stalls = 0
	_sum_fps = 0.0
	_buckets = [0, 0, 0, 0, 0]
	print("")
	print("[trace] ── 第 %d 轮「%s」mods=%s" % [i, TRACE_ROUNDS[i]["name"], str(TRACE_ROUNDS[i]["mods"])])
	phase = Phase.TRACE
	phase_t = 0.0


## 分桶：<16.7（满帧）/ 16.7–33 / 33–60 / 60–120 / >120
func _bucket(ms: float) -> int:
	if ms < 16.7:
		return 0
	if ms < 33.0:
		return 1
	if ms < 60.0:
		return 2
	if ms < 120.0:
		return 3
	return 4


func _round_summary() -> void:
	var mean := _sum_ms / maxf(float(_frames), 1.0)
	var fps_mean := _sum_fps / maxf(float(_frames), 1.0)
	var rname := "drive" if MODE == "drive" else str(TRACE_ROUNDS[round]["name"])
	print("[trace] 第 %d 轮「%s」：引擎FPS均值 %.1f  帧均值 %.2fms  最小 %.2f  最大 %.2f  >16.7ms %d  >33.3ms %d  >50ms(长帧) %d" % [
		round, rname, fps_mean, mean, _min_ms, _max_ms,
		_slow_frames, _slow_frames_33, _stalls])
	print("[trace]   直方图 <16.7:%d  16.7-33:%d  33-60:%d  60-120:%d  >120:%d  (共 %d 帧)" % [
		_buckets[0], _buckets[1], _buckets[2], _buckets[3], _buckets[4], _frames])


## mapshot：ready → 按 M → 1.5s 后抓图 → 再按 M 退出
func _mapshot_tick(delta: float) -> void:
	if not bool(main.get("session_ready")):
		return
	phase_t += delta
	match _map_phase:
		0:
			_press_key(KEY_M, true)
			_press_key(KEY_M, false)
			print("[perf] 已按 M 打开大地图")
			_map_phase = 1
		1:
			if phase_t < 2.0:
				return
			_capture_shot("bigmap")
			_map_phase = 2
		2:
			_press_key(KEY_M, true)
			_press_key(KEY_M, false)
			print("[perf] mapshot 完成")
			get_tree().quit(0)


## 合成按键：游戏用 Input.is_key_pressed() 轮询，而 parse_input_event 会更新
## 引擎内部的按键状态，所以这样能真的把车开起来。
func _press_key(code: int, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code as Key
	ev.physical_keycode = code as Key
	ev.pressed = pressed
	Input.parse_input_event(ev)


## 长帧时打印世界状态：区分「流式加载卡住」和「渲染本身慢」
func _world_state() -> String:
	if world == null:
		return "(world 未就绪)"
	var c: Dictionary = world.call("counts")
	var cs: Dictionary = c.get("chunkStreamer", {})
	var fac := {}
	var f = world.get("facades")
	if f != null and f.has_method("diagnostics"):
		fac = f.call("diagnostics")
	var ld = world.get("loader")
	var ldr := "-"
	if ld != null and ld.has_method("counters"):
		var cnt: Vector2i = ld.call("counters")
		ldr = "%d/%d%s" % [cnt.x, cnt.y, "" if ld.call("is_idle") else " 忙"]
	var focus: Vector3 = world.get("focus")
	var spd := 0.0
	var car = main.get("car")
	if car != null:
		spd = float(car.get("speed"))
	return "车=%.1fm/s blocks=%s 立面=%s/%s 区块=%s/%s 待载=%s 当前=%s 加载队列=%s focus=(%.0f,%.0f) nodes=%d" % [
		spd,
		str(c.get("blocks")),
		str(fac.get("loaded", "?")), str(fac.get("visible", "?")),
		str(cs.get("loaded", "?")), str(cs.get("blocks", "?")),
		str(cs.get("pending", "?")), str(cs.get("current", "")),
		ldr, focus.x, focus.z,
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))]


## 记录原始开关值，采样结束后一律还原
func _capture_orig() -> void:
	var env: Environment = lighting.env_node.environment
	_orig_ssao = env.ssao_enabled
	_orig_glow = env.glow_enabled
	_orig_shadow = lighting.sun.shadow_enabled
	_orig_fxaa = get_viewport().screen_space_aa
	_orig_scale = get_viewport().scaling_3d_scale
	_toggles = [
		{"node": world.get("terrain_root"), "visible": true, "key": "terrain"},
		{"node": world.get("roads_root"), "visible": true, "key": "roads"},
		{"node": world.get("landmarks_root"), "visible": true, "key": "landmarks"},
		{"node": world.get("scenery_root"), "visible": true, "key": "scenery"},
		{"node": world.get("facades_root"), "visible": true, "key": "facades"},
		{"node": world.get("water_root"), "visible": true, "key": "water"},
		{"node": world.get("chunks_root"), "visible": true, "key": "chunks"},
		{"node": world.get("buildings_root"), "visible": true, "key": "buildings"},
		{"node": main.get_node_or_null("SkySystem"), "visible": true, "key": "sky"},
		{"node": main.get_node_or_null("SignSystem"), "visible": true, "key": "signs"},
		{"node": main.get_node_or_null("TrafficSystem"), "visible": true, "key": "traffic"},
		{"node": main.get_node_or_null("PedestrianSystem"), "visible": true, "key": "pedestrians"},
		{"node": main.get_node_or_null("EbikeSystem"), "visible": true, "key": "ebikes"},
		{"node": main.get_node_or_null("TrafficSignals"), "visible": true, "key": "signals"},
	]
	# HUD / 小地图（CanvasLayer 也有 visible）
	var maps = main.get("maps")
	if maps != null:
		_toggles.append({"node": maps.get("minimap_holder"), "visible": true, "key": "minimap"})
	_toggles.append({"node": main.get("hud"), "visible": true, "key": "hud"})
	# 路灯池：只把「采样时真的亮着」的灯登记进来，关掉/还原都只碰这些
	var lamp_lit := 0
	for l in lighting.get("_lamp_pool"):
		if l is Light3D and (l as Light3D).visible:
			_toggles.append({"node": l, "visible": true, "key": "lamps"})
			lamp_lit += 1
	print("[perf] 路灯池亮着 %d 盏" % lamp_lit)
	print("[perf] 原始状态：SSAO=%s Glow=%s 阴影=%s FXAA=%d 缩放=%.2f" % [
		_orig_ssao, _orig_glow, _orig_shadow, _orig_fxaa, _orig_scale])
	print("[perf] 共 %d 组，每组稳定 %.2fs + 采样 %.2fs" % [
		CONFIGS.size(), SETTLE_TIME, SAMPLE_TIME])


func _next_config() -> void:
	cfg_i += 1
	if cfg_i >= CONFIGS.size():
		_report()
		return
	_reset()
	_apply(CONFIGS[cfg_i]["mods"])
	phase = Phase.SETTLE
	phase_t = 0.0


func _reset() -> void:
	var env: Environment = lighting.env_node.environment
	env.ssao_enabled = _orig_ssao
	env.glow_enabled = _orig_glow
	lighting.sun.shadow_enabled = _orig_shadow
	get_viewport().screen_space_aa = _orig_fxaa
	get_viewport().scaling_3d_scale = _orig_scale
	for e in _toggles:
		var n: Node = e["node"]
		if n != null and is_instance_valid(n):
			n.visible = bool(e["visible"])


func _apply(mods: Dictionary) -> void:
	var env: Environment = lighting.env_node.environment
	if mods.has("ssao"):
		env.ssao_enabled = bool(mods["ssao"])
	if mods.has("glow"):
		env.glow_enabled = bool(mods["glow"])
	if mods.has("shadow"):
		lighting.sun.shadow_enabled = bool(mods["shadow"])
	if mods.has("fxaa"):
		get_viewport().screen_space_aa = (Viewport.SCREEN_SPACE_AA_FXAA
			if bool(mods["fxaa"]) else Viewport.SCREEN_SPACE_AA_DISABLED)
	if mods.has("scale"):
		get_viewport().scaling_3d_scale = float(mods["scale"])
	for e in _toggles:
		var n: Node = e["node"]
		if n == null or not is_instance_valid(n):
			continue
		if mods.has(str(e["key"])):
			n.visible = bool(mods[str(e["key"])])


func _begin_sample() -> void:
	_frames = 0
	_sum_ms = 0.0
	_min_ms = 1e9
	_max_ms = 0.0
	_sum_cpu = 0.0
	_sum_phys = 0.0
	_slow_frames = 0
	_slow_frames_33 = 0
	phase = Phase.SAMPLE
	phase_t = 0.0


func _accumulate(delta: float) -> void:
	var ms := delta * 1000.0
	_frames += 1
	_sum_ms += ms
	if ms < _min_ms:
		_min_ms = ms
	if ms > _max_ms:
		_max_ms = ms
	if ms > 16.7:
		_slow_frames += 1
	if ms > 33.3:
		_slow_frames_33 += 1
	# 注意：Performance.TIME_PROCESS 实测与 delta 严重不符（首轮报 117ms 而 delta 只有
	# 16ms），不能当"每帧 CPU 时间"用，只作为参考值打印。
	_sum_cpu += float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0
	_sum_phys += float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0


func _finish_sample() -> void:
	if _frames <= 0:
		_frames = 1
	var n := float(_frames)
	var avg := _sum_ms / n
	var res := {
		"name": CONFIGS[cfg_i]["name"],
		"avg": avg,
		"min": _min_ms,
		"max": _max_ms,
		"fps": 1000.0 / maxf(avg, 0.001),
		"drop": float(_slow_frames) / n * 100.0,
		"cpu": _sum_cpu / n,
		"phys": _sum_phys / n,
		"draws": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"prims": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"vram": int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"slow": _slow_frames,
		"slow33": _slow_frames_33,
		"frames": _frames,
	}
	if res["name"] == "baseline":
		baseline_ms = avg
	results.append(res)
	print("[perf] %-14s fps=%6.1f frame=%6.2fms  丢帧 %3d/%3d (%3.0f%%)  draws=%5d prims=%7.2fM vram=%4dMB nodes=%5d" % [
		res["name"], res["fps"], avg, _slow_frames, _frames, res["drop"],
		res["draws"], float(res["prims"]) / 1e6, res["vram"] / 1048576, res["nodes"]])
	_next_config()


func _report() -> void:
	print("")
	print("[perf] ── 归因（相对基线）──")
	print("[perf] 度量说明：vsync 开，60Hz 下 >16.7ms 的帧就是「丢帧」；")
	print("[perf]   丢帧率降得越多 = 这一项的开销越大。帧均值只能落在 16.7/33.3 两档上。")
	var b: Dictionary = results[0]
	var bd := float(b["drop"])
	for r in results:
		if r["name"] == "baseline":
			print("[perf] %-14s 基线        fps=%6.1f  丢帧 %3.0f%%  draws=%5d  prims=%7.2fM" % [
				r["name"], b["fps"], bd, int(b["draws"]), float(b["prims"]) / 1e6])
			continue
		print("[perf] %-14s fps %+6.1f   丢帧 %+6.1f 个百分点   draws %+5d   prims %+7.2fM" % [
			r["name"], float(r["fps"]) - float(b["fps"]), float(r["drop"]) - bd,
			int(r["draws"]) - int(b["draws"]),
			(float(r["prims"]) - float(b["prims"])) / 1e6])
	print("[perf] 全部完成")
	get_tree().quit(0)
