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
##   - Godot 不能只渲染"附近 200 个网格"，盒子里的东西全会进 —— 所以靠
##     2Hz 节流把成本摊平；分辨率由引擎定，配不了 128px；重挂一次
##     `UPDATE_ONCE` 即触发一次捕获。
##   - ⚠️ 影响域（2026-11-03，修复记录 五十一）：原版 Babylon 的探针贴图**只赋给
##     车漆材质**；Godot 的 ReflectionProbe 是逐像素硬边界影响 —— 盒内所有像素
##     （包括路面）都改用探针反射，盒外用天空 IBL。曾经照抄原版给 90m 盒子，
##     结果盒子前表面在车前方 ~45m 的路面上投出一条**随车移动的明暗分界线**
##     （探针内容 ≠ 天空 radiance，粗糙沥青两侧反射不同亮度）。unshaded 调试
##     视图下消失（跳过反射）、隐藏网格/关 SSR/SSAO/阴影都无效 —— 这条线曾长期
##     误诊为 IBL/几何问题。
##   - 修法：盒子压扁 + 抬高下沿到 0.9m，把路面（车局部 y≈0~0.3）整个排除在
##     影响域外；横向收到 12m，容忍坡度（0.6m 余量 / 12m = 5% 坡）与车身俯仰。
##     立方图内容仍是全场景捕获，车漆（0.9~2.9m 高的车身）反射不受影响。
##
## 挂接：作为车模的子节点随车移动；画质档 medium+ 才启用。

const PROBE_SIZE := Vector3(12.0, 2.0, 12.0)
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
	# 下沿 = 1.9 - 2.0/2 = 0.9m：路面在车局部 y≈0~0.3，整条排除在影响域外；
	# 车身（顶 ~1.3m）仍在盒内。此前 90m 盒 + 下沿 -28.9m 会把 45m 内路面全罩进。
	_probe.position = Vector3(0.0, 1.9, 0.0)
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
