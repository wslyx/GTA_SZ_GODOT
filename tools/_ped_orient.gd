extends Node3D
##
## 行人朝向探针：把 `pedestrian.glb` 并排摆两份 —— 左 = MINUS_Z 约定
## （rotation.y = -yaw，本届修复后用的），右 = PLUS_Z 约定（rotation.y = PI - yaw，
## 修复前用的）。相机放在**南侧**向北平视：
##   正面对着南（相机）的一位 = 朝向约定错了；背对相机（看得到后脑/头发）的才对。
##
## 用法：
##   Godot_v4.7.x_console.exe --path . --resolution 900x600 res://tools/_ped_orient.tscn
## 产物：res://tools/shots/ped_orient.png

const OUT := "res://tools/shots/ped_orient.png"
const OUT_SIDE := "res://tools/shots/ped_orient_side.png"
const GAP := 0.75
## 数据 yaw = 0（正北），world 前向 = (sin0, 0, -cos0) = (0,0,-1) ⇒ 背对南侧相机
const YAW := 0.0

## 视角：front = 南侧平视（看脸/后背）；side = 东侧平视（看脚尖朝向）
var _view := "front"


func _ready() -> void:
	_view = OS.get_environment("PED_ORIENT_VIEW")
	if _view.is_empty():
		_view = "front"
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("res://tools/shots"))
	_build_env()
	# 平视：两人左右排（沿 X）；侧视：两人前后排（沿 Z），否则会互相遮挡
	var row_x := _view == "front"
	var a := Vector3(-GAP, 0.0, 0.0) if row_x else Vector3(0.0, 0.0, -GAP)
	var b := Vector3(GAP, 0.0, 0.0) if row_x else Vector3(0.0, 0.0, GAP)
	_spawn("minusZ(修复后)", a, CoordinateUtil.node_yaw(YAW, CoordinateUtil.ModelForward.MINUS_Z))
	_spawn("plusZ(修复前)", b, CoordinateUtil.node_yaw(YAW, CoordinateUtil.ModelForward.PLUS_Z))
	await _shoot()


func _build_env() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.16, 0.18, 0.2)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.78, 0.82)
	env.ambient_light_energy = 0.8
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.6
	sun.rotation_degrees = Vector3(-52.0, 28.0, 0.0)
	sun.shadow_enabled = false
	add_child(sun)

	var cam := Camera3D.new()
	cam.fov = 46.0
	if _view == "side":
		# 东侧（+X）平视：脚尖朝 -Z（画面左后）说明朝向约定对
		cam.global_transform = Transform3D(Basis.IDENTITY, Vector3(3.4, 1.15, 0.15))
	elif _view == "feet":
		# 贴地近摄：只看两只脚，脚尖朝向一目了然
		cam.fov = 34.0
		cam.global_transform = Transform3D(Basis.IDENTITY, Vector3(1.55, 0.55, 0.0))
		add_child(cam)
		cam.look_at(Vector3(0.0, 0.06, 0.0))
		cam.current = true
		return
	elif _view == "top":
		# 正上方俯视，up 取 -Z（正北）：画面**上**方 = 正北，脚尖朝上说明在朝北走
		cam.fov = 40.0
		cam.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 3.6, 0.0))
		add_child(cam)
		cam.look_at_from_position(Vector3(0.0, 3.6, 0.0), Vector3(0.0, 0.4, 0.0), Vector3(0.0, 0.0, -1.0))
		cam.current = true
		return
	else:
		# 南侧（+Z）向北平视，目标点取人物胸口高度
		cam.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 1.25, 2.9))
	add_child(cam)
	cam.look_at(Vector3(0.0, 1.0, 0.0))
	cam.current = true


func _spawn(label: String, at: Vector3, yaw_node: float) -> void:
	var packed: PackedScene = load("res://data/city/pedestrian.glb")
	if packed == null:
		push_error("[ped_orient] 行人模型加载失败")
		return
	var inst: Node3D = packed.instantiate()
	inst.position = at
	inst.rotation.y = yaw_node
	add_child(inst)
	# 地面参照：一小块深色板，方便判断脚底位置
	var body := StaticBody3D.new()
	var mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(0.9, 0.9)
	mi.mesh = plane
	mi.position = at
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.32, 0.34)
	mi.material_override = mat
	body.add_child(mi)
	add_child(body)
	var tag := Label3D.new()
	tag.text = label
	tag.font_size = 48
	tag.pixel_size = 0.0022
	tag.position = at + Vector3(0.0, 1.95, 0.0)
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(tag)


func _shoot() -> void:
	# 等两帧：第一帧走完 _ready 的建树，第二帧保证所有网格已进渲染队列
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(
		OUT_SIDE if _view == "side" else ("res://tools/shots/ped_orient_top.png" if _view == "top"
			else ("res://tools/shots/ped_orient_feet.png" if _view == "feet" else OUT)))
	var err := img.save_png(path)
	print("[ped_orient] 已保存 %s (err=%d, %dx%d)" % [path, err, img.get_width(), img.get_height()])
	get_tree().quit(0)
