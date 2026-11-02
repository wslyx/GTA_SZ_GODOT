extends SceneTree
## 诊断：列出一个区块里所有材质名（确认地面材质筛选清单）

func _initialize() -> void:
	var r: PackedScene = ResourceLoader.load("res://data/city/blocks/0_0.scn", "PackedScene",
		ResourceLoader.CACHE_MODE_IGNORE)
	var inst := (r as PackedScene).instantiate()
	var names := {}
	var stack: Array = [inst]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			for s in mi.mesh.get_surface_count():
				var m := mi.mesh.surface_get_material(s)
				if m != null:
					var key := str(m.resource_name)
					names[key] = int(names.get(key, 0)) + 1
		for c in n.get_children():
			stack.append(c)
	for k in names.keys():
		print("[mat] %s × %d" % [k, names[k]])
	quit(0)
