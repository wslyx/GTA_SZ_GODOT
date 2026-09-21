extends RefCounted
class_name Autopilot
##
## 自动驾驶 —— 移植原版 src/city-autopilot.ts。
##
## 策略：
##   - 用 RoadGraph.route() 规划折线，沿折线取前瞻点作为目标
##   - 每帧对三个横向偏移（左 1.15 / 中 0 / 右 5.2）各做一次 0.05s × 30 步前滚，
##     按"离障碍的间隙 + 贴合路线"打分，选最优偏移
##   - 速度受路型与宽度限制，转弯时额外降速
##   - 与前车保持 3.05m 圆形预测；与前车距离过近则跟车
##   - 信号灯：从前瞻点查询前方红灯停线距离 hold，
##     若 hold 存在且剩余路程 > hold + 6，则按 sqrt(9*(hold-1.8)) 限速；
##     速降到 0.3 以下进入 yielding（红灯等待不计入绕行计时）
##   - 受困：静止 >5s 判 blocked；等待 >3s 触发绕行重规划
##
## 坐标：数据坐标 (east, north)。

enum Phase { IDLE, DRIVING, YIELDING, BLOCKED, ARRIVED }

const CRUISE_MIN := 6.0
const CRUISE_MAX := 28.0
const LOOKAHEAD := 26.0
const ROLLOUT_STEPS := 30
const ROLLOUT_DT := 0.05
const OFFSETS := [1.15, 0.0, 5.2]
const OBSTACLE_RADIUS := 3.05
const STALL_TIMEOUT := 5.0
const WAIT_TIMEOUT := 3.0
const ARRIVE_RADIUS := 12.0

## 路型限速（原版 ROAD_CRUISE）
const ROAD_CRUISE := {
	"motorway": 28.0, "trunk": 24.0, "primary": 24.0, "secondary": 20.0,
	"tertiary": 17.0, "residential": 14.0, "unclassified": 13.0,
	"living_street": 12.0, "service": 10.0, "footway": 8.0, "path": 8.0,
}

var active := false
var phase: int = Phase.IDLE
var reason := ""

var _route: PackedVector2Array = PackedVector2Array()
var _index := 0
var _wait_timer := 0.0
var _stall_timer := 0.0
var _last_pos := Vector2.ZERO
var _reroute_cooldown := 0.0

var world: CityWorld
var graph: RoadGraph
## 外部注入：func(from: Vector2, to: Vector2) -> float  返回前方红灯停线距离，无则 INF
var signal_hold: Callable = Callable()
## 外部注入：func(pos: Vector2, yaw: float) -> bool  该点是否被建筑/水阻挡
var blocked_fn: Callable = Callable()
## 外部注入：交通车辆位置数组（数据坐标）
var traffic_positions: Callable = Callable()


func setup(p_world: CityWorld) -> void:
	world = p_world
	graph = p_world.graph


## 开始导航到目标点
func start(target: Vector2, from: Vector2) -> bool:
	if graph == null or graph.nodes.is_empty():
		return false
	_route = graph.route(from, target)
	if _route.size() < 2:
		phase = Phase.BLOCKED
		reason = "no-route"
		return false
	_index = 0
	active = true
	phase = Phase.DRIVING
	reason = ""
	_wait_timer = 0.0
	_stall_timer = 0.0
	_last_pos = from
	return true


func cancel() -> void:
	active = false
	phase = Phase.IDLE
	_route = PackedVector2Array()
	reason = ""


func _target_point(pos: Vector2) -> Vector2:
	# 沿折线推进索引到前瞻距离
	while _index < _route.size() - 1 and pos.distance_to(_route[_index]) < 6.0:
		_index += 1
	var ahead := _route[mini(_index, _route.size() - 1)]
	# 找前瞻点
	var acc := 0.0
	var prev := pos
	for i in range(_index, _route.size()):
		acc += prev.distance_to(_route[i])
		prev = _route[i]
		if acc >= LOOKAHEAD:
			ahead = _route[i]
			break
		ahead = _route[i]
	return ahead


## 单步决策。返回 {throttle, steer}
func compute(pos: Vector2, yaw: float, speed: float, dt: float) -> Dictionary:
	if not active:
		return {"throttle": 0.0, "steer": 0.0}

	# 到达判定
	var goal := _route[_route.size() - 1]
	if pos.distance_to(goal) < ARRIVE_RADIUS:
		phase = Phase.ARRIVED
		reason = "arrived"
		active = false
		return {"throttle": 0.0, "steer": 0.0}

	# 受困与等待计时
	var moved := pos.distance_to(_last_pos)
	_last_pos = pos
	if speed < 0.4:
		_stall_timer += dt
		if phase != Phase.YIELDING:
			_wait_timer += dt
	else:
		_stall_timer = 0.0
		_wait_timer = 0.0

	if _stall_timer > STALL_TIMEOUT:
		phase = Phase.BLOCKED
		reason = "stalled"
	if _wait_timer > WAIT_TIMEOUT:
		_wait_timer = 0.0
		reason = "reroute"
		# 绕行：以当前点重新规划（原版 findRoute(avoid)）
		start(goal, pos)

	# 目标朝向
	var target := _target_point(pos)
	var desired_yaw := atan2(target.x - pos.x, target.y - pos.y)
	var delta := wrapf(desired_yaw - yaw, -PI, PI)

	# 三个横向偏移前滚，选最优
	var best_offset: float = OFFSETS[1]
	var best_score := -INF
	var others: Array = traffic_positions.call() if traffic_positions.is_valid() else []
	for off in OFFSETS:
		var score := _rollout_score(pos, yaw, speed, delta, off, others)
		if score > best_score:
			best_score = score
			best_offset = off

	var steer_target := clampf(delta * 1.6 + best_offset * 0.05, -1.0, 1.0)

	# 限速：路型 + 宽度 + 转弯
	var cruise := _cruise_speed(pos)
	var turn_caution := 3.5 if absf(delta) > 0.35 else 6.0
	var speed_limit := minf(cruise, turn_caution * cruise / 6.0)

	# 前车跟车
	for o in others:
		var op: Vector2 = o
		var d := pos.distance_to(op)
		if d < OBSTACLE_RADIUS * 3.0:
			var fwd := Vector2(sin(yaw), cos(yaw))
			var to_o := (op - pos).normalized()
			if fwd.dot(to_o) > 0.6:
				speed_limit = minf(speed_limit, maxf(0.0, (d - 4.0) * 1.2))

	# 信号灯
	if signal_hold.is_valid():
		var hold: float = signal_hold.call(pos, Vector2(sin(yaw), cos(yaw)))
		if is_finite(hold):
			var remaining := pos.distance_to(goal)
			if remaining > hold + 6.0:
				speed_limit = minf(speed_limit, sqrt(maxf(0.0, 9.0 * (hold - 1.8))))
			if speed < 0.3:
				phase = Phase.YIELDING
				reason = "red-light"

	if speed_limit < 0.2:
		return {"throttle": -0.35, "steer": steer_target}

	var throttle := clampf((speed_limit - speed) * 0.35, -0.6, 1.0)
	if throttle > 0.0 and phase == Phase.DRIVING:
		reason = "driving"
	return {"throttle": throttle, "steer": steer_target}


func _cruise_speed(pos: Vector2) -> float:
	# CityCollision.nearest 的签名是 (east: float, north: float)，不是收 Vector2
	var near: Dictionary = world.collision.nearest(pos.x, pos.y)
	if near.is_empty():
		return CRUISE_MIN
	var road: Dictionary = near["road"]
	var kind := str(road.get("kind", "unclassified"))
	var base: float = ROAD_CRUISE.get(kind, 12.0)
	if str(road.get("id", "")).ends_with("_link"):
		base = minf(base, 10.0)
	var w := float(road.get("width", 6.0))
	if w < 4.5:
		base = minf(base, 10.0)
	elif w < 6.0:
		base = minf(base, 14.0)
	return clampf(base, CRUISE_MIN, CRUISE_MAX)


## 对给定偏移做前滚，返回评分（越大越好）
func _rollout_score(pos: Vector2, yaw: float, speed: float, delta: float, offset: float, others: Array) -> float:
	var car := CarDrive.new()
	car.x = pos.x
	car.z = pos.y
	car.yaw = yaw
	car.speed = speed
	var steer := clampf(delta * 1.6 + offset * 0.05, -1.0, 1.0)
	var min_clearance := INF
	for i in ROLLOUT_STEPS:
		car.step({"throttle": 0.35, "steer": steer, "handbrake": false}, ROLLOUT_DT)
		var p := Vector2(car.x, car.z)
		# 贴路线分数
		var to_route := 0.0
		if not _route.is_empty():
			var best_d := INF
			for k in range(maxi(0, _index - 2), _route.size()):
				var d := p.distance_to(_route[k])
				if d < best_d:
					best_d = d
			to_route = -best_d
		# 障碍间隙
		for o in others:
			var op: Vector2 = o
			min_clearance = minf(min_clearance, p.distance_to(op) - OBSTACLE_RADIUS)
		# 静态阻挡直接重罚
		if blocked_fn.is_valid() and blocked_fn.call(p):
			return -1000.0
		if i == ROLLOUT_STEPS - 1:
			return to_route * 1.0 + clampf(min_clearance, -10.0, 10.0) * 0.6
	return 0.0


func status() -> Dictionary:
	return {"active": active, "phase": Phase.keys()[phase], "reason": reason,
			"waypoints": _route.size(), "index": _index,
			"remaining": _route.size() - _index}


## 供地图绘制路线
func route_points() -> PackedVector2Array:
	return _route
