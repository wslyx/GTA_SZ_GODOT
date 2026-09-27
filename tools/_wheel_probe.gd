extends SceneTree
## 一次性验证：CarWheels 能否找到轮网、读取清单、并正确写出带轴心的 transform
const CarWheelsScript := preload("res://scripts/vehicles/car_wheels.gd")

func _initialize() -> void:
	var packed := load("res://data/city/car.glb") as PackedScene
	var inst := packed.instantiate()
	root.add_child(inst)
	var cw = CarWheelsScript.new()
	cw.setup(inst)
	print("找到轮网/刹车盘零件: %d，wheelRadius=%.4f" % [cw.part_count, cw.wheel_radius])
	# 应用一圈滚动 + 右转 0.3rad，检查前轮与后轮的变换
	cw.apply(1.234, 0.3)
	var lf := inst.find_child("wheel_lf_rubber", true, false) as MeshInstance3D
	var lr := inst.find_child("wheel_lr_rubber", true, false) as MeshInstance3D
	var bf := inst.find_child("brake_lf_caliper", true, false) as MeshInstance3D
	for pair in [["wheel_lf_rubber", lf], ["wheel_lr_rubber", lr], ["brake_lf_caliper", bf]]:
		var mi: MeshInstance3D = pair[1]
		var t := mi.transform
		print("%s origin=%s" % [pair[0], t.origin])
		print("  basis.x=%s  (转向后仍应近水平、长度1)" % t.basis.x)
	# 前轮原点应等于 T(P)·R·T(-P) 作用下的 P−R·P；后轮无转向只有滚转
	var check := Transform3D(Basis(Vector3.UP, -0.3) * Basis(Vector3.RIGHT, 1.234), Vector3.ZERO)
	var expect_lf: Vector3 = check.origin + (Vector3(-0.8564, 0.4406, -1.4312) - check.basis * Vector3(-0.8564, 0.4406, -1.4312))
	print("lf 原点理论值=%s  实际=%s" % [expect_lf, lf.transform.origin])
	quit(0)
