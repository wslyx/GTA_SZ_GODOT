extends CanvasLayer
class_name GameHUD
##
## 抬头显示 —— 对应原版 src/city-hud.ts + city-hud.css + city-quicktips.ts/css
## + city-story.css（`城市故事` 卡片）。
##
## 版式全部按原版 CSS 的**实测数值**复刻，不是"看着差不多"：
##
##   --hud-edge = clamp(22px, 1.7vw, 40px)        1920 宽 → 32.64px
##   --hud-dial = clamp(224px, 16vw, 308px)       1920 宽 → 307.2px（高 ×0.9643）
##   --hud-map  = dial × 0.865                    1920 宽 → 265.7px
##   header 内边距 = clamp(25px, 2.5vh, 40px)     1124 高 → 28.1px
##   城市地图 [M] top 33px ／ 城市生活 [J] top 69px ／ 画质 · 中 top 94px
##   小地图 bottom 49px，left = edge − 10px，圆形
##   速度表盘 right = edge，bottom 20px
##   城市故事卡片 top clamp(170px, 28vh, 340px)，left = edge，宽 236px
##   快捷键条 left 50%，bottom 19px，translateX(−50%)
##
## 表盘几何逐项照搬 createDial()（SVG viewBox 0 0 280 270）：
##   圆心 (140,136)、外弧 r=120、起始 −128°、扫过 256°、内圈 r=111、
##   41 根刻度（每 8 根为主刻度，r 112→108／102），主刻度标签 r=94 值 i×5、
##   限速弧 118°→128°（#d87477，宽 5）、能量圈 (140,231) r=16。

# ---------------------------------------------------------------------------
# 原版 CSS 的可变尺寸（clamp 实测）
# ---------------------------------------------------------------------------

func _vw() -> float:
	return get_viewport().get_visible_rect().size.x


func _vh() -> float:
	return get_viewport().get_visible_rect().size.y


func _hud_edge() -> float:
	return clampf(_vw() * 0.017, 22.0, 40.0)


func _hud_dial() -> float:
	return clampf(_vw() * 0.16, 224.0, 308.0)


func _hud_map() -> float:
	return _hud_dial() * 0.865


func _header_pad() -> float:
	return clampf(_vh() * 0.025, 25.0, 40.0)


# ---------------------------------------------------------------------------
# 配色（原版 CSS 变量 / 各选择器取色）
# ---------------------------------------------------------------------------

const HUD_WHITE := Color(0.957, 0.953, 0.937)          ## #f4f3ef
const HUD_MUTED := Color(0.933, 0.941, 0.922, 0.68)    ## rgba(238,240,235,.68)
const SUBTITLE_C := Color(0.976, 0.969, 0.941, 0.86)   ## rgba(249,247,240,.86)
const TOPBTN_C := Color(0.961, 0.961, 0.937, 0.72)     ## rgba(245,245,239,.72)
const KBD_EDGE := Color(1.0, 1.0, 1.0, 0.208)          ## #ffffff35
const KBD_TEXT := Color(0.937, 0.933, 0.894)           ## #efeee4

## .story-hud —— 城市故事卡片
const STORY_BG := Color(0.082, 0.173, 0.208, 0.933)    ## #152c35ee
const STORY_EDGE := Color(0.769, 0.839, 0.800, 0.239)  ## #c4d6cc3d
const STORY_BAR := Color(0.780, 0.831, 0.655)          ## #c7d4a7
const STORY_SMALL := Color(0.706, 0.784, 0.690)        ## #b4c8b0
const STORY_TEXT := Color(0.718, 0.812, 0.757)         ## #b7cfc1
const STORY_TITLE := Color(0.929, 0.941, 0.886)        ## #edf0e2
const STORY_TOP_RATIO := 0.28                           ## top clamp(170px, 28vh, 340px)
const STORY_W := 236.0

## .city-quicktips
const TIP_TEXT := Color(0.929, 0.941, 0.902, 0.702)    ## #edf0e6b3
const TIP_MODE := Color(0.722, 0.843, 0.773, 0.588)    ## #b8d7c596
const TIP_KBD_TEXT := Color(0.933, 0.949, 0.890, 0.788) ## #eef2e3c9
const TIP_KBD_EDGE := Color(0.878, 0.898, 0.855, 0.165) ## #e0e5da2a
const TIP_BG_A := Color(0.031, 0.082, 0.114, 0.0)       ## #08151d00
const TIP_BG_B := Color(0.031, 0.082, 0.114, 0.278)     ## #08151d47
const TIP_TOGGLE := Color(0.937, 0.949, 0.894, 0.729)   ## #eff2e4ba

## 表盘描边色（.cinematic-dial 各 class）
const DIAL_TRACK := Color(0.961, 0.961, 0.929, 0.439)   ## #f5f5ed70
const DIAL_INNER := Color(0.961, 0.961, 0.929, 0.220)   ## #f5f5ed38
const DIAL_LIMIT := Color(0.847, 0.455, 0.467)          ## #d87477
const DIAL_TICK := Color(0.941, 0.941, 0.914, 0.400)    ## #f0f0e966
const DIAL_TICK_MAJOR := Color(0.976, 0.976, 0.937, 0.839) ## #f9f9efd6
const DIAL_LABEL := Color(0.953, 0.953, 0.929, 0.580)   ## #f3f3ed94
const DIAL_POWER_RING := Color(0.063, 0.125, 0.161, 0.153) ## #10202927
const DIAL_POWER_EDGE := Color(1.0, 1.0, 1.0, 0.212)    ## #ffffff36
const DIAL_POWER := Color(0.427, 0.886, 0.788)          ## #6de2c9

## SVG 表盘坐标系（原版 viewBox 0 0 280 270）
const DIAL_VB := Vector2(280.0, 270.0)
const DIAL_CENTER := Vector2(140.0, 136.0)
const DIAL_R := 120.0
const DIAL_START_DEG := -128.0
const DIAL_SWEEP_DEG := 256.0
const DIAL_MAX_SPEED := 200.0

## #career-invitation —— 起始点的生活邀请卡（city-career.css:23）
##   position:absolute; top:165px; left:var(--hud-edge); max-width:330px;
##   padding:18px 22px; background #173437dc; border 1px #adc8b540
const INV_BG := Color(0.090, 0.204, 0.216, 0.863)      ## #173437dc
const INV_EDGE := Color(0.678, 0.784, 0.710, 0.251)    ## #adc8b540
const INV_SMALL := Color(0.675, 0.796, 0.714)          ## #accbb6
const INV_TITLE := Color(0.902, 0.918, 0.835)          ## #e6ead5
const INV_BODY := Color(0.718, 0.812, 0.757)           ## #b7cfc1
const INV_TOP := 165.0
const INV_PAD := Vector2(22.0, 18.0)
const INV_MAX_W := 330.0
## 卡片在出生点停留的里程上限（原版 world.state.distance > 300 即收起）
const INV_DISTANCE_LIMIT := 300.0

## .story-entry —— 故事尚未开始时是「入口卡」（内边距 11/14），
## 剧情进行中才是 .story-hud（内边距 14/15）
const STORY_ENTRY_PAD := Vector2(14.0, 11.0)
const STORY_HUD_PAD := Vector2(15.0, 14.0)

## 原版 city-quicktips.ts 的 QUICK 表（四模式，键位/说明逐字照搬）
const QUICK_TIPS := {
	"driving": [
		{"key": "WASD", "label": "驾驶"}, {"key": "T", "label": "坦克"},
		{"key": "空格", "label": "手刹"}, {"key": "C", "label": "镜头"},
		{"key": "F", "label": "下车"}, {"key": "G", "label": "观景"},
		{"key": "Y", "label": "雨天"},
	],
	"walking": [
		{"key": "WASD", "label": "行走"}, {"key": "滚轮", "label": "远近"},
		{"key": "C", "label": "人称"}, {"key": "Shift", "label": "跑步"},
		{"key": "鼠标", "label": "看向"}, {"key": "F", "label": "上车"},
		{"key": "E", "label": "互动"},
	],
	"observer": [
		{"key": "WASD", "label": "平移"}, {"key": "Q E", "label": "升降"},
		{"key": "鼠标", "label": "环绕"}, {"key": "B", "label": "飞机"},
		{"key": "G / F", "label": "返回"}, {"key": "滚轮", "label": "远近"},
	],
	"tank": [
		{"key": "WASD", "label": "驾驶"}, {"key": "Q E", "label": "炮塔"},
		{"key": "空格", "label": "开炮"}, {"key": "T", "label": "轿车"},
		{"key": "F", "label": "下车"}, {"key": "C", "label": "镜头"},
	],
}
## 原版 LABELS：左端的模式名（carView 时是「看车」，本版未做看车镜头）
const QUICK_LABELS := {"driving": "驾驶", "walking": "步行", "observer": "观景", "tank": "坦克"}

## 飞行仪表 —— 原版 city-flight-hud.css 的数值
##   .flight-instruments{left:32px;top:155px;width:232px;padding:20px 22px;
##     background:linear-gradient(120deg,#0f202edb,#12252d9c);border:1px #ffffff29;
##     border-radius:9px}
## Godot 的 StyleBoxFlat 没有渐变，取渐变的起点色（#0f202edb）作整块底色。
const FL_BG := Color(0.059, 0.125, 0.180, 0.859)      ## #0f202edb
const FL_EDGE := Color(1.0, 1.0, 1.0, 0.161)          ## #ffffff29
const FL_SMALL := Color(0.620, 0.792, 0.773)          ## #9ecac5
const FL_TEXT := Color(0.957, 0.953, 0.914)           ## #f4f3e9
const FL_PHASE := Color(0.835, 0.863, 0.824, 0.651)   ## #d5dcd2a6
const FL_DT := Color(0.627, 0.710, 0.741)             ## #a0b5bd
const FL_UNIT := Color(0.714, 0.804, 0.784)           ## #b6cdc8
const FL_TRACK := Color(1.0, 1.0, 1.0, 0.086)         ## #ffffff16
const FL_THROTTLE := Color(0.584, 0.851, 0.776)       ## #95d9c6
const FL_PANEL_W := 232.0
const FL_PANEL_POS := Vector2(32.0, 155.0)
const FL_PAD := Vector2(22.0, 20.0)
## 油门条宽度 = 面板宽 232 − 左右 padding 22×2
const FL_BAR_W := 188.0
## .flight-crash{top:32%;border-top:2px #ffb968;background:linear-gradient(180deg,#2a171dcc,#161c2800)}
const FL_CRASH_EDGE := Color(1.0, 0.725, 0.408)       ## #ffb968
const FL_CRASH_BG := Color(0.165, 0.090, 0.114, 0.800) ## #2a171dcc
const FL_CRASH_SMALL := Color(1.0, 0.737, 0.541)      ## #ffbc8a
## .flight-help{bottom:26px;left:50%;gap:7px;padding:14px 26px;background:#0b1b27d9}
const FL_HELP_BG := Color(0.043, 0.106, 0.153, 0.851) ## #0b1b27d9
const FL_HELP_EDGE := Color(1.0, 1.0, 1.0, 0.145)     ## #ffffff25
const FL_HELP_SPAN := Color(0.741, 0.796, 0.784)      ## #bdcbc8
const FL_HELP_MISSILE := Color(0.741, 0.910, 0.847)   ## #bde8d8

var world: CityWorld
var player = null
var enabled := true

var _root: Control
var _wordmark: Label
var _subtitle: Label
var _top_group: VBoxContainer
var _story_card: PanelContainer
var _story_bar: ColorRect
var _story_small: Label
var _story_title: Label
var _story_body: Label
var _story_pad := Vector2.ZERO      ## 当前生效的内边距（入口卡 / 剧情卡）
var _invitation: PanelContainer
var _inv_box: Control
var _inv_small: Label
var _inv_title: Label
var _inv_body: Label
var _inv_kbd: PanelContainer
var _dial: Control
var _speed_label: Label
var _kmh_label: Label
var _gear_label: Label
var _odo_label: Label
var _quicktips: Control
var _toast_label: Label
var _fps_label: Label
## 飞行仪表（原版 city-flight-hud.ts）
var _flight_panel: PanelContainer
var _flight_phase: Label
var _flight_speed: Label
var _flight_alt: Label
var _flight_heading: Label
var _flight_throttle: Label
var _flight_bar_fill: ColorRect
var _flight_crash: PanelContainer
var _flight_crash_span: Label
var _flight_help: PanelContainer
var _flight_missile: Label
var _flight_throttle_value := 0.55
## 光照档时钟（原版 city-hud.ts 的 hud.clock：白天 14:20 / 日落 18:25 / 夜晚 20:10）
var _clock_label: Label

## 预热的字体（原版教训：SystemFont 当帧新建当帧 draw_string 会画成实心方块，
## 所以凡是走 draw_* 的文字，字体都在 _build() 里一次性建好）
var _f_ui: Font
var _f_serif: Font
var _f_num: Font
var _f_tip: Font
var _f_dial_label: Font

var _toast_timer := 0.0
var _speed_display := 0.0
var _hud_tick := 0.0
var _show_fps := false
var _dial_scale := Vector2.ONE
var _tip_mode := "driving"
var _tip_items: Array = []
var _tip_mode_txt := "驾驶"
var _tip_boxes: Array = []

const AREA_CACHE_RADIUS := 150.0
var _area_cache_pos := Vector2.ZERO
var _area_cache_name := ""
var _area_cache_valid := false


func setup(p_world: CityWorld, p_player) -> void:
	world = p_world
	player = p_player
	layer = 10
	_build()
	get_viewport().size_changed.connect(_on_viewport_resized)


# ---------------------------------------------------------------------------
# 字体
# ---------------------------------------------------------------------------

func _sys(candidates: Array) -> SystemFont:
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(candidates)
	sf.allow_system_fallback = true
	return sf


## 原版大量使用 letter-spacing。Godot 的 Label 没有这个属性，
## 只能靠 FontVariation.spacing_glyph 在字体层实现。
func _spaced(base: Font, px: float) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = base
	fv.spacing_glyph = int(round(px))
	return fv


func _label(text: String, font: Font, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## 键位小方块（原版 style.css 的 `kbd` + city-quicktips 的覆盖）：
##   border 1px、border-radius 3px、padding 2px 5px、margin 0 4px、font 11px
func _kbd(text: String, font: Font, font_size: int, edge: Color, fg: Color,
		pad := Vector2(5, 2), radius := 3) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.075, 0.145, 0.169, 0.15)      ## #13252b26
	sb.border_color = edge
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = pad.x
	sb.content_margin_right = pad.x
	sb.content_margin_top = pad.y
	sb.content_margin_bottom = pad.y
	p.add_theme_stylebox_override("panel", sb)
	var l := _label(text, font, font_size, fg)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p.add_child(l)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


# ---------------------------------------------------------------------------
# 构建
# ---------------------------------------------------------------------------

func _build() -> void:
	_f_ui = _sys(["PingFang SC", "Microsoft YaHei", "微软雅黑", "Noto Sans SC",
		"SimHei", "sans-serif"])
	_f_serif = _sys(["Songti SC", "Noto Serif SC", "STSong", "SimSun", "宋体", "serif"])
	_f_num = _sys(["DIN Alternate", "Arial Narrow", "Helvetica Neue", "Arial", "sans-serif"])
	_f_tip = _f_ui
	_f_dial_label = _sys(["Helvetica Neue", "Arial", "sans-serif"])

	_root = Control.new()
	_root.name = "hud-root"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_build_header()
	_build_wanted()
	_build_combat()
	_build_topright()
	_build_story_card()
	_build_invitation()
	_build_dial()
	_build_quicktips()
	_build_flight()

	_toast_label = _label("", _f_ui, 12, Color(0.949, 0.945, 0.906))
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# .cinematic-hud #toast { top: 120px; }  padding 11px 20px / 边框 #f5f5e91f / 底 #172026c9
	_toast_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast_label.position = Vector2(-320, 120)
	_toast_label.size = Vector2(640, 30)
	_root.add_child(_toast_label)

	_fps_label = _label("", _f_ui, 11, Color(0.933, 0.933, 0.871, 0.639))
	_fps_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_fps_label.position = Vector2(-300, -34)
	_fps_label.size = Vector2(280, 26)
	_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_fps_label.visible = false
	_root.add_child(_fps_label)

	_on_viewport_resized()


# ---------------------------------------------------------------------------
# 通缉星（顶部居中 5 颗 ★；亮 #e8b64c，熄 22% 白；当前星随 heat 脉冲）
# ---------------------------------------------------------------------------

const WANTED_LIT := Color(0.910, 0.714, 0.298)      ## #e8b64c
const WANTED_DIM := Color(1.0, 1.0, 1.0, 0.22)
const WANTED_STAR_COUNT := 5

var _wanted_labels: Array = []
var _wanted_level := 0
var _wanted_heat := 0.0


func _build_wanted() -> void:
	var star_size := int(round(clampf(_vw() * 0.014, 15.0, 22.0)))
	var step := float(star_size) + 6.0
	var total := step * float(WANTED_STAR_COUNT - 1)
	for i in WANTED_STAR_COUNT:
		var l := _label("★", _f_ui, star_size, WANTED_DIM)
		# PRESET_CENTER_TOP 的锚点下 position.x 是相对中心线的偏移
		l.set_anchors_preset(Control.PRESET_CENTER_TOP)
		l.position = Vector2(-total * 0.5 + step * float(i), _header_pad() + 4.0)
		l.visible = false
		_root.add_child(l)
		_wanted_labels.append(l)


## 通缉值 UI 入口（WantedSystem → main_game 调用）。level 0–5，heat 0–1。
func set_wanted(level: int, heat: float) -> void:
	_wanted_level = clampi(level, 0, WANTED_STAR_COUNT)
	_wanted_heat = clampf(heat, 0.0, 1.0)
	for i in _wanted_labels.size():
		_wanted_labels[i].visible = i < _wanted_level


func _update_wanted(delta: float) -> void:
	if _wanted_level <= 0:
		return
	# 当前星（最右亮着的那颗）按 heat 做呼吸脉冲：快满时闪烁加快
	var pulse := 0.72 + 0.28 * (0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.006 * (1.0 + _wanted_heat)))
	for i in _wanted_labels.size():
		if i == _wanted_level - 1:
			var c := WANTED_LIT
			c.a *= lerpf(1.0, pulse, _wanted_heat)
			_wanted_labels[i].add_theme_color_override("font_color", c)
		elif i < _wanted_level:
			_wanted_labels[i].add_theme_color_override("font_color", WANTED_LIT)


# ---------------------------------------------------------------------------
# 战斗 UI（GTA化 §2.3）：准星 / 弹药 / 血条
# ---------------------------------------------------------------------------

const CROSS_COLOR := Color(0.949, 0.945, 0.906, 0.9)
const CROSS_HIT := Color(0.910, 0.714, 0.298, 1.0)   ## 命中反馈同通缉星亮色

var _crosshair: Control = null
var _cross_ticks: Array = []
var _ammo_label: Label = null
var _health_fill: ColorRect = null
var _hit_mark_t := 0.0
var _combat_visible := false


func _build_combat() -> void:
	# 准星：中心点 + 上下左右 4 条短线（ColorRect，无纹理依赖）
	_crosshair = Control.new()
	_crosshair.set_anchors_preset(Control.PRESET_CENTER)
	_crosshair.visible = false
	_root.add_child(_crosshair)
	var dot := ColorRect.new()
	dot.color = CROSS_COLOR
	dot.size = Vector2(3, 3)
	dot.position = Vector2(-1.5, -1.5)
	_crosshair.add_child(dot)
	for i in 4:
		var t := ColorRect.new()
		t.color = CROSS_COLOR
		t.size = Vector2(2, 7) if i % 2 == 0 else Vector2(7, 2)
		var off := 9.0
		if i == 0: t.position = Vector2(-1, -off - 7)
		elif i == 1: t.position = Vector2(-1, off)
		elif i == 2: t.position = Vector2(-off - 7, -1)
		else: t.position = Vector2(off, -1)
		_crosshair.add_child(t)
		_cross_ticks.append(t)
	# 弹药：屏幕中下（准星下方 64px）
	_ammo_label = _label("", _f_num, 15, Color(0.949, 0.945, 0.906, 0.88))
	_ammo_label.set_anchors_preset(Control.PRESET_CENTER)
	_ammo_label.position = Vector2(-90, 64)
	_ammo_label.size = Vector2(180, 22)
	_ammo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ammo_label.visible = false
	_root.add_child(_ammo_label)
	# 血条：左上 wordmark/副标题下方 —— 宽 150、高 5 的暗槽 + 亮填充
	var hp_slot := ColorRect.new()
	hp_slot.color = Color(1, 1, 1, 0.14)
	hp_slot.position = Vector2(_hud_edge(), _header_pad() + 64.0)
	hp_slot.size = Vector2(150, 5)
	_root.add_child(hp_slot)
	_health_fill = ColorRect.new()
	_health_fill.color = Color(0.42, 0.78, 0.60)
	_health_fill.position = Vector2(0, 0)
	_health_fill.size = Vector2(150, 5)
	hp_slot.add_child(_health_fill)


## 武器状态（weapon_system.hud_state() 透传）：{} = 空手隐藏整套战斗 UI
func set_weapon(state: Dictionary) -> void:
	_combat_visible = not state.is_empty()
	_crosshair.visible = _combat_visible
	_ammo_label.visible = _combat_visible
	if _combat_visible:
		if bool(state.get("reloading", false)):
			_ammo_label.text = "装填中…"
		else:
			_ammo_label.text = "%d / %d  %s" % [state.get("ammo", 0), state.get("mag", 0), state.get("name", "")]


## 血量 0–100
func set_health(hp: float) -> void:
	if _health_fill != null:
		_health_fill.size.x = 150.0 * clampf(hp, 0.0, 100.0) / 100.0
		_health_fill.color = Color(0.42, 0.78, 0.60) if hp > 30.0 else Color(0.89, 0.35, 0.30)


## 命中反馈：4 条短线闪一下暖色
func hit_mark() -> void:
	_hit_mark_t = 0.18


func _update_combat(delta: float) -> void:
	if not _combat_visible:
		return
	_hit_mark_t = maxf(0.0, _hit_mark_t - delta)
	var c := CROSS_HIT if _hit_mark_t > 0.0 else CROSS_COLOR
	for t in _cross_ticks:
		t.color = c


func _build_header() -> void:
	var pad := _header_pad()
	var edge := _hud_edge()
	# .wordmark：Songti 衬线、clamp(30,2.35vw,45)px、letter-spacing .26em
	var wm_size := int(round(clampf(_vw() * 0.0235, 30.0, 45.0)))
	_wordmark = _label("深城纪", _spaced(_f_serif, float(wm_size) * 0.26), wm_size, HUD_WHITE)
	_wordmark.position = Vector2(edge, pad)
	_root.add_child(_wordmark)

	var sub_size := int(round(clampf(_vw() * 0.0093, 11.0, 17.0)))
	_subtitle = _label("", _spaced(_f_ui, float(sub_size) * 0.12), sub_size, SUBTITLE_C)
	# margin-top 8px（原版 .wordmark span）
	_subtitle.position = Vector2(edge, pad + float(wm_size) * 1.18 + 8.0)
	_root.add_child(_subtitle)


func _build_topright() -> void:
	_top_group = VBoxContainer.new()
	_top_group.name = "top-right"
	_top_group.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_top_group.alignment = BoxContainer.ALIGNMENT_BEGIN
	# 原版 #map-button top 33px / #journal-button top 69px / 画质 top 94px
	# → 行间距 ≈ 36px 减行高，取分离 16。
	_top_group.add_theme_constant_override("separation", 16)
	_top_group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# right = --hud-edge：左边要让出 edge，否则文字顶到屏幕边缘被裁。
	_top_group.position = Vector2(-260.0 - _hud_edge(), 33.0)
	_top_group.size = Vector2(260, 120)
	_root.add_child(_top_group)

	# 原版 #map-button / #journal-button 都在 header 里、right = --hud-edge，
	# 字号 11px、letter-spacing .08em、色 rgba(245,245,239,.72)
	for row in [["城市地图", "M"], ["城市生活", "J"]]:
		var h := HBoxContainer.new()
		h.alignment = BoxContainer.ALIGNMENT_END
		h.add_theme_constant_override("separation", 4)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var lab := _label(str(row[0]), _spaced(_f_ui, 0.9), 11, TOPBTN_C)
		lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		h.add_child(lab)
		h.add_child(_kbd(str(row[1]), _f_ui, 10, KBD_EDGE, KBD_TEXT))
		_top_group.add_child(h)

	# 画质 · 中（city-graphics-panel 的 trigger，CSS top 94px）
	var q := HBoxContainer.new()
	q.alignment = BoxContainer.ALIGNMENT_END
	q.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ql := _label("", _spaced(_f_ui, 0.9), 11, TOPBTN_C)
	ql.name = "quality-label"
	ql.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	q.add_child(ql)
	_top_group.add_child(q)

	# 光照档时钟（原版 hud.clock，随 L 键切档更新）
	_clock_label = _label("", _spaced(_f_ui, 0.9), 11, TOPBTN_C)
	_clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_top_group.add_child(_clock_label)


func _build_story_card() -> void:
	var top := clampf(_vh() * STORY_TOP_RATIO, 170.0, 340.0)
	_story_card = PanelContainer.new()
	_story_card.name = "story-card"
	_story_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = STORY_BG
	sb.border_color = STORY_EDGE
	sb.set_border_width_all(1)
	# 原版 border-left:2px solid #c7d4a7 —— StyleBoxFlat 只有一个 border_color，
	# 所以左边那条强调线用同宽的 left border 近似（颜色取强调色）
	sb.border_width_left = 2
	sb.border_color = STORY_EDGE
	sb.content_margin_left = 15.0
	sb.content_margin_right = 15.0
	sb.content_margin_top = 14.0
	sb.content_margin_bottom = 14.0
	_story_card.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_story_small = _label("城市故事", _spaced(_f_ui, 1.4), 10, STORY_SMALL)
	v.add_child(_story_small)
	_story_title = _label("", _f_serif, 19, STORY_TITLE)
	v.add_child(_story_title)
	_story_body = _label("", _f_ui, 12, STORY_TEXT)
	_story_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_story_body.custom_minimum_size = Vector2(STORY_W - 32.0, 0.0)
	_story_body.add_theme_constant_override("line_spacing", 4)
	v.add_child(_story_body)
	_story_card.add_child(v)

	# 左边那条 2px 强调线单独画在 _root 上（PanelContainer 会把子节点拉满，
	# 放进去会变成整块色板），位置在 update_hud 里跟着卡片高度同步。
	_story_bar = ColorRect.new()
	_story_bar.color = STORY_BAR
	_story_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_story_bar.size = Vector2(2, 0)
	_root.add_child(_story_bar)

	_root.add_child(_story_card)


## 起始点的生活邀请卡 —— 原版 city-career-experience.ts:27
##   <small>雨停以后</small>
##   <strong>城市这么大，先把今天过好。</strong>
##   <span>去一个新的角落 · 认识一个人 · 攒自己的房间 <kbd>J</kbd></span>
## 原版是 <button>，点一下 = 打开城市手账（hooks.open）。
func _build_invitation() -> void:
	_invitation = PanelContainer.new()
	_invitation.name = "career-invitation"
	var sb := StyleBoxFlat.new()
	sb.bg_color = INV_BG
	sb.border_color = INV_EDGE
	sb.set_border_width_all(1)
	sb.content_margin_left = INV_PAD.x
	sb.content_margin_right = INV_PAD.x
	sb.content_margin_top = INV_PAD.y
	sb.content_margin_bottom = INV_PAD.y
	_invitation.add_theme_stylebox_override("panel", sb)
	_invitation.mouse_filter = Control.MOUSE_FILTER_STOP
	_invitation.gui_input.connect(_on_invitation_input)

	# PanelContainer 会把子节点拉满内容区，所以内部再放一个可手动定位的 Control
	_inv_box = Control.new()
	_inv_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_invitation.add_child(_inv_box)

	_inv_small = _label("雨停以后", _spaced(_f_ui, 1.2), 10, INV_SMALL)
	_inv_box.add_child(_inv_small)
	_inv_title = _label("城市这么大，先把今天过好。", _f_serif, 21, INV_TITLE)
	_inv_box.add_child(_inv_title)
	_inv_body = _label("去一个新的角落 · 认识一个人 · 攒自己的房间", _f_ui, 11, INV_BODY)
	_inv_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_inv_box.add_child(_inv_body)
	# 行内 <kbd>J</kbd>：style.css 的 kbd 规则（1px 边、圆角 3、内边距 2×5、字号 11）
	_inv_kbd = _kbd("J", _f_ui, 11, Color(0.925, 0.961, 0.914, 0.29),
		Color(0.874, 0.906, 0.851), Vector2(5, 2), 3)
	_inv_kbd.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_inv_box.add_child(_inv_kbd)

	_root.add_child(_invitation)


func _on_invitation_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		if player != null and player.panels != null and not player.panels.journal_visible:
			player.panels.toggle_journal()


## 原版 city-career-experience.ts:79 的显隐条件，逐项对应：
##   合约进行中 / 已有完成合约 / 顺路单进行中 / 菜单打开 / 无人机观景 / 已开出 300m
func _refresh_invitation() -> void:
	if _invitation == null or player == null:
		return
	var show := true
	if player.career != null:
		var c: Dictionary = player.career.status()
		if int(c.get("active", -1)) >= 0 or int(c.get("completed", 0)) > 0:
			show = false
	if player.rides != null and int(player.rides.active_ride) >= 0:
		show = false
	if player.is_observer():
		show = false
	if player.panels != null and player.panels.journal_visible:
		show = false
	if player.maps != null and player.maps.big_map_visible:
		show = false
	if player.paused and not player.is_observer():
		show = false
	if float(player.odometer()) > INV_DISTANCE_LIMIT:
		show = false
	_invitation.visible = show


func _build_dial() -> void:
	_dial = Control.new()
	_dial.name = "dial"
	_dial.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dial.draw.connect(_draw_dial)
	_root.add_child(_dial)

	var speed_size := int(round(_hud_dial() * 0.34))
	_speed_label = _label("000", _f_num, speed_size, Color(0.965, 0.961, 0.941))
	_speed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_speed_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.53))
	_speed_label.add_theme_constant_override("shadow_offset_y", 2)
	_speed_label.add_theme_constant_override("shadow_outline_size", 2)
	_dial.add_child(_speed_label)

	_kmh_label = _label("KM/H", _spaced(_f_num, float(_hud_dial()) * 0.069 * 0.13),
		int(round(_hud_dial() * 0.069)), Color(0.957, 0.957, 0.925, 0.667))
	_kmh_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_dial.add_child(_kmh_label)

	# .cinematic-speed-meta：left/right 20%、bottom 17px、opacity .58
	_gear_label = _label("P", _f_ui, 10, Color(0.957, 0.957, 0.922))
	_gear_label.add_theme_color_override("font_color", Color(0.957, 0.957, 0.922, 0.58))
	_dial.add_child(_gear_label)
	_odo_label = _label("0.0 KM", _f_ui, 9, Color(0.933, 0.933, 0.902, 0.58))
	_dial.add_child(_odo_label)


func _build_quicktips() -> void:
	_quicktips = Control.new()
	_quicktips.name = "quicktips"
	_quicktips.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_quicktips.draw.connect(_draw_quicktips)
	_root.add_child(_quicktips)

	# 原版 city-quicktips.ts 的 QUICK 表（四模式），secondary 的窄屏隐藏项这里全显示。
	# 注意：条目随模式切换，_tip_boxes 只建「最大条目数」个，多余的保持隐藏。
	_tip_items = QUICK_TIPS[_tip_mode]
	for it in _tip_items:
		var b := _kbd(str(it["key"]), _f_tip, 9, TIP_KBD_EDGE, TIP_KBD_TEXT, Vector2(4, 1), 2)
		b.visible = false
		_quicktips.add_child(b)
		_tip_boxes.append(b)
	var q := _kbd("?", _f_tip, 9, TIP_KBD_EDGE, TIP_KBD_TEXT, Vector2(4, 1), 2)
	q.visible = false
	_quicktips.add_child(q)
	# ⚠️ 必须入列：_draw_quicktips 把 _tip_boxes 的**最后一个**当「? 操作」切换钮。
	# 之前漏了这句，导致切换钮一直显示最后一个条目的键位（驾驶模式显示 [Y]）。
	_tip_boxes.append(q)


## 飞行仪表 —— 原版 city-flight-hud.ts 的 .flight-instruments / .flight-crash /
## .flight-help 三块。此前本版只做了模式文案，仪表（空速 / 离地高度 / 航向 /
## 油门）与坠毁倒计时都没有。
func _build_flight() -> void:
	# ---- 仪表盘 ----
	_flight_panel = PanelContainer.new()
	_flight_panel.name = "flight-instruments"
	_flight_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = FL_BG
	sb.border_color = FL_EDGE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(9)
	sb.content_margin_left = FL_PAD.x
	sb.content_margin_right = FL_PAD.x
	sb.content_margin_top = FL_PAD.y
	sb.content_margin_bottom = FL_PAD.y
	_flight_panel.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flight_panel.add_child(v)

	var small := _label("BAY WINGS / 湾翼", _spaced(_f_ui, 2.0), 10, FL_SMALL)
	v.add_child(small)
	var strong := _label("海湾自由飞行", _f_ui, 17, FL_TEXT)
	v.add_child(strong)
	_flight_phase = _label("", _f_ui, 11, FL_PHASE)
	v.add_child(_flight_phase)

	# dl：grid 两列，gap 18px 行 / 24px 列，margin 24px 上 / 16px 下
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 18)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 16)
	v.add_child(spacer)
	v.add_child(grid)

	_flight_speed = _flight_readout(grid, "空速", "KM/H")
	_flight_alt = _flight_readout(grid, "离地高度", "M")
	_flight_heading = _flight_readout(grid, "航向", "°")
	_flight_throttle = _flight_readout(grid, "油门", "%")
	# 航向那一格的单位就是 °，不需要再留 6px 间隔 —— 保持与其余三格一致即可。

	var track := ColorRect.new()
	track.color = FL_TRACK
	track.custom_minimum_size = Vector2(FL_BAR_W, 3)
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(track)
	# 填充条挂在 track 上（ColorRect 不是容器，子节点的 position 不会被排版覆盖）
	_flight_bar_fill = ColorRect.new()
	_flight_bar_fill.color = FL_THROTTLE
	_flight_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flight_bar_fill.size = Vector2(0, 3)
	track.add_child(_flight_bar_fill)
	_root.add_child(_flight_panel)

	# ---- 坠毁提示 ----
	_flight_crash = PanelContainer.new()
	_flight_crash.name = "flight-crash"
	_flight_crash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var csb := StyleBoxFlat.new()
	csb.bg_color = FL_CRASH_BG
	csb.border_color = FL_CRASH_EDGE
	csb.border_width_top = 2
	csb.set_border_width_all(0)
	csb.border_width_top = 2
	csb.content_margin_left = 48.0
	csb.content_margin_right = 48.0
	csb.content_margin_top = 25.0
	csb.content_margin_bottom = 25.0
	_flight_crash.add_theme_stylebox_override("panel", csb)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 12)
	cv.alignment = BoxContainer.ALIGNMENT_CENTER
	cv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flight_crash.add_child(cv)
	var cs := _label("FLIGHT ENDED", _spaced(_f_ui, 4.0), 11, FL_CRASH_SMALL)
	cs.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cv.add_child(cs)
	var ct := _label("飞机撞毁", _spaced(_f_ui, 6.0), 30, FL_TEXT)
	ct.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cv.add_child(ct)
	_flight_crash_span = _label("3 秒后返回无人机", _f_ui, 14, FL_TEXT)
	_flight_crash_span.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cv.add_child(_flight_crash_span)
	_root.add_child(_flight_crash)

	# ---- 底部操作提示 ----
	_flight_help = PanelContainer.new()
	_flight_help.name = "flight-help"
	_flight_help.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hsb := StyleBoxFlat.new()
	hsb.bg_color = FL_HELP_BG
	hsb.border_color = FL_HELP_EDGE
	hsb.set_border_width_all(1)
	hsb.set_corner_radius_all(7)
	hsb.content_margin_left = 26.0
	hsb.content_margin_right = 26.0
	hsb.content_margin_top = 14.0
	hsb.content_margin_bottom = 14.0
	_flight_help.add_theme_stylebox_override("panel", hsb)
	var hv := VBoxContainer.new()
	hv.add_theme_constant_override("separation", 7)
	hv.alignment = BoxContainer.ALIGNMENT_CENTER
	hv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flight_help.add_child(hv)
	var hs := _label("W / S · 抬头 / 俯冲　 A / D · 左右侧倾", _f_ui, 13, FL_TEXT)
	hs.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hv.add_child(hs)
	var h1 := _label("方向键亦可操纵 · Q / E 方向舵 · Shift 加速 · X 减速 · 空格发射导弹",
		_f_ui, 12, FL_HELP_SPAN)
	h1.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hv.add_child(h1)
	_flight_missile = _label("", _f_num, 12, FL_HELP_MISSILE)
	_flight_missile.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hv.add_child(_flight_missile)
	var h2 := _label("B 无人机 · G / F 返回驾驶 · L 切换光照", _f_ui, 12, FL_HELP_SPAN)
	h2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hv.add_child(h2)
	_root.add_child(_flight_help)
	_flight_panel.visible = false
	_flight_crash.visible = false
	_flight_help.visible = false


## 仪表盘里的一个读数格：dt 小标题 + dd 数值 + 单位小字
## （原版 dt 11px #a0b5bd / dd 26px / small 9px #b6cdc8 margin-left 6px）
func _flight_readout(grid: GridContainer, title: String, unit: String) -> Label:
	var cell := VBoxContainer.new()
	cell.add_theme_constant_override("separation", 5)
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.add_child(cell)
	var dt := _label(title, _spaced(_f_ui, 1.0), 11, FL_DT)
	cell.add_child(dt)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(row)
	var dd := _label("0", _f_num, 26, FL_TEXT)
	row.add_child(dd)
	var u := _label(unit, _spaced(_f_num, 1.0), 9, FL_UNIT)
	row.add_child(u)
	return dd


# ---------------------------------------------------------------------------
# 尺寸 / 布局（原版是 CSS 定位，这里在每次尺寸变化时算一遍，不每帧算）
# ---------------------------------------------------------------------------

## 公开的重新排版入口。
##
## 需要它的原因：HUD 先于 MapUI 建好，_build() 里那次排版去问 MapUI 要小地图
## 位置时，MapUI.setup() 还没跑（minimap_holder 还是 null），请求被丢掉，
## 小地图就永远停在 0×0。main_game 在 maps.setup() 之后再叫一次这里。
func refresh_layout() -> void:
	_on_viewport_resized()


func _on_viewport_resized() -> void:
	if _dial == null:
		return
	var edge := _hud_edge()
	var dial_w := _hud_dial()
	var dial_h := dial_w * 0.9643
	_dial.position = Vector2(_vw() - edge - dial_w, _vh() - 20.0 - dial_h)
	_dial.size = Vector2(dial_w, dial_h)
	_dial_scale = Vector2(dial_w / DIAL_VB.x, dial_h / DIAL_VB.y)

	# 速度读数：inset 29.5% 0 auto，居中
	_speed_label.size = Vector2(dial_w, dial_h * 0.42)
	_speed_label.position = Vector2(0, dial_h * 0.275)
	_kmh_label.size = Vector2(dial_w, dial_h * 0.09)
	_kmh_label.position = Vector2(0, dial_h * 0.275 + dial_h * 0.355)

	_gear_label.position = Vector2(dial_w * 0.20, dial_h - 17.0 - 12.0)
	_gear_label.size = Vector2(40, 12)
	_odo_label.position = Vector2(dial_w * 0.80 - 42.0, dial_h - 17.0 - 12.0)
	_odo_label.size = Vector2(42, 12)
	_odo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	var map := _hud_map()
	# #minimap { bottom: 49px; left: calc(var(--hud-edge) - 10px); }
	if player != null and player.maps != null and player.maps.has_method("set_minimap_rect"):
		player.maps.set_minimap_rect(
			Vector2(edge - 10.0, _vh() - 49.0 - map), Vector2(map, map))

	var card_top := clampf(_vh() * STORY_TOP_RATIO, 170.0, 340.0)
	_story_card.position = Vector2(edge, card_top)
	_story_card.custom_minimum_size = Vector2(STORY_W, 0)
	_layout_invitation(edge)

	_toast_label.position = Vector2(_vw() * 0.5 - 320.0, 120.0)
	_fps_label.position = Vector2(_vw() - edge - 280.0, _vh() - 34.0)
	_quicktips.position = Vector2(0, _vh() - 19.0 - 30.0)
	_quicktips.size = Vector2(_vw(), 30)
	_quicktips.queue_redraw()
	_layout_flight()
	_dial.queue_redraw()


## 飞行三块的定位（原版 CSS 的 left/top/bottom + translateX(-50%)）
func _layout_flight() -> void:
	if _flight_panel == null:
		return
	_flight_panel.position = FL_PANEL_POS
	_flight_panel.custom_minimum_size = Vector2(FL_PANEL_W, 0)
	_flight_panel.size = _flight_panel.get_combined_minimum_size()
	_flight_bar_fill.size = Vector2(FL_BAR_W * _flight_throttle_value, 3.0)

	var crash_sz := _flight_crash.get_combined_minimum_size()
	_flight_crash.size = crash_sz
	_flight_crash.position = Vector2(_vw() * 0.5 - crash_sz.x * 0.5, _vh() * 0.32)

	var help_sz := _flight_help.get_combined_minimum_size()
	_flight_help.size = help_sz
	_flight_help.position = Vector2(_vw() * 0.5 - help_sz.x * 0.5,
		_vh() - 26.0 - help_sz.y)


## 邀请卡：宽高都由内容决定（原版 width:auto + max-width:330px）。
##   top 165px（**不是** clamp，原版就是固定值）· left = --hud-edge · padding 18px 22px
func _layout_invitation(edge: float) -> void:
	if _invitation == null:
		return
	var small_h := float(_f_ui.get_height(10))
	var title_h := float(_f_serif.get_height(21))
	var body_h := float(_f_ui.get_height(11))
	var inner_h := small_h + 12.0 + title_h + 12.0 + body_h     # <strong> margin 12px 0
	# 宽度按**内联内容**量：正文 + 行内 kbd（margin 0 4px）+ 4px，不靠 Label 的
	# 最小宽度 —— autowrap 打开后最小宽度只反映"最长可断片段"，量不出整行宽度。
	var title_w := float(_f_serif.get_string_size(_inv_title.text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 21).x)
	var body_w := float(_f_ui.get_string_size(_inv_body.text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x)
	var ksz := _inv_kbd.get_combined_minimum_size()
	var inline_w := maxf(title_w, body_w + 4.0 + ksz.x)
	var inner_w := minf(INV_MAX_W, inline_w + INV_PAD.x * 2.0) - INV_PAD.x * 2.0
	_inv_box.custom_minimum_size = Vector2(inner_w, inner_h)
	_inv_box.size = Vector2(inner_w, inner_h)
	_inv_small.position = Vector2(0, 0)
	_inv_title.position = Vector2(0, small_h + 12.0)
	var body_y := small_h + 12.0 + title_h + 12.0
	_inv_body.position = Vector2(0, body_y)
	_inv_body.custom_minimum_size = Vector2(inner_w, body_h)
	# 行内 kbd 与正文基线对齐（CSS 的 inline 盒子跟着文字的 baseline 走）
	_inv_kbd.position = Vector2(body_w + 4.0,
		body_y + float(_f_ui.get_ascent(11)) - ksz.y + 3.0)
	_inv_kbd.size = ksz
	_invitation.position = Vector2(edge, INV_TOP)
	_invitation.size = _invitation.get_combined_minimum_size()


# ---------------------------------------------------------------------------
# 每帧更新（原版 HUD 节流 ≈8.3Hz，即 hudTick < 0.12）
# ---------------------------------------------------------------------------

func update_hud(delta: float) -> void:
	if not enabled or player == null:
		return
	_update_wanted(delta)
	_update_combat(delta)
	_toast_timer -= delta
	if _toast_timer <= 0.0 and _toast_label.text != "":
		_toast_label.text = ""

	_hud_tick -= delta
	if _hud_tick > 0.0:
		return
	_hud_tick = 0.12

	var speed := float(player.speed())
	_speed_display = lerpf(_speed_display, absf(speed) * 3.6, 0.35)
	_speed_label.text = "%03d" % int(round(_speed_display))
	_gear_label.text = player.gear_text()
	_odo_label.text = "%.1f KM" % (float(player.odometer()) / 1000.0)

	var pos: Vector2 = player.data_position()
	var area := _area_name(pos)
	# 原版：subtitle = `${areaLabel} · ${mode}`，mode 取 自由驾驶 / 沿途导航 / 步行探索 …
	_subtitle.text = "%s · %s" % [area if area != "" else "深圳湾", _mode_word()]
	# 光照档时钟（原版 writeText(hud.clock, …)：day 14:20 / night 20:10 / 其余 18:25）
	if _clock_label != null:
		_clock_label.text = "%s · 光照 %s（L 切换）" % [GameState.clock_text(), _light_word()]
	# 原版 city-quicktips.ts:183 的模式切换：driving/walking/observer/tank，
	# 飞行中整个快捷条隐藏（quickTips.update({hidden: !!world.flight?.active})）
	var tip_mode := "driving"
	if player.mode == MainGame.Mode.AIRCRAFT or player.is_observer():
		tip_mode = "observer"
	elif player.mode == MainGame.Mode.WALKING:
		tip_mode = "walking"
	elif player.mode == MainGame.Mode.TANK:
		tip_mode = "tank"
	var flying: bool = player.mode == MainGame.Mode.AIRCRAFT
	if _quicktips.visible == flying:
		_quicktips.visible = not flying
	if tip_mode != _tip_mode:
		_tip_mode = tip_mode
		_tip_mode_txt = str(QUICK_LABELS[tip_mode])
		_tip_items = QUICK_TIPS[tip_mode]
		_apply_tip_boxes()
		_quicktips.queue_redraw()

	_update_flight(flying)
	_refresh_story()
	_refresh_invitation()
	# 卡片高度由内容决定，低对比度的左侧强调线跟着它同步
	if _story_bar != null and _story_card != null:
		_story_bar.position = _story_card.position
		_story_bar.size = Vector2(2, _story_card.size.y)

	var q := _top_group.get_child(2) as HBoxContainer
	if q != null:
		var l := q.get_node_or_null("quality-label") as Label
		if l != null:
			l.text = "画质 · %s" % _quality_word()

	if _show_fps:
		var fps := Engine.get_frames_per_second()
		_fps_label.text = "FPS %d · %.1f m/s · %.0f,%.0f" % [fps, speed, pos.x, pos.y]
	_dial.queue_redraw()


## 飞行仪表刷新 —— 原版 city-flight-hud.ts 的 update()。
## 四项读数（空速 / 离地高度 / 航向 / 油门）、油门条、阶段文案、坠毁倒计时、
## 导弹状态，全部按原版公式。
func _update_flight(flying: bool) -> void:
	if _flight_panel == null or player == null:
		return
	# 原版：panel.hidden = menuOpen || !observer.active || photoTarget?.id==='car'
	# 本版没有菜单打开态与看车镜头，等价条件就是"处于飞行模式且飞机确实在飞"。
	# ⚠️ has_method 返回 Variant，`var show :=` 会推断失败（无头实跑抓到）
	var show: bool = flying and player.has_method("flight_hud_state")
	_flight_panel.visible = show
	_flight_help.visible = show
	if not show:
		_flight_crash.visible = false
		return
	var s: Dictionary = player.flight_hud_state()
	var live := bool(s.get("active", false))
	_flight_panel.visible = live
	_flight_help.visible = live
	if not live:
		_flight_crash.visible = false
		return

	var phase := str(s.get("phase", ""))
	_flight_speed.text = "%d" % int(round(float(s.get("speed", 0.0)) * 3.6))
	_flight_alt.text = "%d" % int(round(float(s.get("altitude", 0.0))))
	# 原版 String(Math.round((yaw*180/PI%360+360)%360)).padStart(3,'0')
	#
	# ⚠️ 两个坑（开窗截图肉眼看到 "航向 -99°" 才发现的）：
	#   ① GDScript 的 `%` 是**截断求余**，负数会返回负数（−99 % 360 = −99），
	#      不像 JS 的 `%` 也返回负数但原版随后又 +360 再 %360 归正了；
	#      这里用 fposmod 一次归到 [0,360)。
	#   ② 原版是先归正、再 round，所以 359.6° 会显示成 "000°" 而不是 "360°"。
	var heading := int(round(fposmod(rad_to_deg(float(s.get("yaw", 0.0))), 360.0)))
	_flight_heading.text = "%03d°" % heading
	var th := clampf(float(s.get("throttle", 0.0)), 0.0, 1.0)
	_flight_throttle.text = "%d" % int(round(th * 100.0))
	_flight_throttle_value = th
	_flight_bar_fill.size = Vector2(FL_BAR_W * th, 3.0)
	_flight_phase.text = "飞行中断" if phase == "exploding" else "辅助平飞 · 松开按键自动回正"

	# 坠毁倒计时：原版 Math.max(1, Math.ceil((FLIGHT_RECOVERY_MS-(now-crashedAt))/1000))
	_flight_crash.visible = phase == "exploding"
	if _flight_crash.visible:
		var left_ms := float(s.get("recovery_ms", 3000)) \
			- float(Time.get_ticks_msec() - int(s.get("crashed_at", 0)))
		_flight_crash_span.text = "%d 秒后返回无人机" % maxi(1, int(ceil(left_ms / 1000.0)))

	# 导弹状态（原版 .flight-missile-status）
	var ms: Dictionary = s.get("missiles", {})
	var cd := float(ms.get("cooldown", 0.0))
	if phase == "exploding":
		_flight_missile.text = ""
	elif cd > 0.05:
		_flight_missile.text = "导弹装填 %.1f 秒" % cd
	else:
		_flight_missile.text = "导弹就绪 · 按住空格连续发射"


## 原版 city-graphics-panel 的档位中文名
func _quality_word() -> String:
	match GraphicsQuality.tier():
		"low": return "低"
		"high": return "高"
	return "中"


## 原版 city-hud.ts 的 mode 文案
func _mode_word() -> String:
	if player.is_observer():
		return "无人机观景"
	if player.has_route():
		return "沿途导航"
	return "自由驾驶"


## 光照档名（与 main_game._light_mode_name 一致）
func _light_word() -> String:
	match GameState.light_mode:
		GameContent.LightMode.DAY:
			return "晴日"
		GameContent.LightMode.NIGHT:
			return "夜色"
	return "日落"


func _refresh_story() -> void:
	# .story-hud 的三段：`<small>城市故事</small><strong>标题</strong><span>目标</span>`
	# 对应原版 city-story-experience.ts:148 的 hud.innerHTML。
	#
	# 原版这个位置其实有**两种**形态（city-story.css）：
	#   .story-entry —— 剧情还没开始：第三段是**梗概**（synopsis），内边距 11px 14px，
	#                   整块是按钮，点一下进故事。出生点看到的就是这一版。
	#   .story-hud   —— 剧情进行中：第三段是当前目标，内边距 14px 15px。
	var title := ""
	var body := ""
	var entry := false
	if player != null and player.story != null:
		var st: Dictionary = player.story.status()
		title = str(st.get("title", "最后一单"))
		if bool(st.get("completed", false)):
			# city-story-experience.ts:143 —— 完成后第三段换成这句
			body = "已完成 · 奖励不会重复发放"
			entry = true
		elif not player.story.active:
			body = str(st.get("synopsis", ""))
			entry = true
		else:
			# 步骤不再有静态 text 字段（改为原版的 lines/objective），
			# 卡片这里显示 objective —— 它本来就是给玩家看的"下一步做什么"
			var step: Dictionary = player.story.current_step()
			body = str(step.get("objective", ""))
	if title == "":
		# 故事跑完就退回合约/自由驾驶，卡片不留空
		var c: Dictionary = player.career.status() if player.career != null else {}
		title = str(c.get("contract", ""))
		if title == "":
			title = "自由驾驶"
			body = "沿着这座城市，慢慢开。"
	if body == "" and player != null:
		body = str(player.route_text())
	_story_title.text = title
	_story_body.text = body
	_set_story_pad(entry)


## 入口卡与剧情卡的内边距切换（只在实际变化时改 StyleBox）
func _set_story_pad(entry: bool) -> void:
	var want := STORY_ENTRY_PAD if entry else STORY_HUD_PAD
	if _story_pad == want:
		return
	_story_pad = want
	var sb := _story_card.get_theme_stylebox("panel") as StyleBoxFlat
	if sb == null:
		return
	sb.content_margin_left = want.x
	sb.content_margin_right = want.x
	sb.content_margin_top = want.y
	sb.content_margin_bottom = want.y


func toast(text: String, seconds := 3.0) -> void:
	_toast_label.text = text
	_toast_timer = seconds


func toggle_fps() -> void:
	set_fps_visible(not _show_fps)


func set_fps_visible(v: bool) -> void:
	_show_fps = v
	_fps_label.visible = v


func is_fps_visible() -> bool:
	return _show_fps


func toggle_tips() -> void:
	_quicktips.visible = not _quicktips.visible


# ---------------------------------------------------------------------------
# 速度表盘（createDial 的逐项移植）
# ---------------------------------------------------------------------------

func _dial_pt(deg: float, radius: float) -> Vector2:
	var a := deg_to_rad(deg)
	# 原版 dialPoint：x = 140 + sin(a)·r，y = 136 − cos(a)·r
	return Vector2(DIAL_CENTER.x + sin(a) * radius, DIAL_CENTER.y - cos(a) * radius)


func _draw_dial() -> void:
	var s := _dial_scale
	var start := DIAL_START_DEG
	var end := DIAL_START_DEG + DIAL_SWEEP_DEG

	# 外弧（dial-track，1.15px）
	_draw_arc_path(start, end, DIAL_R, DIAL_TRACK, 1.15 * s.x)
	# 内圈（dial-inner-ring，0.6px，r=111）
	_draw_arc_path(start, end, 111.0, DIAL_INNER, 0.6 * s.x)
	# 限速弧（dial-limit，5px，118°→128°）
	_draw_arc_path(118.0, 128.0, DIAL_R, DIAL_LIMIT, 5.0 * s.x)

	# 41 根刻度：i%8==0 为主刻度
	for i in 41:
		var t := float(i) / 40.0
		var angle := start + t * DIAL_SWEEP_DEG
		var major := i % 8 == 0
		var a := _dial_pt(angle, 112.0) * s
		var b := _dial_pt(angle, 102.0 if major else 108.0) * s
		var col := DIAL_TICK_MAJOR if major else DIAL_TICK
		_dial.draw_line(a, b, col, (1.0 if major else 0.75) * s.x, true)
		if major:
			var p := _dial_pt(angle, 94.0) * s
			var txt := str(i * 5)
			var w := _f_dial_label.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 7)
			_dial.draw_string(_f_dial_label, p - Vector2(w.x * 0.5, -2.0),
				txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 7, DIAL_LABEL)

	# 进度弧（dial-progress，白色 4px）
	var frac := clampf(_speed_display / DIAL_MAX_SPEED, 0.0, 1.0)
	if frac > 0.001:
		_draw_arc_path(start, start + DIAL_SWEEP_DEG * frac, DIAL_R, Color(0.988, 0.988, 0.965), 4.0 * s.x)

	# 指针：(140,11)-(140,22) 绕 (140,136) 旋转
	var needle_angle := start + DIAL_SWEEP_DEG * frac
	var rot := deg_to_rad(needle_angle)
	var n0 := DIAL_CENTER + Vector2(0, 11 - 136).rotated(rot)
	var n1 := DIAL_CENTER + Vector2(0, 22 - 136).rotated(rot)
	_dial.draw_line(n0 * s, n1 * s, Color.WHITE, 2.0 * s.x, true)

	# 能量圈 + 闪电（cx140 cy231 r16）
	var pc := Vector2(140.0, 231.0) * s
	var pr := 16.0 * s.x
	_dial.draw_circle(pc, pr, DIAL_POWER_RING)
	_dial.draw_arc(pc, pr, 0.0, TAU, 24, DIAL_POWER_EDGE, 0.7 * s.x, true)
	# 原版 path：M 143.5 219 L 133 233 L 139 233 L 136.5 243 L 148 228 L 142 228 Z
	var bolt := PackedVector2Array([
		Vector2(143.5, 219.0), Vector2(133.0, 233.0), Vector2(139.0, 233.0),
		Vector2(136.5, 243.0), Vector2(148.0, 228.0), Vector2(142.0, 228.0),
	])
	var bp := PackedVector2Array()
	for v in bolt:
		bp.append(v * s)
	_dial.draw_colored_polygon(bp, DIAL_POWER)


## 把 SVG 的 A 弧命令换成 Godot 的 draw_arc（圆心/半径/起止角），
## 角度换算：SVG 的 0° 指向 −y，顺时针为正 → Godot 弧度直接用同一套
## （Godot 的 y 轴也向下），所以 theta = deg_to_rad(deg - 90)。
func _draw_arc_path(from_deg: float, to_deg: float, radius: float, color: Color, width: float) -> void:
	var c := DIAL_CENTER * _dial_scale
	var r := radius * _dial_scale.x
	_dial.draw_arc(c, r, deg_to_rad(from_deg - 90.0), deg_to_rad(to_deg - 90.0),
		maxi(8, int(absf(to_deg - from_deg) / 2.0)), color, width, true)


# ---------------------------------------------------------------------------
# 快捷键条（city-quicktips.css）
# ---------------------------------------------------------------------------

## 模式切换时更新键位小方块的文字（_tip_boxes 只建了最大条目数个，
## 末尾那个是「? 操作」常驻块，不能覆盖）
func _apply_tip_boxes() -> void:
	var total := _tip_boxes.size()
	var q_index := total - 1
	for i in total:
		if i == q_index:
			continue
		var box: PanelContainer = _tip_boxes[i]
		if i < _tip_items.size():
			(box.get_child(0) as Label).text = str(_tip_items[i]["key"])
			box.visible = true
		else:
			box.visible = false


func _draw_quicktips() -> void:
	if _tip_boxes.is_empty():
		return
	var mode_size := 9
	var item_size := 10
	var gap := 17.0        ## .city-quicktips ul { gap: 17px }
	var item_gap := 5.0    ## .city-quicktips li { gap: 5px }
	var line_h := 30.0     ## .city-quicktips-line { min-height: 30px }
	var mode_txt := _tip_mode_txt  ## 原版 LABELS[mode]，随模式切换

	# ---- 量宽 ----
	var mode_w := _f_dial_label.get_string_size(mode_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, mode_size).x
	var total := mode_w + 2.0 + 16.0
	var item_w: Array = []
	var item_txt_w: Array = []
	for i in _tip_items.size():
		var k: PanelContainer = _tip_boxes[i]
		var ksz := k.get_combined_minimum_size()
		var lw := _f_dial_label.get_string_size(str(_tip_items[i]["label"]),
			HORIZONTAL_ALIGNMENT_LEFT, -1, item_size).x
		item_w.append(ksz.x)
		item_txt_w.append(lw)
		total += ksz.x + item_gap + lw + gap
	var q_k: PanelContainer = _tip_boxes[_tip_boxes.size() - 1]
	var q_ksz := q_k.get_combined_minimum_size()
	var q_txt_w := _f_dial_label.get_string_size("操作", HORIZONTAL_ALIGNMENT_LEFT, -1, item_size).x
	# 分隔线前是 gap 的间隔，按钮本身是 padding-left 13px
	total += 13.0 + q_ksz.x + item_gap + q_txt_w

	var sz := _quicktips.size
	var x0 := (sz.x - total) * 0.5
	# ⚠️ y 是**控件内**坐标，条带本身占满控件高度（0 → line_h）。
	# 早期这里写成 `var y := sz.y`，等于又把控件高度加了一遍，
	# 整条快捷提示被推到屏幕外，只在上边缘露出半行。
	var y := 0.0
	var mid := y + line_h * 0.5

	# ---- 背景条：linear-gradient(90deg, #08151d00, #08151d47 20%, #08151d47 80%, #08151d00) ----
	var bar_x := x0 - 9.0
	var bar_w := total + 18.0
	var seg := 32
	for i in seg:
		var a := _tip_alpha(float(i) / float(seg))
		var b := _tip_alpha(float(i + 1) / float(seg))
		var c := Color(TIP_BG_B.r, TIP_BG_B.g, TIP_BG_B.b, (a + b) * 0.5)
		_quicktips.draw_rect(Rect2(bar_x + bar_w * float(i) / float(seg), y,
			bar_w / float(seg) + 0.5, line_h), c)

	# ---- 模式标签（.city-quicktips-mode: 9px / letter-spacing .12em / #b8d7c596）----
	var tx := x0
	_quicktips.draw_string(_spaced(_f_tip, mode_size * 0.12), Vector2(tx, mid + 3.0),
		mode_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, mode_size, TIP_MODE)
	tx += mode_w + 2.0 + 16.0

	# ---- 键位块 + 说明 ----
	for i in _tip_items.size():
		var k: PanelContainer = _tip_boxes[i]
		var ksz := Vector2(item_w[i], k.get_combined_minimum_size().y)
		k.position = Vector2(tx, y + (line_h - ksz.y) * 0.5)
		k.size = ksz
		k.visible = true
		tx += ksz.x + item_gap
		_quicktips.draw_string(_f_dial_label, Vector2(tx, mid + 3.5),
			str(_tip_items[i]["label"]), HORIZONTAL_ALIGNMENT_LEFT, -1, item_size, TIP_TEXT)
		tx += float(item_txt_w[i]) + gap

	# ---- 分隔竖线（border-left: 1px solid #e4eade26）+ `? 操作` ----
	_quicktips.draw_line(Vector2(tx - gap * 0.5, y + 6.0),
		Vector2(tx - gap * 0.5, y + line_h - 6.0), Color(0.894, 0.918, 0.871, 0.149), 1.0, true)
	q_k.position = Vector2(tx + 13.0, y + (line_h - q_ksz.y) * 0.5)
	q_k.size = q_ksz
	q_k.visible = true
	_quicktips.draw_string(_f_dial_label, Vector2(tx + 13.0 + q_ksz.x + item_gap, mid + 3.5),
		"操作", HORIZONTAL_ALIGNMENT_LEFT, -1, item_size, TIP_TOGGLE)


func _tip_alpha(t: float) -> float:
	# 0 → 0；0.2 → 0.278；0.8 → 0.278；1 → 0
	if t <= 0.2:
		return TIP_BG_B.a * (t / 0.2)
	if t >= 0.8:
		return TIP_BG_B.a * ((1.0 - t) / 0.2)
	return TIP_BG_B.a


# ---------------------------------------------------------------------------
# 片区名（HUD 以 ~8.3Hz 刷新，而 all_landmarks() 是上千条的地标表）
# ---------------------------------------------------------------------------

func _area_name(pos: Vector2) -> String:
	if world == null:
		return ""
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
