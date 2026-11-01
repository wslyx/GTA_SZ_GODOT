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
		# ⚠️ cache_mode 是第 4 参：曾经写成 load_threaded_request(p, "PackedScene", true)
		# 而把 enqueue 传入的 cache_mode 静默丢弃（第 3 参其实是 use_sub_threads），
		# 导致区块实际按默认 CACHE_MODE_REUSE 进全局缓存 —— 卸载后场景/贴图被缓存
		# 强引用永不释放，「流式回收显存」从未真正生效，开车越远内存越涨。
		var err := ResourceLoader.load_threaded_request(p, "PackedScene", true,
			_current["cache_mode"])
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
	# 卡顿归因：load_threaded 把解码放后台，但 `instantiate()`（建节点树 +
	# 解码 mesh buffer 成引擎格式）在主线程 —— 大文件的这一步就是长帧
	var __t0 := Time.get_ticks_msec()
	var inst := (scene as PackedScene).instantiate()
	if inst == null:
		_fail(p, "实例化失败")
		return
	var __ms := Time.get_ticks_msec() - __t0
	if __ms > 12:
		print("[HITCH] 实例化 %s 用时 %d ms" % [p.get_file(), __ms])
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


## 加载一个"树原型"替换模型，返回 [{mesh, local}]：
##   mesh   —— 场景里的 MeshInstance3D 网格（场景实例已释放，Mesh 资源仍被引用）
##   local  —— 相对场景根的容器变换 * scale（glTF 根节点常带 0.001 之类的导出缩放，
##             不展开的话实例会被放到 4369m 高空，见 tree_modern.glb 的根节点）
##
## 材质染色：无贴图灰模（albedo 0.5 灰）直接用是一排灰树，这里按
## 「网格底边相对整体高度」二分 —— 底边高于整体 25% 的是树冠、其余是树干。
## 重复调用是幂等的（绝对赋值不是乘法），林冠/种植两层各调一次不冲突。
## 结果按 path 缓存：73MB 的场景 instantiate 一次就够，两层共享同一份条目。
static var _tree_model_cache: Dictionary = {}
static func load_tree_model(path: String, scale: float, foliage: Color, trunk: Color) -> Array[Dictionary]:
	if _tree_model_cache.has(path):
		return _tree_model_cache[path]
	var out: Array[Dictionary] = []
	if not ResourceLoader.exists(path):
		push_warning("[GlbLoader] 树替换模型不存在/未导入：%s（打开一次 Godot 编辑器完成导入，导入前回退原版树）" % path)
		return out
	var scene := load(path) as PackedScene
	if scene == null:
		return out
	var inst := scene.instantiate()
	var mi_list := meshes_of(inst)
	# 先扫一遍算整体高度（各网格 AABB 经容器变换后的最高点）
	var top := 0.0
	for mi in mi_list:
		if mi.mesh == null:
			continue
		var waabb := _xf_aabb(_relative_xf(inst, mi), mi.mesh.get_aabb())
		top = maxf(top, waabb.position.y + waabb.size.y)
	for mi in mi_list:
		if mi.mesh == null or mi.mesh.get_surface_count() == 0:
			continue
		var xf := _relative_xf(inst, mi)
		var waabb2 := _xf_aabb(xf, mi.mesh.get_aabb())
		var tint := foliage if (top > 0.0 and waabb2.position.y > top * 0.25) else trunk
		for s in mi.mesh.get_surface_count():
			var mat: Material = mi.mesh.surface_get_material(s)
			if mat is StandardMaterial3D:
				var std := mat as StandardMaterial3D
				std.albedo_color = tint
				std.roughness = maxf(std.roughness, 0.85)
		out.append({"mesh": mi.mesh, "local": xf * Transform3D(
			Basis().scaled(Vector3.ONE * scale), Vector3.ZERO)})
	inst.queue_free()
	_tree_model_cache[path] = out
	return out


## 节点相对场景根的累积变换（容器节点的平移/缩放会被带出来）。
static func _relative_xf(root: Node, n: Node3D) -> Transform3D:
	var xf := n.transform
	var p: Node = n.get_parent()
	while p != null and p != root:
		if p is Node3D:
			xf = (p as Node3D).transform * xf
		p = p.get_parent()
	return xf


## AABB 经 Transform3D 变换后的包围盒（8 角点取 min/max）。
## 不用 `Transform3D * AABB`：该运算符版本支持不一致，8 角点是零 API 风险写法。
static func _xf_aabb(xf: Transform3D, aabb: AABB) -> AABB:
	var mn := Vector3.INF
	var mx := -Vector3.INF
	for i in 8:
		var c := Vector3(
			aabb.position.x + (aabb.size.x if (i & 1) != 0 else 0.0),
			aabb.position.y + (aabb.size.y if (i & 2) != 0 else 0.0),
			aabb.position.z + (aabb.size.z if (i & 4) != 0 else 0.0))
		var w := xf * c
		mn = mn.min(w)
		mx = mx.max(w)
	return AABB(mn, mx - mn)


## 统一设置阴影与可见层，等价于原版 load() 里对每个 mesh 做的事。
##
## 参数 receive_shadows 仅为兼容调用方而保留：**Godot 4 没有**
## `MeshInstance3D.receive_shadows` 这个属性（那是 Godot 3 的 GeometryInstance
## 属性，4 里接收阴影是自动的），写了会报
## "Invalid assignment of property or key 'receive_shadows'"。只设置 cast_shadow。
static func configure_meshes(meshes: Array, receive_shadows := true, cast_shadows := true,
		vertex_colors := true) -> void:
	for m in meshes:
		var mi := m as MeshInstance3D
		if mi == null:
			continue
		mi.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		)
		if vertex_colors:
			enable_vertex_colors([mi])


# ---------------------------------------------------------------------------
# 区块内嵌贴图跨块共享（chunk_streamer 专用，见 dedup_chunk_textures）
# ---------------------------------------------------------------------------

## 共享贴图注册表："residential.jpg" 等后缀键 → 首个登记的纹理实例。
## static 持有：区块卸载后共享实例继续存活，重载的块直接重挂上来。
static var _chunk_tex_cache: Dictionary = {}
static var _chunk_tex_re: RegEx = null


## 把区块内嵌贴图重映射到**跨块共享**的实例，返回重映射的引用数。
##
## 背景：split_city_blocks.py 切分时把同一套建筑贴图逐块复制内嵌
## （data/city/blocks/<i>_<j>_<名>.jpg，150 块 × 4 张，MD5 实证同后缀同内容）。
## 区块用 CACHE_MODE_IGNORE 加载（卸载即 GC 的前提），不命中资源缓存，
## 于是每个常驻块都各自实例化整套贴图：~68 块 × 4 张 1024² S3TC ≈ 190MB 显存。
## 加载后把材质的 albedo/emission 贴图引用重挂到共享实例，块内副本引用归零
## 即被 GC，常驻开销降到 ≈ 4 张 ≈ 3MB。
##
## ⚠️ 配套条件：调用方（chunk_streamer._on_loaded）加载后**不得**再持有
## PackedScene 引用 —— 场景捆绑着块内原始贴图，保留它副本就永不回收。
static func dedup_chunk_textures(root: Node) -> int:
	var n := 0
	for mi in meshes_of(root):
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var mat: Material = mi.mesh.surface_get_material(s)
			if mat is StandardMaterial3D:
				n += _remap_shared_textures(mat as StandardMaterial3D)
	return n


static func _remap_shared_textures(m: StandardMaterial3D) -> int:
	var n := 0
	for prop in ["albedo_texture", "emission_texture"]:
		var t: Texture2D = m.get(prop)
		if t == null or t.resource_path == "":
			continue
		var key := _chunk_tex_key(t.resource_path)
		if key == "":
			continue
		var shared: Texture2D = _chunk_tex_cache.get(key)
		if shared != null and is_instance_valid(shared):
			if shared != t:
				m.set(prop, shared)
				n += 1
		else:
			_chunk_tex_cache[key] = t
	return n


## res://data/city/blocks/<i>_<j>_<名>.jpg → "<名>.jpg"；
## 不带 blocks 目录或不符合块前缀命名的路径返回 ""（不去重，保守处理）。
static func _chunk_tex_key(path: String) -> String:
	if not path.contains("/blocks/"):
		return ""
	if _chunk_tex_re == null:
		_chunk_tex_re = RegEx.new()
		_chunk_tex_re.compile("^-?\\d+_-?\\d+_(.+)$")
	var m: RegExMatch = _chunk_tex_re.search(path.get_file())
	return m.get_string(1) if m != null else ""


## 建筑的颜色**全部**烘焙在 COLOR_0 顶点色里：blocks/*.glb 与 buildings.glb 的
## 每个材质反照率都是 (1,1,1)， primitive 属性只有 POSITION / NORMAL / COLOR_0
##（连 TEXCOORD_0 都没有）。
##
## ⚠️ Godot 的 glTF 导入器**不会**自动打开 `vertex_color_use_as_albedo` ——
## 实测这 255 个建筑网格的该标志全是 false，于是顶点色被忽略、整城渲染成
## **纯白纸模型**（白天尤其明显，住宅楼群洗成一片白）。这是 glTF 语义上的
## 正确行为（COLOR_0 是 baseColor 的乘数），所以凡带 COLOR 属性的表面一律开启。
##
## 无头模式看不到画面，这个问题是开窗截图后才发现的（见 修复记录 二十四）。
static func enable_vertex_colors(meshes: Array) -> int:
	var done := 0
	for m in meshes:
		var mi := m as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var mesh: Mesh = mi.mesh
		for s in mesh.get_surface_count():
			if not (mesh.surface_get_format(s) & Mesh.ARRAY_FORMAT_COLOR):
				continue
			var mats: Array = []
			var sm: Material = mesh.surface_get_material(s)
			if sm != null:
				mats.append(sm)
			if mi.material_override != null:
				mats.append(mi.material_override)
			for mat in mats:
				if mat is StandardMaterial3D and not (mat as StandardMaterial3D).vertex_color_use_as_albedo:
					(mat as StandardMaterial3D).vertex_color_use_as_albedo = true
					done += 1
	return done
