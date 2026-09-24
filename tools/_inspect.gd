extends SceneTree
##
## 无头材质体检：把指定 GLB 的每个 surface 材质名 / 反照率 / 粗糙度 / 贴图打印出来。
## 用法：
##   Godot_v4.7.1-stable_win64_console.exe --headless --path . \
##       --script res://tools/_inspect.gd -- roads terrain
##

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		args = ["roads", "terrain"]
	for name in args:
		_dump(str(name))
	quit(0)


func _dump(name: String) -> void:
	var path := "res://data/city/" + name + ".glb"
	if not ResourceLoader.exists(path):
		print("[inspect] 缺少 %s" % path)
		return
	var packed := load(path) as PackedScene
	if packed == null:
		print("[inspect] %s 加载失败" % path)
		return
	var inst := packed.instantiate()
	print("\n===== %s =====" % path)
	var mats := {}
	_walk(inst, mats)
	print("  材质数 %d，mesh 节点 %d" % [mats.size(), _mesh_count])
	for key in mats.keys():
		print("  %s" % key)


var _mesh_count := 0


func _walk(node: Node, mats: Dictionary) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var mesh: Mesh = mi.mesh
		if mesh != null:
			_mesh_count += 1
			for s in mesh.get_surface_count():
				var mat: Material = mi.get_active_material(s)
				if mat == null:
					mat = mesh.surface_get_material(s)
				mats[_describe(mat, mesh.surface_get_name(s))] = true
	for c in node.get_children():
		_walk(c, mats)


func _describe(mat: Material, surf: String) -> String:
	if mat == null:
		return "surface=%s  <无材质>" % surf
	var line := "surface=%s  name='%s'  %s" % [surf, mat.resource_name, mat.get_class()]
	if mat is BaseMaterial3D:
		var b := mat as BaseMaterial3D
		line += "  albedo=%s  rough=%.3f  metal=%.3f" % [
			str(b.albedo_color), b.roughness, b.metallic]
		line += "  albedoTex=%s  roughTex=%s" % [
			"有" if b.albedo_texture != null else "无",
			"有" if b.roughness_texture != null else "无"]
		if b.roughness_texture != null:
			line += "  roughChan=%d" % b.roughness_texture_channel
	return line
