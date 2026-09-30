extends SceneTree
##
## 无头探针：坦克炮弹管线（TankShells）。
## 验证：发射 → 弹道推进 → 地形命中爆炸 → 池上限 4 发 / 拒绝第 5 发。
## 用法：
##   Godot_v4.7.1-stable_win64_console.exe --headless --path . \
##       --script res://tools/_tank_shells_probe.gd
##

func _initialize() -> void:
	var city_data = load("res://scripts/core/city_data.gd").new()
	city_data.load_core()
	var failures := 0

	var fc = load("res://scripts/world/flight_collision.gd").new()
	fc.build(city_data.buildings)
	var sweep := func(a: Vector3, b: Vector3) -> Dictionary:
		return fc.sweep(a, b, city_data_height())

	var shells = load("res://scripts/vehicles/tank_shells.gd").new()
	shells.name = "ProbeTankShells"
	root.add_child(shells)

	# 1) 池上限：连续射 4 发成功，第 5 发被拒
	var fired := 0
	for i in 5:
		var shot: Dictionary = {
			"origin": {"x": 5000.0 + i, "y": 300.0, "z": 0.0},
			"velocity": {"x": 0.0, "y": -30.0, "z": 0.0},
		}
		if shells.fire_shot(shot, sweep, 0.0):
			fired += 1
	if fired == 4 and not shells.has_free():
		print("[OK] 4 发入池，第 5 发被拒")
	else:
		print("[FAIL] 池上限异常：fired=%d has_free=%s" % [fired, shells.has_free()])
		failures += 1

	# 2) 弹道推进 + 地形命中（零高度地形：y<=0.25 判撞；145m/s 横速 + 重力下坠，
	#    6s 寿命内必然落地）——用一发从 300m 高度垂直下坠的弹验证
	var shells2 = load("res://scripts/vehicles/tank_shells.gd").new()
	shells2.name = "ProbeTankShells2"
	root.add_child(shells2)
	shells2.fire_shot({
		"origin": {"x": 0.0, "y": 100.0, "z": 0.0},
		"velocity": {"x": 40.0, "y": 0.0, "z": 0.0},
	}, sweep, 0.0)
	var frames := 0
	while int(shells2.stats()["shells"]) > 0 and frames < 1200:
		shells2.step(1.0 / 60.0, sweep)
		frames += 1
	if int(shells2.stats()["hits"]) == 1 and frames < 1200:
		print("[OK] 炮弹 %.1fs 后命中地形并爆炸" % (frames / 60.0))
	else:
		print("[FAIL] 炮弹未正常命中：stats=%s frames=%d" % [shells2.stats(), frames])
		failures += 1

	# 3) clear_effects 收尾
	shells.clear_effects()
	if int(shells.stats()["shells"]) == 0:
		print("[OK] clear_effects 清空弹池")
	else:
		print("[FAIL] clear_effects 后仍有弹：", shells.stats())
		failures += 1

	print("=== 结果：%s（失败 %d 项）===" % ["全部通过" if failures == 0 else "存在失败", failures])
	quit(1 if failures > 0 else 0)


## 探针用地形高度函数（数据坐标）：平地 0m
func city_data_height() -> Callable:
	return func(_x: float, _z: float) -> float: return 0.0
