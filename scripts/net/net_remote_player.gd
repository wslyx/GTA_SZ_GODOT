extends Node3D
class_name NetRemotePlayer
## 深城纪多人战局 · 远程玩家化身（MVP 占位实现）
##
## 用一个胶囊体 + 昵称牌代表远程玩家。
## 位置渲染采用"快照缓冲插值"：维护最近的状态快照，延迟 INTERP_DELAY_MS 渲染，
## 在两个快照间线性插值 —— 相比直接向目标指数趋近，帧间速度更连贯、不抖动。
## 快照用尽（弱网）时短暂保持最后位置，不做长距离外推以免回弹。
## 后续可替换为 ALS 驱动的镜像角色（接 GtaSzAlsPlayerHost 的姿态回放）。

## 远程会话 ID
var remote_session_id := 0
## 玩家辨识色（会话 ID 哈希，身体/昵称牌/雷达共用）
var identity_color := Color.WHITE
## 远程玩家昵称
var player_name := "漫游者" :
	set(value):
		player_name = value
		_refresh_label()

## 移动模式（walk/car/tank/plane/observer），非 walk 时在昵称牌上标注
var move_mode := "walk" :
	set(value):
		if move_mode == value:
			return
		move_mode = value
		_refresh_label()

## 插值渲染延迟（毫秒）：略大于状态上报间隔（15Hz≈67ms）
const INTERP_DELAY_MS := 100
## 快照缓冲上限（15Hz 下约 1.3 秒）
const SNAPSHOT_MAX := 20

## 快照缓冲：[{t: 接收时刻ms, pos: Vector3, yaw: float, vel: Vector3}]
var _snapshots: Array = []
var _has_target := false

## 速度外推上限（秒）：快照用尽时按最后速度外推，超过后冻结防止飞出
const MAX_EXTRAPOLATION_SEC := 1.0

var _body: MeshInstance3D
var _label: Label3D


func _init() -> void:
	name = "NetRemotePlayer"


func _ready() -> void:
	identity_color = _color_from_id(remote_session_id)
	# 胶囊身体（用会话 ID 哈希出辨识色）
	_body = MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.35
	capsule.height = 1.75
	_body.mesh = capsule
	_body.position.y = 0.9
	var mat := StandardMaterial3D.new()
	mat.albedo_color = identity_color
	mat.roughness = 0.7
	_body.material_override = mat
	add_child(_body)

	# 昵称牌
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.position.y = 2.15
	_label.pixel_size = 0.004
	_label.font_size = 48
	_label.modulate = identity_color
	_refresh_label()
	add_child(_label)

	# 尚未收到位置包前隐藏
	visible = false


func _process(_delta: float) -> void:
	if not _has_target or _snapshots.is_empty():
		return
	var render_t := Time.get_ticks_msec() - INTERP_DELAY_MS

	# 找到夹住 render_t 的相邻两个快照
	var a: Dictionary = {}
	var b: Dictionary = {}
	for i in range(_snapshots.size() - 1):
		var s1: Dictionary = _snapshots[i]
		var s2: Dictionary = _snapshots[i + 1]
		if s1.t <= render_t and s2.t >= render_t:
			a = s1
			b = s2
			break

	if a.is_empty():
		# 渲染时刻早于最早快照（刚收到首包）
		if render_t <= _snapshots[0].t:
			a = _snapshots[0]
			b = _snapshots[0]
		else:
			# 快照用尽（弱网/丢包）：按最后速度外推，最多 1 秒，之后冻结。
			# 静止（速度近零）时保持最后位置即可。
			var last: Dictionary = _snapshots[-1]
			var last_vel: Vector3 = last.vel
			if last_vel.length_squared() > 0.01:
				var overtime := minf(float(render_t - int(last.t)) / 1000.0, MAX_EXTRAPOLATION_SEC)
				global_position = last.pos + last_vel * overtime
				rotation.y = last.yaw
			return

	# 丢弃太旧的快照（保留 1 秒余量，避免缓冲无限增长）
	while _snapshots.size() > 2 and _snapshots[1].t < render_t - 1000:
		_snapshots.pop_front()

	# 位置线性插值 + 朝向角度插值
	var span: int = int(b.t) - int(a.t)
	if span <= 0:
		global_position = a.pos
		rotation.y = a.yaw
		return
	var alpha := clampf(float(render_t - int(a.t)) / float(span), 0.0, 1.0)
	global_position = a.pos.lerp(b.pos, alpha)
	rotation.y = lerp_angle(a.yaw, b.yaw, alpha)


## 收到远程玩家的最新状态（服务端 RoomBroadcast 的二进制 GameData）
func apply_state(pos: Vector3, yaw: float, mode := "walk", vel := Vector3.ZERO) -> void:
	move_mode = mode
	_snapshots.append({ "t": Time.get_ticks_msec(), "pos": pos, "yaw": yaw, "vel": vel })
	if _snapshots.size() > SNAPSHOT_MAX:
		_snapshots.pop_front()
	if not _has_target:
		# 首包直接落位，避免从原点飞过来
		global_position = pos
		rotation.y = yaw
		_has_target = true
		visible = true


## 按会话 ID 生成稳定辨识色
func _color_from_id(id: int) -> Color:
	var hue := fmod(float(id % 360) / 360.0 + 0.618033, 1.0)
	return Color.from_hsv(hue, 0.65, 0.9)


## 昵称牌文本：昵称 +（非步行时的）模式徽标
func _refresh_label() -> void:
	if _label == null:
		return
	match move_mode:
		"car":
			_label.text = "%s（车）" % player_name
		"tank":
			_label.text = "%s（坦克）" % player_name
		"plane":
			_label.text = "%s（飞机）" % player_name
		_:
			_label.text = player_name
