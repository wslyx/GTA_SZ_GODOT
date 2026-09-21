extends RefCounted
class_name SpatialHash
##
## 均匀网格空间哈希。对应原版 CityCollision 里的 `cells` / `bCells`（cell 边长 90）。
##
## 用途：
##   - 顶点/实例的空间查询（路灯、树木、招牌的近邻裁剪）
##   - 线段索引（道路段最近点查询，供自动驾驶与碰撞使用）
##   - 多边形索引（建筑的环包含测试）
##
## 键一律用数据坐标 (east, north) 计算，与 world 坐标的 z 轴符号无关。

var cell_size: float
var _buckets: Dictionary = {}


func _init(p_cell_size: float = 90.0) -> void:
	cell_size = p_cell_size


func _key(cx: int, cz: int) -> int:
	# 把两个 int 压成一个 int 键，避免字符串哈希开销
	return (cx + 32768) * 65536 + (cz + 32768)


func cell_of(east: float, north: float) -> Vector2i:
	return Vector2i(int(floor(east / cell_size)), int(floor(north / cell_size)))


## 把一个元素按其包围盒范围插入所有覆盖到的格子
func insert_range(value, min_e: float, min_n: float, max_e: float, max_n: float) -> void:
	var c0 := cell_of(min_e, min_n)
	var c1 := cell_of(max_e, max_n)
	for cx in range(c0.x, c1.x + 1):
		for cz in range(c0.y, c1.y + 1):
			var k := _key(cx, cz)
			if not _buckets.has(k):
				_buckets[k] = []
			_buckets[k].append(value)


## 按点插入
func insert(value, east: float, north: float) -> void:
	insert_range(value, east, north, east, north)


## 查询单个格子
func at(east: float, north: float) -> Array:
	var k := _key(int(floor(east / cell_size)), int(floor(north / cell_size)))
	return _buckets.get(k, [])


## 查询 3×3 邻域（用于"附近"类查询）
func around(east: float, north: float, rings: int = 1) -> Array:
	var c := cell_of(east, north)
	var out: Array = []
	for dx in range(-rings, rings + 1):
		for dz in range(-rings, rings + 1):
			var k := _key(c.x + dx, c.y + dz)
			if _buckets.has(k):
				out.append_array(_buckets[k])
	return out


## 半径查询（先粗筛 3×3，再由调用方按距离精筛）。返回去重后的列表。
func within_radius(east: float, north: float, radius: float) -> Array:
	var rings := int(ceil(radius / cell_size))
	var seen := {}
	var out: Array = []
	var c := cell_of(east, north)
	var r2 := radius * radius
	for dx in range(-rings, rings + 1):
		for dz in range(-rings, rings + 1):
			var k := _key(c.x + dx, c.y + dz)
			if not _buckets.has(k):
				continue
			for v in _buckets[k]:
				if not (v is Vector2):
					continue
				if seen.has(v):
					continue
				var d := Vector2(v).distance_squared_to(Vector2(east, north))
				if d <= r2:
					seen[v] = true
					out.append(v)
	return out


func cell_count() -> int:
	return _buckets.size()


func clear() -> void:
	_buckets.clear()
