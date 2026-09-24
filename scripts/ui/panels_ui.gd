extends CanvasLayer
class_name PanelsUI
##
## 面板组 —— 城市手账（J）、画质调节、加载画面、对话。
## 对应原版 city-career.css 的 #life-journal、city-graphics-panel.ts、city-loading.ts、
## story-dialog。
##
## 手账内容：身份 / 等级 / XP / 品质 / 关系（0–20）/ 升级 / 已完成合约 / 可接合约。

var world: CityWorld
var player = null
var career: CareerSystem
var story: StorySystem

var journal: Control
var loading: Control
var dialog: Control

var journal_visible := false
var dialog_active := false
var _dialog_options: Array = []
var _dialog_kind := ""

# --- 加载画面（对应原版 city-loading.ts 的状态机）-----------------------------
enum LoadState { LOADING, READY, ERROR, LEAVING }
var _loading_state: int = LoadState.LOADING
var _loading_target := 0.0        ## 目标进度（来自 CityWorld 的真实构建比例）
var _loading_shown := 0.0         ## 显示进度（向目标平滑逼近）
var _loading_built := false
var _loading_stage := 0           ## 当前阶段下标 0–16
var _loading_note := ""           ## CityWorld 上报的阶段说明（进阶诊断用）

var _lr: Control                  ## 加载画面根（full rect）
var _l_poster: TextureRect
var _l_film: VideoStreamPlayer    ## 原版预录的陶土城环绕动画（.city-loader-film）
var _l_vignette: ColorRect
var _l_top_left: Label
var _l_top_right: Label
var _l_title: Control             ## 标题块（整体做进入动画）
var _l_edition: Label
var _l_h1: Label
var _l_rule: ColorRect
var _l_lede: Label
var _l_districts: Control
var _l_group: Label
var _l_status: Label
var _l_num: Label
var _l_unit: Label
var _l_bar_bg: ColorRect
var _l_bar_fill: TextureRect
var _l_bar_glows: Array = []
var _l_count: Label
var _l_basis: Label
var _l_failure: Control
var _l_failure_text: Label
var _l_retry: PanelContainer
var _fonts := {}


## 加载界面必须在**城市构建之前**就建好。
## 之前的写法把 _build() 整个放进 setup()，而 setup() 是 _on_built()（城市构建完成）
## 之后才调的 —— 于是整个加载阶段 `loading` 都是 null，show_loading() /
## set_loading_progress() 全部空转，玩家看到的是一片黑屏。
func _ready() -> void:
	layer = 12
	_build_loading()
	show_loading()


func setup(p_world: CityWorld, p_player, p_career: CareerSystem, p_story: StorySystem) -> void:
	world = p_world
	player = p_player
	career = p_career
	story = p_story
	layer = 12
	_build()


func _font(size: int) -> Font:
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["Microsoft YaHei", "微软雅黑", "SimHei",
		"PingFang SC", "Noto Sans CJK SC", "sans-serif"])
	sf.allow_system_fallback = true
	# SystemFont 没有 font_size 属性（那是 Label 的主题字号），删掉
	# 由 add_theme_font_size_override / Label3D.font_size 控制
	return sf


func _panel(title: String, size: Vector2, pos: Vector2) -> Dictionary:
	var c := Control.new()
	c.set_anchors_preset(Control.PRESET_TOP_LEFT)
	c.position = pos
	c.size = size
	c.visible = false
	add_child(c)
	var bg := ColorRect.new()
	bg.color = Color(0.045, 0.055, 0.075, 0.94)
	bg.size = size
	c.add_child(bg)
	var border := ColorRect.new()
	border.color = Color(0.28, 0.32, 0.38, 0.9)
	border.size = Vector2(size.x, 2)
	c.add_child(border)
	var t := Label.new()
	t.add_theme_font_override("font", _font(28))
	t.add_theme_color_override("font_color", Color(0.96, 0.94, 0.88))
	t.text = title
	t.position = Vector2(22, 16)
	c.add_child(t)
	var body := Label.new()
	body.add_theme_font_override("font", _font(18))
	body.add_theme_color_override("font_color", Color(0.88, 0.91, 0.94))
	body.position = Vector2(22, 62)
	body.size = size - Vector2(44, 84)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	c.add_child(body)
	return {"root": c, "title": t, "body": body}


func _build() -> void:
	if not _loading_built:
		_build_loading()
	journal = _panel("城市手账 · J 关闭", Vector2(720, 620), Vector2(600, 180))["root"]
	journal_body = journal.get_child(3)

	_build_settings()

	# 对话
	dialog = Control.new()
	dialog.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	dialog.position = Vector2(-460, -280)
	dialog.size = Vector2(920, 220)
	dialog.visible = false
	add_child(dialog)
	var dbg := ColorRect.new()
	dbg.color = Color(0.05, 0.06, 0.08, 0.95)
	dbg.size = Vector2(920, 220)
	dialog.add_child(dbg)
	dialog_body = Label.new()
	dialog_body.add_theme_font_override("font", _font(22))
	dialog_body.add_theme_color_override("font_color", Color(0.95, 0.94, 0.90))
	dialog_body.position = Vector2(28, 24)
	dialog_body.size = Vector2(864, 100)
	dialog_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dialog.add_child(dialog_body)
	dialog_options = Label.new()
	dialog_options.add_theme_font_override("font", _font(20))
	dialog_options.add_theme_color_override("font_color", Color(0.92, 0.84, 0.60))
	dialog_options.position = Vector2(28, 130)
	dialog_options.size = Vector2(864, 80)
	dialog_options.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dialog.add_child(dialog_options)


var journal_body: Label
var dialog_body: Label
var dialog_options: Label


# ---------------------------------------------------------------------------
# 加载画面 —— 逐项移植原版 src/city-loading.ts + city-loading.css
#
# 版式全部取 CSS 的实测数值（1920×1124 视口）：
#   底 #e8eae5 ／ --loader-mint #436d67 ／ --loader-paper #243a3e
#   海报 cover + object-position 60% 50%，其上两层渐变暗角
#     （见 shaders/loading_vignette.gdshader，色标位置与 alpha 逐值换算）
#   顶栏 top 5.4% · left/right 6.1%（10px / ls .23em / #526967）
#   标题块 left 11% · top 27%
#     edition 10px / ls .35em / #55756d
#     h1       衬线 clamp(65px,7.4vw,122px) / lh 1.3 / ls .21em / #233b3e
#     分隔线   42×1 #758e84，上下各 27px
#     正文     衬线 clamp(15px,1.5vw,23px) / lh 1.9 / ls .17em / #3f5655
#     片区行   margin-top 28px，10px / ls .19em / #617570，间隔 16×1 #95a69a
#   底部块 left 11% · right 8% · bottom 9.5%，进度块宽 min(660px,61%)
#     group  9px / ls .24em / #436d67
#     status 上边距 8px、12px / lh 1.7 / #304948
#     百分比 DIN 39px / ls -.035em / lh .9 / #243a3e，单位 10px / #617570，间隔 5px
#     进度条 高度 2px，底 #667f7133，填充 90deg #396b65→#698a73(70%)→#a78d5b，
#            光晕 0 0 9px #a6d7bd52
#     阶段行 margin-top 11px，9px / ls .12em / #5a7068
#   进入动画 1.2s（opacity 0→1 + translateY 12→0）；离场 0.7s 淡出
#
# 进度语义照搬原版 update()：completion = (stageIndex + stageFraction) / 17。
# 原版注释写明这套阶段**不是**在测量下载字节数；本移植把 stageIndex /
# stageFraction 由 CityWorld 的真实构建比例换算，于是既保留原版 17 段文案与
# 「阶段 NN / 17」计数，进度条又贴着真实工作量走（大件 GLB 卡住时百分比照样停）。
# ---------------------------------------------------------------------------

const POSTER_PATH := "res://data/city/loading/bamboo-clay-poster.jpg"
const FILM_PATH := "res://data/city/loading/bamboo-clay-loop.ogv"
const VIGNETTE_SHADER := "res://shaders/loading_vignette.gdshader"

## 原版 CITY_LOADING_STAGES（id / label / group），顺序与文案逐字照搬。
const LOADING_STAGES := [
	{"id": "map", "label": "正在展开深圳地图", "group": "城市骨架"},
	{"id": "ridges", "label": "正在展开深圳山脊", "group": "城市骨架"},
	{"id": "relief", "label": "正在铺设公园缓坡", "group": "城市骨架"},
	{"id": "bridges", "label": "正在架设跨水桥梁", "group": "城市骨架"},
	{"id": "coast", "label": "正在铺设海岸线和城市道路", "group": "海岸与天际线"},
	{"id": "buildings", "label": "正在载入南山、福田、罗湖建筑", "group": "海岸与天际线"},
	{"id": "landmarks", "label": "正在装配深圳地标", "group": "海岸与天际线"},
	{"id": "signage", "label": "正在点亮城市招牌", "group": "海岸与天际线"},
	{"id": "vehicle", "label": "正在启动你的车", "group": "路上的生活"},
	{"id": "landscape", "label": "正在种植榕树、棕榈与花境", "group": "路上的生活"},
	{"id": "furniture", "label": "正在布置城市座椅", "group": "路上的生活"},
	{"id": "lighting", "label": "正在调试海湾的光与倒影", "group": "光与倒影"},
	{"id": "puddles", "label": "雨停了，正在铺设路边积水", "group": "光与倒影"},
	{"id": "navigation", "label": "正在连接城市导航", "group": "准备出发"},
	{"id": "life-sites", "label": "正在打开沿途生活", "group": "准备出发"},
	{"id": "interface", "label": "正在准备驾驶界面", "group": "准备出发"},
	{"id": "experience", "label": "正在准备你的城市生活", "group": "准备出发"},
]

const LOADER_PAPER := Color(0.141, 0.227, 0.243)      ## #243a3e
const LOADER_MINT := Color(0.263, 0.427, 0.404)       ## #436d67
const LOADER_STATUS_C := Color(0.188, 0.286, 0.282)   ## #304948
const LOADER_READY_C := Color(0.212, 0.373, 0.314)    ## #365f50（data-state=ready）
const LOADER_ERROR_C := Color(0.608, 0.294, 0.192)    ## #9b4b31

## 进度条底槽 / 填充（city-loading.css 的 .city-loader-progress）
const BAR_BG_C := Color(0.400, 0.498, 0.443, 0.200)   ## #667f7133
const BAR_C0 := Color8(57, 107, 101)                  ## #396b65
const BAR_C1 := Color8(105, 138, 115)                 ## #698a73
const BAR_C2 := Color8(167, 141, 91)                  ## #a78d5b

var _l_bar_x := 0.0
var _l_bar_y := 0.0
var _l_bar_w := 0.0
var _title_tween: Tween
var _film_tween: Tween


func _sys_font(key: String, candidates: Array) -> Font:
	if _fonts.has(key):
		return _fonts[key]
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(candidates)
	sf.allow_system_fallback = true
	_fonts[key] = sf
	return sf


func _ui_font() -> Font:
	return _sys_font("ui", ["PingFang SC", "Microsoft YaHei", "微软雅黑",
		"Noto Sans SC", "SimHei", "sans-serif"])


func _serif_font() -> Font:
	return _sys_font("serif", ["Songti SC", "Noto Serif SC", "STSong",
		"SimSun", "宋体", "serif"])


func _num_font() -> Font:
	return _sys_font("num", ["DIN Alternate", "Arial Narrow", "Helvetica Neue",
		"Arial", "sans-serif"])


## CSS letter-spacing → FontVariation.spacing_glyph（Label 没有字距属性）
func _spaced(base: Font, px: float) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = base
	fv.spacing_glyph = int(round(px))
	return fv


## CSS 行高的半行距换算。
## CSS 的 content box 高度 = line-height，字形盒（ascent+descent）在其中居中：
##   half_leading = (line-height − 字形盒高) / 2，基线 = 盒顶 + half_leading + ascent。
## 返回 (盒高, 基线相对盒顶的偏移)；字号大、line-height < 1 时 half_leading 为负，
## 字形会上溢，这正是原版 h1（lh 1.3）与百分比（lh .9）的排布方式。
func _css_line(base: Font, size: int, ratio: float) -> Vector2:
	var natural := float(base.get_height(size))
	var box := ratio * float(size)
	return Vector2(box, (box - natural) * 0.5 + float(base.get_ascent(size)))


func _mk_label(text: String, font: Font, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _build_loading() -> void:
	if _loading_built:
		return
	_loading_built = true

	_lr = Control.new()
	_lr.name = "LoadingScreen"
	_lr.set_anchors_preset(Control.PRESET_FULL_RECT)
	# 加载期吃掉鼠标事件（原版是在 window 捕获阶段拦下 keydown / keyup）
	_lr.mouse_filter = Control.MOUSE_FILTER_STOP
	_lr.clip_contents = true
	add_child(_lr)
	loading = _lr   # 兼容既有接口（diagnostics / visible / show_loading）

	# --- 海报底图（.city-loader-poster：object-fit cover，位置 60% 50%）--------
	_l_poster = TextureRect.new()
	_l_poster.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_l_poster.stretch_mode = TextureRect.STRETCH_SCALE
	_l_poster.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(POSTER_PATH):
		_l_poster.texture = load(POSTER_PATH)
	_lr.add_child(_l_poster)

	# --- 影片（.city-loader-film：原版预录的「春笋 · 冷暖光影环绕」3D 动画）----
	# 原版用 <video muted loop playsinline> 盖在海报上（data-film=playing 时
	# 0.8s 淡入），播的是 24s 的陶土城相机环绕。Godot 原生只认 Theora，
	# 所以素材转成了同码率的 .ogv（bamboo-clay-loop.ogv，1920×1080/30fps/24s）。
	# 若素材缺失或解码失败，VideoStreamPlayer 就是透明的 —— 海报自动兜底，
	# 与原版 poster 之下、film 之上的降级顺序一致。
	_l_film = VideoStreamPlayer.new()
	_l_film.name = "loading-film"
	_l_film.expand = true                       # 拉伸到控件矩形（cover 矩形由布局算）
	_l_film.loop = true                         # 原版 <video loop>
	_l_film.volume_db = -80.0                   # 原版 muted（源片本就无音轨）
	_l_film.autoplay = false
	_l_film.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_l_film.modulate.a = 0.0                    # .city-loader-film{opacity:0}
	if FileAccess.file_exists(FILM_PATH):
		# 不能用 ResourceLoader.exists 判断 —— .ogv 不走导入缓存时它返回 false；
		# VideoStreamTheora 在播放时用 FileAccess 直接读 res:// 源文件。
		var stream := VideoStreamTheora.new()
		stream.file = FILM_PATH
		_l_film.stream = stream
	else:
		push_warning("[PanelsUI] 缺少加载影片 %s，加载画面只用海报" % FILM_PATH)
	_lr.add_child(_l_film)

	# --- 暗角（.city-loader-vignette：两层 linear-gradient）--------------------
	_l_vignette = ColorRect.new()
	_l_vignette.color = Color.WHITE
	_l_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(VIGNETTE_SHADER):
		var mat := ShaderMaterial.new()
		mat.shader = load(VIGNETTE_SHADER)
		_l_vignette.material = mat
	_lr.add_child(_l_vignette)

	# --- 顶栏 ------------------------------------------------------------------
	_l_top_left = _mk_label("SHENZHEN / OPEN ROADS",
		_spaced(_sys_font("helv", ["Helvetica Neue", "Arial", "sans-serif"]), 2.3),
		10, Color(0.322, 0.412, 0.404))
	_lr.add_child(_l_top_left)
	_l_top_right = _mk_label("一座城市 · 无数种生活", _spaced(_ui_font(), 2.1),
		10, Color(0.322, 0.412, 0.404))
	_lr.add_child(_l_top_right)

	# --- 标题块 ----------------------------------------------------------------
	_l_title = Control.new()
	_l_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lr.add_child(_l_title)

	_l_edition = _mk_label("城市漫游", _spaced(_ui_font(), 3.5), 10,
		Color(0.333, 0.459, 0.427))                                   ## #55756d
	_l_edition.position = Vector2.ZERO
	_l_title.add_child(_l_edition)

	_l_h1 = _mk_label("深城纪", _spaced(_serif_font(), 0.21), 100,
		Color(0.137, 0.231, 0.243))                                   ## #233b3e
	_l_h1.add_theme_color_override("font_shadow_color", Color(1, 1, 1, 0.4))
	_l_h1.add_theme_constant_override("shadow_offset_x", 0)
	_l_h1.add_theme_constant_override("shadow_offset_y", 1)
	_l_h1.add_theme_constant_override("shadow_outline_size", 16)
	_l_title.add_child(_l_h1)

	_l_rule = ColorRect.new()
	_l_rule.color = Color(0.459, 0.557, 0.518)                    ## #758e84
	_l_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_l_rule.size = Vector2(42, 1)
	_l_title.add_child(_l_rule)

	_l_lede = _mk_label("把下班后的时间，\n还给这座城市。",
		_spaced(_serif_font(), 0.17), 20, Color(0.247, 0.337, 0.333))  ## #3f5655
	_l_title.add_child(_l_lede)

	_l_districts = Control.new()
	_l_districts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_l_title.add_child(_l_districts)
	for i in 5:
		if i % 2 == 0:
			var d := _mk_label(["南山", "福田", "罗湖"][i / 2], _spaced(_ui_font(), 1.9),
				10, Color(0.380, 0.459, 0.439))                    ## #617570
			_l_districts.add_child(d)
		else:
			var dash := ColorRect.new()
			dash.color = Color(0.584, 0.651, 0.604)                ## #95a69a
			dash.size = Vector2(16, 1)
			dash.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_l_districts.add_child(dash)

	# --- 底部进度块 ------------------------------------------------------------
	_l_group = _mk_label(LOADING_STAGES[0]["group"], _spaced(_ui_font(), 2.4), 9, LOADER_MINT)
	_lr.add_child(_l_group)

	_l_status = _mk_label("正在启动城市", _spaced(_ui_font(), 1.1), 12, LOADER_STATUS_C)
	_l_status.add_theme_constant_override("line_spacing", 8)
	_lr.add_child(_l_status)

	_l_num = _mk_label("0", _spaced(_num_font(), -1.4), 39, LOADER_PAPER)
	_lr.add_child(_l_num)
	_l_unit = _mk_label("%", _sys_font("helv", ["Arial", "Helvetica Neue", "sans-serif"]),
		10, Color(0.380, 0.459, 0.439))                            ## #617570
	_lr.add_child(_l_unit)

	_l_bar_bg = ColorRect.new()
	_l_bar_bg.color = BAR_BG_C
	_l_bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lr.add_child(_l_bar_bg)

	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.7, 1.0])
	grad.colors = PackedColorArray([BAR_C0, BAR_C1, BAR_C2])
	var gtex := GradientTexture1D.new()
	gtex.gradient = grad
	gtex.width = 256

	# 光晕：box-shadow 0 0 9px #a6d7bd52。Godot 没有 2D 模糊，
	# 用两层同渐变、低透明度的铺底近似（先画大的一层，再画小的一层）。
	for i in 2:
		var glow := TextureRect.new()
		glow.texture = gtex
		glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		glow.stretch_mode = TextureRect.STRETCH_SCALE
		glow.modulate = Color(1, 1, 1, 0.10 if i == 0 else 0.16)
		glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_lr.add_child(glow)
		_l_bar_glows.append(glow)

	_l_bar_fill = TextureRect.new()
	_l_bar_fill.texture = gtex
	_l_bar_fill.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_l_bar_fill.stretch_mode = TextureRect.STRETCH_SCALE
	_l_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lr.add_child(_l_bar_fill)

	_l_count = _mk_label("阶段 01 / %d" % LOADING_STAGES.size(),
		_spaced(_ui_font(), 1.1), 9, Color(0.353, 0.439, 0.408))    ## #5a7068
	_lr.add_child(_l_count)
	_l_basis = _mk_label("按已完成阶段推进", _spaced(_ui_font(), 1.1), 9,
		Color(0.353, 0.439, 0.408))
	_lr.add_child(_l_basis)

	# --- 失败态（.city-loader-failure）-----------------------------------------
	_l_failure = Control.new()
	_l_failure.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_l_failure.visible = false
	_lr.add_child(_l_failure)

	_l_failure_text = _mk_label("", _ui_font(), 12, LOADER_ERROR_C)
	_l_failure_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_l_failure.add_child(_l_failure_text)

	_l_retry = PanelContainer.new()
	var rsb := StyleBoxFlat.new()
	rsb.bg_color = Color(0.416, 0.533, 0.459, 0.078)              ## #6a887514
	rsb.border_color = Color(0.439, 0.549, 0.459, 0.502)          ## #708c7580
	rsb.set_border_width_all(1)
	rsb.set_corner_radius_all(2)
	rsb.content_margin_left = 15.0
	rsb.content_margin_right = 15.0
	rsb.content_margin_top = 10.0
	rsb.content_margin_bottom = 10.0
	_l_retry.add_theme_stylebox_override("panel", rsb)
	_l_retry.mouse_filter = Control.MOUSE_FILTER_STOP
	var retry_l := _mk_label("重新载入   ↗", _spaced(_ui_font(), 1.3), 12, LOADER_STATUS_C)
	_l_retry.add_child(retry_l)
	_l_retry.gui_input.connect(_on_retry_input)
	_l_failure.add_child(_l_retry)

	get_viewport().size_changed.connect(_layout_loading)
	_layout_loading()
	set_process(true)


## 失败态的「重新载入」：对应原版 retryAction → options.onRetry ?? location.reload()
func _on_retry_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			get_tree().reload_current_scene()


# ---------------------------------------------------------------------------
# 版式（原版是 CSS 百分比定位，这里在尺寸变化时算一遍）
# ---------------------------------------------------------------------------

func _layout_loading() -> void:
	if _lr == null:
		return
	var vw := get_viewport().get_visible_rect().size.x
	var vh := get_viewport().get_visible_rect().size.y
	_lr.size = Vector2(vw, vh)

	var ui := _ui_font()
	var serif := _serif_font()
	var num := _num_font()
	var helv := _sys_font("helv", ["Helvetica Neue", "Arial", "sans-serif"])

	# 海报 cover：scale = max(vw/tw, vh/th)，再按 object-position 60% 50% 偏移
	if _l_poster != null and _l_poster.texture != null:
		var tw := float(_l_poster.texture.get_width())
		var th := float(_l_poster.texture.get_height())
		var s := maxf(vw / maxf(tw, 1.0), vh / maxf(th, 1.0))
		var w := tw * s
		var h := th * s
		_l_poster.position = Vector2(-(w - vw) * 0.60, -(h - vh) * 0.50)
		_l_poster.size = Vector2(w, h)
	# 影片与海报同框：源片 1920×1080 与海报同为 16:9，cover 结果一致
	# （原版 CSS 对两者用同一条 object-fit:cover; object-position:60% 50%）
	if _l_film != null:
		_l_film.position = _l_poster.position
		_l_film.size = _l_poster.size
	if _l_vignette != null:
		_l_vignette.position = Vector2.ZERO
		_l_vignette.size = Vector2(vw, vh)

	# 顶栏：top 5.4% · left/right 6.1%
	var top_y := vh * 0.054
	_l_top_left.position = Vector2(vw * 0.061, top_y)
	_l_top_left.size = Vector2(vw * 0.5, 14)
	_l_top_right.size = Vector2(vw * 0.5, 14)
	_l_top_right.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_l_top_right.position = Vector2(vw * (1.0 - 0.061) - vw * 0.5, top_y)

	# 标题块：left 11% · top 27%
	var h1_size := int(round(clampf(vw * 0.074, 65.0, 122.0)))
	var lede_size := int(round(clampf(vw * 0.015, 15.0, 23.0)))
	_l_h1.add_theme_font_size_override("font_size", h1_size)
	_l_h1.add_theme_font_override("font", _spaced(serif, float(h1_size) * 0.21))
	_l_lede.add_theme_font_size_override("font_size", lede_size)
	_l_lede.add_theme_font_override("font", _spaced(serif, float(lede_size) * 0.17))
	_l_lede.add_theme_constant_override("line_spacing",
		int(round(1.9 * float(lede_size) - float(serif.get_height(lede_size)))))
	# status 是单行，行距只在多行时有意义，这里只在 overflow 为正时设
	_l_status.add_theme_constant_override("line_spacing",
		maxi(0, int(round(1.7 * 12.0 - float(ui.get_height(12))))))

	var tx := vw * 0.11
	var ty := vh * 0.27
	_l_title.position = Vector2(tx, ty)
	var y := 0.0
	y += float(ui.get_height(10))                      # edition（单行）
	# h1：margin 20px 0，CSS 行高 1.3
	var h1_line := _css_line(serif, h1_size, 1.3)
	y += 20.0
	_l_h1.position = Vector2(0, y + (h1_line.x - float(serif.get_height(h1_size))) * 0.5)
	y += h1_line.x
	y += 27.0                                          # rule margin-top
	_l_rule.position = Vector2(0, y)
	y += 1.0 + 27.0                                    # rule 高 1px + margin-bottom
	# 正文两行：CSS 行高 1.9 → 行距 = 1.9×字号 − 字形盒高（Godot 的 line_spacing
	# 只加在行与行之间），块高按 CSS 的 n×行高 计，首行按半行距上移
	var lede_natural := float(serif.get_height(lede_size))
	var lede_line := 1.9 * float(lede_size)
	_l_lede.position = Vector2(0, y + (lede_line - lede_natural) * 0.5)
	y += 2.0 * lede_line
	y += 28.0                                          # districts margin-top
	# 片区行：南山 —(16×1)— 福田 —(16×1)— 罗湖，间隔 16px
	var dx := 0.0
	var dash_y := float(ui.get_height(10)) * 0.5
	for i in _l_districts.get_child_count():
		var c: Control = _l_districts.get_child(i)
		if c is Label:
			c.position = Vector2(dx, 0)
			dx += (c as Label).get_minimum_size().x + 16.0
		else:
			c.position = Vector2(dx, dash_y)
			dx += 32.0
	_l_districts.position = Vector2(0, y)
	_l_districts.size = Vector2(dx, float(ui.get_height(10)))

	# 底部块：left 11% · right 8% · bottom 9.5%
	var bl := vw * 0.11
	var br := vw * (1.0 - 0.08)
	var block_w := minf(660.0, vw * 0.61)
	var flow_bottom := vh - vh * 0.095

	# 失败态会占掉流程尾部（原版是同一个流式盒、bottom 锚定 → 整体上移）
	if _l_failure != null and _l_failure.visible:
		_l_failure_text.position = Vector2.ZERO
		var fh_text := float(ui.get_multiline_string_size(_l_failure_text.text,
			HORIZONTAL_ALIGNMENT_LEFT, block_w, 12).y)
		var fh := 24.0 + fh_text + 15.0 + _l_retry.get_combined_minimum_size().y
		_l_failure.position = Vector2(bl, flow_bottom - fh + 24.0)
		_l_failure.size = Vector2(block_w, fh)
		_l_failure_text.size = Vector2(block_w, fh_text)
		_l_retry.position = Vector2(0, fh_text + 15.0)
		flow_bottom -= fh

	var meta_h := float(ui.get_height(9))
	var meta_y := flow_bottom - meta_h
	_l_count.position = Vector2(bl, meta_y)
	_l_count.size = Vector2(block_w * 0.5, meta_h)
	# 推进依据靠右对齐到进度块右缘（原版 flex space-between）
	_l_basis.position = Vector2(br - block_w * 0.5, meta_y)
	_l_basis.size = Vector2(block_w * 0.5, meta_h)
	_l_basis.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	_l_bar_w = block_w
	_l_bar_x = bl
	_l_bar_y = meta_y - 11.0 - 2.0
	_l_bar_bg.position = Vector2(_l_bar_x, _l_bar_y)
	_l_bar_bg.size = Vector2(_l_bar_w, 2)

	# 标题列（group + status）与百分比块共用 heading 底边
	var heading_bottom := _l_bar_y - 17.0
	var group_h := float(ui.get_height(9))
	var status_line := _css_line(ui, 12, 1.7)
	_l_group.position = Vector2(bl, heading_bottom - status_line.x - 8.0 - group_h)
	_l_group.size = Vector2(block_w, group_h)
	_l_status.position = Vector2(bl, heading_bottom - status_line.x
		+ (status_line.x - float(ui.get_height(12))) * 0.5)
	_l_status.size = Vector2(block_w * 0.8, status_line.x)

	# 百分比：align-items:flex-end + 内部 baseline 对齐；数字右对齐、右缘固定，
	# 所以盒宽按最宽文本 "100" 算，位数变化时不会牵动版式。
	var n_size := 39
	var n_natural := float(num.get_height(n_size))
	var n_box := 0.9 * float(n_size)                   # lh .9
	var n_half := (n_box - n_natural) * 0.5
	var n_top := heading_bottom - n_box
	var n_baseline := n_top + n_half + float(num.get_ascent(n_size))
	var u_size := 10
	var u_w := float(helv.get_string_size("%", HORIZONTAL_ALIGNMENT_LEFT, -1, u_size).x)
	var n_w := float(num.get_string_size("100", HORIZONTAL_ALIGNMENT_LEFT, -1, n_size).x)
	_l_num.add_theme_font_override("font", _spaced(num, float(n_size) * -0.035))
	_l_num.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_l_num.position = Vector2(br - u_w - 5.0 - n_w, n_top + n_half)
	_l_num.size = Vector2(n_w, n_box)
	_l_unit.position = Vector2(br - u_w, n_baseline - float(helv.get_ascent(u_size)))
	_l_unit.size = Vector2(u_w, float(helv.get_height(u_size)))

	_apply_bar()


## 进度条：宽度按完成度生长，两层光晕跟着填充一起伸缩。
func _apply_bar() -> void:
	if _l_bar_fill == null:
		return
	var frac := clampf(_loading_shown, 0.0, 1.0)
	var w := _l_bar_w * frac
	_l_bar_fill.position = Vector2(_l_bar_x, _l_bar_y)
	_l_bar_fill.size = Vector2(w, 2)
	for i in _l_bar_glows.size():
		var g: TextureRect = _l_bar_glows[i]
		var pad := 9.0 if i == 0 else 4.0
		g.position = Vector2(_l_bar_x - pad, _l_bar_y - (pad * 0.5))
		g.size = Vector2(maxf(0.0, w + pad * 2.0), 2.0 + pad)
	if _l_num != null:
		_l_num.text = str(int(floor(_loading_shown * 100.0)))


# ---------------------------------------------------------------------------
# 状态机（原版 update / finish / reveal / error 的对应实现）
# ---------------------------------------------------------------------------

func _set_stage_texts() -> void:
	if _l_status == null:
		return
	if _loading_state == LoadState.READY:
		_l_group.text = "准备出发"
		_l_status.text = "城市已就绪"
		_l_basis.text = "下一程，由你决定"
		_l_count.text = "阶段 %02d / %d" % [LOADING_STAGES.size(), LOADING_STAGES.size()]
		return
	if _loading_state == LoadState.ERROR:
		# .city-loader[data-state=error] .city-loader-group{color:#9b4b31}
		_l_group.add_theme_color_override("font_color", LOADER_ERROR_C)
		_l_group.text = "载入中断"
		_l_status.text = "城市暂时没有载入"
		_l_basis.text = "已保留当前进度"
		return
	_l_group.add_theme_color_override("font_color", LOADER_MINT)
	var st: Dictionary = LOADING_STAGES[clampi(_loading_stage, 0, LOADING_STAGES.size() - 1)]
	_l_group.text = str(st["group"])
	_l_status.text = str(st["label"])
	_l_count.text = "阶段 %02d / %d" % [_loading_stage + 1, LOADING_STAGES.size()]


func _process(delta: float) -> void:
	# 进度条平滑逼近：单块 266MB 的 buildings.glb 会长时间停在同一百分比，
	# 直接跳变到目标值会让界面看起来"卡住了"。
	# 时间常数 0.12s ≈ 原版 CSS 的 transition: transform .28s ease。
	if _lr == null or not _lr.visible:
		return
	if is_equal_approx(_loading_shown, _loading_target):
		return
	_loading_shown += (_loading_target - _loading_shown) * (1.0 - exp(-delta / 0.12))
	if absf(_loading_target - _loading_shown) < 0.0015:
		_loading_shown = _loading_target
	_apply_bar()


## 由真实构建比例换算阶段（见本节顶部注释：17 段文案 + 真实进度）
func _sync_stage() -> void:
	var n := LOADING_STAGES.size()
	var pos := clampf(_loading_target, 0.0, 0.9999) * float(n)
	_loading_stage = clampi(int(floor(pos)), 0, n - 1)
	if _loading_state != LoadState.LOADING:
		return
	var frac := clampf(pos - float(_loading_stage), 0.0, 1.0)
	_l_basis.text = "当前阶段含资源进度" if frac > 0.0 and frac < 1.0 else "按已完成阶段推进"
	_set_stage_texts()


func set_loading_text(text: String) -> void:
	# 原版没有独立的状态文案通道（group / status / count 全部来自阶段表），
	# 这里只留作诊断：加载期的真实相位名由 CityWorld 上报。
	_loading_note = text


func set_loading_detail(text: String) -> void:
	# 原版进度块只有「阶段 / 推进依据」两行，没有资源计数行 —— 单列会破坏版式。
	# 资源计数仍然保留在 _loading_note 里供诊断，不上屏。
	if text != "":
		_loading_note = text


func set_loading_progress(p: float) -> void:
	if _loading_state != LoadState.LOADING:
		return
	_loading_target = clampf(p, 0.0, 1.0)
	_sync_stage()


## 进入失败态：对应原版 error()。原版会隐藏标题正文与片区行，并显示重载按钮。
func fail_loading(reason: String) -> void:
	if _loading_state == LoadState.LEAVING or _loading_state == LoadState.ERROR:
		return
	_loading_state = LoadState.ERROR
	_set_stage_texts()
	if _l_lede != null:
		_l_lede.visible = false
	if _l_districts != null:
		_l_districts.visible = false
	if _l_failure != null:
		_l_failure_text.text = reason if reason != "" else "请重新载入后再试。"
		_l_failure.visible = true
	_layout_loading()


func finish_loading() -> void:
	if _loading_state == LoadState.LEAVING:
		return
	_loading_state = LoadState.READY
	_loading_target = 1.0
	_loading_shown = 1.0
	_loading_stage = LOADING_STAGES.size() - 1
	# .city-loader[data-state=ready] .city-loader-percent{color:#365f50}
	# 只改百分比的**数字**（单位 span 有自己的 #617570，不跟着变）
	if _l_num != null:
		_l_num.add_theme_color_override("font_color", LOADER_READY_C)
	_set_stage_texts()
	_apply_bar()
	_reveal_loading()


## 原版 reveal()：ready 之后淡出 0.7s 再移除；这里用同一条时间线（promise → 计时器）
func _reveal_loading() -> void:
	if _loading_state == LoadState.LEAVING or _lr == null:
		return
	_loading_state = LoadState.LEAVING
	if _title_tween != null and _title_tween.is_valid():
		_title_tween.kill()
	var t := create_tween()
	t.tween_property(_lr, "modulate:a", 0.0, 0.7).set_trans(Tween.TRANS_LINEAR)
	t.tween_callback(_on_loading_faded)


## 0.7s 淡出结束 → 移除（原版 reveal() 里的 removeTimer → dispose）
func _on_loading_faded() -> void:
	if _lr == null:
		return
	_lr.visible = false
	_lr.modulate.a = 1.0
	# 原版 dispose() 里的 releaseFilm()：淡出结束后才停片，淡出过程中影片照常播
	if _l_film != null:
		_l_film.stop()
		_l_film.modulate.a = 0.0


## 影片淡入/淡出（原版 .city-loader-film{transition:opacity .8s}）
func _film_fade(target: float) -> void:
	if _l_film == null:
		return
	if _film_tween != null and _film_tween.is_valid():
		_film_tween.kill()
	_film_tween = create_tween()
	_film_tween.tween_property(_l_film, "modulate:a", target, 0.8) \
		.set_trans(Tween.TRANS_LINEAR)


func show_loading() -> void:
	if _lr == null:
		_build_loading()
	_loading_state = LoadState.LOADING
	_loading_target = 0.0
	_loading_shown = 0.0
	_loading_stage = 0
	_lr.visible = true
	_lr.modulate.a = 1.0
	if _l_num != null:
		_l_num.add_theme_color_override("font_color", LOADER_PAPER)
	if _l_group != null:
		_l_group.add_theme_color_override("font_color", LOADER_MINT)
	if _l_lede != null:
		_l_lede.visible = true
	if _l_districts != null:
		_l_districts.visible = true
	if _l_failure != null:
		_l_failure.visible = false
	if _l_film != null:
		# 原版 syncFilm()：播放并让 film 淡入盖过海报；解码失败时节点透明，海报兜底
		_l_film.modulate.a = 0.0
		if _l_film.stream != null:
			_l_film.play()
			_film_fade(1.0)
	_l_group.text = LOADING_STAGES[0]["group"]
	_l_status.text = "正在启动城市"     # 原版初始 DOM 的文案
	_l_basis.text = "按已完成阶段推进"
	_l_count.text = "阶段 01 / %d" % LOADING_STAGES.size()
	_layout_loading()
	# 进入动画：city-loader-enter 1.2s ease both（上浮 12px + 淡入）
	var base_y := _l_title.position.y
	_l_title.position.y = base_y + 12.0
	_l_title.modulate.a = 0.0
	if _title_tween != null and _title_tween.is_valid():
		_title_tween.kill()
	_title_tween = create_tween().set_parallel(true)
	_title_tween.tween_property(_l_title, "position:y", base_y, 1.2) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_title_tween.tween_property(_l_title, "modulate:a", 1.0, 1.2) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


# ---------------------------------------------------------------------------
# 手账
# ---------------------------------------------------------------------------

func toggle_journal() -> void:
	journal_visible = not journal_visible
	journal.visible = journal_visible
	if journal_visible:
		refresh_journal()


func refresh_journal() -> void:
	var s := career.status()
	var lines: Array = []
	lines.append("身份：%s      等级：%d      经验：%d / %d" % [s["identity"], s["level"], s["xp"], CareerSystem.XP_PER_LEVEL])
	lines.append("累计收入：¥%d      已完成合约：%d" % [s["earned"], s["completed"]])
	if s["active"] >= 0:
		lines.append("进行中：%s      剩余时限：%.0fs      品质：%.0f" % [
			s["contract"], maxf(0.0, float(s["deadline"]) - float(s["elapsed"])), s["quality"]])
	else:
		lines.append("当前没有进行中的合约")
	lines.append("")
	lines.append("关系：何志 %d / 阿琳 %d / 养护站 %d（上限 %d）" % [
		s["relations"][0], s["relations"][1], s["relations"][2], CareerSystem.RELATION_MAX])
	lines.append("")
	lines.append("可接合约（按对应数字键接单）：")
	var avail: Array = s["available"]
	if avail.is_empty():
		lines.append("   （当前身份没有可接的合约，先提升等级）")
	else:
		for ord in avail.size():
			var c: Dictionary = CareerSystem.CONTRACTS[int(avail[ord])]
			lines.append("   [%d] %s  ·  ¥%d  ·  %s → %s" % [
				ord + 1, c["name"], int(c["base_pay"]), c["from"], c["to"]])
	lines.append("")
	# 注意：String.join() 的形参是 PackedStringArray，直接传 Array 会被分析器判错，
	# 所以统一显式转换一次。
	var upgrades: Array = s["upgrades"]
	lines.append("升级（已购：%s）" % ("、".join(PackedStringArray(upgrades)) if not upgrades.is_empty() else "无"))
	for u in CareerSystem.UPGRADES:
		lines.append("   %s — %s" % [u["name"], u["desc"]])
	lines.append("")
	var st := story.status()
	lines.append("故事《%s》：第 %d 步（%s）%s" % [
		st["title"], int(st["step"]) + 1, st["stepId"], "已完结" if st["completed"] else "进行中"])
	lines.append("")
	lines.append("旧城小活：%s · 现金 ¥%d · 第 %d 天" % [
		GameContent.work_status_name(GameState.work), GameState.cash, GameState.day])
	journal_body.text = "\n".join(PackedStringArray(lines))


# ---------------------------------------------------------------------------
# 图像设置页（CS2 风格：↑↓ 选择，←→ 调整，即时生效并自动保存）
#
# 替换了旧版只读的"画质设置"面板（refresh_graphics 只展示档位参数，
# cycle_quality 从未被任何按键调用过）。所有选项实时下发：
#   预设 → GraphicsQuality.set_tier（并清空逐项覆盖）
#   其余 → 写 overrides 后立即 apply（视口属性 / apply_to_world 广播）
# ---------------------------------------------------------------------------

## 设置行定义：key / 显示名 / 选项标签（←→ 在选项间循环）
const SETTINGS_ROWS := [
	{"key": "preset", "name": "画质预设", "opts": ["低", "中", "高"]},
	{"key": "scaling", "name": "渲染缩放", "opts": ["50%", "65%", "75%", "88%", "100%", "125%", "150%"]},
	{"key": "aa", "name": "抗锯齿", "opts": ["关", "FXAA"]},
	{"key": "shadows", "name": "阴影", "opts": ["关", "低 (1024)", "高 (2048)"]},
	{"key": "ao", "name": "环境光遮蔽", "opts": ["关", "开"]},
	{"key": "bloom", "name": "泛光 (Bloom)", "opts": ["关", "开"]},
	{"key": "lamps", "name": "夜间路灯数量", "opts": ["8 盏", "16 盏", "24 盏"]},
	{"key": "trees", "name": "植被密度", "opts": ["低 (4000)", "中 (9000)", "高 (16000)"]},
	{"key": "exposure", "name": "曝光补偿", "opts": ["-30%", "-15%", "标准", "+15%", "+30%"]},
	{"key": "fps", "name": "帧率显示", "opts": ["关", "开"]},
]

var settings_root: Control
var settings_rows_box: Control
var hud = null                    ## 帧率显示行需要操作 HUD（main_game 注入）
var settings_visible := false
var settings_sel := 0
var _settings_name_labels: Array = []
var _settings_value_labels: Array = []


func toggle_settings() -> bool:
	settings_visible = not settings_visible
	settings_root.visible = settings_visible
	if settings_visible:
		refresh_settings()
	return settings_visible


func _mk_settings_row(parent: Control, y: float) -> void:
	var name_l := Label.new()
	name_l.add_theme_font_override("font", _font(19))
	name_l.add_theme_color_override("font_color", Color(0.86, 0.89, 0.93))
	name_l.position = Vector2(30, y)
	name_l.size = Vector2(300, 26)
	parent.add_child(name_l)
	_settings_name_labels.append(name_l)
	var value_l := Label.new()
	value_l.add_theme_font_override("font", _font(19))
	value_l.add_theme_color_override("font_color", Color(0.85, 0.72, 0.40))
	value_l.position = Vector2(360, y)
	value_l.size = Vector2(240, 26)
	value_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	parent.add_child(value_l)
	_settings_value_labels.append(value_l)


func _build_settings() -> void:
	if settings_root != null:
		return
	settings_root = Control.new()
	settings_root.name = "SettingsPanel"
	settings_root.set_anchors_preset(Control.PRESET_TOP_LEFT)
	settings_root.position = Vector2(620, 200)
	settings_root.size = Vector2(660, 480)
	settings_root.visible = false
	add_child(settings_root)
	var bg := ColorRect.new()
	bg.color = Color(0.045, 0.055, 0.075, 0.94)
	bg.size = Vector2(660, 480)
	settings_root.add_child(bg)
	var border := ColorRect.new()
	border.color = Color(0.28, 0.32, 0.38, 0.9)
	border.size = Vector2(660, 2)
	settings_root.add_child(border)
	var t := Label.new()
	t.add_theme_font_override("font", _font(26))
	t.add_theme_color_override("font_color", Color(0.96, 0.94, 0.88))
	t.text = "图像设置"
	t.position = Vector2(28, 16)
	settings_root.add_child(t)
	var hint := Label.new()
	hint.add_theme_font_override("font", _font(15))
	hint.add_theme_color_override("font_color", Color(0.55, 0.60, 0.66))
	hint.text = "↑↓ 选择   ←→ 调整   F10 / Esc 关闭 · 即时生效并自动保存"
	hint.position = Vector2(330, 24)
	hint.size = Vector2(310, 22)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	settings_root.add_child(hint)
	settings_rows_box = Control.new()
	settings_rows_box.position = Vector2.ZERO
	settings_rows_box.size = Vector2(660, 400)
	settings_root.add_child(settings_rows_box)
	for i in SETTINGS_ROWS.size():
		_mk_settings_row(settings_rows_box, 72.0 + i * 34.0)
	var note := Label.new()
	note.add_theme_font_override("font", _font(15))
	note.add_theme_color_override("font_color", Color(0.50, 0.55, 0.62))
	note.text = "选「画质预设」会重置下面的高级选项为该档位默认值"
	note.position = Vector2(28, 72.0 + SETTINGS_ROWS.size() * 34.0 + 8.0)
	note.size = Vector2(600, 22)
	settings_root.add_child(note)


## 当前选项在每行的下标（读 GraphicsQuality 的生效状态）
func _setting_current_index(key: String) -> int:
	match key:
		"preset":
			return clampi(GraphicsQuality.tier_index(), 0, 2)
		"scaling":
			return GraphicsQuality.scaling_step_index()
		"aa":
			return clampi(int(GraphicsQuality.overrides.get("aa", 1)), 0, 1)
		"shadows":
			return clampi(int(GraphicsQuality.effective().get("shadows", 2)), 0, 2)
		"ao":
			return 1 if bool(GraphicsQuality.effective().get("ao", true)) else 0
		"bloom":
			if GraphicsQuality.overrides.has("bloom"):
				return 1 if bool(GraphicsQuality.overrides["bloom"]) else 0
			return 1 if float(GraphicsQuality.profile().get("bloom_scale", 0.5)) > 0.0 else 0
		"lamps":
			var lv := int(GraphicsQuality.effective().get("lamps", 24))
			var best := 2
			for i in GraphicsQuality.LAMP_STEPS.size():
				if int(GraphicsQuality.LAMP_STEPS[i]) == lv:
					best = i
					break
			return best
		"trees":
			var tv := int(GraphicsQuality.effective().get("tree_budget", 9000))
			var tbest := 1
			for i in GraphicsQuality.TREE_STEPS.size():
				if int(GraphicsQuality.TREE_STEPS[i]) == tv:
					tbest = i
					break
			return tbest
		"exposure":
			return GraphicsQuality.exposure_step_index()
		"fps":
			if GraphicsQuality.overrides.has("fps"):
				return 1 if bool(GraphicsQuality.overrides["fps"]) else 0
			return 0
	return 0


## 应用某行的选项：写入 overrides 并立即下发。
func _apply_setting(key: String, idx: int) -> void:
	match key:
		"preset":
			# 预设 = 重置高级选项（CS2 同款行为）
			GraphicsQuality.clear_overrides()
			GraphicsQuality.set_tier(GraphicsQuality.TIERS[clampi(idx, 0, 2)])
			GraphicsQuality.apply_to_world(world)
		"scaling":
			GraphicsQuality.set_override("scaling",
				float(GraphicsQuality.SCALING_STEPS[clampi(idx, 0, GraphicsQuality.SCALING_STEPS.size() - 1)]))
			GraphicsQuality.apply_resolution_scale()
		"aa":
			GraphicsQuality.set_override("aa", clampi(idx, 0, 1))
			GraphicsQuality.apply_aa()
		"shadows", "ao", "bloom", "lamps", "trees", "exposure":
			match key:
				"shadows":
					GraphicsQuality.set_override("shadows", clampi(idx, 0, 2))
				"ao":
					GraphicsQuality.set_override("ao", idx >= 1)
				"bloom":
					GraphicsQuality.set_override("bloom", idx >= 1)
				"lamps":
					GraphicsQuality.set_override("lamps",
						int(GraphicsQuality.LAMP_STEPS[clampi(idx, 0, GraphicsQuality.LAMP_STEPS.size() - 1)]))
				"trees":
					GraphicsQuality.set_override("tree_budget",
						int(GraphicsQuality.TREE_STEPS[clampi(idx, 0, GraphicsQuality.TREE_STEPS.size() - 1)]))
				"exposure":
					GraphicsQuality.set_override("exposure",
						float(GraphicsQuality.EXPOSURE_STEPS[clampi(idx, 0, GraphicsQuality.EXPOSURE_STEPS.size() - 1)]))
			GraphicsQuality.apply_to_world(world)
			# 曝光补偿乘在 tonemap_exposure 上，要重放一次当前光照模式才生效
			if key == "exposure" and world != null and world.lighting != null:
				world.lighting.apply_mode(world.lighting.mode)
		"fps":
			var on := idx >= 1
			GraphicsQuality.set_override("fps", on)
			if hud != null and hud.has_method("set_fps_visible"):
				hud.set_fps_visible(on)
	GraphicsQuality.save()


func refresh_settings() -> void:
	if settings_root == null:
		_build_settings()
	for i in SETTINGS_ROWS.size():
		var row: Dictionary = SETTINGS_ROWS[i]
		var sel := i == settings_sel
		var name_l: Label = _settings_name_labels[i]
		name_l.text = ("▶  " if sel else "    ") + str(row["name"])
		name_l.add_theme_color_override("font_color",
			Color(0.98, 0.90, 0.55) if sel else Color(0.86, 0.89, 0.93))
		var value_l: Label = _settings_value_labels[i]
		var oi := _setting_current_index(str(row["key"]))
		var opts: Array = row["opts"]
		value_l.text = "‹ %s ›" % str(opts[clampi(oi, 0, opts.size() - 1)])
		value_l.add_theme_color_override("font_color",
			Color(1.0, 0.82, 0.45) if sel else Color(0.85, 0.72, 0.40))


## 设置页打开时的按键路由。返回 true 表示按键已消费。
func handle_settings_key(k: InputEventKey) -> bool:
	if not settings_visible:
		return false
	match k.keycode:
		KEY_F10, KEY_ESCAPE:
			toggle_settings()
			return true
		KEY_UP:
			settings_sel = (settings_sel - 1 + SETTINGS_ROWS.size()) % SETTINGS_ROWS.size()
			refresh_settings()
			return true
		KEY_DOWN:
			settings_sel = (settings_sel + 1) % SETTINGS_ROWS.size()
			refresh_settings()
			return true
		KEY_LEFT:
			_nudge_setting(-1)
			return true
		KEY_RIGHT:
			_nudge_setting(1)
			return true
	return false


func _nudge_setting(dir: int) -> void:
	var row: Dictionary = SETTINGS_ROWS[settings_sel]
	var key := str(row["key"])
	var n: int = row["opts"].size()
	var idx := (_setting_current_index(key) + dir + n) % n
	_apply_setting(key, idx)
	refresh_settings()


# ---------------------------------------------------------------------------
# 对话
# ---------------------------------------------------------------------------

func show_dialogue(text: String, options: Array, kind := "story") -> void:
	_dialog_kind = kind
	_dialog_options = options
	dialog_body.text = text
	var lines: Array = []
	for i in options.size():
		lines.append("[%d] %s" % [i + 1, options[i].get("text", "")])
	dialog_options.text = "\n".join(PackedStringArray(lines))
	dialog.visible = true
	dialog_active = true


func close_dialogue() -> void:
	dialog.visible = false
	dialog_active = false
	_dialog_options = []


## 返回选项下标，无则 -1
func choose_dialogue(number: int) -> int:
	if not dialog_active:
		return -1
	var idx := number - 1
	if idx < 0 or idx >= _dialog_options.size():
		return -1
	return idx


func dialog_option_text(idx: int) -> String:
	if idx < 0 or idx >= _dialog_options.size():
		return ""
	return str(_dialog_options[idx].get("text", ""))


## 供主控制器判断当前对话类型（story / career）
func dialog_kind() -> String:
	return _dialog_kind


func diagnostics() -> Dictionary:
	return {"journal": journal_visible, "dialog": dialog_active,
			"quality": GraphicsQuality.tier(), "loadingVisible": loading.visible if loading != null else false,
			"loadStage": _loading_stage, "loadStageCount": LOADING_STAGES.size(),
			"loadProgress": _loading_target, "loadPhase": _loading_note}
