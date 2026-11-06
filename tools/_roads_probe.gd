extends SceneTree
##
## roads.glb 结构探针（NODESTAT 优化评估用，一次性）：
## 统计 MeshInstance3D 数、唯一材质数、每网格 surface 数、顶点/三角总量，
## 以及节点名的 640m 分块（roads_i_j）分布 —— 判断"合批/流式"两条路的收益。
##
## 用法：Godot_console.exe --headless --path . -s res://tools/_roads_probe.gd

func _init() -> void:
	var ps: PackedScene = load("res://data/city/roads.glb")
	if ps == null:
		printerr("[roads-probe] roads.glb 加载失败")
		quit(1)
		return
	var root := ps.instantiate()
	var mats := {}
	var mesh_mats := {}
	var total_verts := 0
	var total_tris := 0
	var total_surfaces := 0
	var cells := {}
	var nodes_by_type := {}
	var stack: Array = [root]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		nodes_by_type[nd.get_class()] = int(nodes_by_type.get(nd.get_class(), 0)) + 1
		var nm := String(nd.name)
		# 分块名 roads_i_j（可能有负数与多级后缀）
		if nm.begins_with("roads_"):
			var parts := nm.split("_")
			if parts.size() >= 3:
				cells[parts[1] + "_" + parts[2]] = int(cells.get(parts[1] + "_" + parts[2], 0)) + 1
		if nd is MeshInstance3D:
			var mi := nd as MeshInstance3D
			var mesh := mi.mesh
			if mesh != null:
				total_surfaces += mesh.get_surface_count()
				for s in mesh.get_surface_count():
					var m := mesh.surface_get_material(s)
					var key := str(m.resource_name) + "|" + m.get_class() if m != null else "<null>"
					mats[key] = int(mats.get(key, 0)) + 1
				total_verts += mesh.get_faces().size() / 3  # 近似顶点（get_faces 返回三角面）
				total_tris += mesh.get_faces().size() / 3
		for ch in nd.get_children():
			stack.append(ch)

	print("[roads-probe] 节点类型分布: %s" % [str(nodes_by_type)])
	print("[roads-probe] MeshInstance surface 总数(≈draw call 上限): %d" % total_surfaces)
	print("[roads-probe] 唯一材质 %d 种:" % mats.size())
	for k in mats.keys():
		print("[roads-probe]   %s × %d surface" % [k, mats[k]])
	print("[roads-probe] 三角面合计 ≈ %.1fM" % (total_tris / 1000000.0))
	print("[roads-probe] 640m 分块数: %d（即流式化后的常驻单元数）" % cells.size())
	var sorted_cells := cells.keys()
	sorted_cells.sort()
	for k in sorted_cells:
		print("[roads-probe]   cell %s: %d mesh" % [k, cells[k]])
	root.free()
	quit(0)
