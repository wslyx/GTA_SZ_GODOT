extends Node
##
## 全局玩家状态（autoload: GameState）。
##
## 两部分：
##  1) 旧城小活的存档状态 —— 一比一对应原 state.ts 的 GameState 与其纯函数
##     （startWork / sortParcel / advanceCheckpoint / payout / buy / meet / nextDay），
##     校验规则同样照搬 validateSave。
##  2) 城市玩法状态 —— 光照模式、天气、画质档、订单完成记录、职业/故事进度。
##
## 状态变化统一发 changed 信号，由 HUD 与存档系统订阅。

signal changed()
signal work_status_changed(status: int)
signal cash_changed(cash: int)
signal journal_updated()

const SAVE_VERSION := 1

# --- 旧城小活 ---------------------------------------------------------------

var day := 1
var cash := 180
var work: int = GameContent.WorkStatus.AVAILABLE
var sorted_count := 0
var correct := 0
var checkpoint := 0
var deliveries := 0
var inventory: Array[String] = []
var relationship := 0
var talked_day := 0
var evening := "none"          ## none | friends | quiet
var location := "street"       ## street | room
var px := 1.0
var pz := 11.0
var minutes := 18 * 60 + 12

# --- 城市玩法 ---------------------------------------------------------------

var light_mode: int = GameContent.LightMode.SUNSET
var rain := false
var graphics_tier := "medium"  ## low | medium | high
var completed_rides: Array[String] = []
var audio_enabled := true
var paused := false


func _ready() -> void:
	reset()


## 新档初值，完全照搬原 freshState() 的数值
func reset() -> void:
	day = 1
	cash = 180
	work = GameContent.WorkStatus.AVAILABLE
	sorted_count = 0
	correct = 0
	checkpoint = 0
	deliveries = 0
	inventory = []
	relationship = 0
	talked_day = 0
	evening = "none"
	location = "street"
	px = 1.0
	pz = 11.0
	minutes = 18 * 60 + 12
	completed_rides = []
	changed.emit()


func emit_changed() -> void:
	changed.emit()


# ---------------------------------------------------------------------------
# 旧城小活：原 state.ts 的纯函数，逐个搬过来
# ---------------------------------------------------------------------------


## 原 validateSave()：不接受则返回 false（GDScript 无法返回 null 联合类型，
## 故用 out_err 传错误原因）
func validate_save(d: Dictionary, out_err: Array) -> bool:
	if int(d.get("version", 0)) != SAVE_VERSION:
		out_err.append("version")
		return false
	var v_day := int(d.get("day", 0))
	if v_day < 1 or v_day > 9999:
		out_err.append("day")
		return false
	var v_cash := float(d.get("cash", -1))
	if not is_finite(v_cash) or v_cash < 0.0 or v_cash > 1e9:
		out_err.append("cash")
		return false
	if not ["available", "sorting", "hauling", "delivered", "paid"].has(str(d.get("work", ""))):
		out_err.append("work")
		return false
	var inv: Array = d.get("inventory", [])
	var seen := {}
	for i in inv:
		var key := str(i)
		if not GameContent.ITEM_PRICES.has(key):
			out_err.append("inventory_unknown")
			return false
		if seen.has(key):
			out_err.append("inventory_duplicate")
			return false
		seen[key] = true
	if int(d.get("sorted", 0)) < 0 or int(d.get("sorted", 0)) > 9:
		out_err.append("sorted")
		return false
	if int(d.get("correct", 0)) < 0 or int(d.get("correct", 0)) > int(d.get("sorted", 0)):
		out_err.append("correct")
		return false
	if int(d.get("checkpoint", 0)) < 0 or int(d.get("checkpoint", 0)) > 3:
		out_err.append("checkpoint")
		return false
	if not ["street", "room"].has(str(d.get("location", ""))):
		out_err.append("location")
		return false
	if not ["none", "friends", "quiet"].has(str(d.get("evening", ""))):
		out_err.append("evening")
		return false
	var work_str := str(d.get("work", ""))
	if work_str == "available" and (int(d.get("sorted", 0)) != 0 or int(d.get("checkpoint", 0)) != 0):
		out_err.append("available_requires_clean")
		return false
	if ["hauling", "delivered", "paid"].has(work_str) and int(d.get("sorted", 0)) != 9:
		out_err.append("hauling_requires_sorted9")
		return false
	if ["delivered", "paid"].has(work_str) and int(d.get("checkpoint", 0)) != 3:
		out_err.append("delivered_requires_cp3")
		return false
	return true


func start_work() -> bool:
	if work != GameContent.WorkStatus.AVAILABLE:
		return false
	work = GameContent.WorkStatus.SORTING
	sorted_count = 0
	correct = 0
	checkpoint = 0
	work_status_changed.emit(work)
	changed.emit()
	return true


## 返回 {correct: bool, done: bool}；不合法返回空字典
func sort_parcel(category: int) -> Dictionary:
	if work != GameContent.WorkStatus.SORTING:
		return {}
	if sorted_count >= GameContent.PACKAGES.size():
		return {}
	if not [0, 1, 2].has(category):
		return {}
	var is_correct: bool = GameContent.PACKAGES[sorted_count]["type"] == category
	if is_correct:
		correct += 1
	sorted_count += 1
	if sorted_count == GameContent.PACKAGES.size():
		work = GameContent.WorkStatus.HAULING
		work_status_changed.emit(work)
	changed.emit()
	return {"correct": is_correct, "done": work == GameContent.WorkStatus.HAULING}


func advance_checkpoint(index: int) -> bool:
	if work != GameContent.WorkStatus.HAULING or index != checkpoint or index >= 3:
		return false
	checkpoint += 1
	if checkpoint == 3:
		work = GameContent.WorkStatus.DELIVERED
		work_status_changed.emit(work)
	changed.emit()
	return true


func payout() -> Dictionary:
	if work != GameContent.WorkStatus.DELIVERED:
		return {}
	var bonus := 40 if inventory.has("raincoat") else int(round(correct / 9.0 * 40.0))
	var result := {"base": 280, "bonus": bonus, "cost": 107, "net": 173 + bonus}
	cash += int(result["net"])
	work = GameContent.WorkStatus.PAID
	deliveries += 1
	work_status_changed.emit(work)
	cash_changed.emit(cash)
	changed.emit()
	return result


func buy(item: String) -> bool:
	if not GameContent.ITEM_PRICES.has(item):
		return false
	if inventory.has(item):
		return false
	if cash < int(GameContent.ITEM_PRICES[item]):
		return false
	cash -= int(GameContent.ITEM_PRICES[item])
	inventory.append(item)
	cash_changed.emit(cash)
	changed.emit()
	return true


func meet(choice: String) -> bool:
	if work != GameContent.WorkStatus.PAID or evening != "none":
		return false
	if not ["friends", "quiet"].has(choice):
		return false
	evening = choice
	if choice == "friends":
		relationship += 1
	changed.emit()
	return true


func next_day() -> bool:
	if work != GameContent.WorkStatus.PAID:
		return false
	day += 1
	work = GameContent.WorkStatus.AVAILABLE
	sorted_count = 0
	correct = 0
	checkpoint = 0
	evening = "none"
	minutes = 18 * 60 + (0 if inventory.has("mattress") else 15)
	location = "street"
	px = -5.0
	pz = 54.0
	work_status_changed.emit(work)
	changed.emit()
	return true


# ---------------------------------------------------------------------------
# 城市玩法
# ---------------------------------------------------------------------------

func add_cash(amount: int) -> void:
	cash += amount
	cash_changed.emit(cash)
	changed.emit()


func mark_ride_complete(ride_id: String) -> void:
	if not completed_rides.has(ride_id):
		completed_rides.append(ride_id)
		changed.emit()


func set_light_mode(mode: int) -> void:
	light_mode = mode
	changed.emit()


func to_dict() -> Dictionary:
	return {
		"version": SAVE_VERSION,
		"day": day, "cash": cash, "work": _work_str(work),
		"sorted": sorted_count, "correct": correct, "checkpoint": checkpoint,
		"deliveries": deliveries, "inventory": inventory.duplicate(),
		"relationship": relationship, "talkedDay": talked_day, "evening": evening,
		"location": location, "x": px, "z": pz, "minutes": minutes,
		"lightMode": light_mode, "rain": rain, "graphicsTier": graphics_tier,
		"completedRides": completed_rides.duplicate(),
	}


func from_dict(d: Dictionary) -> void:
	day = int(d.get("day", 1))
	cash = int(d.get("cash", 180))
	work = _work_from_str(str(d.get("work", "available")))
	sorted_count = int(d.get("sorted", 0))
	correct = int(d.get("correct", 0))
	checkpoint = int(d.get("checkpoint", 0))
	deliveries = int(d.get("deliveries", 0))
	inventory.clear()
	for i in d.get("inventory", []):
		inventory.append(str(i))
	relationship = int(d.get("relationship", 0))
	talked_day = int(d.get("talkedDay", 0))
	evening = str(d.get("evening", "none"))
	location = str(d.get("location", "street"))
	px = float(d.get("x", 1.0))
	pz = float(d.get("z", 11.0))
	minutes = int(d.get("minutes", 18 * 60 + 12))
	light_mode = int(d.get("lightMode", GameContent.LightMode.SUNSET))
	rain = bool(d.get("rain", false))
	graphics_tier = str(d.get("graphicsTier", "medium"))
	completed_rides.clear()
	for r in d.get("completedRides", []):
		completed_rides.append(str(r))
	changed.emit()


func _work_str(w: int) -> String:
	match w:
		GameContent.WorkStatus.AVAILABLE: return "available"
		GameContent.WorkStatus.SORTING: return "sorting"
		GameContent.WorkStatus.HAULING: return "hauling"
		GameContent.WorkStatus.DELIVERED: return "delivered"
		GameContent.WorkStatus.PAID: return "paid"
	return "available"


func _work_from_str(s: String) -> int:
	match s:
		"sorting": return GameContent.WorkStatus.SORTING
		"hauling": return GameContent.WorkStatus.HAULING
		"delivered": return GameContent.WorkStatus.DELIVERED
		"paid": return GameContent.WorkStatus.PAID
	return GameContent.WorkStatus.AVAILABLE


## 时钟读数（受光照模式影响，与原版 HUD 一致）
func clock_text() -> String:
	match light_mode:
		GameContent.LightMode.DAY: return GameContent.CLOCK["day"]
		GameContent.LightMode.NIGHT: return GameContent.CLOCK["night"]
	return GameContent.CLOCK["default"]
