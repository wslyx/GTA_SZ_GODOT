extends Node
## 全自动复现测试：加载完整主世界（默认 CAR 模式，与用户环境一致）→ 连接服务器 →
## 监控主线程帧间隔，定位"连接后画面卡住"。
## 运行: godot --headless --path <项目> res://tests_e2e/auto_drive_connect_test.gd -- 127.0.0.1 端口

var t := 0.0
var _phase := "loading"
var _frame_max_delta := 0.0
var _connect_t := -1.0
var _main_game: MainGame = null


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var host: String = args[0] if args.size() >= 1 else "127.0.0.1"
	var port: int = int(args[1]) if args.size() >= 2 else 20820
	print("[auto] 阶段: 加载完整主世界 scenes/main.tscn ...")
	var main_scene = load("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main_scene)
	set_meta("host", host)
	set_meta("port", port)


func _process(delta: float) -> void:
	t += delta
	if delta > _frame_max_delta:
		_frame_max_delta = delta
	if delta > 1.0:
		print("[auto] ⚠ 帧卡顿 %.2f 秒 @ t=%.1f 阶段=%s" % [delta, t, _phase])

	match _phase:
		"loading":
			# 等主世界异步构建完成（bind_local_player 在 _build_world 里调用）
			if NetSession._local_player != null:
				_main_game = _find_main_game()
				var mode_name := "CAR"
				if _main_game:
					mode_name = str(_main_game.mode)
				print("[auto] 主世界就绪: MainGame=%s mode=%s local_player=%s" % [
					_main_game != null, mode_name,
					NetSession._local_player.name])
				_phase = "connecting"
				var host: String = get_meta("host")
				var port: int = get_meta("port")
				print("[auto] 调用 join_session %s:%d（模拟用户 F9，默认 CAR 模式）..." % [host, port])
				NetSession.join_session(host, port, "自动测试")
				_connect_t = t
		"connecting":
			if NetSession.in_session:
				print("[auto] ✓ 已加入战局 @ t=%.1f —— 进入 20 秒主线程监控" % t)
				_phase = "monitoring"
			elif t > _connect_t + 30.0:
				print("[auto] ✗ 30 秒未加入战局，放弃")
				get_tree().quit()
		"monitoring":
			if t > _connect_t + 20.0:
				print("[auto] === 监控结束 ===")
				print("[auto] in_session=%s room='%s' rtt=%d remotes=%d" % [
					NetSession.in_session, NetSession.current_room,
					NetSession.last_rtt, NetSession._remotes.size()])
				print("[auto] 期间最大帧间隔: %.3f 秒 %s" % [
					_frame_max_delta,
					"（正常，无阻塞）" if _frame_max_delta < 1.0 else "（存在长阻塞帧！主线程曾卡死）"])
				print("[auto] 节点数: %d" % get_tree().get_node_count())
				get_tree().quit()


func _find_main_game() -> MainGame:
	for node in get_tree().root.get_children():
		if node is MainGame:
			return node
	return null
