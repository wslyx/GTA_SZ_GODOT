extends RefCounted
class_name StorySystem
##
## 城市故事 —— 逐项移植原版 src/city-story.ts（内容见 city-story-content.ts）。
##
## 目前只有一条：《最后一单》，reward 180，共 8 步。
## 地点复用 career 的 place_position()；触发条件是"目标 28m 内、速度 <1、已下车、按 E"。
## 位移超过 45m 视为调试跳转，会给出提示。
##
## 步骤图：
##   hub-pickup → office-meet → ┬ office-spare → park-help → bay-after-park
##                              └ bay-direct → ┬ hub-end-direct
##                                             └ hub-end-detour
##   两条分支最终都回到 hub 收尾。

const TRIGGER_RADIUS := 28.0
const TRIGGER_SPEED := 1.0
const DEBUG_JUMP_DISTANCE := 45.0

## 原版 city-story-content.ts 的 synopsis，逐字照搬。
## 剧情未开始时，HUD 的故事卡（.story-entry）第三段显示的就是这句 —— 也就是
## 出生点截图里能看到的那段话。
const SYNOPSIS := "收工前，阿辉把滨海那单的保温袋交给你。先去科苑下班驿站让阿琳核销，"\
	+ "再决定直接送滨海交接点，还是绕公园城市养护站把卡箍给老陈。"

## 人物表（原版 city-story-content.ts 的 people）
const PEOPLE := {
	"ahui": {"name": "阿辉", "role": "驿站日结，本单派件"},
	"alin": {"name": "阿琳", "role": "科苑职场人，本单核销"},
	"laochen": {"name": "老陈", "role": "城市工人，本单在公园养护站等卡箍"},
	"player": {"name": "你", "role": "日结配送"},
}

## 原版 city-story-content.ts 的 CITY_STORY_CONTENT —— **全量重搬**（schema 1）。
##
## 此前本文件是"早期改写版"：8 步的情节与人物名都和原版不一致（原版是阿辉 /
## 阿琳 / 老陈的配送单，改写版换成了何志与"送文件"）。现已按原版逐条重搬：
##   steps 含 id / place / title / objective / action / lines / choices / next /
##   terminal，consequence 一并保留。
## 对话 UI 目前一次只显示一段文本 + 选项，所以 `text` 由 lines 拼成
## （"阿辉：…" 逐行）、`options` 由 choices 映射（无 choices 的步骤给一个
## 推进项）—— 见 _dialogue_text() / _options_of()。
const STORY := {
	"id": "bay-last-delivery",
	"title": "最后一单",
	"reward": 180,
	"steps": [
		{
			"id": "hub-pickup", "place": "hub",
			"title": "驿站还不能关",
			"objective": "到海湾生活驿站停稳下车，向阿辉领取保温袋。",
			"action": "collect",
			"lines": [
				{"speaker": "ahui", "text": "滨海那单还搁着，晚班退件没到，我走不开。"},
				{"speaker": "ahui", "text": "保温袋给你。先去科苑驿站让阿琳对码，再送滨海。"},
			],
			"next": "office-meet",
		},
		{
			"id": "office-meet", "place": "office",
			"title": "窗口对码",
			"objective": "到科苑下班驿站门前停稳下车，找阿琳核对取件码。",
			"action": "talk",
			"lines": [
				{"speaker": "alin", "text": "码对上了。工作群催我回去，我得先走。"},
				{"speaker": "alin", "text": "老陈的卡箍还在我包里。你先送滨海，还是顺路丢公园？"},
			],
			"choices": [
				{
					"id": "go-bay-direct",
					"label": "先去滨海交接点交货",
					"next": "bay-direct",
					"consequence": "不去公园。阿琳回公司，卡箍留在科苑下班驿站，老陈明早来取；下一站滨海路边交接点。",
				},
				{
					"id": "detour-park",
					"label": "先去公园养护站把卡箍给老陈",
					"next": "office-spare",
					"consequence": "仍在科苑下班驿站向阿琳取走卡箍，再去公园城市养护站，最后送滨海交接点。",
				},
			],
		},
		{
			"id": "office-spare", "place": "office",
			"title": "包里的卡箍",
			"objective": "在科苑下班驿站窗口停稳下车，向阿琳取走老陈的卡箍。",
			"action": "collect",
			"lines": [
				{"speaker": "alin", "text": "给，中午我签的。"},
				{"speaker": "alin", "text": "拿着就走，我回公司了。"},
			],
			"next": "park-help",
		},
		{
			"id": "park-help", "place": "park",
			"title": "养护站交接",
			"objective": "到公园城市养护站停稳下车，把卡箍交给老陈。",
			"action": "deliver",
			"lines": [
				{"speaker": "laochen", "text": "卡箍来了就行，今晚不换过道要积水。"},
				{"speaker": "laochen", "text": "滨海那袋还等着，你走。"},
			],
			"next": "bay-after-park",
		},
		{
			"id": "bay-direct", "place": "bay",
			"title": "趁热送到",
			"objective": "到滨海路边交接点停稳下车，交付保温袋。",
			"action": "deliver",
			"lines": [
				{"speaker": "ahui", "text": "对面回了，饭烫手，签收了。"},
				{"speaker": "ahui", "text": "你回海湾驿站结。"},
			],
			"next": "hub-end-direct",
		},
		{
			"id": "bay-after-park", "place": "bay",
			"title": "送到，但温了",
			"objective": "到滨海路边交接点停稳下车，交付保温袋。",
			"action": "deliver",
			"lines": [
				{"speaker": "ahui", "text": "签是签了，说不烫了。"},
				{"speaker": "ahui", "text": "钱照结，你回来。"},
			],
			"next": "hub-end-detour",
		},
		{
			"id": "hub-end-direct", "place": "hub",
			"title": "准时收工",
			"objective": "回海湾生活驿站停稳下车，找阿辉结算。",
			"action": "talk",
			"lines": [
				{"speaker": "ahui", "text": "换班前送到，一百八打你账上。"},
				{"speaker": "ahui", "text": "老陈问卡箍，他说明早自己来科苑驿站取。"},
			],
			"terminal": true,
		},
		{
			"id": "hub-end-detour", "place": "hub",
			"title": "单子还是结了",
			"objective": "回海湾生活驿站停稳下车，找阿辉结算。",
			"action": "talk",
			"lines": [
				{"speaker": "ahui", "text": "饭温了他们也收，一百八不少你的。"},
				{"speaker": "ahui", "text": "老陈对讲里谢了声。下次零件走维修站，别绕配送单。"},
			],
			"terminal": true,
		},
	],
}

var world: CityWorld
var career: CareerSystem

var active := false
var step_index := 0
var completed := false
var message := ""
var pending_dialogue := {}
var debug_jumps := 0
var _last_pos := Vector2.ZERO


func setup(p_world: CityWorld, p_career: CareerSystem) -> void:
	world = p_world
	career = p_career
	_load()


func _load() -> void:
	var d := SaveSystem.load_section(SaveSystem.story_key())
	if d.is_empty():
		return
	step_index = int(d.get("step", 0))
	completed = bool(d.get("completed", false))
	debug_jumps = int(d.get("debugJumps", 0))


func _save() -> void:
	SaveSystem.save_section(SaveSystem.story_key(), {
		"step": step_index, "completed": completed, "debugJumps": debug_jumps,
	})


func current_step() -> Dictionary:
	var steps: Array = STORY["steps"]
	if step_index < 0 or step_index >= steps.size():
		return {}
	return steps[step_index]


func step_target() -> Vector2:
	var s := current_step()
	if s.is_empty():
		return Vector2.ZERO
	return career.place_position(str(s["place"]))


## 供 HUD 的提示
func interaction_hint(pos: Vector2, speed: float, on_foot: bool) -> Dictionary:
	if completed:
		return {}
	var s := current_step()
	if s.is_empty():
		return {}
	var d := pos.distance_to(step_target())
	if d < TRIGGER_RADIUS and absf(speed) < TRIGGER_SPEED and on_foot:
		return {"key": "E", "text": "《%s》推进剧情" % STORY["title"]}
	if d < 200.0:
		return {"key": "", "text": "《%s》· 还有 %.0fm" % [STORY["title"], d]}
	return {}


## 把原版的 lines（多人台词）拼成对话 UI 的一段文本：
##   「阿辉：滨海那单还搁着…」逐行。原版 UI 是分行渲染的，本移植的对话面板
##   一次只收一个字符串，所以用换行拼起来。
func _dialogue_text(s: Dictionary) -> String:
	var lines: Array = s.get("lines", [])
	if lines.is_empty():
		return str(s.get("objective", ""))
	var out := ""
	for l in lines:
		var sp: Dictionary = PEOPLE.get(str((l as Dictionary).get("speaker", "")), {})
		var nm := str(sp.get("name", (l as Dictionary).get("speaker", "")))
		if out != "":
			out += "\n"
		out += "%s：%s" % [nm, str((l as Dictionary).get("text", ""))]
	return out


## 选项：有 choices 就按原版 label/next 映射；没有就给一个推进项（原版这类步骤
## 是"对话完自动 next"）。terminal 步骤给空 next，choose() 据此收尾发奖励。
func _options_of(s: Dictionary) -> Array:
	var choices: Array = s.get("choices", [])
	if not choices.is_empty():
		var out: Array = []
		for c in choices:
			var cd: Dictionary = c
			out.append({"text": str(cd.get("label", "")), "next": str(cd.get("next", "")),
				"id": str(cd.get("id", "")),
				"consequence": str(cd.get("consequence", ""))})
		return out
	if bool(s.get("terminal", false)):
		return [{"text": "结束", "next": "", "id": "", "consequence": ""}]
	return [{"text": "继续", "next": str(s.get("next", "")), "id": "", "consequence": ""}]


## 按 E 推进
func interact(pos: Vector2, speed: float, on_foot: bool) -> Dictionary:
	if completed:
		return {}
	var s := current_step()
	if s.is_empty():
		return {}
	if not on_foot:
		return {"ok": false, "message": "剧情需要下车交互"}

	var d := pos.distance_to(step_target())
	if d > TRIGGER_RADIUS or absf(speed) > TRIGGER_SPEED:
		return {"ok": false, "message": ""}

	pending_dialogue = s
	# active 之前从未被置 true，note_position() 里的
	# `... and active` 恒假 → 调试跳转检测整段是死代码。玩家一旦真正开始
	# 推进剧情就置位，完结时清掉。
	active = true
	return {"ok": true, "step": s, "message": _dialogue_text(s),
		"options": _options_of(s), "objective": str(s.get("objective", "")),
		"title": str(s.get("title", ""))}


## 选择对话选项
func choose(option: int) -> Dictionary:
	if pending_dialogue.is_empty():
		return {}
	# 选项由步骤现场生成（原版 choices），不再依赖步骤里的静态 options 字段
	var opts: Array = _options_of(pending_dialogue)
	if option < 0 or option >= opts.size():
		return {}
	var next := str(opts[option].get("next", ""))
	pending_dialogue = {}
	var steps: Array = STORY["steps"]
	if next == "":
		completed = true
		active = false
		GameState.add_cash(int(STORY["reward"]))
		message = "《%s》完成 +¥%d" % [STORY["title"], int(STORY["reward"])]
		_save()
		return {"completed": true, "message": message}
	for i in steps.size():
		if str(steps[i]["id"]) == next:
			step_index = i
			break
	_save()
	var ns: Dictionary = steps[step_index]
	return {"advanced": true, "step": ns, "message": _dialogue_text(ns),
		"options": _options_of(ns)}


## 调试跳转检测（位移 >45m 判定，原版如此）
func note_position(pos: Vector2) -> void:
	if _last_pos == Vector2.ZERO:
		_last_pos = pos
		return
	if pos.distance_to(_last_pos) > DEBUG_JUMP_DISTANCE and active:
		debug_jumps += 1
		_save()
	_last_pos = pos


func status() -> Dictionary:
	var s := current_step()
	return {
		"title": STORY["title"],
		"synopsis": SYNOPSIS,
		"active": active,
		"step": step_index,
		"stepId": str(s.get("id", "")),
		"completed": completed,
		"debugJumps": debug_jumps,
		"pendingDialogue": not pending_dialogue.is_empty(),
		"message": message,
	}
