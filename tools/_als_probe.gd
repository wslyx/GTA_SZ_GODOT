extends Node
##
## ALS 角色功能探针（**无头也能跑**，不需要显卡）。
##
## 为什么需要它：ALS 的失败点在 C# 宿主 _Ready() 的资产校验，一旦抛异常
## RuntimeReady=false，下车就"没有人"。这类问题用日志看得到，但"人到底有没有
## 进场景、是不是站在地上、骨骼在不在"要看**场景树**，不是看画面。
## 无头模式下场景树、物理、C# 逻辑照常跑，所以这里直接下车并检查角色。
##
## 用法：
##   tools\run_godot.bat --headless res://tools/_als_probe.tscn
##
## 输出：一串 [als-probe] 行，最后 print 结论（OK / FAIL）。

const SCENE := "res://scenes/main.tscn"
const WARMUP_SEC := 13.0     ## 建城约 13s（二进制快照路径）
const AFTER_ENTER_SEC := 2.5 ## 下车后等角色落地/绑定

var main: Node = null
var _elapsed := 0.0
var _stage := 0
var _enter_at := 0.0


func _ready() -> void:
	var packed: PackedScene = load(SCENE)
	if packed == null:
		push_error("[als-probe] 主场景加载失败")
		get_tree().quit(1)
		return
	main = packed.instantiate()
	add_child(main)
	print("[als-probe] 主场景已加入，等待建城（%.0fs）…" % WARMUP_SEC)


func _process(delta: float) -> void:
	if main == null:
		return
	_elapsed += delta

	if _stage == 0:
		var ready := bool(main.get("session_ready"))
		if ready or _elapsed > WARMUP_SEC + 20.0:
			print("[als-probe] session_ready=%s（用时 %.1fs）" % [str(ready), _elapsed])
			_report_static()
			_enter_on_foot()
			_stage = 1
			_enter_at = _elapsed
		return

	if _stage == 1 and _elapsed - _enter_at >= AFTER_ENTER_SEC:
		_stage = 2
		_verify_walking()


## 下车前的静态检查：宿主在不在、RuntimeReady 是否真
func _report_static() -> void:
	var host: Node = main.get("_als_host")
	if host == null:
		print("[als-probe] FAIL：_als_host 为 null（C# 宿主没装配，GodotALS.csproj 没编译？）")
		return
	var runtime_ready = host.get("RuntimeReady")
	print("[als-probe] 宿主=%s RuntimeReady=%s 子节点=%d" % [
		host.name, str(runtime_ready), host.get_child_count()])
	var skel := _find_skeleton(host)
	print("[als-probe] 骨骼节点：%s" % (skel.get_path() if skel != null else "<未找到>"))


## 按 F 下车
func _enter_on_foot() -> void:
	var mode_before = int(main.get("mode"))
	main.call("_toggle_vehicle_entry")
	print("[als-probe] 已调用下车：mode %d → %d" % [mode_before, int(main.get("mode"))])


## 下车后的关键断言
func _verify_walking() -> void:
	var ok := true
	var host: Node = main.get("_als_host")
	var walk_active = main.get("_als_walk_active")
	print("[als-probe] _als_walk_active=%s" % str(walk_active))
	if not bool(walk_active):
		print("[als-probe] FAIL：下车后 _als_walk_active 仍为 false —— 角色没进世界")
		ok = false

	if host != null:
		var runtime_ready = bool(host.get("RuntimeReady"))
		print("[als-probe] 下车后 RuntimeReady=%s" % str(runtime_ready))
		if not runtime_ready:
			ok = false
		var skel := _find_skeleton(host)
		if skel == null:
			print("[als-probe] FAIL：宿主下没有 Skeleton3D")
			ok = false
		else:
			var bones: int = skel.get_bone_count()
			print("[als-probe] Skeleton3D 骨骼数=%d" % bones)
			if bones <= 0:
				ok = false
		# 位置要看**可视根节点**：宿主自己的 transform 一直是原点，
		# 角色实际由 CharacterSlot 下的 mannequin 摆放（原版同一个结构）
		var visual: Node3D = skel.get_parent() as Node3D
		if visual != null:
			var p := visual.global_position
			print("[als-probe] 可视根=%s 世界坐标=(%.1f, %.1f, %.1f) visible=%s" % [
				visual.name, p.x, p.y, p.z, str(visual.visible)])
			# 出生点在 (2800 左右)，若仍在原点附近说明没被摆到车旁
			if Vector2(p.x, p.z).length() < 100.0:
				print("[als-probe] 注意：可视根仍在世界原点附近（出生点应在 2800m 外）")
		var car_pos := Vector3.ZERO
		if main.get("mode") != null:
			var car = main.get("car")
			if car != null:
				car_pos = CoordinateUtil.to_world(float(car.x), float(car.z),
					float(main.get("world").height_field.height_at(car.x, car.z)))
				print("[als-probe] 车位置=(%.1f, %.1f, %.1f) 与角色水平距离=%.1f m" % [
					car_pos.x, car_pos.y, car_pos.z,
					Vector2(visual.global_position.x - car_pos.x,
						visual.global_position.z - car_pos.z).length()])

	print("[als-probe] 结论：%s" % ("OK —— ALS 角色已进入场景" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for c in node.get_children():
		var found := _find_skeleton(c)
		if found != null:
			return found
	return null
