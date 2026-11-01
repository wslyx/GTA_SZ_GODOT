extends Node3D
class_name FlightExplosion
##
## 飞行爆炸 —— 对应原版 src/city-flight-explosion.ts。
##
## 体积火球（2026-11-01 夜已一比一）：原版那支 133 行 GLSL（球体内部 28 步
## fbm 光线步进、自遮挡 + 烟尘夹层）已译成 `shaders/flight_fireball.gdshader`，
## 本脚本只负责调度：生成时刻表 FLIGHT_FIREBALLS、包络 fireballEnvelope、
## `eye_world` 每帧喂相机世界坐标（原版 onBind 同款）。

## 原版 FLIGHT_FIREBALLS：错开的多次爆燃，全部落在 3 秒的坠毁恢复窗内
const FIREBALLS := [
	{"at": 0.00, "offset": Vector3(0.0, 0.0, 0.0), "radius": 5.8, "seed": 1.3},
	{"at": 0.10, "offset": Vector3(5.6, 1.0, 1.5), "radius": 5.5, "seed": 7.1},
	{"at": 0.19, "offset": Vector3(-6.2, 1.8, -1.0), "radius": 6.1, "seed": 13.6},
	{"at": 0.34, "offset": Vector3(0.5, 5.0, -3.2), "radius": 7.2, "seed": 21.8},
	{"at": 0.49, "offset": Vector3(8.0, 4.5, -0.5), "radius": 6.3, "seed": 28.4},
	{"at": 0.65, "offset": Vector3(-6.8, 7.0, 2.2), "radius": 7.3, "seed": 35.1},
	{"at": 0.84, "offset": Vector3(1.2, 10.5, 0.7), "radius": 8.0, "seed": 44.6},
	{"at": 1.06, "offset": Vector3(-9.0, 3.5, -0.5), "radius": 5.1, "seed": 55.8},
	{"at": 1.21, "offset": Vector3(7.7, 9.0, 1.1), "radius": 5.8, "seed": 63.2},
]
const LIFE := 3.0

var _spheres: Array[MeshInstance3D] = []
var _mats: Array[ShaderMaterial] = []
var _origin := Vector3.ZERO
var _yaw := 0.0
var _seconds := 99.0      ## 已经过去的秒数；>= LIFE 视为熄灭


func _ready() -> void:
	_ensure_built()


## 球体池在首次使用时构建（--script 无头探针里 _ready 不触发，双保险）
func _ensure_built() -> void:
	if not _spheres.is_empty():
		return
	var shader := load("res://shaders/flight_fireball.gdshader") as Shader
	if shader == null:
		push_error("[FlightExplosion] 火球着色器加载失败")
		return
	var box := BoxMesh.new()
	box.size = Vector3.ONE * 2.0   ## 局部 ±1，与原版 CreateBox({size:2}) 一致
	for i in FIREBALLS.size():
		var mat := ShaderMaterial.new()
		mat.shader = shader
		var fb: Dictionary = FIREBALLS[i]
		mat.set_shader_parameter("seed", float(fb["seed"]))
		_mats.append(mat)
		var mi := MeshInstance3D.new()
		mi.name = "fireball-%d" % i
		mi.mesh = box
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_spheres.append(mi)


## 在命中点起爆。world_pos 是 **Godot 世界坐标**，yaw 用于把偏移转到命中局部轴。
func burst(world_pos: Vector3, yaw: float) -> void:
	_ensure_built()
	_origin = world_pos
	_yaw = yaw
	_seconds = 0.0
	var c := cos(yaw)
	var s := sin(yaw)
	for i in FIREBALLS.size():
		var fb: Dictionary = FIREBALLS[i]
		var off: Vector3 = fb["offset"]
		# 绕 Y 转到命中时的朝向（原版 offset 用的是 impact-local 轴）
		_spheres[i].position = _origin + Vector3(off.x * c + off.z * s, off.y,
			-off.x * s + off.z * c)
		_spheres[i].scale = Vector3.ONE * 0.13
	_step(0.0)


## 原版 step(seconds)：由 FlightMissiles 在每次 step 时推进
func step(seconds: float) -> void:
	_ensure_built()
	_seconds = seconds
	_step(seconds)


func _step(seconds: float) -> void:
	var alive := false
	# eye_world：原版在 onBind 里喂 activeCamera.globalPosition；这里在推进时喂
	var eye := Vector3(0.0, 2.0, 0.0)
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		eye = cam.global_position
	for i in FIREBALLS.size():
		var fb: Dictionary = FIREBALLS[i]
		var env := _envelope(seconds, float(fb["at"]))
		var mi: MeshInstance3D = _spheres[i]
		mi.visible = bool(env["visible"])
		if not mi.visible:
			continue
		alive = true
		var r: float = float(fb["radius"]) * float(env["growth"])
		mi.scale = Vector3.ONE * maxf(0.01, r)
		var mat: ShaderMaterial = _mats[i]
		mat.set_shader_parameter("eye_world", eye)
		mat.set_shader_parameter("age", float(env["age"]))
		mat.set_shader_parameter("heat", float(env["heat"]))
		mat.set_shader_parameter("opacity", float(env["opacity"]))
	if not alive and seconds >= LIFE:
		reset()


## 原版 fireballEnvelope(seconds, birth)
func _envelope(seconds: float, birth: float) -> Dictionary:
	var age := seconds - birth
	return {
		"age": age,
		"visible": age >= 0.0 and seconds < 3.0,
		"growth": 0.0 if age < 0.0 else 0.13 + 0.87 * (1.0 - exp(-age * 9.0)),
		"heat": clampf(1.22 - age * 0.59, 0.06, 1.2),
		# 原版 clamp((3-seconds)/.35) 的默认上下界是 0/1，GDScript 必须写全
		"opacity": clampf((3.0 - seconds) / 0.35, 0.0, 1.0),
	}


## 原版 GLSL 的 fire(h)：四段 smoothstep 渐变（暗 → 红 → 橙 → 黄白）
func _fire(h: float) -> Color:
	var c := Color(0.038, 0.030, 0.029).lerp(Color(0.32, 0.047, 0.008),
		_smoothstep(0.12, 0.42, h))
	c = c.lerp(Color(1.9, 0.26, 0.012), _smoothstep(0.38, 0.74, h))
	c = c.lerp(Color(3.1, 1.12, 0.075), _smoothstep(0.72, 1.03, h))
	c = c.lerp(Color(3.6, 2.05, 0.58), _smoothstep(1.08, 1.34, h))
	return c


func _smoothstep(a: float, b: float, x: float) -> float:
	var t := clampf((x - a) / maxf(1e-6, b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func reset() -> void:
	_seconds = 99.0
	for i in _spheres.size():
		_spheres[i].visible = false


func stats() -> Dictionary:
	var n := 0
	for mi in _spheres:
		if mi.visible:
			n += 1
	return {"fireballs": n, "seconds": _seconds}


func is_ready() -> bool:
	return _spheres.size() == FIREBALLS.size()
