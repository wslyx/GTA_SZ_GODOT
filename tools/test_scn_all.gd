extends SceneTree
## 诊断脚本：全量加载 150 个烘焙 .scn，找出加载失败的块。
## 用法：godot --headless --script res://tools/test_scn_all.gd

const MANIFEST := "res://data/city/blocks-manifest.json"


func _initialize() -> void:
	var f := FileAccess.open(MANIFEST, FileAccess.READ)
	var man: Dictionary = JSON.parse_string(f.get_as_text())
	var blocks: Array = man["blocks"]
	var ok := 0
	var failed: Array = []
	var total_ms := 0
	for b in blocks:
		var scn := str(b["file"]).trim_suffix(".glb") + ".scn"
		var t := Time.get_ticks_msec()
		var r: PackedScene = ResourceLoader.load(scn, "PackedScene",
			ResourceLoader.CACHE_MODE_IGNORE)
		var ms := Time.get_ticks_msec() - t
		total_ms += ms
		if r == null:
			failed.append(scn)
			push_error("[test] 加载失败 %s" % scn)
		else:
			var inst := (r as PackedScene).instantiate()
			var meshes := 0
			var stack: Array = [inst]
			while not stack.is_empty():
				var n: Node = stack.pop_back()
				if n is MeshInstance3D:
					meshes += 1
				for c in n.get_children():
					stack.append(c)
			inst.free()
			if meshes == 0:
				failed.append(scn + "（0 个网格）")
				push_error("[test] 空场景 %s" % scn)
			else:
				ok += 1
	print("[test] 完成：%d 正常 / %d 异常 / 平均 %d ms" % [ok, failed.size(), total_ms / maxi(1, blocks.size())])
	for s in failed:
		print("[test] 异常清单：", s)
	quit(0)
