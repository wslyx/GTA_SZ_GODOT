extends RefCounted
class_name Rides
##
## 出租车订单与生活驿站 —— 对应原版 src/city-life.ts + city-life-hub.ts。
##
## 3 条订单（原版数据）：
##   coast-shift   老陈 · 从出生点沿 yaw 方向 155m 处上车，送到 900m 处的路点，¥128
##   office-evening 阿琳 · 市民中心 → 香蜜，¥160
##   day-pay       阿辉 · 腾讯滨海大厦 → 人才公园，¥220
##
## 状态机：idle → pickup（乘客在 from 点等待）
##              → riding（已上车，前往 destination）
##              → 结算（到达、停稳、里程 ≥150m）
##
## 结算条件（原版 settleRide）：phase=riding 且未结算 且 atDestination 且 |speed|≤1
##   且 odometer − startOdometer ≥ 150
## 一旦 debugJump 标记过，该单永不可结算。

const PICKUP_RADIUS := 28.0
const SETTLE_SPEED := 1.0
const MIN_ODOMETER := 150.0

enum Phase { IDLE, PICKUP, RIDING, SETTLED }

## 三个生活驿站的交互点（life-sites.json + life-hub.json）
const HUB_INTERACTIONS := {
	"entry": Vector2(0.0, -4.35),
	"delivery": Vector2(3.95, -4.45),
	"rest": Vector2(-3.65, -3.3),
}

var world: CityWorld
var rides: Array = []
var sites: Array = []

var active_ride := -1
var phase: int = Phase.IDLE
var odometer := 0.0
var start_odometer := 0.0
var debugged := false
var settled_count := 0
## 调试跳转阈值（米）：单帧位移超过它就判定为瞬移/调试
const DEBUG_JUMP_DISTANCE := 45.0
var _last_pos := Vector2.ZERO
var cash_earned := 0
var message := ""


func setup(p_world: CityWorld) -> void:
	world = p_world
	_build_sites()
	_build_rides()


func _build_sites() -> void:
	sites.clear()
	var data: Dictionary = CityData.life_sites()
	for s in data.get("sites", []):
		sites.append({
			"id": str(s.get("id", "")),
			"name": str(s.get("name", "")),
			"x": float(s.get("x", 0.0)),
			"z": float(s.get("z", 0.0)),
			"heading": float(s.get("heading", 0.0)),
			# 不能写 s.get("arrival", [0,0])[0]：get() 返回 Variant，
			# 一旦 arrival 存的是 Vector2（Godot 4 的 Vector2 不支持 [] 下标）就会运行时报错。
			"arrival": _arrival_of(s.get("arrival")),
			"yaw": float(s.get("yaw", 0.0)),
			"road": str(s.get("road", "")),
			"footprint": s.get("footprint", []),
		})


## arrival 可能是 [x, z] 数组，也可能已经是 Vector2 —— 统一成一个 Vector2
static func _arrival_of(v: Variant) -> Vector2:
	if v is Vector2:
		return v
	if v is Array:
		var a: Array = v
		if a.size() >= 2:
			return Vector2(float(a[0]), float(a[1]))
	return Vector2.ZERO


## 沿某条路网方向找距离 d 处的路点（原版用地标间的实际路网）
func _point_along(from: Vector2, yaw: float, dist: float) -> Vector2:
	if world == null or world.graph == null or world.graph.nodes.is_empty():
		return from + Vector2(sin(yaw), cos(yaw)) * dist
	var dir := Vector2(sin(yaw), cos(yaw))
	var best := from
	var best_score := -INF
	for n in world.graph.nodes:
		var v := n - from
		var along := v.dot(dir)
		if along < dist * 0.6 or along > dist * 1.4:
			continue
		var lateral := absf(v.x * dir.y - v.y * dir.x)
		var score := along - lateral * 3.0
		if score > best_score:
			best_score = score
			best = n
	return best


func _build_rides() -> void:
	rides.clear()
	var spawn := CityData.spawn_pos
	var spawn_yaw := CityData.spawn_yaw

	# coast-shift：老陈
	rides.append({
		"id": "coast-shift", "name": "老陈 · 沿海班次", "driver": "老陈",
		"reward": 128, "from": _point_along(spawn, spawn_yaw, 155.0),
		"to": _point_along(spawn, spawn_yaw, 900.0), "done": false,
	})

	# office-evening：阿琳 市民中心 → 香蜜
	var civic := CityData.landmark_by_id("civic")
	var xiangmi := CityData.landmark_by_id("xiangmi")
	var civic_pos := Vector2(float(civic.get("x", 0.0)), float(civic.get("z", 0.0))) if not civic.is_empty() else spawn
	var xiangmi_pos := Vector2(float(xiangmi.get("x", 0.0)), float(xiangmi.get("z", 0.0))) if not xiangmi.is_empty() else spawn
	rides.append({
		"id": "office-evening", "name": "阿琳 · 下班顺路", "driver": "阿琳",
		"reward": 160, "from": civic_pos, "to": xiangmi_pos, "done": false,
	})

	# day-pay：阿辉 腾讯滨海 → 人才公园
	var tencent := CityData.landmark_by_id("tencent")
	var talent := CityData.landmark_by_id("talent")
	var tencent_pos := Vector2(float(tencent.get("x", 0.0)), float(tencent.get("z", 0.0))) if not tencent.is_empty() else spawn
	var talent_pos := Vector2(float(talent.get("x", 0.0)), float(talent.get("z", 0.0))) if not talent.is_empty() else spawn
	rides.append({
		"id": "day-pay", "name": "阿辉 · 结今日工资", "driver": "阿辉",
		"reward": 220, "from": tencent_pos, "to": talent_pos, "done": false,
	})

	for r in rides:
		r["done"] = GameState.completed_rides.has(r["id"])


## 供 HUD：当前可交互的提示
func interaction_hint(pos: Vector2, speed: float) -> Dictionary:
	if active_ride >= 0:
		var r: Dictionary = rides[active_ride]
		if phase == Phase.PICKUP:
			var d := pos.distance_to(r["from"])
			if d < PICKUP_RADIUS and absf(speed) < SETTLE_SPEED:
				return {"key": "E", "text": "接单：%s（¥%d）" % [r["name"], int(r["reward"])]}
			return {"key": "", "text": "前往接客点 · 还有 %.0fm" % d}
		if phase == Phase.RIDING:
			var d2 := pos.distance_to(r["to"])
			return {"key": "", "text": "送达目的地 · 还有 %.0fm" % d2}

	# 未接单时：靠近任一乘客上车点可接单
	for i in rides.size():
		var r2: Dictionary = rides[i]
		if r2["done"]:
			continue
		if pos.distance_to(r2["from"]) < PICKUP_RADIUS and absf(speed) < SETTLE_SPEED:
			return {"key": "E", "text": "接单：%s（¥%d）" % [r2["name"], int(r2["reward"])]}

	# 生活驿站交互
	for s in sites:
		var d3 := pos.distance_to(Vector2(s["x"], s["z"]))
		if d3 < 16.0:
			return {"key": "E", "text": "%s · 可用服务" % s["name"]}
	return {"key": "", "text": ""}


## 按 E 交互
func interact(pos: Vector2, speed: float) -> Dictionary:
	if active_ride >= 0:
		var r: Dictionary = rides[active_ride]
		if phase == Phase.PICKUP and pos.distance_to(r["from"]) < PICKUP_RADIUS and absf(speed) < SETTLE_SPEED:
			phase = Phase.RIDING
			start_odometer = odometer
			message = "%s 上车了" % r["driver"]
			return {"ok": true, "message": message}
		return {"ok": false, "message": ""}

	for i in rides.size():
		var r2: Dictionary = rides[i]
		if r2["done"]:
			continue
		if pos.distance_to(r2["from"]) < PICKUP_RADIUS and absf(speed) < SETTLE_SPEED:
			active_ride = i
			phase = Phase.PICKUP
			# 接新单时清掉上一单的跳变标记，否则一旦 debugged 过就永远结不了单
			debugged = false
			message = "已接单：%s" % r2["name"]
			return {"ok": true, "message": message}
	return {"ok": false, "message": ""}


## 每帧结算判定
func step(pos: Vector2, speed: float, travelled: float) -> Dictionary:
	# 调试跳转检测：debugged 之前在整个仓库里**从没被置过 true**，
	# 下面那句 `or debugged` 永远是假 —— 承诺的"跳变后本单不可结算"完全失效。
	# 这里按位移突变补上判定（与 story_system 的 DEBUG_JUMP_DISTANCE 同一量级）。
	if _last_pos != Vector2.ZERO and pos.distance_to(_last_pos) > DEBUG_JUMP_DISTANCE:
		debugged = true
	_last_pos = pos

	odometer += travelled
	if active_ride < 0 or phase != Phase.RIDING or debugged:
		return {}
	var r: Dictionary = rides[active_ride]
	var at_destination := pos.distance_to(r["to"]) < PICKUP_RADIUS
	if not at_destination or absf(speed) > SETTLE_SPEED:
		return {}
	if odometer - start_odometer < MIN_ODOMETER:
		return {}

	GameState.add_cash(int(r["reward"]))
	GameState.mark_ride_complete(str(r["id"]))
	SaveSystem.save_city_life()
	settled_count += 1
	cash_earned += int(r["reward"])
	r["done"] = true
	phase = Phase.SETTLED
	active_ride = -1
	message = "结算完成 +¥%d" % int(r["reward"])
	return {"settled": true, "reward": int(r["reward"]), "message": message}


func cancel() -> void:
	active_ride = -1
	phase = Phase.IDLE


func status() -> Dictionary:
	return {
		"phase": Phase.keys()[phase],
		"active": active_ride,
		"odometer": odometer,
		"settled": settled_count,
		"earned": cash_earned,
		"rides": rides.size(),
		"sites": sites.size(),
		"message": message,
	}
