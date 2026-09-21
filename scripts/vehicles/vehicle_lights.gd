extends Node3D
class_name VehicleLights
##
## 载具灯组 —— 移植原版 city-world.ts 的 vehicleLightRig。
##
## 原版踩过的坑很关键，这里原样保留其结论：
##   切换载具、附近灯光变化与异步 GLB 加载会改变已有材质的灯光配置，触发大量
##   PBR 着色器重编译，尚未准备好的子网格被跳过，天空从缺口透出来。
##   修复办法是把载具灯具挂到一个**独立、持续启用**的节点上，而不是跟着载具
##   一起 enable/disable；局部灯光也保持固定配置，只改强度表示亮灭。
##
## 所以本节点始终 visible，只改 light_energy / 自发光强度。

## 前照灯（原版 SpotLight 参数）
const HEAD_COLOR := Color(0.78, 0.87, 1.0)
const HEAD_INTENSITY := 250.0
const HEAD_RANGE := 65.0
const HEAD_ANGLE := PI / 3.0
## 前灯在**车模局部**的偏移。车模（car.glb）的机头/车头在 -Z（前轮 Z=-1.43，
## 后轮 Z=+1.78），所以前灯要装在 z = -2.25、尾灯装在 z = +2.2。
## 之前两者是反的：前灯被放到车尾、尾灯被放到车头。
const HEAD_OFFSET := Vector3(0.6, 0.82, -2.25)
const TAIL_OFFSET := Vector3(0.72, 0.72, 2.2)
const HEAD_DIR := Vector3(0.0, -0.055, 1.0)

## 尾灯
const TAIL_COLOR := Color(0.9, 0.12, 0.08)
const TAIL_BRAKE_COLOR := Color(1.0, 0.22, 0.12)
const REVERSE_COLOR := Color(0.95, 0.95, 0.88)

var headlights: Array[SpotLight3D] = []
var tail_left: OmniLight3D
var tail_right: OmniLight3D
var tail_left_mi: MeshInstance3D
var tail_right_mi: MeshInstance3D
var fill_light: OmniLight3D

var mode: int = GameContent.LightMode.SUNSET
var braking := false
var reversing := false
var lights_on := true
var _built := false


func build() -> void:
	if _built:
		return
	for side in [-1.0, 1.0]:
		var l := SpotLight3D.new()
		l.name = "headlight-%s" % ("l" if side < 0.0 else "r")
		l.light_color = HEAD_COLOR
		l.light_energy = HEAD_INTENSITY / 100.0
		l.spot_range = HEAD_RANGE
		l.spot_angle = rad_to_deg(HEAD_ANGLE)
		l.spot_angle_attenuation = 4.0
		l.shadow_enabled = false
		l.position = Vector3(HEAD_OFFSET.x * side, HEAD_OFFSET.y, HEAD_OFFSET.z)
		# SpotLight3D 默认沿自身 **-Z** 发光，车头也在 -Z，所以不需要旋转。
		# 之前注释写"车头在 glTF 里为 +Z"是错的，已按实测纠正。
		l.rotation = Vector3(0.0, 0.0, 0.0)
		add_child(l)
		headlights.append(l)

	for side in [-1.0, 1.0]:
		var t := OmniLight3D.new()
		t.name = "taillight-%s" % ("l" if side < 0.0 else "r")
		t.light_color = TAIL_COLOR
		t.light_energy = 0.3
		t.omni_range = 6.0
		t.shadow_enabled = false
		t.position = Vector3(TAIL_OFFSET.x * side, TAIL_OFFSET.y, TAIL_OFFSET.z)
		add_child(t)
		if side < 0.0:
			tail_left = t
		else:
			tail_right = t

	fill_light = OmniLight3D.new()
	fill_light.name = "car-fill"
	fill_light.light_color = Color(0.82, 0.86, 0.92)
	fill_light.light_energy = 0.0
	fill_light.omni_range = 12.0
	fill_light.shadow_enabled = false
	fill_light.position = Vector3(0.0, 1.6, 0.0)
	add_child(fill_light)

	_built = true
	# 本节点**永不隐藏**，只改强度（见类注释）
	visible = true


func set_light_mode(m: int) -> void:
	mode = m
	var night := m == GameContent.LightMode.NIGHT
	lights_on = night
	for l in headlights:
		l.light_energy = (HEAD_INTENSITY / 100.0) if night else 0.0
	if fill_light != null:
		fill_light.light_energy = 2.6 if night else 0.0
	_apply_tail()


## 跟随载具位姿（世界坐标）
func place(world_transform: Transform3D) -> void:
	global_transform = world_transform


func update_brake(braking_flag: bool, reversing_flag: bool) -> void:
	braking = braking_flag
	reversing = reversing_flag
	_apply_tail()


func _apply_tail() -> void:
	var night := mode == GameContent.LightMode.NIGHT
	if tail_left == null:
		return
	if reversing:
		tail_left.light_color = REVERSE_COLOR
		tail_right.light_color = REVERSE_COLOR
		tail_left.light_energy = 1.2
		tail_right.light_energy = 1.2
		return
	tail_left.light_color = TAIL_BRAKE_COLOR if braking else TAIL_COLOR
	tail_right.light_color = tail_left.light_color
	var e := 0.3
	if braking:
		e = 2.4 if night else 1.6
	elif night:
		e = 0.8
	tail_left.light_energy = e
	tail_right.light_energy = e


func diagnostics() -> Dictionary:
	return {"built": _built, "headlights": headlights.size(),
			"energy": headlights[0].light_energy if not headlights.is_empty() else 0.0,
			"braking": braking, "reversing": reversing, "mode": mode}
