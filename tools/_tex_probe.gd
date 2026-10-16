extends SceneTree
## 探针：dump 一个区块 GLB 的表面格式与材质贴图引用。
## 用于区块内嵌贴图去重方案的前置调查（chunk_streamer CACHE_MODE_IGNORE
## 下每块各自持有 office/office-emissive/residential/residential-emissive）。
## 跑法：console exe --headless --path proj -s tools/_tex_probe.gd

func _init() -> void:
	var man: Dictionary = DataLoader.json_dict("res://data/city/blocks-manifest.json")
	if man.is_empty() or man.get("blocks", []).is_empty():
		print("PROBE_FAIL: manifest 不可用")
		quit()
		return
	var blocks: Array = man["blocks"]
	var file: String = str(blocks[0]["file"])
	print("probe file: ", file, "  (manifest blocks=", blocks.size(), ")")
	var scene: PackedScene = load(file)
	if scene == null:
		print("PROBE_FAIL: 场景加载失败")
		quit()
		return
	var inst := scene.instantiate()
	var tex_ids: Dictionary = {}     # instance_id → 描述（同块内共享检查）
	var mat_ids: Dictionary = {}
	var uv_surfaces := 0
	var total_surfaces := 0
	for mi in GlbLoader.meshes_of(inst):
		var mesh: Mesh = mi.mesh
		if mesh == null:
			continue
		for s in mesh.get_surface_count():
			total_surfaces += 1
			var fmt: int = mesh.surface_get_format(s)
			var has_uv: bool = (fmt & Mesh.ARRAY_FORMAT_TEX_UV) != 0
			if has_uv:
				uv_surfaces += 1
			var mat := mesh.surface_get_material(s)
			var mat_desc := "null"
			if mat != null:
				mat_ids[mat.get_instance_id()] = str(mat.resource_name)
				mat_desc = "%s#%d '%s'" % [mat.get_class(), mat.get_instance_id() % 100000, mat.resource_name]
			var line := "%s s%d uv=%s mat=%s" % [mi.name, s, has_uv, mat_desc]
			if mat is StandardMaterial3D:
				var m := mat as StandardMaterial3D
				line += " albedo=%s emission_on=%s" % [_tex(m.albedo_texture, tex_ids), m.emission_enabled]
				if m.emission_enabled:
					line += " emission_tex=%s" % _tex(m.emission_texture, tex_ids)
			print(line)
	print("---- surfaces=%d with_uv=%d unique_mats=%d unique_tex=%d"
		% [total_surfaces, uv_surfaces, mat_ids.size(), tex_ids.size()])
	for id in tex_ids:
		print("TEX ", tex_ids[id])
	inst.free()
	quit()


func _tex(t: Texture2D, ids: Dictionary) -> String:
	if t == null:
		return "null"
	var id := t.get_instance_id()
	if not ids.has(id):
		ids[id] = "%s#%d name='%s' path='%s' size=%s" % [t.get_class(),
			id % 100000, t.resource_name, t.resource_path, t.get_size()]
	return "%s#%d" % [t.get_class(), id % 100000]
