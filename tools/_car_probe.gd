extends SceneTree
## 车辆零件体检：包围盒 + 三角面数（判断 surface 投射查询的规模）
func _initialize() -> void:
	var packed := load("res://data/city/car.glb") as PackedScene
	var inst := packed.instantiate()
	print("\n%-28s %8s %8s %8s %8s" % ["mesh", "Z 中心", "三角面", "X 中心", "Y 中心"])
	_walk(inst, Transform3D.IDENTITY)
	quit(0)

func _walk(n: Node, xf: Transform3D) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var x := xf * mi.transform
		var mesh: Mesh = mi.mesh
		if mesh != null and mesh.get_surface_count() > 0:
			var tri := 0
			for s in mesh.get_surface_count():
				var arrays := mesh.surface_get_arrays(s)
				var idx = arrays[Mesh.ARRAY_INDEX]
				tri += (idx.size() / 3) if idx != null else (arrays[Mesh.ARRAY_VERTEX].size() / 3)
			var c := x * mesh.get_aabb().get_center()
			print("%-28s %8.2f %8d %8.2f %8.2f" % [mi.name, c.z, tri, c.x, c.y])
	for ch in n.get_children():
		var cxf := xf
		if ch is Node3D:
			cxf = xf * (ch as Node3D).transform
		_walk(ch, cxf)
