extends Node
## 内存探针（常驻诊断工具）：周期采样 + 阶段埋点，供持续优化用。
##   - _process 周期行：看整体走势（static = Godot 资源堆；video/tex = 渲染器记账设备内存）
##   - MemProbe.mark("xxx")：构建期主线程被阻塞、_process 不跑，关键调用之间手工打点用
##   - 主线程停滞看门狗（2026-11-04）：后台线程盯 process 帧号，停超 8s 就把
##     phase（主循环最近写入的执行阶段）打到日志 —— 行车 2km 卡死这类"无限
##     帧阻塞"没有尸体日志，靠它锁定卡住的位置。
## 读数口径：进程级提交内存/工作集用任务管理器或外部采样对齐（驱动上传堆不在 static/video 里）。

const INTERVAL := 2.0
const STALL_WARN_SEC := 8.0

## 主循环最近写入的执行阶段（看门狗线程只读）
static var phase := "boot"
## 帧号（主线程每帧推进；后台线程比较它判断主线程是否停滞）
static var frames_seen := 0
## 主线程采样的节点数（后台线程只读静态值，不在工作线程碰场景树）
static var nodes_seen := 0

var _t0 := 0
var _acc := 100.0  # 首帧立即打一次
var _watch_thread: Thread = null
var _watch_stop := false


## 阶段埋点：打印当前 Godot 资源堆用量。
static func mark(label: String) -> void:
	var stat := float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0
	# 启动性能归因： mark 点自带时间戳（grep [BOOT-T] 就能拉出整条时间线）
	print("[MemProbe] %s static=%.0fMB t=%.1fs" % [
		label, stat, float(Time.get_ticks_msec()) / 1000.0])


func _ready() -> void:
	_watch_thread = Thread.new()
	_watch_thread.start(_watch_worker)


func _exit_tree() -> void:
	_watch_stop = true
	if _watch_thread != null and _watch_thread.is_started():
		_watch_thread.wait_to_finish()
	_watch_thread = null


## 后台看门狗：主线程帧号停超阈值时从工作线程打日志（print 线程安全）。
## 停滞期间每 8s 报一次"卡在哪个阶段"，恢复时报一次总时长。
func _watch_worker() -> void:
	var last_frames := -1
	var stall_start := 0
	var last_warn := 0
	var ongoing := false
	while not _watch_stop:
		OS.delay_msec(500)
		var now := Time.get_ticks_msec()
		var f := frames_seen
		if f != last_frames:
			if ongoing:
				print("[MemProbe] 主线程停滞 %.1fs 后恢复 phase=\"%s\"" % [
					(now - stall_start) / 1000.0, phase])
				ongoing = false
			last_frames = f
			stall_start = now
			last_warn = 0
			continue
		if last_frames < 0:
			last_frames = f
			stall_start = now
			continue
		var stalled := (now - stall_start) / 1000.0
		if stalled >= STALL_WARN_SEC and now - last_warn >= STALL_WARN_SEC * 1000:
			print("[MemProbe] ⚠ 主线程停滞 %.0fs phase=\"%s\" nodes=%d" % [
				stalled, phase, nodes_seen])
			last_warn = now
			ongoing = true


func _process(delta: float) -> void:
	frames_seen = Engine.get_process_frames()
	nodes_seen = get_tree().get_node_count()
	_acc += delta
	if _acc < INTERVAL:
		return
	_acc = 0.0
	if _t0 == 0:
		_t0 = Time.get_ticks_msec()
	var t := (Time.get_ticks_msec() - _t0) / 1000.0
	var video := float(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)) / 1048576.0
	var tex := float(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED)) / 1048576.0
	var stat := float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0
	var nodes := get_tree().get_node_count()
	print("[MemProbe] t=%.0fs static=%.0fMB video=%.0fMB tex=%.0fMB nodes=%d"
		% [t, stat, video, tex, nodes])
