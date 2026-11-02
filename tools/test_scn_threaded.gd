extends SceneTree
## 诊断脚本：验证烘焙 .scn 的**线程化加载**（chunk_streamer 实际用的路径：
## load_threaded_request + use_sub_threads + CACHE_MODE_IGNORE）。
## 用法：godot --headless --script res://tools/test_scn_threaded.gd

const PATHS := [
	"res://data/city/blocks/0_0.glb",
	"res://data/city/blocks/0_0.scn",
]


func _initialize() -> void:
	_run()


func _run() -> void:
	for p in PATHS:
		var err := ResourceLoader.load_threaded_request(p, "PackedScene", true,
			ResourceLoader.CACHE_MODE_IGNORE)
		if err != OK:
			print("[test] %s -> request 失败 code=%d" % [p.get_file(), err])
			continue
		var frames := 0
		var st := ResourceLoader.THREAD_LOAD_IN_PROGRESS
		while st == ResourceLoader.THREAD_LOAD_IN_PROGRESS and frames < 600:
			await process_frame
			frames += 1
			st = ResourceLoader.load_threaded_get_status(p)
		if st == ResourceLoader.THREAD_LOAD_LOADED:
			var scene: PackedScene = ResourceLoader.load_threaded_get(p)
			print("[test] %s -> LOADED frames=%d children=%d" % [
				p.get_file(), frames, (scene as PackedScene).instantiate().get_child_count()])
		else:
			print("[test] %s -> status=%d frames=%d（600 帧未完成即卡死）" % [
				p.get_file(), st, frames])
	quit(0)
