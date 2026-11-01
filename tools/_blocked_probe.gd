extends Node
##
## 碰撞墙探针：从 (-3600,-800) 沿正东扫到 (-2000,-800)，每 10m 报一次
## CityCollision.blocked() 的翻转点 —— 定位"看不见的墙"到底在哪、是哪条数据。

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
			print("[wall-probe] 超时")
			get_tree().quit(1)
		return
	_scan()
	get_tree().quit(0)


func _scan() -> void:
	var collision = main.get("world").collision
	var z := -800.0
	var prev: bool = collision.blocked(-3600.0, z)
	print("[wall-probe] 起点 (-3600, %.0f) blocked=%s" % [z, str(prev)])
	var x := -3590.0
	while x <= -2000.0:
		var b: bool = collision.blocked(x, z)
		if b != prev:
			print("[wall-probe] 翻转 @ x=%.0f  %s → %s" % [x, str(prev), str(b)])
			prev = b
		x += 10.0
	# 顺带：扫南北几条平行线，看墙的走向
	for zz in [-700.0, -750.0, -850.0, -900.0, -1000.0]:
		var row := ""
		var xx := -2400.0
		var last := false
		while xx <= -1900.0:
			var b2: bool = collision.blocked(xx, zz)
			row += "█" if b2 else "·"
			if b2 != last and row.length() > 1:
				pass
			last = b2
			xx += 25.0
		print("[wall-probe] z=%6.0f  %s  (%.0f→%.0f, 每格25m)" % [zz, row, -2400.0, -1900.0])
	get_tree().quit(0)
