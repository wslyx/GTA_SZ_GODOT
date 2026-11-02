extends RefCounted
##
## 武器系统 v1 —— 纯数据 + 弹道判定，无场景节点（GTA化 §2.3）。
##
## 由 main_game 持有并驱动：
##   - 输入（开火/换枪/装填）在 main_game，本类只管状态机与弹道；
##   - 弹道：数据坐标 2D 射线，步进查 CityCollision.blocked（建筑挡弹）；
##     行人命中走 pedestrian_system.shoot_hit()（段-点测试，0.7m 半径）；
##     车流/警车 = 射线 1.6m 内扫过（v1 无车辆伤害，只有命中事件与通缉）；
##   - 每次开火 report_crime("weapon")（wanted 内部 2s 冷却去抖）。
##
## v1 待补：枪声（procedural_audio 加噪声包络）、枪模型/持枪动画、
## 车辆伤害、drive-by（车内开火）。

## 三把枪。dmg 在 v1 只用于击退力度（行人无血条，中弹即倒）。
const WEAPONS := [
	{"name": "9mm 手枪", "rpm": 300.0, "range": 45.0, "spread": 0.02,
		"mag": 15, "reload": 1.3, "auto": false, "pellets": 1, "kick": 3.0},
	{"name": "冲锋枪", "rpm": 750.0, "range": 50.0, "spread": 0.055,
		"mag": 30, "reload": 2.0, "auto": true, "pellets": 1, "kick": 2.0},
	{"name": "霰弹枪", "rpm": 75.0, "range": 22.0, "spread": 0.10,
		"mag": 6, "reload": 2.6, "auto": false, "pellets": 7, "kick": 5.0},
]

## 弹道步长（米，数据坐标）；CityCollision.blocked 的采样精度够了
const RAY_STEP := 1.2
## 车辆命中半径（数据坐标，按车宽 2m 留余量）
const CAR_HIT_RADIUS := 1.6

## 当前持枪下标，-1 = 空手
var armed := -1
## 各枪弹匣余量（与 WEAPONS 同长）
var _ammo: Array = []
## 换弹剩余秒
var _reload_left := 0.0
## 射击间隔剩余秒
var _fire_cd := 0.0
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	_rng.seed = 20261103
	for w in WEAPONS:
		_ammo.append(int(w["mag"]))


func current() -> Dictionary:
	return {} if armed < 0 else WEAPONS[armed]


func ammo_in_mag() -> int:
	return 0 if armed < 0 else int(_ammo[armed])


func reloading() -> bool:
	return _reload_left > 0.0


## 换枪/收枪：再按同一数字键 = 收枪。返回提示文案（空串 = 无变化）。
func select(index: int) -> String:
	if index < 0 or index >= WEAPONS.size():
		return ""
	if armed == index:
		armed = -1
		return "已收枪"
	armed = index
	_reload_left = 0.0
	return "已切换：%s（弹匣 %d/%d · 左键开火）" % [WEAPONS[index]["name"], _ammo[armed], WEAPONS[index]["mag"]]


## 每帧驱动。just_pressed：本帧刚按下左键；held：左键按住。
## from/dir：数据坐标枪口与单位朝向。返回本帧事件（HUD/音效/主循环用）：
##   {fired, hit_person, hit_car, hit_wall, reloading, reload_done}
func step(delta: float, just_pressed: bool, held: bool,
		from: Vector2, dir: Vector2, world) -> Dictionary:
	var out := {"fired": false, "hit_person": 0, "hit_car": false, "hit_wall": false,
		"reloading": false, "reload_done": false}
	if armed < 0:
		return out
	var w: Dictionary = WEAPONS[armed]
	# 换弹计时
	if _reload_left > 0.0:
		_reload_left -= delta
		out["reloading"] = true
		if _reload_left <= 0.0:
			_ammo[armed] = int(w["mag"])
			out["reload_done"] = true
		return out
	_fire_cd = maxf(0.0, _fire_cd - delta)
	var want_fire := (bool(w["auto"]) and held) or just_pressed
	if not want_fire or _fire_cd > 0.0:
		return out
	if int(_ammo[armed]) <= 0:
		_reload_left = float(w["reload"])
		out["reloading"] = true
		return out
	_ammo[armed] = int(_ammo[armed]) - 1
	_fire_cd = 60.0 / float(w["rpm"])
	out["fired"] = true

	# 一次扳机 = pellets 发弹丸（霰弹枪散射；其他 1 发）
	for _p in int(w["pellets"]):
		var a := atan2(dir.x, dir.y) + _rng.randf_range(-float(w["spread"]), float(w["spread"]))
		var d := Vector2(sin(a), cos(a))
		_trace_shot(from, d, float(w["range"]), float(w["kick"]), world, out)
	return out


## 单发弹丸：墙/行人/车三择最近的命中点
func _trace_shot(from: Vector2, dir: Vector2, range_m: float, kick: float,
		world, out: Dictionary) -> void:
	# 1) 墙：沿射线步进查碰撞（最先挡住的地方）
	var wall_t := -1.0
	var s := RAY_STEP
	while s <= range_m:
		if world.collision.blocked(from.x + dir.x * s, from.y + dir.y * s):
			wall_t = s
			break
		s += RAY_STEP
	# 2) 行人：段-点最近测试
	var ped: Dictionary = world.pedestrians.shoot_hit(from, dir, range_m)
	var ped_t: float = float(ped["t"]) if not ped.is_empty() else -1.0
	# 3) 车（车流 + 警车）：与行人取最近
	var car_t := -1.0
	var car_hit := false
	for src in [world.traffic.car_poses(), world.wanted.cop_poses() if world.wanted != null else []]:
		for c in src:
			var rel := Vector2(c["x"], c["z"]) - from
			var t := rel.dot(dir)
			if t < 0.5 or t > range_m or (wall_t > 0.0 and t > wall_t) \
					or (ped_t > 0.0 and t > ped_t):
				continue
			var perp := rel - dir * t
			if perp.length() <= CAR_HIT_RADIUS:
				car_t = t
				car_hit = true
				break
		if car_hit:
			break

	# 判定落点事件：行人 > 车 > 墙（距离最近者赢，上面已经按 t 剪枝）
	if ped_t > 0.0 and (wall_t < 0.0 or ped_t <= wall_t):
		out["hit_person"] = int(out["hit_person"]) + 1
		# 开枪 + 打中人都算治安事件（wanted 内部冷却去抖）
		if world.wanted != null:
			world.wanted.report_crime("weapon", ped["pos"], 1.0)
		return
	if car_hit:
		out["hit_car"] = true
		if world.wanted != null:
			var pos := from + dir * car_t
			world.wanted.report_crime("weapon", pos, 1.0)
		return
	if wall_t > 0.0:
		out["hit_wall"] = true


## HUD 用：{name, ammo, mag, reloading}
func hud_state() -> Dictionary:
	if armed < 0:
		return {}
	var w: Dictionary = WEAPONS[armed]
	return {"name": w["name"], "ammo": int(_ammo[armed]), "mag": int(w["mag"]),
		"reloading": reloading()}
