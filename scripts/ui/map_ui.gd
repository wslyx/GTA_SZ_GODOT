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

## 大地图上点选地标命中半径（像素）
const PICK_RADIUS := 26.0
## 按下-松开位移小于该值视为"点击"而不是拖动
const CLICK_SLOP := 6.0
## 没点中地标时，把点击处吸附到最近道路的最大距离（米）
const SNAP_RADIUS := 90.0

## 点选了目的地（大地图左键点地标/任意路面）→ main_game 接管并启动自动驾驶
signal destination_picked(pos: Vector2, dest_name: String)
## 点选失败（点到了海面/山体等无路可达处）——给玩家一句明确反馈，
## 否则点击毫无反应，看起来就像功能坏了。
signal pick_failed(reason: String)
## 路线规划好后，玩家在大地图上点按钮选驾驶方式（原版
## city-map.ts 的 `#auto-drive` / `#drive-route` 两个按钮）。
## auto = true 自动驾驶前往，false 自己开过去。
signal route_mode_chosen(auto: bool)

var world: CityWorld
var player = null

var minimap: Control
var minimap_holder: Control
var big_map: Control
var big_map_visible := false
## 驾驶方式选择按钮（原版 .atlas-route-actions 里的两个按钮）
var _choice_panel: Control
var _btn_auto: Button
var _btn_manual: Button
var _choice_visible := false
var _choice_name := ""

var big_scale := 3.0
var big_view := Vector2.ZERO
var _dragging := false
var _drag_last := Vector2.ZERO
## 点选目的地：按下位置与是否已拖动（区分点击与拖图）
var _press_pos := Vector2.ZERO
var _press_dragged := false
## 当前选中的目的地（供绘制标记）
var _dest := {}

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

	_build_route_choice()


## 原版 city-map.ts:93 —— 选好地点后地图面板底部出现两个按钮：
##   「自动驾驶前往 ↗」→ onAutoDrive
##   「自己开过去 →」  → onManualRoute
## 两个回调都会先 selectDestination 再 openMap(false)，也就是**按钮在地图里点，
## 点了才关地图**。这里照搬：按钮是 big_map 的子控件，点完由 main_game 关地图。
func _build_route_choice() -> void:
	_choice_panel = Control.new()
	_choice_panel.name = "route-actions"
	_choice_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	# -108 而不是更靠上：HUD 的 toast 在底部 -150 一带，别和它叠在一起
	_choice_panel.position = Vector2(-232, -108)
	_choice_panel.size = Vector2(464, 54)
	_choice_panel.visible = false
	big_map.add_child(_choice_panel)

	_btn_auto = _mk_choice_button("自动驾驶前往 ↗", Vector2(0, 0))
	_btn_auto.pressed.connect(func(): _on_choice_pressed(true))
	_btn_manual = _mk_choice_button("自己开过去 →", Vector2(240, 0))
	_btn_manual.pressed.connect(func(): _on_choice_pressed(false))


func _mk_choice_button(text: String, pos: Vector2) -> Button:
	var b := Button.new()
	b.text = text
	b.size = Vector2(224, 54)
	b.position = pos
	# ⚠️ 不能让按钮拿到焦点：点完地图关闭后，焦点若还留在按钮上，
	# 开车时按空格（手刹）/ 回车会被当成"再点一次按钮"。
	b.focus_mode = Control.FOCUS_NONE
	# 默认字体不含中文，必须显式指定（与 Label 用同一套字体）
	b.add_theme_font_override("font", _font(20))
	b.add_theme_font_size_override("font_size", 20)
	_choice_panel.add_child(b)
	return b


func _on_choice_pressed(auto: bool) -> void:
	hide_route_choice()
	route_mode_chosen.emit(auto)


## 规划成功 → 显示两个按钮（地图保持打开，等玩家点）
func show_route_choice(dest_name: String) -> void:
	_choice_visible = true
	_choice_name = dest_name
	if _choice_panel != null:
		_choice_panel.visible = true
	big_map.queue_redraw()


func hide_route_choice() -> void:
	_choice_visible = false
	_choice_name = ""
	if _choice_panel != null:
		_choice_panel.visible = false


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


## 上式的逆变换。
##
## ⚠️ 曾经写成 `(view.y - (s.y - size.y * 0.5)) / map_scale` —— 括号把 view.y
## 也套进了除法。屏幕 y 轴向下、数据 y 轴向北，二者是
##   py = view.y - (sy - H/2) / k        （view.y **不**参与除法）
## 而错误写法给出 (view.y - sy + H/2)/k。只有当 view.y == 0（地图中心恰在
## 数据原点）时才碰巧等价，实测在出生点附近误差就有数百米、远离原点可达
## 上万米：滚轮缩放的锚点会整屏飞走，用它算出的视野矩形也整个错位。
func screen_to_map(s: Vector2, view: Vector2, map_scale: float, size: Vector2) -> Vector2:
	return Vector2(view.x + (s.x - size.x * 0.5) / map_scale,
		view.y - (s.y - size.y * 0.5) / map_scale)


## 当前视野对应的数据坐标矩形（用于剔除）。
##
## ⚠️ 不能写 `Rect2(br, (tl - br).abs())`：Rect2 的 position 是**左上角**
## （x 最小、y 最小），而右下角 br 的 x 是最大的 —— 那样整个矩形会向右
## 平移整整一个屏宽，导致视野内的道路/建筑 100% 被剔除（实测）。
## 用 `Rect2(tl).expand(br)` 由两点直接取包围盒最稳妥。
func view_rect(size: Vector2) -> Rect2:
	var tl := screen_to_map(Vector2.ZERO, big_view, big_scale, size)
	var br := screen_to_map(size, big_view, big_scale, size)
	return Rect2(tl, Vector2.ZERO).expand(br)


## 保持指针下的地图点不动地缩放
func zoom_at(factor: float, screen_point: Vector2, size: Vector2) -> void:
	var before := screen_to_map(screen_point, big_view, big_scale, size)
	big_scale = clampf(big_scale * factor, base_scale() * 0.8, 18.0)
	var after := screen_to_map(screen_point, big_view, big_scale, size)
	big_view += before - after


## 让 extent 宽度大致铺满屏幕的缩放。按**实际窗口宽度**算，
## 不能写死 900 —— 在 1920/2560 宽的窗口上会缩得过小，看不出全城轮廓。
func base_scale() -> float:
	var vw := 900.0 if big_map == null else maxf(big_map.size.x, 240.0)
	var w := CityData.extent.size.x * 1.2
	return maxf(0.02, vw / maxf(w, 1.0))


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

	# 路线（双层描边，原版做法）。
	# 颜色与大地图一致用**浅绿** —— 原版「自己开过去」的提示语就是
	# "沿小地图上的浅绿路线行驶"（main.ts onManualRoute）。
	if player.has_route():
		var route: PackedVector2Array = player.route_points()
		var line := PackedVector2Array()
		for p in route:
			var s2 := map_to_screen(p, view, map_scale, size)
			s2.y = size.y * 0.5 + (s2.y - size.y * 0.5) * _tilt
			line.append(s2)
		if line.size() >= 2:
			minimap.draw_polyline(line, Color(0.10, 0.12, 0.14, 0.9), 6.0, true)
			minimap.draw_polyline(line, Color(0.55, 0.95, 0.60), 3.0, true)

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

## 打开时默认**铺满全城**（base_scale），而不是固定 0.6。
## 0.6 只显示约 2 km 宽 —— 城市有 13.5 km 宽，玩家打开地图看到的只是
## 出生点周围一角，既看不到路网全貌也找不到地标，点选目的地无从下手。
func toggle_big_map() -> void:
	big_map_visible = not big_map_visible
	big_map.visible = big_map_visible
	if big_map_visible:
		big_view = player.data_position() if player != null else CityData.spawn_pos
		big_scale = base_scale()
		# 已经选好目的地但还没选驾驶方式时，重开地图要把两个按钮带回来
		if _choice_panel != null:
			_choice_panel.visible = _choice_visible
		big_map.queue_redraw()
	elif _choice_panel != null:
		# 关地图只是收起按钮，目的地本身仍然有效（原版 selected 也保留）
		_choice_panel.visible = false


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
			if mb.pressed:
				_press_pos = mb.position
				_press_dragged = false
			elif not _press_dragged and _press_pos.distance_to(mb.position) < CLICK_SLOP:
				# 原版交互：大地图上点选地标 → 自动驾驶前往（city-map.ts onAutoDrive）
				_pick_destination(mb.position)
			_drag_last = mb.position
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		if mm.position.distance_to(_press_pos) > CLICK_SLOP:
			_press_dragged = true
		var delta := mm.position - _drag_last
		_drag_last = mm.position
		big_view += Vector2(-delta.x / big_scale, delta.y / big_scale)
		big_map.queue_redraw()


## 在屏幕坐标附近找最近的地标；命中则记录目的地并广播。
##
## 路线目标必须用地标的 **arrival**（道路上的到达点）——地标的 x/z 是
## 建筑中心，10/44 个落在街区/园区内部的孤立路网岛上，用它规划路线
## 会静默失败（no-route）。原版 city-map.ts 的目的地同样是 arrival。
##
## 没命中地标时不再直接放弃（那样玩家点了地图却毫无反应，会以为功能坏了）：
## 退化为「把点击处吸附到最近道路」，任意位置都能当作目的地。
func _pick_destination(s: Vector2) -> void:
	var best_pos := Vector2.ZERO
	var best_name := ""
	var best_d := PICK_RADIUS
	for lm in CityData.all_landmarks():
		var p := Vector2(float(lm.get("x", 0.0)), float(lm.get("z", 0.0)))
		var sp := map_to_screen(p, big_view, big_scale, big_map.size)
		var d := sp.distance_to(s)
		if d < best_d:
			best_d = d
			var arr = lm.get("arrival", null)
			if arr is Array and (arr as Array).size() >= 2:
				best_pos = Vector2(float(arr[0]), float(arr[1]))
			else:
				best_pos = p
			best_name = str(lm.get("name", ""))
	if best_name != "":
		_emit_destination(best_pos, best_name)
		return

	var snapped := _snap_to_road(s)
	if snapped.is_empty():
		pick_failed.emit("这里没有可到达的道路，换个地点试试")
		return
	_emit_destination(Vector2(snapped["pos"]), str(snapped["name"]))


## 点击处的地图坐标 → 最近道路上的可停放点（原版 mapPointDestination）。
##
## ⚠️ 必须用 `world.graph.nearest_edge`（对应原版 `MapRoadIndex.nearest`，
## 会一圈圈向外扩散搜索再兜底全扫），**不能**用 `world.collision.nearest`：
## 后者是碰撞判定用的，只在点所在的**单个 90m 格子**里找、不向外扩散，
## 点在格子外就直接返回空字典，等于大部分点击都吸附不上。
## 距离超过 SNAP_RADIUS 就认为点在山体/海面/远处，不作为目的地。
func _snap_to_road(s: Vector2) -> Dictionary:
	if world == null or world.graph == null or world.graph.nodes.is_empty():
		return {}
	var m := screen_to_map(s, big_view, big_scale, big_map.size)
	var near: Dictionary = world.graph.nearest_edge(m)
	if near.is_empty():
		return {}
	var pt: Vector2 = near["point"]
	if m.distance_to(pt) > SNAP_RADIUS:
		return {}
	var nm := "地图选点"
	if world.collision != null:
		var cn: Dictionary = world.collision.nearest(pt.x, pt.y)
		if not cn.is_empty():
			var road: Dictionary = cn.get("road", {})
			var rn := str(road.get("display_name", road.get("name", "")))
			if rn != "":
				nm = rn
	return {"pos": pt, "name": nm}


func _emit_destination(pos: Vector2, dest_name: String) -> void:
	_dest = {"pos": pos, "name": dest_name}
	# 按钮先收起来：要等 main_game 规划成功（show_route_choice）后再出现，
	# 否则会短暂显示一个"规划失败"的目的地也能点的状态
	hide_route_choice()
	big_map.queue_redraw()
	destination_picked.emit(pos, dest_name)


## 自动驾驶取消 / 结束时清除目的地标记与选择按钮
func clear_destination() -> void:
	if not _dest.is_empty():
		_dest = {}
		big_map.queue_redraw()
	hide_route_choice()


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

	# 可见的地图范围（数据坐标），用于视野剔除 —— 否则每次重绘都要
	# 变换全部 12202 条道路 / 16089 个建筑的每个顶点，大地图一开就会卡
	_compute_bboxes()
	var view_box := view_rect(size)

	# 建筑（仅 zoom > 3.6）—— 16089 个，必须按视野剔除
	if big_scale > 3.6:
		for bi in CityData.buildings.size():
			if not (_building_boxes[bi] as Rect2).intersects(view_box):
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

	# 地标：圆点**始终**绘制（只有几十个，开销可忽略，也是点选目的地的靶心）；
	# 名称只在 zoom ≥ 1.1 时画，否则全城视图下几十个中文标签会糊成一片。
	var font := _font(16)
	for lm in CityData.all_landmarks():
		var p := Vector2(float(lm.get("x", 0.0)), float(lm.get("z", 0.0)))
		var s := map_to_screen(p, big_view, big_scale, size)
		if s.x < 0.0 or s.y < 0.0 or s.x > size.x or s.y > size.y:
			continue
		big_map.draw_circle(s, 4.0, Color(0.95, 0.82, 0.45))
		if big_scale >= 1.1:
			big_map.draw_string(font, s + Vector2(8, 5), str(lm.get("name", "")),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.96, 0.94, 0.88))

	# 自动驾驶路线（浅绿，双层描边；原版 onAutoDrive 后大地图同样绘制）
	if player != null and player.has_route():
		var route: PackedVector2Array = player.route_points()
		if route.size() >= 2:
			var rline := PackedVector2Array()
			for p in route:
				rline.append(map_to_screen(p, big_view, big_scale, size))
			big_map.draw_polyline(rline, Color(0.10, 0.12, 0.14, 0.85), 6.0, true)
			big_map.draw_polyline(rline, Color(0.55, 0.95, 0.60), 3.0, true)

	# 目的地标记（金色圆点 + 名字）
	if not _dest.is_empty():
		var dpos: Vector2 = _dest["pos"]
		var ds := map_to_screen(dpos, big_view, big_scale, size)
		big_map.draw_circle(ds, 7.0, Color(0.98, 0.80, 0.35))
		big_map.draw_arc(ds, 12.0, 0.0, TAU, 28, Color(0.98, 0.80, 0.35), 2.0, true)
		big_map.draw_string(_font(15), ds + Vector2(14, 5), str(_dest.get("name", "")),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.98, 0.90, 0.70))

	# 玩家
	if player != null:
		var ps := map_to_screen(player.data_position(), big_view, big_scale, size)
		big_map.draw_circle(ps, 6.0, Color(0.98, 0.35, 0.25))
		big_map.draw_arc(ps, 9.0, 0.0, TAU, 24, Color(0.98, 0.90, 0.60), 2.0, true)

	# 待选驾驶方式：按钮上方给出路线概览（原版 #destination-status：
	# "沿道路约 3.2 公里 · 抵达目的地周边" / "目的地就在附近"）
	if _choice_visible and _choice_name != "" and player != null and player.has_route():
		var route: PackedVector2Array = player.route_points()
		var length := 0.0
		for i in range(1, route.size()):
			length += route[i].distance_to(route[i - 1])
		var info := "已规划到 %s" % _choice_name
		if length >= 45.0:
			info += " · 沿道路约 %.1f 公里 · 抵达目的地周边" % (length / 1000.0)
		else:
			info += " · 目的地就在附近"
		var info_font := _font(18)
		var w := info_font.get_string_size(info, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
		big_map.draw_string(info_font, Vector2(size.x * 0.5 - w * 0.5, size.y - 128), info,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.92, 0.88, 0.70))

	# 比例尺：固定画 100 像素长的横杠，标注它代表的**米数** = 100 / big_scale。
	# （旧写法把 scale_len 又乘回 big_scale，标签恒为 "100 m"，完全失真。）
	var bar_px := 100.0
	var bar_m := bar_px / maxf(big_scale, 0.0001)
	var font2 := _font(14)
	big_map.draw_line(Vector2(40, size.y - 40), Vector2(40 + bar_px, size.y - 40),
		Color(0.90, 0.92, 0.94), 2.0, true)
	big_map.draw_string(font2, Vector2(40, size.y - 50), _scale_label(bar_m),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.90, 0.92, 0.94))
	big_map.draw_string(font2, Vector2(40, size.y - 20),
		"M 关闭 · 滚轮缩放 · 拖动平移 · 点击地标或任意道路 = 规划路线 · 缩放 %.2f" % big_scale,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.80, 0.85, 0.90))


## 比例尺标签：≥1000m 用 km
static func _scale_label(meters: float) -> String:
	if meters >= 1000.0:
		return "%.1f km" % (meters / 1000.0)
	return "%.0f m" % meters


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
