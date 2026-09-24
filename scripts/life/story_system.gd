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

const STORY := {
	"id": "bay-last-delivery",
	"title": "最后一单",
	"reward": 180,
	"steps": [
		{"id": "hub-pickup", "place": "hub", "text": "何志把最后一单交到你手上：「跑完这单，今天就收工。」",
		 "options": [{"text": "接过来", "next": "office-meet"}]},
		{"id": "office-meet", "place": "office", "text": "阿琳在楼下等着，手里还攥着一份没送出去的文件。",
		 "options": [
			{"text": "先帮她送文件", "next": "office-spare"},
			{"text": "先把这单送到湾边", "next": "bay-direct"},
		 ]},
		{"id": "office-spare", "place": "park", "text": "养护站的师傅说，这份文件得趁天亮送到公园那头。",
		 "options": [{"text": "我顺路", "next": "park-help"}]},
		{"id": "park-help", "place": "park", "text": "师傅递来一瓶水：「湾边风大，慢点开。」",
		 "options": [{"text": "谢谢", "next": "bay-after-park"}]},
		{"id": "bay-after-park", "place": "bay", "text": "湾边的灯一盏盏亮起来，最后一单终于送到了。",
		 "options": [{"text": "回驿站", "next": "hub-end-direct"}]},
		{"id": "bay-direct", "place": "bay", "text": "你选择先把货送到湾边。阿琳说她明天自己跑一趟。",
		 "options": [{"text": "回驿站", "next": "hub-end-detour"}]},
		{"id": "hub-end-direct", "place": "hub", "text": "驿站的灯还亮着。今天到此为止。",
		 "options": [{"text": "结束", "next": ""}]},
		{"id": "hub-end-detour", "place": "hub", "text": "你把车停好，想了想明天要不要绕远一点。",
		 "options": [{"text": "结束", "next": ""}]},
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
	return {"ok": true, "step": s, "message": str(s["text"])}


## 选择对话选项
func choose(option: int) -> Dictionary:
	if pending_dialogue.is_empty():
		return {}
	var opts: Array = pending_dialogue.get("options", [])
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
	return {"advanced": true, "step": steps[step_index], "message": str(steps[step_index]["text"])}


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
