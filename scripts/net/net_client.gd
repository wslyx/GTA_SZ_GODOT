extends Node
class_name NetClient
## 深城纪多人战局 · 底层 UDP 协议客户端
##
## 与 kcp_tauri 服务端的自定义 UDP 二进制协议逐字段对齐（见
## kcp_tauri/src-tauri/src/kcp/protocol.rs）：
##   包头 26 字节: version(1)=0x01 | command(1) | session_id(u64 LE)
##                 | sequence(u32 LE) | timestamp(u64 LE) | payload_len(u32 LE)
## 之后跟 payload。
##
## 注意：该协议并非真正的 KCP 算法，可靠性由应用层 ReliableData/ACK 完成；
## MVP 战局同步全部走不可靠 Data/RoomBroadcast，丢一帧位置无妨。

signal connected(session_id: int)
signal connection_failed(reason: String)
signal disconnected(reason: String)
signal pong(rtt_ms: int)
signal room_joined(room: String, member_count: int)
signal room_join_failed(room: String, reason: String)
signal members_listed(room: String, members: Array)
signal room_left(room: String, remaining: int)
signal member_joined(session_id: int, room: String, player_name: String)
signal member_left(session_id: int, room: String, player_name: String)
signal host_changed(session_id: int, room: String, player_name: String)
signal room_data(sender_session_id: int, room: String, data: PackedByteArray)
signal rooms_listed(rooms: Array)
signal kicked(reason: String)
## 服务器主动点对点推送（Data 包，sender=0 系统通道）
signal server_data(data: PackedByteArray)
## 点对点数据（Data 包，sender=其他玩家；游戏内暂未使用，先开放信号）
signal data_received(sender_session_id: int, data: PackedByteArray)

# ---- 命令字节（与服务端 KcpCommand 完全一致）----
const CMD_HANDSHAKE := 0x02
const CMD_HANDSHAKE_ACK := 0x03
const CMD_DATA := 0x04
const CMD_DISCONNECT := 0x05
const CMD_PING := 0x06
const CMD_PONG := 0x07
const CMD_LIST_CLIENTS := 0x08
const CMD_BROADCAST := 0x09
const CMD_RELIABLE_DATA := 0x0A
const CMD_RELIABLE_ACK := 0x0B
const CMD_JOIN_ROOM := 0x0C
const CMD_LEAVE_ROOM := 0x0D
const CMD_ROOM_BROADCAST := 0x0E
const CMD_UPDATE_ROOM_METADATA := 0x0F
const CMD_LIST_ROOMS := 0x10

const HEADER_SIZE := 26
const PROTOCOL_VERSION := 0x01

## 服务器地址与端口
var host := "127.0.0.1"
var port := 9999
## 本端会话 ID（握手成功后由服务端分配）
var session_id := 0
## 是否已完成握手
var connected_flag := false

var _udp := PacketPeerUDP.new()
var _player_name := "漫游者"
var _ping_seq := 0
var _ping_sent_ms := 0
var _awaiting_ack := false


func _init() -> void:
	name = "NetClient"


## 发起握手（异步：结果通过 connected / connection_failed 信号返回）
## auth_token 非空时启用 Token 认证：payload = sha256(token+昵称)hex + 昵称，
## 须与服务端 KcpConfig.auth_token 一致，否则握手被静默拒绝。
func connect_to_server(p_host: String, p_port: int, player_name: String, auth_token := "") -> void:
	host = p_host
	port = p_port
	_player_name = player_name
	_udp.close()
	# connect_to_host 绑定随机本地端口并锁定远端，之后 put/get_packet 即可收发
	# 注意：返回 Error 枚举，成功为 OK(0)，不能用 not 取反判断
	var err := _udp.connect_to_host(p_host, p_port)
	if err != OK:
		connection_failed.emit("无法绑定 UDP 端口")
		return
	var name_bytes := player_name.to_utf8_buffer()
	var payload := name_bytes
	if auth_token != "":
		# 与服务端约定：期望值 = sha256_hex(token 字节 + 昵称字节)，后接昵称原文
		var digest := (auth_token + player_name).sha256_text()
		payload = digest.to_ascii_buffer() + name_bytes
	_send_packet(CMD_HANDSHAKE, 0, 0, payload)
	_awaiting_ack = true


## 断开连接
func disconnect_from_server() -> void:
	if connected_flag:
		_send_packet(CMD_DISCONNECT, session_id, 0, PackedByteArray())
	connected_flag = false
	_awaiting_ack = false
	_udp.close()
	session_id = 0


## 加入战局（房间不存在时服务端自动创建）
func join_room(room: String) -> void:
	if not connected_flag:
		return
	_send_packet(CMD_JOIN_ROOM, session_id, 0, room.to_utf8_buffer())


## 离开战局（空串 = 离开当前所在战局）
func leave_room(room: String) -> void:
	if not connected_flag:
		return
	_send_packet(CMD_LEAVE_ROOM, session_id, 0, room.to_utf8_buffer())


## 战局内广播任意二进制数据（不可靠）
func send_room_broadcast(room: String, data: PackedByteArray) -> void:
	if not connected_flag:
		return
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	var room_bytes := room.to_utf8_buffer()
	buf.put_8(room_bytes.size())
	buf.put_data(room_bytes)
	buf.put_data(data)
	_send_packet(CMD_ROOM_BROADCAST, session_id, 0, buf.data_array)


## 请求战局列表
func request_rooms() -> void:
	if not connected_flag:
		return
	_send_packet(CMD_LIST_ROOMS, session_id, 0, PackedByteArray())


## 发送心跳（服务端回 Pong，用于 RTT 测量与保活）
func send_ping() -> void:
	if not connected_flag:
		return
	_ping_seq += 1
	_ping_sent_ms = Time.get_ticks_msec()
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	buf.put_u64(int(Time.get_unix_time_from_system() * 1000.0))
	_send_packet(CMD_PING, session_id, 0, buf.data_array)


## 发送点对点数据（payload 前置 8 字节目标会话 ID，服务端转发）
func send_data(target_session_id: int, data: PackedByteArray) -> void:
	if not connected_flag:
		return
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	buf.put_u64(target_session_id)
	buf.put_data(data)
	_send_packet(CMD_DATA, session_id, 0, buf.data_array)


## 每帧轮询 UDP 包（由 NetSession 驱动）
func poll() -> void:
	# 未连接时也要短暂轮询，接收握手 ACK
	if not connected_flag and not _awaiting_ack:
		return
	# 每帧最多处理 64 包：防止异常风暴（服务器 bug/地址伪造）拖死主循环
	var budget := 64
	while budget > 0 and _udp.get_available_packet_count() > 0:
		budget -= 1
		var packet := _udp.get_packet()
		if packet.size() < HEADER_SIZE:
			continue
		_handle_packet(packet)


# ---- 内部实现 ----

func _send_packet(command: int, sid: int, seq: int, payload: PackedByteArray) -> void:
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	buf.put_8(PROTOCOL_VERSION)
	buf.put_8(command)
	buf.put_u64(sid)
	buf.put_u32(seq)
	buf.put_u64(int(Time.get_unix_time_from_system() * 1000.0))
	buf.put_u32(payload.size())
	buf.put_data(payload)
	_udp.put_packet(buf.data_array)


func _handle_packet(packet: PackedByteArray) -> void:
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	buf.data_array = packet
	var version := buf.get_8()
	if version != PROTOCOL_VERSION:
		return
	var command := buf.get_8()
	var sid := buf.get_u64()
	var _seq := buf.get_u32()
	var _ts := buf.get_u64()
	var payload_len := buf.get_u32()
	# ⚠️ 不用 buf.get_data()：该 API 在部分 Godot 4.x 版本返回 Array 而非
	# PackedByteArray（无 get_string_from_utf8）。用 PackedByteArray.slice 切片
	# （Godot 4 的 slice end 为排他边界；Godot 3 的 subarray 已更名）。
	var payload := packet.slice(HEADER_SIZE, HEADER_SIZE + payload_len)

	match command:
		CMD_HANDSHAKE_ACK:
			# 服务端在包头的 session_id 字段返回分配好的会话 ID
			session_id = sid
			connected_flag = true
			_awaiting_ack = false
			connected.emit(session_id)
		CMD_PONG:
			pong.emit(Time.get_ticks_msec() - _ping_sent_ms)
		CMD_DISCONNECT:
			var reason := "KICKED_BY_ADMIN" if payload.size() > 0 else "SERVER_CLOSED"
			if payload.size() > 0:
				reason = payload.get_string_from_utf8()
			disconnected.emit(reason)
			connected_flag = false
			_udp.close()
		CMD_JOIN_ROOM:
			_handle_join_room(sid, payload)
		CMD_LEAVE_ROOM:
			_handle_leave_room(sid, payload)
		CMD_ROOM_BROADCAST:
			_handle_room_broadcast(sid, payload)
		CMD_DATA:
			# payload: [sender u64][data]。sender=0 为服务器主动推送（工单 2.6），
			# 其他值为点对点转发。此前 CMD_DATA 未处理，服务器推送被静默丢弃。
			if payload.size() >= 8:
				var dbuf := StreamPeerBuffer.new()
				dbuf.big_endian = false
				dbuf.data_array = payload
				var sender := dbuf.get_u64()
				var data := payload.slice(8)
				if sender == 0:
					server_data.emit(data)
				else:
					data_received.emit(sender, data)
		CMD_LIST_ROOMS:
			_handle_list_rooms(payload)
		_:
			pass


func _handle_join_room(from_sid: int, payload: PackedByteArray) -> void:
	var text := payload.get_string_from_utf8()
	# 五种格式：OK:room:count（自己加入成功）/ ERR:...（失败）
	#           JOIN:sid:room:name（他人加入）/ MEMBERS:room:JSON（成员清单）
	#           HOST:sid:room:name（房主转移）
	if text.begins_with("OK:"):
		var parts := text.split(":", false, 2)
		if parts.size() >= 3:
			room_joined.emit(parts[1], int(parts[2]))
	elif text.begins_with("ERR:"):
		room_join_failed.emit("", text.substr(4))
	elif text.begins_with("JOIN:"):
		var parts := text.split(":", false, 3)
		if parts.size() >= 4 and int(parts[1]) != session_id:
			member_joined.emit(int(parts[1]), parts[2], parts[3])
	elif text.begins_with("HOST:"):
		var parts := text.split(":", false, 3)
		if parts.size() >= 4:
			host_changed.emit(int(parts[1]), parts[2], parts[3])
	elif text.begins_with("MEMBERS:"):
		var parts := text.split(":", true, 2)
		if parts.size() >= 3:
			var json := JSON.new()
			if json.parse(parts[2]) == OK and json.data is Array:
				members_listed.emit(parts[1], json.data)


func _handle_leave_room(from_sid: int, payload: PackedByteArray) -> void:
	var text := payload.get_string_from_utf8()
	if text.begins_with("OK:"):
		var parts := text.split(":", false, 2)
		if parts.size() >= 3:
			room_left.emit(parts[1], int(parts[2]))
	elif text.begins_with("LEAVE:"):
		var parts := text.split(":", false, 3)
		if parts.size() >= 4 and int(parts[1]) != session_id:
			member_left.emit(int(parts[1]), parts[2], parts[3])


func _handle_room_broadcast(from_sid: int, payload: PackedByteArray) -> void:
	# payload: [sender u64][room_len u8][room][data]
	if payload.size() < 9:
		return
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	buf.data_array = payload
	var sender := buf.get_u64()
	var room_len := buf.get_8()
	if payload.size() < 9 + room_len:
		return
	# ⚠️ 用 slice 切片取房间名与数据（原因同上；end 排他）
	var room := payload.slice(9, 9 + room_len).get_string_from_utf8()
	var data := payload.slice(9 + room_len)
	room_data.emit(sender, room, data)


func _handle_list_rooms(payload: PackedByteArray) -> void:
	var json := JSON.new()
	if json.parse(payload.get_string_from_utf8()) == OK:
		rooms_listed.emit(json.data.get("rooms", []))
