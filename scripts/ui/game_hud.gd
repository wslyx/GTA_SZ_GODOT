extends CanvasLayer
class_name GameHUD
##
## 抬头显示 —— 对应原版 src/city-hud.ts + city-quicktips.ts + aerial-film-hud.ts。
##
## 显示项（照搬原版）：
##   速度（|v| × 3.6，三位补零）、档位（R / D / P）、里程（distance/1000，单位 KM）、
##   当前路名 + 片区、时钟（昼 14:20 / 夜 20:10 / 默认 18:25）、
##   订单阶段文案、toast、FPS 面板、操作速查
##
## 速度表盘：原版是内联 SVG，viewBox 0 0 280 270，量程 200，起始 −128°、扫过 256°。
## 这里用 _draw() 画同样的弧与指针。

const DIAL_RANGE := 200.0
const DIAL_START_DEG := -128.0
const DIAL_SWEEP_DEG := 256.0

var world: CityWorld
var player = null   ## PlayerController
var enabled := true

var _root: Control
var _speed_label: Label
var _gear_label: Label
var _odo_label: Label
var _road_label: Label
var _area_label: Label
var _clock_label: Label
var _mode_label: Label
var _toast_label: Label
var _fps_label: Label
var _route_label: Label
var _dial: Control
var _tips: Control

var _toast_timer := 0.0
var _speed_display := 0.0
var _hud_tick := 0.0
var _show_fps := false

## 片区名缓存（见 _area_name）：移动不超过这个距离就复用上次结果
const AREA_CACHE_RADIUS := 150.0
var _area_cache_pos := Vector2.ZERO
var _area_cache_name := ""
var _area_cache_valid := false


func setup(p_world: CityWorld, p_player) -> void:
	world = p_world
	player = p_player
	layer = 10
	_build()


func _mk_label(size: int, color: Color, pos: Vector2, anchor := 0) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0.03, 0.04, 0.05, 0.85))
	l.add_theme_constant_override("outline_size", 6)
	l.position = pos
	return l


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	var font := _font()

	# 速度表盘（左下）
	_dial = Control.new()
	_dial.custom_minimum_size = Vector2(280, 270)
	_dial.size = Vector2(280, 270)
	_dial.draw.connect(_draw_dial)
	_dial.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dial.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_dial.position = Vector2(28, -310)
	_root.add_child(_dial)

	_speed_label = _mk_label(64, Color(0.96, 0.97, 0.99), Vector2(0, 0))
	_speed_label.add_theme_font_override("font", font)
	_speed_label.position = Vector2(70, 188)
	_dial.add_child(_speed_label)

	_gear_label = _mk_label(30, Color(0.86, 0.90, 0.95), Vector2(0, 0))
	_gear_label.add_theme_font_override("font", font)
	_gear_label.position = Vector2(196, 210)
	_dial.add_child(_gear_label)

	# 里程
	_odo_label = _mk_label(20, Color(0.80, 0.85, 0.90), Vector2(0, 0))
	_odo_label.add_theme_font_override("font", font)
	_odo_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_odo_label.position = Vector2(40, -34)
	_root.add_child(_odo_label)

	# 右上：路名 / 片区 / 时钟
	_road_label = _mk_label(34, Color(0.97, 0.97, 0.95), Vector2(0, 0))
	_road_label.add_theme_font_override("font", font)
	_road_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_road_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_road_label.position = Vector2(-360, 34)
	_road_label.size = Vector2(320, 44)
	_root.add_child(_road_label)

	_area_label = _mk_label(22, Color(0.84, 0.89, 0.93), Vector2(0, 0))
	_area_label.add_theme_font_override("font", font)
	_area_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_area_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_area_label.position = Vector2(-360, 78)
	_area_label.size = Vector2(320, 32)
	_root.add_child(_area_label)

	_clock_label = _mk_label(22, Color(0.84, 0.89, 0.93), Vector2(0, 0))
	_clock_label.add_theme_font_override("font", font)
	_clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_clock_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_clock_label.position = Vector2(-360, 110)
	_clock_label.size = Vector2(320, 32)
	_root.add_child(_clock_label)

	# 模式提示（顶部中央）
	_mode_label = _mk_label(24, Color(0.95, 0.92, 0.82), Vector2(0, 0))
	_mode_label.add_theme_font_override("font", font)
	_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mode_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_mode_label.position = Vector2(-320, 26)
	_mode_label.size = Vector2(640, 34)
	_root.add_child(_mode_label)

	# 订单阶段（中上）
	_route_label = _mk_label(22, Color(0.92, 0.86, 0.66), Vector2(0, 0))
	_route_label.add_theme_font_override("font", font)
	_route_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_route_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_route_label.position = Vector2(-360, 64)
	_route_label.size = Vector2(720, 30)
	_root.add_child(_route_label)

	# toast（中下）
	_toast_label = _mk_label(26, Color(0.98, 0.96, 0.90), Vector2(0, 0))
	_toast_label.add_theme_font_override("font", font)
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_toast_label.position = Vector2(-360, -150)
	_toast_label.size = Vector2(720, 36)
	_root.add_child(_toast_label)

	# FPS 面板
	_fps_label = _mk_label(18, Color(0.78, 0.92, 0.80), Vector2(0, 0))
	_fps_label.add_theme_font_override("font", font)
	_fps_label.position = Vector2(34, 30)
	_fps_label.visible = false
	_root.add_child(_fps_label)

	# 操作速查
	_tips = _build_tips(font)
	_root.add_child(_tips)


func _font() -> Font:
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["Microsoft YaHei", "微软雅黑", "SimHei",
		"PingFang SC", "Noto Sans CJK SC", "sans-serif"])
	sf.allow_system_fallback = true
	return sf


func _build_tips(font: Font) -> Control:
	var c := Control.new()
	c.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	c.position = Vector2(-460, -330)
	c.size = Vector2(430, 300)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var panel := ColorRect.new()
	panel.color = Color(0.04, 0.05, 0.07, 0.72)
	panel.size = Vector2(430, 300)
	c.add_child(panel)
	var text := Label.new()
	text.add_theme_font_override("font", font)
	text.add_theme_font_size_override("font_size", 18)
	text.add_theme_color_override("font_color", Color(0.90, 0.93, 0.96))
	text.position = Vector2(16, 12)
	text.size = Vector2(400, 280)
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.text = _tips_text()
	c.add_child(text)
	c.visible = false
	return c


func _tips_text() -> String:
	return "\n".join(PackedStringArray([
		"驾驶  W/A/S/D 或方向键 · Space 手刹",
		"F 上下车 · T 切换坦克 · R 回到最近道路",
		"步行  W/A/S/D · Shift 跑 · C 切换人称",
		"G 无人机观景 · B 无人机/飞机",
		"坦克  Q/E 炮塔 · PgUp/PgDn 炮管 · Space 开炮 · X 刹车",
		"飞机  Space 导弹 · X 减速",
		"M 地图 · J 手账 · L 光照 · Y 雨天",
		"P 帧率面板 · H 鸣笛 · K 隐藏鼠标 · Esc 暂停",
		"拖动 环绕 · Shift+拖动 平移 · 滚轮 缩放",
	]))


# ---------------------------------------------------------------------------
# 每帧更新（原版 HUD 节流 ≈8.3Hz，即 hudTick < 0.12）
# ---------------------------------------------------------------------------

func update_hud(delta: float) -> void:
	if not enabled or player == null:
		return
	_toast_timer -= delta
	if _toast_timer <= 0.0:
		_toast_label.text = ""

	_hud_tick -= delta
	if _hud_tick > 0.0:
		return
	_hud_tick = 0.12

	var speed := float(player.speed())
	_speed_display = lerpf(_speed_display, absf(speed) * 3.6, 0.35)
	_speed_label.text = "%03d" % int(round(_speed_display))
	_gear_label.text = player.gear_text()
	_odo_label.text = "%.2f KM" % (float(player.odometer()) / 1000.0)

	var pos: Vector2 = player.data_position()
	var road := _road_name(pos)
	_road_label.text = road
	_area_label.text = _area_name(pos)
	_clock_label.text = GameState.clock_text()
	_mode_label.text = player.mode_text()

	if _route_label != null:
		_route_label.text = player.route_text()

	if _show_fps:
		var fps := Engine.get_frames_per_second()
		_fps_label.text = "FPS %d\n速度 %.1f m/s\n位置 %.0f, %.0f\n模式 %s" % [
			fps, speed, pos.x, pos.y, player.mode_text()]
	_dial.queue_redraw()


func toast(text: String, seconds := 3.0) -> void:
	_toast_label.text = text
	_toast_timer = seconds


func toggle_fps() -> void:
	set_fps_visible(not _show_fps)


## 供设置页直接设值（不用先查当前状态再翻转）
func set_fps_visible(v: bool) -> void:
	_show_fps = v
	_fps_label.visible = v


func is_fps_visible() -> bool:
	return _show_fps


func toggle_tips() -> void:
	_tips.visible = not _tips.visible


func _road_name(pos: Vector2) -> String:
	if world == null:
		return ""
	var near := world.collision.nearest(pos.x, pos.y)
	if near.is_empty():
		return ""
	var road: Dictionary = near["road"]
	var dn := str(road.get("display_name", ""))
	if dn != "":
		return dn
	var n := str(road.get("name", ""))
	return n


func _area_name(pos: Vector2) -> String:
	if world == null:
		return ""
	# HUD 以 ~8.3Hz 刷新，而 all_landmarks() 是上千条的地标表。
	# 片区名是"就近取整"的结果，玩家挪动一两百米不会变，没必要每次全量重扫。
	if _area_cache_valid and pos.distance_to(_area_cache_pos) < AREA_CACHE_RADIUS:
		return _area_cache_name
	var best := ""
	var best_d := 4000.0
	for lm in CityData.all_landmarks():
		var d := pos.distance_to(Vector2(float(lm.get("x", 0.0)), float(lm.get("z", 0.0))))
		if d < best_d:
			best_d = d
			best = str(lm.get("area", ""))
	_area_cache_pos = pos
	_area_cache_name = best
	_area_cache_valid = true
	return best


# ---------------------------------------------------------------------------
# 表盘绘制
# ---------------------------------------------------------------------------

func _draw_dial() -> void:
	var center := Vector2(140, 140)
	var radius := 116.0
	var start := deg_to_rad(DIAL_START_DEG)
	var sweep := deg_to_rad(DIAL_SWEEP_DEG)

	_dial.draw_arc(center, radius, start, start + sweep, 64, Color(0.10, 0.12, 0.15, 0.85), 14.0, true)
	_dial.draw_arc(center, radius * 0.78, start, start + sweep, 64, Color(0.16, 0.19, 0.23, 0.8), 2.0, true)

	# 刻度
	for i in 11:
		var t := float(i) / 10.0
		var a := start + sweep * t
		var inner := center + Vector2(cos(a), sin(a)) * (radius - 12.0)
		var outer := center + Vector2(cos(a), sin(a)) * radius
		var col := Color(0.72, 0.78, 0.84, 0.9)
		if t > 0.8:
			col = Color(0.92, 0.42, 0.30, 0.95)
		_dial.draw_line(inner, outer, col, 3.0, true)

	# 指针
	var frac := clampf(_speed_display / DIAL_RANGE, 0.0, 1.0)
	var angle := start + sweep * frac
	var tip := center + Vector2(cos(angle), sin(angle)) * (radius - 20.0)
	_dial.draw_line(center, tip, Color(0.95, 0.85, 0.55), 4.0, true)
	_dial.draw_circle(center, 7.0, Color(0.80, 0.84, 0.88))
