extends RefCounted
class_name GeomUtil
##
## 运行时网格构造工具。
##
## 用途：把 JSON / .bin 数据变成 Godot 网格 —— 地面三角带、水面平面、
## 招牌四边形、高度场网格等。所有函数都遵循 Godot 4 的绕序约定：
##   **正面为顺时针（从正面看去）**
## 地面类网格统一显式写入朝上的法线，避免绕序判断错误导致整片地面不可见。
##
## 注意：GLB 资产（建筑、道路、地形、树木…）不经过这里，由 Godot 的 glTF 导入器直接处理。

## 顶点属性常量（供 make_surface 使用）
const NORMAL_UP := Vector3.UP


## 由三角列表构造只含顶点的网格（法线显式给定）。
## tris 每 3 个元素构成一个三角形；normals 可为空（则用 UP）。
static func mesh_from_triangles(tris: PackedVector3Array, normals: PackedVector3Array = PackedVector3Array(), uvs: PackedVector2Array = PackedVector2Array()) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := tris.size()
	for i in n:
		if uvs.size() == n:
			st.set_uv(uvs[i])
		if normals.size() == n:
			st.set_normal(normals[i])
		else:
			st.set_normal(NORMAL_UP)
		st.add_vertex(tris[i])
	# 不调用 generate_tangents()：程序化网格没有 UV，会报
	# \"UVs are required to generate tangents\"；这几个网格也不需要切线
	return st.commit()


## 由三角列表 + 每三角形一个高度构造地面网格（每个顶点的 y 由回调给出）。
static func mesh_from_ground_triangles(tris_xz: PackedVector3Array, height_fn: Callable, normals: PackedVector3Array = PackedVector3Array()) -> ArrayMesh:
	var verts := PackedVector3Array()
	verts.resize(tris_xz.size())
	for i in tris_xz.size():
		var v := tris_xz[i]
		var h: float = height_fn.call(v.x, v.z) if height_fn.is_valid() else 0.0
		verts[i] = Vector3(v.x, h, v.z)
	return mesh_from_triangles(verts, normals)


## 朝上的四边形（水面 / 地面片）。四角按顺时针给出即可，内部自动修正。
static func quad_up(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> ArrayMesh:
	var tris := PackedVector3Array()
	var poly := PackedVector2Array([Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z), Vector2(d.x, d.z)])
	if CoordinateUtil.signed_area_2d(poly) > 0.0:
		tris = PackedVector3Array([a, c, b, a, d, c])
	else:
		tris = PackedVector3Array([a, b, c, a, c, d])
	return mesh_from_triangles(tris)


## 环形水面（内方外方的四片矩形），用于海平线远景。
## inner 为内圈半长，outer 为外圈半长；y 为高度。绕序自动修正。
static func ring_plane(inner: float, outer: float, y: float, segments: int = 4) -> ArrayMesh:
	var tris := PackedVector3Array()
	# 四片矩形拼接，覆盖 [-outer,outer]^2 \ [-inner,inner]^2
	var corners := [
		[Vector2(-outer, -outer), Vector2(outer, -outer), Vector2(inner, -inner), Vector2(-inner, -inner)],
		[Vector2(outer, -outer), Vector2(outer, outer), Vector2(inner, inner), Vector2(inner, -inner)],
		[Vector2(outer, outer), Vector2(-outer, outer), Vector2(-inner, inner), Vector2(inner, inner)],
		[Vector2(-outer, outer), Vector2(-outer, -outer), Vector2(-inner, -inner), Vector2(-inner, inner)],
	]
	for quad in corners:
		var poly := PackedVector2Array(quad)
		var v := PackedVector3Array([
			Vector3(quad[0].x, y, quad[0].y), Vector3(quad[1].x, y, quad[1].y),
			Vector3(quad[2].x, y, quad[2].y), Vector3(quad[3].x, y, quad[3].y),
		])
		if CoordinateUtil.signed_area_2d(poly) > 0.0:
			tris.append_array(PackedVector3Array([v[0], v[2], v[1], v[0], v[3], v[2]]))
		else:
			tris.append_array(PackedVector3Array([v[0], v[1], v[2], v[0], v[2], v[3]]))
	return mesh_from_triangles(tris)


## 由高度场网格构造地形网格。
## heights 为 row-major 的 float 数组（rows × cols），
## origin 为 (x0, z0)，step_xy 为 (dx, dz)，可选 hole 回调返回 true 则跳过该格。
static func grid_mesh(heights: PackedFloat32Array, rows: int, cols: int, origin_x: float, origin_z: float, dx: float, dz: float, skip: Callable = Callable()) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for r in rows - 1:
		for c in cols - 1:
			if skip.is_valid() and skip.call(c, r):
				continue
			var x0 := origin_x + c * dx
			var x1 := origin_x + (c + 1) * dx
			var z0 := origin_z + r * dz
			var z1 := origin_z + (r + 1) * dz
			var h00 := heights[r * cols + c]
			var h10 := heights[r * cols + c + 1]
			var h01 := heights[(r + 1) * cols + c]
			var h11 := heights[(r + 1) * cols + c + 1]
			var v00 := Vector3(x0, h00, z0)
			var v10 := Vector3(x1, h10, z0)
			var v01 := Vector3(x0, h01, z1)
			var v11 := Vector3(x1, h11, z1)
			# 与 (x,z) 平面顺时针一致：v00, v10, v11 / v00, v11, v01
			var poly := PackedVector2Array([Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1)])
			if CoordinateUtil.signed_area_2d(poly) > 0.0:
				_add_tri(st, v00, v11, v10)
				_add_tri(st, v00, v01, v11)
			else:
				_add_tri(st, v00, v10, v11)
				_add_tri(st, v00, v11, v01)
	# 不调用 generate_tangents()：程序化网格没有 UV，会报
	# \"UVs are required to generate tangents\"；这几个网格也不需要切线
	return st.commit()


static func _add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.set_normal(NORMAL_UP)
	st.add_vertex(a)
	st.set_normal(NORMAL_UP)
	st.add_vertex(b)
	st.set_normal(NORMAL_UP)
	st.add_vertex(c)


## 空间中的四边形（招牌 / 广告牌）。
## position 为数据坐标顶点，normal 为朝向，tangent 为水平延伸方向，width/height 为尺寸。
## 该四边形是**竖直**的（沿 up 与 tangent 展开），不参与地面绕序规则。
static func sign_quad(position: Vector3, normal: Vector3, tangent: Vector3, width: float, height: float, anchor: String = "center") -> ArrayMesh:
	var t := tangent.normalized()
	var u := normal.cross(t).normalized()
	if u == Vector3.ZERO:
		u = Vector3.UP
	var right := t * (width * 0.5)
	var up := u * (height * 0.5)
	var shift := Vector3.ZERO
	match anchor:
		"left":
			shift = t * (width * 0.5)
		"right":
			shift = -t * (width * 0.5)
		_:
			shift = Vector3.ZERO
	var c := position + shift
	var a := c - right - up
	var b := c + right - up
	var d := c + right + up
	var e := c - right + up
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# 面向 normal：从 normal 方向看去为顺时针
	var n := normal.normalized()
	for tri in [[a, b, d], [a, d, e]]:
		for v in tri:
			st.set_normal(n)
			st.set_uv(Vector2(0.0, 0.0))
			st.add_vertex(v)
	# 不调用 generate_tangents()：程序化网格没有 UV，会报
	# \"UVs are required to generate tangents\"；这几个网格也不需要切线
	return st.commit()


## 圆环（订单目的地标记），朝上。
static func torus_up(center: Vector3, radius: float, thickness: float, segments: int = 48) -> ArrayMesh:
	var verts := PackedVector3Array()
	for i in segments:
		var a0 := TAU * i / segments
		var a1 := TAU * (i + 1) / segments
		var outer0 := center + Vector3(cos(a0), 0, sin(a0)) * (radius + thickness * 0.5)
		var outer1 := center + Vector3(cos(a1), 0, sin(a1)) * (radius + thickness * 0.5)
		var inner0 := center + Vector3(cos(a0), 0, sin(a0)) * (radius - thickness * 0.5)
		var inner1 := center + Vector3(cos(a1), 0, sin(a1)) * (radius - thickness * 0.5)
		verts.append_array(PackedVector3Array([inner0, outer0, outer1, inner0, outer1, inner1]))
	return mesh_from_triangles(verts)


## MultiMesh 实例化辅助：把 [位置, 朝向yaw, 缩放] 列表灌进 MultiMesh。
static func fill_multimesh(mm: MultiMesh, entries: Array, source_forward: int = CoordinateUtil.ModelForward.PLUS_Z) -> void:
	mm.instance_count = entries.size()
	mm.visible_instance_count = entries.size()
	for i in entries.size():
		var e: Dictionary = entries[i]
		var xf := Transform3D.IDENTITY
		var basis := Basis(Vector3.UP, CoordinateUtil.node_yaw(float(e.get("yaw", 0.0)), source_forward))
		var sc: float = float(e.get("scale", 1.0))
		if e.has("scale3"):
			var s3: Vector3 = e["scale3"]
			basis = basis.scaled(s3)
		elif sc != 1.0:
			basis = basis.scaled(Vector3(sc, sc, sc))
		if e.has("tilt"):
			basis = basis.rotated(Vector3.RIGHT, float(e["tilt"]))
		xf = Transform3D(basis, e.get("pos", Vector3.ZERO))
		mm.set_instance_transform(i, xf)
		if e.has("color"):
			mm.set_instance_color(i, e["color"])
