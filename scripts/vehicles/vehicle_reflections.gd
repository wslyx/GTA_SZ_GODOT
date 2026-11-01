extends Node3D
##
## 主角车漆反射 —— 移植原版 src/city-vehicle-reflections.ts。
##
## 原版做法（77 行，值得照抄的关键决策）：
##   - 128px ReflectionProbe，refreshRate=0（**手动捕获**），目标 2 次/秒；
##   - 只在「相机距车 < 65m」时启用；车**移动 ≥2m** 且距上次捕获 ≥0.5s 才重拍
##     —— 静止/匀速直行时几乎零成本；
##   - 捕获点在车顶上 1.1m，renderList 只装附近建筑（按距离排序 + 预算截断）。
##
## Godot 对应物：`ReflectionProbe` + `UPDATE_ONCE`（拍一张然后闲置，需要时再触发）。
## 差异与代价：
##   - Godot 不能只渲染"附近 200 个网格"，盒子里的东西全会进 —— 所以盒子
##     尺寸给 90m（罩住近处楼），靠 2Hz 节流把成本摊平；
##   - 分辨率由引擎定，配不了 128px；重挂一次 `UPDATE_ONCE` 即触发一次捕获。
##
## 挂接：作为车模的子节点随车移动；画质档 medium+ 才启用。

const PROBE_SIZE := Vector3(90.0, 60.0, 90.0)
const CAPTURE_INTERVAL := 0.5      ## 原版 targetCapturesPerSecond = 2
const CAPTURE_MOVE := 2.0          ## 原版：位移 < 2m 不重拍
const ENABLE_DISTANCE := 65.0      ## 原版：相机距车 65m 外不启用

var enabled := false
var captures := 0
var meshes_budget := 0

var _probe: ReflectionProbe
var _last_capture_pos := Vector3.ZERO
var _last_capture_time := -INF
var _camera: Camera3D


func setup(camera: Camera3D) -> void:
	_camera = camera
	_probe = ReflectionProbe.new()
	_probe.name = "VehicleReflectionProbe"
	_probe.size = PROBE_SIZE
	_probe.update_mode = ReflectionProbe.UPDATE_ONCE
	_probe.intensity = 0.8
	_probe.box_projection = true
	_probe.position = Vector3(0.0, 1.1, 0.0)   ## 原版：车顶上 1.1m
	add_child(_probe)
	set_enabled(true)


## 原版 setEnabled
func set_enabled(value: bool) -> void:
	enabled = value
	if _probe != null:
		_probe.visible = value
	if not value:
		_last_capture_time = -INF


## 每帧调用（车在动，开销是两个 distance_squared + 几个比较）
func update_vehicle(camera_pos: Vector3, dt: float) -> void:
	if not enabled or _probe == null or _camera == null:
		return
	# 原版：相机离车太远就整个停掉（这时的车漆由 IBL/SSR 顶着）
	if camera_pos.distance_squared_to(global_position) > ENABLE_DISTANCE * ENABLE_DISTANCE:
		return
	var now := Time.get_ticks_msec() / 1000.0
	var moved := global_position.distance_squared_to(_last_capture_pos)
	if now - _last_capture_time < CAPTURE_INTERVAL:
		return
	if captures > 0 and moved < CAPTURE_MOVE * CAPTURE_MOVE:
		return
	# 重新武装一次捕获。ReflectionProbe 没有手动 capture()，也没有 DISABLE 档，
	# 社区做法就是 ALWAYS→ONCE 两步：中间那一帧按 ALWAYS 跑（2Hz 下可忽略）。
	_probe.update_mode = ReflectionProbe.UPDATE_ALWAYS
	_probe.update_mode = ReflectionProbe.UPDATE_ONCE
	captures += 1
	_last_capture_time = now
	_last_capture_pos = global_position


func diagnostics() -> Dictionary:
	return {
		"enabled": enabled,
		"captures": captures,
		"size": PROBE_SIZE,
		"capturesPerSecond": 2.0,
	}
