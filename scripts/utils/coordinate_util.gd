extends Node
##
## 坐标契约 —— 整个项目只在这里定义一次，其它模块一律调用本文件。
##
## 【数据侧】(data space) 与原版 GTA_SZ 完全一致：
##   单位 = 真实米 × 0.60，x = 东(east)，z = 北(north)，y = 上。
##   originWGS84 = [114.025, 22.536]，经度差 ×102850、纬度差 ×111320。
##   朝向 yaw 的方向向量为 (sin yaw, cos yaw)，即 yaw=0 指向正北，yaw=π/2 指向正东。
##
## 【Godot 侧】(world space)
##   Godot 是右手系。要让"东×上 = -北"成立（真实地理的右手表示），必须取
##       world = (x = east, y = up, z = -north)
##   这不是随意选择：Blender 资产经 glTF 导出后正好是 (east, up, -north)，
##   与本约定一致，因此**所有 GLB 无需任何旋转或镜像即可直接使用**。
##   若改成 z = +north，就必须给每个 GLB 根节点做 Z 镜像，而那会反转三角形绕序，
##   是移植中最容易踩且最难排查的坑之一。
##
## 【朝向换算】
##   数据 yaw → world 方向：(sin yaw, 0, -cos yaw)
##   节点 rotation.y 的取值取决于模型在 glTF 里的前向轴：
##     - 模型前向 = +Z（车/坦克/飞机/行人等多数资产）：rotation.y = PI - yaw
##     - 模型前向 = -Z：                              rotation.y = -yaw
##   用 forward_mode 参数区分，见 ModelForward 枚举。

enum ModelForward {
	PLUS_Z,  ## glTF 中模型朝向 +Z（本项目绝大多数资产）
	MINUS_Z, ## glTF 中模型朝向 -Z
}

const ORIGIN_LON := 114.025
const ORIGIN_LAT := 22.536
const LON_METRES := 102850.0
const LAT_METRES := 111320.0
const HORIZONTAL_SCALE := 0.60
const VERTICAL_SCALE := 0.60

## city.json meta.extent（数据坐标 [minX, minZ, maxX, maxZ]）
const EXTENT_MIN_X := -6788.1
const EXTENT_MIN_Z := -2604.89
const EXTENT_MAX_X := 6788.1
const EXTENT_MAX_Z := 2604.89

## coastal/infrastructure.json
const WATER_HEIGHT := -0.25

## 立面瓦片分块边长（facade-tiles.json tileSize）
const FACADE_TILE_SIZE := 640.0
## 城市网格分块边长（buildings.glb 的 block_<i>_<j>_ 命名）
const CITY_BLOCK_SIZE := 640.0


## 数据 (east, north) → Godot Vector3（y 由调用方给或默认 0）
func to_world(east: float, north: float, y: float = 0.0) -> Vector3:
	return Vector3(east, y, -north)


func to_world_v2(v: Vector2, y: float = 0.0) -> Vector3:
	return Vector3(v.x, y, -v.y)


## Godot Vector3 → 数据 (east, north)
func from_world(v: Vector3) -> Vector2:
	return Vector2(v.x, -v.z)


## 只换 XZ 平面：数据 (east, north) → Godot (x, z)
func to_world_xz(east: float, north: float) -> Vector2:
	return Vector2(east, -north)


## WGS84 经纬度 → 数据坐标（对应原版 city-map-geometry.ts 的 wgs84ToMap）
func wgs84_to_map(lon: float, lat: float) -> Vector2:
	return Vector2(
		(lon - ORIGIN_LON) * LON_METRES * HORIZONTAL_SCALE,
		(lat - ORIGIN_LAT) * LAT_METRES * HORIZONTAL_SCALE
	)


## 数据 yaw → world 单位方向向量（水平）
func yaw_to_direction(yaw: float) -> Vector3:
	return Vector3(sin(yaw), 0.0, -cos(yaw))


## world 单位方向向量 → 数据 yaw（yaw_to_direction 的逆）
func direction_to_yaw(dir: Vector3) -> float:
	return atan2(dir.x, -dir.z)


## 让"模型前向轴"对准数据 yaw 所需的节点 rotation.y
func node_yaw(yaw: float, forward: int = ModelForward.PLUS_Z) -> float:
	if forward == ModelForward.PLUS_Z:
		return PI - yaw
	return -yaw


## 让"模型前向轴"对准 world 方向向量所需的 rotation.y
func node_yaw_from_direction(dir: Vector3, forward: int = ModelForward.PLUS_Z) -> float:
	return node_yaw(direction_to_yaw(dir), forward)


## 由节点 rotation.y 反推数据 yaw
func yaw_from_node_yaw(rot_y: float, forward: int = ModelForward.PLUS_Z) -> float:
	if forward == ModelForward.PLUS_Z:
		return PI - rot_y
	return -rot_y


func in_extent(east: float, north: float) -> bool:
	return east >= EXTENT_MIN_X and east <= EXTENT_MAX_X and north >= EXTENT_MIN_Z and north <= EXTENT_MAX_Z


# ---------------------------------------------------------------------------
# 多边形工具
# ---------------------------------------------------------------------------

## 数据环 [[east, north], ...] → Godot XZ 平面点列 PackedVector2Array(x, z)
func ring_to_xz(ring: Array) -> PackedVector2Array:
	var pts := PackedVector2Array()
	pts.resize(ring.size())
	for i in ring.size():
		var p: Array = ring[i]
		pts[i] = Vector2(float(p[0]), -float(p[1]))
	return pts


## 2D 有符号面积（以 (x, z) 为平面）。>0 为逆时针。
static func signed_area_2d(pts: PackedVector2Array) -> float:
	var a := 0.0
	var n := pts.size()
	for i in n:
		var p := pts[i]
		var q := pts[(i + 1) % n]
		a += p.x * q.y - q.x * p.y
	return a * 0.5


## Godot 4 的正面为顺时针绕序：要得到朝上的地面三角形，(x,z) 必须顺时针（面积为负）。
## 传入三个顶点，若绕序不对则交换后两个。
static func wind_up_facing(tri: PackedVector2Array) -> PackedVector2Array:
	if signed_area_2d(tri) > 0.0:
		var t := tri[1]
		tri[1] = tri[2]
		tri[2] = t
	return tri


## 数据环（含洞）→ 三角化的 XZ 三角形列表，绕序已修正为朝上。
## holes 为洞的环数组（数据坐标）。用 Geometry2D 做多边形差集以支持洞。
func triangulate_polygon_with_holes(outer: Array, holes: Array = []) -> PackedVector3Array:
	var out_pts := ring_to_xz(outer)
	var merged: Array[PackedVector2Array] = [out_pts]
	for h in holes:
		var hp := ring_to_xz(h)
		var next: Array[PackedVector2Array] = []
		for poly in merged:
			var diff := Geometry2D.clip_polygons(poly, hp)
			for d in diff:
				if d.size() >= 3:
					next.append(d)
		merged = next
		if merged.is_empty():
			break

	var tris := PackedVector3Array()
	for poly in merged:
		var idx := Geometry2D.triangulate_polygon(poly)
		var i := 0
		while i + 2 < idx.size():
			var tri := PackedVector2Array([poly[idx[i]], poly[idx[i + 1]], poly[idx[i + 2]]])
			tri = wind_up_facing(tri)
			for v in tri:
				tris.append(Vector3(v.x, 0.0, v.y))
			i += 3
	return tris
