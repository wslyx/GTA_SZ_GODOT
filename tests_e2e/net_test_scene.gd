extends Node
## 自动化连接测试场景：加载完整项目 autoload 后，用正式 NetSession 代码连接服务器。
## 与无头探针（godot_udp_probe.gd）的区别：本场景走 autoload 的正式连接路径。
## 运行: godot --headless --path <项目> res://tests_e2e/net_test_scene.tscn -- 127.0.0.1 20730

var t := 0.0
var _done := false
var _last_state := ""


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var host: String = args[0] if args.size() >= 1 else "127.0.0.1"
	var port: int = int(args[1]) if args.size() >= 2 else 20730
	print("[net-test] 场景就绪 autoload NetSession 存在=%s" % str(NetSession != null))
	# 绑定移动模式提供者（与 main_game 行为一致）
	NetSession.bind_mode_provider(func() -> String: return "walk")
	print("[net-test] 调用 join_session %s:%d 昵称=场景测试员" % [host, port])
	NetSession.join_session(host, port, "场景测试员")


func _process(delta: float) -> void:
	t += delta
	# 每 3 秒报一次状态变化
	var st := "in_session=%s room='%s' rtt=%d" % [
		NetSession.in_session, NetSession.current_room, NetSession.last_rtt]
	if st != _last_state:
		_last_state = st
		print("[net-test] t=%.1f %s" % [t, st])
	if t > 15.0 and not _done:
		_done = true
		if NetSession.in_session:
			print("[net-test] ✓ 测试通过：已加入战局")
		else:
			print("[net-test] ✗ 测试失败：15 秒未加入战局（状态: %s）" % st)
		get_tree().quit()
