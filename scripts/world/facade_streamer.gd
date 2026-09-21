extends Node3D
class_name FacadeStreamer
##
## 立面瓦片流式加载 —— 逐行移植原版 src/city-facade-stream.ts。
##
## 规则（照搬原版）：
##   分块 640m；初始化时加载玩家 700m 内的瓦片
##   每帧：距中心 >1500m 卸载；<700m 显示
##   加载队列：在 1050m 内找**第一个**未加载的瓦片，**一次只加载一个**（串行），
##   失败记入 failed 集合并稍后重试
##   空中视角时引入 250ms 延迟，等视角稳定后再排队，避免边飞边加载
##
## 数据：city/facade-tiles.json {tileSize:640, tiles:[{id,x,z,bytes,meshes,sha256}]}
## 瓦片文件：data/city/facade-tiles/<id>.glb

const TILE_SIZE := 640.0
const SHOW_RADIUS := 700.0
const QUEUE_RADIUS := 1050.0
const UNLOAD_RADIUS := 1500.0
const AERIAL_LOAD_DELAY_MS := 250
## 失败重试间隔（秒）与重试上限。
## 必须有一个下限：之前失败后没有重置 _retry_timer，而选点条件又是
## "_retry_timer <= 0 时不再拦截失败瓦片"，于是缺失的瓦片会被**每帧重新排队**，
## 每帧一条 push_warning，永不收敛。
const FAILED_RETRY_DELAY := 4.0
const MAX_ATTEMPTS := 3

var world: CityWorld
var enabled := true

var tiles: Array = []                 ## {id, x, z, node, state}
var _by_id: Dictionary = {}
var _loader := GlbLoader.new()
var _current_id := ""
var _failed: Dictionary = {}
var _attempts: Dictionary = {}
var _retry_timer := 0.0
var _aerial_delay := 0.0
var _quality_scale := 1.0
var stats_loaded := 0
var stats_unloaded := 0
var stats_failed := 0

# --- 启动期预加载 -----------------------------------------------------------
## 出生点附近的瓦片在加载界面里一次性载完，避免行驶途中单块 6MB GLB 造成掉帧。
var _preload_ids: Array = []
var _preload_total := 0
var _preload_done_n := 0
var _setup_done := false


func setup(p_world: CityWorld) -> void:
	# 幂等：CityWorld 的步骤与 main_game 都可能调到这里，重复 connect 会让
	# 同一块瓦片被处理两次（_by_id 里 state 被覆写）。
	if _setup_done:
		return
	_setup_done = true
	world = p_world
	_loader.entry_loaded.connect(_on_loaded)
	_loader.entry_failed.connect(_on_failed)


# ---------------------------------------------------------------------------
# 启动期预加载
# ---------------------------------------------------------------------------

## 把 focus_data 半径内的瓦片全部入队（仍是一次一个地串行走完）
func begin_preload(focus_data: Vector2) -> int:
	_preload_ids.clear()
	_preload_total = 0
	_preload_done_n = 0
	var fx := focus_data.x
	var fz := focus_data.y
	for t in tiles:
		var d := Vector2(float(t["x"]) - fx, float(t["z"]) - fz).length()
		if d <= SHOW_RADIUS:
			_preload_ids.append(str(t["id"]))
	if _preload_ids.is_empty():
		return 0
	_preload_total = _preload_ids.size()
	for id in _preload_ids:
		var e: Dictionary = _by_id[id]
		e["state"] = "loading"
		_loader.enqueue(_tile_path(id), self, id)
	print("[FacadeStreamer] 预加载出生点 %.0fm 内立面瓦片 %d 块" % [SHOW_RADIUS, _preload_total])
	return _preload_total


func poll_preload() -> void:
	if _preload_ids.is_empty():
		return
	_loader.poll()


func preload_done() -> bool:
	if _preload_ids.is_empty():
		return true
	return _loader.is_idle()


func preload_progress() -> float:
	if _preload_ids.is_empty():
		return 1.0
	if _loader.is_idle():
		return 1.0
	# 用「已就位的瓦片数 / 总数」，比单块的线程进度更贴合观感
	var done := 0
	for id in _preload_ids:
		var e: Dictionary = _by_id.get(id, {})
		if str(e.get("state", "")) == "loaded":
			done += 1
	return clampf(float(done) / float(_preload_total), 0.0, 0.99)


func preload_detail() -> String:
	if _preload_ids.is_empty():
		return ""
	var done := 0
	for id in _preload_ids:
		var e: Dictionary = _by_id.get(id, {})
		if str(e.get("state", "")) == "loaded":
			done += 1
	return "近景立面 %d / %d" % [done, _preload_total]


## 由 CityWorld 的步骤调用
func init_streaming(focus_data: Vector2) -> bool:
	if not tiles.is_empty():
		return true  # 幂等：重复调用不重建清单
	var man: Dictionary = CityData.facade_tiles
	if man.is_empty():
		man = DataLoader.json_dict("/city/facade-tiles.json")
	for t in man.get("tiles", []):
		var id := str(t["id"])
		var e := {
			"id": id,
			"x": float(t["x"]),
			"z": float(t["z"]),
			"node": null,
			"state": "pending",  # pending | loading | loaded
		}
		tiles.append(e)
		_by_id[id] = e
	print("[FacadeStreamer] 瓦片清单 %d 块，初始加载 %.0fm 内" % [tiles.size(), SHOW_RADIUS])
	return true


func set_quality(p: Dictionary) -> void:
	_quality_scale = float(p.get("detail_scale", 1.0))


func _tile_path(id: String) -> String:
	return "res://data/city/facade-tiles/%s.glb" % id


func update_system(delta: float, focus: Vector3) -> void:
	if not enabled or tiles.is_empty():
		return
	var fx := focus.x
	var fz := -focus.z

	# 1) 卸载
	for t in tiles:
		if t["state"] != "loaded":
			continue
		var d := Vector2(float(t["x"]) - fx, float(t["z"]) - fz).length()
		if d > UNLOAD_RADIUS:
			var node: Node3D = t["node"]
			if node != null and is_instance_valid(node):
				node.queue_free()
			t["node"] = null
			t["state"] = "pending"
			stats_unloaded += 1

	# 2) 显示 / 隐藏
	for t in tiles:
		var node: Node3D = t["node"]
		if node == null or not is_instance_valid(node):
			continue
		var d := Vector2(float(t["x"]) - fx, float(t["z"]) - fz).length()
		node.visible = d <= SHOW_RADIUS * _quality_scale

	# 3) 串行排队加载：1050m 内最近的未加载瓦片
	if not _loader.is_idle():
		_loader.poll()
		return
	if _current_id != "":
		return

	if world != null and world.aerial:
		if _aerial_delay < AERIAL_LOAD_DELAY_MS:
			_aerial_delay += delta * 1000.0
			return
	else:
		_aerial_delay = 0.0

	_retry_timer -= delta
	var best := ""
	var best_d := INF
	for t in tiles:
		if t["state"] != "pending":
			continue
		if _failed.has(t["id"]) and _retry_timer > 0.0:
			continue
		var d := Vector2(float(t["x"]) - fx, float(t["z"]) - fz).length()
		if d <= QUEUE_RADIUS and d < best_d:
			best_d = d
			best = str(t["id"])
	if best == "":
		if _retry_timer <= 0.0:
			_retry_timer = 3.0
			_failed.clear()
		return

	var entry: Dictionary = _by_id[best]
	entry["state"] = "loading"
	_current_id = best
	_loader.enqueue(_tile_path(best), self, best)


func _on_loaded(_path: String, node: Node3D, meta: Variant) -> void:
	var id := str(meta)
	_current_id = ""
	var e: Dictionary = _by_id.get(id, {})
	if e.is_empty():
		node.queue_free()
		return
	GlbLoader.configure_meshes(GlbLoader.meshes_of(node), true, false)
	e["node"] = node
	e["state"] = "loaded"
	stats_loaded += 1


func _on_failed(path: String, _reason: String) -> void:
	# 预加载阶段是批量入队的，_current_id 一直是空串，只能从路径反推 id
	var id := _current_id
	if id == "":
		id = path.get_file().get_basename()
	_current_id = ""
	stats_failed += 1
	if id == "":
		return
	var n := int(_attempts.get(id, 0)) + 1
	_attempts[id] = n
	var e: Dictionary = _by_id.get(id, {})
	if e.is_empty():
		return
	if n >= MAX_ATTEMPTS:
		# 彻底放弃，不再排队（否则会一直重试一个根本不存在的瓦片）
		e["state"] = "dead"
		push_warning("[FacadeStreamer] 瓦片 %s 连续失败 %d 次，永久跳过" % [id, n])
		return
	_failed[id] = true
	e["state"] = "pending"
	_retry_timer = FAILED_RETRY_DELAY


func diagnostics() -> Dictionary:
	var loaded := 0
	# 不能叫 visible —— Node3D 已有 visible 属性
	var shown := 0
	for t in tiles:
		if t["state"] == "loaded":
			loaded += 1
			var n: Node3D = t["node"]
			if n != null and is_instance_valid(n) and n.visible:
				shown += 1
	return {"tiles": tiles.size(), "loaded": loaded, "visible": shown,
			"loadedTotal": stats_loaded, "unloadedTotal": stats_unloaded,
			"failed": stats_failed, "pending": _loader.pending(), "current": _current_id}
