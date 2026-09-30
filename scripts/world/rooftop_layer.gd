extends Node3D
class_name RooftopLayer
##
## 屋顶设备层 —— 逐行移植原版 src/city-rooftops.ts（CityRooftops）。
##
## 数据：`rooftops/plan.json`（离线 `prepare_city_rooftops.mjs` 生成，76864 个实例）
##   groups[].instances = [x, z, y, sx, sy, sz, yaw]，落在普通楼体的 crown 屋面上
##   14 类：停机坪 / 抬升停机坪 / 三种设备房 / 楼梯间 / 冷却塔 / 空调机 / 水箱 /
##         天线 / 光伏 / 天窗 / 通风管 / 女儿墙屏
## 模型：`rooftops/props.glb`，网格名 `prop_<kind>_<material>`。
##
## 选取规则与原版一致：
##   - 22 m 移动门槛重建（与林冠 / 种植层同一套节流）
##   - 按 **ring 顺序**遍历 200 m 格（近的先装满），到预算就停 —— 不用排序
##   - 大件（设备房 / 停机坪 / 水箱…）街面 950 / 空中 1750 m，预算 5000/9000
##   - 小件（空调机、通风管）街面 380 / 空中 650 m，预算 2500/4000
##
## 朝向换算：原版对**镜像过**的顶点（`bakeTransformIntoVertices(Scaling(1,1,-1))`）
## 施加 `Quaternion.RotationAxis(Up, yaw)`。设 Σ=diag(1,1,-1)，Godot 里顶点已经是
## Σ·v_blender（glTF 导出即 (east, up, −north)），所以等价旋转为 Σ·R_y(a)·Σ，
## 而 Σ·R_y(a)·Σ = R_y(−a)。故这里是 **Basis(UP, −yaw)**，不是 +yaw。
##
## ⚠️ 写入分帧：街道预算下约 3.5k 个实例、空中约 10.5k 个，而每个 kind 的**每个
## mesh** 都要写满整份列表 —— 满预算时一次重建是 2~3 万次 set_instance_transform。
## 原版在 JS 里是整块写 Float32Array，Godot 里逐实例调用扛不住，所以照林冠的做法
## 把写入摊到多帧（`WRITE_CHUNK` / 帧）。

const BASE := "res://data/city/rooftops/"
const PLAN_PATH := "/city/rooftops/plan.json"
const PROPS_GLB := "res://data/city/rooftops/props.glb"
const CELL := 200.0
const REBUILD_MOVE := 22.0
## 每帧最多写入的实例数（transform + color 各算一次调用）
const WRITE_CHUNK := 2500

## 原版 SMALL_KINDS
const SMALL_KINDS := ["ac-unit", "vent-pipe"]
## 原版 ROOFTOP_RADIUS / ROOFTOP_BUDGET（[街面, 空中]）
const RADIUS_LARGE := [950.0, 1750.0]
const RADIUS_SMALL := [380.0, 650.0]
const BUDGET_LARGE := [5000, 9000]
const BUDGET_SMALL := [2500, 4000]

var world: CityWorld
var enabled := true

## kind → {meshes: [{mm, local}], large: bool}
var _protos: Dictionary = {}
## Vector2i(cell) → {kind → Array of instance}
var _cells: Dictionary = {}
## 材质名 → StandardMaterial3D（去重用）
var _mats: Dictionary = {}
## 昼夜自发光材质（原版 lamp / redled）
var _lamp_mats: Array = []
var _led_mats: Array = []

var _instances_total := 0
var _last_focus := Vector2.ZERO
var _has_focus := false
var _last_aerial := false
var _last_mode := -1
var _built := false
## 分帧写入任务：phase 0=空闲，1=写入
var _job: Dictionary = {"phase": 0}
var _stats := {"large": 0, "small": 0, "drawCalls": 0, "kinds": 0}


func setup(p_world: CityWorld) -> void:
	world = p_world
	if not _load_plan():
		return
	if not _load_props():
		return
	_built = true


func _load_plan() -> bool:
	var plan: Dictionary = DataLoader.json_dict(PLAN_PATH)
	var groups: Array = plan.get("groups", [])
	if groups.is_empty():
		push_warning("[RooftopLayer] 缺少 rooftops/plan.json")
		return false
	var t0 := Time.get_ticks_msec()
	_instances_total = 0
	for g in groups:
		var kind := str(g.get("kind", ""))
		if kind == "":
			continue
		for inst in g.get("instances", []):
			var a: Array = inst
			if a.size() < 7:
				continue
			var key := Vector2i(int(floor(float(a[0]) / CELL)), int(floor(float(a[1]) / CELL)))
			if not _cells.has(key):
				_cells[key] = {}
			var by_kind: Dictionary = _cells[key]
			if not by_kind.has(kind):
				by_kind[kind] = []
			(by_kind[kind] as Array).append(a)
			_instances_total += 1
	print("[RooftopLayer] 屋顶实例 %d 个 / %d 类 / %d 个 200m 格，索引 %d ms"
		% [_instances_total, groups.size(), _cells.size(), Time.get_ticks_msec() - t0])
	return true


func _load_props() -> bool:
	if not ResourceLoader.exists(PROPS_GLB):
		push_warning("[RooftopLayer] 缺少 props.glb")
		return false
	var scene := load(PROPS_GLB) as PackedScene
	if scene == null:
		return false
	var inst_root := scene.instantiate()
	var re := RegEx.new()
	re.compile("^prop_([a-z0-9-]+)_([a-z]+)$")
	for mi in GlbLoader.meshes_of(inst_root):
		var m := re.search(mi.name)
		if m == null:
			continue
		var kind := m.get_string(1)
		_enable_instance_tint(mi.mesh)
		_apply_material_look(mi.mesh)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = mi.mesh
		var node := MultiMeshInstance3D.new()
		node.multimesh = mm
		node.name = "roof-%s-%d" % [kind, _protos.size()]
		# 原版 casters：只有大件投影（停机坪/设备房在屋面上有可读阴影，通风管没有）
		node.cast_shadow = (GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if SMALL_KINDS.has(kind) else GeometryInstance3D.SHADOW_CASTING_SETTING_ON)
		add_child(node)
		if not _protos.has(kind):
			_protos[kind] = {"meshes": [], "large": not SMALL_KINDS.has(kind)}
		var proto: Dictionary = _protos[kind]
		(proto["meshes"] as Array).append({"mm": mm, "local": _relative_transform(inst_root, mi)})
	inst_root.queue_free()
	print("[RooftopLayer] 屋顶原型 %d 类 / 网格 %d 个 / 材质 %d 个（染色开启）"
		% [_protos.size(), _mesh_count(), _mats.size()])
	return not _protos.is_empty()


func _mesh_count() -> int:
	var n := 0
	for k in _protos:
		n += (_protos[k]["meshes"] as Array).size()
	return n


## 原版 init() 里对材质做的四项统一处理 + 昼夜自发光挂点。
##
## 去重靠材质名（Godot 会给同名材质加 `.001` 后缀，原版用 `/\.\d+$/` 剥掉）。
func _apply_material_look(mesh: Mesh) -> void:
	if mesh == null:
		return
	var strip := RegEx.new()
	strip.compile("\\.\\d+$")
	for s in mesh.get_surface_count():
		var mat: Material = mesh.surface_get_material(s)
		if not (mat is StandardMaterial3D):
			continue
		var sm := mat as StandardMaterial3D
		var mat_name := strip.sub(str(sm.resource_name), "", false)
		if _mats.has(mat_name):
			continue
		_mats[mat_name] = sm
		match mat_name:
			"darkglass", "landmarkglass":
				# 玻璃设备房 / 天窗：压暗底色 + 低粗糙度，好让天空在它上面读得出来
				sm.albedo_color = sm.albedo_color * 0.9
				sm.roughness = 0.18
				sm.metallic = 0.0
			"lamp":
				# 周边灯罩：白天读作小灰壳，暖光只在黄昏/夜里点亮
				sm.albedo_color = Color(0.55, 0.56, 0.54)
				sm.emission_enabled = true
				_lamp_mats.append(sm)
			"redled":
				sm.emission_enabled = true
				_led_mats.append(sm)
			"tankwhite":
				# 不锈钢水箱：偏漫射的白 + 柔和光泽，不是蓝镜子
				sm.metallic = 0.0
				sm.roughness = 0.46
				sm.albedo_color = Color(0.74, 0.74, 0.71)


## 原版：props.glb 无 COLOR_0，Godot 默认不把顶点色乘进 albedo —— 必须显式打开。
## 属性名是 vertex_color_use_**as_**albedo（写成 Godot 3.x 的旧名会静默失效，
## 本项目已经在种植层踩过一次）。
func _enable_instance_tint(mesh: Mesh) -> void:
	if mesh == null:
		return
	for s in mesh.get_surface_count():
		var mat: Material = mesh.surface_get_material(s)
		if mat is StandardMaterial3D:
			(mat as StandardMaterial3D).vertex_color_use_as_albedo = true


static func _relative_transform(root: Node, n: Node3D) -> Transform3D:
	var xf := n.transform
	var p: Node = n.get_parent()
	while p != null and p != root:
		if p is Node3D:
			xf = (p as Node3D).transform * xf
		p = p.get_parent()
	return xf


## 原版 setMode：白天 0 / 黄昏 .6 / 夜里 1；灯 ×1.2、LED ×1.6
func set_mode(mode: int) -> void:
	var on := 0.0
	if mode == GameContent.LightMode.NIGHT:
		on = 1.0
	elif mode == GameContent.LightMode.SUNSET:
		on = 0.6
	for m in _lamp_mats:
		var sm: StandardMaterial3D = m as StandardMaterial3D
		sm.emission_enabled = on > 0.0
		sm.emission_energy_multiplier = on * 1.2
	for m2 in _led_mats:
		var sm2: StandardMaterial3D = m2 as StandardMaterial3D
		sm2.emission_enabled = on > 0.0
		sm2.emission_energy_multiplier = on * 1.6


# ---------------------------------------------------------------------------
# 选取
# ---------------------------------------------------------------------------

## 原版 ringOffsets：按切比雪夫半径一层层向外，保证"最近优先"且不用排序
static func _ring_offsets(extent: int) -> Array:
	var out: Array = []
	for r in range(0, extent + 1):
		for a in range(-r, r + 1):
			for b in range(-r, r + 1):
				if maxi(absi(a), absi(b)) == r:
					out.append(Vector2i(a, b))
	return out


## 原版 rooftopTint：设备房与水箱的暖度/亮度有变化，玻璃与金属几乎不变
static func _tint(kind: String, x: float, z: float) -> Color:
	var h := absf(sin(x * 0.317 + z * 0.871))
	var h2 := absf(cos(x * 0.541 - z * 0.223))
	if kind == "penthouse-glass" or kind == "skylight" or kind == "solar-array":
		return Color(0.96 + h * 0.08, 0.96 + h2 * 0.08, 0.98 + h * 0.04)
	if kind == "water-tank":
		return Color(0.90 + h * 0.22, 0.89 + h2 * 0.20, 0.86 + h * 0.18)
	if kind == "penthouse-render" or kind == "stair-bulkhead" or kind == "ac-unit":
		return Color(0.72 + h * 0.42, 0.72 + h2 * 0.40, 0.70 + h * 0.36)
	return Color(0.85 + h * 0.25, 0.86 + h2 * 0.22, 0.86 + h * 0.20)


func update_system(_delta: float, focus: Vector3) -> void:
	if not enabled or not _built:
		return
	# 昼夜自发光：光照档由 GameState 持有（LightingDirector.apply_mode 写入），
	# 这里只做一次变更检测，不反向依赖光照系统
	if GameState.light_mode != _last_mode:
		_last_mode = GameState.light_mode
		set_mode(_last_mode)
	# 写入没结束就先推进它（与林冠同一套：宁可晚一帧重建，也不顶爆单帧）
	if int(_job["phase"]) != 0:
		_write_step()
		return
	var aerial := world != null and world.aerial
	var f2 := Vector2(focus.x, -focus.z)
	var moved := INF
	if _has_focus:
		moved = f2.distance_to(_last_focus)
	if moved < REBUILD_MOVE and aerial == _last_aerial:
		return
	_has_focus = true
	_last_focus = f2
	_last_aerial = aerial
	_select(focus, aerial)


## 原版 update() 的选取部分：大件一趟、小件一趟，各自独立半径与预算
func _select(focus: Vector3, aerial: bool) -> void:
	var x := focus.x
	var z := -focus.z
	var cx := int(floor(x / CELL))
	var cz := int(floor(z / CELL))
	var picked := {}
	var n_large := 0
	var n_small := 0

	for pass_idx in 2:
		var want_large := pass_idx == 0
		var slot := 1 if aerial else 0
		var radius: float
		var budget: int
		if want_large:
			radius = RADIUS_LARGE[slot]
			budget = BUDGET_LARGE[slot]
		else:
			radius = RADIUS_SMALL[slot]
			budget = BUDGET_SMALL[slot]
		var r2 := radius * radius
		var extent := int(ceil(radius / CELL))
		var count := 0
		var stop := false
		for off in _ring_offsets(extent):
			if stop:
				break
			var key := Vector2i(cx + int(off.x), cz + int(off.y))
			if not _cells.has(key):
				continue
			var by_kind: Dictionary = _cells[key]
			for kind in by_kind:
				var proto: Dictionary = _protos.get(kind, {})
				if proto.is_empty() or bool(proto["large"]) != want_large:
					continue
				if not picked.has(kind):
					picked[kind] = []
				var group: Array = picked[kind]
				for inst in by_kind[kind]:
					var a: Array = inst
					var dx := float(a[0]) - x
					var dz := float(a[1]) - z
					if dx * dx + dz * dz > r2:
						continue
					group.append(a)
					count += 1
					if want_large:
						n_large += 1
					else:
						n_small += 1
					if count >= budget:
						stop = true
						break
				if stop:
					break

	# 摊平成写入单元：每个 kind 的每个 mesh 都要写满整份列表
	var units: Array = []
	for kind2 in _protos:
		var list: Array = picked.get(kind2, [])
		for entry in (_protos[kind2]["meshes"] as Array):
			units.append({"mm": entry["mm"], "local": entry["local"],
				"list": list, "kind": kind2})
	_job = {"phase": 1, "units": units, "ui": 0, "ii": 0}
	_stats["large"] = n_large
	_stats["small"] = n_small
	_write_step()


func _write_step() -> void:
	var written := 0
	var units: Array = _job["units"]
	var ui := int(_job["ui"])
	while ui < units.size() and written < WRITE_CHUNK:
		var u: Dictionary = units[ui]
		var mm: MultiMesh = u["mm"]
		var local: Transform3D = u["local"]
		var list: Array = u["list"]
		var kind: String = u["kind"]
		var ii := int(_job["ii"])
		if ii == 0:
			mm.instance_count = list.size()
		while ii < list.size() and written < WRITE_CHUNK:
			var a: Array = list[ii]
			# [x, z, y, sx, sy, sz, yaw]
			var inst_basis := Basis(Vector3.UP, -float(a[6])).scaled(
				Vector3(float(a[3]), float(a[4]), float(a[5])))
			var pos := CoordinateUtil.to_world(float(a[0]), float(a[1]), float(a[2]))
			mm.set_instance_transform(ii, Transform3D(inst_basis, pos) * local)
			mm.set_instance_color(ii, _tint(kind, float(a[0]), float(a[1])))
			ii += 1
			written += 1
		mm.visible_instance_count = ii
		if ii >= list.size():
			ui += 1
			ii = 0
		_job["ii"] = ii
		_job["ui"] = ui
	if ui >= units.size():
		_job = {"phase": 0}
		_stats["drawCalls"] = units.size()


func diagnostics() -> Dictionary:
	return {
		"prototypes": _protos.size(),
		"meshes": _mesh_count(),
		"instances": _instances_total,
		"cells": _cells.size(),
		"lampMaterials": _lamp_mats.size(),
		"ledMaterials": _led_mats.size(),
		"writing": int(_job["phase"]) != 0,
		"stats": _stats,
	}
