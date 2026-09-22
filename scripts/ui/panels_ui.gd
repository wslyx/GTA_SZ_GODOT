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

var _loading_label: Label
var _loading_bar: Control
var _loading_pct: Label
var _loading_detail: Label
var _loading_progress := 0.0      ## 目标进度
var _loading_shown := 0.0         ## 显示进度（向目标平滑逼近）
var _loading_built := false

const BAR_WIDTH := 520.0


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
# 加载画面
# ---------------------------------------------------------------------------

func _build_loading() -> void:
	if _loading_built:
		return
	_loading_built = true

	loading = Control.new()
	loading.name = "LoadingScreen"
	loading.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(loading)

	var lbg := ColorRect.new()
	lbg.color = Color(0.02, 0.03, 0.05, 1.0)
	lbg.set_anchors_preset(Control.PRESET_FULL_RECT)
	loading.add_child(lbg)

	# 顶部标题
	var title := Label.new()
	title.add_theme_font_override("font", _font(22))
	title.add_theme_color_override("font_color", Color(0.85, 0.72, 0.40))
	title.set_anchors_preset(Control.PRESET_CENTER)
	title.position = Vector2(-300, -110)
	title.size = Vector2(600, 32)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.text = "深 城 纪 · SHENCHENGJI"
	loading.add_child(title)

	# 阶段文案
	_loading_label = Label.new()
	_loading_label.add_theme_font_override("font", _font(30))
	_loading_label.add_theme_color_override("font_color", Color(0.92, 0.94, 0.96))
	_loading_label.set_anchors_preset(Control.PRESET_CENTER)
	_loading_label.position = Vector2(-300, -50)
	_loading_label.size = Vector2(600, 42)
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.text = "深城纪 · 正在加载"
	loading.add_child(_loading_label)

	# 进度条底槽
	var bar_bg := ColorRect.new()
	bar_bg.color = Color(0.12, 0.14, 0.18)
	bar_bg.set_anchors_preset(Control.PRESET_CENTER)
	bar_bg.position = Vector2(-BAR_WIDTH * 0.5, 10)
	bar_bg.size = Vector2(BAR_WIDTH, 10)
	loading.add_child(bar_bg)

	# 进度条（从左侧生长：锚点已居中，左边缘固定）
	_loading_bar = ColorRect.new()
	_loading_bar.color = Color(0.85, 0.72, 0.40)
	_loading_bar.set_anchors_preset(Control.PRESET_CENTER)
	_loading_bar.position = Vector2(-BAR_WIDTH * 0.5, 10)
	_loading_bar.size = Vector2(0, 10)
	loading.add_child(_loading_bar)

	# 百分比
	_loading_pct = Label.new()
	_loading_pct.add_theme_font_override("font", _font(20))
	_loading_pct.add_theme_color_override("font_color", Color(0.85, 0.72, 0.40))
	_loading_pct.set_anchors_preset(Control.PRESET_CENTER)
	_loading_pct.position = Vector2(-300, 30)
	_loading_pct.size = Vector2(600, 28)
	_loading_pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_pct.text = "0%"
	loading.add_child(_loading_pct)

	# 明细（资源计数等）
	_loading_detail = Label.new()
	_loading_detail.add_theme_font_override("font", _font(16))
	_loading_detail.add_theme_color_override("font_color", Color(0.55, 0.60, 0.66))
	_loading_detail.set_anchors_preset(Control.PRESET_CENTER)
	_loading_detail.position = Vector2(-300, 62)
	_loading_detail.size = Vector2(600, 24)
	_loading_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_detail.text = ""
	loading.add_child(_loading_detail)

	set_process(true)


func _process(delta: float) -> void:
	# 进度条平滑逼近：单块 266MB 的 buildings.glb 会长时间停在同一百分比，
	# 直接跳变到目标值会让界面看起来"卡住了"。
	if loading == null or not loading.visible:
		return
	if is_zero_approx(_loading_shown - _loading_progress):
		return
	_loading_shown = move_toward(_loading_shown, _loading_progress, delta * 0.65)
	_apply_bar()


func _apply_bar() -> void:
	if _loading_bar != null:
		_loading_bar.size = Vector2(BAR_WIDTH * _loading_shown, 10)
	if _loading_pct != null:
		_loading_pct.text = "%d%%" % int(round(_loading_shown * 100.0))


func set_loading_text(text: String) -> void:
	if _loading_label != null and _loading_label.text != text:
		_loading_label.text = text


func set_loading_detail(text: String) -> void:
	if _loading_detail != null and _loading_detail.text != text:
		_loading_detail.text = text


func set_loading_progress(p: float) -> void:
	_loading_progress = clampf(p, 0.0, 1.0)


func finish_loading() -> void:
	_loading_progress = 1.0
	_loading_shown = 1.0
	_apply_bar()
	if loading != null:
		loading.visible = false


func show_loading() -> void:
	_loading_progress = 0.0
	_loading_shown = 0.0
	_apply_bar()
	if loading != null:
		loading.visible = true


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
			"quality": GraphicsQuality.tier(), "loadingVisible": loading.visible if loading != null else false}
