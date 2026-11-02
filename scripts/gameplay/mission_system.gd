extends RefCounted
##
## 街头任务系统 v1 —— GTA 式"进光标触发 → 做目标 → 拿赏金"（GTA化 §2.4）。
##
## 与 CareerSystem（打工合约：取送/服务/工资条）互补，这里是"外快"：
##   - 任务模板来自 data/game/missions.json（缺文件时用内置兜底）；
##   - 触发点/目标点**运行时**从路网主分量节点里选（城市坐标不写死在 JSON 里，
##     换图不用改数据）；竞速检查点用 graph.route() 折线按 350m 采样；
##   - 三种类型：
##       deliver    送货：到目标点 20m 内完成；
##       race       竞速：按顺序过检查点（30m 半径，开车过的）；
##       eliminate  清场：在目标街区半径内放倒 targets 个行人（武器命中上报）；
##   - 计时任务超时 / 被捕 / 被击倒 → 任务失败（on_busted 由 main_game 调）；
##   - 赏金走 GameState.add_cash（与生涯共用钱包，存档自带）。
##
## 由 main_game 持有：step(delta, pos, speed) 每帧喂；事件经返回值传出
## （toast 文案 + marker 变更），main_game 负责 HUD 与地图标记。

## 备选光标数（地图上同时存在的任务标记）
const OFFER_COUNT := 2
## 光标重排周期（秒）：玩家走远了才挪
const OFFER_REFRESH := 20.0
## 光标触发半径（米，数据坐标）
const TRIGGER_RADIUS := 12.0
## 光标离玩家过远时重排
const OFFER_STALE_DIST := 1500.0
## deliver/race 的判定半径
const TARGET_RADIUS := 20.0
const CHECKPOINT_RADIUS := 30.0
## 竞速检查点采样间距（沿 route 折线）
const CHECKPOINT_SPACING := 350.0
## step 内部节流
const STEP_HZ := 0.2

const DEFAULT_MISSIONS := {
	"missions": [
		{"id": "deliver-1", "type": "deliver", "name": "湾边急件",
			"brief": "有个包裹要送到湾边去，路上别惹警察。",
			"reward": 500, "time_limit": 0,
			"trigger_min": 300, "trigger_max": 1200,
			"target_min": 600, "target_max": 2500},
		{"id": "race-1", "type": "race", "name": "滨海竞速",
			"brief": "沿检查点跑完全程，别在中途把车撞散了。",
			"reward": 800, "time_limit": 0,
			"trigger_min": 300, "trigger_max": 1200,
			"checkpoints": 5, "leg_min": 1500, "leg_max": 4000},
		{"id": "eliminate-1", "type": "eliminate", "name": "清理街区",
			"brief": "去目标街区放倒 4 个人，干完赶紧甩掉通缉。",
			"reward": 650, "time_limit": 0,
			"trigger_min": 300, "trigger_max": 1000,
			"target_min": 300, "target_max": 900,
			"targets": 4, "area_radius": 150},
	]
}

var world: CityWorld
var enabled := true

## 当前光标（可触发的任务 offer）：{tpl, pos}
var offers: Array = []
## 进行中的任务：{tpl, state 数据…}；空 = 无任务
var active: Dictionary = {}
var earned_total := 0
var completed_count := 0

var _rng := RandomNumberGenerator.new()
var _step_acc := 0.0
var _offer_timer := 0.0
var _templates: Array = []


func setup(p_world: CityWorld) -> void:
	world = p_world
	_rng.seed = 20261104
	_load_templates()
	_refresh_offers(Vector2.ZERO, true)


func _load_templates() -> void:
	_templates.clear()
	var parsed = null
	if FileAccess.file_exists("res://data/game/missions.json"):
		var f := FileAccess.open("res://data/game/missions.json", FileAccess.READ)
		if f != null:
			parsed = JSON.parse_string(f.get_as_text())
	if parsed == null or not (parsed is Dictionary) or not parsed.has("missions"):
		push_warning("[MissionSystem] missions.json 缺失/损坏，用内置兜底任务")
		parsed = DEFAULT_MISSIONS
	for m in parsed["missions"]:
		if m is Dictionary and m.has("id") and m.has("type"):
			_templates.append(m)
	if _templates.is_empty():
		_templates = DEFAULT_MISSIONS["missions"].duplicate()


# ---------------------------------------------------------------------------
# 选点（路网 degree≥2 节点，线性扫——只在生成光标/目标时偶发调用）
# ---------------------------------------------------------------------------

func _pick_node(near: Vector2, min_d: float, max_d: float) -> int:
	var graph := world.graph
	if graph == null or graph.nodes.is_empty():
		return -1
	var candidates: Array = []
	for i in graph.nodes.size():
		if graph.degree(i) < 2:
			continue
		var d := graph.nodes[i].distance_to(near)
		if d >= min_d and d <= max_d:
			candidates.append(i)
	if candidates.is_empty():
		return -1
	return candidates[_rng.randi_range(0, candidates.size() - 1)]


# ---------------------------------------------------------------------------
# 光标（offer）管理
# ---------------------------------------------------------------------------

func _refresh_offers(pos: Vector2, force := false) -> void:
	if world == null or world.graph == null:
		return
	# 玩家没走太远且光标还新鲜 → 不动
	if not force and not offers.is_empty():
		var stale := true
		for o in offers:
			if o["pos"].distance_to(pos) < OFFER_STALE_DIST:
				stale = false
				break
		if not stale:
			return
	offers.clear()
	for _i in OFFER_COUNT:
		var nid := _pick_node(pos, 300.0, 1500.0)
		if nid < 0:
			break
		var tpl: Dictionary = _templates[_rng.randi_range(0, _templates.size() - 1)]
		offers.append({"tpl": tpl, "pos": world.graph.nodes[nid]})


# ---------------------------------------------------------------------------
# 每帧
# ---------------------------------------------------------------------------

## 返回事件（可叠加多帧攒下的事件）：
##   {event: started|checkpoint|completed|failed, text, marker}
## marker：{pos, name} 光标变更（含清空 {}），main_game 拿去刷地图标记。
func step(delta: float, pos: Vector2, speed: float) -> Dictionary:
	if not enabled:
		return {}
	_step_acc += delta
	if _step_acc < STEP_HZ:
		return {}
	var dt := _step_acc
	_step_acc = 0.0

	# 1) 无任务：维护光标 + 触发判定
	if active.is_empty():
		_offer_timer -= dt
		if _offer_timer <= 0.0:
			_offer_timer = OFFER_REFRESH
			var before := _marker()
			_refresh_offers(pos)
			if _marker_changed(before):
				return {"event": "offers", "text": "",
					"marker": _marker()}
		for o in offers:
			if o["pos"].distance_to(pos) < TRIGGER_RADIUS:
				return _start(o, pos)
		return {}

	# 2) 有任务：推进
	return _step_active(dt, pos, speed)


func _marker() -> Dictionary:
	if not active.is_empty():
		var m: Dictionary = active["marker"]
		return m
	if not offers.is_empty():
		return {"pos": offers[0]["pos"], "name": "任务光标"}
	return {}


func _marker_changed(before: Dictionary) -> bool:
	var now := _marker()
	if before.is_empty() != now.is_empty():
		return true
	if now.is_empty():
		return false
	return before["pos"] != now["pos"]


func _start(offer: Dictionary, pos: Vector2) -> Dictionary:
	var tpl: Dictionary = offer["tpl"]
	var type := str(tpl["type"])
	offers.clear()
	active = {"tpl": tpl, "type": type, "elapsed": 0.0, "count": 0}
	var marker := {}
	var text := ""

	if type == "deliver":
		var nid := _pick_node(offer["pos"], float(tpl.get("target_min", 600.0)),
			float(tpl.get("target_max", 2500.0)))
		if nid < 0:
			active = {}
			return {"event": "failed", "text": "任务生成失败", "marker": _marker()}
		var target: Vector2 = world.graph.nodes[nid]
		active["target"] = target
		# 限时：JSON 指定 > 按路程推导（与生涯合约同款 11m/s + 60s 底）
		var tl := float(tpl.get("time_limit", 0.0))
		if tl <= 0.0:
			tl = offer["pos"].distance_to(target) / 11.0 + 60.0
		active["time_limit"] = tl
		marker = {"pos": target, "name": tpl["name"]}
		text = "%s：%.0f 秒内送到目的地" % [tpl["name"], tl]

	elif type == "race":
		var nid := _pick_node(offer["pos"], float(tpl.get("leg_min", 1500.0)),
			float(tpl.get("leg_max", 4000.0)))
		if nid < 0:
			active = {}
			return {"event": "failed", "text": "任务生成失败", "marker": _marker()}
		var finish: Vector2 = world.graph.nodes[nid]
		var line: PackedVector2Array = world.graph.route(offer["pos"], finish)
		var cps := _sample_checkpoints(line, int(tpl.get("checkpoints", 5)))
		if cps.size() < 2:
			active = {}
			return {"event": "failed", "text": "路线规划失败", "marker": _marker()}
		active["checkpoints"] = cps
		var tl := float(tpl.get("time_limit", 0.0))
		if tl <= 0.0:
			# 按全程折线长 / 12m/s 再放宽 35%
			var total := 0.0
			for i in range(1, line.size()):
				total += line[i - 1].distance_to(line[i])
			tl = total / 12.0 * 1.35
		active["time_limit"] = tl
		marker = {"pos": cps[0], "name": "检查点 1/%d" % cps.size()}
		text = "%s：%d 个检查点，%.0f 秒内跑完" % [tpl["name"], cps.size(), tl]

	elif type == "eliminate":
		var nid := _pick_node(offer["pos"], float(tpl.get("target_min", 300.0)),
			float(tpl.get("target_max", 900.0)))
		if nid < 0:
			active = {}
			return {"event": "failed", "text": "任务生成失败", "marker": _marker()}
		var target: Vector2 = world.graph.nodes[nid]
		active["target"] = target
		active["radius"] = float(tpl.get("area_radius", 150.0))
		active["need"] = int(tpl.get("targets", 4))
		var tl := float(tpl.get("time_limit", 0.0))
		active["time_limit"] = tl
		marker = {"pos": target, "name": tpl["name"]}
		text = "%s：去目标街区放倒 %d 个人" % [tpl["name"], active["need"]]
	else:
		active = {}
		return {"event": "failed", "text": "未知任务类型 " + type, "marker": {}}

	active["marker"] = marker
	var brief: String = str(tpl.get("brief", ""))
	if not brief.is_empty():
		text = brief + "\n" + text
	return {"event": "started", "text": text, "marker": marker}


## 沿 route 折线按 CHECKPOINT_SPACING 采样检查点（终点必收）
func _sample_checkpoints(line: PackedVector2Array, want: int) -> Array:
	var out: Array = []
	if line.size() < 2:
		return out
	var acc := 0.0
	var next_at := CHECKPOINT_SPACING
	for i in range(1, line.size()):
		var seg := line[i - 1].distance_to(line[i])
		acc += seg
		while acc >= next_at and out.size() < want - 1:
			out.append(line[i])
			next_at += CHECKPOINT_SPACING
	out.append(line[line.size() - 1])
	return out


func _step_active(dt: float, pos: Vector2, _speed: float) -> Dictionary:
	active["elapsed"] = float(active["elapsed"]) + dt
	var tl := float(active.get("time_limit", 0.0))
	if tl > 0.0 and float(active["elapsed"]) > tl:
		return _fail("超时了")
	var type := str(active["type"])

	if type == "deliver":
		if pos.distance_to(active["target"]) < TARGET_RADIUS:
			return _complete()
	elif type == "race":
		var cps: Array = active["checkpoints"]
		var idx := int(active["count"])
		if idx < cps.size() and pos.distance_to(cps[idx]) < CHECKPOINT_RADIUS:
			active["count"] = idx + 1
			if int(active["count"]) >= cps.size():
				return _complete()
			var next_cp: Vector2 = cps[int(active["count"])]
			return {"event": "checkpoint",
				"text": "检查点 %d/%d" % [int(active["count"]), cps.size()],
				"marker": {"pos": next_cp, "name": "检查点 %d/%d" % [int(active["count"]) + 1, cps.size()]}}
	elif type == "eliminate":
		# 进度由 note_hit() 上报（pending_text），这里负责把进度吐成事件
		if int(active["count"]) >= int(active["need"]):
			return _complete()
		if active.has("pending_text"):
			var t := str(active["pending_text"])
			active.erase("pending_text")
			return {"event": "progress", "text": t}
	return {}


## 武器命中上报（main_game._step_weapons 调）：eliminate 任务的进度来源
func note_hit(pos: Vector2) -> void:
	if active.is_empty() or str(active["type"]) != "eliminate":
		return
	if pos.distance_to(active["target"]) > float(active["radius"]):
		return
	active["count"] = int(active["count"]) + 1
	if int(active["count"]) < int(active["need"]):
		active["pending_text"] = "目标进度 %d/%d" % [int(active["count"]), int(active["need"])]


## 被捕 / 被击倒：任务失败
func on_busted() -> Dictionary:
	if active.is_empty():
		return {}
	return _fail("你在任务里被拿下了")


func _fail(reason: String) -> Dictionary:
	var name := str(active["tpl"]["name"])
	active = {}
	# 光标重新铺开
	_refresh_offers(Vector2.ZERO, true)
	return {"event": "failed", "text": "任务失败「%s」：%s" % [name, reason],
		"marker": _marker()}


func _complete() -> Dictionary:
	var tpl: Dictionary = active["tpl"]
	var reward := int(tpl.get("reward", 300))
	GameState.add_cash(reward)
	earned_total += reward
	completed_count += 1
	active = {}
	_refresh_offers(Vector2.ZERO, true)
	return {"event": "completed",
		"text": "任务完成「%s」+¥%d" % [tpl["name"], reward],
		"reward": reward, "marker": _marker()}


# ---------------------------------------------------------------------------
# 诊断
# ---------------------------------------------------------------------------

func status() -> Dictionary:
	var s := {
		"offers": offers.size(),
		"completed": completed_count,
		"earned": earned_total,
	}
	if not active.is_empty():
		s["active"] = str(active["tpl"]["name"])
		s["type"] = str(active["type"])
		s["elapsed"] = snappedf(float(active["elapsed"]), 0.1)
		s["time_limit"] = float(active.get("time_limit", 0.0))
		s["progress"] = int(active.get("count", 0))
		# 总量：eliminate = 目标人数；race = 检查点数（deliver 无进度计数）
		if str(active["type"]) == "eliminate":
			s["total"] = int(active.get("need", 0))
		elif str(active["type"]) == "race":
			s["total"] = (active.get("checkpoints", []) as Array).size()
	return s


## 小地图标记（HUD 完善包）：无任务时 = 任务光标（金点）；有任务时 = 当前目标
func blips() -> Array:
	var out: Array = []
	var gold := Color(0.91, 0.71, 0.30)
	if active.is_empty():
		for o in offers:
			out.append({"x": o["pos"].x, "z": o["pos"].y, "color": gold, "r": 4.5})
		return out
	var m: Dictionary = active.get("marker", {})
	if not m.is_empty() and m["pos"] is Vector2:
		var mp: Vector2 = m["pos"]
		out.append({"x": mp.x, "z": mp.y, "color": gold, "r": 5.0})
	return out
