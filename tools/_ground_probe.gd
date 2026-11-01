extends Node
##
## 地面归属探针：从样例中心向四周打竖直射线，报告命中的网格名与坐标，
## 用来把"相机该摆哪儿才能看到 terrain_pavement"这件事问清楚，而不是靠猜。

const SCENE := "res://scenes/main.tscn"
## 直接用**世界坐标**扫海湾：找那条白色条带是什么
const W_CENTER := Vector2(-2168.0, 810.0)
const SPAN := 500.0
const STEP := 80.0

var main: Node = null
var t := 0.0


func _ready() -> void:
	main = (load(SCENE) as PackedScene).instantiate()
	add_child(main)


func _process(delta: float) -> void:
	t += delta
	if main.get("session_ready") != true:
		if t > 150.0:
			print("[ground-probe] 超时")
			get_tree().quit(1)
		return
	_probe()
	get_tree().quit(0)


func _probe() -> void:
	var space: PhysicsDirectSpaceState3D = main.get_viewport().world_3d.direct_space_state
	var found := {}
	var hit := 0
	var dz := -SPAN
	while dz <= SPAN:
		var dx := -SPAN
		while dx <= SPAN:
			var world := Vector3(W_CENTER.x + dx, 0.0, W_CENTER.y + dz)
			var from := world + Vector3(0.0, 60.0, 0.0)
			var to := world - Vector3(0.0, 30.0, 0.0)
			var q := PhysicsRayQueryParameters3D.create(from, to)
			q.collide_with_areas = false
			var res := space.intersect_ray(q)
			if not res.is_empty():
				var col: Object = res.get("collider")
				var nm := "(无碰撞体)"
				if col is Node:
					nm = String((col as Node).name)
				hit += 1
				if not found.has(nm):
					found[nm] = [world, res.get("position")]
			dx += STEP
		dz += STEP
	print("[ground-probe] 命中 %d 个采样点，按碰撞体分组：" % hit)
	for nm in found:
		var v: Array = found[nm]
		print("   %-36s 首采样 世界(%.0f, %.0f) 高度 %.2f" % [
			nm, (v[1] as Vector3).x, (v[1] as Vector3).z, (v[1] as Vector3).y])
