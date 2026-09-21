extends RefCounted
class_name RoadGraph
##
## 路网图 + A* 路径规划 —— 一比一移植原版 src/navigation.ts 的 RoadGraph。
##
## 原版有两种构建方式：
##   - 传 noded（navigation.json 的 {nodes, edges}）→ 直接用预计算图
##   - 否则按 `Math.round(p/3)` 合并坐标重合的端点，从 roads 现场构建
## 主客户端用的是预计算图（42829 节点 / 47218 边），本移植同样优先用 navigation.json。
##
## 邻接表用 CSR（compressed sparse row）扁平数组存储，避免 4 万个 Dictionary 的开销。

var nodes := PackedVector2Array()
var _edge_start := PackedInt32Array()
var _edge_to := PackedInt32Array()
var _edge_len := PackedFloat32Array()
var _degree := PackedInt32Array()

## 原始边列表（建图时保留，供调试/统计）
var raw_edges: Array = []


func build_from_navigation() -> bool:
	CityData.load_navigation()
	if CityData.nav_nodes.is_empty():
		return false
	nodes = CityData.nav_nodes
	var pairs: Array = CityData.nav_edges
	raw_edges = pairs
	_build_csr(pairs)
	print("[RoadGraph] 使用 navigation.json：%d 节点 / %d 边" % [nodes.size(), pairs.size()])
	return true


func build_from_roads(roads: Array) -> void:
	var lookup := {}
	var edge_pairs: Array = []
	nodes = PackedVector2Array()
	for r in roads:
		var pts: PackedVector2Array = r["points"]
		var prev := -1
		for p in pts:
			var key := "%d,%d" % [int(round(p.x / 3.0)), int(round(p.y / 3.0))]
			var id: int = lookup.get(key, -1)
			if id < 0:
				id = nodes.size()
				lookup[key] = id
				nodes.append(p)
			if prev >= 0 and prev != id:
				edge_pairs.append(Vector2i(prev, id))
			prev = id
	raw_edges = edge_pairs
	_build_csr(edge_pairs)
	print("[RoadGraph] 从 roads 现场构建：%d 节点 / %d 边" % [nodes.size(), edge_pairs.size()])


func _build_csr(pairs: Array) -> void:
	var n := nodes.size()
	_degree.resize(n)
	_degree.fill(0)
	for e in pairs:
		var a := int(e[0])
		var b := int(e[1])
		if a < 0 or b < 0 or a >= n or b >= n:
			continue
		_degree[a] += 1
		_degree[b] += 1

	_edge_start.resize(n + 1)
	_edge_start[0] = 0
	for i in n:
		_edge_start[i + 1] = _edge_start[i] + _degree[i]

	var total := _edge_start[n]
	_edge_to.resize(total)
	_edge_len.resize(total)
	var cursor := PackedInt32Array()
	cursor.resize(n)
	cursor.fill(0)
	for e in pairs:
		var a := int(e[0])
		var b := int(e[1])
		if a < 0 or b < 0 or a >= n or b >= n or a == b:
			continue
		var d := nodes[a].distance_to(nodes[b])
		var ia := _edge_start[a] + cursor[a]
		_edge_to[ia] = b
		_edge_len[ia] = d
		cursor[a] += 1
		var ib := _edge_start[b] + cursor[b]
		_edge_to[ib] = a
		_edge_len[ib] = d
		cursor[b] += 1


func neighbors(i: int) -> Array:
	var out: Array = []
	for k in range(_edge_start[i], _edge_start[i + 1]):
		out.append({"to": _edge_to[k], "len": _edge_len[k]})
	return out


func neighbor_ids(i: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for k in range(_edge_start[i], _edge_start[i + 1]):
		out.append(_edge_to[k])
	return out


func degree(i: int) -> int:
	return _edge_start[i + 1] - _edge_start[i]


func edge_length(i: int, j: int) -> float:
	for k in range(_edge_start[i], _edge_start[i + 1]):
		if _edge_to[k] == j:
			return _edge_len[k]
	return -1.0


func has_edge(i: int, j: int) -> bool:
	return edge_length(i, j) >= 0.0


## 线性最近节点。原版如此（O(n)）；40 万次调用会有开销，
## 调用方（交通/行人）请自行做节流或缓存。
func nearest(p: Vector2) -> int:
	var best := 0
	var best_d := INF
	for i in nodes.size():
		var d := p.distance_squared_to(nodes[i])
		if d < best_d:
			best_d = d
			best = i
	return best


func nearest_node_in_range(p: Vector2, min_d: float, max_d: float, require_degree: bool = true) -> int:
	var best := -1
	var best_d := INF
	for i in nodes.size():
		if require_degree and degree(i) < 2:
			continue
		var d := p.distance_to(nodes[i])
		if d < min_d or d > max_d:
			continue
		if d < best_d:
			best_d = d
			best = i
	return best


## 最近边：返回 {a, b, point, t, d, length}
func nearest_edge(p: Vector2) -> Dictionary:
	var best := {"a": 0, "b": 0, "point": Vector2.ZERO, "t": 0.0, "d": INF, "length": 0.0}
	var n := nodes.size()
	for i in n:
		var a := nodes[i]
		for k in range(_edge_start[i], _edge_start[i + 1]):
			var j := _edge_to[k]
			if j <= i:
				continue
			var length := _edge_len[k]
			var b := nodes[j]
			var dx := b.x - a.x
			var dz := b.y - a.y
			var t := 0.0
			if length > 0.0:
				t = clamp(((p.x - a.x) * dx + (p.y - a.y) * dz) / (length * length), 0.0, 1.0)
			var point := Vector2(a.x + dx * t, a.y + dz * t)
			var d := p.distance_to(point)
			if d < best["d"]:
				best = {"a": i, "b": j, "point": point, "t": t, "d": d, "length": length}
	return best


## 把折线加密到间距 ≤20（且跳过 <0.08 的重复点）
static func dense(points: Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	for p in points:
		var pp: Vector2 = p
		if result.is_empty():
			result.append(pp)
			continue
		var q := result[result.size() - 1]
		var d := q.distance_to(pp)
		if d < 0.08:
			continue
		var steps := int(ceil(d / 20.0))
		for k in range(1, steps + 1):
			result.append(q + (pp - q) * (float(k) / float(steps)))
	return result


## A* / Dijkstra（原版用一致代价 Dijkstra + 二叉堆）。返回数据坐标折线。
##
## 注意：`nearest_edge()` 返回的是 Dictionary，`dict["key"]` 取出来是 Variant。
## 直接写 `var last := end["a"] if ... else end["b"]` 会因为推断不出类型而报
## "Cannot infer the type of last variable"，用 Variant 当下标去索引
## PackedFloat64Array 也会退化成不安全的运行时检查。
## 所以这里先把结果取成有类型的局部变量，后面全部用它们。
func route(a: Vector2, b: Vector2) -> PackedVector2Array:
	var n := nodes.size()
	if n == 0:
		return PackedVector2Array()

	var start := nearest_edge(a)
	var end := nearest_edge(b)

	var sa: int = start["a"]
	var sb: int = start["b"]
	var sp: Vector2 = start["point"]
	var st: float = start["t"]
	var slen: float = start["length"]

	var ea: int = end["a"]
	var eb: int = end["b"]
	var ep: Vector2 = end["point"]
	var et: float = end["t"]
	var elen: float = end["length"]

	if sa == ea and sb == eb:
		return dense([a, sp, ep, b])

	var dist := PackedFloat64Array()
	dist.resize(n)
	dist.fill(INF)
	var parent := PackedInt32Array()
	parent.resize(n)
	parent.fill(-1)
	var visited := PackedByteArray()
	visited.resize(n)

	var heap := _MinHeap.new()
	var start_cost_a := st * slen
	var start_cost_b := (1.0 - st) * slen
	dist[sa] = start_cost_a
	dist[sb] = start_cost_b
	heap.push(sa, start_cost_a)
	heap.push(sb, start_cost_b)

	while not heap.is_empty():
		var top := heap.pop()
		var id: int = top[0]
		var d: float = top[1]
		if visited[id] == 1:
			continue
		if d > dist[id]:
			continue
		visited[id] = 1
		for k in range(_edge_start[id], _edge_start[id + 1]):
			var nx: int = _edge_to[k]
			var nd := d + _edge_len[k]
			if nd < dist[nx]:
				dist[nx] = nd
				parent[nx] = id
				heap.push(nx, nd)

	var cost_a := dist[ea] + et * elen
	var cost_b := dist[eb] + (1.0 - et) * elen
	var last: int = ea if cost_a <= cost_b else eb
	if not is_finite(dist[last]):
		return PackedVector2Array()

	var rev: Array = []
	var v := last
	var guard := 0
	while v >= 0 and guard < n * 2:
		rev.append(nodes[v])
		v = parent[v]
		guard += 1
	rev.reverse()

	var pts: Array = [a, sp]
	pts.append_array(rev)
	pts.append(ep)
	pts.append(b)
	return dense(pts)


## 供诊断
func stats() -> Dictionary:
	return {"nodes": nodes.size(), "edges": raw_edges.size(), "csr": _edge_len.size()}


## 最小二叉堆（元素为 [id, cost]）
class _MinHeap extends RefCounted:
	var _h: Array = []

	func is_empty() -> bool:
		return _h.is_empty()

	func push(id: int, cost: float) -> void:
		_h.append([id, cost])
		var i := _h.size() - 1
		while i > 0:
			var p := (i - 1) >> 1
			if _h[p][1] <= _h[i][1]:
				break
			var t = _h[p]
			_h[p] = _h[i]
			_h[i] = t
			i = p

	func pop() -> Array:
		var top: Array = _h[0]
		var last: Array = _h.pop_back()
		if not _h.is_empty():
			_h[0] = last
			var i := 0
			var size := _h.size()
			while i * 2 + 1 < size:
				var c := i * 2 + 1
				if c + 1 < size and _h[c + 1][1] < _h[c][1]:
					c += 1
				if _h[c][1] >= _h[i][1]:
					break
				var t = _h[i]
				_h[i] = _h[c]
				_h[c] = t
				i = c
		return top
