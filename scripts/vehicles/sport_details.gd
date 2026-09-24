extends RefCounted
class_name SportDetails
##
## 主角车辆运动套件 —— 对应原版 src/city-sport-details.ts 的
## `createCitySportDetails`。
##
## ⚠️ 这一段是"车看起来不一样"的**主因**：`car.glb` 里**没有**尾翼、扩散器、
## 四出排气这些零件（实测零件表只有 paint / trim / glass / leather / 灯 /
## 轮毂 / 卡钳，见 tools/_car_probe.gd 的输出）。原版是在运行时**程序化生成**
## 它们的，移植版从未做过这一步，所以车尾是光秃秃的。
##
## 原版做法（这里逐项照搬）：
##   1. 从 `car_paint` + `car_trim` 的三角面里取"车身外表面"，
##      提供两个投射函数：
##        topAt(x, z)      → 在 (x,z) 处车身顶面的 y
##        rearAt(x, y)     → 在 (x,y) 处车尾外表面的 z
##      （原版 `surface()` 用重心坐标判定三角形是否覆盖查询点，再插值第三个轴）
##   2. 用这些投射结果把套件"贴"到车身上：尾翼支柱落在后舱盖、
##      扩散器为贴合车尾的网格面、排气环落在后杠表面。
##   3. 材质只有三个：缎面碳纤维 / 拉丝钛 / 灯与排气的暗腔。
##
## 几何常量全部取自原版 `inspectCitySportMounts` 的返回值：
##   wing      {width 1.70, depth .28, height 1.105, centreZ rearSign×2.22}
##   支柱两点  x = ±.58, z = rearSign×2.23（并要求该处顶面 y ∈ [.80,1.2]）
##   排气四点  x = ±.715 / ±.575, y = .27（并要求 |z| ∈ [2.3,2.49]）
##   排气环    外径 .059 / 内径 .044，环口 z = rearSign×2.487
##   扩散器    16 行 × 48 列，y 从 .245 起、跨 .365
##
## 性能上的唯一改动：原版线性扫全部三角形（这里 car_paint 4.3 万 + car_trim
## 1.9 万 = 6.2 万面，而扩散器要查 17×49 个点），GDScript 下会卡住启动十几秒，
## 所以加了一层网格桶索引。**查询语义与结果不变**。

# --- 原版几何常量 -----------------------------------------------------------
const WING_WIDTH := 1.70
const WING_DEPTH := 0.28
const WING_HEIGHT := 1.105
const WING_CENTRE_Z := 2.22
## 翼型剖面（原版 profile 数组，[depth, height]）
const WING_PROFILE := [
	Vector2(-0.175, -0.008), Vector2(-0.135, 0.019), Vector2(0.12, 0.019),
	Vector2(0.175, -0.006), Vector2(0.13, -0.029), Vector2(-0.135, -0.026),
]
const WING_PROFILE_REF := 0.35          ## 原版 depth*wing.depth/.35 里的 .35
const DECK_X := 0.58
const DECK_Z := 2.23
const EXHAUST_X := [-0.715, -0.575, 0.575, 0.715]
const EXHAUST_Y := 0.27
const EXHAUST_OUTER_R := 0.059
const EXHAUST_INNER_R := 0.044
const EXHAUST_TIP_Z := 2.487
const VALANCE_ROWS := 16
const VALANCE_COLS := 48

# --- 原版三个材质 -----------------------------------------------------------
const CARBON_ALBEDO := Color(0.027, 0.034, 0.045)
const CARBON_METALLIC := 0.38
const CARBON_ROUGHNESS := 0.32
const TITANIUM_ALBEDO := Color(0.52, 0.58, 0.65)
const TITANIUM_METALLIC := 0.94
const TITANIUM_ROUGHNESS := 0.23
const CAVITY_ALBEDO := Color(0.008, 0.012, 0.018)
const CAVITY_METALLIC := 0.12
const CAVITY_ROUGHNESS := 0.42

## 桶索引的分辨率（只影响查询速度，不影响结果）
const BUCKETS := 24

var rear_sign := 1.0
var front_sign := -1.0
var skipped_reason := ""
var mesh_count := 0

## 三角形平铺存储：每 9 个 float 一个三角形（3 顶点 × xyz）
var _tri := PackedFloat32Array()
## 每个三角形的包围盒：每 6 个 float（minx,maxx,miny,maxy,minz,maxz）
var _box := PackedFloat32Array()
var _count := 0
## (x,z) 桶 → 三角形下标列表；用于 top_at
##
## ⚠️ 桶的值必须是**普通 Array**（引用类型）。写成 `PackedInt32Array` 会踩到
## Godot 的值类型语义：`(dict[k] as PackedInt32Array).append(t)` 改的是副本，
## 桶永远是空的 —— 表现为所有投射查询返回 -INF、整套套件被静默跳过。
var _bucket_xz: Dictionary = {}
## (x,y) 桶 → 三角形下标列表；用于 rear_at / front_at
var _bucket_xy: Dictionary = {}
var _x0 := 0.0
var _x1 := 0.0
var _z0 := 0.0
var _z1 := 0.0
var _y0 := 0.0
var _y1 := 0.0
var _cxz := Vector2.ONE
var _cxy := Vector2.ONE

var _mat_carbon: StandardMaterial3D
var _mat_titanium: StandardMaterial3D
var _mat_cavity: StandardMaterial3D


## 对一辆车生成并挂载运动套件。返回生成的节点数（0 表示被跳过了）。
func apply(car_root: Node3D) -> int:
	mesh_count = 0
	skipped_reason = ""
	if car_root == null:
		skipped_reason = "car-root-missing"
		print("[SportDetails] 跳过：%s" % skipped_reason)
		return 0
	if not _collect_source(car_root):
		skipped_reason = "paint-or-trim-missing"
		print("[SportDetails] 跳过：%s" % skipped_reason)
		return 0

	# 原版：rearSign 取尾灯 meanZ 的符号，frontSign 取前灯 meanZ 的符号，
	# 并要求两者反号且 |meanZ| > 1.8，否则整套跳过。
	var tail_z := _mean_z(car_root, "car_redled")
	var head_z := _mean_z(car_root, "car_led")
	if absf(tail_z) < 1.8 or absf(head_z) < 1.8 or signf(tail_z) == signf(head_z):
		skipped_reason = "front-rear-coordinates-failed (tail z=%.3f head z=%.3f)" % [tail_z, head_z]
		print("[SportDetails] 跳过：%s" % skipped_reason)
		return 0
	rear_sign = signf(tail_z)
	front_sign = signf(head_z)

	# 原版的两处装配面自检：不通过就整套不装，宁可没有也不要悬空的尾翼
	var deck_y := top_at(DECK_X, rear_sign * DECK_Z)
	if not is_finite(deck_y) or deck_y < 0.80 or deck_y > 1.2:
		skipped_reason = "rear-deck-surface-missing (deck_y=%.3f, 车身三角面 %d)" % [deck_y, _count]
		print("[SportDetails] 跳过：%s" % skipped_reason)
		return 0
	var ex_z := rear_at(-0.715, EXHAUST_Y)
	if not is_finite(ex_z) or absf(ex_z) < 2.3 or absf(ex_z) > 2.49:
		skipped_reason = "rear-bumper-surface-missing (z=%.3f)" % ex_z
		print("[SportDetails] 跳过：%s" % skipped_reason)
		return 0

	_make_materials()
	_build_wing(car_root, deck_y)
	_build_valance(car_root)
	_build_exhaust(car_root)
	print("[SportDetails] 运动套件 %d 个节点（rearSign=%.0f，车身三角面 %d，后舱盖 y=%.3f）" % [
		mesh_count, rear_sign, _count, deck_y])
	return mesh_count


# ---------------------------------------------------------------------------
# 材质
# ---------------------------------------------------------------------------

func _make_materials() -> void:
	_mat_carbon = _pbr("city-sport:satin-carbon", CARBON_ALBEDO,
		CARBON_METALLIC, CARBON_ROUGHNESS)
	# 原版给碳纤维也开了 clearCoat（.35 / .18）
	_mat_carbon.clearcoat_enabled = true
	_mat_carbon.clearcoat = 0.35
	_mat_carbon.clearcoat_roughness = 0.18
	_mat_titanium = _pbr("city-sport:brushed-titanium", TITANIUM_ALBEDO,
		TITANIUM_METALLIC, TITANIUM_ROUGHNESS)
	_mat_cavity = _pbr("city-sport:lamp-and-exhaust-cavity", CAVITY_ALBEDO,
		CAVITY_METALLIC, CAVITY_ROUGHNESS)


func _pbr(n: String, col: Color, metallic: float, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.resource_name = n
	m.albedo_color = col
	m.metallic = metallic
	m.roughness = rough
	return m


func _add(car_root: Node3D, n: String, mesh: Mesh, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = n
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	car_root.add_child(mi)
	mesh_count += 1
	return mi


# ---------------------------------------------------------------------------
# 车身外表面投射（原版 inspectCitySportMounts 的 surface()）
# ---------------------------------------------------------------------------

func _collect_source(car_root: Node3D) -> bool:
	var verts: Array[PackedVector3Array] = []
	var idxs: Array[PackedInt32Array] = []
	# ⚠️ 从 car_root 的**子节点**开始递归，且初始变换取单位阵 ——
	# 这样累积出来的三角形坐标是"相对车根"的局部坐标，与后面
	# top_at / rear_at 的调用坐标系一致。若把 car_root 自己也算进去，
	# 会把车根的朝向/位置烘进三角形，投射结果全错。
	for child in car_root.get_children():
		for want in ["paint", "trim"]:
			_gather(child, want, verts, idxs, Transform3D.IDENTITY)
	if verts.is_empty():
		return false
	# 展平成三角形数组，并算包围盒
	var tri := PackedFloat32Array()
	var box := PackedFloat32Array()
	for m in verts.size():
		var v := verts[m]
		var ix := idxs[m]
		var n := ix.size() / 3
		for t in n:
			var a := v[ix[t * 3]]
			var b := v[ix[t * 3 + 1]]
			var c := v[ix[t * 3 + 2]]
			tri.append(a.x); tri.append(a.y); tri.append(a.z)
			tri.append(b.x); tri.append(b.y); tri.append(b.z)
			tri.append(c.x); tri.append(c.y); tri.append(c.z)
			box.append(minf(a.x, minf(b.x, c.x))); box.append(maxf(a.x, maxf(b.x, c.x)))
			box.append(minf(a.y, minf(b.y, c.y))); box.append(maxf(a.y, maxf(b.y, c.y)))
			box.append(minf(a.z, minf(b.z, c.z))); box.append(maxf(a.z, maxf(b.z, c.z)))
	_tri = tri
	_box = box
	_count = tri.size() / 9
	if _count == 0:
		return false
	# 建桶索引
	var x0 := INF
	var x1 := -INF
	var y0 := INF
	var y1 := -INF
	var z0 := INF
	var z1 := -INF
	for t in _count:
		x0 = minf(x0, _box[t * 6]); x1 = maxf(x1, _box[t * 6 + 1])
		y0 = minf(y0, _box[t * 6 + 2]); y1 = maxf(y1, _box[t * 6 + 3])
		z0 = minf(z0, _box[t * 6 + 4]); z1 = maxf(z1, _box[t * 6 + 5])
	_x0 = x0; _x1 = x1; _y0 = y0; _y1 = y1; _z0 = z0; _z1 = z1
	_cxz = Vector2(float(BUCKETS) / maxf(x1 - x0, 1e-4), float(BUCKETS) / maxf(z1 - z0, 1e-4))
	_cxy = Vector2(float(BUCKETS) / maxf(x1 - x0, 1e-4), float(BUCKETS) / maxf(y1 - y0, 1e-4))
	for t in _count:
		_fill_bucket(_bucket_xz, _cxz, t, Vector2(_x0, _z0),
			_box[t * 6], _box[t * 6 + 1], _box[t * 6 + 4], _box[t * 6 + 5])
		_fill_bucket(_bucket_xy, _cxy, t, Vector2(_x0, _y0),
			_box[t * 6], _box[t * 6 + 1], _box[t * 6 + 2], _box[t * 6 + 3])
	return true


func _gather(n: Node, want: String, verts: Array, idxs: Array,
		xf := Transform3D.IDENTITY) -> void:
	var cur := xf
	if n is Node3D:
		cur = xf * (n as Node3D).transform
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var base := mi.name
		var dot := base.find(".")
		if dot > 0:
			base = base.substr(0, dot)
		if base.begins_with("car_") and base.ends_with(want) and mi.mesh != null:
			for s in mi.mesh.get_surface_count():
				var arrays := mi.mesh.surface_get_arrays(s)
				var pv: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var pi = arrays[Mesh.ARRAY_INDEX]
				var out_v := PackedVector3Array()
				out_v.resize(pv.size())
				for i in pv.size():
					out_v[i] = cur * pv[i]
				var out_i := PackedInt32Array()
				if pi == null:
					out_i.resize(pv.size())
					for i in pv.size():
						out_i[i] = i
				else:
					out_i.resize(pi.size())
					for i in pi.size():
						out_i[i] = int(pi[i])
				verts.append(out_v)
				idxs.append(out_i)
	for c in n.get_children():
		_gather(c, want, verts, idxs, cur)


func _fill_bucket(buckets: Dictionary, inv_c: Vector2, t: int, origin: Vector2,
		ax0: float, ax1: float, bx0: float, bx1: float) -> void:
	var i0 := clampi(int((ax0 - origin.x) * inv_c.x), 0, BUCKETS - 1)
	var i1 := clampi(int((ax1 - origin.x) * inv_c.x), 0, BUCKETS - 1)
	var j0 := clampi(int((bx0 - origin.y) * inv_c.y), 0, BUCKETS - 1)
	var j1 := clampi(int((bx1 - origin.y) * inv_c.y), 0, BUCKETS - 1)
	for i in range(i0, i1 + 1):
		for j in range(j0, j1 + 1):
			var key := j * BUCKETS + i
			var cell: Array = buckets.get(key, [])
			if cell.is_empty() and not buckets.has(key):
				buckets[key] = cell
			cell.append(t)


## 原版 surface(x, other, vertical, faceSign) 的等价实现。
## vertical=true  → 在 (x, other=z) 处插值 **y**（车身顶面）
## vertical=false → 在 (x, other=y) 处插值 **z**，再乘 faceSign（车身前/后外表面）
func _surface(x: float, other: float, vertical: bool, face_sign: float) -> float:
	var buckets: Dictionary = _bucket_xz if vertical else _bucket_xy
	var inv_c := _cxz if vertical else _cxy
	var origin := Vector2(_x0, _z0) if vertical else Vector2(_x0, _y0)
	var i := clampi(int((x - origin.x) * inv_c.x), 0, BUCKETS - 1)
	var j := clampi(int((other - origin.y) * inv_c.y), 0, BUCKETS - 1)
	var list: Array = buckets.get(j * BUCKETS + i, [])
	var jj := 2 if vertical else 1      # 参与面积判定的第二个轴
	var kk := 1 if vertical else 2      # 被插值的轴
	var furthest := -INF
	for t in list:
		# list 是无类型 Array，t 是 Variant —— 显式标注才能过 `:=` 推断
		var b: int = int(t) * 6
		if x < _box[b] - 1e-6 or x > _box[b + 1] + 1e-6:
			continue
		var lo := _box[b + 2 * jj]
		var hi := _box[b + 2 * jj + 1]
		if other < lo - 1e-6 or other > hi + 1e-6:
			continue
		var p: int = int(t) * 9
		var p0 := Vector2(_tri[p], _tri[p + jj])
		var p1 := Vector2(_tri[p + 3], _tri[p + 3 + jj])
		var p2 := Vector2(_tri[p + 6], _tri[p + 6 + jj])
		var den := (p1.y - p2.y) * (p0.x - p2.x) + (p2.x - p1.x) * (p0.y - p2.y)
		if absf(den) < 1e-10:
			continue
		var u := ((p1.y - p2.y) * (x - p2.x) + (p2.x - p1.x) * (other - p2.y)) / den
		var v := ((p2.y - p0.y) * (x - p2.x) + (p0.x - p2.x) * (other - p2.y)) / den
		var w := 1.0 - u - v
		if minf(u, minf(v, w)) < -1e-5:
			continue
		var value := u * _tri[p + kk] + v * _tri[p + 3 + kk] + w * _tri[p + 6 + kk]
		furthest = maxf(furthest, value * (1.0 if vertical else face_sign))
	return furthest


func top_at(x: float, z: float) -> float:
	return _surface(x, z, true, rear_sign)


func rear_at(x: float, y: float) -> float:
	return rear_sign * _surface(x, y, false, rear_sign)


func _mean_z(car_root: Node3D, mesh_name: String) -> float:
	var acc := {"sum": 0.0, "n": 0}
	for child in car_root.get_children():
		_mean_z_walk(child, mesh_name, Transform3D.IDENTITY, acc)
	var n: int = acc["n"]
	return float(acc["sum"]) / float(n) if n > 0 else 0.0


func _mean_z_walk(n: Node, mesh_name: String, xf: Transform3D, acc: Dictionary) -> void:
	var cur := xf
	if n is Node3D:
		cur = xf * (n as Node3D).transform
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var base := mi.name
		var dot := base.find(".")
		if dot > 0:
			base = base.substr(0, dot)
		if base == mesh_name and mi.mesh != null:
			acc["sum"] = float(acc["sum"]) + (cur * mi.mesh.get_aabb().get_center()).z
			acc["n"] = int(acc["n"]) + 1
	for c in n.get_children():
		_mean_z_walk(c, mesh_name, cur, acc)


# ---------------------------------------------------------------------------
# 尾翼（原版：翼型多面体 + 端板 + 支柱 + 底座 + 螺栓）
# ---------------------------------------------------------------------------

func _build_wing(car_root: Node3D, deck_y: float) -> void:
	var centre_z := rear_sign * WING_CENTRE_Z
	# --- 翼型：把 6 点剖面按翼展挤出，左右两个截面 ---
	var verts: Array[Vector3] = []
	for si in 2:
		var side := float(si) * 2.0 - 1.0
		for pi in WING_PROFILE.size():
			var pr: Vector2 = WING_PROFILE[pi]
			verts.append(Vector3(side * WING_WIDTH * 0.5,
				WING_HEIGHT + pr.y,
				centre_z + rear_sign * pr.x * WING_DEPTH / WING_PROFILE_REF))
	var n_profile := WING_PROFILE.size()
	var faces: Array = []
	var f0: Array = []
	var f1: Array = []
	for i in n_profile:
		f0.append(i)
		f1.append(n_profile + i)
	faces.append(f0)
	faces.append(f1)
	for i in n_profile:
		var j := (i + 1) % n_profile
		faces.append([i, j, j + n_profile, i + n_profile])
	_add(car_root, "sport-wing-airfoil", _polyhedron(verts, faces), _mat_carbon)

	# --- 两端端板 + 钛色嵌条 ---
	for si in 2:
		var side := float(si) * 2.0 - 1.0
		var px := side * (WING_WIDTH * 0.5 - 0.011)
		var plate := _add(car_root, "sport-wing-endplate",
			_box_mesh(0.020, 0.080, 0.295), _mat_carbon)
		plate.position = Vector3(px, WING_HEIGHT + 0.016, centre_z)
		plate.rotation.x = rear_sign * 0.045
		var inlay := _add(car_root, "sport-wing-endplate-inlay",
			_box_mesh(0.022, 0.012, 0.19), _mat_titanium)
		inlay.position = Vector3(px, WING_HEIGHT + 0.035, centre_z + rear_sign * 0.015)
		inlay.rotation.x = rear_sign * 0.045

	# --- 两个支柱：底座贴合后舱盖，柱身连到翼面 ---
	var support_z := rear_sign * DECK_Z
	for si in 2:
		var side := float(si) * 2.0 - 1.0
		var sx := side * DECK_X
		# 底座四角取 (x±.055, z±.075) 处的车顶面 + 两个厚度偏移
		var pad_verts: Array[Vector3] = []
		for oi in 2:
			var offset := -0.005 if oi == 0 else 0.013
			for di in 4:
				var dx := 0.055 if (di == 1 or di == 2) else -0.055
				var dzc := 0.075 if (di == 2 or di == 3) else -0.075
				var px2 := sx + dx
				var pz2 := support_z + dzc
				pad_verts.append(Vector3(px2, top_at(px2, pz2) + offset, pz2))
		_add(car_root, "sport-wing-deck-foot",
			_polyhedron(pad_verts, [[0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4],
				[1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]]), _mat_carbon)

		var bottom := Vector3(sx, deck_y + 0.006, support_z)
		var top := Vector3(sx, WING_HEIGHT - 0.025, centre_z + rear_sign * 0.045)
		var span := top - bottom
		var upright := _add(car_root, "sport-wing-upright",
			_box_mesh(0.035, span.length(), 0.065), _mat_titanium)
		upright.position = (bottom + top) * 0.5
		upright.rotation.x = atan2(span.z, span.y)

		for bi in 2:
			var dz := -0.044 if bi == 0 else 0.044
			var bolt := SphereMesh.new()
			bolt.radius = 0.009
			bolt.height = 0.018
			bolt.radial_segments = 6
			bolt.rings = 4
			var b := _add(car_root, "sport-wing-mount-bolt", bolt, _mat_titanium)
			b.position = Vector3(sx, top_at(sx, support_z + dz) + 0.018, support_z + dz)


# ---------------------------------------------------------------------------
# 后碳纤维扩散器（贴合车尾的网格面）
# ---------------------------------------------------------------------------

func _build_valance(car_root: Node3D) -> void:
	var positions := PackedVector3Array()
	var indices := PackedInt32Array()
	var ok := true
	for row in VALANCE_ROWS + 1:
		var v := float(row) / float(VALANCE_ROWS)
		var y := 0.245 + v * 0.365
		var half := 0.74 + 0.085 * sin(PI * v)
		for column in VALANCE_COLS + 1:
			var x := (float(column) / float(VALANCE_COLS) - 0.5) * half * 2.0
			var z := rear_at(x, y) + rear_sign * 0.012
			if not is_finite(z):
				ok = false
				break
			positions.append(Vector3(x, y, z))
		if not ok:
			break
	if not ok:
		return
	for row in VALANCE_ROWS:
		for column in VALANCE_COLS:
			var a := row * (VALANCE_COLS + 1) + column
			var b := a + 1
			var c := a + VALANCE_COLS + 1
			var d := c + 1
			if rear_sign < 0.0:
				indices.append_array([a, b, c, b, d, c])
			else:
				indices.append_array([a, c, b, b, c, d])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# 网格顶点共享 → 生成平滑法线（与原版 VertexData.ComputeNormals 一致）
	mesh.surface_set_material(0, _mat_carbon)
	_add(car_root, "sport-rear-carbon-valance", mesh, _mat_carbon)


# ---------------------------------------------------------------------------
# 四出排气环 + 暗腔
# ---------------------------------------------------------------------------

func _build_exhaust(car_root: Node3D) -> void:
	var segments := 16
	var outer := EXHAUST_OUTER_R
	var inner := EXHAUST_INNER_R
	var tip := absf(EXHAUST_TIP_Z)
	for ei in EXHAUST_X.size():
		var ex := float(EXHAUST_X[ei])
		var z := rear_at(ex, EXHAUST_Y)
		if not is_finite(z):
			continue
		var back := absf(z) - 0.018
		var positions := PackedVector3Array()
		var indices := PackedInt32Array()
		# ⚠️ 这里刻意不抽 lambda：GDScript 的 Packed*Array 是**值类型**，
		# lambda 按值捕获，`positions.append()` 只会改到副本，
		# 外层拿到的仍是空数组。四段环直接内联写。
		var rings := [Vector3(outer, back, 0.0), Vector3(outer, tip, 0.0),
			Vector3(inner, tip, 0.0), Vector3(inner, tip - 0.035, 0.0)]
		for r in rings:
			var radius: float = r.x
			var depth: float = r.y
			for i in segments + 1:
				var a := float(i) / float(segments) * TAU
				positions.append(Vector3(ex + cos(a) * radius,
					EXHAUST_Y + sin(a) * radius, rear_sign * depth))
		for band in 3:
			for i in segments:
				var a := band * (segments + 1) + i
				var b := a + 1
				var c := a + segments + 1
				var d := c + 1
				if rear_sign < 0.0:
					indices.append_array([a, b, c, b, d, c])
				else:
					indices.append_array([a, c, b, b, c, d])
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = positions
		arrays[Mesh.ARRAY_INDEX] = indices
		var pipe := ArrayMesh.new()
		pipe.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		_add(car_root, "sport-quad-exhaust-ring", pipe, _mat_titanium)

		# 环内的暗盘（原版用 DoubleSide 的圆盘，不额外开光、不做布尔切割）
		var disc := CylinderMesh.new()
		disc.top_radius = inner
		disc.bottom_radius = inner
		disc.height = 0.002
		disc.radial_segments = 16
		disc.rings = 1
		var cap := _add(car_root, "sport-exhaust-dark-bore", disc, _mat_cavity)
		cap.position = Vector3(ex, EXHAUST_Y, rear_sign * (tip - 0.034))
		cap.rotation.x = PI * 0.5
		cap.rotation.x = PI * 0.5


# ---------------------------------------------------------------------------
# 网格工具
# ---------------------------------------------------------------------------

## 原版 polyhedron()：逐面翻转朝向并三角化，法线逐面计算（平面着色）
func _polyhedron(vertices: Array, faces: Array) -> ArrayMesh:
	var centre := Vector3.ZERO
	for i in vertices.size():
		centre += vertices[i] as Vector3
	centre /= float(vertices.size())
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for fi in faces.size():
		var face: Array = faces[fi]
		var pts: Array[Vector3] = []
		for i in face.size():
			pts.append(vertices[int(face[i])] as Vector3)
		var mid := Vector3.ZERO
		for p in pts:
			mid += p
		mid /= float(pts.size())
		var normal := (pts[0] - pts[1]).cross(pts[2] - pts[1])
		if normal.dot(mid - centre) < 0.0:
			pts.reverse()
		for i in range(1, pts.size() - 1):
			st.add_vertex(pts[0])
			st.add_vertex(pts[i])
			st.add_vertex(pts[i + 1])
	st.generate_normals()
	return st.commit()


func _box_mesh(w: float, h: float, d: float) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = Vector3(w, h, d)
	return b
