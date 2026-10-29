extends Node
## 深城纪多人战局 · 会话编排 autoload（NetSession）
##
## 职责：
##  - 连接 kcp_tauri 战局服务器，加入默认战局（自由漫游大厅）
##  - 以 15Hz 把本地玩家位置/朝向打包成二进制 GameData 经 RoomBroadcast 上报
##  - 接收战局广播，维护远程玩家化身（NetRemotePlayer）与聊天
##  - 心跳保活、被踢/掉线自动清理
##
## 快捷键：F9 连接/断开  T 打开聊天  Esc 关闭聊天
##
## 接入：project.godot 已注册 autoload；main_game.gd 中调用
## NetSession.bind_local_player(_als_host) 绑定本地玩家节点。

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 9999
const DEFAULT_ROOM := "sz_free_roam"

## 连接配置文件（user://net_config.json），F10 面板可编辑并保存
const CONFIG_PATH := "user://net_config.json"

## 状态上报频率（Hz）
const STATE_SEND_HZ := 15.0
## 心跳间隔（秒）
const HEARTBEAT_INTERVAL := 3.0
## 无任何服务端消息视为掉线的阈值（秒）
const SILENCE_TIMEOUT := 15.0
## 远程玩家无消息剔除阈值（秒）
const REMOTE_TIMEOUT := 10.0

## 服务器地址（可在运行时覆盖）
var host := DEFAULT_HOST
var port := DEFAULT_PORT
## 战局认证令牌：与服务端 KcpConfig.auth_token 一致；空串 = 未启用认证
var auth_token := ""
## 启动时自动连接（配置文件里开关，默认关）
var auto_connect := false
## 玩家昵称
var player_name := "漫游者%02d" % (randi() % 100)
## 是否自动重连（被管理员踢出时不重连）
var auto_reconnect := true
## 重连尝试上限
const MAX_RECONNECT_ATTEMPTS := 5
## 当前所在战局，空串表示未加入
var current_room := ""
## 是否处于"已连接且已加入战局"状态
var in_session := false
## 最近一次往返延迟（毫秒），-1 表示未知
var last_rtt := -1
## 本地玩家当前移动模式（walk/car/tank/plane/observer），经 weapon 字段上报
var current_mode := "walk"

## 模式来源 Callable（由 main_game 绑定，返回 walk/car/tank/plane/observer）
var _mode_provider: Callable = Callable()

## 本地玩家节点（Node3D，通常是 AlsPlayerHost）
var _local_player: Node3D = null
# ⚠️ _client 与 _remotes 的值故意不写类型注解：net_client.gd / net_remote_player.gd
# 是新增脚本，class_name 要等编辑器重扫才会进全局类缓存（与 main_game.gd
# 对 Rider 的处理同理），preload + 无注解可保证冷启动也能解析。
var _client = null
## 远程玩家化身：会话 ID → NetRemotePlayer
var _remotes := {}
## 远程玩家最后活跃时间：会话 ID → Time.get_ticks_msec()
var _remote_last_seen := {}

## 自动重连状态
var _reconnect_attempts := 0
var _reconnect_pending := false

var _state_accum := 0.0
var _heartbeat_accum := 0.0
var _silence_accum := 0.0
var _send_sequence := 0

## 差分速度估计（发送端）：上次上报的位置与时刻
var _last_sent_pos := Vector3.ZERO
var _last_sent_ms := -1

## 聊天与状态 UI
var _hud: CanvasLayer = null
var _chat_log: RichTextLabel = null
var _chat_input: LineEdit = null
var _status_label: Label = null
## F10 连接设置面板
var _settings_panel: PanelContainer = null
## 雷达小地图（net_radar.gd 实例；故意不写类型——provider 是其自定义属性）
var _radar = null
var _set_host: LineEdit = null
var _set_port: LineEdit = null
var _set_room: LineEdit = null
var _set_name: LineEdit = null
var _set_token: LineEdit = null
var _set_auto: CheckButton = null

const REMOTE_PLAYER_SCRIPT := preload("res://scripts/net/net_remote_player.gd")
const NET_CLIENT_SCRIPT := preload("res://scripts/net/net_client.gd")
const RADAR_SCRIPT := preload("res://scripts/net/net_radar.gd")


func _ready() -> void:
	_diag("=== NetSession autoload 就绪（游戏启动）===")
	_load_config()
	_build_hud()
	_chat("系统", "多人战局模块已加载。按 F9 连接服务器，F10 打开连接设置。")
	if auto_connect:
		_chat("系统", "auto_connect 已启用，自动连接 %s:%d ..." % [host, port])
		join_session(host, port, player_name)


## 读取连接配置（user://net_config.json；缺省文件时用默认值）
func _load_config() -> void:
	var f := FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if f == null:
		return
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK or not (json.data is Dictionary):
		push_warning("[NetSession] net_config.json 解析失败，使用默认配置")
		return
	var cfg: Dictionary = json.data
	host = str(cfg.get("host", host))
	port = int(cfg.get("port", port))
	var room := str(cfg.get("room", DEFAULT_ROOM))
	if room != "":
		_default_room_override = room
	auth_token = str(cfg.get("token", auth_token))
	auto_connect = bool(cfg.get("auto_connect", auto_connect))
	var name := str(cfg.get("name", ""))
	if name.strip_edges() != "":
		player_name = name.strip_edges().left(24)


## 保存连接配置（F10 面板"保存"按钮）
func save_config() -> void:
	var f := FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if f == null:
		_chat("系统", "配置保存失败：无法写入 %s" % CONFIG_PATH)
		return
	f.store_string(JSON.stringify({
		"host": host,
		"port": port,
		"room": _default_room_override,
		"name": player_name,
		"token": auth_token,
		"auto_connect": auto_connect,
	}, "  "))
	f.close()
	_chat("系统", "连接配置已保存")


## 默认战局（可被配置文件覆盖；join 时使用）
var _default_room_override := DEFAULT_ROOM


var _heartbeat_probe_ms := 0

## 关键诊断写文件（user://net_diag.log）：卡死后可直接读文件取证。
func _diag(msg: String) -> void:
	var f := FileAccess.open("user://net_diag.log", FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open("user://net_diag.log", FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line("[%s] %s" % [Time.get_datetime_string_from_system().replace("T", " "), msg])
	f.close()


var _last_frame_ticks := 0

func _process(delta: float) -> void:
	# 帧间隔看门狗：>2 秒的帧 = 主线程曾长时间阻塞，落盘留证
	var frame_now := Time.get_ticks_msec()
	if _last_frame_ticks != 0 and frame_now - _last_frame_ticks > 2000:
		_diag("⚠ 帧阻塞 %.1f 秒（主线程上一帧卡了很久）" % [
			(frame_now - _last_frame_ticks) / 1000.0])
	_last_frame_ticks = frame_now
	# 心跳：10 秒一跳，写 stdout + 文件
	var probe_now := Time.get_ticks_msec()
	if probe_now - _heartbeat_probe_ms > 10000:
		_heartbeat_probe_ms = probe_now
		var hb := "心跳 in_session=%s remotes=%d nodes=%d" % [
			in_session, _remotes.size(), get_tree().get_node_count()]
		print("[NetSession] ", hb)
		_diag(hb)
	if _client == null:
		return
	_client.poll()

	if in_session:
		# 状态上报节流
		_state_accum += delta
		if _state_accum >= 1.0 / STATE_SEND_HZ:
			_state_accum = 0.0
			_send_local_state()

		# 心跳
		_heartbeat_accum += delta
		if _heartbeat_accum >= HEARTBEAT_INTERVAL:
			_heartbeat_accum = 0.0
			_client.send_ping()

		# 静默超时检测（非手动断开，走自动重连流程）
		_silence_accum += delta
		if _silence_accum > SILENCE_TIMEOUT:
			_on_disconnected("连接超时（%d 秒无服务器消息）" % int(SILENCE_TIMEOUT))
			return
	else:
		# 握手阶段超时（10 秒无 ACK）：走断线重连流程
		_silence_accum += delta
		if _silence_accum > 10.0:
			_on_disconnected("握手超时")
			return

	# 远程玩家超时剔除
	var now := Time.get_ticks_msec()
	var stale: Array = []
	for sid in _remote_last_seen:
		if now - int(_remote_last_seen[sid]) > REMOTE_TIMEOUT * 1000.0:
			stale.append(sid)
	for sid in stale:
		_remove_remote(sid, "超时")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		match key.keycode:
			KEY_F9:
				if in_session or _client != null:
					_leave_session("手动断开")
				else:
					join_session(host, port, player_name)
			KEY_T:
				if in_session and _chat_input and not _chat_input.visible:
					_chat_input.visible = true
					_chat_input.grab_focus()
					get_viewport().set_input_as_handled()
			KEY_ESCAPE:
				if _chat_input and _chat_input.visible:
					_chat_input.visible = false
					_chat_input.release_focus()
			KEY_F10:
				if _settings_panel:
					_settings_panel.visible = not _settings_panel.visible


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_cleanup_client()


## 绑定本地玩家节点（Node3D），状态同步读取它的全局位姿
func bind_local_player(node: Node3D) -> void:
	_local_player = node


## 绑定移动模式来源 Callable（无参，返回 walk/car/tank/plane/observer）
func bind_mode_provider(provider: Callable) -> void:
	_mode_provider = provider


## 连接服务器并加入默认战局
func join_session(p_host: String, p_port: int, p_name: String) -> void:
	if _client != null:
		_chat("系统", "正在连接中，请勿重复连接")
		return
	host = p_host
	port = p_port
	if p_name.strip_edges() != "":
		player_name = p_name.strip_edges().left(24)
	_reconnect_pending = false
	_silence_accum = 0.0
	_set_status("连接中 %s:%d ..." % [host, port])
	_chat("系统", "正在连接服务器 %s:%d ..." % [host, port])
	_diag("join_session 开始 host=%s port=%d" % [host, port])
	_client = NET_CLIENT_SCRIPT.new()
	add_child(_client)
	_client.connected.connect(_on_connected)
	_client.connection_failed.connect(_on_connect_failed)
	_client.disconnected.connect(_on_disconnected)
	_client.room_joined.connect(_on_room_joined)
	_client.room_join_failed.connect(_on_room_join_failed)
	_client.members_listed.connect(_on_members_listed)
	_client.member_joined.connect(_on_member_joined)
	_client.member_left.connect(_on_member_left)
	_client.host_changed.connect(_on_host_changed)
	_client.room_data.connect(_on_room_data)
	_client.rooms_listed.connect(func(rooms): _chat("战局列表", str(rooms)))
	_client.pong.connect(func(rtt): last_rtt = rtt; _silence_accum = 0.0)
	_client.connect_to_server(host, port, player_name, auth_token)
	_diag("connect_to_server 已调用")


## 离开战局并断开连接
func leave_session() -> void:
	_leave_session("手动断开")


## 发送聊天消息（战局广播 JSON）
func send_chat(text: String) -> void:
	if not in_session or current_room == "" or _client == null:
		return
	var payload := JSON.stringify({ "type": "chat", "from": player_name, "text": text.left(120) }).to_utf8_buffer()
	_client.send_room_broadcast(current_room, payload)


## 请求战局列表（结果通过聊天窗展示，便于调试）
func request_rooms() -> void:
	if _client != null and in_session:
		_client.request_rooms()


# ---- 事件处理 ----

func _on_connected(sid: int) -> void:
	_silence_accum = 0.0
	_chat("系统", "握手成功，会话 ID: %d" % sid)
	_diag("握手成功")
	_set_status("已连接，加入战局...")
	_client.join_room(_default_room_override)


func _on_connect_failed(reason: String) -> void:
	_cleanup_client()
	_chat("系统", "连接失败: %s" % reason)
	_set_status("离线")


func _on_disconnected(reason: String) -> void:
	if reason == "KICKED_BY_ADMIN":
		# 被管理员踢出不自动重连
		_leave_session("被服务器管理员踢出", true)
		return
	# 服务器断开/超时：自动重连（指数退避 2s/4s/8s/15s/15s）
	_cleanup_client()
	if auto_reconnect and _reconnect_attempts < MAX_RECONNECT_ATTEMPTS:
		_reconnect_attempts += 1
		var delay := mini(2 << mini(_reconnect_attempts - 1, 3), 15)
		_reconnect_pending = true
		_set_status("连接中断，%d 秒后重连（第 %d/%d 次）" % [delay, _reconnect_attempts, MAX_RECONNECT_ATTEMPTS])
		_chat("系统", "连接中断: %s，%d 秒后自动重连" % [reason, delay])
		var timer := get_tree().create_timer(float(delay))
		timer.timeout.connect(_try_reconnect)
	else:
		_chat("系统", "连接断开: %s" % reason)
		_set_status("离线")


## 定时器回调：尝试重连
func _try_reconnect() -> void:
	if not _reconnect_pending or _client != null or in_session:
		return
	join_session(host, port, player_name)


func _on_room_joined(room: String, count: int) -> void:
	current_room = room
	in_session = true
	_diag("已加入战局 room=%s count=%d" % [room, count])
	_reconnect_attempts = 0   # 成功加入战局，重连计数归零
	_silence_accum = 0.0
	_set_status("战局 %s · %d 人 · %s" % [room, count + 1, ("RTT %dms" % last_rtt) if last_rtt >= 0 else ""])
	_chat("系统", "已加入战局「%s」（当前 %d 人）" % [room, count + 1])
	if _radar != null:
		_radar.visible = true


func _on_room_join_failed(_room: String, reason: String) -> void:
	_chat("系统", "加入战局失败: %s" % reason)


## 加入战局后收到已有成员清单：直接用真实昵称创建化身（无需等首包）
func _on_members_listed(room: String, members: Array) -> void:
	if room != current_room or _client == null:
		return
	for m in members:
		if not (m is Dictionary):
			continue
		var sid := int(str(m.get("sid", "0")))
		var member_name := str(m.get("name", ""))
		if sid != 0 and sid != _client.session_id and member_name != "":
			_ensure_remote(sid, member_name)
			_chat("战局", "已在战局中: %s" % member_name)


func _on_member_joined(sid: int, room: String, name: String) -> void:
	_chat("战局", "%s 加入了战局「%s」" % [name, room])
	_ensure_remote(sid, name)


func _on_member_left(sid: int, room: String, name: String) -> void:
	_chat("战局", "%s 离开了战局「%s」" % [name, room])
	_remove_remote(sid, "离开")


## 房主转移通知（原房主离开/被踢/超时后自动转移给最早加入成员）
func _on_host_changed(sid: int, room: String, name: String) -> void:
	if room != current_room:
		return
	var who := "你" if _client != null and sid == _client.session_id else name
	_chat("战局", "%s 成为战局「%s」的新房主" % [who, room])


func _on_room_data(sender: int, room: String, data: PackedByteArray) -> void:
	var _wd_t0 := Time.get_ticks_usec()
	_silence_accum = 0.0
	if data.size() == 0:
		return
	if _is_binary_game_data(data):
		var state := _decode_game_data(data)
		if state.is_empty():
			return
		_remote_last_seen[sender] = Time.get_ticks_msec()
		_diag("收到状态包 sender=%d size=%d" % [sender, data.size()])
		var remote := _ensure_remote(sender, "玩家%d" % (sender % 1000))
		remote.apply_state(
			state.position, state.yaw, str(state.get("mode", "walk")),
			state.get("velocity", Vector3.ZERO))
	elif data[0] == 0x7B:  # '{' JSON（聊天/系统公告等文本消息）
		var json := JSON.new()
		if json.parse(data.get_string_from_utf8()) == OK and json.data is Dictionary:
			match str(json.data.get("type", "")):
				"chat":
					_chat(str(json.data.get("from", "?")), str(json.data.get("text", "")))
				"announce":
					# 系统公告（sender=0，服务端主动推送），聊天窗高亮展示
					_chat("【公告】", str(json.data.get("text", "")))
	var _wd_cost := Time.get_ticks_usec() - _wd_t0
	if _wd_cost > 50000:
		_diag("⚠ 房间数据处理耗时 %d 微秒 sender=%d size=%d" % [
			_wd_cost, sender, data.size()])


# ---- 内部实现 ----

## 上报本地玩家状态（二进制 GameData：POSITION | ROTATION | WEAPON=移动模式）
func _send_local_state() -> void:
	if _local_player == null or not is_instance_valid(_local_player) or _client == null:
		return
	var _wd_t0 := Time.get_ticks_usec()
	# 每次上报前向模式提供者刷新当前模式（未绑定则维持上次值）
	if _mode_provider.is_valid():
		var m: String = str(_mode_provider.call())
		if m != "":
			current_mode = m
	var xf := _local_player.global_transform
	var pos := xf.origin
	# 差分速度估计：相邻两次上报的位置差 / 时间差（米/秒）。
	# 首次上报或瞬移（>200 m/s，如快速移动/重生）时置零，防止外推飞出。
	var now_ms := Time.get_ticks_msec()
	var vel := Vector3.ZERO
	if _last_sent_ms > 0:
		var dt := float(now_ms - _last_sent_ms) / 1000.0
		if dt > 0.001:
			vel = (pos - _last_sent_pos) / dt
			if vel.length() > 200.0:
				vel = Vector3.ZERO
	_last_sent_pos = pos
	_last_sent_ms = now_ms
	# Godot 坐标系→发送原样数值，两端仅做中转不做换算
	var q := xf.basis.get_rotation_quaternion()
	_send_sequence += 1
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	buf.put_8(0x01)                      # version
	buf.put_8(0x01)                      # msg_type = GameData
	buf.put_u64(int(Time.get_unix_time_from_system() * 1000.0))  # timestamp
	buf.put_u32(_send_sequence)          # sequence
	buf.put_u16(0x0033)                  # field_mask: POSITION|ROTATION|WEAPON|VELOCITY
	buf.put_float(pos.x)
	buf.put_float(pos.y)
	buf.put_float(pos.z)
	buf.put_float(q.x)
	buf.put_float(q.y)
	buf.put_float(q.z)
	buf.put_float(q.w)
	# WEAPON 字段（binary_protocol 字段顺序在 health/max_health 之后）：
	# u8 长度 + UTF-8 内容，复用为移动模式标记
	var mode_bytes := current_mode.to_utf8_buffer()
	buf.put_8(mode_bytes.size())
	buf.put_data(mode_bytes)
	# VELOCITY 字段（binary_protocol 最后一个字段）：3×f32 米/秒
	buf.put_float(vel.x)
	buf.put_float(vel.y)
	buf.put_float(vel.z)
	_client.send_room_broadcast(current_room, buf.data_array)
	var _wd_cost := Time.get_ticks_usec() - _wd_t0
	if _wd_cost > 50000:
		_diag("⚠ 状态上报耗时 %d 微秒（阈值 50000）" % _wd_cost)


func _is_binary_game_data(data: PackedByteArray) -> bool:
	# 服务端 GameDataPacket.HEADER_SIZE = 16，且首两字节为 version=1, type=1
	return data.size() >= 16 and data[0] == 0x01 and data[1] == 0x01


## 解码二进制 GameData → { position: Vector3, yaw: float }
func _decode_game_data(data: PackedByteArray) -> Dictionary:
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	buf.data_array = data
	buf.seek(2)
	buf.get_u64()                # timestamp
	buf.get_u32()                # sequence
	var field_mask := buf.get_u16()
	var result := {}
	if field_mask & 0x0001:
		result.position = Vector3(buf.get_float(), buf.get_float(), buf.get_float())
	if field_mask & 0x0002:
		var qx := buf.get_float()
		var qy := buf.get_float()
		var qz := buf.get_float()
		var qw := buf.get_float()
		var basis := Basis(Quaternion(qx, qy, qz, qw))
		result.yaw = basis.get_euler().y
	else:
		result.yaw = 0.0
	# WEAPON 字段被复用为移动模式标记（walk/car/tank/plane/observer）。
	# ⚠️ 手动计算偏移切片，不用 buf.get_data()（部分版本返回 Array 无 get_string_from_utf8）
	var off := 16
	if field_mask & 0x0001:
		off += 12
	if field_mask & 0x0002:
		off += 16
	if field_mask & 0x0010 and off < data.size():
		var wlen := data[off]
		off += 1
		if wlen > 0 and off + wlen <= data.size():
			result.mode = data.slice(off, off + wlen).get_string_from_utf8()
			off += wlen
	# VELOCITY 字段（binary_protocol 尾部字段）：3×f32 米/秒。
	# buf 游标停在 rotation 之后（weapon 为手动切片），需 seek 对齐后再读。
	if field_mask & 0x0020 and off + 12 <= data.size():
		buf.seek(off)
		result.velocity = Vector3(
			buf.get_float(), buf.get_float(), buf.get_float())
	return result


## 获取（或创建）远程玩家化身
func _ensure_remote(sid: int, name: String) -> Node3D:
	if _remotes.has(sid) and is_instance_valid(_remotes[sid]):
		return _remotes[sid]
	var root := _remote_root()
	var avatar: NetRemotePlayer = REMOTE_PLAYER_SCRIPT.new()
	avatar.remote_session_id = sid
	avatar.player_name = name
	root.add_child(avatar)
	_remotes[sid] = avatar
	_remote_last_seen[sid] = Time.get_ticks_msec()
	return avatar


func _remove_remote(sid: int, _reason: String) -> void:
	if _remotes.has(sid):
		if is_instance_valid(_remotes[sid]):
			_remotes[sid].queue_free()
		_remotes.erase(sid)
	_remote_last_seen.erase(sid)


## 远程玩家的挂载点（跟随当前场景根节点）
func _remote_root() -> Node:
	var scene := get_tree().current_scene
	if scene == null:
		return self
	var root := scene.get_node_or_null("NetRemoteRoot")
	if root == null:
		root = Node3D.new()
		root.name = "NetRemoteRoot"
		scene.add_child(root)
	return root


## 离开战局并断开连接（manual=true 表示主动断开，不触发重连）
func _leave_session(reason: String, manual := true) -> void:
	if manual:
		_reconnect_pending = false
		_reconnect_attempts = 0
	if current_room != "" and _client != null:
		_client.leave_room(current_room)
	_cleanup_client()
	_chat("系统", reason)
	_set_status("离线")


func _cleanup_client() -> void:
	current_room = ""
	in_session = false
	if _radar != null:
		_radar.visible = false
	for sid in _remotes.keys():
		_remove_remote(sid, "断开")
	if _client != null:
		if is_instance_valid(_client):
			_client.disconnect_from_server()
			_client.queue_free()
		_client = null


# ---- 聊天 / HUD ----

func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.name = "NetSessionHUD"
	_hud.layer = 60
	add_child(_hud)

	# 状态条（屏幕左上角）
	_status_label = Label.new()
	_status_label.text = "离线"
	_status_label.position = Vector2(12, 40)
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_label.modulate = Color(0.75, 0.78, 0.85, 0.9)
	_hud.add_child(_status_label)

	# 聊天记录（左下角，最多展示最近 6 条）
	_chat_log = RichTextLabel.new()
	_chat_log.bbcode_enabled = false
	_chat_log.scroll_active = false
	_chat_log.fit_content = true
	_chat_log.position = Vector2(12, 0)
	_chat_log.custom_minimum_size = Vector2(420, 130)
	_chat_log.anchor_top = 1.0
	_chat_log.anchor_bottom = 1.0
	_chat_log.offset_top = -190
	_chat_log.offset_left = 12
	_chat_log.offset_right = 432
	_chat_log.add_theme_font_size_override("normal_font_size", 14)
	_chat_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(_chat_log)

	# 聊天输入框（按 T 唤出）
	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = "按 Enter 发送，Esc 取消"
	_chat_input.visible = false
	_chat_input.anchor_top = 1.0
	_chat_input.anchor_bottom = 1.0
	_chat_input.offset_top = -52
	_chat_input.offset_left = 12
	_chat_input.offset_right = 432
	_chat_input.add_theme_font_size_override("font_size", 14)
	_chat_input.text_submitted.connect(_on_chat_submit)
	_hud.add_child(_chat_input)

	_build_settings_panel()

	# 雷达小地图（右上角）：战局内才显示
	var radar = RADAR_SCRIPT.new()
	radar.name = "NetRadar"
	radar.provider = _radar_entries
	radar.anchor_left = 1.0
	radar.anchor_right = 1.0
	radar.offset_left = -156
	radar.offset_right = -24
	radar.offset_top = 24
	radar.offset_bottom = 156
	radar.visible = false
	_hud.add_child(radar)
	_radar = radar


## 雷达数据提供者：把远程化身换算为本地玩家坐标系下的 (东, 南) 偏移（米）
func _radar_entries() -> Array:
	if _local_player == null or not is_instance_valid(_local_player):
		return []
	var _wd_t0 := Time.get_ticks_usec()
	var origin := _local_player.global_position
	var yaw: float = _local_player.global_rotation.y
	# 本地玩家朝向旋转：让雷达"上"对准玩家面朝方向（-Z 为面朝）
	# 注意 Basis 只能乘 Vector3，先在 3D 旋转再取 xz 平面
	var rot := Basis(Vector3.UP, -yaw)
	var entries: Array = []
	for sid in _remotes:
		var avatar = _remotes[sid]
		if avatar == null or not is_instance_valid(avatar):
			continue
		# avatar 为 GDScript 实例（保持无类型以访问 identity_color/player_name）；
		# 位置经显式 Vector3 计算，Basis 旋转后取 xz 平面
		var rel: Vector3 = (avatar as Node3D).global_position - origin
		var rotated3: Vector3 = rot * rel
		entries.append({
			"pos": Vector2(rotated3.x, rotated3.z),
			"color": avatar.identity_color,
			"name": avatar.player_name,
		})
	var _wd_cost := Time.get_ticks_usec() - _wd_t0
	if _wd_cost > 50000:
		_diag("⚠ 雷达数据构建耗时 %d 微秒（阈值 50000）" % _wd_cost)
	return entries


## F10 连接设置面板：host / port / 战局 / 昵称 / Token / 自动连接
func _build_settings_panel() -> void:
	_settings_panel = PanelContainer.new()
	_settings_panel.name = "NetSettingsPanel"
	_settings_panel.visible = false
	_settings_panel.anchor_left = 0.5
	_settings_panel.anchor_right = 0.5
	_settings_panel.anchor_top = 0.5
	_settings_panel.anchor_bottom = 0.5
	_settings_panel.offset_left = -190
	_settings_panel.offset_right = 190
	_settings_panel.offset_top = -140
	_settings_panel.offset_bottom = 140
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.10, 0.13, 0.95)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(14)
	_settings_panel.add_theme_stylebox_override("panel", style)
	_hud.add_child(_settings_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_settings_panel.add_child(vbox)

	var title := Label.new()
	title.text = "连接设置（F10 关闭）"
	title.add_theme_font_size_override("font_size", 15)
	vbox.add_child(title)

	_set_host = _add_setting_row(vbox, "服务器地址", host)
	_set_port = _add_setting_row(vbox, "端口", str(port))
	_set_room = _add_setting_row(vbox, "默认战局", _default_room_override)
	_set_name = _add_setting_row(vbox, "昵称", player_name)
	_set_token = _add_setting_row(vbox, "Token（可空）", auth_token)

	_set_auto = CheckButton.new()
	_set_auto.text = "启动时自动连接"
	_set_auto.button_pressed = auto_connect
	_set_auto.add_theme_font_size_override("font_size", 13)
	vbox.add_child(_set_auto)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)
	var save_btn := Button.new()
	save_btn.text = "保存配置"
	save_btn.pressed.connect(_on_settings_save)
	btn_row.add_child(save_btn)
	var connect_btn := Button.new()
	connect_btn.text = "保存并连接"
	connect_btn.pressed.connect(_on_settings_connect)
	btn_row.add_child(connect_btn)


func _add_setting_row(parent: Node, label_text: String, value: String) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(96, 0)
	label.add_theme_font_size_override("font_size", 13)
	row.add_child(label)
	var edit := LineEdit.new()
	edit.text = value
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.add_theme_font_size_override("font_size", 13)
	row.add_child(edit)
	parent.add_child(row)
	return edit


## 从面板读回设置并保存
func _on_settings_save() -> void:
	host = _set_host.text.strip_edges()
	port = maxi(1024, mini(int(_set_port.text) if _set_port.text.is_valid_int() else port, 65535))
	_default_room_override = _set_room.text.strip_edges()
	var new_name := _set_name.text.strip_edges()
	if new_name != "":
		player_name = new_name.left(24)
	auth_token = _set_token.text.strip_edges()
	auto_connect = _set_auto.button_pressed
	save_config()


## 保存并立即连接（未连接时）
func _on_settings_connect() -> void:
	_on_settings_save()
	if _client == null:
		join_session(host, port, player_name)


func _on_chat_submit(text: String) -> void:
	_chat_input.visible = false
	_chat_input.release_focus()
	var trimmed := text.strip_edges()
	if trimmed != "":
		send_chat(trimmed)


func _chat(from: String, text: String) -> void:
	if _chat_log == null:
		return
	_chat_log.append_text("[%s] %s\n" % [from, text])
	# 只保留最近 30 行
	var lines := _chat_log.get_parsed_text().split("\n")
	if lines.size() > 30:
		_chat_log.clear()
		for i in range(lines.size() - 30, lines.size()):
			if lines[i] != "":
				_chat_log.append_text(lines[i] + "\n")


func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text
