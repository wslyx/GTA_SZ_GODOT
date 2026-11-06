extends Node
##
## 平面镜反射一次性探针（性能优化方案 §2.1 验证用）：
##   1. 等 session_ready；
##   2. 打印 planar_mirror 诊断（enabled / 尺寸 / Hz / 更新模式）；
##   3. 等 2s（触发 ≥1 次节流渲染）后抓取镜像 SubViewport 的纹理，
##      采样 9 个点判断是否渲染出内容（全黑/全空 = UPDATE_ONCE 没触发）；
##   4. 车开到海边（数据坐标 goto），第三人称截图供人工比对倒影；
##   5. 打印 mirror_tex 纹理实际尺寸后退出。
##
## 用法：
##   Godot_console.exe --path . --resolution 1920x1080 res://tools/_mirror_probe.tscn

var main: Node = null
var started := false
var t := 0.0
var phase := 0
var out_dir := ""

func _ready() -> void:
	out_dir = ProjectSettings.globalize_path("res://tools/shots")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var scene: PackedScene = load("res://scenes/main.tscn")
	main = scene.instantiate()
	add_child(main)
	print("[mirror-probe] 主场景已加入")

func _mirror() -> Node:
	var w = main.get("world")
	if w == null or w.get("water") == null:
		return null
	return w.water.get("planar_mirror")

func _process(delta: float) -> void:
	if main == null:
		return
	t += delta
	match phase:
		0:
			if main.get("session_ready") != true:
				if t > 120.0:
					push_error("[mirror-probe] 等 session_ready 超时")
					get_tree().quit(1)
				return
			started = true
			phase = 1
			t = 0.0
			print("[mirror-probe] session_ready 达成，等 2s 触发节流渲染…")
		1:
			if t < 2.0:
				return
			phase = 2
			t = 0.0
			var m := _mirror()
			if m == null:
				print("[mirror-probe] ❌ 找不到 world.water.planar_mirror")
				get_tree().quit(1)
				return
			print("[mirror-probe] diag=%s" % [m.diagnostics()])
			var vp: SubViewport = m.get("viewport")
			if vp == null:
				print("[mirror-probe] ❌ viewport 为空")
				get_tree().quit(1)
				return
			print("[mirror-probe] viewport size=%s update_mode=%d(4=ONCE,3=ALWAYS,0=DISABLED)" % [
				str(vp.size), vp.render_target_update_mode])
			var tex: Texture2D = vp.get_texture()
			if tex == null:
				print("[mirror-probe] ❌ 纹理为空")
				get_tree().quit(1)
				return
			var img := tex.get_image()
			if img == null:
				print("[mirror-probe] ❌ 纹理图像取不到")
				get_tree().quit(1)
				return
			var sz := Vector2i(img.get_width(), img.get_height())
			# 3×3 采样：全黑（含 A=0）说明 UPDATE_ONCE 从未渲染成功
			var bright := 0
			for i in 3:
				for j in 3:
					var px := img.get_pixel(sz.x * (i + 1) / 4, sz.y * (j + 1) / 4)
					if px.get_luminance() > 0.02 or px.a > 0.1:
						bright += 1
			print("[mirror-probe] 纹理 %dx%d 采样亮度点 %d/9 %s" % [
				sz.x, sz.y, bright, "✅ 有内容" if bright > 0 else "❌ 全黑（未渲染）"])
			# 车开到海边截图（沿用 _shot 的 goto 语义：直接摆车位）
			var car = main.get("car")
			if car != null and car.has_method("reset_to"):
				car.reset_to(1200.0, -2400.0, -1.72)
				var model = main.get("_car_model")
				print("[mirror-probe] 车已摆到海边，等 6s 流式加载收尾后截图")
			phase = 3
		3:
			if t < 6.0:
				return
			var img2 := get_viewport().get_texture().get_image()
			var path := out_dir + "/mirror_probe.png"
			img2.save_png(path)
			print("[mirror-probe] 截图已存 %s" % path)
			# 收尾：再打一次诊断（确认节流持续工作）
			var m2 := _mirror()
			if m2 != null:
				print("[mirror-probe] 终态 diag=%s" % [m2.diagnostics()])
			print("[mirror-probe] 完成")
			get_tree().quit(0)
