extends Node3D
class_name SignSystem
##
## 建筑招牌 —— 对应原版 src/city-building-signs.ts（3077 条招牌）+ landmark-signage.ts。
##
## 原版做法：把选中招牌的文字渲染进一张 2048×1024 的动态图集（8×8 格），
## 合成单个 mesh，每条招牌一个 quad，顶点按 position/normal/tangent/width/height 摆放。
## 选择规则：距离 <1100m、朝向 back 面系数 facing ≥ .16、在视锥内、字面像素 ≥ 2.4，
## 按 letterPixels*(.38+.62*facing)/(1+.1*r²) 取前 64 条。
##
## Godot 对应：用 Label3D 池（≤64 个）直接显示文字，省掉自建图集与字体光栅化，
## 视觉结果等价（贴面朝向的可读文字），且中文排版质量更好。
## 中文字形依赖字体：这里用 SystemFont 依次尝试常见中文字体。

const MAX_SIGNS := 64
const MAX_DISTANCE := 1100.0
const MIN_FACING := 0.16
const MIN_LETTER_PIXELS := 2.4
## 原版图集单元格 256×128，字号按此比例
const CELL_ASPECT := 2.0

var world: CityWorld
var enabled := true

var _signs: Array = []
## 招牌空间索引：3077 条每 0.25s 全量扫太重
var _sign_points := PackedVector2Array()
var _sign_grid: PointGrid
var _pool: Array = []
var _font: Font
var _timer := 0.0
## 每个 Label3D 槽位上次写入的文字：Label3D.text 赋**相同的值**也会触发
## 字形重排与纹理上传（64 个 × 4Hz 就是持续的隐性开销），必须短路。
var _pool_texts: Array = []
## 相机几乎没动时跳过整轮选择（招牌选择依赖相机位置与朝向，25m 内结果基本不变）
const UPDATE_MOVE := 25.0
var _last_cam := Vector3(INF, INF, INF)
var _last_night := false


func setup(p_world: CityWorld) -> void:
	world = p_world
	_make_font()
	var data: Dictionary = CityData.building_signs()
	var raw: Array = data.get("signs", [])
	_signs.clear()
	for s in raw:
		if not (s is Dictionary):
			continue
		var pos: Array = s.get("position", [])
		if pos.size() < 3:
			continue
		_signs.append(s)
	# 网格索引：3077 条每 0.25s 全量扫太重（数据坐标 east/north 作平面）
	_sign_points.resize(_signs.size())
	for i in _signs.size():
		var pos2: Array = _signs[i]["position"]
		_sign_points[i] = Vector2(float(pos2[0]), float(pos2[2]))
	_sign_grid = PointGrid.new(256.0)
	_sign_grid.build(_sign_points)
	_make_pool()
	_build_direction_signs()
	print("[SignSystem] 招牌数据 %d 条，显示池 %d" % [_signs.size(), _pool.size()])
	update_signs(world.focus)


## ── 指路牌（2026-10-24 补齐；2026-11-03 加杆 + 背板 + 路肩偏移）─────
## 原版 city-world.ts setupSigns()：spawn ±650/700m 内的 primary/trunk 主干道
## （路名含「辅」跳过、points ≥4、count++>8 → 最多 8 块），8×2m 单面片
## 自发光不受光照（夜里也清晰可读），按行进方向选 sign-east/west.jpg。
## 贴面只朝 a→b 行进方向 —— 背面不渲染（原版注释：背面会镜像文字）。
## 原版牌子无杆、悬在 6.8m —— 本端口补齐三件事：
##   1. 挂点原是道路中线首点（road.points[0]），直接立杆会插进车道，
##      故沿迎面来车的右手侧偏移 half_width+0.8m 到路肩；
##   2. 补 5.9m 立柱（顶入牌底 0.1m），受光照、投影；
##   3. 补灰色铝背板（不贴图、unshaded）—— 不用 CULL_DISABLED 开双面，
##      因为同一张贴图背面会看到镜像文字，背板则背面干净。
const DIRECTION_SIGN_MAX := 8
## 杆顶 5.9m，牌面中心 6.8m、高 2m（底缘 5.8m）→ 杆顶嵌入牌底 0.1m
const SIGN_POLE_HEIGHT := 5.9
## 背板相对牌面沿 −法线的后移量，避免共面深度闪烁
const SIGN_BACK_GAP := 0.02

func _build_direction_signs() -> void:
	var spawn: Vector2 = CityData.spawn_pos
	var placed := 0
	var tex_cache := {}
	# 牌面 / 背板 / 立柱的网格与材质只建一份，每块牌子 3 个 MeshInstance3D 共享
	var quad := QuadMesh.new()
	quad.size = Vector2(8.0, 2.0)
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.12
	pole_mesh.bottom_radius = 0.16
	pole_mesh.height = SIGN_POLE_HEIGHT
	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.42, 0.44, 0.47)
	pole_mat.metallic = 0.6
	pole_mat.roughness = 0.45
	# 背板 unshaded 与牌面亮度语义一致（牌面 albedo 0.82，背板压暗一档）
	var back_mat := StandardMaterial3D.new()
	back_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	back_mat.albedo_color = Color(0.5, 0.52, 0.55)
	for road in CityData.roads:
		if placed >= DIRECTION_SIGN_MAX:
			break
		var pts: PackedVector2Array = road.get("points", PackedVector2Array())
		if pts.size() < 4:
			continue
		var kind := str(road.get("kind", ""))
		if kind != "primary" and kind != "trunk":
			continue
		if "辅" in str(road.get("name", "")):
			continue
		var a := pts[0]
		var b := pts[1]
		if absf(a.x - spawn.x) > 650.0 or absf(a.y - spawn.y) > 700.0:
			continue
		placed += 1
		var dir_data := b - a
		var tex_name := "west" if b.x < a.x else "east"
		var tex_path := "res://data/city/textures/sign-%s.jpg" % tex_name
		var tex: Texture2D = null
		if tex_cache.has(tex_name):
			tex = tex_cache[tex_name]
		elif ResourceLoader.exists(tex_path):
			tex = load(tex_path)
			tex_cache[tex_name] = tex
		if tex == null:
			push_warning("[SignSystem] 缺少指路牌贴图 %s" % tex_path)
			continue
		# 迎面来车沿 -dir 行驶，其右手侧在数据坐标里 = (-dn, dx)（右手通行）
		var half_w := float(road.get("width", 16.0)) * 0.5
		var shoulder := Vector2(-dir_data.y, dir_data.x).normalized() * (half_w + 0.8)
		var anchor := a + shoulder
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = tex
		# 原版：disableLighting + emissiveColor .82 → 等价 unshaded × 0.82
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.82, 0.82, 0.82)
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		var mi := MeshInstance3D.new()
		mi.name = "direction-sign"
		mi.mesh = quad
		mi.material_override = mat
		mi.position = CoordinateUtil.to_world(anchor.x, anchor.y, 6.8)
		# 原版 rotation.y = atan2(dx, dz) + π（Babylon z=北、平面朝 −Z，
		# 法线 = a→b 行进方向）；Godot QuadMesh 面朝 +Z：
		# 法线 = (sin φ, cos φ)，令其等于 (dx, −dz)̂ → φ = atan2(dx, −dz)
		var phi := atan2(dir_data.x, -dir_data.y)
		mi.rotation.y = phi
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		# 背板：同尺寸灰板，法线反向、沿 −法线后退 2cm —— 背面看到的是干净金属板
		var back := MeshInstance3D.new()
		back.name = "direction-sign-back"
		back.mesh = quad
		back.material_override = back_mat
		var n := Vector3(sin(phi), 0.0, cos(phi))
		back.position = mi.position - n * SIGN_BACK_GAP
		back.rotation.y = phi + PI
		back.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(back)
		# 立柱：立在路肩点上，顶入牌底 0.1m；受光照、投影（牌面与背板不投影）
		var pole := MeshInstance3D.new()
		pole.name = "direction-sign-pole"
		pole.mesh = pole_mesh
		pole.material_override = pole_mat
		pole.position = CoordinateUtil.to_world(anchor.x, anchor.y, SIGN_POLE_HEIGHT * 0.5)
		add_child(pole)
	print("[SignSystem] 指路牌 %d 块" % placed)


func _make_font() -> void:
	var sf := SystemFont.new()
	# 依次尝试常见简体中文字体（Windows / macOS / 常见 Linux 发行版）
	sf.font_names = PackedStringArray([
		"Microsoft YaHei", "微软雅黑", "SimHei", "黑体",
		"PingFang SC", "苹方", "Noto Sans CJK SC", "Source Han Sans SC",
		"WenQuanYi Micro Hei", "Arial Unicode MS", "sans-serif",
	])
	sf.allow_system_fallback = true
	_font = sf


func _make_pool() -> void:
	for i in MAX_SIGNS:
		var l := Label3D.new()
		l.name = "sign-%d" % i
		l.font = _font
		l.font_size = 64
		l.pixel_size = 0.012
		l.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		l.no_depth_test = false
		# 原版片元 `if(dot(view,vNormal)<=0.)discard;` —— 文字只从正面可见，
		# 背面（墙另一侧）不可见。double_sided=true 会从墙背面透出镜像文字。
		l.double_sided = false
		l.shaded = false
		l.modulate = Color(1.0, 0.96, 0.90)
		l.outline_size = 6
		l.outline_modulate = Color(0.05, 0.05, 0.06, 0.85)
		l.alpha_cut = Label3D.ALPHA_CUT_DISCARD
		l.visible = false
		l.render_priority = 1
		add_child(l)
		_pool.append(l)
		_pool_texts.append("")


## 视线朝向系数（原版 facing）：招牌法线朝向相机的程度，0–1
func _facing(normal: Vector3, cam_pos: Vector3, sign_pos: Vector3) -> float:
	var to_cam := (cam_pos - sign_pos)
	if to_cam.length_squared() < 0.0001:
		return 0.0
	to_cam = to_cam.normalized()
	# 数据法线 (east, up, north) → 世界 (east, up, -north)
	var n := Vector3(normal.x, normal.y, -normal.z).normalized()
	return maxf(0.0, n.dot(to_cam))


func update_signs(cam_pos: Vector3) -> void:
	if not enabled:
		return
	# 相机几乎没动且昼夜模式没变 → 选择结果基本不变，整轮跳过
	# （签名选择依赖相机位置，驱动时 25m 也就 0.5~1s 的粒度，视觉无感）
	var night := GameState.light_mode == GameContent.LightMode.NIGHT
	if cam_pos.distance_to(_last_cam) < UPDATE_MOVE and night == _last_night:
		return
	_last_cam = cam_pos
	_last_night = night
	# 网格索引：只取 MAX_DISTANCE 内的招牌，不再全量扫 3077 条
	var center := Vector2(cam_pos.x, -cam_pos.z)
	var near_ids: Array = []
	if _sign_grid != null:
		near_ids = _sign_grid.query_radius(center, MAX_DISTANCE)

	var selected: Array = []
	for idx in near_ids:
		var s: Dictionary = _signs[idx]
		var pos: Array = s["position"]
		var p := CoordinateUtil.to_world(float(pos[0]), float(pos[2]), float(pos[1]))
		var d := p.distance_to(cam_pos)
		if d > MAX_DISTANCE:
			continue
		var nrm: Array = s.get("normal", [0.0, 0.0, 1.0])
		var facing := _facing(Vector3(float(nrm[0]), float(nrm[1]), float(nrm[2])), cam_pos, p)
		if facing < MIN_FACING:
			continue
		var text := str(s.get("text", ""))
		if text.is_empty():
			continue
		var width := float(s.get("width", 6.0))
		# 字面像素：招牌宽度 / 字数 * 屏幕密度近似
		var letter_pixels := width * 20.0 / maxf(1.0, float(text.length())) * facing
		if letter_pixels < MIN_LETTER_PIXELS:
			continue
		var score := letter_pixels * (0.38 + 0.62 * facing) / (1.0 + 0.1 * d * d / 10000.0)
		selected.append({"score": score, "s": s, "pos": p, "d": d})

	selected.sort_custom(func(a, b): return a["score"] > b["score"])

	for i in _pool.size():
		var l: Label3D = _pool[i]
		if i >= selected.size():
			l.visible = false
			continue
		var e: Dictionary = selected[i]
		var s: Dictionary = e["s"]
		var text := str(s.get("text", ""))
		# 相同值短路：赋同样的 text 也会触发字形重排 + 纹理上传
		if str(_pool_texts[i]) != text:
			l.text = text
			_pool_texts[i] = text
		l.visible = true
		var pos: Array = s["position"]
		var nrm: Array = s.get("normal", [0.0, 0.0, 1.0])
		var tan: Array = s.get("tangent", [1.0, 0.0, 0.0])
		var width := float(s.get("width", 6.0))
		var height := float(s.get("height", width / CELL_ASPECT))
		var n := Vector3(float(nrm[0]), float(nrm[1]), -float(nrm[2])).normalized()
		var t := Vector3(float(tan[0]), float(tan[1]), -float(tan[2])).normalized()
		# 文字平面：法线朝外、宽度沿 tangent、竖直方向由 n×t 得到
		var up := n.cross(t)
		if up.y < 0.0:
			# ⚠️ 翻 up 的同时必须把 t 一起翻：否则 t×up = -n，基变成左手系
			# （det<0），Label3D 的文字整体镜像 —— 就是"墙上的字反了"。
			# 原版 city-building-signs.ts 注释同款问题："exterior-facing tangent
			# order projects right-to-left: reverse U so Chinese reads normally"。
			up = -up
			t = -t
		# 不能叫 basis —— Node3D 已有 basis 属性
		var sign_basis := Basis(t, up, n)
		l.global_transform = Transform3D(sign_basis,
			CoordinateUtil.to_world(float(pos[0]), float(pos[2]), float(pos[1])))
		l.pixel_size = clampf(height / 64.0, 0.004, 0.06)
		# 夜间提亮（原版 night 亮度 0.72 → 1.9）；night 在函数开头已判定
		l.modulate = Color(1.0, 0.97, 0.90) * (1.35 if night else 1.0)


func update_system(delta: float, focus: Vector3) -> void:
	var __hitch_t0 := Time.get_ticks_msec()
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = 0.25
	update_signs(focus)

	var __hitch_ms := Time.get_ticks_msec() - __hitch_t0
	if __hitch_ms > 15:
		print("[HITCH] %s 本帧 %d ms" % ["Signs", __hitch_ms])

func diagnostics() -> Dictionary:
	var shown := 0
	for l in _pool:
		if l.visible:
			shown += 1
	return {"data": _signs.size(), "pool": _pool.size(), "shown": shown}
