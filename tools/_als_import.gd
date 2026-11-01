extends Node
##
## 一次性工具：无头重跑 ALS 资产编译（等价于编辑器菜单 Tools → Compile ALS Asset Set）。
##
## 用法：
##   Godot_v4.7.x_console.exe --headless --path . res://tools/_als_import.tscn
##
## ⚠️ 需要 .NET SDK（本机便携版在 D:/PortableSoft/dotnet-sdk-8.0.424-win-x64，
##    用目录里的 godot-cli.bat 启动即可带上 DOTNET_ROOT）。
## 产物：assets/generated/als_v4/compiled/als_animation_set.tres

const BRIDGE := "res://src/Als.Godot/Import/AlsImporterPlugin.cs"


func _ready() -> void:
	# 局部变量不能叫 script —— 与 Node 原生成员重名（体检会报）
	var bridge_script: Script = load(BRIDGE)
	if bridge_script == null or not bridge_script.can_instantiate():
		push_error("[als_import] 无法加载 C# 导入器（GodotALS.csproj 没编译成功？）")
		get_tree().quit(1)
		return
	var bridge: Object = bridge_script.new()
	var ok: bool = bool(bridge.call("RunImport"))
	print("[als_import] RunImport -> %s" % str(ok))
	get_tree().quit(0 if ok else 1)
