extends Node3D
##
## 火球体积着色器的独立渲染探针：不进游戏、不撞机，直接看那支
## 28 步 fbm 光线步进画出来的火球长什么样。
##
## 用法：
##   tools\run_godot.bat --headless res://tools/_fireball_probe.tscn   # 无头没图
##   Godot_v4.7.x_console.exe --path . --resolution 900x600 res://tools/_fireball_probe.tscn
## 产物：tools/shots/fireball.png

const OUT := "res://tools/shots/fireball.png"


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tools/shots"))
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.06, 0.08)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var shader := load("res://shaders/flight_fireball.gdshader") as Shader
	var mat := ShaderMaterial.new()
	mat.shader = shader
	var eye := Vector3(0.0, 1.1, 4.2)
	mat.set_shader_parameter("eye_world", eye)
	mat.set_shader_parameter("age", 0.55)
	mat.set_shader_parameter("seed", 1.3)
	mat.set_shader_parameter("heat", 1.0)
	mat.set_shader_parameter("opacity", 1.0)
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3.ONE * 2.0
	mi.mesh = box
	mi.material_override = mat
	add_child(mi)

	var cam := Camera3D.new()
	cam.fov = 50.0
	add_child(cam)
	cam.look_at_from_position(eye, Vector3.ZERO, Vector3.UP)
	cam.current = true

	_shoot()


func _shoot() -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(OUT)
	var err := img.save_png(path)
	print("[fireball-probe] 已保存 %s (err=%d)" % [path, err])
	get_tree().quit(0)
