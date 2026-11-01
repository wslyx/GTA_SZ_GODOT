extends Node3D
class_name AlsPhysicsGround
##
## ALS 物理碰撞代理 —— 为 C# ALS 胶囊角色（src/Als.Godot/Locomotion/
## GtaSzAlsPlayerHost.cs）提供它必需的物理世界。
##
## 背景：深城纪的世界是"高度场采样 + 无物理体"的移植架构（CityWalk 走
## height_at(x,z)，CityCollision 走二维足迹 blocked(x,z)），全场景没有任何
## StaticBody3D。而 ALS 角色是标准 Godot 物理角色（CharacterBody3D +
## IntersectRay 接地探针，碰撞层/掩码 1），没有物理地面就会直接坠落。
##
## 方案：跟随玩家的"局部物理世界"——
##   1) 地面：以玩家为中心的 N×N 方格瓦片（StaticBody3D + 共享 BoxShape3D），
##      每片顶面贴 height_field.height_at 的采样高度。玩家挪出阈值就整组重排。
##      斜坡（盘山道/引桥）在瓦片尺度内呈台阶状，ALS 的迈步与地面探针可消化；
##      水面高度有限且有限，所以海湾上也能像原版步行一样"走在水面上"。
##   2) 建筑：按 FlightCollision 同款 160m 格索引 CityData.buildings，每个
##      建筑用其外环 AABB 挤出成 BoxShape3D（跳过 landmark-detail 与
##      height<=1.1，与 FlightCollision 的简化口径一致）。玩家跨格时增删格。
##
## 坐标：世界 = (east, y, -north)（CoordinateUtil 契约），height_field 的入口
## 是数据坐标 (east, north)，本地做 z → -z 翻转。
##
## 层级：全部 shape 落 layer 1 / mask 1 —— ALS 马达的生产碰撞掩码就是 1。

const TILE := 6.0                 ## 地面瓦片边长（米）
const GROUND_RADIUS := 42.0       ## 以玩家为中心的地面覆盖半径（米）
const GROUND_DEPTH := 2.0         ## 瓦片厚度（顶面在采样高度，往下延伸）
const REBUILD_STEP := 2.0         ## 玩家位移超过该值才重排地面瓦片
const CELL := 160.0               ## 建筑索引格边长（与 FlightCollision.CELL 一致）
const BUILDING_CELL_REACH := 1    ## 玩家所在格向四周扩展的格数

var _world: CityWorld
var _ground_body: StaticBody3D
var _tiles: Array[CollisionShape3D] = []
var _tile_shape: BoxShape3D
var _ground_center := Vector2(1.0e9, 1.0e9)
var _building_bodies: Dictionary = {}    ## 格键 → StaticBody3D
var _building_cell := Vector2i(0x7FFFFFFF, 0x7FFFFFFF)
var _building_cells: Dictionary = {}     ## 格键 → Array[[BoxShape3D, Vector3 中心], ...]（setup 一次性索引）
var _vehicle_body: StaticBody3D = null   ## 停着的载具障碍盒（下车时放置，上车时移除）

func setup(world: CityWorld) -> void:
	_world = world
	name = "AlsPhysicsGround"
	_ground_body = StaticBody3D.new()
	_ground_body.name = "GroundProxy"
	_ground_body.collision_layer = 1
	_ground_body.collision_mask = 1
	add_child(_ground_body)
	_tile_shape = BoxShape3D.new()
	_tile_shape.size = Vector3(TILE, GROUND_DEPTH, TILE)
	var grid := int(ceil(GROUND_RADIUS * 2.0 / TILE))
	for i in grid * grid:
		var shape := CollisionShape3D.new()
		shape.shape = _tile_shape
		shape.disabled = true
		_ground_body.add_child(shape)
		_tiles.append(shape)
	# 全城建筑按格索引成缓存：GDScript 全量解析环点一次要几百毫秒到数秒，
	# 必须放在加载期做掉 —— 这是首次下车卡顿的主因之一。
	# ⚠️ buildings 由 CityWorld 构建步骤 0（CityData.load_core）填充，
	# setup 时还是空的 —— 挂 core_loaded 信号，数据就绪瞬间在主线程建索引。
	if CityData.is_loaded():
		_index_buildings()
	else:
		CityData.core_loaded.connect(_index_buildings, CONNECT_ONE_SHOT)


## 每帧由 main_game._step_walk 以 ALS 马达世界坐标调用。
func update_around(world_pos: Vector3) -> void:
	var __hitch_t0 := Time.get_ticks_msec()
	if _world == null:
		return
	var center := Vector2(world_pos.x, world_pos.z)
	if _ground_center.distance_squared_to(center) > REBUILD_STEP * REBUILD_STEP:
		_rebuild_ground(center)
		_ground_center = center
	var cell := Vector2i(int(floor(world_pos.x / CELL)), int(floor(world_pos.z / CELL)))
	if cell != _building_cell:
		_rebuild_buildings(cell)
		_building_cell = cell

	var __hitch_ms := Time.get_ticks_msec() - __hitch_t0
	if __hitch_ms > 15:
		print("[HITCH] %s 本帧 %d ms" % ["AlsGround", __hitch_ms])

func _rebuild_ground(center: Vector2) -> void:
	var height_field: HeightField = _world.height_field
	# 瓦片中心对齐到 TILE 网格，保证玩家居中且不随移动抖动。
	# 偏移用 (grid-1)/2 而非 grid/2：14 片时中心偏移 ±39m、各片再外延 3m，
	# 覆盖恰为 ±42m（GROUND_RADIUS）；用 grid/2 会偏出一整片（-45/+39）。
	var origin_x := floorf(center.x / TILE) * TILE
	var origin_z := floorf(center.y / TILE) * TILE
	var grid := int(ceil(GROUND_RADIUS * 2.0 / TILE))
	var index := 0
	for ix in grid:
		for iz in grid:
			var wx := origin_x + (ix - (grid - 1) * 0.5) * TILE
			var wz := origin_z + (iz - (grid - 1) * 0.5) * TILE
			var height: float = height_field.height_at(wx, -wz)
			var shape := _tiles[index]
			index += 1
			if not is_finite(height):
				shape.disabled = true
				continue
			shape.disabled = false
			shape.position = Vector3(wx, height - GROUND_DEPTH * 0.5, wz)


func _cell_key(cx: int, cz: int) -> int:
	return (cx + 32768) * 65536 + (cz + 32768)


## 一次性把 CityData.buildings 按格索引成 [BoxShape3D, 中心] 缓存。
## 口径与原实现一致：外环 AABB 挤出成盒（跳过 landmark-detail 与
## height<=1.1），跨格建筑整块放进每个覆盖它的格（重复块无副作用）。
func _index_buildings() -> void:
	var buildings: Array = CityData.buildings
	for b in buildings:
		var height := float(b.get("height", 0.0))
		if str(b.get("style", "")) == "landmark-detail" or height <= 1.1:
			continue
		var rings: Array = b.get("rings", [])
		if rings.is_empty():
			continue
		var minx := INF
		var minz := INF
		var maxx := -INF
		var maxz := -INF
		for p in rings[0]:
			var px := 0.0
			var pz := 0.0
			if p is Vector2:
				px = p.x
				pz = p.y
			else:
				px = float(p[0])
				pz = float(p[1])
			minx = minf(minx, px)
			maxx = maxf(maxx, px)
			minz = minf(minz, pz)
			maxz = maxf(maxz, pz)
		if not is_finite(minx) or maxx - minx < 0.2 or maxz - minz < 0.2:
			continue
		var box := BoxShape3D.new()
		box.size = Vector3(maxx - minx, height, maxz - minz)
		var pos := Vector3((minx + maxx) * 0.5, height * 0.5, -(minz + maxz) * 0.5)
		for cx in range(int(floor(minx / CELL)), int(floor(maxx / CELL)) + 1):
			for cz in range(int(floor(minz / CELL)), int(floor(maxz / CELL)) + 1):
				var key := _cell_key(cx, cz)
				if not _building_cells.has(key):
					_building_cells[key] = []
				_building_cells[key].append([box, pos])


## 增量式跨格：离开范围的格 freed，新进入范围的格按缓存查表实例化。
## （原先每次跨格全量扫描全城并重建 3×3 格 —— 步行中反复卡顿的来源。）
func _rebuild_buildings(cell: Vector2i) -> void:
	var keep := {}
	for cx in range(cell.x - BUILDING_CELL_REACH, cell.x + BUILDING_CELL_REACH + 1):
		for cz in range(cell.y - BUILDING_CELL_REACH, cell.y + BUILDING_CELL_REACH + 1):
			var key := _cell_key(cx, cz)
			keep[key] = true
			# ⚠️ 无建筑的格 _build_cell 返回 null —— 只缓存非空体，
			# 否则下次重建对 Nil 调 queue_free 报错（空格重查缓存也只花微秒）。
			var body := _build_cell(key)
			if body != null:
				_building_bodies[key] = body
	for key in _building_bodies.keys():
		if not keep.has(key):
			_building_bodies[key].queue_free()
			_building_bodies.erase(key)


## 一个格子的建筑碰撞体：格内所有缓存建筑合成一个 StaticBody3D。
func _build_cell(key: int) -> StaticBody3D:
	var entries: Array = _building_cells.get(key, [])
	if entries.is_empty():
		return null
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 1
	add_child(body)
	for e in entries:
		var shape := CollisionShape3D.new()
		shape.shape = e[0]
		shape.position = e[1]
		body.add_child(shape)
	return body


## —— 停着的载具障碍（GTA 式停车：下车后车留在原地且不可穿越）——
## 载具体系没有物理体（世界是"高度场 + 无物理体"架构），mannequin 的
## 胶囊只跟本代理的 layer-1 静态体碰撞；不补这个盒就会从停着的车里穿过。
## 尺寸用模型自身的合并 AABB 推（跟随模型当前 yaw 旋转），上车时 clear。

## 在 ALS 物理代理里放置"停着的载具"障碍盒。model = 载具模型根节点。
func set_vehicle_obstacle(model: Node3D) -> void:
	clear_vehicle_obstacle()
	if model == null or not model.is_inside_tree():
		return
	var aabb := _merged_local_aabb(model)
	if aabb.size.x < 0.5 or aabb.size.z < 0.5:
		return
	var body := StaticBody3D.new()
	body.name = "ParkedVehicle"
	body.collision_layer = 1
	body.collision_mask = 1
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = aabb.size
	shape.shape = box
	shape.position = aabb.get_center()
	body.add_child(shape)
	add_child(body)
	# 跟随模型当前的世界放置（含 yaw 朝向与贴地高度）
	body.global_transform = Transform3D(model.global_basis, model.global_position)
	_vehicle_body = body


## 移除载具障碍（上车/载具重新开始移动前调用）。
func clear_vehicle_obstacle() -> void:
	if _vehicle_body != null:
		_vehicle_body.queue_free()
		_vehicle_body = null


## 模型树在 root 本地空间内的合并 AABB（跳过 root 自身 transform）。
func _merged_local_aabb(root: Node3D) -> AABB:
	var mn := Vector3.INF
	var mx := -Vector3.INF
	var stack: Array = [[root, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var e: Array = stack.pop_back()
		var n: Node = e[0]
		var xf: Transform3D = e[1]
		if n is Node3D and n != root:
			xf = xf * (n as Node3D).transform
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.mesh != null and mi.mesh.get_aabb().size.length() > 0.0:
				# 复用 GlbLoader 的角点法 AABB 变换（Transform3D * AABB 版本差异坑）
				var ab: AABB = GlbLoader._xf_aabb(xf, mi.mesh.get_aabb())
				mn = mn.min(ab.position)
				mx = mx.max(ab.position + ab.size)
		for c in n.get_children():
			stack.append([c, xf])
	if not is_finite(mn.x):
		return AABB()
	return AABB(mn, mx - mn)
