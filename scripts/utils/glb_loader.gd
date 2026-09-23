extends RefCounted
class_name GlbLoader
##
## GLB 异步加载队列。
##
## 原版用 ImportMeshAsync 并发拉取；Godot 里同步 load() 一个 266MB 的 buildings.glb
## 会把主线程卡死，所以这里用 ResourceLoader.load_threaded_request 做后台加载，
## 主线程每帧 poll 一次，**严格串行**（与原版立面流式的"一次一个"策略一致，
## 避免同时解析多个大场景把内存打爆）。
##
## 用法：
##   var q := GlbLoader.new()
##   q.enqueue("res://data/city/terrain.glb", terrain_root, Callable())
##   # 每帧调用 q.poll()
##   if q.is_idle(): ...

## 第 4 个参数 scene 是加载得到的 PackedScene（chunk 流式用它持有引用以便卸载时
## 真正释放显存）。注意：**信号参数不能带默认值**（GDScript 语法限制），因此这里
## 不写 `= null`；已有的 city_world / facade_streamer 回调把第 4 参声明为可选
## （`_scene: Resource = null`），3 参/4 参调用都能接，保持向后兼容。
signal entry_loaded(path: String, node: Node3D, meta: Variant, scene: Resource)
signal entry_failed(path: String, reason: String)
signal queue_done()

## 每项：{path, parent, meta, state, scene}
var _queue: Array = []
var _current := {}
var _active := false
var loaded_count := 0
var failed_count := 0
## 累计入队数（含已完成），用于加载界面的「N / M」
var enqueued_count := 0


## cache_mode 透传给 ResourceLoader.load_threaded_request：
##   CACHE_MODE_REUSE（默认）—— 资源按路径入全局缓存，适合一次性常驻资源（地形/道路/立面）。
##   CACHE_MODE_IGNORE        —— 不入全局缓存，区块实例被 queue_free 且引用归零后即被 GC，
##                                是动态区块流式卸载、真正回收显存的关键（见 chunk_streamer.gd）。
func enqueue(path: String, parent: Node, meta: Variant = null,
		cache_mode: ResourceLoader.CacheMode = ResourceLoader.CACHE_MODE_REUSE) -> void:
	enqueued_count += 1
	_queue.append({"path": path, "parent": parent, "meta": meta, "cache_mode": cache_mode, "state": "pending"})


func enqueue_many(paths: Array, parent: Node, meta: Variant = null,
		cache_mode: ResourceLoader.CacheMode = ResourceLoader.CACHE_MODE_REUSE) -> void:
	for p in paths:
		enqueue(str(p), parent, meta, cache_mode)


func pending() -> int:
	return _queue.size()


func is_idle() -> bool:
	return _current.is_empty() and _queue.is_empty()


## 已完成数（成功 + 失败）
func finished_count() -> int:
	return loaded_count + failed_count


## 整体进度 0–1：已完成项 + 当前项的线程加载进度。
## 只给 0–0.99，避免"队列跑完了但步骤还没推进"时进度条提前顶到 100%。
func progress() -> float:
	if is_idle():
		return 1.0
	var total := maxi(enqueued_count, 1)
	var cur := 0.0
	if not _current.is_empty():
		var out: Array = []
		var st := ResourceLoader.load_threaded_get_status(str(_current["path"]), out)
		if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS and out.size() > 0:
			cur = clampf(float(out[0]), 0.0, 0.95)
	return clampf((float(finished_count()) + cur) / float(total), 0.0, 0.99)


## 界面用的计数 [已完成, 总数]
func counters() -> Vector2i:
	return Vector2i(finished_count(), enqueued_count)


## 推进一个加载项。返回"这一帧是否有进展"。
func poll() -> bool:
	if _current.is_empty():
		if _queue.is_empty():
			return false
		_current = _queue.pop_front()
		var p: String = _current["path"]
		if not ResourceLoader.exists(p):
			_fail(p, "资源不存在（是否没经过 glTF 导入？）")
			_current = {}
			return true
		var err := ResourceLoader.load_threaded_request(p, "PackedScene", true)
		if err != OK:
			_fail(p, "load_threaded_request 失败 code=%d" % err)
			_current = {}
			return true
		_current["state"] = "loading"
		return true

	var p: String = _current["path"]
	var out: Array = []
	var status := ResourceLoader.load_threaded_get_status(p, out)
	match status:
		ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			return false
		ResourceLoader.THREAD_LOAD_LOADED:
			var scene := ResourceLoader.load_threaded_get(p)
			_finish(scene)
			return true
		_:
			_fail(p, "线程加载失败 status=%d" % status)
			_current = {}
			return true


func _finish(scene: Resource) -> void:
	var p: String = _current["path"]
	var parent: Node = _current["parent"]
	var meta: Variant = _current["meta"]
	_current = {}
	loaded_count += 1
	if scene == null:
		_fail(p, "load_threaded_get 返回 null")
		return
	var inst := (scene as PackedScene).instantiate()
	if inst == null:
		_fail(p, "实例化失败")
		return
	# GLB 由 Blender 导出，glTF 已是 (east, up, -north)，与 Godot 世界 (x=east, y=up, z=-north)
	# 完全一致，因此**不需要任何旋转或镜像**。这里刻意不动 transform，改动会引入
	# 三角绕序反转（见 CoordinateUtil 头部说明）。
	if parent != null and is_instance_valid(parent):
		parent.add_child(inst)
	entry_loaded.emit(p, inst, meta, scene)
	if _queue.is_empty():
		queue_done.emit()


func _fail(path: String, reason: String) -> void:
	failed_count += 1
	push_warning("[GlbLoader] %s：%s" % [path, reason])
	entry_failed.emit(path, reason)
	if _queue.is_empty():
		queue_done.emit()


## 递归遍历节点，收集命名匹配的节点（用于分块索引）
static func collect_by_prefix(root: Node, prefix: String, out: Array) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.name.begins_with(prefix):
			out.append(n)
		for c in n.get_children():
			stack.append(c)


## 找出 glTF 根下的全部 MeshInstance3D（跳过容器节点）。
##
## 返回 **Array[MeshInstance3D]** 而不是普通 Array：调用方普遍这样写
##     for mi in GlbLoader.meshes_of(root):
##         var ok := mi.name.begins_with("roads")
## 如果返回无类型数组，`mi` 就是 Variant，`mi.name` 也是 Variant，
## `:=` 推断失败（本项目把 INFERRED_DECLARATION 当错误处理，直接编译不过）。
## 元素类型标出来之后，循环变量就是真正的 MeshInstance3D。
static func meshes_of(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


## 统一设置阴影与可见层，等价于原版 load() 里对每个 mesh 做的事。
##
## 参数 receive_shadows 仅为兼容调用方而保留：**Godot 4 没有**
## `MeshInstance3D.receive_shadows` 这个属性（那是 Godot 3 的 GeometryInstance
## 属性，4 里接收阴影是自动的），写了会报
## "Invalid assignment of property or key 'receive_shadows'"。只设置 cast_shadow。
static func configure_meshes(meshes: Array, receive_shadows := true, cast_shadows := true) -> void:
	for m in meshes:
		var mi := m as MeshInstance3D
		if mi == null:
			continue
		mi.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		)
