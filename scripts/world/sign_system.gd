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
	print("[SignSystem] 招牌数据 %d 条，显示池 %d" % [_signs.size(), _pool.size()])
	update_signs(world.focus)


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
		l.double_sided = true
		l.shaded = false
		l.modulate = Color(1.0, 0.96, 0.90)
		l.outline_size = 6
		l.outline_modulate = Color(0.05, 0.05, 0.06, 0.85)
		l.alpha_cut = Label3D.ALPHA_CUT_DISCARD
		l.visible = false
		l.render_priority = 1
		add_child(l)
		_pool.append(l)


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
		l.text = str(s.get("text", ""))
		l.visible = true
		var pos: Array = s["position"]
		var nrm: Array = s.get("normal", [0.0, 0.0, 1.0])
		var tan: Array = s.get("tangent", [1.0, 0.0, 0.0])
		var width := float(s.get("width", 6.0))
		var height := float(s.get("height", width / CELL_ASPECT))
		var n := Vector3(float(nrm[0]), float(nrm[1]), -float(nrm[2])).normalized()
		var t := Vector3(float(tan[0]), float(tan[1]), -float(tan[2])).normalized()
		# 文字平面：法线朝外、宽度沿 tangent、竖直方向由 n×t 得到
		var up := n.cross(t).normalized()
		if up.y < 0.0:
			up = -up
		# 不能叫 basis —— Node3D 已有 basis 属性
		var sign_basis := Basis(t, up, n)
		l.global_transform = Transform3D(sign_basis,
			CoordinateUtil.to_world(float(pos[0]), float(pos[2]), float(pos[1])))
		l.pixel_size = clampf(height / 64.0, 0.004, 0.06)
		# 夜间提亮（原版 night 亮度 0.72 → 1.9）
		var night := GameState.light_mode == GameContent.LightMode.NIGHT
		l.modulate = Color(1.0, 0.97, 0.90) * (1.35 if night else 1.0)


func update_system(delta: float, focus: Vector3) -> void:
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = 0.25
	update_signs(focus)


func diagnostics() -> Dictionary:
	var shown := 0
	for l in _pool:
		if l.visible:
			shown += 1
	return {"data": _signs.size(), "pool": _pool.size(), "shown": shown}
