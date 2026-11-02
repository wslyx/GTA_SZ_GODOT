extends RefCounted
##
## 街头商店 v1 —— 军品店（买枪/补弹）+ 面馆（回血）（GTA化 §4.3）。
##
## 位置挂在生涯生活站点上（复用 CareerSystem.place_position 的地标/life-sites
## 定位），E 键交互、复用对话面板选购（panels.show_dialogue + 数字键）。
## 购买只做**判定与扣钱**（GameState.add_cash），效果（回血/解锁枪/补弹）由
## main_game 按 action 应用 —— 商店系统不持有玩家/武器引用。
## 购买记录（已购枪）经 SaveSystem 持久化。

const SHOP_RADIUS := 16.0
const PRICE_AMMO := 150
const PRICE_SMG := 800
const PRICE_SHOTGUN := 1200
const PRICE_MEAL := 100

const SHOPS := [
	{"id": "gunshop", "place": "workshop", "name": "军品店",
		"line": "军品店老板：弹药管够，货也硬。看上哪个？"},
	{"id": "diner", "place": "hub", "name": "老码头面馆",
		"line": "面馆老板：刚出锅的，吃完满血复活。"},
]

var world: CityWorld
## 与 weapon_system.WEAPONS 同序的拥有表：手枪默认有，冲锋枪/霰弹枪要买
var owned_guns: Array = [true, false, false]
var total_spent := 0
var purchase_count := 0
## 商店位置（id → 数据坐标 Vector2）。⚠️ 不能写回 SHOPS —— 它是 const，
## Godot 4 里 const 容器深度只读，`s["pos"] = ...` 会抛
## "Invalid assignment on read-only value (on base: 'Dictionary')"，
## 位置永远写不进去，near_shop 永远返回 {}（商店整个失效）。
var _pos := {}


func setup(p_world: CityWorld, career, _weapons) -> void:
	world = p_world
	for s in SHOPS:
		_pos[str(s["id"])] = career.place_position(str(s["place"]))
	_load()


func _load() -> void:
	var d: Dictionary = SaveSystem.load_section(SaveSystem.shop_key())
	if d.is_empty():
		return
	owned_guns.clear()
	for o in d.get("owned_guns", [true, false, false]):
		owned_guns.append(bool(o))
	total_spent = int(d.get("total_spent", 0))
	purchase_count = int(d.get("purchase_count", 0))


func _save() -> void:
	SaveSystem.save_section(SaveSystem.shop_key(), {
		"owned_guns": owned_guns, "total_spent": total_spent,
		"purchase_count": purchase_count,
	})


## pos（数据坐标）附近半径内的商店；不在任何商店旁返回 {}
func near_shop(pos: Vector2) -> Dictionary:
	for s in SHOPS:
		var sp: Vector2 = _pos.get(str(s["id"]), Vector2.ZERO)
		if sp != Vector2.ZERO and pos.distance_to(sp) < SHOP_RADIUS:
			return s
	return {}


## 商店的选购菜单：{line, options:[{text, price, action, value}]}
## 军品店已购齐两把枪时，只剩补弹一项。
func menu_for(shop: Dictionary) -> Dictionary:
	var opts: Array = []
	if str(shop["id"]) == "gunshop":
		opts.append({"text": "补满全部弹药 ¥%d" % PRICE_AMMO,
			"price": PRICE_AMMO, "action": "ammo"})
		for i in [1, 2]:
			if not bool(owned_guns[i]):
				var gun_name := "冲锋枪" if i == 1 else "霰弹枪"
				var price := PRICE_SMG if i == 1 else PRICE_SHOTGUN
				opts.append({"text": "%s ¥%d" % [gun_name, price],
					"price": price, "action": "buy_gun", "value": i})
	else:
		opts.append({"text": "一碗牛肉面 ¥%d（回满血）" % PRICE_MEAL,
			"price": PRICE_MEAL, "action": "heal"})
	return {"line": str(shop["line"]), "options": opts}


## 购买判定 + 扣钱。返回 {ok, text, action, value}；ok=false 时 text 是拒绝原因。
func purchase(shop: Dictionary, idx: int) -> Dictionary:
	var menu := menu_for(shop)
	var opts: Array = menu["options"]
	if idx < 0 or idx >= opts.size():
		return {"ok": false, "text": "没有这个选项"}
	var opt: Dictionary = opts[idx]
	var price := int(opt["price"])
	if GameState.cash < price:
		return {"ok": false, "text": "钱不够（还差 ¥%d）" % (price - GameState.cash)}
	GameState.add_cash(-price)
	total_spent += price
	purchase_count += 1
	_save()
	return {"ok": true, "text": str(opt["text"]), "action": str(opt["action"]),
		"value": opt.get("value", -1)}


## 被捕没收：只剩手枪，弹匣清空重置（§4.4，main_game 调）
func confiscate() -> void:
	owned_guns = [true, false, false]
	_save()
