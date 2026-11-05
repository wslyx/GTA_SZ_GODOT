extends RefCounted
class_name MapHealth
##
## 全图数据体检（方案 B）—— 离线比对「物理高度场」与「视觉地形」一致性。
##
## 由 main_game 以 CLI 参数 --map-health 触发（游戏内运行，复用真实系统：
## world.height_field / 已加载的 terrain/roads/bridges/relief 节点）。
##
## 采样点：
##   A. 全部路网节点（nav_nodes，车实际会开到的地方）
##   B. 全城网格中 |height_field| > 0.8m 的点（山地/公园缓坡/桥面）
##
## 判定（visual = 该点正上方最高视觉地面三角形；hf = HeightField.height_at）：
##   hf - visual > 1m   → float  浮空（车悬空，症状即玩家截图）
##   hf - visual < -1m  → sink   下陷（车扎进地里）
##   无视觉地面且 |hf| > 0.5 → hole 空洞
##
## 输出：artifacts/map_health/mismatches.csv + 返回汇总 Dictionary

const GROUND_MATS := ["asphalt", "pavement", "land", "park", "concrete", "road", "grass"]
const BIN := 64.0
const THRESHOLD := 1.0

## ---- 屋顶/高架结构剔除（2026-11-05，跑图体检归因）----
## 地标建筑的混凝土/石材屋面（会展中心 13.2m 顶板、书城 7m 台地）材质名
## 是 "concrete"/"stone"，命中 GROUND_MATS —— 被当成"地面"烘进修正网格，
## 楼旁 8m 格带内的路面物理被抬到楼顶（体检 12m/4.5m 浮空的根因）。
## 判据：三角形平均高度比**原生层叠地面**（lianhua+mountain+relief，不含
## 修正网格与桥）高出 ROOF_ABOVE 以上、且原生地面本身在低地（< NATIVE_MAX，
## 山区原生与视觉天生差 10m+，不能用这条规则误杀陡坡）→ 不是可行驶地面。
const ROOF_ABOVE := 5.0
const ROOF_NATIVE_MAX := 10.0

## (east, north) -> 原生层叠高度。collect_visual_ground 时从 world 注入。
var _native_hint: Callable = Callable()

var _tris := PackedFloat32Array()   ## 9 floats/tri：ax,az,ay  bx,bz,by  cx,cz,cy（数据坐标 east/north/up）
var _bins: Dictionary = {}          ## Vector2i → PackedInt32Array
var _rows: Array = []
var _stat := {"float": 0, "sink": 0, "hole": 0, "ok": 0}


func run(world: CityWorld, quick: bool) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var hf = world.height_field

	# ---- 1) 收集视觉地面三角形（世界坐标 → 数据坐标，north = -z）----
	collect_visual_ground(world, false)
	print("[MapHealth] 视觉地面三角形 %d / 格桶 %d" % [_tris.size() / 9, _bins.size()])

	# ---- 2) 采样点 ----
	var pts := PackedVector2Array()   ## 数据坐标 (east, north)
	CityData.load_navigation()
	var nav: PackedVector2Array = CityData.nav_nodes
	var nstep := 4 if quick else 1
	for i in range(0, nav.size(), nstep):
		pts.append(nav[i])
	var gstep := 60 if quick else 30
	var hills := 0
	for ex in range(-6780, 6781, gstep):
		for nz in range(-2600, 2601, gstep):
			var h: float = hf.height_at(float(ex), float(nz))
			if absf(h) > 0.8:
				pts.append(Vector2(float(ex), float(nz)))
				hills += 1
	print("[MapHealth] 采样点 %d（路网 %d + 起伏区 %d）" % [pts.size(), nav.size() / nstep, hills])

	# ---- 3) 逐点比对 ----
	for i in pts.size():
		var p := pts[i]
		var hv: float = hf.height_at(p.x, p.y)
		var vv := _visual_height(p.x, p.y)
		if is_nan(vv):
			if absf(hv) > 0.5:
				_stat["hole"] += 1
				_rows.append("hole,%.1f,%.1f,%.2f,,," % [p.x, p.y, hv])
			continue
		var diff := hv - vv
		if diff > THRESHOLD:
			_stat["float"] += 1
			_rows.append("float,%.1f,%.1f,%.2f,%.2f,%.2f" % [p.x, p.y, hv, vv, diff])
		elif diff < -THRESHOLD:
			_stat["sink"] += 1
			_rows.append("sink,%.1f,%.1f,%.2f,%.2f,%.2f" % [p.x, p.y, hv, vv, diff])
		else:
			_stat["ok"] += 1
		if i % 20000 == 0 and i > 0:
			print("[MapHealth] %d/%d …" % [i, pts.size()])

	# ---- 4) 报告 ----
	var dir := DirAccess.open("res://")
	if dir != null and not dir.dir_exists("artifacts/map_health"):
		dir.make_dir_recursive("artifacts/map_health")
	var out := FileAccess.open("res://artifacts/map_health/mismatches.csv", FileAccess.WRITE)
	out.store_line("kind,east,north,hf_y,visual_y,diff")
	for r in _rows:
		out.store_line(str(r))
	out.close()
	print("[MapHealth] 完成 %d ms：ok=%d 浮空=%d 下陷=%d 空洞=%d" % [
		Time.get_ticks_msec() - t0, _stat["ok"], _stat["float"], _stat["sink"], _stat["hole"]])
	return {"stat": _stat.duplicate(), "rows": _rows, "csv": "artifacts/map_health/mismatches.csv"}


# ---------------------------------------------------------------------------
# 视觉三角形收集（世界坐标 → 数据坐标 north = -z）
# ---------------------------------------------------------------------------

## 收集全城视觉地面三角形。供本类 run() 与 bake_height_fix（B-2 烘焙）共用。
##
## for_height_fix=true（烘焙修正高度网格用）时跳过两类：
##   · coastal_bridge_* 桥面 —— 桥下要通行，max 栅格化会把桥面高度糊到桥下水域；
##     桥面高度仍由 HeightField 原生 bridge_lift 层负责（onRoad 闸门）；
##   · rain_* 雨面覆盖层 —— 不是地面。
func collect_visual_ground(world: CityWorld, for_height_fix := false) -> void:
	# 注入原生高度提示（屋顶剔除用）。height_field 的原生层是公开方法，
	# 这里故意**不含**修正网格与 bridge_lift —— 屋顶判据要的是"没有人工
	# 结构时大地在哪"。
	if world != null and world.height_field != null:
		var hf = world.height_field
		_native_hint = func(e: float, n: float) -> float:
			return hf.lianhua_height(e, n) + hf.mountain_delta(e, n) + hf.relief_height(e, n)
	else:
		_native_hint = Callable()
	# 地标/楼体/区块：屋顶剔除（ROOF_ABOVE）。会展中心 13.2m 混凝土顶板、
	# 书城 7m 石材台地、普通楼体 block_*_concrete 的楼顶（探测命中
	# block_-3_-1_concrete 等在 59.6m / 215.6m）材质名都命中 GROUND_MATS，
	# 曾把楼旁路面/路网的物理抬到楼顶，也让体检把楼顶当"视觉地面"报下陷。
	# 这里的高度判据只用于人工结构根 ——
	# ⚠️ 山体瓦片不能用：原生山体网格在西部有整片 0 的洞（实测 (-5442,-1846)
	# 视觉山 81.6m / 原生 0m），按"高出原生即剔除"会把真山删掉。
	var roots: Array = [world.terrain_root, world.roads_root]
	for r in roots:
		if r != null:
			_collect(r, false, for_height_fix)
	for r in [world.buildings_root, world.chunks_root, world.landmarks_root]:
		if r != null:
			_collect(r, false, for_height_fix, true)
	# 公园缓坡补面（distant_system 程序化生成的 ground-relief 节点）+
	# 远山 / 近山（mountain-relief 瓦片）—— 都是 SurfaceTool 网格**无材质**，
	# 走 all_materials 路径；height_field 的 relief/mountain delta 以它们为视觉对应层
	if world.distant != null:
		if world.distant.relief_node != null:
			_collect(world.distant.relief_node, true, false)
		for mn in world.distant.mountain_nodes:
			if mn is Node:
				_collect(mn, true, false)


func _collect(root: Node, all_materials := false, skip_bridge := false,
		roof_filter := false) -> void:
	var n := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		if nd is MeshInstance3D:
			var mi := nd as MeshInstance3D
			if mi.mesh != null:
				# ---- 植被排除（2026-11-03，修复记录 五十二）----
				# 树冠/灌木不是可行驶地面。此前 detail_lianhua_leaf（莲花山树冠
				# 簇）被收进"视觉地面"，height-fix 网格在灌木区取到树冠高度
				# （实测 (1665,1730) 地面 22.9 / 树冠 31.8 / fix=27.73 的双线性
				# 混合值）—— 车在山上灌木区浮到半空"开在隐形树顶上"。
				# 材质名过滤拦不住（GlbLoader 重挂材质后 resource_name 可能变），
				# 这里按网格节点名拉黑，覆盖所有植被来源。
				var lname := String(mi.name).to_lower()
				if lname.contains("leaf") or lname.contains("canopy") \
						or lname.contains("tree") or lname.contains("bush") \
						or lname.contains("meadow") or lname.contains("grass_instance"):
					continue
				if skip_bridge and (mi.name.begins_with("coastal_bridge_")
						or mi.name.begins_with("rain")):
					continue
				var xform := mi.global_transform
				for s in mi.mesh.get_surface_count():
					var m := mi.mesh.surface_get_material(s)
					var mn := str(m.resource_name).to_lower() if m != null else ""
					var ground := all_materials
					if not ground:
						for g in GROUND_MATS:
							if mn.begins_with(g):
								ground = true
								break
					if not ground:
						continue
				var faces := mi.mesh.get_faces()
				var i := 0
				while i + 2 < faces.size():
					var a := xform * faces[i]
					var b := xform * faces[i + 1]
					var c := xform * faces[i + 2]
					if roof_filter and _is_roof_triangle(a, b, c):
						i += 3
						continue
					_add_tri(a.x, -a.z, a.y, b.x, -b.z, b.y, c.x, -c.z, c.y)
					n += 1
					i += 3
		for ch in nd.get_children():
			stack.append(ch)
	if n > 0:
		print("[MapHealth]   %s → %d 地面三角形" % [root.name, n])


# ---------------------------------------------------------------------------
# 屋顶/高架结构剔除
# ---------------------------------------------------------------------------

## 三角形平均高度比原生地面高出 ROOF_ABOVE 且原生在低地 → 屋顶/高架顶板，
## 不是可行驶地面（烘焙与体检口径一致）。原生层缺失（无提示）时不剔除。
func _is_roof_triangle(a: Vector3, b: Vector3, c: Vector3) -> bool:
	if not _native_hint.is_valid():
		return false
	var avg_y := (a.y + b.y + c.y) / 3.0
	var e := (a.x + b.x + c.x) / 3.0
	var n := -(a.z + b.z + c.z) / 3.0
	var native: float = _native_hint.call(e, n)
	return native < ROOF_NATIVE_MAX and avg_y - native > ROOF_ABOVE


# ---------------------------------------------------------------------------
# 三角形存储 + 64m 格桶 + 点查询
# ---------------------------------------------------------------------------

func _add_tri(ax: float, az: float, ay: float, bx: float, bz: float, by: float,
		cx: float, cz: float, cy: float) -> void:
	var idx := _tris.size() / 9
	_tris.append(ax); _tris.append(az); _tris.append(ay)
	_tris.append(bx); _tris.append(bz); _tris.append(by)
	_tris.append(cx); _tris.append(cz); _tris.append(cy)
	var minx := minf(ax, minf(bx, cx))
	var maxx := maxf(ax, maxf(bx, cx))
	var minz := minf(az, minf(bz, cz))
	var maxz := maxf(az, maxf(bz, cz))
	var x0 := int(floor(minx / BIN))
	var x1 := int(floor(maxx / BIN))
	var z0 := int(floor(minz / BIN))
	var z1 := int(floor(maxz / BIN))
	for gx in range(x0, x1 + 1):
		for gz in range(z0, z1 + 1):
			var k := Vector2i(gx, gz)
			var arr: PackedInt32Array = _bins.get(k, PackedInt32Array())
			arr.append(idx)
			_bins[k] = arr


func _visual_height(east: float, north: float) -> float:
	var best := NAN
	var gx := int(floor(east / BIN))
	var gz := int(floor(north / BIN))
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var arr: PackedInt32Array = _bins.get(Vector2i(gx + dx, gz + dz), PackedInt32Array())
			for ti in arr:
				var base := ti * 9
				var y := _tri_height(east, north,
					_tris[base], _tris[base + 1], _tris[base + 2],
					_tris[base + 3], _tris[base + 4], _tris[base + 5],
					_tris[base + 6], _tris[base + 7], _tris[base + 8])
				if not is_nan(y) and (is_nan(best) or y > best):
					best = y
	return best


## 2D 重心测试（数据平面 east/north），点在三角形内返回插值高度，否则 NAN
func _tri_height(px: float, pz: float, ax: float, az: float, ay: float,
		bx: float, bz: float, by: float, cx: float, cz: float, cy: float) -> float:
	var d := (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
	if absf(d) < 1e-9:
		return NAN
	var l1 := ((bz - cz) * (px - cx) + (cx - bx) * (pz - cz)) / d
	var l2 := ((cz - az) * (px - cx) + (ax - cx) * (pz - cz)) / d
	var l3 := 1.0 - l1 - l2
	if l1 < -0.001 or l2 < -0.001 or l3 < -0.001:
		return NAN
	return l1 * ay + l2 * by + l3 * cy
