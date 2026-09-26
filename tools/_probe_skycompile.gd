extends SceneTree
## 临时探针：判断无头模式下 **sky 着色器到底有没有被编译**。
##
## 方法：故意写一个必定失败的 sky 着色器（未定义标识符）。
##   若报 SHADER ERROR → 编译确实发生 → 那么同批的成功用例就是真的通过；
##   若毫无反应     → 编译没发生，之前的"通过"是假阳性。
## 用完即删。


var _frames := 0


func _initialize() -> void:
	var holder := Node3D.new()
	root.add_child(holder)
	# 对照组：一定失败
	_try(holder, "对照组（必定失败）", """
shader_type sky;
void sky() { COLOR = totally_undefined_symbol; }
""")
	# 待测：EYEDIR 的屏幕导数
	_try(holder, "EYEDIR 的 dFdx/dFdy", """
shader_type sky;
void sky() {
	float pixel = max(length(dFdx(EYEDIR)), length(dFdy(EYEDIR)));
	COLOR = vec3(pixel);
}
""")
	# 待测：ALPHA 可写、HALF_RES_COLOR 可读
	_try(holder, "ALPHA + HALF_RES_COLOR", """
shader_type sky;
void sky() { COLOR = HALF_RES_COLOR.rgb; ALPHA = 0.5; }
""")


func _process(_delta: float) -> bool:
	_frames += 1
	return _frames >= 2


func _try(parent: Node, label: String, code: String) -> void:
	var sh := Shader.new()
	sh.code = code
	var sky := Sky.new()
	var mat := ShaderMaterial.new()
	mat.shader = sh
	sky.sky_material = mat
	sky.process_mode = Sky.PROCESS_MODE_REALTIME
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	var we := WorldEnvironment.new()
	we.environment = env
	parent.add_child(we)
	print("=== 提交：", label)
