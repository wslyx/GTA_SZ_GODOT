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
var graphics_panel: Control
var loading: Control
var dialog: Control

var journal_visible := false
var dialog_active := false
var _dialog_options: Array = []
var _dialog_kind := ""

var _loading_label: Label
var _loading_bar: Control
var _loading_progress := 0.0


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
	journal = _panel("城市手账 · J 关闭", Vector2(720, 620), Vector2(600, 180))["root"]
	journal_body = journal.get_child(3)

	graphics_panel = _panel("画质设置 · G+Shift 关闭", Vector2(560, 320), Vector2(680, 820))["root"]
	graphics_body = graphics_panel.get_child(3)

	# 加载画面
	loading = Control.new()
	loading.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(loading)
	var lbg := ColorRect.new()
	lbg.color = Color(0.02, 0.03, 0.05, 1.0)
	lbg.set_anchors_preset(Control.PRESET_FULL_RECT)
	loading.add_child(lbg)
	_loading_label = Label.new()
	_loading_label.add_theme_font_override("font", _font(30))
	_loading_label.add_theme_color_override("font_color", Color(0.92, 0.94, 0.96))
	_loading_label.set_anchors_preset(Control.PRESET_CENTER)
	_loading_label.position = Vector2(-300, -30)
	_loading_label.size = Vector2(600, 40)
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.text = "深城纪 · 正在加载"
	loading.add_child(_loading_label)

	var bar_bg := ColorRect.new()
	bar_bg.color = Color(0.12, 0.14, 0.18)
	bar_bg.set_anchors_preset(Control.PRESET_CENTER)
	bar_bg.position = Vector2(-260, 30)
	bar_bg.size = Vector2(520, 8)
	loading.add_child(bar_bg)
	_loading_bar = ColorRect.new()
	_loading_bar.color = Color(0.85, 0.72, 0.40)
	_loading_bar.set_anchors_preset(Control.PRESET_CENTER)
	_loading_bar.position = Vector2(-260, 30)
	_loading_bar.size = Vector2(0, 8)
	loading.add_child(_loading_bar)

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
var graphics_body: Label
var dialog_body: Label
var dialog_options: Label


# ---------------------------------------------------------------------------
# 加载
# ---------------------------------------------------------------------------

func set_loading_text(text: String) -> void:
	if _loading_label != null:
		_loading_label.text = text


func set_loading_progress(p: float) -> void:
	_loading_progress = clampf(p, 0.0, 1.0)
	if _loading_bar != null:
		_loading_bar.size = Vector2(520.0 * _loading_progress, 8)


func finish_loading() -> void:
	if loading != null:
		loading.visible = false


func show_loading() -> void:
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
# 画质面板
# ---------------------------------------------------------------------------

func toggle_graphics() -> void:
	graphics_panel.visible = not graphics_panel.visible
	if graphics_panel.visible:
		refresh_graphics()


func refresh_graphics() -> void:
	var p := GraphicsQuality.profile()
	var lines: Array = []
	lines.append("当前档位：%s（共 low / medium / high）" % GraphicsQuality.tier())
	lines.append("")
	lines.append("最大分辨率    %d × %d" % [p["max_pixels"].x, p["max_pixels"].y])
	lines.append("阴影贴图      %d" % int(p["shadow_size"]))
	lines.append("环境光遮蔽    %s（采样 %d）" % ["开" if p["ao"] else "关", int(p["ao_samples"])])
	lines.append("镜面反射      %d" % int(p["mirror_size"]))
	lines.append("MSAA          %d×" % int(p["msaa"]))
	lines.append("Bloom 强度    %.2f" % float(p["bloom_scale"]))
	lines.append("镜头效果      %s" % ["开" if p["lens_effects"] else "关"])
	lines.append("细节比例      %.2f" % float(p["detail_scale"]))
	lines.append("近景树木      %d" % int(p["near_trees"]))
	lines.append("林冠 full     %d" % int(p["canopy_full"]))
	lines.append("")
	lines.append("按 L 循环切换光照，按 Y 切换雨天")
	graphics_body.text = "\n".join(PackedStringArray(lines))


func cycle_quality() -> void:
	GraphicsQuality.set_tier(GraphicsQuality.cycle())
	if world != null:
		GraphicsQuality.apply_to_world(world)
	if graphics_panel.visible:
		refresh_graphics()


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
