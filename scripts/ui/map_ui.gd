extends CanvasLayer
class_name MapUI
##
## 小地图与大地图 —— 对应原版 src/city-map.ts + city-map-geometry.ts + city-map-view.ts
## + city-road-names.ts。
##
## 坐标映射（逐字照搬 city-map-geometry.ts）：
##   wgs84ToMap(lon, lat) = [(lon − 114.025) × 102850 × 0.6,
##                           (lat − 22.536 ) × 111320 × 0.6]
##   mapToScreen = [(x − view.x) × scale + W/2,  H/2 − (z − view.z) × scale]
##   screenToMap 为上式的逆；zoomMapAt 保持指针下的点不动
## 实现上把 scale 形参命名为 map_scale —— CanvasLayer 自带 scale 属性，
## 用同名局部变量/形参会触发 SHADOWED_VARIABLE_BASE_CLASS 告警。
## 小地图：世界瓦片 512m → 256px（MAP_SCALE .38），随车速做透视压扁
##   tilt = 0.40 + min(1, |v|/28) × 0.25，观察模式 0.12
## 大地图：缩放钳制在 baseScale × 0.8 ~ 18；边界按 meta.extent 外扩 20%；
##   建筑只在 zoom > 3.6 时绘制。

const TILE_WORLD := 512.0
const TILE_PX := 256.0
const MINIMAP_SCALE := 0.38
const MAX_TILE_CACHE := 96

var world: CityWorld
var player = null

var minimap: Control
var minimap_holder: Control
var big_map: Control
var big_map_visible := false

var big_scale := 3.0
var big_view := Vector2.ZERO
var _dragging := false
var _drag_last := Vector2.ZERO

var _tilt := 0.40
## 包围盒缓存：小地图/大地图都要做"视野剔除"，
## 每帧现算 12202 条道路的包围盒得不偿失，所以只在首次绘制时算一次。
var _bboxes_ready := false
var _road_boxes: Array = []   ## Rect2（数据坐标）
var _green_boxes: Array = []
var _water_boxes: Array = []
var _landmark_boxes: Array = []
var _building_boxes: Array = []


func setup(p_world: CityWorld, p_player) -> void:
	world = p_world
	player = p_player
	layer = 8
	_build()


func _build() -> void:
	# 小地图需要裁剪：道路/水面等多边形顶点在方框外，不裁剪会画到方框外面。
	# 注意 clip_contents 只裁剪**子控件**的绘制、不裁控件自己的 _draw，
	# 所以结构必须是：holder（裁剪）→ minimap（实际绘制）。
	minimap_holder = Control.new()
	minimap_holder.name = "minimap-clip"
	minimap_holder.set_anchors_preset(Control.PRESET_TOP_LEFT)
	minimap_holder.position = Vector2(28, 96)
	minimap_holder.size = Vector2(320, 320)
	minimap_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	minimap_holder.clip_contents = true
	add_child(minimap_holder)

	minimap = Control.new()
	minimap.name = "minimap"
	minimap.set_anchors_preset(Control.PRESET_FULL_RECT)
	minimap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	minimap.draw.connect(_draw_minimap)
	minimap_holder.add_child(minimap)

	big_map = Control.new()
	big_map.name = "map-panel"
	big_map.set_anchors_preset(Control.PRESET_FULL_RECT)
	big_map.mouse_filter = Control.MOUSE_FILTER_STOP
	big_map.visible = false
	big_map.draw.connect(_draw_big_map)
	big_map.gui_input.connect(_on_map_input)
	add_child(big_map)


func _font(size: int) -> Font:
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["Microsoft YaHei", "微软雅黑", "SimHei",
		"PingFang SC", "Noto Sans CJK SC", "sans-serif"])
	sf.allow_system_fallback = true
	# SystemFont 没有 font_size 属性（那是 Label 的主题字号），删掉
	# 由 add_theme_font_size_override / Label3D.font_size 控制
	return sf


# ---------------------------------------------------------------------------
# 坐标映射
# ---------------------------------------------------------------------------

## 数据坐标 → 屏幕像素（view 为地图中心的数据坐标）
func map_to_screen(p: Vector2, view: Vector2, map_scale: float, size: Vector2) -> Vector2:
	return Vector2((p.x - view.x) * map_scale + size.x * 0.5,
		size.y * 0.5 - (p.y - view.y) * map_scale)


func screen_to_map(s: Vector2, view: Vector2, map_scale: float, size: Vector2) -> Vector2:
	return Vector2((s.x - size.x * 0.5) / map_scale + view.x,
		(view.y - (s.y - size.y * 0.5)) / map_scale)


## 保持指针下的地图点不动地缩放
func zoom_at(factor: float, screen_point: Vector2, size: Vector2) -> void:
	var before := screen_to_map(screen_point, big_view, big_scale, size)
	big_scale = clampf(big_scale * factor, base_scale() * 0.8, 18.0)
	var after := screen_to_map(screen_point, big_view, big_scale, size)
	big_view += before - after


func base_scale() -> float:
	# 让 extent 宽度大致铺满屏幕
	var w := CityData.extent.size.x * 1.2
	return maxf(0.02, 900.0 / maxf(w, 1.0))


static func _bbox_of(pts) -> Rect2:
	var out := Rect2()
	var first := true
	for p in pts:
		var v := Vector2(float(p[0]), float(p[1])) if (p is Array) else (p as Vector2)
		if first:
			out = Rect2(v, Vector2.ZERO)
			first = false
		else:
			out = out.expand(v)
	return out.grow(4.0)


func _compute_bboxes() -> void:
	if _bboxes_ready:
		return
	_bboxes_ready = true
	_road_boxes.clear()
	_green_boxes.clear()
	_water_boxes.clear()
	_landmark_boxes.clear()
	for r in CityData.roads:
		_road_boxes.append(_bbox_of(r["points"]))
	for g in CityData.green:
		var rings: Array = g.get("rings", [])
		_green_boxes.append(_bbox_of(rings[0]) if not rings.is_empty() else Rect2())
	for w in CityData.water:
		var wr: Array = w.get("rings", [])
		_water_boxes.append(_bbox_of(wr[0]) if not wr.is_empty() else Rect2())
	for lm in CityData.all_landmarks():
		var p := Vector2(float(lm.get("x", 0.0)), float(lm.get("z", 0.0)))
		_landmark_boxes.append(Rect2(p - Vector2(30, 30), Vector2(60, 60)))
	# 建筑只在大地图 zoom > 3.6 时绘制，但也得按视野剔除（16089 个）
	_building_boxes.clear()
	for b in CityData.buildings:
		var rings: Array = b["rings"]
		_building_boxes.append(_bbox_of(rings[0]) if not rings.is_empty() else Rect2())


# ---------------------------------------------------------------------------
# 小地图
# ---------------------------------------------------------------------------

func _draw_minimap() -> void:
	if world == null or player == null or not world.city_ready:
		return
	var size := minimap.size
	var pos: Vector2 = player.data_position()
	var speed := absf(float(player.speed()))

	# 透视压扁：观察模式最平，高速最扁
	var target_tilt := 0.40 + minf(1.0, speed / 28.0) * 0.25
	if player.is_observer():
		target_tilt = 0.12
	_tilt = lerpf(_tilt, target_tilt, 0.12)

	# 背景
	minimap.draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.05, 0.07, 0.88))
	var inner := Rect2(Vector2(6, 6), size - Vector2(12, 12))
	minimap.draw_rect(inner, Color(0.07, 0.10, 0.13, 0.95))

	# 裁剪到内框
	var view := pos
	var map_scale := MINIMAP_SCALE * 2.0
	_compute_bboxes()
	# 视野范围（数据坐标）：小地图只显示这么一小块，
	# 之外的道路/绿地/水面全部跳过 —— 这是小地图最大的开销来源
	var half := Vector2(size.x * 0.5 / map_scale, size.y * 0.5 / map_scale) + Vector2(80.0, 80.0)
	var view_rect := Rect2(pos - half, half * 2.0)

	# 水域
	for wi in CityData.water.size():
		if not (_water_boxes[wi] as Rect2).intersects(view_rect):
			continue
		var w: Dictionary = CityData.water[wi]
		var rings: Array = w.get("rings", [])
		if rings.is_empty():
			continue
		_fill_ring(rings[0], view, map_scale, size, Color(0.07, 0.15, 0.22, 0.95), _tilt)
	# 绿地
	for gi in CityData.green.size():
		if not (_green_boxes[gi] as Rect2).intersects(view_rect):
			continue
		var g: Dictionary = CityData.green[gi]
		var rings2: Array = g.get("rings", [])
		if rings2.is_empty():
			continue
		_fill_ring(rings2[0], view, map_scale, size, Color(0.11, 0.20, 0.13, 0.95), _tilt)
	# 道路
	for ri in CityData.roads.size():
		if not (_road_boxes[ri] as Rect2).intersects(view_rect):
			continue
		var r: Dictionary = CityData.roads[ri]
		var pts: PackedVector2Array = r["points"]
		if pts.size() < 2:
			continue
		var kind := str(r["kind"])
		var col := Color(0.55, 0.58, 0.62)
		var wdt := 1.0
		match kind:
			"motorway":
				col = Color(0.80, 0.72, 0.45)
				wdt = 3.0
			"trunk", "primary":
				col = Color(0.72, 0.68, 0.48)
				wdt = 2.4
			"secondary":
				col = Color(0.62, 0.62, 0.58)
				wdt = 1.8
			"tertiary":
				wdt = 1.4
			_:
				wdt = 0.9
		var screen := PackedVector2Array()
		for p in pts:
			var s := map_to_screen(p, view, map_scale, size)
			s.y = size.y * 0.5 + (s.y - size.y * 0.5) * _tilt
			if s.x > -60.0 and s.x < size.x + 60.0 and s.y > -60.0 and s.y < size.y + 60.0:
				screen.append(s)
		if screen.size() >= 2:
			minimap.draw_polyline(screen, col, wdt, true)

	# 路线（双层描边，原版做法）
	if player.has_route():
		var route: PackedVector2Array = player.route_points()
		var line := PackedVector2Array()
		for p in route:
			var s2 := map_to_screen(p, view, map_scale, size)
			s2.y = size.y * 0.5 + (s2.y - size.y * 0.5) * _tilt
			line.append(s2)
		if line.size() >= 2:
			minimap.draw_polyline(line, Color(0.10, 0.12, 0.14, 0.9), 6.0, true)
			minimap.draw_polyline(line, Color(0.95, 0.80, 0.35), 3.0, true)

	# 玩家箭头
	var c := size * 0.5
	var yaw: float = player.data_yaw()
	var dir := Vector2(sin(yaw), -cos(yaw))
	var perp := Vector2(-dir.y, dir.x)
	var tri := PackedVector2Array([
		c + dir * 11.0,
		c - dir * 7.0 + perp * 6.0,
		c - dir * 7.0 - perp * 6.0,
	])
	minimap.draw_colored_polygon(tri, Color(0.98, 0.90, 0.55))
	minimap.draw_polyline(PackedVector2Array([tri[0], tri[1], tri[2], tri[0]]),
		Color(0.15, 0.16, 0.18), 1.5, true)


func _fill_ring(ring: Array, view: Vector2, map_scale: float, size: Vector2, col: Color, tilt: float) -> void:
	if ring.size() < 3:
		return
	var poly := PackedVector2Array()
	for p in ring:
		var v := Vector2(float(p[0]), float(p[1]))
		var s := map_to_screen(v, view, map_scale, size)
		s.y = size.y * 0.5 + (s.y - size.y * 0.5) * tilt
		poly.append(s)
	minimap.draw_colored_polygon(poly, col)


# ---------------------------------------------------------------------------
# 大地图
# ---------------------------------------------------------------------------

func toggle_big_map() -> void:
	big_map_visible = not big_map_visible
	big_map.visible = big_map_visible
	if big_map_visible:
		big_view = player.data_position() if player != null else CityData.spawn_pos
		big_scale = maxf(base_scale(), 0.6)
		big_map.queue_redraw()


func _on_map_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			zoom_at(1.15, mb.position, big_map.size)
			big_map.queue_redraw()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			zoom_at(1.0 / 1.15, mb.position, big_map.size)
			big_map.queue_redraw()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			_drag_last = mb.position
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		var delta := mm.position - _drag_last
		_drag_last = mm.position
		big_view += Vector2(-delta.x / big_scale, delta.y / big_scale)
		big_map.queue_redraw()


func _draw_big_map() -> void:
	var size := big_map.size
	big_map.draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.03, 0.05, 0.92))

	# 海域底色：整个 extent
	var ext := CityData.extent
	var corners := PackedVector2Array([
		map_to_screen(ext.position, big_view, big_scale, size),
		map_to_screen(Vector2(ext.end.x, ext.position.y), big_view, big_scale, size),
		map_to_screen(ext.end, big_view, big_scale, size),
		map_to_screen(Vector2(ext.position.x, ext.end.y), big_view, big_scale, size),
	])
	big_map.draw_colored_polygon(corners, Color(0.05, 0.11, 0.16))

	# 陆地
	for ring in CityData.land_rings:
		_draw_ring_big(ring, Color(0.13, 0.14, 0.13))
	for g in CityData.green:
		for ring in g.get("rings", []):
			_draw_ring_big(ring, Color(0.13, 0.21, 0.14))
	for w in CityData.water:
		var rings: Array = w.get("rings", [])
		if not rings.is_empty():
			_draw_ring_big(rings[0], Color(0.06, 0.14, 0.20))

	# 建筑（仅 zoom > 3.6）—— 16089 个，必须按视野剔除
	_compute_bboxes()
	var view_box2 := Rect2(screen_to_map(size, big_view, big_scale, size),
		(screen_to_map(Vector2.ZERO, big_view, big_scale, size)
			- screen_to_map(size, big_view, big_scale, size)).abs())
	if big_scale > 3.6:
		for bi in CityData.buildings.size():
			if not (_building_boxes[bi] as Rect2).intersects(view_box2):
				continue
			var b: Dictionary = CityData.buildings[bi]
			var rings: Array = b["rings"]
			if rings.is_empty():
				continue
			var col := Color(0.20, 0.21, 0.22)
			if float(b["height"]) > 100.0:
				col = Color(0.30, 0.31, 0.33)
			_draw_ring_big(rings[0], col)

	# 道路
	_compute_bboxes()
	# 可见的地图范围（数据坐标），用于视野剔除 —— 否则每次重绘都要
	# 变换全部 12202 条道路的每个顶点，大地图一开就会卡
	var visible_rect := screen_to_map(Vector2.ZERO, big_view, big_scale, size)
	var visible_end := screen_to_map(size, big_view, big_scale, size)
	var view_box := Rect2(visible_end, visible_rect - visible_end).abs()
	for ri in CityData.roads.size():
		if not (_road_boxes[ri] as Rect2).intersects(view_box):
			continue
		var r: Dictionary = CityData.roads[ri]
		var pts: PackedVector2Array = r["points"]
		if pts.size() < 2:
			continue
		var kind := str(r["kind"])
		var prio: int = GameContent.ROAD_LABEL_PRIORITY.get(kind, 10)
		if big_scale < 1.6 and prio < 70:
			continue
		if big_scale < 3.0 and prio < 40:
			continue
		var col := Color(0.42, 0.44, 0.46)
		var wdt := maxf(0.6, float(r["width"]) * big_scale * 0.5)
		if prio >= 80:
			col = Color(0.78, 0.70, 0.44)
		elif prio >= 70:
			col = Color(0.68, 0.64, 0.46)
		var line := PackedVector2Array()
		for p in pts:
			line.append(map_to_screen(p, big_view, big_scale, size))
		if line.size() >= 2:
			big_map.draw_polyline(line, col, wdt, true)

	# 地标标注（zoom 门限 ≥ 1.1）
	if big_scale >= 1.1:
		var font := _font(16)
		for lm in CityData.all_landmarks():
			var p := Vector2(float(lm.get("x", 0.0)), float(lm.get("z", 0.0)))
			var s := map_to_screen(p, big_view, big_scale, size)
			if s.x < 0.0 or s.y < 0.0 or s.x > size.x or s.y > size.y:
				continue
			big_map.draw_circle(s, 4.0, Color(0.95, 0.82, 0.45))
			big_map.draw_string(font, s + Vector2(8, 5), str(lm.get("name", "")),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.96, 0.94, 0.88))

	# 玩家
	if player != null:
		var ps := map_to_screen(player.data_position(), big_view, big_scale, size)
		big_map.draw_circle(ps, 6.0, Color(0.98, 0.35, 0.25))
		big_map.draw_arc(ps, 9.0, 0.0, TAU, 24, Color(0.98, 0.90, 0.60), 2.0, true)

	# 比例尺
	var scale_len := 100.0
	if big_scale > 0.0:
		scale_len = 100.0 / big_scale
	var font2 := _font(14)
	big_map.draw_line(Vector2(40, size.y - 40), Vector2(40 + scale_len * big_scale, size.y - 40),
		Color(0.90, 0.92, 0.94), 2.0, true)
	big_map.draw_string(font2, Vector2(40, size.y - 50), "%.0f m" % (scale_len * big_scale),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.90, 0.92, 0.94))
	big_map.draw_string(font2, Vector2(40, size.y - 20),
		"M 关闭地图 · 滚轮缩放 · 左键拖动 · 缩放 %.2f" % big_scale,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.80, 0.85, 0.90))


func _draw_ring_big(ring: Array, col: Color) -> void:
	if ring.size() < 3:
		return
	var poly := PackedVector2Array()
	for p in ring:
		poly.append(map_to_screen(Vector2(float(p[0]), float(p[1])), big_view, big_scale, big_map.size))
	big_map.draw_colored_polygon(poly, col)


## 小地图重绘节流。
##
## `_draw_minimap` 每次要遍历全部 12202 条道路的每个顶点做坐标变换，
## 60fps 下就是每秒数百万次运算 —— 必须节流，否则真机上画面直接卡死。
const REDRAW_INTERVAL := 0.2
var _redraw_timer := 0.0


func update_ui(delta: float) -> void:
	_redraw_timer -= delta
	if _redraw_timer > 0.0:
		return
	_redraw_timer = REDRAW_INTERVAL
	minimap.queue_redraw()
	if big_map_visible:
		big_map.queue_redraw()
