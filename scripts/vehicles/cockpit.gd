extends Node3D
class_name Cockpit
##
## 驾驶舱内舱 + 仪表 —— 移植原版 src/city-cockpit.ts（createCityCockpit）。
##
## 原版做了三件事，这里逐条对应：
##   1. **裁掉模型自带的转向盘体积**：`car_leather` / `car_trim` 里有一坨
##      模压出来的方向盘与中控，正好挡在司机位视线里。原版用
##      “三角形三个顶点都落在盒内就丢”的方式，把局部盒
##      x∈±.205 / y∈.54…​.97 / z∈.69…​.92 内的三角形删掉（Babylon 局部 +Z 为车头），
##      再单独保存一份裁剪副本，只在座舱视角显示。
##      Godot 这边直接**原地裁剪**这两个网格的索引（省一份几何，也不用两份显隐）。
##   2. **内舱几何**：仪表舱壳（圆角环扫）、金属薄边框、方向盘（轮缘+气囊+三根
##      辐条）、转向柱、氛围缝。
##   3. **实时仪表**：原版是张 1024×384 的 DynamicTexture（canvas 画的），
##      10Hz、值变了才重画：速度大字 + 挡位 + 灯光/电量 + 进度条 + TRIP + 转向。
##      Godot 里用 QuadMesh 当屏 + 若干 Label3D 当文字（不占 viewport、不用
##      每帧生成贴图），刷新同样节流到 10Hz。
##
## ⚠️ 坐标换算（最容易踩的一处）
##   原版全部坐标写在 **Babylon 车体局部空间（+Z = 车头）**；Godot 的 car.glb
##   是原样载入的 glTF，**车头 −Z**。所以：
##       z → −z            （前后翻转）
##       rotation.x → −x   （绕 X 的倾角跟着翻，即 M·R·M 共轭，M = diag(1,1,−1)）
##   例：原版仪表舱 (0, .94, 1.026) 倾角 .12 → 本文件 (0, .94, −1.026) 倾角 −.12。
##
## 显隐：`set_active(true)` 时隐藏 `car_glass`（原版同样把 sourceGlass 关掉，
## 否则挡风玻璃的反射/贴膜会糊住整块画面），并显示内舱几何；反之亦然。

## 原版 CITY_DRIVER_POSE 的等价常量在 chase_camera.gd（COCKPIT_POSITION/LOOK_AHEAD）
const NEAR := 0.04

## 原版裁切盒（已换算到 Godot 的 −Z 前向）
const CLIP_MIN := Vector3(-0.205, 0.54, -0.92)
const CLIP_MAX := Vector3(0.205, 0.97, -0.69)

## 仪表刷新节流（原版 100ms）
const PAINT_INTERVAL := 0.1

var car_root: Node3D
var active := false

var _screen_root: Node3D
var _wheel_rotor: Node3D
var _speed_label: Label3D
var _gear_label: Label3D
var _lamp_label: Label3D
var _trip_label: Label3D
var _steer_label: Label3D

## 只在座舱视角显示的节点（内舱几何）
var _cockpit_only: Array[Node3D] = []
## 进入座舱时要隐藏的网格（挡风玻璃等）
var _hidden_in_cockpit: Array[Node3D] = []
## 裁剪统计，供诊断/文档用
var clipped_triangles := 0
var clipped_meshes: Array[String] = []

var _paint_age := 999.0
var _last_key := ""


func setup(p_car_root: Node3D) -> void:
	car_root = p_car_root
	_collect_and_clip()
	_build_interior()
	set_active(false)


## 找出内饰/玻璃网格：内饰做裁切，玻璃在座舱视角隐藏。
## （原版按名字正则 /^car_(leather|trim)(\.\d+)?$/ 与 /^car_glass(\.\d+)?$/ 匹配）
func _collect_and_clip() -> void:
	var stack: Array[Node] = [car_root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D:
			var nm := String(n.name).to_lower()
			if nm.begins_with("car_glass"):
				_hidden_in_cockpit.append(n as Node3D)
			elif nm.begins_with("car_leather") or nm.begins_with("car_trim"):
				var removed := _clip_dashboard(n as MeshInstance3D)
				if removed > 0:
					clipped_triangles += removed
					clipped_meshes.append("%s:%d" % [n.name, removed])
	if clipped_triangles > 0:
		print("[Cockpit] 裁掉挡视线的内饰三角形 %d 个：%s" % [
			clipped_triangles, ", ".join(clipped_meshes)])


## 三角形三个顶点都在盒内才丢（与原版判定一致）
func _inside(v: Vector3) -> bool:
	return v.x > CLIP_MIN.x and v.x < CLIP_MAX.x \
		and v.y > CLIP_MIN.y and v.y < CLIP_MAX.y \
		and v.z > CLIP_MIN.z and v.z < CLIP_MAX.z


func _clip_dashboard(mi: MeshInstance3D) -> int:
	var mesh := mi.mesh as ArrayMesh
	if mesh == null:
		return 0
	var out := ArrayMesh.new()
	var removed := 0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		if arrays.is_empty():
			continue
		var idx = arrays[Mesh.ARRAY_INDEX]
		if idx == null:
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		else:
			var src: PackedInt32Array = idx
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var keep := PackedInt32Array()
			var i := 0
			while i + 2 < src.size():
				var a := verts[src[i]]
				var b := verts[src[i + 1]]
				var c := verts[src[i + 2]]
				if _inside(a) and _inside(b) and _inside(c):
					removed += 1
				else:
					keep.append(src[i])
					keep.append(src[i + 1])
					keep.append(src[i + 2])
				i += 3
			if keep.size() == src.size():
				out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			else:
				arrays[Mesh.ARRAY_INDEX] = keep
				out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out.surface_set_material(out.get_surface_count() - 1, mesh.surface_get_material(s))
	if removed > 0:
		# 表面顺序不变，所以 VehicleMaterials 打的 surface override 仍然有效
		mi.mesh = out
	return removed


# ---------------------------------------------------------------------------
# 内舱几何（坐标已换算到 Godot 的 −Z 前向）
# ---------------------------------------------------------------------------

func _mat(color: Color, rough: float, metal := 0.0, emissive := Color.BLACK) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = metal
	if emissive != Color.BLACK:
		m.emission_enabled = true
		m.emission = emissive
		m.emission_energy_multiplier = 1.0
	return m


func _mesh_node(mesh: Mesh, pos: Vector3, rot_deg: Vector3, material: Material,
		parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.position = pos
	mi.rotation_degrees = rot_deg
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	(parent if parent != null else self).add_child(mi)
	return mi


func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


func _build_interior() -> void:
	var graphite := _mat(Color(0.024, 0.030, 0.038), 0.72)
	var metal := _mat(Color(0.22, 0.25, 0.28), 0.36, 0.72)
	var rubber := _mat(Color(0.015, 0.019, 0.025), 0.68)
	var lit := _mat(Color(0.045, 0.15, 0.20), 0.45, 0.0, Color(0.025, 0.13, 0.19))

	# --- 仪表舱壳 + 支脚 + 中控台（原版 instrument-shell / foot / centre-console）
	var shell := _mesh_node(_box(Vector3(0.48, 0.166, 0.062)),
		Vector3(0.0, 0.94, -1.026), Vector3(-6.9, 0.0, 0.0), graphite)
	_cockpit_only.append(shell)
	_cockpit_only.append(_mesh_node(_box(Vector3(0.22, 0.055, 0.11)),
		Vector3(0.0, 0.836, -1.104), Vector3.ZERO, graphite))
	_cockpit_only.append(_mesh_node(_box(Vector3(0.16, 0.035, 0.25)),
		Vector3(0.35, 0.647, -0.74), Vector3.ZERO, graphite))
	# 氛围缝（原版 ambient-seam）
	_cockpit_only.append(_mesh_node(_box(Vector3(0.24, 0.0025, 0.006)),
		Vector3(0.0, 0.852, -1.023), Vector3.ZERO, lit))

	# --- 显示屏：深色自发光底板 + 文字（原版 live_instrument_screen 0.46×0.15）
	_screen_root = Node3D.new()
	_screen_root.position = Vector3(0.0, 0.94, -0.994)
	_screen_root.rotation_degrees = Vector3(-6.9, 0.0, 0.0)
	add_child(_screen_root)
	_cockpit_only.append(_screen_root)

	var screen := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.452, 0.148)
	screen.mesh = quad
	var screen_mat := _mat(Color(0.031, 0.059, 0.082), 0.6)
	screen_mat.emission_enabled = true
	screen_mat.emission = Color(0.02, 0.05, 0.07)
	screen_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	screen.material_override = screen_mat
	_screen_root.add_child(screen)

	_speed_label = _label(Vector3(0.0, 0.012, 0.002), 76, Color(0.93, 0.96, 0.95))
	_speed_label.text = "000"
	_gear_label = _label(Vector3(-0.175, 0.036, 0.002), 40, Color(0.45, 0.82, 0.75))
	_gear_label.text = "P"
	_lamp_label = _label(Vector3(0.09, 0.052, 0.002), 20, Color(0.66, 0.73, 0.74))
	_lamp_label.text = "日间行车灯"
	_trip_label = _label(Vector3(-0.175, -0.052, 0.002), 19, Color(0.56, 0.65, 0.67))
	_trip_label.text = "TRIP 0.0 KM"
	_trip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_steer_label = _label(Vector3(0.175, -0.052, 0.002), 19, Color(0.56, 0.65, 0.67))
	_steer_label.text = "方向回正"
	_steer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	# --- 方向盘（原版 wheel pivot (0,.725,.79) 倾角 −.13 → 此处 +.13）
	_wheel_rotor = Node3D.new()
	_wheel_rotor.position = Vector3(0.0, 0.725, -0.79)
	_wheel_rotor.rotation_degrees = Vector3(7.45, 0.0, 0.0)
	add_child(_wheel_rotor)
	_cockpit_only.append(_wheel_rotor)

	var rim := TorusMesh.new()
	rim.inner_radius = 0.142
	rim.outer_radius = 0.176
	rim.rings = 24
	rim.ring_segments = 10
	_mesh_node(rim, Vector3.ZERO, Vector3(90.0, 0.0, 0.0), rubber, _wheel_rotor)
	_mesh_node(_box(Vector3(0.14, 0.098, 0.043)), Vector3(0.0, 0.0, 0.014), Vector3.ZERO,
		rubber, _wheel_rotor)
	# 三根辐条：左右水平 + 一根朝下（原版 spoke-left/right/bottom）
	_mesh_node(_box(Vector3(0.13, 0.027, 0.022)), Vector3(-0.095, 0.012, -0.006),
		Vector3.ZERO, metal, _wheel_rotor)
	_mesh_node(_box(Vector3(0.13, 0.027, 0.022)), Vector3(0.095, 0.012, -0.006),
		Vector3.ZERO, metal, _wheel_rotor)
	_mesh_node(_box(Vector3(0.034, 0.12, 0.023)), Vector3(0.0, -0.082, -0.007),
		Vector3.ZERO, metal, _wheel_rotor)

	# --- 转向柱（原版 shaft 在 (0,.72,.94) 水平躺倒）
	var shaft := CylinderMesh.new()
	shaft.height = 0.25
	shaft.top_radius = 0.024
	shaft.bottom_radius = 0.024
	_mesh_node(shaft, Vector3(0.0, 0.72, -0.94), Vector3(90.0, 0.0, 0.0), graphite)


func _label(pos: Vector3, size: int, color: Color) -> Label3D:
	var l := Label3D.new()
	l.position = pos
	l.font_size = size
	l.pixel_size = 0.0007
	l.modulate = color
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.no_depth_test = false
	l.double_sided = false
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	l.outline_size = 0
	_screen_root.add_child(l)
	return l


# ---------------------------------------------------------------------------
# 对外
# ---------------------------------------------------------------------------

## 原版 setActive：座舱视角隐藏 model 自带玻璃，显示内舱几何
func set_active(value: bool) -> void:
	if value == active:
		return
	active = value
	for n in _hidden_in_cockpit:
		if is_instance_valid(n):
			n.visible = not value
	for n in _cockpit_only:
		if is_instance_valid(n):
			n.visible = value
	if value:
		_last_key = ""      # 强制下一帧重画一次仪表


## 原版 update(speed, steer, state)：转向盘随转向角转，仪表按需重画
func update_telemetry(speed_mps: float, steer: float, throttle_negative: bool,
		night: bool, distance_m: float, dt: float) -> void:
	if not active:
		return
	_wheel_rotor.rotation.z = -clampf(steer, -1.0, 1.0) * 2.6
	_paint_age += dt
	if _paint_age < PAINT_INTERVAL:
		return
	_paint_age = 0.0
	_paint(speed_mps, steer, throttle_negative, night, distance_m)


func _paint(speed_mps: float, steer: float, throttle_negative: bool, night: bool,
		distance_m: float) -> void:
	var kmh := mini(299, int(round(absf(speed_mps) * 3.6)))
	var gear := "P"
	if absf(speed_mps) >= 0.15:
		gear = "R" if speed_mps < 0.0 else "D"
	var trip := "%.1f" % (maxf(0.0, distance_m) / 1000.0)
	var steer_txt := "方向回正"
	if steer < -0.04:
		steer_txt = "转向 ◀"
	elif steer > 0.04:
		steer_txt = "转向 ▶"
	var key := "%d|%s|%s|%s|%s|%s" % [kmh, gear, trip, str(night), steer_txt,
		str(throttle_negative)]
	if key == _last_key:
		return
	_last_key = key
	_speed_label.text = "%03d" % kmh
	_gear_label.text = gear
	_gear_label.modulate = Color(0.90, 0.69, 0.45) if gear == "R" else Color(0.45, 0.82, 0.75)
	_lamp_label.text = "近光灯" if night else "日间行车灯"
	_trip_label.text = "TRIP  %s KM" % trip
	_steer_label.text = steer_txt


func diagnostics() -> Dictionary:
	return {
		"active": active,
		"clippedTriangles": clipped_triangles,
		"clippedMeshes": clipped_meshes,
		"hiddenInCockpit": _hidden_in_cockpit.size(),
		"cockpitNodes": _cockpit_only.size(),
	}
