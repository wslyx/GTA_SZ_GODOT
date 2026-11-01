extends Node3D
class_name MeadowLayer
##
## 草叶层 —— 逐行移植原版 src/city-meadow.ts（CityMeadow）。
##
## 数据：`grassland-v2/meadow.json`（3162 个 128m 瓦片，每瓦片 32×32×3 字节）
##   row-major（row = 北/z，col = 东/x），stride=3：[safe, soil, slope°×4]
##   safe == 255 才算合格点；slope > 12° 或 soil > .78 丢弃
##   坐标：x = ix*128 + (col+.5)*4，z = iz*128 + (row+.5)*4（数据坐标）
##
## 每类瓦片按原版规则长出一丛丛草：
##   · 每个合格点最多 48 丛，按黄金角螺旋散布，半径 = safeRadius − .20
##   · 逐丛高度 .05–.11（2.5% 概率抽到 .12–.15 的“野草”）
##   · range 按序号分档：前 6 丛 28m / 12 丛 21m / 24 丛 14m / 其余 7m
##
## 渲染：一个 7 叶 × 5 三角的程序化网格 + 8 个 MultiMesh 槽位（原版 maxMeshes=8），
## 逐实例写矩阵 / 颜色 / 自定义数据（风摆的 range 与 phase → 着色器里的
## INSTANCE_CUSTOM）。空中或相机离地 > 16m 时整层关闭；街面上每 3m 或 70ms 重建。
##
## ⚠️ 选取不用 sort_custom：候选可达数千，GDScript 的 lambda 比较器会直接吃掉
## 几十毫秒。这里按优先级分 64 个桶顺序取，效果等同「取最近的前 N 个」。

const MANIFEST_PATH := "/city/grassland-v2/meadow.json"
const BASE := "res://data/city/grassland-v2/"
const SHADER_PATH := "res://shaders/meadow.gdshader"

## 原版 MEADOW_LIMITS
const LIMIT_CLUMPS := 2304
const LIMIT_MESHES := 8
const LIMIT_RADIUS := 28.0
const LIMIT_REBUILD_DISTANCE := 3.0
const LIMIT_BLADES := 7
const LIMIT_CLUMPS_PER_PATCH := 48
const LIMIT_LEAF_MARGIN := 0.20
const LIMIT_HIGH_CAMERA := 16.0
## 原版 cacheTiles 默认 12
const CACHE_TILES := 12
## 原版同时最多 4 个瓦片在途
const MAX_PENDING := 4
## 重建节流（毫秒）
## 驾驶模式的重建节流：原版 70ms 是"步行/慢速"节奏；行车 30m/s 时 3m 阈值
## 每秒能触发十几次 55–187ms 的草皮重建（实测热点转弯的主要卡顿之一）。
## 行车 500ms 一次足够：草皮是背景细节，速度感下不可感。
const REBUILD_THROTTLE_MS := 500
## 优先级分桶数（越大越接近精确排序）
const BUCKETS := 64

var world: CityWorld
var enabled := true

var _manifest: Dictionary = {}
var _tile_index: Dictionary = {}      ## "ix,iz" → tile
## 瓦片缓存："id" → {tile, patches, samples:{patch_key → clumps}, used}
var _cache: Dictionary = {}
var _revision := 0
var _max_clumps := LIMIT_CLUMPS
var _slots: Array = []                ## {mm, node}
var _mesh: Mesh = null
var _mat: ShaderMaterial = null

var _last_x := INF
var _last_z := INF
var _last_camera_y := INF
var _last_mode := ""
var _last_aerial := false
var _last_rebuild_ms := -100000
var _dirty := true
var _built := false
var _stats := {"instances": 0, "drawCalls": 0, "triangles": 0, "patches": 0,
	"mode": "driving", "loadedTiles": 0, "sourceTiles": 0}


func setup(p_world: CityWorld) -> void:
	world = p_world
	if not _load_manifest():
		return
	if not _build_material():
		return
	_mesh = _build_geometry()
	_built = true


func set_quality(p: Dictionary) -> void:
	_max_clumps = clampi(int(p.get("meadow_clumps", LIMIT_CLUMPS)), 1, 2500)
	_dirty = true


## 种植层要据此停掉 lawn-tuft 细节（原版 `p[2]===0 && this.meadow?.ready`）
func is_ready() -> bool:
	return _built


func _load_manifest() -> bool:
	var m: Dictionary = DataLoader.json_dict(MANIFEST_PATH)
	if m.is_empty():
		push_warning("[MeadowLayer] 缺少 grassland-v2/meadow.json")
		return false
	# 原版 validateMeadowManifest 的硬校验
	if int(m.get("schemaVersion", 0)) != 1 or int(m.get("tileSize", 0)) != 128 \
			or int(m.get("step", 0)) != 4 or int(m.get("gridSize", 0)) != 32 \
			or int(m.get("stride", 0)) != 3:
		push_warning("[MeadowLayer] 草地采样清单格式不符，整层关闭")
		return false
	var safe := float(m.get("safeRadius", 0.0))
	if safe < 0.3 or safe > 3.5:
		push_warning("[MeadowLayer] safeRadius=%s 越界，整层关闭" % str(safe))
		return false
	var tiles: Array = m.get("tiles", [])
	if tiles.is_empty() or tiles.size() > 20000:
		push_warning("[MeadowLayer] 草地采样瓦片数异常，整层关闭")
		return false
	_manifest = m
	for t in tiles:
		var td: Dictionary = t
		_tile_index["%d,%d" % [int(td.get("ix", 0)), int(td.get("iz", 0))]] = td
	print("[MeadowLayer] 草地瓦片 %d 个 / safeRadius %s m / 每瓦片 32×32×3 字节"
		% [tiles.size(), str(safe)])
	return true


func _build_material() -> bool:
	if not ResourceLoader.exists(SHADER_PATH):
		push_warning("[MeadowLayer] 缺少 meadow.gdshader")
		return false
	var shader := load(SHADER_PATH) as Shader
	if shader == null:
		return false
	_mat = ShaderMaterial.new()
	_mat.shader = shader
	return true


# ---------------------------------------------------------------------------
# 几何：7 叶 × 5 三角（原版 createMeadowGeometry 逐行对应）
# ---------------------------------------------------------------------------

## 原版 hash(n)：32 位整数散列 → [0,1)。GDScript 的 int 是 64 位，
## 所以每一步都要自己截回 32 位（原版靠 Math.imul + >>>0）。
static func _hash(n: int) -> float:
	var x := n & 0xFFFFFFFF
	x = (x ^ (x >> 16)) & 0xFFFFFFFF
	x = (x * 0x7FEB352D) & 0xFFFFFFFF
	x = (x ^ (x >> 15)) & 0xFFFFFFFF
	x = (x * 0x846CA68B) & 0xFFFFFFFF
	x = (x ^ (x >> 16)) & 0xFFFFFFFF
	return float(x) / 4294967296.0


## 原版 cellSeed：imul(x,73856093) ^ imul(z,19349663)（取无符号低 32 位）
static func _cell_seed(x: int, z: int) -> int:
	var a := (x * 73856093) & 0xFFFFFFFF
	var b := (z * 19349663) & 0xFFFFFFFF
	return (a ^ b) & 0xFFFFFFFF


## 原版 rangeFor(i)
static func _range_for(i: int) -> float:
	if i < 6:
		return 28.0
	if i < 12:
		return 21.0
	if i < 24:
		return 14.0
	return 7.0


func _build_geometry() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for blade in LIMIT_BLADES:
		var seed := blade * 97 + 51
		var angle := float(blade) * 2.399963229728653
		var dx := cos(angle)
		var dz := sin(angle)
		var wx := -dz
		var wz := dx
		var root := 0.12 + _hash(seed) * 0.08
		var bend := 0.15 + _hash(seed + 1) * 0.13
		var top := 0.78 + _hash(seed + 2) * 0.22
		var width := 0.055 + _hash(seed + 3) * 0.022
		var base := blade * 7
		var ts := [0.0, 0.40, 0.76]
		for t in ts:
			_add_vert(st, float(t), -1.0, dx, dz, wx, wz, root, bend, top, width)
			_add_vert(st, float(t), 1.0, dx, dz, wx, wz, root, bend, top, width)
		_add_vert(st, 1.0, 0.0, dx, dz, wx, wz, root, bend, top, width)
		var idx := PackedInt32Array([
			base, base + 2, base + 1,
			base + 1, base + 2, base + 3,
			base + 2, base + 4, base + 3,
			base + 3, base + 4, base + 5,
			base + 4, base + 6, base + 5,
		])
		for k in idx:
			st.add_index(k)
	st.generate_normals()
	return st.commit()


func _add_vert(st: SurfaceTool, t: float, side: float, dx: float, dz: float,
		wx: float, wz: float, root: float, bend: float, top: float, width: float) -> void:
	var spread := 0.0 if t == 1.0 else width * (1.0 - 0.82 * t) * side
	var pos := Vector3(dx * (root + bend * t * t) + wx * spread,
		top * t, dz * (root + bend * t * t) + wz * spread)
	# 顶点明度渐变（原版 colors.push(brightness, brightness, brightness*.94)）
	var brightness := 0.60 + 0.40 * pow(t, 0.70)
	st.set_color(Color(brightness, brightness, brightness * 0.94, 1.0))
	st.set_uv(Vector2((side + 1.0) * 0.5, t))
	st.add_vertex(pos)


# ---------------------------------------------------------------------------
# 瓦片 → 点 → 丛
# ---------------------------------------------------------------------------

## 原版 decodeMeadowTile
func _decode_tile(tile: Dictionary, data: PackedByteArray) -> Array:
	var grid := int(_manifest.get("gridSize", 32))
	var stride := int(_manifest.get("stride", 3))
	var step := float(_manifest.get("step", 4.0))
	var safe_radius := float(_manifest.get("safeRadius", 2.9))
	if data.size() != int(tile.get("bytes", 0)):
		return []
	var out: Array = []
	for row in grid:
		for col in grid:
			var at := (row * grid + col) * stride
			if data[at] != 255:
				continue
			var slope := float(data[at + 2]) / 4.0
			var soil := float(data[at + 1]) / 255.0
			if slope > 12.0 or soil > 0.78:
				continue
			var gx := int(tile.get("ix", 0)) * grid + col
			var gz := int(tile.get("iz", 0)) * grid + row
			out.append({
				"x": (float(gx) + 0.5) * step,
				"z": (float(gz) + 0.5) * step,
				"soil": soil, "slope": slope,
				"seed": _cell_seed(gx, gz),
				"safe_radius": safe_radius,
			})
	return out


## 原版 createMeadowPatch
func _create_patch(p: Dictionary) -> Array:
	var safe_radius := float(p.get("safe_radius", 2.9))
	var radius := maxf(0.0, safe_radius - LIMIT_LEAF_MARGIN)
	var seed := int(p["seed"])
	var phase := _hash(seed + 3) * PI * 2.0
	var soil := float(p["soil"])
	var px := float(p["x"])
	var pz := float(p["z"])
	var out: Array = []
	for i in LIMIT_CLUMPS_PER_PATCH:
		var s := (seed + (i + 1) * 2654435761) & 0xFFFFFFFF
		if _hash(s + 7) < soil * 0.72:
			continue
		var theta := float(i) * 2.399963229728653 + phase + (_hash(s + 11) - 0.5) * 0.30
		var r := sqrt((float(i) + 0.25 + _hash(s + 17) * 0.5) / float(LIMIT_CLUMPS_PER_PATCH)) \
			* radius * (0.83 + 0.12 * sin(theta * 3.0 + phase) + 0.05 * cos(theta * 5.0 - phase))
		var wild := _hash(s + 23) < 0.025
		var height := 0.0
		if wild:
			height = 0.12 + _hash(s + 29) * 0.03
		else:
			height = 0.05 + _hash(s + 29) * 0.06
		out.append({
			"x": px + cos(theta) * r,
			"z": pz + sin(theta) * r,
			"height": height,
			"width": height * (0.85 + _hash(s + 31) * 0.30),
			"yaw": _hash(s + 37) * PI * 2.0,
			"soil": soil, "seed": s, "range": _range_for(i),
			"variation": 0.84 + _hash(s + 41) * 0.26,
			"tint": _hash(s + 43),
		})
	return out


## 取（并按需解码）一个瓦片；同步读 3KB 二进制文件，代价可忽略。
func _tile_loaded(tile: Dictionary) -> Dictionary:
	var id := str(tile.get("id", ""))
	if _cache.has(id):
		var e: Dictionary = _cache[id]
		e["used"] = _revision
		return e
	if _failed.has(id) or _pending >= MAX_PENDING:
		return {}
	var url := str(tile.get("url", ""))
	var path := BASE + url
	if not FileAccess.file_exists(path):
		_failed[id] = true
		return {}
	_pending += 1
	var data := FileAccess.get_file_as_bytes(path)
	_pending -= 1
	var patches := _decode_tile(tile, data)
	var entry := {"tile": tile, "patches": patches, "samples": {}, "used": _revision}
	_cache[id] = entry
	_trim_cache()
	return entry


var _pending := 0
var _failed: Dictionary = {}


func _trim_cache() -> void:
	if _cache.size() <= CACHE_TILES:
		return
	var ids: Array = _cache.keys()
	ids.sort_custom(func(a, b): return int(_cache[a]["used"]) < int(_cache[b]["used"]))
	var n := _cache.size() - CACHE_TILES
	for i in n:
		_cache.erase(ids[i])
	# 会话很长时同一批瓦片会反复进出，失败标记也要定期清（原版同样不缓存失败）
	if _failed.size() > 256:
		_failed.clear()


# ---------------------------------------------------------------------------
# 每帧
# ---------------------------------------------------------------------------

func update_system(delta: float, focus: Vector3) -> void:
	if not enabled or not _built:
		return
	_update(delta, focus)


func _update(_delta: float, focus: Vector3) -> void:
	var x := focus.x
	var z := -focus.z
	var aerial := world != null and world.aerial
	# ⚠️ 相机高度必须取**真实相机**：city_world 传给子系统的 focus 是玩家位置
	# （y=0），拿它算不出"离地 16m 以上就不长草"这条门限。
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var camera_y := cam.global_position.y if cam != null else focus.y
	var now := Time.get_ticks_msec()
	# 原版门限：3m 移动 / 相机高度变化 .5m / 视角模式变化才重建
	if not _dirty and aerial == _last_aerial and absf(camera_y - _last_camera_y) < 0.5 \
			and Vector2(x - _last_x, z - _last_z).length() < LIMIT_REBUILD_DISTANCE:
		return
	var ground := world.ground_height(x, -z) if world != null else 0.0
	var high := camera_y - ground > LIMIT_HIGH_CAMERA
	var mode := "aerial" if aerial else ("high-camera" if high else "driving")
	# 原版：街面模式下 70ms 内不再上传
	if mode == "driving" and _last_mode == "driving" \
			and absf(camera_y - _last_camera_y) < 2.0 and now - _last_rebuild_ms < REBUILD_THROTTLE_MS:
		return
	_last_x = x
	_last_z = z
	_last_camera_y = camera_y
	_last_aerial = aerial
	_last_mode = mode
	_dirty = false
	_eye = Vector3(x, camera_y, z)
	_stats["mode"] = mode
	if mode != "driving":
		for s in _slots:
			(s["node"] as MultiMeshInstance3D).visible = false
		_stats["instances"] = 0
		_stats["drawCalls"] = 0
		_stats["triangles"] = 0
		_stats["patches"] = 0
		return
	_last_rebuild_ms = now
	_rebuild(x, z)


func _rebuild(x: float, z: float) -> void:
	_revision += 1
	var safe := float(_manifest.get("safeRadius", 2.9))
	var radius := LIMIT_RADIUS + LIMIT_REBUILD_DISTANCE + safe
	var tile_size := float(_manifest.get("tileSize", 128.0))
	# 该半径内可能命中的瓦片（通常是 1–4 个）
	var lo_ix := int(floor((x - radius) / tile_size))
	var hi_ix := int(floor((x + radius) / tile_size))
	var lo_iz := int(floor((z - radius) / tile_size))
	var hi_iz := int(floor((z + radius) / tile_size))
	var tiles: Array = []
	for ix in range(lo_ix, hi_ix + 1):
		for iz in range(lo_iz, hi_iz + 1):
			var key := "%d,%d" % [ix, iz]
			if not _tile_index.has(key):
				continue
			var tile: Dictionary = _tile_index[key]
			if int(tile.get("count", 0)) <= 0:
				continue
			var entry := _tile_loaded(tile)
			if not entry.is_empty():
				tiles.append(entry)

	# 候选丛：按优先级（d / range）分桶，避免 GDScript 里的 sort_custom
	var buckets: Array = []
	buckets.resize(BUCKETS)
	for i in BUCKETS:
		buckets[i] = []
	var patch_count := 0
	for entry in tiles:
		var tid := str(entry["tile"].get("id", ""))
		for patch in entry["patches"]:
			if Vector2(float(patch["x"]) - x, float(patch["z"]) - z).length() > radius:
				continue
			patch_count += 1
			var samples: Dictionary = entry["samples"]
			var pkey := int(patch["seed"])
			var clumps: Array
			if samples.has(pkey):
				clumps = samples[pkey]
			else:
				clumps = _create_patch(patch)
				samples[pkey] = clumps
			for c in clumps:
				var d := Vector2(float(c["x"]) - x, float(c["z"]) - z).length()
				if d > float(c["range"]) + LIMIT_REBUILD_DISTANCE:
					continue
				var priority := d / float(c["range"])
				var b := clampi(int(priority * float(BUCKETS - 1)), 0, BUCKETS - 1)
				(buckets[b] as Array).append({"c": c, "tile": tid})

	# 顺序取到预算为止
	var cap := mini(_max_clumps, LIMIT_CLUMPS)
	var groups := {}
	var total := 0
	for bi in BUCKETS:
		if total >= cap:
			break
		for it in buckets[bi]:
			if total >= cap:
				break
			var tid2 := str(it["tile"])
			if not groups.has(tid2):
				if groups.size() >= LIMIT_MESHES:
					continue
				groups[tid2] = []
			(groups[tid2] as Array).append(it["c"])
			total += 1

	_write(groups, x, z, patch_count)
	# 长期驻留的瓦片样本会一直累积，要把远离的补丁样本丢掉（原版同款清理）。
	# ⚠️ 这里先按瓦片一次性算出"该留哪些 seed"，再整体擦除 —— 不要在
	# 样本键上再套一层补丁遍历，那是 O(样本 × 补丁) ≈ 百万次。
	for entry2 in _cache.values():
		var samples2: Dictionary = entry2["samples"]
		if samples2.size() <= 64:
			continue
		var keep := {}
		for patch2 in entry2["patches"]:
			if Vector2(float(patch2["x"]) - x, float(patch2["z"]) - z).length() <= radius + 8.0:
				keep[int(patch2["seed"])] = true
		for pkey2 in samples2.keys():
			if not keep.has(pkey2):
				samples2.erase(pkey2)


var _eye := Vector3.ZERO


func _write(groups: Dictionary, x: float, z: float, patch_count: int) -> void:
	if _mat == null:
		return
	var instances := 0
	var used := 0
	for tid in groups:
		var clumps: Array = groups[tid]
		var n := clumps.size()
		if n == 0:
			continue
		var slot := _slot(used)
		used += 1
		var mm: MultiMesh = slot["mm"]
		# 容量按 128 对齐，避免每帧重分配缓冲
		var want := int(ceil(float(n) / 128.0)) * 128
		if mm.instance_count != want:
			mm.instance_count = want
		mm.visible_instance_count = n
		for i in n:
			var c: Dictionary = clumps[i]
			var cx := float(c["x"])
			var cz := float(c["z"])
			var h := float(c["height"])
			var w := float(c["width"])
			var g := world.ground_height(cx, -cz) - 0.004
			var inst_basis := Basis(Vector3.UP, -float(c["yaw"])).scaled(Vector3(w, h, w))
			mm.set_instance_transform(i, Transform3D(inst_basis, CoordinateUtil.to_world(cx, cz, g)))
			# 原版：variation = .84 + hash*.26，dry = soil*.22
			var variation := float(c["variation"])
			var dry := float(c["soil"]) * 0.22
			mm.set_instance_color(i, Color(
				minf(1.15, variation + dry), variation,
				variation * (0.85 + float(c["tint"]) * 0.15), 1.0))
			mm.set_instance_custom_data(i, Color(float(c["range"]),
				_hash(int(c["seed"]) + 47) * PI * 2.0, 0.0, 0.0))
		(slot["node"] as MultiMeshInstance3D).visible = true
		instances += n
	for i in range(used, _slots.size()):
		(_slots[i]["node"] as MultiMeshInstance3D).visible = false
	_stats["instances"] = instances
	_stats["drawCalls"] = used
	_stats["triangles"] = instances * LIMIT_BLADES * 5
	_stats["patches"] = patch_count
	_stats["loadedTiles"] = _cache.size()
	_stats["sourceTiles"] = _tile_index.size()
	_sync_shader()


func _slot(idx: int) -> Dictionary:
	while _slots.size() <= idx:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = _mesh
		var node := MultiMeshInstance3D.new()
		node.multimesh = mm
		node.name = "meadow-%d" % _slots.size()
		# 不自投影（原版 castsShadows:false），接收阴影交给地面
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.material_override = _mat
		add_child(node)
		_slots.append({"mm": mm, "node": node})
	return _slots[idx]


func _sync_shader() -> void:
	if _mat == null:
		return
	var night := 1.0 if GameState.light_mode == GameContent.LightMode.NIGHT else 0.0
	# 用真实流逝时间驱动风摆（原版 performance.now()/1000）
	_mat.set_shader_parameter("meadow_eye_time",
		Vector4(_eye.x, _eye.y, _eye.z, float(Time.get_ticks_msec()) / 1000.0))
	_mat.set_shader_parameter("city_landscape_night", Vector4(night, 0.05, 1.12, 0.12))


func diagnostics() -> Dictionary:
	return {
		"ready": _built,
		"sourceTiles": _tile_index.size(),
		"loadedTiles": _cache.size(),
		"maxClumps": _max_clumps,
		"slots": _slots.size(),
		"stats": _stats,
	}
