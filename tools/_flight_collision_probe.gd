extends SceneTree
##
## 无头探针：验证 FlightCollision（飞行碰撞）的关键语义。
## 用法：
##   Godot_v4.7.1-stable_win64_console.exe --headless --path . \
##       --script res://tools/_flight_collision_probe.gd
##

func _initialize() -> void:
	# --script 模式下 autoload 全局名不可用，手动实例化 CityData
	var city_data = load("res://scripts/core/city_data.gd").new()
	city_data.load_core()
	var failures := 0

	var fc = load("res://scripts/world/flight_collision.gd").new()
	fc.build(city_data.buildings)

	var zero_h := func(_x: float, _z: float) -> float: return 0.0

	# 1) 高空横穿全城：不应有任何命中（旧 blocked() 实现会满地都是"墙"）
	var hit_high: Dictionary = fc.sweep(Vector3(-6000, 400, -2000), Vector3(6000, 400, 2000), zero_h)
	if not hit_high.is_empty():
		print("[FAIL] 高空 400m 横穿竟命中：", hit_high)
		failures += 1
	else:
		print("[OK] 高空 400m 横穿无命中")

	# 2) 穿过最高楼半高处的水平线：必须命中 building
	var tallest: Dictionary = {}
	for b in city_data.buildings:
		if float(b.get("height", 0.0)) > float(tallest.get("height", 0.0)):
			tallest = b
	var ring: PackedVector2Array = fc._pack_ring(tallest["rings"][0])
	var cx := 0.0
	var cz := 0.0
	for p in ring:
		cx += p.x
		cz += p.y
	cx /= ring.size()
	cz /= ring.size()
	var mid_y := float(tallest["height"]) * 0.5
	var hit_bld: Dictionary = fc.sweep(Vector3(cx - 300, mid_y, cz), Vector3(cx + 300, mid_y, cz), zero_h)
	if hit_bld.is_empty() or str(hit_bld.get("kind")) != "building":
		print("[FAIL] 穿最高楼（h=%s）未命中 building：" % tallest["height"], hit_bld)
		failures += 1
	else:
		print("[OK] 穿最高楼 h=%.0f 命中 building @ %s" % [float(tallest["height"]), hit_bld["point"]])

	# 3) 同一水平线抬到楼顶之上：不应命中（旧实现会撞投影）
	var hit_above: Dictionary = fc.sweep(Vector3(cx - 300, float(tallest["height"]) + 30.0, cz),
			Vector3(cx + 300, float(tallest["height"]) + 30.0, cz), zero_h)
	if not hit_above.is_empty():
		print("[FAIL] 楼顶上方 30m 竟命中：", hit_above)
		failures += 1
	else:
		print("[OK] 楼顶上方 30m 无命中")

	# 4) 贴地 5m：撞地形（用无建筑实例隔离地形规则；(0,0) 处有楼，先撞楼才是对的）
	var fc_empty = load("res://scripts/world/flight_collision.gd").new()
	fc_empty.build([])
	var hit_ground: Dictionary = fc_empty.sweep(Vector3(0, 5, 0), Vector3(30, 5, 0),
			func(_x: float, _z: float) -> float: return 50.0)
	if hit_ground.is_empty() or str(hit_ground.get("kind")) != "terrain":
		print("[FAIL] 贴地 5m（地形 50m）未撞地形：", hit_ground)
		failures += 1
	else:
		print("[OK] 贴地判定地形命中")

	# 5) 贴海面：y<=0.15 撞水，y=2 掠海不撞（原版 max(-0.1, h)+0.25 规则）
	var sea := func(_x: float, _z: float) -> float: return -50.0
	var hit_water: Dictionary = fc_empty.sweep(Vector3(0, 0.1, 0), Vector3(30, 0.1, 0), sea)
	var skim_water: Dictionary = fc_empty.sweep(Vector3(0, 2, 0), Vector3(30, 2, 0), sea)
	if hit_water.is_empty():
		print("[FAIL] 贴海面 0.1m 未判撞水：", hit_water)
		failures += 1
	else:
		print("[OK] 贴海面撞水")
	if not skim_water.is_empty():
		print("[FAIL] 掠海 2m 竟撞：", skim_water)
		failures += 1
	else:
		print("[OK] 掠海 2m 不撞")

	print("=== 结果：%s（失败 %d 项）===" % ["全部通过" if failures == 0 else "存在失败", failures])
	quit(1 if failures > 0 else 0)
