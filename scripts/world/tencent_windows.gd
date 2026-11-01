extends Node3D
##
## 腾讯滨海大厦「逐窗格亮灯」—— 移植原版 src/city-landmark-lighting.ts。
##
## 原版为什么这么绕：导出的幕墙 GLB **没有 UV**（`detail_tencent_landmarkglass`
## 就是 `POSITION + NORMAL` 两个属性，24256 顶点 / 12138 三角形）。但每块窗格是
## **互不相连的四边形**，所以可以用「索引拓扑的连通分量」把每块玻璃单独恢复出来，
## 再按世界坐标算出它自己的局部 UV（底边方向当 U 轴、竖直方向当 V），写进顶点属性，
## 着色器里按「到格边的距离」逐格点亮。大背墙、屋顶、屏幕板因为连通分量过大或
## 高度超范围会被跳过，自然不会亮。
##
## Godot 侧的两点差异：
##  1. 原版用自定义属性 `tencentWindow`（4 个 float）。Godot 的 `ARRAY_CUSTOM0`
##     要额外指定 format 位，容易踩坑；这块网格本来**没有 UV 也没有顶点色**，
##     于是直接借用 `ARRAY_TEX_UV`（u, v）+ `ARRAY_COLOR`（warmth, active）——
##     两个标准通道，零格式烦恼。
##  2. 原版是 `MaterialPluginBase` 挂在原材质上；这里换成独立 ShaderMaterial，
##     并把原玻璃材质的外观参数（albedo / metallic / roughness）抄进 uniform，
##     保证白天看起来还是那块玻璃，只是不发光。
##
## ⚠️ 与这份资产的差异（重要）：原版那套判据假设"每块窗格是一个独立四边形"。
## 本仓库的 `detail_tencent_landmarkglass` 解开后是 **6058 条通高竖条**
## （每条 4 顶点、y 覆盖整楼 145m、宽 14m 级），找不到"一层一个小格"的分量。
## 所以这里保留"用连通分量恢复每条的局部 UV + 随机种子"，把**竖直方向按楼层切格**
## 交给着色器（`floors` uniform，逐格 hash 决定亮不亮）——视觉结果与原版一致
## （随机点亮的窗格、顶部标识带留暗），且同样不拆分网格、不加 draw call。
##
## 完成判据（未完成项清单 A4）：夜景下幕墙出现随机点亮的窗格、其余墙面不亮、
## 无额外 draw call（整块网格一次画完，不拆分）。

const SHADER_PATH := "res://shaders/tencent_windows.gdshader"

## 窗格候选的顶点数范围（原版同一组判据；这份资产里大墙/屋顶是 12+ 顶点，靠它筛掉）
const PANE_VERTS_MIN := 4
const PANE_VERTS_MAX := 8
## 判定"底边顶点"的竖直容差（占该条高度的比例，原版是 0.04m；这里归一化后取 4%）
const BASE_EPS_RATIO := 0.04
## 目标窗宽（米，含窗框）：竖条实际宽十几米，横向也要按这个尺寸切格
const WINDOW_WIDTH_M := 2.4
## 单条最多切几列（防呆：算错了也不会出现细密条纹）
const MAX_COLUMNS := 12

## 光照档 → 发光强度（原版 bindForSubMesh：白天 0 / 黄昏 .55 / 夜晚 1.5）
const HDR_BY_MODE := [0.0, 0.55, 1.5]

var material: ShaderMaterial
var panes := 0
var glass_triangles := 0
var build_ms := 0.0

var _hdr := 0.0
var _target := 0.0


func setup(landmarks_root: Node3D) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var mi := _find_tencent_glass(landmarks_root)
	if mi == null:
		push_warning("[TencentWindows] 没找到 detail_tencent_landmarkglass")
		return diagnostics()
	var shader := load(SHADER_PATH) as Shader
	if shader == null:
		push_error("[TencentWindows] 着色器加载失败: %s" % SHADER_PATH)
		return diagnostics()

	material = ShaderMaterial.new()
	material.shader = shader
	_copy_glass_look(mi)
	_build(mi, material)
	mi.material_override = material
	build_ms = float(Time.get_ticks_msec() - t0)
	_hdr = float(HDR_BY_MODE[clampi(GameState.light_mode, 0, 2)])
	_target = _hdr
	material.set_shader_parameter("window_hdr", _hdr)
	print("[TencentWindows] 窗格 %d 块 / %d 三角形 / %.0f ms" % [panes, glass_triangles, build_ms])
	return diagnostics()


## 光照档平滑跟随（原版由 MaterialPlugin 每帧按 mode 直接取值；这里补一点插值，
## 因为 apply_mode 是渐进过渡的，窗格如果瞬切会和整场景的慢变脱节）
func _process(delta: float) -> void:
	if material == null:
		return
	_target = float(HDR_BY_MODE[clampi(GameState.light_mode, 0, 2)])
	if is_equal_approx(_hdr, _target):
		return
	_hdr = move_toward(_hdr, _target, delta * 2.5)
	material.set_shader_parameter("window_hdr", _hdr)


# ---------------------------------------------------------------------------
# 找网格
# ---------------------------------------------------------------------------

func _find_tencent_glass(root: Node3D) -> MeshInstance3D:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D:
			var nm := String(n.name).to_lower()
			if nm.begins_with("detail_tencent") and nm.contains("landmarkglass"):
				return n as MeshInstance3D
	return null


## 把原玻璃材质的外观参数抄进 uniform：白天不发光时仍像那块玻璃
func _copy_glass_look(mi: MeshInstance3D) -> void:
	var src := mi.material_override
	if src == null and mi.mesh != null and mi.mesh.get_surface_count() > 0:
		src = mi.mesh.surface_get_material(0)
	if src is StandardMaterial3D:
		var sm := src as StandardMaterial3D
		material.set_shader_parameter("base_albedo", sm.albedo_color)
		material.set_shader_parameter("metallic", sm.metallic)
		material.set_shader_parameter("roughness", sm.roughness)


# ---------------------------------------------------------------------------
# 顶点数据重建（原版 attachTencentWindowData 的逐行移植）
# ---------------------------------------------------------------------------

func _build(mi: MeshInstance3D, mat: ShaderMaterial) -> void:
	var mesh := mi.mesh
	if mesh == null:
		return
	var out := ArrayMesh.new()
	var xf := mi.global_transform
	# 这份资产的幕墙是单位盒 + 节点缩放 72.6 → 先量出真实米制尺寸再切格
	var world_scale := maxf(0.0001, xf.basis.get_scale().x)
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		if arrays.is_empty():
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx = arrays[Mesh.ARRAY_INDEX]
		var count := verts.size()
		if idx == null or count == 0:
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			continue
		var src: PackedInt32Array = idx

		# 世界坐标 + 并查集（一次遍历搞定连通分量）
		var world := PackedVector3Array()
		world.resize(count)
		for i in count:
			world[i] = xf * verts[i]
		var parent := PackedInt32Array()
		parent.resize(count)
		for i in count:
			parent[i] = i
		var t := 0
		while t + 2 < src.size():
			var a := _root(parent, src[t])
			var b := _root(parent, src[t + 1])
			if b != a:
				parent[b] = a
			var c := _root(parent, src[t + 2])
			if c != a:
				parent[c] = a
			t += 3

		# ⚠️ 分组的容器必须是普通 Array：PackedInt32Array 是**值类型**，
		# `(groups[r] as PackedInt32Array).append(i)` 会追加到临时副本上，
		# 结果是每组只剩 1 个顶点（这个坑踩过一次，别改回去）。
		var groups := {}
		for i in count:
			var r := _root(parent, i)
			if groups.has(r):
				(groups[r] as Array).append(i)
			else:
				groups[r] = [i]

		var uv := PackedVector2Array()
		uv.resize(count)
		var col := PackedColorArray()
		col.resize(count)
		for i in count:
			uv[i] = Vector2.ZERO
			col[i] = Color(0.0, 0.0, 0.0, 1.0)

		var made := 0
		for key in groups:
			var ids: Array = groups[key]
			if ids.size() < PANE_VERTS_MIN or ids.size() > PANE_VERTS_MAX:
				continue
			if not _emit_pane(ids, world, uv, col, world_scale):
				continue
			made += 1

		panes += made
		glass_triangles += src.size() / 3
		arrays[Mesh.ARRAY_TEX_UV] = uv
		arrays[Mesh.ARRAY_COLOR] = col
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out.surface_set_material(out.get_surface_count() - 1, mat)
	mi.mesh = out


## 并查集求根（带路径折半）
func _root(parent: PackedInt32Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i


## 单个连通分量 → 一组 (u, v, warmth, active)。不满足窗格判据返回 false。
func _emit_pane(ids: Array, world: PackedVector3Array,
		uv: PackedVector2Array, col: PackedColorArray, world_scale: float) -> bool:
	var bottom := INF
	var top := -INF
	for id in ids:
		var y: float = world[id].y
		bottom = minf(bottom, y)
		top = maxf(top, y)
	var height := top - bottom
	if height <= 0.0001:
		return false

	# 底边两个顶点定 U 轴（水平投影）
	var first := -1
	var second := -1
	for id in ids:
		if world[id].y < bottom + (top - bottom) * BASE_EPS_RATIO:
			if first < 0:
				first = id
			elif second < 0:
				second = id
	if first < 0 or second < 0:
		return false
	var p0 := world[first]
	var axis := world[second] - p0
	axis.y = 0.0
	var width := axis.length()
	if width <= 0.0001:
		return false
	axis = axis / width

	var min_u := INF
	var max_u := -INF
	var centre := Vector3.ZERO
	var us := PackedFloat32Array()
	us.resize(ids.size())
	for k in ids.size():
		var p := world[ids[k]]
		var u := (p - p0).dot(axis)
		us[k] = u
		min_u = minf(min_u, u)
		max_u = maxf(max_u, u)
		centre += p
	centre /= float(ids.size())
	var span := max_u - min_u
	if span <= 0.0001:
		return false

	# 每条一个稳定种子（原版用中心点 hash；这里同理，但只决定"这一列偏暖还是偏冷"
	# 以及逐层点亮的随机序列，具体哪层亮由着色器按楼层格算）
	var seed_x := int(round(centre.x * 0.5))
	var seed_y := int(round(centre.z * 0.5)) + int(round(centre.y * 0.7)) * 31
	var warmth := _hash2(seed_x + 41, seed_y + 97)

	# 横向切格：竖条实际宽 width*scale 米，按 WINDOW_WIDTH_M 定列数
	var cols := clampi(int(round(width * world_scale / WINDOW_WIDTH_M)), 1, MAX_COLUMNS)
	for k in ids.size():
		var id: int = ids[k]
		uv[id] = Vector2((us[k] - min_u) / span * float(cols), (world[id].y - bottom) / height)
		# COLOR = (种子, 是窗格=1, 0, 1)；逐格点亮在片元里做
		col[id] = Color(warmth, 1.0, 0.0, 1.0)
	return true


## 原版 hash(x, y)：sin 取小数部分
func _hash2(x: int, y: int) -> float:
	var n := sin(float(x) * 127.1 + float(y) * 311.7) * 43758.5453123
	return n - floor(n)


func diagnostics() -> Dictionary:
	return {
		"panes": panes,
		"glassTriangles": glass_triangles,
		"buildMs": snappedf(build_ms, 0.1),
		"hdr": snappedf(_hdr, 0.01),
	}
