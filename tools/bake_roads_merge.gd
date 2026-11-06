extends SceneTree
##
## roads.glb 离线合批烘焙（性能优化方案 §2.10 的道路部分）。
##
## 背景（tools/_perf.gd tree 模式实测）：roads.glb 实例化为 765 个
## MeshInstance3D，却只有 5 种材质（asphalt/pavement/roadline/steel/lamp），
## 765 个 draw call 占全场 1665 个 surface 的 46%，是全场景最大 draw call
## 来源；且流式模式下道路整根常驻、无按格剔除 —— 合并零剔除损失，纯赚。
##
## 做法：按材质资源分组，把每个 surface 的数组（应用实例变换后）拼进同一
## ArrayMesh，产出 data/city/roads_merged.scn（5 个 MeshInstance3D）。
## 节点名 roads_merged_<材质>：仍满足 ground_field 的 GROUND_MESH_RE
## "roads_" 前缀；不匹配 roads_i_j 分块正则 → 回退剔除路径里道路整组可见
## （与流式模式现状一致）。
##
## 运行时配套：city_world._plan_roads 优先加载 roads_merged.scn，
## 文件不存在自动回退 roads.glb（烘焙产物可删，不锁死）。
##
## 用法：
##   Godot_console.exe --headless --path . -s res://tools/bake_roads_merge.gd

const SRC := "res://data/city/roads.glb"
const DST := "res://data/city/roads_merged.scn"

func _init() -> void:
	var t0 := Time.get_ticks_msec()
	if not ResourceLoader.exists(SRC):
		printerr("[bake-roads] 源文件不存在：%s" % SRC)
		quit(1)
		return
	var ps: PackedScene = load(SRC)
	if ps == null:
		printerr("[bake-roads] 加载失败")
		quit(1)
		return
	var root := ps.instantiate()

	# 材质键 → 累加器。键用材质实例（765 个 mesh 共享 5 个实例）。
	var acc := {}   # Material → {verts, normals, uvs, colors, indices, count}
	var mi_count := 0
	var surf_count := 0
	var has_color_any := false
	for mi in _mesh_instances(root):
		mi_count += 1
		var xf := _relative_xf(root, mi)
		var nb := xf.basis.inverse().transposed()   # 法线矩阵（假设无剪切/负缩放）
		var mesh: Mesh = mi.mesh
		if mesh == null:
			continue
		for s in mesh.get_surface_count():
			var mat := mesh.surface_get_material(s)
			if mat == null:
				continue
			var arrays := mesh.surface_get_arrays(s)
			if arrays[Mesh.ARRAY_VERTEX] == null:
				continue
			surf_count += 1
			var fmt: int = mesh.surface_get_format(s)
			if fmt & Mesh.ARRAY_FORMAT_COLOR:
				has_color_any = true
			var a: Dictionary = acc.get_or_add(mat, {
				"verts": PackedVector3Array(), "normals": PackedVector3Array(),
				"uvs": PackedVector2Array(), "colors": PackedColorArray(),
				"indices": PackedInt32Array(), "has_uv": true, "has_color": true, "n": 0})
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var wv := PackedVector3Array()
			wv.resize(verts.size())
			for i in verts.size():
				wv[i] = xf * verts[i]
			var wn := PackedVector3Array()
			var src_n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			if src_n != null and src_n.size() == verts.size():
				wn.resize(src_n.size())
				for i in src_n.size():
					wn[i] = (nb * src_n[i]).normalized()
			var wuv := PackedVector2Array()
			var src_uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
			if src_uv != null and src_uv.size() == verts.size():
				wuv = src_uv
			else:
				a["has_uv"] = false
			var wc := PackedColorArray()
			var src_c: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
			if src_c != null and src_c.size() == verts.size():
				wc = src_c
			else:
				a["has_color"] = false
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var base: int = a["n"]
			var widx := PackedInt32Array()
			if idx != null:
				widx.resize(idx.size())
				for i in idx.size():
					widx[i] = idx[i] + base
			else:
				widx.resize(verts.size())
				for i in verts.size():
					widx[i] = base + i
			a["verts"].append_array(wv)
			if not wn.is_empty():
				a["normals"].append_array(wn)
			if not wuv.is_empty():
				a["uvs"].append_array(wuv)
			if not wc.is_empty():
				a["colors"].append_array(wc)
			a["indices"].append_array(widx)
			a["n"] = base + verts.size()

	# 组装合并场景
	var out_root := Node3D.new()
	out_root.name = "RoadsMerged"
	var report: Array = []
	for mat in acc.keys():
		var a: Dictionary = acc[mat]
		var am := ArrayMesh.new()
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = a["verts"]
		if not (a["normals"] as PackedVector3Array).is_empty():
			arrays[Mesh.ARRAY_NORMAL] = a["normals"]
		# 同一合并网格内 UV/顶点色必须一致（有则都有）——混合格式 Godot 不收
		if not (a["uvs"] as PackedVector2Array).is_empty() and a["has_uv"]:
			arrays[Mesh.ARRAY_TEX_UV] = a["uvs"]
		if not (a["colors"] as PackedColorArray).is_empty() and a["has_color"]:
			arrays[Mesh.ARRAY_COLOR] = a["colors"]
		arrays[Mesh.ARRAY_INDEX] = a["indices"]
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		am.surface_set_material(0, mat)
		var mi := MeshInstance3D.new()
		mi.name = "roads_merged_%s" % (mat.resource_name if str(mat.resource_name) != "" else str(acc.keys().find(mat)))
		mi.mesh = am
		out_root.add_child(mi)
		report.append("%s: %d 顶点 / %d 三角" % [mi.name,
			(a["verts"] as PackedVector3Array).size(),
			(a["indices"] as PackedInt32Array).size() / 3])

	var packed := PackedScene.new()
	packed.pack(out_root)
	var err := ResourceSaver.save(packed, DST)
	if err != OK:
		printerr("[bake-roads] 保存失败 code=%d → %s" % [err, DST])
		quit(1)
		return
	print("[bake-roads] 完成：%d MeshInstance / %d surface → %d 合并网格（含 COLOR:%s）用時 %d ms"
		% [mi_count, surf_count, acc.size(), str(has_color_any), Time.get_ticks_msec() - t0])
	for r in report:
		print("[bake-roads]   %s" % r)
	quit(0)


func _mesh_instances(root: Node) -> Array[MeshInstance3D]:
	return GlbLoader.meshes_of(root)


## 与 GlbLoader._relative_xf 同逻辑（SceneTree 脚本里直接复用静态方法即可，
## 这里包一层便于阅读；注意根自身 transform 不算——GLB 根在原点）
func _relative_xf(root: Node, n: Node3D) -> Transform3D:
	return GlbLoader._relative_xf(root, n)
