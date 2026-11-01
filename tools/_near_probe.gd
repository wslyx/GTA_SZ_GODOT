extends Node
##
## 无人机 nearZ 自适应的纯数学验证（不需要显卡）。
##
## 直接构造一个 ChaseCamera，把它摆到不同高度调用 follow_observer，
## 打印 near —— 期望：
##   低空（贴楼，< 360m）→ 0.30（原固定值）
##   400m             → (400-360)*0.1 = 4.0
##   1000m            → 64.0
##   1600m 以上       → 封顶 128

const CAM := preload("res://scripts/vehicles/chase_camera.gd")


func _ready() -> void:
	var cam = CAM.new()
	add_child(cam)
	cam.set_mode(3, true)  # Mode.OBSERVER
	var ok := true
	for raw in [0.0, 120.0, 359.0, 400.0, 1000.0, 1600.0, 5000.0]:
		var height: float = raw
		cam.observer_position = Vector3(0.0, height, 0.0)
		cam.global_position = Vector3(0.0, height, 0.0)
		cam.follow_observer(1.0)
		var expect: float = 0.3 if height <= 360.0 else minf(128.0, (height - 360.0) * 0.1)
		var near: float = cam.near
		var good := absf(near - expect) < 0.01
		ok = ok and good
		print("[near-probe] 高度 %6.0f m → near=%7.2f 期望 %7.2f  %s"
			% [height, near, expect, "OK" if good else "MISMATCH"])
	print("[near-probe] 结论：%s" % ("OK" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)
