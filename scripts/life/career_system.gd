extends RefCounted
class_name CareerSystem
##
## 城市职业系统 —— 逐项移植原版 src/city-career.ts + city-career-experience.ts。
##
## 结构（照搬原版数值）：
##   3 个身份：日结打工者 / 职场人 / 城市工人
##   5 个地点：hub（生活驿站）/ bay（湾边）/ office（科苑）/ park（公园养护站）/ workshop
##   6 个合约：每个身份 2 个，requiredLevel 1 与 2
##     objective 类型 pickup / dropoff / service（service 需原地停留 7/9/10/11 秒）
##     basePay 依次 190 / 330 / 230 / 315 / 260 / 350
##   deadline = 里程 / 11 + 55（秒）
##   品质从 100 起：交付超时每秒 −0.38；comfort 按急刹/急转扣分
##   结算 = (basePay × (0.65 + 0.65 × q/100) + 18 + 关系 × 4 + 25) × 1.08
##   每单 +100 XP，200 XP 升 1 级
##   4 项升级；3 位关系值 0–20；每身份第 1、3 单触发对话选择（共 6 条）

enum Objective { PICKUP, DROPOFF, SERVICE }
enum ContractState { LOCKED, AVAILABLE, ACTIVE, DONE }

const XP_PER_LEVEL := 200
const XP_PER_CONTRACT := 100
const QUALITY_START := 100.0
const QUALITY_TIMEOUT_RATE := 0.38
const DEADLINE_PER_METRE := 11.0
const DEADLINE_BASE := 55.0
const RELATION_MAX := 20

const IDENTITIES := [
	{"id": "daily", "name": "日结打工者", "contracts": [0, 1]},
	{"id": "office", "name": "职场人", "contracts": [2, 3]},
	{"id": "worker", "name": "城市工人", "contracts": [4, 5]},
]

## 5 个地点（对应 life-sites.json 与地标 arrival）
const PLACES := ["hub", "bay", "office", "park", "workshop"]

## 6 个合约
const CONTRACTS := [
	{"id": "daily-1", "identity": 0, "level": 1, "name": "早班分拣",
	 "objective": Objective.PICKUP, "from": "hub", "to": "bay", "base_pay": 190, "service_seconds": 7.0},
	{"id": "daily-2", "identity": 0, "level": 2, "name": "午市跑腿",
	 "objective": Objective.DROPOFF, "from": "bay", "to": "hub", "base_pay": 330, "service_seconds": 9.0},
	{"id": "office-1", "identity": 1, "level": 1, "name": "园区代送",
	 "objective": Objective.PICKUP, "from": "office", "to": "hub", "base_pay": 230, "service_seconds": 10.0},
	{"id": "office-2", "identity": 1, "level": 2, "name": "会议物料",
	 "objective": Objective.SERVICE, "from": "office", "to": "park", "base_pay": 315, "service_seconds": 11.0},
	{"id": "worker-1", "identity": 2, "level": 1, "name": "绿化补种",
	 "objective": Objective.SERVICE, "from": "park", "to": "workshop", "base_pay": 260, "service_seconds": 9.0},
	{"id": "worker-2", "identity": 2, "level": 2, "name": "夜间巡线",
	 "objective": Objective.DROPOFF, "from": "workshop", "to": "bay", "base_pay": 350, "service_seconds": 10.0},
]

## 4 项升级
const UPGRADES := [
	{"id": "route", "name": "熟路", "desc": "订单时限 +12%"},
	{"id": "comfort", "name": "稳当", "desc": "舒适度扣分减半"},
	{"id": "gear", "name": "装备", "desc": "基础报酬 +8%"},
	{"id": "network", "name": "人脉", "desc": "关系收益翻倍"},
]

## 6 条关系对话（每身份第 1、2 单各一条）
## ⚠️ 曾经这里写的是 daily-3 / office-3 / worker-3，但 CONTRACTS 里每个身份只有
## 2 单（*-1 / *-2），根本没有 *-3 —— 那 3 条对话永远匹配不上，是死数据。
const DIALOGUES := [
	{"id": "daily-1", "identity": 0, "line": "老陈：年轻人，先把手上的单子跑顺，钱是跑出来的。",
	 "options": [{"text": "我明白，慢慢来", "relationship": 1}, {"text": "我想跑得更快", "relationship": 0}]},
	{"id": "daily-2", "identity": 0, "line": "阿芳：今天这单远，路上记得吃饭。",
	 "options": [{"text": "谢谢，我会的", "relationship": 2}, {"text": "先跑完再说", "relationship": 0}]},
	{"id": "office-1", "identity": 1, "line": "阿琳：这套流程你比我熟，回头请你喝咖啡。",
	 "options": [{"text": "顺手的事", "relationship": 1}, {"text": "记得那杯咖啡", "relationship": 2}]},
	{"id": "office-2", "identity": 1, "line": "主管：物料对齐了，周五不用再加班。",
	 "options": [{"text": "那我先走了", "relationship": 0}, {"text": "还有别的要处理吗", "relationship": 2}]},
	{"id": "worker-1", "identity": 2, "line": "养护站班长：树要按风向种，不然长不直。",
	 "options": [{"text": "我记住了", "relationship": 1}, {"text": "让我试试看", "relationship": 2}]},
	{"id": "worker-2", "identity": 2, "line": "同事：夜里的湾边风大，注意脚下。",
	 "options": [{"text": "你也是", "relationship": 2}, {"text": "习惯了", "relationship": 0}]},
]

var world: CityWorld

var identity: int = 0
var level := 1
var xp := 0
var quality := QUALITY_START
var relations: Array = [0, 0, 0]
var upgrades: Array = []
var money := 0
var completed: Array = []
var active_contract := -1
var contract_state: int = ContractState.AVAILABLE
var elapsed := 0.0
var deadline := 0.0
var service_timer := 0.0
var message := ""
var event_log: Array = []


func setup(p_world: CityWorld) -> void:
	world = p_world
	_load()


func _load() -> void:
	var d := SaveSystem.load_section(SaveSystem.career_key())
	if d.is_empty():
		return
	identity = int(d.get("identity", 0))
	level = int(d.get("level", 1))
	xp = int(d.get("xp", 0))
	relations.clear()
	for r in d.get("relations", [0, 0, 0]):
		relations.append(int(r))
	completed.clear()
	for c in d.get("completed", []):
		completed.append(str(c))
	upgrades.clear()
	for u in d.get("upgrades", []):
		upgrades.append(str(u))
	money = int(d.get("money", 0))


func _save() -> void:
	SaveSystem.save_section(SaveSystem.career_key(), {
		"identity": identity, "level": level, "xp": xp,
		"relations": relations, "completed": completed,
		"upgrades": upgrades, "money": money,
	})


func set_identity(i: int) -> void:
	if i < 0 or i >= IDENTITIES.size():
		return
	identity = i
	level = 1
	xp = 0
	_save()
	event_log.append("身份切换为 %s" % IDENTITIES[i]["name"])


## 地点坐标：优先用地标 arrival，否则用 life-sites
func place_position(place_id: String) -> Vector2:
	var lm := CityData.landmark_by_id(place_id)
	if not lm.is_empty():
		var arr: Array = lm.get("arrival", [])
		if arr.size() >= 2:
			return Vector2(float(arr[0]), float(arr[1]))
		return Vector2(float(lm.get("x", 0.0)), float(lm.get("z", 0.0)))
	var sites: Dictionary = CityData.life_sites()
	for s in sites.get("sites", []):
		var sid := str(s.get("id", ""))
		if sid == place_id or (place_id == "hub" and sid == "hub"):
			var arr2: Array = s.get("arrival", [])
			if arr2.size() >= 2:
				return Vector2(float(arr2[0]), float(arr2[1]))
	return Vector2.ZERO


func available_contracts() -> Array:
	var out: Array = []
	for i in CONTRACTS.size():
		var c: Dictionary = CONTRACTS[i]
		if int(c["identity"]) != identity:
			continue
		if completed.has(str(c["id"])):
			continue
		if int(c["level"]) > level:
			continue
		out.append(i)
	return out


func accept(index: int) -> bool:
	if index < 0 or index >= CONTRACTS.size():
		return false
	if not available_contracts().has(index):
		return false
	active_contract = index
	contract_state = ContractState.ACTIVE
	quality = QUALITY_START
	elapsed = 0.0
	service_timer = 0.0
	var c: Dictionary = CONTRACTS[index]
	var from := place_position(str(c["from"]))
	var to := place_position(str(c["to"]))
	var dist := from.distance_to(to)
	deadline = dist / DEADLINE_PER_METRE + DEADLINE_BASE
	if upgrades.has("route"):
		deadline *= 1.12
	message = "已接下：%s（限时 %.0fs）" % [c["name"], deadline]
	event_log.append(message)
	return true


## 每帧推进：超时扣品质、service 累计停留时间
func step(delta: float, pos: Vector2, speed: float, hard_brake: bool, hard_turn: bool) -> Dictionary:
	if contract_state != ContractState.ACTIVE or active_contract < 0:
		return {}
	var c: Dictionary = CONTRACTS[active_contract]
	elapsed += delta

	if elapsed > deadline:
		quality = maxf(0.0, quality - QUALITY_TIMEOUT_RATE * delta * 60.0)

	var comfort_penalty := 0.0
	if hard_brake:
		comfort_penalty += 0.9
	if hard_turn:
		comfort_penalty += 0.4
	if upgrades.has("comfort"):
		comfort_penalty *= 0.5
	quality = maxf(0.0, quality - comfort_penalty)

	if int(c["objective"]) == Objective.SERVICE:
		var target := place_position(str(c["to"]))
		if pos.distance_to(target) < 20.0 and absf(speed) < 1.5:
			service_timer += delta
			if service_timer >= float(c["service_seconds"]):
				return complete()
			return {"servicing": true, "progress": service_timer / float(c["service_seconds"])}
		else:
			service_timer = 0.0
		return {"servicing": false, "progress": 0.0}

	var dest := place_position(str(c["to"]))
	if pos.distance_to(dest) < 20.0 and absf(speed) < 1.5:
		return complete()
	return {"servicing": false, "progress": 0.0}


func complete() -> Dictionary:
	if active_contract < 0:
		return {}
	var c: Dictionary = CONTRACTS[active_contract]
	var rel_bonus := 0.0
	if upgrades.has("network"):
		rel_bonus = float(relations[identity] * 4) * 2.0
	else:
		rel_bonus = float(relations[identity] * 4)
	var gear_bonus := 1.08 if upgrades.has("gear") else 1.0
	var pay := (float(c["base_pay"]) * (0.65 + 0.65 * quality / 100.0)
		+ 18.0 + rel_bonus + 25.0) * 1.08 * gear_bonus
	var reward := int(round(pay))

	GameState.add_cash(reward)
	money += reward
	completed.append(str(c["id"]))
	xp += XP_PER_CONTRACT
	while xp >= XP_PER_LEVEL:
		xp -= XP_PER_LEVEL
		level += 1

	var dialogue := _dialogue_for(str(c["id"]))
	message = "结算 +¥%d（品质 %.0f）" % [reward, quality]
	event_log.append(message)
	active_contract = -1
	contract_state = ContractState.DONE
	_save()
	return {"completed": true, "reward": reward, "quality": quality,
			"level": level, "dialogue": dialogue, "message": message}


func _dialogue_for(contract_id: String) -> Dictionary:
	for d in DIALOGUES:
		if str(d["id"]) == contract_id:
			return d
	return {}


func choose_dialogue_option(dialogue: Dictionary, option: int) -> void:
	var opts: Array = dialogue.get("options", [])
	if option < 0 or option >= opts.size():
		return
	var gain := int(opts[option].get("relationship", 0))
	if upgrades.has("network"):
		gain *= 2
	relations[identity] = mini(RELATION_MAX, relations[identity] + gain)
	_save()


func buy_upgrade(id: String) -> bool:
	if upgrades.has(id):
		return false
	for u in UPGRADES:
		if str(u["id"]) == id:
			upgrades.append(id)
			_save()
			return true
	return false


func status() -> Dictionary:
	return {
		"identity": IDENTITIES[identity]["name"],
		"level": level, "xp": xp,
		"quality": quality,
		"relations": relations.duplicate(),
		"upgrades": upgrades.duplicate(),
		"completed": completed.size(),
		"active": active_contract,
		"contract": CONTRACTS[active_contract]["name"] if active_contract >= 0 else "",
		"deadline": deadline, "elapsed": elapsed,
		"earned": money,
		"available": available_contracts(),
		"message": message,
	}
