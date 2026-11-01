extends Node
##
## 材质归属探针：打印指定前缀网格的材质链（override / surface override / mesh 材质），
## 用来定位"谁把这片地面画成了白板"。

const SCENE := "res://scenes/main.tscn"
const PREFIX := "landmark_baypark_concrete"

var main: Node = null
var t := 0.0


func _ready() -> void:
	main = (load(SCENE) as PackedScene).instantiate()
	add_child(main)


var _next_check := 58.0


func _process(delta: float) -> void:
	t += delta
	# 追踪第二份拷贝何时出现：t=58 起每 2s 数一次
	if t >= _next_check and t < 80.0:
		_next_check += 2.0
		var n := _count()
		print("[mat-probe] t=%.0fs concrete 实例数=%d" % [t, n])
		if n >= 2:
			_where()
			get_tree().quit(0)
	if t > 150.0:
		print("[mat-probe] 超时（始终 1 份）")
		get_tree().quit(0)


func _count() -> int:
	var n := 0
	var stk: Array = [main]
	while not stk.is_empty():
		var nd: Node = stk.pop_back()
		for ch in nd.get_children():
			stk.append(ch)
		if nd is MeshInstance3D and String(nd.name) == "landmark_baypark_concrete":
			n += 1
	return n


func _where() -> void:
	var stk: Array = [main]
	while not stk.is_empty():
		var nd: Node = stk.pop_back()
		for ch in nd.get_children():
			stk.append(ch)
		if nd is MeshInstance3D and String(nd.name) == "landmark_baypark_concrete":
			print("[mat-probe] 实例路径=%s" % nd.get_path())


func _report() -> void:
	var w: Node = main.get("world")
	var stk: Array = [w, main]   # world 之外还要扫 main 直挂（找第二份拷贝）
	while not stk.is_empty():
		var n: Node = stk.pop_back()
		for ch in n.get_children():
			stk.append(ch)
		if n is MeshInstance3D and String(n.name).to_lower().begins_with(PREFIX):
			var mi := n as MeshInstance3D
			var xf := mi.global_transform
			print("[mat-probe] %s  origin=%s  basis.x=%s" % [
				mi.name, str(xf.origin), str(xf.basis.x)])
	get_tree().quit(0)


func _matdesc(m: Material) -> String:
	if m == null:
		return "<null>"
	if m is ShaderMaterial:
		var sh: Shader = (m as ShaderMaterial).shader
		return "ShaderMaterial(%s, kind=%s)" % [
			sh.resource_path.get_file() if sh != null else "?",
			str((m as ShaderMaterial).get_shader_parameter("baypark_kind"))]
	if m is BaseMaterial3D:
		var bm := m as BaseMaterial3D
		return "Standard(albedo=%s, tex=%s, vc=%s)" % [str(bm.albedo_color),
			str(bm.albedo_texture != null), str(bm.vertex_color_use_as_albedo)]
	return m.get_class()
