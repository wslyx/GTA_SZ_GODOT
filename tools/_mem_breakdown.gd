extends Node
##
## 内存分解探针（一次性诊断，回答"2.7GB 里都有什么"）：
## 等 session_ready + 稳定 10s（区块加载收尾），然后一次拉全四层账目：
##   1. 进程工作集（tasklist 查询自己，对齐任务管理器数字）
##   2. Godot 资源堆（MEMORY_STATIC / MAX / 对象·资源·节点计数）
##   3. 显存总账 + 明细（RENDERING_INFO_*：纹理/缓冲；RenderingDevice 分项）
##   4. 系统（OS.get_memory_info）
## 输出后自动退出。
##
## 用法：
##   Godot_console.exe --path . --resolution 1920x1080 res://tools/_mem_breakdown.tscn

var main: Node = null
var t := 0.0

func _ready() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	main = scene.instantiate()
	add_child(main)
	print("[mem] 探针启动")

func _process(delta: float) -> void:
	if main == null:
		return
	t += delta
	if t < 10.0:
		if main.get("session_ready") != true:
			return
		if t < 10.0:
			return
	set_process(false)
	_dump()

func _dump() -> void:
	var mb := 1048576.0
	# ---- 1) 进程工作集（对齐任务管理器）----
	var pid := OS.get_process_id()
	var out: Array = []
	OS.execute("tasklist", ["/FI", "PID eq %d" % pid, "/FO", "CSV", "/NH"], out)
	var ws_line := str(out[0]) if out.size() > 0 else ""
	var ws_mb := -1.0
	# 形如 "xxx.exe","1234","Console","1","287,412 K"
	var parts := ws_line.split(",")
	if parts.size() >= 5:
		var k := str(parts[4]).strip_edges().replace("\"", "").replace(" K", "").replace(",", "")
		ws_mb = float(k) / 1024.0
	print("[mem] ① 进程工作集（任务管理器口径）= %.0f MB" % ws_mb)

	# ---- 2) Godot 资源堆 ----
	var stat: float = Performance.get_monitor(Performance.MEMORY_STATIC) / mb
	var stat_max: float = Performance.get_monitor(Performance.MEMORY_STATIC_MAX) / mb
	var obj_cnt: int = Performance.get_monitor(Performance.OBJECT_COUNT)
	var res_cnt: int = Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)
	var node_cnt: int = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var orphan_cnt: int = Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	print("[mem] ② Godot 资源堆 = %.0f MB（峰值 %.0f MB）对象 %d / 资源 %d / 节点 %d（孤儿 %d）"
		% [stat, stat_max, obj_cnt, res_cnt, node_cnt, orphan_cnt])

	# ---- 3) 显存 ----
	var video: float = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) / mb
	var tex: float = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED) / mb
	var buf: float = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_BUFFER_MEM_USED) / mb
	var vd: RenderingDevice = RenderingServer.get_rendering_device()
	var rd_tex := -1.0
	var rd_buf := -1.0
	if vd != null:
		rd_tex = vd.get_memory_usage(RenderingDevice.MEMORY_TEXTURES) / mb
		rd_buf = vd.get_memory_usage(RenderingDevice.MEMORY_BUFFERS) / mb
	print("[mem] ③ 显存总账 = %.0f MB（纹理 %.0f + 缓冲 %.0f）" % [video, tex, buf])
	print("[mem]    RenderingDevice 分项：纹理 %.0f MB / 缓冲 %.0f MB（其余 ≈ 渲染目标/交换链等内部分配）"
		% [rd_tex, rd_buf])

	# ---- 4) 系统 ----
	var mi := OS.get_memory_info()
	print("[mem] ④ 系统内存：物理 %.0f MB / 可用 %.0f MB" % [
		float(mi.get("physical", 0)) / mb, float(mi.get("available", 0)) / mb])

	# ---- 5) 差额解释 ----
	print("[mem] ⑤ 账目关系：工作集 ≈ 资源堆 + 引擎/驱动运行时开销 + Mono堆 + 代码段；")
	print("[mem]    显存是 GPU 侧独立记账，不进工作集（集显除外）。")
	print("[mem] 完成")
	get_tree().quit(0)
