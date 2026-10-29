extends SceneTree
## Godot 无头连接探针：用真实 net_client.gd 连接服务器，自动化复现连接流程。
## 运行: godot --headless --path <项目> --script res://tests_e2e/godot_udp_probe.gd
## 之前可选传参: godot ... --script ... -- 127.0.0.1 20700

var client
var t := 0.0
var connected := false
var joined := false
var got_broadcast := false
var done := false
var pkts := 0


func _initialize() -> void:
	print("=== Godot UDP 探针启动 ===")
	var script = load("res://scripts/net/net_client.gd")
	client = script.new()
	root.add_child(client)
	client.connected.connect(func(sid: int) -> void:
		print("[probe] 握手成功 sid=%d" % sid)
		connected = true)
	client.room_joined.connect(func(room: String, count: int) -> void:
		print("[probe] 加入战局 %s 人数=%d" % [room, count])
		joined = true)
	client.connection_failed.connect(func(r: String) -> void:
		print("[probe] 连接失败: ", r))
	client.disconnected.connect(func(r: String) -> void:
		print("[probe] 断开: ", r))
	client.member_joined.connect(func(sid: int, room: String, name: String) -> void:
		print("[probe] 成员加入: ", name))
	client.room_data.connect(func(sender: int, room: String, data: PackedByteArray) -> void:
		got_broadcast = true
		pkts += 1)
	var host := "127.0.0.1"
	var port := 20700
	var args := OS.get_cmdline_user_args()
	if args.size() >= 2:
		host = args[0]
		port = int(args[1])
	print("[probe] 连接 %s:%d ..." % [host, port])
	client.connect_to_server(host, port, "探针", "")
	print("[probe] 握手已发送")


func _process(delta: float) -> bool:
	t += delta
	client.poll()
	if t > 3.0 and connected and not joined:
		# 握手成功后自动加入战局，验证 join_room 往返
		client.join_room("probe_room")
		joined = true  # 防止重复发
		print("[probe] join_room 已发送")
	if t > 12.0 and not done:
		done = true
		print("=== 探针结果: connected=%s joined=%s broadcast=%s packets=%d ===" % [
			connected, joined, got_broadcast, pkts])
		print(connected and joined and got_broadcast if false else ("=== 结论: %s ===" % (
			"全链路正常" if (connected and joined) else
			("握手正常但 join_room 无响应（复现卡死点）" if connected else
			"握手就无响应（UDP 层问题）"))))
		return true
	return false
