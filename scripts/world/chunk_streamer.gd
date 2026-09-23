extends Node3D
class_name ChunkStreamer
##
## 城市建筑区块动态加载 / 卸载。
##
## 移植目标：原版 GTA_SZ 把整座深圳（buildings.glb ≈ 266MB）一次性塞进场景，
## 旧版 city_world._cull_chunks 只切换 node.visible —— 几何始终驻留显存，城市越大越吃内存。
## 本模块把建筑按 640m 区块（与 buildings.glb 内 block_i_j 命名一一对应）做成独立 GLB，
## 仅保留玩家周围一圈常驻，玩家移动时边界随之平移：
##
##   * 区块中心距玩家 ≤ LOAD_RADIUS(3000m)        → 加载（角色始终离"未加载边界"约 3km）
##   * 区块中心距玩家 >  UNLOAD_RADIUS(3600m)      → 卸载（迟滞，避免边界抖动反复加载）
##   * 空中视角（observer）：放大半径 + 250ms 稳定延迟，避免边飞边加载
##
## 数据：res://data/city/blocks-manifest.json
##       {chunkSize, blocks:[{i,j,x,z,file}]}，x/z 为数据坐标 (east, north)。
## 区块文件：res://data/city/blocks/<i>_<j>.glb（由 tools/split_city_blocks.py 从 monolithic
##       buildings.glb 切出；不含被地标替换掉的楼体 mesh）。
##
## 与 FacadeStreamer 同构：严格串行、冷却、失败重试；额外用 CACHE_MODE_IGNORE 让
## 卸载时 PackedScene 引用归零即被 GC，真正回收显存（见 glb_loader.gd）。
##
## 回退：若 manifest 或区块文件缺失，CityWorld 走 monolithic 老路径，本模块 inactive，
##       绝不破坏现有工程。

const MANIFEST_PATH := "res://data/city/blocks-manifest.json"
const BLOCK_SIZE := 640.0

## 角色离"未加载边界"的目标距离（约 3km）。玩家永远在 LOAD_RADIUS 内拥有已加载区块，
## 所以最近一块未加载区块中心 ≥ LOAD_RADIUS，边界始终保持在 3km 左右。
const LOAD_RADIUS := 3000.0
## 卸载半径 > 加载半径，形成迟滞带，避免玩家在 3km 线上来回时区块反复加载/卸载。
const UNLOAD_RADIUS := 3600.0
const LOAD_RADIUS_AERIAL := 6000.0
const UNLOAD_RADIUS_AERIAL := 7200.0
const AERIAL_LOAD_DELAY_MS := 250.0
## 运行时串行加载冷却：每块建筑 GLB 较小（数百 KB~数 MB），尖峰比立面瓦片轻，冷却可更短。
const LOAD_COOLDOWN := 0.12
## 出生点预加载冷却：加载界面里一次性铺满 3km，冷却压到极小，尽快出加载条。
const PRELOAD_COOLDOWN := 0.02
## 加载/卸载扫描降频：640m 粒度，4~5Hz 足够。
const VIS_INTERVAL := 0.2
## 阴影只投在玩家附近（原版 SHADOW_RADIUS=520m）。
const SHADOW_RADIUS := 520.0
const FAILED_RETRY_DELAY := 4.0
const MAX_ATTEMPTS := 3

var world: CityWorld
var active := false          ## manifest 已就绪、正在流式
var enabled := true

var chunks: Array = []       ## {i,j,x,z,file,state,node,scene}
var _by_key: Dictionary = {} ## "i_j" → entry
var _loader := GlbLoader.new()
var _current_key := ""
var _failed: Dictionary = {}
var _attempts: Dictionary = {}
var _retry_timer := 0.0
var _aerial_delay := 0.0
var _cooldown := 0.0
var _vis_timer := 0.0
var _aerial := false
var stats_loaded := 0
var stats_unloaded := 0
var stats_failed := 0

# --- 启动期预加载 -----------------------------------------------------------
var _preload_keys: Array = []
var _preload_total := 0
var _preload_done_n := 0
var _setup_done := false


func setup(p_world: CityWorld) -> void:
	if _setup_done:
		return
	_setup_done = true
	world = p_world
	_loader.entry_loaded.connect(_on_loaded)
	_loader.entry_failed.connect(_on_failed)


## manifest 是否存在（供 CityWorld 决定是否走流式 / 回退）。
static func manifest_available() -> bool:
	return ResourceLoader.exists(MANIFEST_PATH)


## 读 manifest，建区块清单。幂等。
func init_manifest() -> bool:
	if not chunks.is_empty():
		active = true
		return true
	if not manifest_available():
		return false
	var man: Dictionary = DataLoader.json_dict(MANIFEST_PATH)
	if man.is_empty() or not man.has("blocks"):
		push_warning("[ChunkStreamer] manifest 格式异常：%s" % MANIFEST_PATH)
		return false
	for b in man.get("blocks", []):
		var i := int(b["i"])
		var j := int(b["j"])
		var e := {
			"i": i, "j": j,
			"x": float(b["x"]), "z": float(b["z"]),
			"file": str(b["file"]),
			"node": null, "scene": null,
			"state": "pending",  # pending | loading | loaded | dead
		}
		chunks.append(e)
		_by_key["%d_%d" % [i, j]] = e
	active = true
	print("[ChunkStreamer] 区块清单 %d 块，加载半径 %.0fm / 卸载 %.0fm"
		% [chunks.size(), LOAD_RADIUS, UNLOAD_RADIUS])
	return true


func set_aerial(v: bool) -> void:
	_aerial = v


# ---------------------------------------------------------------------------
# 启动期预加载（出生点周围 LOAD_RADIUS 内一次性铺满）
# ---------------------------------------------------------------------------

func begin_preload(focus_data: Vector2) -> int:
	_preload_keys.clear()
	_preload_total = 0
	_preload_done_n = 0
	var fx := focus_data.x
	var fz := focus_data.y
	for e in chunks:
		if e["state"] != "pending":
			continue
		var dx := float(e["x"]) - fx
		var dz := float(e["z"]) - fz
		if dx * dx + dz * dz <= LOAD_RADIUS * LOAD_RADIUS:
			_preload_keys.append("%d_%d" % [e["i"], e["j"]])
	if _preload_keys.is_empty():
		return 0
	_preload_total = _preload_keys.size()
	for key in _preload_keys:
		var e: Dictionary = _by_key[key]
		e["state"] = "loading"
		_loader.enqueue(e["file"], world.chunks_root, key, ResourceLoader.CACHE_MODE_IGNORE)
	print("[ChunkStreamer] 预加载出生点 %.0fm 内建筑区块 %d 块" % [LOAD_RADIUS, _preload_total])
	return _preload_total


func poll_preload() -> void:
	if _preload_keys.is_empty():
		return
	_loader.poll()


func preload_done() -> bool:
	if _preload_keys.is_empty():
		return true
	return _loader.is_idle()


func preload_progress() -> float:
	if _preload_keys.is_empty():
		return 1.0
	if _loader.is_idle():
		return 1.0
	var done := 0
	for key in _preload_keys:
		var e: Dictionary = _by_key.get(key, {})
		if str(e.get("state", "")) == "loaded":
			done += 1
	return clampf(float(done) / float(_preload_total), 0.0, 0.99)


func preload_detail() -> String:
	if _preload_keys.is_empty():
		return ""
	var done := 0
	for key in _preload_keys:
		var e: Dictionary = _by_key.get(key, {})
		if str(e.get("state", "")) == "loaded":
			done += 1
	return "建筑区块 %d / %d" % [done, _preload_total]


# ---------------------------------------------------------------------------
# 运行时：每帧调用（throttled）
# ---------------------------------------------------------------------------

func update_system(delta: float, focus: Vector3) -> void:
	if not enabled or not active or chunks.is_empty():
		return
	# 焦点换算到数据坐标 (east, north)，与 manifest 的 x/z 同空间
	var fx := focus.x
	var fz := -focus.z
	_cooldown -= delta
	_retry_timer -= delta

	# 1) 卸载扫描（降频）：超出 UNLOAD_RADIUS 的已加载区块整块释放
	_vis_timer -= delta
	if _vis_timer <= 0.0:
		_vis_timer = VIS_INTERVAL
		var unload_r := UNLOAD_RADIUS_AERIAL if _aerial else UNLOAD_RADIUS
		var ur2 := unload_r * unload_r
		var sr2 := SHADOW_RADIUS * SHADOW_RADIUS
		for e in chunks:
			if e["state"] != "loaded":
				continue
			var dx := float(e["x"]) - fx
			var dz := float(e["z"]) - fz
			var d2 := dx * dx + dz * dz
			if d2 > ur2:
				_unload_chunk(e)
				continue
			# 阴影随玩家移动刷新（chunk 加载时只判定了一次）
			var near := d2 <= sr2
			var node: Node3D = e["node"]
			if node != null and is_instance_valid(node):
				var cast := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if near \
					else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				for mi in GlbLoader.meshes_of(node):
					if mi.cast_shadow != cast:
						mi.cast_shadow = cast

	# 2) 串行排队加载：LOAD_RADIUS 内最近的未加载区块
	if not _loader.is_idle():
		_loader.poll()
		return
	if _current_key != "":
		return
	if _aerial:
		if _aerial_delay < AERIAL_LOAD_DELAY_MS:
			_aerial_delay += delta * 1000.0
			return
	else:
		_aerial_delay = 0.0
	if _cooldown > 0.0:
		return

	var load_r := LOAD_RADIUS_AERIAL if _aerial else LOAD_RADIUS
	var lr2 := load_r * load_r
	var best := ""
	var best_d2 := INF
	for e in chunks:
		if e["state"] != "pending":
			continue
		if _failed.has("%d_%d" % [e["i"], e["j"]]) and _retry_timer > 0.0:
			continue
		var dx := float(e["x"]) - fx
		var dz := float(e["z"]) - fz
		var d2 := dx * dx + dz * dz
		if d2 <= lr2 and d2 < best_d2:
			best_d2 = d2
			best = "%d_%d" % [e["i"], e["j"]]
	if best == "":
		if _retry_timer <= 0.0:
			_retry_timer = 3.0
			_failed.clear()
		return

	var entry: Dictionary = _by_key[best]
	entry["state"] = "loading"
	_current_key = best
	_cooldown = LOAD_COOLDOWN
	_loader.enqueue(entry["file"], world.chunks_root, best, ResourceLoader.CACHE_MODE_IGNORE)


func _unload_chunk(e: Dictionary) -> void:
	var node: Node3D = e["node"]
	if node != null and is_instance_valid(node):
		node.queue_free()
	var key := "%d_%d" % [e["i"], e["j"]]
	if world != null:
		world.blocks = world.blocks.filter(
			func(b: Dictionary) -> bool: return is_instance_valid(b.get("node", null)) and b["node"] != node)
	e["node"] = null
	e["scene"] = null   # 丢弃 PackedScene 引用；CACHE_MODE_IGNORE 下引用归零即被 GC
	e["state"] = "pending"
	_failed.erase(key)
	stats_unloaded += 1


func _on_loaded(_path: String, node: Node3D, meta: Variant, scene: Resource) -> void:
	var key := str(meta)
	_current_key = ""
	var e: Dictionary = _by_key.get(key, {})
	if e.is_empty():
		# 找不到对应区块（极端情况）：直接释放，避免悬挂。
		if node != null and is_instance_valid(node):
			node.queue_free()
		return
	GlbLoader.configure_meshes(GlbLoader.meshes_of(node), true, false)
	# 阴影投在玩家附近（与 city_world 旧 _cull_chunks 一致）
	var dx := float(e["x"]) - world.focus.x
	var dz := float(e["z"]) - (-world.focus.z)
	var near := dx * dx + dz * dz <= SHADOW_RADIUS * SHADOW_RADIUS
	for mi in GlbLoader.meshes_of(node):
		mi.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_ON if near
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	e["node"] = node
	e["scene"] = scene
	e["state"] = "loaded"
	stats_loaded += 1
	# 维护 world.blocks，供 traffic / pedestrian / scenery 的 place() 就绪判断
	if world != null:
		world.blocks.append({
			"node": node, "i": e["i"], "j": e["j"],
			"x": e["x"], "z": e["z"], "road": false, "detail": false,
		})


func _on_failed(path: String, _reason: String) -> void:
	var key := _current_key
	if key == "":
		# 预加载是批量入队，_current_key 恒空，只能从路径反推 i_j
		var fn := path.get_file().get_basename()   # "<i>_<j>"
		key = fn
	_current_key = ""
	stats_failed += 1
	if key == "":
		return
	var n := int(_attempts.get(key, 0)) + 1
	_attempts[key] = n
	var e: Dictionary = _by_key.get(key, {})
	if e.is_empty():
		return
	if n >= MAX_ATTEMPTS:
		e["state"] = "dead"
		push_warning("[ChunkStreamer] 区块 %s 连续失败 %d 次，永久跳过" % [key, n])
		return
	_failed[key] = true
	e["state"] = "pending"
	_retry_timer = FAILED_RETRY_DELAY


func diagnostics() -> Dictionary:
	var loaded := 0
	var shown := 0
	for e in chunks:
		if e["state"] == "loaded":
			loaded += 1
			var n: Node3D = e["node"]
			if n != null and is_instance_valid(n) and n.visible:
				shown += 1
	return {
		"active": active, "blocks": chunks.size(), "loaded": loaded, "visible": shown,
		"loadedTotal": stats_loaded, "unloadedTotal": stats_unloaded, "failed": stats_failed,
		"pending": _loader.pending(), "current": _current_key,
		"loadRadius": LOAD_RADIUS, "unloadRadius": UNLOAD_RADIUS, "aerial": _aerial,
	}
