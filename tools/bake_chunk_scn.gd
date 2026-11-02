extends SceneTree
##
## 区块离线烘焙：GLB → .scn（大地图流式优化①，docs/GTA化改进方案.md 加载节）
##
## 为什么：chunk_streamer 运行时加载 GLB 要付"解析 + 导入重映射"的成本（后台
## 线程），而烘焙后的 .scn 是 Godot 原生二进制序列化，加载 = 直接读——这就是
## UE cook 流程的等价物。配合 chunk_streamer._resolve_load_path()：
## 存在且不比源 GLB 旧的 .scn 自动优先，否则回退 GLB（烘焙永不锁死旧数据）。
##
## 用法（项目根目录）：
##   godot --headless --script res://tools/bake_chunk_scn.gd
##   godot --headless --script res://tools/bake_chunk_scn.gd -- --force
##
## 注意：跑之前先用编辑器打开过一次项目（GLB 需要导入缓存）；烘焙 100+ 块
## 大约几分钟，逐块释放内存（CACHE_MODE_IGNORE 不进缓存）。

const MANIFEST := "res://data/city/blocks-manifest.json"


func _initialize() -> void:
	var force: bool = OS.get_cmdline_user_args().has("--force")
	if not FileAccess.file_exists(MANIFEST):
		push_error("[bake] manifest 不存在：%s" % MANIFEST)
		quit(1)
		return
	var f := FileAccess.open(MANIFEST, FileAccess.READ)
	var man: Dictionary = JSON.parse_string(f.get_as_text())
	if man == null or not man.has("blocks"):
		push_error("[bake] manifest 格式异常")
		quit(1)
		return
	var blocks: Array = man["blocks"]
	print("[bake] %d 个区块（force=%s）" % [blocks.size(), force])
	var ok := 0
	var skipped := 0
	var failed := 0
	for i in blocks.size():
		var b: Dictionary = blocks[i]
		var glb := str(b["file"])
		if not glb.ends_with(".glb"):
			continue
		var scn := glb.trim_suffix(".glb") + ".scn"
		if not force and FileAccess.file_exists(scn) \
				and FileAccess.get_modified_time(scn) >= FileAccess.get_modified_time(glb):
			skipped += 1
			continue
		# CACHE_MODE_IGNORE：不进资源缓存，保存完引用归零即释放内存
		var scene: PackedScene = ResourceLoader.load(glb, "PackedScene",
			ResourceLoader.CACHE_MODE_IGNORE)
		if scene == null:
			push_error("[bake] 加载失败 %s" % glb)
			failed += 1
			continue
		var err := ResourceSaver.save(scene, scn, ResourceSaver.FLAG_COMPRESS)
		if err != OK:
			push_error("[bake] 保存失败 %s code=%d" % [scn, err])
			failed += 1
		else:
			ok += 1
		scene = null
		if (i + 1) % 10 == 0:
			print("[bake] %d/%d …" % [i + 1, blocks.size()])
	print("[bake] 完成：烘焙 %d / 跳过 %d / 失败 %d" % [ok, skipped, failed])
	quit(1 if failed > 0 else 0)
