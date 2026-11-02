extends SceneTree
## 诊断脚本：验证烘焙 .scn 能否正常加载（对比 GLB）。
## 用法：godot --headless --script res://tools/test_scn_load.gd

func _initialize() -> void:
	for p in ["res://data/city/blocks/0_0.glb", "res://data/city/blocks/0_0.scn"]:
		var t := Time.get_ticks_msec()
		var r: PackedScene = ResourceLoader.load(p, "PackedScene",
			ResourceLoader.CACHE_MODE_IGNORE)
		var ok := r != null
		var inst := 0
		if ok:
			inst = (r as PackedScene).instantiate().get_child_count()
		print("[test] %s -> load=%s children=%d %d ms" % [
			p.get_file(), ok, inst, Time.get_ticks_msec() - t])
	quit(0)
