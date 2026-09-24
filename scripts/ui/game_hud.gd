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
		{"key": "拖动", "label": "看向"}, {"key": "F", "label": "上车"},
		{"key": "E", "label": "互动"},
	],
	"observer": [
		{"key": "WASD", "label": "平移"}, {"key": "Q E", "label": "升降"},
		{"key": "拖动", "label": "环绕"}, {"key": "B", "label": "飞机"},
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
	_build_topright()
	_build_story_card()
	_build_invitation()
	_build_dial()
	_build_quicktips()

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
	_dial.queue_redraw()


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
			var step: Dictionary = player.story.current_step()
			body = str(step.get("text", ""))
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
