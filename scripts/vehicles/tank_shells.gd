extends Node3D
class_name TankShells
##
## 坦克炮弹 —— 移植原版 city-tank.ts 的 tracer 池 + 命中效果。
##
## 组成（照搬原版）：
##   - 4 发曳光弹：自发光橙球（d=0.2），发射时找空闲池位启用
##   - 2 个与飞机共用的 FlightExplosion 爆炸（命中点 +0.15m 定向爆）
##   - 弹道：TankSim.advance_shell（数据坐标、重力 9.81、寿命 6s，
##     位置二阶 / 速度一阶积分）；超时落地不爆（原版同款）
##
## 碰撞：复用 FlightCollision.sweep（建筑三维棱柱 + 地形水面采样，数据坐标）——
## 原版炮弹用的也是同一套 FlightCityCollision，不是驾驶的二维 blocked()。
##
## 坐标：仿真全程数据坐标（x 东 / y 上 / z 北），只有画到节点时转世界坐标
## （CoordinateUtil.to_world，z = −北）。

const EXPLOSION_SCRIPT := preload("res://scripts/vehicles/flight_explosion.gd")
const POOL := 4
const LIFE := 6.0

var hits := 0
## 命中爆照时的音效回调（main_game 注入 audio.explosion）
var on_explosion: Callable = Callable()

var _tracers: Array = []      ## MeshInstance3D × POOL
var _shells: Array = []       ## {pos, vel, age, mesh, yaw}
var _effects: Array = []      ## [{fx, age}]


func _ready() -> void:
	_ensure_built()


## 池与爆炸在首次使用时构建（_ready 在某些无头/探针场景不触发，双保险）
func _ensure_built() -> void:
	if not _tracers.is_empty():
		return
	# ⚠️ Resource 在 Godot 4 里是 resource_name（写 name 会报 3.x 兼容层警告）
	var mat := StandardMaterial3D.new()
	mat.resource_name = "tank-shell-radiance"
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.65, 0.17)
	var sphere := SphereMesh.new()
	sphere.radius = 0.10
	sphere.height = 0.20
	sphere.radial_segments = 6
	sphere.rings = 4
	for i in POOL:
		var mi := MeshInstance3D.new()
		mi.name = "tank-shell-%d" % i
		mi.mesh = sphere
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_tracers.append(mi)
	for i in 2:
		var fx = EXPLOSION_SCRIPT.new()
		fx.name = "tank-explosion-%d" % i
		add_child(fx)
		_effects.append({"fx": fx, "age": 99.0})


## 池里还有空闲曳光弹吗（原版 fire() 先查池位、再消耗装填）
func has_free() -> bool:
	_ensure_built()
	return _shells.size() < POOL


## shot = TankSim.fire() 的返回 {origin:{x,y,z}, velocity:{x,y,z}}（数据坐标）
## sweep 为 main_game._flight_sweep；yaw 为炮塔世界角（数据 yaw，爆炸定向用）
func fire_shot(shot: Dictionary, sweep: Callable, yaw: float) -> bool:
	_ensure_built()
	if _shells.size() >= POOL:
		return false
	var idx := -1
	for i in POOL:
		var used := false
		for s in _shells:
			if int(s["mesh"]) == i:
				used = true
				break
		if not used:
			idx = i
			break
	if idx < 0:
		return false
	var o: Dictionary = shot["origin"]
	var v: Dictionary = shot["velocity"]
	(_tracers[idx] as MeshInstance3D).visible = true
	_shells.append({
		"pos": {"x": float(o["x"]), "y": float(o["y"]), "z": float(o["z"])},
		"vel": {"x": float(v["x"]), "y": float(v["y"]), "z": float(v["z"])},
		"age": 0.0,
		"mesh": idx,
		"yaw": yaw,
	})
	return true


## 每帧推进：先更新爆炸，再积分炮弹（原版 tank step 的后半段）
func step(dt: float, sweep: Callable) -> void:
	_ensure_built()
	var h := clampf(dt, 0.0, 0.05)
	for e in _effects:
		if float(e["age"]) < 3.5:
			e["age"] = float(e["age"]) + h
			var fx0 = e["fx"]
			fx0.step(float(e["age"]))
			if float(e["age"]) >= 3.5:
				fx0.reset()
	for i in range(_shells.size() - 1, -1, -1):
		var s: Dictionary = _shells[i]
		var pos: Dictionary = s["pos"]
		var vel: Dictionary = s["vel"]
		var next := TankSim.advance_shell(pos, vel, h)
		var from := Vector3(float(pos["x"]), float(pos["y"]), float(pos["z"]))
		var to := Vector3(float(next["x"]), float(next["y"]), float(next["z"]))
		var hit: Dictionary = sweep.call(from, to)
		s["age"] = float(s["age"]) + h
		if (not hit.is_empty()) or float(s["age"]) > LIFE:
			(_tracers[int(s["mesh"])] as MeshInstance3D).visible = false
			_shells.remove_at(i)
			if not hit.is_empty():
				hits += 1
				_burst(hit, float(s["yaw"]))
		else:
			s["pos"] = next
			(_tracers[int(s["mesh"])] as MeshInstance3D).position = CoordinateUtil.to_world(
				float(next["x"]), float(next["z"]), float(next["y"]))


func _burst(hit: Dictionary, yaw: float) -> void:
	var best: Dictionary = {}
	for e in _effects:
		if best.is_empty() or float(e["age"]) > float(best["age"]):
			best = e
	if best.is_empty():
		return
	var p: Dictionary = hit.get("point", {})
	var world_pos := CoordinateUtil.to_world(float(p.get("x", 0.0)),
		float(p.get("z", 0.0)), float(p.get("y", 0.0)) + 0.15)
	var fx = best["fx"]
	fx.reset()
	fx.burst(world_pos, yaw)
	best["age"] = 0.0
	if on_explosion.is_valid():
		on_explosion.call()


## 切出坦克模式时收尾（原版 setActive(false) → clearEffects）
func clear_effects() -> void:
	_ensure_built()
	_shells.clear()
	for t in _tracers:
		(t as MeshInstance3D).visible = false
	for e in _effects:
		var fx = e["fx"]
		fx.reset()
		e["age"] = 99.0


func stats() -> Dictionary:
	return {"shells": _shells.size(), "hits": hits}
