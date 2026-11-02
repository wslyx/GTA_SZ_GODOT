extends Node3D
class_name NetRemotePlayer
## 深城纪多人战局 · 远程玩家化身
##
## 步行模式：胶囊体 + 昵称牌，yaw 单轴插值（角色直立）。
## 载具模式（car/tank/plane）：隐藏胶囊，挂载与发送端同款的载具 GLB ——
## 发送端上报的是载具模型的 global_transform（含悬挂/俯仰/侧倾全量姿态，
## 与本端同款 GLB 坐标约定一致，见 README 第三节前向轴实测表），
## 因此模型以恒等局部变换挂在化身根节点下即可 1:1 复现，无需任何换算。
##
## 位置渲染采用"快照缓冲插值"：维护最近的状态快照，延迟渲染，
## 在两个快照间线性/四元数插值 —— 相比直接向目标指数趋近，帧间速度更连贯。
## 快照用尽（弱网）时按上报速度外推：匀速载具外推很准，可放宽时长；
## 步行变向频繁，外推上限收紧。快照参数按模式区分（见 MODE_PARAMS）。
##
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

## 移动模式（walk/car/tank/plane/observer），决定挂载的载具模型与插值参数
var move_mode := "walk" :
	set(value):
		if move_mode == value:
			return
		move_mode = value
		_apply_mode_visual()

## 通缉星级 0-5（WANTED 字段，GTA化 §五）：>0 时名牌缀星
var wanted_level := 0

## 载具 GLB 场景路径（与发送端 main_game 用的同一批资产）
const VEHICLE_SCENES := {
	"car": "res://data/city/car.glb",
	"tank": "res://data/city/tank/tank.glb",
	"plane": "res://data/city/floatplane.glb",
}

## 分模式参数：
##  delay_ms 渲染延迟（略大于 15Hz 上报间隔 ≈67ms；高速载具取大些，
##           保证渲染时刻总有前序快照可插，不进入外推）
##  extrap_s 快照用尽时按速度外推的时长上限（匀速载具外推准可放宽；
##           步行变向频繁，超时冻结比长距死推更不突兀）
##  label_y  昵称牌高度（按车顶/炮塔/机翼高度粗调）
const MODE_PARAMS := {
	"walk": { "delay_ms": 100, "extrap_s": 1.0, "label_y": 2.15 },
	"observer": { "delay_ms": 100, "extrap_s": 1.0, "label_y": 2.15 },
	"car": { "delay_ms": 120, "extrap_s": 2.0, "label_y": 1.85 },
	"tank": { "delay_ms": 120, "extrap_s": 1.5, "label_y": 3.0 },
	"plane": { "delay_ms": 160, "extrap_s": 2.5, "label_y": 3.4 },
}

## 快照缓冲上限（15Hz 下约 1.3 秒）
const SNAPSHOT_MAX := 20

## 快照缓冲：[{t: 接收时刻ms, pos: Vector3, yaw: float, quat: Quaternion, vel: Vector3}]
var _snapshots: Array = []
var _has_target := false

var _body: MeshInstance3D
var _label: Label3D
## 已挂载的载具模型：模式 → Node3D（惰性加载，一次挂在就用可见性切换）
var _vehicle_nodes := {}


func _init() -> void:
	name = "NetRemotePlayer"


func _ready() -> void:
	identity_color = _color_from_id(remote_session_id)
	# 胶囊身体（用会话 ID 哈希出辨识色）—— 仅步行/观战模式显示
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
	_label.pixel_size = 0.004
	_label.font_size = 48
	_label.modulate = identity_color
	add_child(_label)

	_apply_mode_visual()

	# 尚未收到位置包前隐藏
	visible = false


func _process(_delta: float) -> void:
	if not _has_target or _snapshots.is_empty():
		return
	var params := _mode_params()
	var render_t := Time.get_ticks_msec() - int(params.get("delay_ms", 100))
	var is_vehicle: bool = VEHICLE_SCENES.has(move_mode)

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
			# 快照用尽（弱网/丢包）：按最后速度外推，超时冻结防飞出。
			# 静止（速度近零）时保持最后位置即可。
			var last: Dictionary = _snapshots[-1]
			var last_vel: Vector3 = last.vel
			var extrap_s: float = params.get("extrap_s", 1.0)
			if last_vel.length_squared() > 0.01:
				var overtime := minf(float(render_t - int(last.t)) / 1000.0, extrap_s)
				global_position = last.pos + last_vel * overtime
				_set_facing(last.yaw, last.quat)
			return

	# 丢弃太旧的快照（保留 1 秒余量，避免缓冲无限增长）
	while _snapshots.size() > 2 and _snapshots[1].t < render_t - 1000:
		_snapshots.pop_front()

	# 位置线性插值；姿态按模式区分：载具用四元数 slerp（保留俯仰/侧倾），
	# 步行只用 yaw 单轴（角色始终直立，容忍 ALS 的小幅身体俯仰）
	var span: int = int(b.t) - int(a.t)
	if span <= 0:
		global_position = a.pos
		_set_facing(a.yaw, a.quat)
		return
	var alpha := clampf(float(render_t - int(a.t)) / float(span), 0.0, 1.0)
	global_position = a.pos.lerp(b.pos, alpha)
	if is_vehicle:
		var qa: Quaternion = a.quat
		var qb: Quaternion = b.quat
		global_transform.basis = Basis(qa.slerp(qb, alpha))
	else:
		rotation = Vector3(0.0, lerp_angle(a.yaw, b.yaw, alpha), 0.0)


## 收到远程玩家的最新状态（服务端 RoomBroadcast 的二进制 GameData）
func apply_state(pos: Vector3, yaw: float, mode := "walk", vel := Vector3.ZERO,
		quat := Quaternion.IDENTITY, wanted := 0) -> void:
	move_mode = mode
	# 通缉星（GTA化 §五）：0-5，>0 时名牌缀星
	if wanted != wanted_level:
		wanted_level = clampi(wanted, 0, 5)
		_refresh_label()
	_snapshots.append({
		"t": Time.get_ticks_msec(), "pos": pos, "yaw": yaw,
		"quat": quat, "vel": vel,
	})
	if _snapshots.size() > SNAPSHOT_MAX:
		_snapshots.pop_front()
	if not _has_target:
		# 首包直接落位，避免从原点飞过来
		global_position = pos
		_set_facing(yaw, quat)
		_has_target = true
		visible = true


## 按当前模式设置朝向：载具用完整四元数，步行只保留 yaw（直立）
func _set_facing(yaw: float, quat: Quaternion) -> void:
	if VEHICLE_SCENES.has(move_mode):
		global_transform.basis = Basis(quat)
	else:
		rotation = Vector3(0.0, yaw, 0.0)


## 分模式视觉切换：载具模式隐藏胶囊、挂载对应 GLB；其余显示胶囊
func _apply_mode_visual() -> void:
	var is_vehicle: bool = VEHICLE_SCENES.has(move_mode)
	if _body != null and is_instance_valid(_body):
		_body.visible = not is_vehicle
	# 已挂载模型的可见性切换
	for mode_key in _vehicle_nodes.keys():
		var node: Node3D = _vehicle_nodes[mode_key]
		if is_instance_valid(node):
			node.visible = (mode_key == move_mode)
	# 首次切换到某载具模式：懒加载场景并挂载（恒等局部变换 —— 发送端发的
	# 就是该模型节点的 global_transform，直接对齐）
	if is_vehicle and not _vehicle_nodes.has(move_mode):
		var path: String = VEHICLE_SCENES[move_mode]
		if ResourceLoader.exists(path):
			var scene := load(path)
			if scene is PackedScene:
				var model: Node3D = (scene as PackedScene).instantiate() as Node3D
				if model != null:
					add_child(model)
					_vehicle_nodes[move_mode] = model
					model.visible = true
	if _label != null and is_instance_valid(_label):
		_label.position.y = float(_mode_params().get("label_y", 2.15))
		_refresh_label()


## 分模式插值/外推参数
func _mode_params() -> Dictionary:
	var p: Variant = MODE_PARAMS.get(move_mode, MODE_PARAMS["walk"])
	return p as Dictionary


## 按会话 ID 生成稳定辨识色
func _color_from_id(id: int) -> Color:
	var hue := fmod(float(id % 360) / 360.0 + 0.618033, 1.0)
	return Color.from_hsv(hue, 0.65, 0.9)


## 昵称牌文本：昵称 +（非步行时的）模式徽标 +（通缉时的）星级
func _refresh_label() -> void:
	if _label == null:
		return
	var text := ""
	match move_mode:
		"car":
			text = "%s（车）" % player_name
		"tank":
			text = "%s（坦克）" % player_name
		"plane":
			text = "%s（飞机）" % player_name
		_:
			text = player_name
	# 通缉星缀尾（WANTED 字段，GTA化 §五）
	if wanted_level > 0:
		text += " " + "★".repeat(wanted_level)
	_label.text = text
