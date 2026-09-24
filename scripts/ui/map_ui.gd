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

## —— 圆形小地图（原版 drawCinematicMinimap / getMapTile）——
## 逻辑输出 320 见方，source plane 1024 见方（原版 */
const MINIMAP_SHADER := "res://shaders/minimap.gdshader"
const MINIMAP_OUT := 320.0
const PLANE_PX := 1024
## 原版：source.setTransform(.75,0,0,.75,0,0)，即 768 画布承载 1024 空间
const PLANE_SCALE := 0.75
## 原版 plane 的投影原点：translate(512, 740)
const PLANE_ORIGIN := Vector2(512.0, 740.0)
## 原版 reach = 920 / MAP_SCALE
const MINIMAP_REACH := 920.0 / MINIMAP_SCALE
## 原版瓦片换算：TILE_PX / TILE_WORLD
const TILE_SCALE := TILE_PX / TILE_WORLD
## 玩家箭头在输出空间的锚点（原版 translate(160,208)）
const ARROW_ANCHOR := Vector2(160.0, 208.0)

## 原版 city-hud.ts 的 ROAD_ENGLISH（路名下方那行英文）
const ROAD_ENGLISH := {
	"滨海大道": "Binhai Blvd",
	"深南大道": "Shennan Blvd",
	"深南中路": "Shennan Middle Rd",
	"深南东路": "Shennan East Rd",
	"后海大道": "Houhai Blvd",
	"后海滨路": "Houhaibin Rd",
	"沙河西路": "Shahe West Rd",
	"南海大道": "Nanhai Blvd",
	"科苑南路": "Keyuan South Rd",
	"科苑路": "Keyuan Rd",
	"海德三道": "Haide 3rd Rd",
	"福华三路": "Fuhua 3rd Rd",
	"益田路": "Yitian Rd",
}

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
## 大地图开/关（true = 展开）。main_game 用它清掉相机拖拽状态：
## 开图那一刻若正按着右键拖视角，之后的松开事件会被地图吞掉，main_game
## 的 _dragging 就永远停在 true —— 关图后不按键也会转视角。
signal big_map_toggled(visible: bool)

var world: CityWorld
var player = null

var minimap: Control
var minimap_holder: Control
var minimap_overlay: Control
var _plane_viewport: SubViewport
var _plane_draw: Control
var _plane_mat: ShaderMaterial
var _road_label: Label
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

# --- 静态图层烘焙（小地图：水域 / 绿地 / 道路）-------------------------------
##
## **为什么必须烘**：水域 + 绿地 + 道路全是世界空间静态数据，但复刻版原先
## 每 0.2s 就用 CanvasItem 命令重画一遍可视部分 —— 实测单次重绘 ~100ms
## （2000+ 个多边形要在 CPU 上重新三角化、3000+ 条抗锯齿折线要重建几何）。
## 实机双轮对照（tools/_perf.gd，vsync 开、相机静止于出生点，各 120 帧）：
##
##   │ 轮次            │ 帧均值   │ >50ms 长帧 │ >16.7ms 帧 │
##   │ baseline        │ 17.97ms │     8      │     16     │
##   │ no-minimap      │ 10.40ms │     0      │      1     │
##   │ baseline2       │ 19.98ms │     9      │     20     │
##
## 也就是「40fps 左右」的观感**全部**来自这 100ms 周期卡顿（其余帧只要 10~14ms）。
##
## 原版本来就是缓存的：city-hud.ts 的 getMapTile() 把每块 512m 瓦片画一次进
## 256px 离屏 canvas（LRU 96 块），之后只 drawImage。这里按同一思路做成
## 「整城一张静态贴图 + 每次重绘一次 draw_texture」。
const BAKE_MARGIN := 64.0     ## 贴图四周外扩像素（防边角要素被裁）

var _map_tex: Texture2D = null
var _map_vp: SubViewport = null
var _map_painter: Control = null
## 贴图像素 (0,0) 对应的数据坐标：x = 最左，y = 最上（= 最大 z）
var _map_origin := Vector2.ZERO
var _map_size := Vector2i.ZERO
var _map_baked := false


func setup(p_world: CityWorld, p_player) -> void:
	world = p_world
	player = p_player
	# 层级：地图要**盖在 HUD 之上**。
	# 原版 city-map.css 给地图面板 z-index:12，而 city-hud.css 的 HUD 只有 2~6 ——
	# 地图一开就压住 HUD。移植版原先给 8（HUD 是 10），方向正好反了，于是
	# HUD 的速度表/里程条压在左下角比例尺上、底部 toast 压住路线信息行，
	# 两段文字叠在一起，看起来就是"乱码"。
	# 取 11：高于 HUD(10)，低于 PanelsUI(12)（手账/设置页/加载画面仍在其上）。
	layer = 11
	_build()
	# 静态图层烘焙：一次性把水域/绿地/道路画进贴图（约 100ms）。
	# 放在 setup 里 —— 此时主循环还在加载画面后面，玩家看不到这一下停顿。
	_bake_static_map()


func _build() -> void:
	# 预热字体缓存。⚠️ 必须赶在**第一次绘制之前**建好，原因见 _font() 的注释：
	# 当帧 new 出来的 SystemFont 当帧拿去 draw_string，画出来是一排实心方块。
	for s in FONT_SIZES:
		_font(s)

	# 圆形小地图（原版 #minimap：bottom 49px、left calc(--hud-edge − 10px)、
	# 直径 = 表盘 × 0.865、border-radius 50%）。位置与尺寸由 HUD 通过
	# set_minimap_rect() 下发，因为 --hud-edge / --hud-dial 都是 clamp(视口) 算出来的。
	#
	# Control 的 clip_contents 只能裁矩形，做不出 border-radius:50%，
	# 所以地图内容画进一个 SubViewport（= 原版的 source plane），
	# 再由 shaders/minimap.gdshader 做「透视压扁 + 圆形裁切 + 顶部雾霭」。
	minimap_holder = Control.new()
	minimap_holder.name = "minimap"
	minimap_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(minimap_holder)

	_plane_viewport = SubViewport.new()
	_plane_viewport.size = Vector2i(PLANE_PX, PLANE_PX)
	_plane_viewport.transparent_bg = true
	_plane_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_plane_viewport.disable_3d = true
	minimap_holder.add_child(_plane_viewport)

	_plane_draw = Control.new()
	_plane_draw.name = "minimap-plane"
	_plane_draw.size = Vector2(PLANE_PX, PLANE_PX)
	_plane_draw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_plane_draw.draw.connect(_draw_minimap_plane)
	_plane_viewport.add_child(_plane_draw)

	minimap = TextureRect.new()
	minimap.name = "minimap-display"
	minimap.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	minimap.stretch_mode = TextureRect.STRETCH_SCALE
	minimap.texture = _plane_viewport.get_texture()
	minimap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_plane_mat = ShaderMaterial.new()
	if ResourceLoader.exists(MINIMAP_SHADER):
		_plane_mat.shader = load(MINIMAP_SHADER)
	else:
		push_warning("[MapUI] 缺少着色器 %s" % MINIMAP_SHADER)
	minimap.material = _plane_mat
	minimap_holder.add_child(minimap)

	minimap_overlay = Control.new()
	minimap_overlay.name = "minimap-overlay"
	minimap_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	minimap_overlay.draw.connect(_draw_minimap_overlay)
	minimap_holder.add_child(minimap_overlay)

	# .cinematic-road-label：top calc(100% + 12px)、居中、路名 + 分隔线 + 英文
	_road_label = Label.new()
	_road_label.add_theme_font_override("font", _font(12))
	_road_label.add_theme_font_size_override("font_size", 13)
	_road_label.add_theme_color_override("font_color", Color(0.949, 0.953, 0.925, 0.83))
	_road_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_road_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.26))
	_road_label.add_theme_constant_override("shadow_offset_y", 1)
	_road_label.add_theme_constant_override("shadow_outline_size", 3)
	_road_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	minimap_holder.add_child(_road_label)

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


## 字号 → 字体缓存。
##
## ⚠️ 必须缓存，而且必须在**真正拿它画之前至少一帧**就建好。
##
## 实测（Godot 4.7.1，最小工程逐条对照）：
##   ① 本帧 `SystemFont.new()` + 设 font_names，本帧就 draw_string → **一整排实心方块**
##   ② 构建时建好、隔帧再用                                      → 正常中文
##   ③ 上一帧建好、本帧用                                        → 正常中文
##   ④ 本帧新建的 SystemFont 包一层 FontVariation 也一样是方块    → 方块
##   ⑤ 同一个新建字体给 Label 用（下一帧才绘制）                  → 正常中文
## 系统字体的解析是延迟的：新建那一帧内还没拿到真实字形，TextServer 只能画出
## "缺字方块"。等它跨过一次帧边界就好了。
##
## 原来的写法是**每次调用都新建**，而 `_draw_big_map()` 每次重绘要调 4 次
## （16 / 15 / 18 / 14），于是大地图上**所有** draw_string 文字 —— 地标名、
## 比例尺、点选目的地后的路线信息行、底部操作提示 —— 全是方块乱码，
## 每帧新建一次就永远等不到那一帧。而 Label / Button 用的字体是 `_build()`
## 里一次性建好、隔了很多帧才绘制的，所以从来不出问题（这正是"只有大地图上的
## 文字乱码"的原因）。
##
## 顺带把开销也降下来了：原来每次重绘都要重新枚举一遍系统字体。
var _font_cache := {}
## `_draw_big_map()` 与路线按钮用到的全部字号，在 `_build()` 里一次性预热
## 小地图叠加层的字号（N 标记 10、路名 13）也要预热
const FONT_SIZES := [10, 12, 13, 14, 15, 16, 18, 20]


func _font(size: int) -> Font:
	var hit: Font = _font_cache.get(size)
	if hit != null:
		return hit
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["Microsoft YaHei", "微软雅黑", "SimHei",
		"PingFang SC", "Noto Sans CJK SC", "sans-serif"])
	sf.allow_system_fallback = true
	# SystemFont 没有 font_size 属性（那是 Label 的主题字号），删掉
	# 由 add_theme_font_size_override / Label3D.font_size 控制
	_font_cache[size] = sf
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
# 小地图（圆形）—— 逐项移植原版 drawCinematicMinimap + getMapTile
# ---------------------------------------------------------------------------

## HUD 下发布局（原版是 CSS：#minimap bottom 49px / left edge−10px / 直径 = dial×.865）
func set_minimap_rect(pos: Vector2, size: Vector2) -> void:
	if minimap_holder == null:
		return
	minimap_holder.position = pos
	minimap_holder.size = size
	# minf 而不是 min —— `min()` 的返回类型是 Variant，用 `:=` 推断会被
	# 「Warning treated as error」直接判为编译失败。
	var d := minf(size.x, size.y)
	minimap.size = Vector2(d, d)
	minimap.position = Vector2((size.x - d) * 0.5, 0)
	minimap_overlay.size = Vector2(d, d)
	minimap_overlay.position = minimap.position
	# .cinematic-road-label { top: calc(100% + 12px); left: -5%; width: 110% }
	_road_label.position = Vector2(-size.x * 0.05, d + 12.0)
	_road_label.size = Vector2(size.x * 1.10, 20.0)


## 原版 minimapTilt(speed, observer)
func _minimap_tilt(speed: float, observer: bool) -> float:
	if observer:
		return 0.12
	return 0.40 + minf(1.0, absf(speed) / 28.0) * 0.25


## source plane：背景 → 水域 → 绿地 → 支路 → 主干道 → 路线。
## 坐标一律相对玩家、按 MAP_SCALE 缩放，再套上 translate(512,740) + rotate(−yaw)。
func _draw_minimap_plane() -> void:
	if world == null or player == null or not world.city_ready:
		_plane_draw.draw_rect(Rect2(Vector2.ZERO, Vector2(PLANE_PX, PLANE_PX)),
			Color(0.106, 0.188, 0.216))
		return
	var pos: Vector2 = player.data_position()
	var yaw: float = player.data_yaw()

	# 原版：source.fillStyle='#1b3037'; fillRect(0,0,1024,1024)
	_plane_draw.draw_rect(Rect2(Vector2.ZERO, Vector2(PLANE_PX, PLANE_PX)),
		Color(0.106, 0.188, 0.216))

	# 只旋转、不缩放：把 0.75 的缩放留给 draw_set_transform 的 scale，
	# 这样线宽也跟随缩放（与原版 canvas 变换一致）。
	_plane_draw.draw_set_transform(PLANE_ORIGIN * PLANE_SCALE, -yaw,
		Vector2(PLANE_SCALE, PLANE_SCALE))

	# —— 静态图层：水域 + 绿地 + 道路，一次性烘焙好，这里只贴一次 ——
	# 烘焙贴图按**平面单位**（1:1）生成，所以这里的 0.75 变换对位置与线宽
	# 的作用与原先逐条 draw_polyline 完全一致。
	if _map_tex != null:
		_plane_draw.draw_texture(_map_tex, Vector2(
			(_map_origin.x - pos.x) * MINIMAP_SCALE,
			-(_map_origin.y - pos.y) * MINIMAP_SCALE))
	else:
		_draw_static_direct(pos)

	# —— 路线：原版 #243e39 宽 7 → #99e0be 宽 4 ——
	if player.has_route():
		var route: PackedVector2Array = player.route_points()
		if route.size() >= 2:
			var rl := PackedVector2Array()
			for p in route:
				rl.append(Vector2((p.x - pos.x) * MINIMAP_SCALE, -(p.y - pos.y) * MINIMAP_SCALE))
			_plane_draw.draw_polyline(rl, Color(0.141, 0.243, 0.224), 5.25, true)
			_plane_draw.draw_polyline(rl, Color(0.600, 0.878, 0.745), 3.0, true)

	_plane_draw.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# ---------------------------------------------------------------------------
# 静态图层：烘焙 + 兜底直绘
# ---------------------------------------------------------------------------

## 烘焙失败或尚未就绪时的兜底：老路径（带视野剔除的直绘）。
## 只在 _map_tex 为空时用到，性能差但保证不会白屏。
func _draw_static_direct(pos: Vector2) -> void:
	_compute_bboxes()
	var view_rect := Rect2(pos - Vector2(MINIMAP_REACH, MINIMAP_REACH),
		Vector2(MINIMAP_REACH, MINIMAP_REACH) * 2.0)
	_draw_water_green(_plane_draw, pos, view_rect)
	_draw_roads(_plane_draw, pos, view_rect)


## 把全城静态图层画进一张贴图。**只在 setup 时跑一次**（约 100ms，藏在加载画面后面）。
##
## 贴图分辨率取 1:1 平面分辨率（MINIMAP_SCALE px/m）：最左 6788m → 约 2580px，
## 全城约 5160×1980，约 40MB 显存 —— 换来每次重绘只剩一次 blit。
func _bake_static_map() -> void:
	if _map_baked or world == null:
		return
	_map_baked = true
	var ext := CityData.extent
	if ext.size.x <= 1.0 or ext.size.y <= 1.0:
		return
	var margin_world := BAKE_MARGIN / MINIMAP_SCALE
	_map_origin = Vector2(ext.position.x - margin_world, ext.end.y + margin_world)
	_map_size = Vector2i(
		int(ceil(ext.size.x * MINIMAP_SCALE)) + int(BAKE_MARGIN) * 2,
		int(ceil(ext.size.y * MINIMAP_SCALE)) + int(BAKE_MARGIN) * 2)
	if _map_size.x < 16 or _map_size.y < 16:
		return
	_map_vp = SubViewport.new()
	_map_vp.name = "minimap-bake"
	_map_vp.size = _map_size
	_map_vp.transparent_bg = false
	_map_vp.disable_3d = true
	_map_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_map_vp)
	_map_painter = Control.new()
	_map_painter.name = "minimap-bake-painter"
	_map_painter.size = Vector2(_map_size)
	_map_painter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_painter.draw.connect(_draw_static_map)
	_map_vp.add_child(_map_painter)
	_map_tex = _map_vp.get_texture()
	print("[MapUI] 小地图静态图层已烘焙：%dx%d（外扩 %.0fpx）" % [
		_map_size.x, _map_size.y, BAKE_MARGIN])


## 烘焙绘制：与实时路径用**同一套坐标公式与线宽**，只是中心固定为贴图原点、
## yaw = 0，且不剔除（一次性画全城）。
func _draw_static_map() -> void:
	if _map_painter == null:
		return
	var pos := _map_origin
	# 贴图底色 = plane 底色：transparent_bg=false 时视口会用项目的
	# default_clear_color（蓝灰）清屏，必须先铺满底色，否则整张小地图会变蓝灰。
	_map_painter.draw_rect(Rect2(Vector2.ZERO, Vector2(_map_size)),
		Color(0.106, 0.188, 0.216))
	_map_painter.draw_set_transform(PLANE_ORIGIN * PLANE_SCALE, 0.0,
		Vector2(PLANE_SCALE, PLANE_SCALE))
	# 不剔除：全城画一遍（bbox 在烘焙里没有意义）
	_draw_water_green(_map_painter, pos, Rect2())
	_draw_roads(_map_painter, pos, Rect2())
	_map_painter.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## 水域 + 绿地（evenodd 挖洞）。view_rect 为空 Rect2 表示不剔除（烘焙路径）。
func _draw_water_green(canvas: CanvasItem, pos: Vector2, view_rect: Rect2) -> void:
	var skip := view_rect.size != Vector2.ZERO
	for wi in CityData.water.size():
		if skip and not (_water_boxes[wi] as Rect2).intersects(view_rect):
			continue
		var rings: Array = (CityData.water[wi] as Dictionary).get("rings", [])
		_draw_polygon_rings(canvas, rings, pos, Color(0.596, 0.741, 0.792, 0.12))
	for gi in CityData.green.size():
		if skip and not (_green_boxes[gi] as Rect2).intersects(view_rect):
			continue
		var rings2: Array = (CityData.green[gi] as Dictionary).get("rings", [])
		_draw_polygon_rings(canvas, rings2, pos, Color(0.588, 0.643, 0.443, 0.18))


## 道路：先支路后主干道，各自「暗描边 + 亮芯」两层。
func _draw_roads(canvas: CanvasItem, pos: Vector2, view_rect: Rect2) -> void:
	var skip := view_rect.size != Vector2.ZERO
	for pass_index in 2:
		var major_pass := pass_index == 1
		for ri in CityData.roads.size():
			if skip and not (_road_boxes[ri] as Rect2).intersects(view_rect):
				continue
			var r: Dictionary = CityData.roads[ri]
			if _is_major_road(str(r.get("kind", ""))) != major_pass:
				continue
			var pts: PackedVector2Array = r["points"]
			if pts.size() < 2:
				continue
			var line := PackedVector2Array()
			for p in pts:
				line.append(Vector2((p.x - pos.x) * MINIMAP_SCALE, -(p.y - pos.y) * MINIMAP_SCALE))
			if line.size() < 2:
				continue
			var rw := float(r.get("width", 8.0)) * TILE_SCALE * 0.7
			# 原版在**瓦片空间**算宽度，随后瓦片被缩到 0.76 倍再画进 plane
			var w := (maxf(3.2 if major_pass else 1.7, rw) + 1.8) * 0.76
			canvas.draw_polyline(line,
				Color(0.059, 0.078, 0.086, 0.66 if major_pass else 0.35), w, true)
			canvas.draw_polyline(line,
				Color(0.875, 0.882, 0.855, 0.83) if major_pass else Color(0.686, 0.714, 0.706, 0.57),
				w - 1.37, true)


## evenodd 挖洞：Godot 的 draw_colored_polygon 不支持多环带洞，
## 所以外环填色后，把内环（洞）按 plane 底色再填一遍。
func _draw_polygon_rings(canvas: CanvasItem, rings: Array, pos: Vector2, col: Color) -> void:
	for i in rings.size():
		var ring: Array = rings[i]
		if ring.size() < 3:
			continue
		var poly := PackedVector2Array()
		for p in ring:
			poly.append(Vector2((float(p[0]) - pos.x) * MINIMAP_SCALE,
				-(float(p[1]) - pos.y) * MINIMAP_SCALE))
		if i == 0:
			canvas.draw_colored_polygon(poly, col)
		else:
			canvas.draw_colored_polygon(poly, Color(0.106, 0.188, 0.216))


func _is_major_road(kind: String) -> bool:
	return kind == "trunk" or kind == "primary" or kind == "secondary"


## 显示端叠加层（原版在圆形裁切与雾霭**之后**才画箭头，所以它不受透视压扁影响）
func _draw_minimap_overlay() -> void:
	if player == null:
		return
	var d := minimap_overlay.size.x
	var k := d / MINIMAP_OUT
	var c := ARROW_ANCHOR * k

	# 车辆标记：moveTo(0,-13)→(9,10)→(0,6)→(-9,10)，填充 #7ee0c9、描边 #123037 宽 2.5
	var tri := PackedVector2Array([
		c + Vector2(0.0, -13.0) * k, c + Vector2(9.0, 10.0) * k,
		c + Vector2(0.0, 6.0) * k, c + Vector2(-9.0, 10.0) * k,
	])
	minimap_overlay.draw_colored_polygon(tri, Color(0.494, 0.878, 0.788))
	var outline := PackedVector2Array([tri[0], tri[1], tri[2], tri[3], tri[0]])
	minimap_overlay.draw_polyline(outline, Color(0.071, 0.188, 0.216), 2.5 * k, true)
	# 内高光：(0,-9)→(0,4)→(-5,6) 填充 #d6fff0
	var inner := PackedVector2Array([
		c + Vector2(0.0, -9.0) * k, c + Vector2(0.0, 4.0) * k, c + Vector2(-5.0, 6.0) * k,
	])
	minimap_overlay.draw_colored_polygon(inner, Color(0.839, 1.0, 0.941))

	# 原版 .north：left = (50 − sin(yaw)·45)%，top = (50 − cos(yaw)·45)%
	var yaw: float = player.data_yaw()
	var nx := (0.5 - sin(yaw) * 0.45) * d
	var ny := (0.5 - cos(yaw) * 0.45) * d
	var f := _font(10)
	var w := f.get_string_size("N", HORIZONTAL_ALIGNMENT_LEFT, -1, 10)
	minimap_overlay.draw_string(f, Vector2(nx - w.x * 0.5, ny + 4.0), "N",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.969, 0.973, 0.937))


## 每帧推进：透视倾斜 → 更新着色器 uniform → 玩家箭头 → 路名标签
func _update_minimap(delta: float) -> void:
	if minimap_holder == null or not minimap_holder.visible:
		return
	var speed := absf(float(player.speed())) if player != null else 0.0
	var observer: bool = player != null and player.is_observer()
	# 原版对 tilt 做指数平滑（.22）：plane.tilt += (target − tilt) × .22
	_tilt = lerpf(_tilt, _minimap_tilt(speed, observer), 22.0 * delta)
	if _plane_mat != null:
		_plane_mat.set_shader_parameter("tilt", _tilt)
	_plane_timer -= delta
	if _plane_timer <= 0.0:
		_plane_timer = REDRAW_INTERVAL
		_plane_draw.queue_redraw()
	minimap_overlay.queue_redraw()
	if _road_label != null and player != null and world != null:
		var pos: Vector2 = player.data_position()
		var near := world.collision.nearest(pos.x, pos.y)
		# 原版 #road-name 取 display_name，缺失时退回 name。
		# ⚠️ 不能写成 `road.get("display_name", road.get("name",""))` ——
		# `get` 的默认值只在**键不存在**时生效；display_name 存在但为空串时
		# 会直接返回空串，标签就一直是空的（实测踩过）。
		var name := ""
		if not near.is_empty():
			var road: Dictionary = near["road"]
			name = str(road.get("display_name", ""))
			if name == "":
				name = str(road.get("name", ""))
		var en: String = ROAD_ENGLISH.get(name, "")
		_road_label.text = name if en == "" else "%s   |   %s" % [name, en]


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
	big_map_toggled.emit(big_map_visible)


## 大地图上的鼠标事件。
##
## ⚠️ 进来第一件事就是 accept_event()，把事件标记为"已处理"、不再往下发。
##
## 实测（Godot 4.7.1，最小工程验证过）：`mouse_filter = MOUSE_FILTER_STOP`
## **拦不住滚轮** —— 地图展开时同一发 Mouse Wheel Up 既进了 GUI 的 gui_input，
## 又照样进了 `_unhandled_input`。后果就是在地图上滚滚轮时，地图缩放了，
## 相机距离 / 步行视距也跟着一起缩放，也就是"鼠标事件穿透到游戏画面"。
## （按键与移动事件 STOP 会自动吞掉，但为免版本行为差异，这里对所有鼠标
## 事件统一 accept_event()，让大地图成为鼠标的绝对屏障。）
func _on_map_input(event: InputEvent) -> void:
	if event is InputEventMouse:
		big_map.accept_event()
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
## source plane 每次要遍历全部 12202 条道路的每个顶点做坐标变换，
## 60fps 下就是每秒数百万次运算 —— 必须节流，否则真机上画面直接卡死。
## （透视倾斜的 uniform 仍然逐帧更新，只有几何重画受节流限制。）
## 小地图重绘间隔。原来是 0.2s，而每次重绘要重画全部可视道路/多边形（≈100ms）。
## 静态图层烘焙之后单次重绘只剩一次 blit + 一条路线，于是取回原版
## city-hud.ts 的 HUD tick（0.12s），跟随更顺滑又不产生长帧。
const REDRAW_INTERVAL := 0.12
var _redraw_timer := 0.0
var _plane_timer := 0.0


func update_ui(delta: float) -> void:
	# 小地图的透视倾斜是按帧做指数平滑的（原版 plane.tilt += (target−tilt)×.22），
	# 所以这里不受下面的 10Hz 节流限制。
	_update_minimap(delta)
	_redraw_timer -= delta
	if _redraw_timer > 0.0:
		return
	_redraw_timer = REDRAW_INTERVAL
	if big_map_visible:
		big_map.queue_redraw()
