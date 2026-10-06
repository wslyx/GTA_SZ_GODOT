extends SceneTree
func _initialize() -> void:
	for p in ["res://shaders/sky_sky.gdshader", "res://shaders/sky.gdshader",
			"res://shaders/night_sky.gdshader"]:
		var sh = load(p)
		print(p, " -> ", "OK" if sh != null and (sh as Shader).get_code().length() > 0 else "FAIL")
	quit(0)
