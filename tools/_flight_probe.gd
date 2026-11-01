extends Node
##
## 飞行碰撞探针：用真实 CityData.buildings 建 FlightCollision，
## 对「已知建筑中心」做三向扫描，验证棱柱求交 / 庭院洞 / 地形采样的行为。
##
## 期望：
##   - 穿过建筑中心（中部高度）→ kind=building；
##   - 同一条水平线抬高到楼顶以上 → 无命中；
##   - 从空中斜插向地面 → kind=terrain（或先撞建筑）。

const SCENE := "res://scenes/main.tscn"

var main: Node = null
var t := 0.0


func _ready() -> void:
	main = (load(SCENE) as PackedScene).instantiate()
	add_child(main)


func _process(delta: float) -> void:
	t += delta
	if main.get("session_ready") != true:
		if t > 150.0:
			print("[flight-probe] 超时")
			get_tree().quit(1)
		return
	_run()
	get_tree().quit(0)


func _run() -> void:
	var fc = main.get("_flight_collision")
	if fc == null:
		# 调用一次确保懒建（_ensure_flight_collision）
		main.call("_ensure_flight_collision")
		fc = main.get("_flight_collision")
	if fc == null:
		print("[flight-probe] FAIL：拿不到 FlightCollision")
		get_tree().quit(1)
		return
	var height_at: Callable = main.get("world").height_field.height_at

	# 挑一栋够高、环简单的楼
	# CityWorld 上数据挂在 city（CityData autoload 的引用字段），名字是 city_data_ref？
	# 实测：city_world 没有直接字段，直接读 autoload
	var buildings: Array = CityData.buildings
	var best = null
	for b in buildings:
		var h := float(b.get("height", 0.0))
		var rings: Array = b.get("rings", [])
		if h >= 30.0 and rings.size() == 1:
			best = b
			break
	if best == null:
		print("[flight-probe] FAIL：找不到测试建筑")
		get_tree().quit(1)
		return
	var cx := 0.0
	var cz := 0.0
	var outer: Array = best["rings"][0]
	for p in outer:
		cx += float(p[0]) / float(outer.size())
		cz += float(p[1]) / float(outer.size())
	var h := float(best["height"])
	var pad := 12.0
	print("[flight-probe] 测试建筑 %s 高 %.0fm 中心(%.0f, %.0f)" % [
		str(best.get("id")), h, cx, cz])

	var hits := 0
	# 1) 中部高度横穿 → 应撞建筑
	for ang in [0.0, 1.1, 2.2, 3.3]:
		var dir := Vector2(sin(ang), cos(ang))
		var a := Vector3(cx - dir.x * (pad + 30.0), h * 0.5, cz - dir.y * (pad + 30.0))
		var b := Vector3(cx + dir.x * (pad + 30.0), h * 0.5, cz + dir.y * (pad + 30.0))
		var res: Dictionary = fc.sweep(a, b, height_at)
		if res.get("kind", "") == "building":
			hits += 1
	print("[flight-probe] 楼体中部 4 向横穿 → 撞建筑 %d/4（期望 4）" % hits)
	var ok := hits == 4

	# 2) 同线抬高到楼顶上方 → 应无命中
	var above: Dictionary = fc.sweep(
		Vector3(cx - 40.0, h + 6.0, cz), Vector3(cx + 40.0, h + 6.0, cz), height_at)
	print("[flight-probe] 楼顶上方横穿 → %s（期望空）" % str(above.get("kind", "无")))
	ok = ok and above.is_empty()

	# 3) 从高空斜插地面 → 地形命中
	var dive: Dictionary = fc.sweep(
		Vector3(cx + 5.0, h + 20.0, cz + 5.0), Vector3(cx + 5.0, 0.0, cz + 5.0), height_at)
	print("[flight-probe] 高空直插 → %s（building 或 terrain 都算有判定）" % str(dive.get("kind", "无")))
	ok = ok and not dive.is_empty()

	print("[flight-probe] 结论：%s" % ("OK" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)
