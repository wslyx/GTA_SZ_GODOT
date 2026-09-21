extends RefCounted
class_name PointGrid
##
## 点的均匀网格索引：build 一次，之后 query_radius 只返回半径内的下标。
##
## 用途：把"每帧/每周期扫全量数据"的循环降到只扫附近的一小撮。
## 实测痛点（都是 GDScript 全量扫、真机上拖垮主线程）：
##   - 灯位 20409 个、每 0.4s 扫一遍（lighting_director）
##   - 停车排 21110 辆、每 0.5s 扫一遍（ebike_system）
##   - 林冠 40927 棵、每 2s 扫一遍还要排序（scenery_system）
##   - 招牌 3077 条、每 0.25s 扫一遍（sign_system）
##
## 用法：
##   var grid := PointGrid.new(256.0)   # 单元 256m
##   grid.build(points)                 # points: PackedVector2Array
##   for idx in grid.query_radius(center, 300.0):
##       var p := points[idx] ...

var cell_size: float
var _cells: Dictionary = {}   ## Vector2i → PackedInt32Array（点下标）


func _init(cs: float) -> void:
	cell_size = maxf(cs, 1.0)


func _cell_of(p: Vector2) -> Vector2i:
	return Vector2i(int(floor(p.x / cell_size)), int(floor(p.y / cell_size)))


func build(points: PackedVector2Array) -> void:
	_cells.clear()
	for i in points.size():
		var c := _cell_of(points[i])
		if _cells.has(c):
			_cells[c].append(i)
		else:
			_cells[c] = PackedInt32Array([i])


## 返回半径内的点下标（无序）。结果量级 = 密度 × 覆盖面积，
## 远小于全量 —— 这正是用它替换全量扫描的原因。
func query_radius(center: Vector2, radius: float) -> Array:
	var out: Array = []
	var span := int(ceil(radius / cell_size))
	var cc := _cell_of(center)
	for dx in range(-span, span + 1):
		for dz in range(-span, span + 1):
			var k := Vector2i(cc.x + dx, cc.y + dz)
			if _cells.has(k):
				out.append_array(_cells[k])
	return out


## 返回半径内、按到 center 的距离升序排列的点下标（带距离）。
## 返回 [{idx, dist}, ...]
func query_radius_sorted(center: Vector2, radius: float, points: PackedVector2Array) -> Array:
	var ids := query_radius(center, radius)
	var out: Array = []
	for idx in ids:
		var d := points[idx].distance_to(center)
		if d <= radius:
			out.append({"idx": idx, "dist": d})
	out.sort_custom(func(a, b): return a["dist"] < b["dist"])
	return out
