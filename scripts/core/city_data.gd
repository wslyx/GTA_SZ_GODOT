extends Node
##
## 城市数据集（autoload: CityData）。
##
## 对应原版 src/city-map.ts + city-world.ts 里的数据加载部分。原版用 fetch 拉 JSON，
## 这里用 DataLoader 从 res://data 读，并做**一次性结构化**（把嵌套 Array 转成
## PackedVector2Array 等紧凑类型），避免每帧反复做类型转换。
##
## 数据之间的分工（与原版一致，容易搞错的点）：
##   city.json
##     - roads / buildings / green / water 的**环**：用于碰撞、招牌布点、地图绘制。
##       **不是**渲染几何 —— 建筑外观来自 buildings.glb，道路来自 roads.glb。
##     - navigation.json 的 nodes/edges 才是交通与自动驾驶用的路网图。
##   buildings.glb / terrain.glb / roads.glb：真正的渲染几何。
##   landmark-detail.glb / landmark-candidates.glb：重点地标，须先按 baseBuildingIds
##     把基础楼体从 buildings 列表里剔除，否则会重叠。
##   street-surfaces.json / ground-surfaces.json / surfaces.json / facades.glb
##     是构建中间产物，运行时不需要（原版 cloudflare 部署也显式跳过），本移植未迁移。

signal core_loaded()

## 未命名道路命名（原版 src/city-road-names.ts）。
## ⚠️ 用 preload 而不是全局类名：新脚本的 class_name 要等编辑器重扫才进全局类缓存，
## 运行时直接引用会报 "Could not find type"。
const ROAD_NAMES_SCRIPT := preload("res://scripts/core/road_names.gd")

const CITY_JSON := "/city/city.json"
const NAVIGATION_JSON := "/city/navigation.json"
const TERRAIN_DETAIL_JSON := "/city/terrain-detail.json"
const LANDMARK_DETAIL_JSON := "/city/landmark-detail.json"
const LANDMARK_CANDIDATES_JSON := "/city/landmark-candidates.json"
const LANDMARK_SIGNAGE_JSON := "/city/landmark-signage.json"
const COASTAL_INFRA_JSON := "/city/coastal/infrastructure.json"
const FACADE_TILES_JSON := "/city/facade-tiles.json"
const BUILDING_EXCLUSIONS_JSON := "/city/building-exclusions.json"
const METADATA_JSON := "/city/metadata.json"
const TERRAIN_MANIFEST_JSON := "/city/terrain-manifest.json"
const DETAIL_MANIFEST_JSON := "/city/detail-manifest.json"

# --- meta ------------------------------------------------------------------
var meta: Dictionary = {}
var extent := Rect2()
var spawn_pos := Vector2.ZERO
var spawn_yaw := 0.0
var spawn_road := ""

# --- 环数据（碰撞 / 地图）---------------------------------------------------
var land_rings: Array = []
## 未拍平的 land 分组（每组 = [外环, 洞...]）—— ObserverDestination 的水面判定
## 需要「外环 + 洞」结构，land_rings 拍平后洞的信息就丢了。
var land_groups: Array = []
var coast_rings: Array = []
var green: Array = []      ## [{name, rings}]
var water: Array = []      ## [{name, rings}]
var roads: Array = []      ## [{id,name,display_name,kind,width,oneway,points:PackedVector2Array,grade}]
var buildings: Array = []  ## [{id,name,rings,height,style,seed,excluded}]
var landmarks: Array = []  ## [{...}]

# --- 地形 ------------------------------------------------------------------
var terrain_detail: Dictionary = {}
var landmark_detail: Dictionary = {}
var landmark_candidates: Dictionary = {}
var landmark_signage: Dictionary = {}
var coastal_infrastructure: Dictionary = {}
var facade_tiles: Dictionary = {}
var building_exclusions: Array = []
var metadata: Dictionary = {}

# --- 派生 ------------------------------------------------------------------
## id → building 下标
var building_index: Dictionary = {}
var road_index: Dictionary = {}
var _loaded := false


func is_loaded() -> bool:
	return _loaded


func load_core() -> void:
	if _loaded:
		return
	var t0 := Time.get_ticks_msec()

	metadata = DataLoader.json_dict(METADATA_JSON)

	# city.json（28.5MB）的 JSON.parse 会产生 ~300MB 瞬时 Variant 字典峰值，
	# 是启动内存峰值的最大单项。优先走二进制快照（_cache_load / _cache_save）：
	# 命中时完全不解析 JSON，瞬时峰值从 ~300MB 降到快照本身的几十 MB；
	# 未命中走原路径，转换完成后写快照，下次启动生效。
	var city_md5 := FileAccess.get_md5(DataLoader.path_for(CITY_JSON))
	var snap := _cache_load(city_md5)
	if snap.is_empty():
		var city = DataLoader.json(CITY_JSON)
		if city == null:
			push_error("[CityData] 无法加载 city.json，城市无法构建")
			return
		meta = city.get("meta", {})

		var ext: Array = meta.get("extent", [-6788.1, -2604.89, 6788.1, 2604.89])
		extent = Rect2(ext[0], ext[1], ext[2] - ext[0], ext[3] - ext[1])

		var sp: Dictionary = city.get("spawn", {})
		spawn_pos = Vector2(float(sp.get("x", 0.0)), float(sp.get("z", 0.0)))
		spawn_yaw = float(sp.get("yaw", 0.0))
		spawn_road = str(sp.get("road", ""))

		land_groups = city.get("land", [])
		land_rings = _flatten_ring_groups(land_groups)
		coast_rings = city.get("coast", [])
		green = city.get("green", [])
		water = city.get("water", [])
		landmarks = city.get("landmarks", [])

		_build_roads(city.get("roads", []))
		_build_buildings(city.get("buildings", []))

		# 快照必须写在路名生成 / 地标剔除 / 生活驿站并入**之前**：
		# 缓存内容是 city.json 的纯函数，下游派生步骤在命中路径上原样重跑。
		_cache_save(city_md5)
		# 原始 city.json 的嵌套字典结构已全部转成紧凑类型（roads/buildings →
		# PackedVector2Array）。Godot 的嵌套 Array/Dictionary 是 Variant 哈希表，
		# 内存开销是文件体积的 5~15 倍 —— roads/buildings 的原始 [x,y] 嵌套数组
		# 是常驻 RSS 的大头，转换完就地释放。land 分组原样保留在本对象
		# （land_groups，ObserverDestination 的「外环 + 洞」判定要用）。
		DataLoader.forget(CITY_JSON)
	else:
		_apply_snapshot(snap)

	# 原版 city-world.ts:250 在拿到 city.json 后**立刻**跑一遍路名生成，
	# HUD / 大地图 / 自动驾驶都吃这份 display_name。
	_assign_road_names()

	terrain_detail = DataLoader.json_dict(TERRAIN_DETAIL_JSON)
	landmark_detail = DataLoader.json_dict(LANDMARK_DETAIL_JSON)
	landmark_candidates = DataLoader.json_dict(LANDMARK_CANDIDATES_JSON)
	landmark_signage = DataLoader.json_dict(LANDMARK_SIGNAGE_JSON)
	coastal_infrastructure = DataLoader.json_dict(COASTAL_INFRA_JSON)
	facade_tiles = DataLoader.json_dict(FACADE_TILES_JSON)
	var be = DataLoader.json_dict(BUILDING_EXCLUSIONS_JSON)
	building_exclusions = be.get("excludedIds", [])

	_apply_landmark_exclusions()
	_append_life_sites()

	# 原始 city.json 的嵌套字典结构已全部转成紧凑类型（roads/buildings →
	# PackedVector2Array，land/coast/green/water/landmarks 由本对象按引用持有）。
	# Godot 的嵌套 Array/Dictionary 是 Variant 哈希表，内存开销是文件体积的
	# 5~15 倍 —— roads/buildings 的原始 [x,y] 嵌套数组是常驻 RSS 的大头，
	# 转换完就地释放。observer_destination 只取 land 分组，用 json_nocache
	# 直读（不入缓存，见 data_loader.gd），不会把整份结构塞回来。
	DataLoader.forget(CITY_JSON)

	_loaded = true
	var ms := Time.get_ticks_msec() - t0
	print("[CityData] 核心数据加载完成 %d ms：道路 %d / 建筑 %d / 绿地 %d / 水域 %d / 地标 %d"
		% [ms, roads.size(), buildings.size(), green.size(), water.size(), landmarks.size()])
	core_loaded.emit()


# --- city.json 二进制快照 ---------------------------------------------------
## 头部布局：4 字节魔数 + 4 字节未压缩长度（s32）+ 32 字节 city.json MD5
## （hex 文本），其后是 var_to_bytes 产物经 ZSTD 压缩的正文。
const CACHE_VERSION := 1
const CACHE_MAGIC := "CDC1"
const CACHE_PATH := "user://cache/city_core.bin"

## 校验并读取快照。返回空 Dictionary 表示未命中，调用方回退 JSON 路径。
## 失效条件（任一不满足即未命中，下次启动会用 JSON 路径重建快照）：
##   - city.json 的 MD5 与头部一致（数据变了自动失效）
##   - 快照格式版本一致（转换逻辑有改动时手工 bump CACHE_VERSION）
func _cache_load(city_md5: String) -> Dictionary:
	if city_md5.is_empty() or not FileAccess.file_exists(CACHE_PATH):
		return {}
	var f := FileAccess.open(CACHE_PATH, FileAccess.READ)
	if f == null:
		return {}
	var head := f.get_buffer(40)
	var body := f.get_buffer(f.get_length() - 40)
	f.close()
	if head.size() < 40 or head.slice(0, 4).get_string_from_ascii() != CACHE_MAGIC:
		return {}
	var raw_size := head.decode_s32(4)
	if raw_size <= 0 or raw_size > (1 << 30):
		return {}
	if head.slice(8, 40).get_string_from_ascii() != city_md5:
		return {}  # city.json 变了
	var bin := body.decompress(raw_size, FileAccess.COMPRESSION_ZSTD)
	if bin.is_empty():
		return {}
	var v = bytes_to_var(bin)
	if v is Dictionary and int(v.get("v", -1)) == CACHE_VERSION:
		print("[CityData] 命中二进制快照（%.1f MB），跳过 city.json 解析"
			% [body.size() / 1048576.0])
		return v
	return {}


## 把当前转换产物写成快照。内容必须是 city.json 的纯函数 —— 调用点在
## _assign_road_names / _apply_landmark_exclusions / _append_life_sites 之前。
## 写失败只告警不阻塞：下次启动走 JSON 路径照常能跑。
func _cache_save(city_md5: String) -> void:
	var t0 := Time.get_ticks_msec()
	var snap := {
		"v": CACHE_VERSION,
		"meta": meta,
		"extent": extent,
		"spawn_pos": spawn_pos,
		"spawn_yaw": spawn_yaw,
		"spawn_road": spawn_road,
		"land_groups": land_groups,
		"coast_rings": coast_rings,
		"green": green,
		"water": water,
		"landmarks": landmarks,
		"roads": roads,
		"buildings": buildings,
	}
	var bin := var_to_bytes(snap)
	var comp := bin.compress(FileAccess.COMPRESSION_ZSTD)
	if comp.is_empty():
		push_warning("[CityData] 快照压缩失败，跳过缓存写入")
		return
	# 头部 40 字节：魔数(0..4) + 未压缩长度 s32(4..8) + MD5 hex 文本(8..40)。
	# ⚠️ 不能先 resize(40) 再 append_array —— append 是追加到当前末尾，
	# MD5 会落到偏移 40 造成错位（正文起点也随之错位），必须逐段拼接。
	var size_bytes := PackedByteArray()
	size_bytes.resize(4)
	size_bytes.encode_s32(0, bin.size())
	var out := PackedByteArray()
	out.append_array(CACHE_MAGIC.to_ascii_buffer())
	out.append_array(size_bytes)
	out.append_array(city_md5.to_ascii_buffer())
	out.append_array(comp)
	var dir := DirAccess.open("user://")
	if dir != null:
		dir.make_dir_recursive("cache")
	var f := FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("[CityData] 快照写入失败（err %d）" % FileAccess.get_open_error())
		return
	f.store_buffer(out)
	f.close()
	print("[CityData] 已写二进制快照 %.1f MB（打包+压缩 %d ms，%s），下次启动免解析 city.json"
		% [out.size() / 1048576.0, Time.get_ticks_msec() - t0, CACHE_PATH])


## 把快照套回成员变量并重建派生索引。
## land_rings 由 land_groups 拍平派生（与未命中路径同一函数，保证一致）；
## building_index 不用管：_apply_landmark_exclusions 每次启动都会无条件重建。
func _apply_snapshot(snap: Dictionary) -> void:
	meta = snap.get("meta", {})
	extent = snap.get("extent", Rect2())
	spawn_pos = snap.get("spawn_pos", Vector2.ZERO)
	spawn_yaw = float(snap.get("spawn_yaw", 0.0))
	spawn_road = str(snap.get("spawn_road", ""))
	land_groups = snap.get("land_groups", [])
	land_rings = _flatten_ring_groups(land_groups)
	coast_rings = snap.get("coast_rings", [])
	green = snap.get("green", [])
	water = snap.get("water", [])
	landmarks = snap.get("landmarks", [])
	roads = snap.get("roads", [])
	buildings = snap.get("buildings", [])
	road_index.clear()
	for i in roads.size():
		road_index[roads[i]["id"]] = i


## 把生活驿站并入地标表（原版 main.ts boot 里对 world.data.landmarks 的 push）。
##
## 为什么必须并进来：HUD 的片区名取"离车最近的地标"的 area，而三个驿站写的是
## `生活驿站`。出生点离海湾生活驿站约 61m，是全场最近的地标 —— 不并进来，
## 左上角品牌副标题就永远是别处的片区名，对不上原版起始画面的
## 「深城纪 / 生活驿站 · 自由驾驶」。
##
## 字段照搬原版的 push：id 加 `life:` 前缀（不污染原版地标 id）、
## height 4.34、excludeRadius 0，并带上 arrival / yaw 供寻路与落车点使用。
func _append_life_sites() -> void:
	var d = DataLoader.json_dict("/city/life-sites.json")
	for s in d.get("sites", []):
		if s is not Dictionary:
			continue
		var site: Dictionary = s
		landmarks.append({
			"id": "life:" + str(site.get("id", "")),
			"name": str(site.get("name", "")),
			"x": float(site.get("x", 0.0)),
			"z": float(site.get("z", 0.0)),
			"height": 4.34,
			"area": "生活驿站",
			"excludeRadius": 0.0,
			"detailCollision": true,
			"arrival": site.get("arrival", null),
			"yaw": float(site.get("yaw", 0.0)),
			"heading": float(site.get("heading", 0.0)),
			"road": str(site.get("road", "")),
			"lifeSite": true,
		})
	_landmarks_cache_built = false
	_all_landmarks_cache = []


func _build_roads(raw: Array) -> void:
	roads = []
	roads.resize(raw.size())
	for i in raw.size():
		var r: Dictionary = raw[i]
		var pts := PackedVector2Array()
		var src: Array = r.get("points", [])
		pts.resize(src.size())
		for j in src.size():
			pts[j] = Vector2(float(src[j][0]), float(src[j][1]))
		roads[i] = {
			"id": str(r.get("id", "")),
			"name": str(r.get("name", "")),
			"display_name": str(r.get("displayName", "")),
			"kind": str(r.get("kind", "unclassified")),
			"width": float(r.get("width", 6.0)),
			"oneway": bool(r.get("oneway", false)),
			"points": pts,
			"grade": str(r.get("grade", "0")),
		}
		road_index[roads[i]["id"]] = i


## 未命名道路命名 —— 逐行对应原版 city-world.ts:250 的
## `await loadRoadDisplayNames(this.data)`。
##
## 上下文点目录（data/map-places.json）是可选件：原版在 fetch 失败时静默降级，
## 只是"附近"式命名会退化到"邻路附近 / 城市方位"这两级。
func _assign_road_names() -> void:
	var places: Array = DataLoader.json_dict("/map-places.json").get("places", [])
	var t0 := Time.get_ticks_msec()
	var res: Dictionary = ROAD_NAMES_SCRIPT.assign_display_names(roads, places, extent)
	print("[CityData] 路名生成 %d ms：未命名 %d 条获得显示名 / 共 %d 条（上下文点 %d）"
		% [Time.get_ticks_msec() - t0, res["contextual"], res["total"], places.size()])


func _build_buildings(raw: Array) -> void:
	buildings = []
	buildings.resize(raw.size())
	for i in raw.size():
		var b: Dictionary = raw[i]
		var rings: Array = []
		for ring in b.get("rings", []):
			rings.append(_ring_to_packed(ring))
		var id := str(b.get("id", ""))
		buildings[i] = {
			"id": id,
			"name": str(b.get("name", "")),
			"rings": rings,
			"height": float(b.get("height", 0.0)),
			"style": str(b.get("style", "residential")),
			"seed": int(b.get("seed", 0)),
			"excluded": false,
		}
		building_index[id] = i


func _ring_to_packed(ring: Array) -> PackedVector2Array:
	var pts := PackedVector2Array()
	pts.resize(ring.size())
	for j in ring.size():
		pts[j] = Vector2(float(ring[j][0]), float(ring[j][1]))
	return pts


## 把被地标替换掉的基础楼体从碰撞/招牌集合中剔除，并把地标自身的粗碰撞脚印补回去。
## 一比一对应原版 landmark-details.ts:57-59 的逻辑。
func _apply_landmark_exclusions() -> void:
	var replaced := {}

	for lm in landmark_detail.get("baseBuildingIds", []):
		replaced[str(lm)] = true
	for lm in landmark_candidates.get("baseBuildingIds", []):
		replaced[str(lm)] = true
	for lm in building_exclusions:
		replaced[str(lm)] = true

	var kept: Array = []
	for b in buildings:
		if replaced.has(b["id"]):
			b["excluded"] = true
		else:
			kept.append(b)
	var removed := buildings.size() - kept.size()
	buildings = kept
	# building_index 是在**过滤之前**按下标建的，过滤后下标整体前移，
	# 索引会指向错误的建筑（或越界）。必须重建。
	building_index.clear()
	for i in buildings.size():
		building_index[str(buildings[i]["id"])] = i

	# 细地标带 collisionFootprints，用 height=1 / style=landmark-detail 推回建筑集合
	for src in [landmark_detail, landmark_candidates]:
		for cf in src.get("collisionFootprints", []):
			var rings: Array = []
			for ring in cf.get("rings", []):
				rings.append(_ring_to_packed(ring))
			if rings.is_empty():
				continue
			buildings.append({
				"id": str(cf.get("id", "landmark-footprint")),
				"name": "",
				"rings": rings,
				"height": 1.0,
				"style": "landmark-detail",
				"seed": 0,
				"excluded": false,
			})
	if removed > 0:
		print("[CityData] 地标替换：剔除基础楼体 %d 个" % removed)


## 地标集合（重点地标 + 候选地标，去重）。
## 结果缓存：HUD 的片区名每 0.12s 调一次，每次重新去重构建得不偿失。
## （列表在 load_core / _apply_landmark_exclusions 里就定型了，运行时不再变化。）
var _all_landmarks_cache: Array = []
var _landmarks_cache_built := false


func all_landmarks() -> Array:
	if _landmarks_cache_built:
		return _all_landmarks_cache
	var out: Array = []
	var seen := {}
	for src in [landmark_detail, landmark_candidates]:
		for lm in src.get("landmarks", []):
			var id := str(lm.get("id", ""))
			if seen.has(id):
				continue
			seen[id] = true
			out.append(lm)
	for lm in landmarks:
		var id := str(lm.get("id", ""))
		if seen.has(id):
			continue
		seen[id] = true
		out.append(lm)
	_all_landmarks_cache = out
	_landmarks_cache_built = true
	return out


func landmark_by_id(id: String) -> Dictionary:
	for lm in all_landmarks():
		if str(lm.get("id", "")) == id:
			return lm
	return {}


# ---------------------------------------------------------------------------
# 导航图（navigation.json：nodes / edges）
# ---------------------------------------------------------------------------

var nav_nodes: PackedVector2Array = PackedVector2Array()
var nav_edges: Array = []  ## [[a, b], ...]

func load_navigation() -> void:
	if not nav_nodes.is_empty():
		return
	var d = DataLoader.json(NAVIGATION_JSON)
	if d == null:
		return
	var nodes: Array = d.get("nodes", [])
	nav_nodes.resize(nodes.size())
	for i in nodes.size():
		nav_nodes[i] = Vector2(float(nodes[i][0]), float(nodes[i][1]))
	var e: Array = d.get("edges", [])
	nav_edges.resize(e.size())
	for i in e.size():
		nav_edges[i] = Vector2i(int(e[i][0]), int(e[i][1]))
	# 42829 节点 / 47218 边的原始嵌套数组已转成 PackedVector2Array / Vector2i，
	# 全项目只有这里读 navigation.json（road_graph 用 nav_nodes / nav_edges），
	# 原始结构就地释放，不留双份。
	DataLoader.forget(NAVIGATION_JSON)
	print("[CityData] 导航图：%d 节点 / %d 边" % [nav_nodes.size(), nav_edges.size()])


# ---------------------------------------------------------------------------
# 各子系统的数据入口（懒加载）
# ---------------------------------------------------------------------------

func lamps() -> Array:
	## [x, z, dx, dz]
	return DataLoader.json_arr("/city/lamps.json")


func trees() -> Array:
	## [x, z, ?, ?]
	return DataLoader.json_arr("/city/trees.json")


func planting() -> Dictionary:
	return DataLoader.json_dict("/city/landscape/planting.json")


func canopy_trees() -> Dictionary:
	return DataLoader.json_dict("/city/landscape/canopy-trees.json")


func building_signs() -> Dictionary:
	return DataLoader.json_dict("/city/building-signs.json")


func pedestrian_paths() -> Array:
	## [ax, az, bx, bz]
	return DataLoader.json_arr("/city/pedestrian-paths.json")


func traffic_signals() -> Dictionary:
	return DataLoader.json_dict("/city/signals/traffic-signals.json")


func parked_ebikes() -> Dictionary:
	return DataLoader.json_dict("/city/ebikes/parked.json")


## ebikes/manifest.json：调色板与骑手服/头盔配色（原版 CityEbikes.init 从这里读）
func ebike_manifest() -> Dictionary:
	return DataLoader.json_dict("/city/ebikes/manifest.json")


func puddles_layout() -> Dictionary:
	return DataLoader.json_dict("/city/rain/puddles-layout.json")


func life_sites() -> Dictionary:
	return DataLoader.json_dict("/city/life-sites.json")


func life_hub() -> Dictionary:
	return DataLoader.json_dict("/city/life-hub.json")


func street_manifest() -> Dictionary:
	return DataLoader.json_dict("/city/street/manifest.json")


func vehicle_manifest() -> Dictionary:
	return DataLoader.json_dict("/city/vehicle-manifest.json")


func floatplane_manifest() -> Dictionary:
	return DataLoader.json_dict("/city/floatplane-manifest.json")


func cafe_manifest() -> Dictionary:
	return DataLoader.json_dict("/city/bamboo-cafe/manifest.json")


func ground_relief_manifest() -> Dictionary:
	return DataLoader.json_dict("/city/ground-relief/manifest.json")


func mountain_manifest() -> Dictionary:
	return DataLoader.json_dict("/city/mountain-relief/manifest.json")


func mountain_near_manifest() -> Dictionary:
	return DataLoader.json_dict("/city/mountain-relief/near-manifest.json")


func far_shore() -> Dictionary:
	return DataLoader.json_dict("/city/coastal/far-shore.json")


func grassland_materials() -> Dictionary:
	return DataLoader.json_dict("/city/grassland-v2/materials.json")


func meadow() -> Dictionary:
	return DataLoader.json_dict("/city/grassland-v2/meadow.json")


func canopy_manifest() -> Dictionary:
	return DataLoader.json_dict("/city/landscape/canopy/manifest.json")


func landscape_manifest() -> Dictionary:
	return DataLoader.json_dict("/city/landscape/manifest.json")


## 道路查询：返回闭合到 pos 的最近路段信息（不建索引，供一次性使用）
func nearest_road(pos: Vector2) -> Dictionary:
	var best := {}
	var best_d := INF
	for r in roads:
		var pts: PackedVector2Array = r["points"]
		for i in range(1, pts.size()):
			var p := _closest_on_segment(pos, pts[i - 1], pts[i])
			if p["d"] < best_d:
				best_d = p["d"]
				best = {"road": r, "point": p["point"], "d": p["d"], "yaw": p["yaw"]}
	return best


## 把「陆地分组」拍平成环列表。
## city.json 里 `land` 的结构是 `[ [ ring, ... ], ... ]`（陆地分组，每组含若干环），
## 而 `coast` 是 `[ ring, ... ]`。不拍平的话，碰撞里的
## `if ring.size() >= 3` 会把「分组」当成环判掉（分组只有 1 个元素），
## 结果就是陆地环为 0 —— 所有点都不在陆地上，一开车就被判阻挡。
static func _flatten_ring_groups(groups: Array) -> Array:
	var out: Array = []
	for g in groups:
		if g is Array and g.size() > 0 and g[0] is Array \
				and g[0].size() > 0 and g[0][0] is Array:
			out.append_array(g)      # 是分组：内层每个元素才是一个环
		else:
			out.append(g)            # 直接就是环
	return out



static func _closest_on_segment(p: Vector2, a: Vector2, b: Vector2) -> Dictionary:
	var ab := b - a
	var len2 := ab.length_squared()
	var t := 0.0
	if len2 > 0.0:
		t = clamp((p - a).dot(ab) / len2, 0.0, 1.0)
	var q := a + ab * t
	return {"point": q, "d": p.distance_to(q), "yaw": atan2(ab.x, ab.y)}


# ---------------------------------------------------------------------------
# 诊断
# ---------------------------------------------------------------------------

func stats() -> Dictionary:
	return {
		"roads": roads.size(),
		"buildings": buildings.size(),
		"green": green.size(),
		"water": water.size(),
		"landmarks": all_landmarks().size(),
		"landRings": land_rings.size(),
		"coastRings": coast_rings.size(),
		"navNodes": nav_nodes.size(),
		"facadeTiles": (facade_tiles.get("tiles", []) as Array).size(),
		"extent": [extent.position.x, extent.position.y, extent.end.x, extent.end.y],
		"loader": DataLoader.cache_stats(),
	}
