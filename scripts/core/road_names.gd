extends RefCounted
##
## 未命名道路命名 —— 逐行移植原版 src/city-road-names.ts。
##
## 数据里的道路有一半以上名字就是「支路」/「道路」这类占位符（本城 12202 条里
## 7354 条），原版在**数据加载完成后立刻**跑一遍命名，给它们拼出四段式显示名：
##
##   1. 匝道：`XX大道—YY路 · 连接匝道`（取两端 2m 内相接的命名路）
##   2. 有邻路：`XX大道附近 · 支路`（中点 150m 内最近的命名同类道路）
##   3. 有片区：`南山 · 后海附近 · 街巷`（中点 400m / 郊区 900m 内的 district 点）
##   4. 兜底：`城市东南侧 · 支路`（按中点相对地图范围的四象限）
##
## HUD 的路名、大地图的标注、自动驾驶的目的地提示都吃 `display_name`，
## 所以在 CityData.load_core() 里 _build_roads 之后立即执行。
##
## ⚠️ 与原版的唯一结构性差别：原版用 `Map<string, Segment[]>` + 对象引用，
## 这里用 `Dictionary[Vector2i] -> Array` 承载同样的 160m 网格索引，并额外加了
## 两级 AABB 剪枝（cell 矩形 + 段 AABB）。原因是 GDScript 里 hypot 的开销远高于
## V8，7354 条未命名路 × 每条约 2.5 次邻域查询如果全量扫会拖慢启动。

## 原版 `const size = 160`
const CELL := 160.0
## 原版 `limit` 常量
const LINK_LIMIT := 2.0
const ADJACENT_LIMIT := 150.0
const CONTEXT_LIMIT := 400.0
const CONTEXT_SUBURB_LIMIT := 900.0

## 未命名路判据（原 city-road-names.ts 的 `generic`）。
## 直接复用 GameContent 上的常量，避免两处副本漂移。
## ⚠️ 用 preload 取而不是 `GameContent.UNNAMED_ROAD_PATTERN`：本文件的函数都是
## static，静态上下文里引用 autoload 单例有解析风险，preload 的 const 是编译期的。
const GC := preload("res://scripts/core/game_content.gd")


## 给所有道路补齐 display_name。就地修改传入的 road 字典（Array 里存的是引用）。
## 返回 {total, contextual, segments}。
static func assign_display_names(roads: Array, places: Array, extent: Rect2) -> Dictionary:
	var generic := RegEx.new()
	# 原版 `generic` 带 /i；Godot 的 RegEx 用内联 (?i) 表达。
	generic.compile("(?i)" + GC.UNNAMED_ROAD_PATTERN)

	# ---- 1. 建索引：只放**已命名**的路段 -------------------------------
	var cells := {}
	var seg_total := 0
	for road in roads:
		var r: Dictionary = road
		if _is_unnamed(generic, str(r.get("name", ""))):
			continue
		var pts: PackedVector2Array = r["points"]
		for i in range(1, pts.size()):
			var a := pts[i - 1]
			var b := pts[i]
			var seg := {"a": a, "b": b, "road": r}
			seg_total += 1
			var x0 := int(floor(minf(a.x, b.x) / CELL))
			var x1 := int(floor(maxf(a.x, b.x) / CELL))
			var z0 := int(floor(minf(a.y, b.y) / CELL))
			var z1 := int(floor(maxf(a.y, b.y) / CELL))
			for x in range(x0, x1 + 1):
				for z in range(z0, z1 + 1):
					var key := Vector2i(x, z)
					if not cells.has(key):
						cells[key] = []
					(cells[key] as Array).append(seg)

	# ---- 2. 片区上下文点 ------------------------------------------------
	# 原版只取 category === 'district' 且 kind !== 'city' 的点。
	var contexts: Array = []
	for p in places:
		if not (p is Dictionary):
			continue
		var pl: Dictionary = p
		if str(pl.get("category", "")) != "district":
			continue
		if str(pl.get("kind", "")) == "city":
			continue
		var px := float(pl.get("x", NAN))
		var pz := float(pl.get("z", NAN))
		if not (is_finite(px) and is_finite(pz)):
			continue
		contexts.append({"name": str(pl.get("name", "")), "x": px, "z": pz,
			"kind": str(pl.get("kind", ""))})

	var xmin := extent.position.x
	var zmin := extent.position.y
	var xmax := extent.end.x
	var zmax := extent.end.y
	var cx_mid := (xmin + xmax) * 0.5
	var cz_mid := (zmin + zmax) * 0.5

	# ---- 3. 逐条命名 ----------------------------------------------------
	var contextual := 0
	for road in roads:
		var r: Dictionary = road
		if not _is_unnamed(generic, str(r.get("name", ""))):
			r["display_name"] = str(r.get("name", ""))
			continue
		contextual += 1
		var kind := str(r.get("kind", "unclassified"))
		var pts2: PackedVector2Array = r["points"]
		# 显式标 Vector2：三元里一边是容器取值，`:=` 有推断不出来的风险
		var mid: Vector2 = pts2[pts2.size() / 2] if pts2.size() > 0 else Vector2.ZERO
		r["display_name"] = _compose(cells, r, kind, mid, contexts, cx_mid, cz_mid)

	return {"total": roads.size(), "contextual": contextual, "segments": seg_total}


## 原版 `road.kind.endsWith('_link') ? '连接匝道' : ... : '支路'`
static func _kind_label(kind: String) -> String:
	if kind.ends_with("_link"):
		return "连接匝道"
	match kind:
		"service": return "内部道路"
		"residential": return "街巷"
		_: return "支路"


static func _compose(cells: Dictionary, road: Dictionary, kind: String, mid: Vector2,
		contexts: Array, cx_mid: float, cz_mid: float) -> String:
	var label := _kind_label(kind)

	# (1) 匝道：两端各取 2m 内相接的命名路
	if kind.ends_with("_link"):
		var pts: PackedVector2Array = road["points"]
		if pts.size() > 0:
			var names: Array = []
			for endpoint in [pts[0], pts[pts.size() - 1]]:
				var hit := _near(cells, endpoint, str(road.get("grade", "")), LINK_LIMIT)
				if hit.is_empty():
					continue
				var nm := str(hit.get("name", ""))
				if nm != "" and not names.has(nm):
					names.append(nm)
			if not names.is_empty():
				return "—".join(PackedStringArray(names)) + " · " + label

	# (2) 邻路
	var adjacent := _near(cells, mid, str(road.get("grade", "")), ADJACENT_LIMIT)
	if not adjacent.is_empty():
		return str(adjacent.get("name", "")) + "附近 · " + label

	# (3) 片区
	var best_name := ""
	var best_d := INF
	for c in contexts:
		var d: float = Vector2(float(c["x"]) - mid.x, float(c["z"]) - mid.y).length()
		var limit: float = CONTEXT_SUBURB_LIMIT if str(c["kind"]) == "suburb" else CONTEXT_LIMIT
		if d < best_d and d < limit:
			best_d = d
			best_name = str(c["name"])
	if best_name != "":
		return best_name + "附近 · " + label

	# (4) 兜底：相对地图中心的方位
	var east := mid.x > cx_mid
	var north := mid.y > cz_mid
	return "城市" + ("东" if east else "西") + ("北" if north else "南") + "侧 · " + label


## 原版 `near(point, road, limit)`：在 3×3 邻域里找**同 grade** 的最近命名路段。
##
## 两级剪枝与原版行为等价（只是少了无谓的 hypot）：
##   a. cell 矩形到 point 的最近距离 > limit → 整个 cell 跳过；
##   b. 段 AABB 到 point 的最近距离 > limit → 该段跳过。
static func _near(cells: Dictionary, point: Vector2, grade: String, limit: float) -> Dictionary:
	var best := {}
	var best_d := INF
	var limit2 := limit * limit
	var cx := int(floor(point.x / CELL))
	var cz := int(floor(point.y / CELL))
	for x in range(cx - 1, cx + 2):
		for z in range(cz - 1, cz + 2):
			var cmin_x := float(x) * CELL
			var cmin_z := float(z) * CELL
			var cdx := maxf(0.0, maxf(cmin_x - point.x, point.x - (cmin_x + CELL)))
			var cdz := maxf(0.0, maxf(cmin_z - point.y, point.y - (cmin_z + CELL)))
			if cdx * cdx + cdz * cdz > limit2:
				continue
			var list = cells.get(Vector2i(x, z))
			if list == null:
				continue
			for s in list:
				var sr: Dictionary = s["road"]
				# 原版用 `s.road.grade !== road.grade` 严格比较；ported 里 grade 是字符串
				if str(sr.get("grade", "")) != grade:
					continue
				var a: Vector2 = s["a"]
				var b: Vector2 = s["b"]
				var ex := maxf(0.0, maxf(minf(a.x, b.x) - point.x, point.x - maxf(a.x, b.x)))
				var ey := maxf(0.0, maxf(minf(a.y, b.y) - point.y, point.y - maxf(a.y, b.y)))
				if ex * ex + ey * ey > limit2:
					continue
				var d := _segment_distance(point, a, b)
				if d > limit:
					continue
				if best.is_empty():
					best = sr
					best_d = d
					continue
				if d < best_d or (d == best_d and str(sr.get("id", "")) < str(best.get("id", ""))):
					best = sr
					best_d = d
	return best


## 点到线段的距离（原版 driving.ts 的 `closest(...).d`）
static func _segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 <= 0.0:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


static func _is_unnamed(re: RegEx, name: String) -> bool:
	return re.search(name.strip_edges()) != null


## 原版 `roadVicinityName`：未命名路直接用它的显示名，命名路加"附近"。
## 观察模式的落点命名（observer-destination）要用。
static func vicinity_name(road: Dictionary) -> String:
	var named := str(road.get("display_name", ""))
	if named == "":
		named = str(road.get("name", ""))
	var nm := str(road.get("name", "")).strip_edges()
	var generic := RegEx.new()
	generic.compile("(?i)" + GC.UNNAMED_ROAD_PATTERN)
	if _is_unnamed(generic, nm):
		return named if named != "" else "深圳街区 · 支路"
	return (nm if nm != "" else named) + "附近"
