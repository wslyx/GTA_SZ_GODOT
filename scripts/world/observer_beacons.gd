extends Node3D
class_name ObserverBeacons
##
## 观察模式信标 —— 移植原版 src/city-observer-beacons.ts 的 3D 部分
## （光柱 + 收藏 + 落点解算）。原版的 UI 是一整套 DOM 面板（切换按钮 / 名称输入框 /
## 收藏列表 / 长按进度圈），移植版按本项目的 UI 习惯改成：**长按左键选点 +
## 三个快捷键操作**，面板留待后续（见 README 第七节）。
##
## 三件网格，与原版一一对应：
##   glow  圆柱（16 段，无盖）opacity .20  —— 外层光晕
##   core  圆柱（12 段，无盖）opacity .82  —— 内芯
##   ring  水平圆盘         opacity .54  —— 地面光环
## 尺寸按到相机的距离缩放（原版 positionBeam）：
##   高度 = clamp(距离 × .31, 100, 560)；宽度 = clamp(距离 × .002, .65, 5.5)
##   圆环缩放 = clamp(距离 / 900, .7, 2.8)；亮度脉冲 = .94 + sin(t × 1.65) × .06

const STATE := preload("res://scripts/life/observer_beacon_state.gd")
const DESTINATION := preload("res://scripts/world/observer_destination.gd")
const SHADER_PATH := "res://shaders/beacon.gdshader"

const GLOW_OPACITY := 0.20
const CORE_OPACITY := 0.82
const RING_OPACITY := 0.54
## 原版圆盘半径 6
const RING_RADIUS := 6.0
## 拾取射线步长与最远距离（米，数据尺度）
const PICK_STEP := 4.0
const PICK_RANGE := 4000.0

var world: CityWorld
var enabled := true

var selected: Dictionary = {}
var favorites: Array = []
## 落点解算（原版 createObserverDestinationResolver）
var resolver = null

var _meshes: Array = []
var _materials: Array = []
var _time := 0.0
var _active := false
var _seq := 0
var _toast: Callable = Callable()


func setup(p_world: CityWorld, toast: Callable = Callable()) -> void:
	world = p_world
	_toast = toast
	if not ResourceLoader.exists(SHADER_PATH):
		push_warning("[ObserverBeacons] 缺少 %s" % SHADER_PATH)
		return
	var shader := load(SHADER_PATH) as Shader
	if shader == null:
		return
	# 三个材质：同一着色器，opacity / ring 不同（圆盘那件的 UV 语义是"以中心为圆心"）
	_materials = [
		_make_material(shader, GLOW_OPACITY, 0.0),
		_make_material(shader, CORE_OPACITY, 0.0),
		_make_material(shader, RING_OPACITY, 1.0),
	]
	# 圆柱：Godot 的 CylinderMesh 高度 1、半径 1；UV.y 沿高、UV.x 绕周，与原版一致
	var glow := MeshInstance3D.new()
	glow.name = "beacon-glow"
	var glow_mesh := CylinderMesh.new()
	glow_mesh.height = 1.0
	glow_mesh.top_radius = 1.0
	glow_mesh.bottom_radius = 1.0
	glow_mesh.radial_segments = 16
	glow_mesh.rings = 1
	glow_mesh.cap_top = false
	glow_mesh.cap_bottom = false
	glow.mesh = glow_mesh
	glow.material_override = _materials[0]

	var core := MeshInstance3D.new()
	core.name = "beacon-core"
	var core_mesh := CylinderMesh.new()
	core_mesh.height = 1.0
	core_mesh.top_radius = 1.0
	core_mesh.bottom_radius = 1.0
	core_mesh.radial_segments = 12
	core_mesh.rings = 1
	core_mesh.cap_top = false
	core_mesh.cap_bottom = false
	core.mesh = core_mesh
	core.material_override = _materials[1]

	var ring := MeshInstance3D.new()
	ring.name = "beacon-ring"
	# 圆盘：Godot 的 PlaneMesh 朝上且 UV 是 0..1 的方形，正好给 `length(UV-.5)` 当半径
	var ring_mesh := PlaneMesh.new()
	ring_mesh.size = Vector2(RING_RADIUS * 2.0, RING_RADIUS * 2.0)
	ring_mesh.subdivide_width = 8
	ring_mesh.subdivide_depth = 8
	ring.mesh = ring_mesh
	ring.material_override = _materials[2]

	for m in [glow, core, ring]:
		var mi: MeshInstance3D = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_meshes.append(mi)

	resolver = DESTINATION.new()
	resolver.setup(world.collision,
		func(x: float, z: float) -> float: return world.height_field.height_at(x, z))
	load_favorites()
	print("[ObserverBeacons] 光柱 %d 件 / 收藏 %d 个（上限 %d）"
		% [_meshes.size(), favorites.size(), STATE.LIMIT])
	# 常驻自检：出生点上空能不能解出「可落车的落点」。落点解算依赖 CityData /
	# CityCollision，无头探针（--script 不注册 autoload）验不到，只能在这里验。
	var sp := CityData.spawn_pos
	var probe: Dictionary = resolver.resolve({"x": sp.x, "y": 6.0, "z": sp.y}, "")
	print("[ObserverBeacons] 落点自检：%s / 有落点=%s"
		% [str(probe.get("name", "?")), str(probe.has("arrival"))])


func _make_material(shader: Shader, opacity: float, ring: float) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("opacity", opacity)
	mat.set_shader_parameter("ring", ring)
	mat.set_shader_parameter("pulse", 1.0)
	mat.render_priority = 1
	return mat


# ---------------------------------------------------------------------------
# 收藏
# ---------------------------------------------------------------------------

## 提示回调由 main_game 在 HUD 就绪后注入（构建期 HUD 还不存在）
func set_toast(cb: Callable) -> void:
	_toast = cb


func load_favorites() -> void:
	var d: Dictionary = SaveSystem.load_section(STATE.STORAGE_KEY)
	favorites = STATE.decode(JSON.stringify(d) if not d.is_empty() else "")


func save_favorites() -> bool:
	var payload = JSON.parse_string(STATE.encode(favorites))
	if payload == null:
		return false
	SaveSystem.save_section(STATE.STORAGE_KEY, payload)
	return true


## 原版收藏按钮：命中已有收藏则更新名字，否则新增（满了就提示）
func save_selected(name := "") -> bool:
	if selected.is_empty():
		return false
	var point := STATE.copy_point(selected)
	if name != "":
		point["name"] = STATE.beacon_name(name)
	var existing := STATE.matching(favorites, point)
	if not existing.is_empty():
		var rebuilt: Array = []
		for p in favorites:
			var d: Dictionary = p
			if str(d["id"]) == str(existing["id"]):
				var merged := STATE.copy_point(point)
				merged["id"] = str(d["id"])
				merged["createdAt"] = float(d.get("createdAt", 0.0))
				rebuilt.append(merged)
			else:
				rebuilt.append(d)
		favorites = rebuilt
	else:
		if favorites.size() >= STATE.LIMIT:
			_toast_msg("收藏已满（%d 个），请先移除一个" % STATE.LIMIT)
			return false
		_seq += 1
		favorites.append(STATE.make_favorite(point, _seq))
	selected = STATE.copy_point(point)
	save_favorites()
	_toast_msg("已收藏 · %s" % str(selected["name"]))
	return true


func remove_favorite(id: String) -> void:
	favorites = favorites.filter(func(p): return str(p["id"]) != id)
	save_favorites()


# ---------------------------------------------------------------------------
# 选点与移动
# ---------------------------------------------------------------------------

## 从相机射出一条射线，与地形高度场求交（原版用的是 Babylon scene.pick）。
## ⚠️ 本移植的城市碰撞是自建的 2D 系统，没有物理体，所以不能用 ray_intersect；
## 这里是沿射线步进 + 二分回退。**只能打地形，打不到屋顶**（差异清单有记）。
func pick(origin_world: Vector3, dir_world: Vector3) -> Dictionary:
	if world == null:
		return {}
	var dir := dir_world.normalized()
	var t := 0.0
	while t < PICK_RANGE:
		t += PICK_STEP
		var w := origin_world + dir * t
		var dxz := CoordinateUtil.from_world(w)
		var ground := world.height_field.height_at(dxz.x, dxz.y)
		if w.y <= ground:
			# 在 [t-step, t] 之间二分细化到 0.5m
			var lo := t - PICK_STEP
			var hi := t
			for _i in 12:
				var mid := (lo + hi) * 0.5
				var mw := origin_world + dir * mid
				var mxz := CoordinateUtil.from_world(mw)
				if mw.y <= world.height_field.height_at(mxz.x, mxz.y):
					hi = mid
				else:
					lo = mid
			var hw := origin_world + dir * hi
			var hxz := CoordinateUtil.from_world(hw)
			return {"x": hxz.x, "y": world.height_field.height_at(hxz.x, hxz.y), "z": hxz.y}
	# 没打到地形（朝天空）
	return {}


## 原版 select：校验 + 复制 + 重置名字
func select(point: Dictionary) -> bool:
	if not DESTINATION.valid_beacon_point(point):
		return false
	selected = STATE.copy_point(point)
	if str(selected.get("name", "")) == "":
		selected["name"] = STATE.beacon_name("")
	return true


func clear() -> void:
	selected = {}
	_update_visibility()


## 原版 travel：交给落点解算，返回带 arrival / yaw 的目的地（找不到就只返回风景点）
func resolve_selected() -> Dictionary:
	if selected.is_empty() or resolver == null:
		return {}
	return resolver.resolve(selected, str(selected.get("name", "")))


# ---------------------------------------------------------------------------
# 每帧
# ---------------------------------------------------------------------------

func update_system(delta: float, active: bool, camera_world: Vector3) -> void:
	if world == null or _meshes.is_empty():
		return
	if active != _active:
		_active = active
		if not active:
			clear()
		_update_visibility()
	if not _active:
		return
	_time += minf(0.1, maxf(0.0, delta))
	position_beam(camera_world)


## 原版 positionBeam
func position_beam(camera_world: Vector3) -> void:
	if selected.is_empty():
		return
	var center := CoordinateUtil.to_world(float(selected["x"]), float(selected["z"]),
		float(selected["y"]))
	var distance := camera_world.distance_to(center)
	var height := clampf(distance * 0.31, 100.0, 560.0)
	var width := clampf(distance * 0.002, 0.65, 5.5)
	var pulse := 0.94 + sin(_time * 1.65) * 0.06

	var glow := _meshes[0] as MeshInstance3D
	glow.position = center + Vector3(0.0, 0.24 + height * 0.5, 0.0)
	glow.scale = Vector3(width, height, width)

	var core := _meshes[1] as MeshInstance3D
	core.position = glow.position
	core.scale = Vector3(width * 0.24, height, width * 0.24)

	var ring := _meshes[2] as MeshInstance3D
	ring.position = center + Vector3(0.0, 0.26, 0.0)
	var ring_scale := clampf(distance / 900.0, 0.7, 2.8)
	ring.scale = Vector3(ring_scale, 1.0, ring_scale)

	for mat in _materials:
		(mat as ShaderMaterial).set_shader_parameter("pulse", pulse)


func _update_visibility() -> void:
	var show := _active and not selected.is_empty()
	for m in _meshes:
		(m as MeshInstance3D).visible = show


func _toast_msg(msg: String) -> void:
	if _toast.is_valid():
		_toast.call(msg)


func diagnostics() -> Dictionary:
	return {
		"active": _active,
		"hasSelection": not selected.is_empty(),
		"favorites": favorites.size(),
		"meshes": _meshes.size(),
		"selection": STATE.copy_point(selected) if not selected.is_empty() else {},
	}
