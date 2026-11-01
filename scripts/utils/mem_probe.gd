extends Node
## 内存探针（常驻诊断工具）：周期采样 + 阶段埋点，供持续优化用。
##   - _process 周期行：看整体走势（static = Godot 资源堆；video/tex = 渲染器记账设备内存）
##   - MemProbe.mark("xxx")：构建期主线程被阻塞、_process 不跑，关键调用之间手工打点用
## 读数口径：进程级提交内存/工作集用任务管理器或外部采样对齐（驱动上传堆不在 static/video 里）。

const INTERVAL := 2.0

var _t0 := 0
var _acc := 100.0  # 首帧立即打一次


## 阶段埋点：打印当前 Godot 资源堆用量。
static func mark(label: String) -> void:
	var stat := float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0
	# 启动性能归因： mark 点自带时间戳（grep [BOOT-T] 就能拉出整条时间线）
	print("[MemProbe] %s static=%.0fMB t=%.1fs" % [
		label, stat, float(Time.get_ticks_msec()) / 1000.0])


func _process(delta: float) -> void:
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
