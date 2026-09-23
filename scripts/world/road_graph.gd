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

## 连通分量。
##
## 实测 navigation.json 的 42829 个节点分属 **1102 个**连通分量，最大的
## 35558 节点（83%）才是真正能开车到的路网，其余是小区/园区/公园内部的
## 孤立小岛（几百个节点甚至更少）。只要起点或终点落在岛上，`route()` 就会
## 返回空路线 —— 玩家看到的是"无法规划到该目的地的路线"，也就是"功能坏了"。
## 建图时把分量算一次，route() 里把孤岛端吸附到主分量上最近的可达点。
var _comp := PackedInt32Array()
var _main_comp := -1
var _main_count := 0

## 节点网格索引（cell 128m）。route() 每次要查 2 次最近边，
## 线性全扫是 O(N+E)=13 万次迭代，实测是规划耗时的大头。
var _grid: Dictionary = {}
const GRID_CELL := 128.0
const GRID_MAX_RING := 24


func build_from_navigation() -> bool:
	CityData.load_navigation()
	if CityData.nav_nodes.is_empty():
		return false
	nodes = CityData.nav_nodes
	var pairs: Array = CityData.nav_edges
	raw_edges = pairs
	_build_csr(pairs)
	_build_components()
	_build_grid()
	print("[RoadGraph] 使用 navigation.json：%d 节点 / %d 边 / 主分量 %d 节点（%.0f%%）"
		% [nodes.size(), pairs.size(), _main_count,
			float(_main_count) / maxf(1.0, float(nodes.size())) * 100.0])
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
	_build_components()
	_build_grid()
	print("[RoadGraph] 从 roads 现场构建：%d 节点 / %d 边 / 主分量 %d 节点"
		% [nodes.size(), edge_pairs.size(), _main_count])


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


## 连通分量（迭代式 DFS，4 万节点不能递归）
func _build_components() -> void:
	var n := nodes.size()
	_comp.resize(n)
	_comp.fill(-1)
	var stack := PackedInt32Array()
	var sizes: Array = []
	var cid := 0
	for s in n:
		if _comp[s] >= 0:
			continue
		_comp[s] = cid
		stack.clear()
		stack.append(s)
		var cnt := 1
		while not stack.is_empty():
			var v: int = stack[stack.size() - 1]
			stack.remove_at(stack.size() - 1)
			for k in range(_edge_start[v], _edge_start[v + 1]):
				var nx: int = _edge_to[k]
				if _comp[nx] < 0:
					_comp[nx] = cid
					cnt += 1
					stack.append(nx)
		sizes.append(cnt)
		cid += 1
	_main_comp = -1
	_main_count = 0
	for i in sizes.size():
		if sizes[i] > _main_count:
			_main_count = sizes[i]
			_main_comp = i


func _cell_key(p: Vector2) -> Vector2i:
	return Vector2i(int(floor(p.x / GRID_CELL)), int(floor(p.y / GRID_CELL)))


func _build_grid() -> void:
	_grid.clear()
	for i in nodes.size():
		var k := _cell_key(nodes[i])
		var arr: PackedInt32Array = _grid.get(k, PackedInt32Array())
		arr.append(i)
		_grid[k] = arr


## 主分量里离 p 最近的节点；没有主分量或找不到时返回 -1。
## 从 p 所在格向外一圈圈扩（每圈只扫环，不重复扫内部），
## 找到的距离 ≤ (已扫半径 − 1 格) 时即判定为全局最近。
func nearest_main_node(p: Vector2) -> int:
	if _grid.is_empty() or _main_comp < 0:
		return -1
	var c := _cell_key(p)
	var best := -1
	var best_d := INF
	for r in range(0, GRID_MAX_RING + 1):
		for dx in range(-r, r + 1):
			for dz in range(-r, r + 1):
				if maxi(absi(dx), absi(dz)) != r:
					continue
				var arr: PackedInt32Array = _grid.get(Vector2i(c.x + dx, c.y + dz), PackedInt32Array())
				for i in arr:
					if _comp[i] != _main_comp:
						continue
					var d := p.distance_to(nodes[i])
					if d < best_d:
						best_d = d
						best = i
		if best >= 0 and best_d <= maxf(0.0, float(r - 1) * GRID_CELL):
			return best
	return best


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
##
## 默认走网格加速：从 p 所在格向外扩圈，只检查圈内节点的邻接边。
## 判据与 `nearest_main_node` 相同（找到的距离 ≤ 已扫半径 − 1 格 → 全局最近）；
## 扩到上限仍不满足就退回线性全扫，结果与纯扫描版**完全一致**。
func nearest_edge(p: Vector2) -> Dictionary:
	if not _grid.is_empty():
		var fast := _nearest_edge_grid(p)
		if not fast.is_empty():
			return fast
	return _nearest_edge_scan(p)


func _nearest_edge_grid(p: Vector2) -> Dictionary:
	var c := _cell_key(p)
	var best: Dictionary = {}
	var best_d := INF
	for r in range(0, GRID_MAX_RING + 1):
		# 扩到 3 格（384m）还一条边都没碰到，说明这个点在海面/山体上，
		# 继续扩圈只会白烧 CPU —— 交给线性全扫（罕见路径，结果仍然正确）。
		if r >= 3 and best_d == INF:
			return {}
		for dx in range(-r, r + 1):
			for dz in range(-r, r + 1):
				if maxi(absi(dx), absi(dz)) != r:
					continue
				var arr: PackedInt32Array = _grid.get(Vector2i(c.x + dx, c.y + dz), PackedInt32Array())
				for i in arr:
					for k in range(_edge_start[i], _edge_start[i + 1]):
						# ⚠️ 这里**不能**像全扫版那样 `if j < i: continue`。
						# 全扫版每个节点都会被遍历，每条边恰好在"小端"被算一次；
						# 网格版只看候选节点的邻接，若另一端在候选集外，这条边
						# 就只有在这一端展开时才可能被检查到 —— 跳过会漏边，
						# 实测最多把最近边算错 30 m。重复算一次的代价远小于漏算。
						var j: int = _edge_to[k]
						var hit := _project_on_edge(p, i, j, _edge_len[k])
						if float(hit["d"]) < best_d:
							best_d = float(hit["d"])
							best = hit
		# 未扫到的格至少在某个轴上偏了 r+1 格，其中的点离 p 必 ≥ r×CELL；
		# 再退一格留余量（长边可能横跨未扫区域）。
		if best_d <= maxf(0.0, float(r - 1) * GRID_CELL):
			return best
	return {}


## p 在边 (i, j) 上的投影
func _project_on_edge(p: Vector2, i: int, j: int, length: float) -> Dictionary:
	var a := nodes[i]
	var b := nodes[j]
	var dx := b.x - a.x
	var dz := b.y - a.y
	var t := 0.0
	if length > 0.0:
		t = clampf(((p.x - a.x) * dx + (p.y - a.y) * dz) / (length * length), 0.0, 1.0)
	var point := Vector2(a.x + dx * t, a.y + dz * t)
	return {"a": i, "b": j, "point": point, "t": t, "d": p.distance_to(point), "length": length}


## 线性全扫版（原实现）：网格不可用或加速版拿不到确定解时兜底
func _nearest_edge_scan(p: Vector2) -> Dictionary:
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

	# 孤岛兜底：任一端所在的边不在主分量里，就把它整体挪到主分量上
	# 最近的可达节点（t/length 归零，等价于"从该节点本身出发/到达"）。
	# 不做这一步，1102 个分量里的小岛（占 17% 节点）会让 route() 直接返回
	# 空路线 —— 玩家点了个地标却被告知无法规划。
	if _comp.size() == nodes.size() and _main_comp >= 0:
		if _comp[sa] != _main_comp and _comp[sb] != _main_comp:
			var sn := nearest_main_node(a)
			if sn >= 0:
				sa = sn
				sb = sn
				sp = nodes[sn]
				st = 0.0
				slen = 0.0
		if _comp[ea] != _main_comp and _comp[eb] != _main_comp:
			var en := nearest_main_node(b)
			if en >= 0:
				ea = en
				eb = en
				ep = nodes[en]
				et = 0.0
				elen = 0.0

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

	# 终点两端都出堆即可收工：一致代价搜索下"出堆即最终最短路"，
	# 不必把 42829 个节点全部展开完（近距离路线能省掉大半时间）。
	var end_a_done := false
	var end_b_done := false

	while not heap.is_empty():
		var top := heap.pop()
		var id: int = top[0]
		var d: float = top[1]
		if visited[id] == 1:
			continue
		if d > dist[id]:
			continue
		visited[id] = 1
		if id == ea:
			end_a_done = true
		if id == eb:
			end_b_done = true
		if end_a_done and end_b_done:
			break
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


## 最小二叉堆（元素为 [id, cost]）。
##
## ⚠️ 存成 `Array[Array]` 时每次比较都要做两层 Variant 解引用（`_h[p][1]`），
## 全城一次规划要推堆十万次以上，光这里就能吃掉几百毫秒。改成两个
## 平行的 **类型化** 数组（PackedInt32Array / PackedFloat64Array）后索引是
## 直接内存访问。容量按 2 倍扩容，避免每次 push 都 resize。
class _MinHeap extends RefCounted:
	var _id := PackedInt32Array()
	var _cost := PackedFloat64Array()
	var _n := 0

	func is_empty() -> bool:
		return _n == 0

	## ⚠️ 判断必须是 `_id.size() < cap`（容量**不够**才扩）。
	## 曾经写成 `>=`：第一次 push 时 size=0 >= 1 为假 → 不扩容 →
	## 往 size=0 的 Packed 数组里写下标 0 直接越界报错，Dijkstra 整个挂掉，
	## 表现为点任何目的地都提示"无法规划到该目的地的路线"。
	func _ensure(cap: int) -> void:
		if _id.size() < cap:
			var nc := maxi(64, cap * 2)
			_id.resize(nc)
			_cost.resize(nc)

	func push(id: int, cost: float) -> void:
		_ensure(_n + 1)
		var i := _n
		_n += 1
		_id[i] = id
		_cost[i] = cost
		while i > 0:
			var p := (i - 1) >> 1
			if _cost[p] <= _cost[i]:
				break
			var ti := _id[p]
			var tc := _cost[p]
			_id[p] = _id[i]
			_cost[p] = _cost[i]
			_id[i] = ti
			_cost[i] = tc
			i = p

	func pop() -> Array:
		var top_id: int = _id[0]
		var top_cost: float = _cost[0]
		_n -= 1
		if _n > 0:
			_id[0] = _id[_n]
			_cost[0] = _cost[_n]
			var i := 0
			while i * 2 + 1 < _n:
				var c := i * 2 + 1
				if c + 1 < _n and _cost[c + 1] < _cost[c]:
					c += 1
				if _cost[c] >= _cost[i]:
					break
				var ti := _id[i]
				var tc := _cost[i]
				_id[i] = _id[c]
				_cost[i] = _cost[c]
				_id[c] = ti
				_cost[c] = tc
				i = c
		return [top_id, top_cost]
