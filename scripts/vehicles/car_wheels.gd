extends RefCounted
class_name CarWheels
##
## 车轮滚动与转向动画 —— 移植原版 city-world.ts update() 里的轮子逻辑：
##
##   wheelSpin += speed * dt / wheelRadius;
##   for (m of carMeshes) if (m.name.startsWith('wheel_')) {
##       m.rotation.x = wheelSpin;
##       m.rotation.y = m.name.match(/wheel_[lr]f_/) ? -steer : 0;
##   } else if (m.name.startsWith('brake_')) m.rotation.set(0, -steer, 0);
##
## 加载时（city-world.ts init）原版还给每个轮网设了 pivot：
##   m.setPivotPoint(Vector3.FromArray(metadata.wheelCentresGltf[q[1]]))
##
## Godot 的 MeshInstance3D 没有 pivot 概念（旋转永远绕节点原点，而本 GLB 的
## 26 个节点全部是平级、无局部变换，几何直接烘在车体坐标里），所以这里用
## 等价公式每帧重写节点 transform：
##   transform = T(轴心) · R · T(−轴心) · 原始transform
##
## 旋转都在 **glTF 模型空间**（车头 −Z、右侧 +X、上 +Y），与原版给 Babylon
## 写 rotation 的空间一致（Babylon 的 (1,1,-1) 根镜像在装载器根上，不影响
## 子树内的局部旋转值），因此符号逐字照抄原版：
##   滚动  绕局部 X，值 = wheelSpin（前进为正）
##   转向  前轮（lf/rf）绕局部 Y，值 = −steer（右转时前轮指向右）
##   刹车盘 brake_*（本车只有前轮）绕局部 Y，值 = −steer，不滚动
##
## wheelRadius 与 wheelCentresGltf 读 data/city/vehicle-manifest.json
## （与原版 fetch('/city/vehicle-manifest.json') 同一份文件），缺省时回退常量。

const MANIFEST_PATH := "res://data/city/vehicle-manifest.json"

## vehicle-manifest.json 的 wheelRadius（hero 车，米）
const DEFAULT_WHEEL_RADIUS := 0.4404016423105851
## vehicle-manifest.json 的 wheelCentresGltf（glTF 模型空间，键 = 角位）
const DEFAULT_CENTRES := {
	"lf": Vector3(-0.8563922643661499, 0.4406319558620453, -1.4311549663543701),
	"rf": Vector3(0.8574297428131104, 0.4406318962574005, -1.4291903972625732),
	"lr": Vector3(-0.8625556230545044, 0.4406314492225647, 1.781485676765442),
	"rr": Vector3(0.8618454933166504, 0.4406314492225647, 1.781485676765442),
}

const CORNERS := ["lf", "rf", "lr", "rr"]


class WheelPart:
	var node: MeshInstance3D
	var centre: Vector3     ## 该角位轮网轴心（glTF 模型空间）
	var front: bool         ## 前轮（lf/rf）随方向盘偏转
	var spins: bool         ## wheel_* 滚动；brake_* 只转向不滚动
	var original: Transform3D


var wheel_radius := DEFAULT_WHEEL_RADIUS
var _parts: Array[WheelPart] = []
var part_count := 0


## 在车辆模型树下收集 wheel_* / brake_* 网格并读取清单参数。
func setup(car_root: Node) -> void:
	_parts.clear()
	part_count = 0
	if car_root == null:
		return
	_load_manifest()
	var stack: Array = [car_root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			var seg := String(mi.name).to_lower().split("_")
			if seg.size() >= 2 and (seg[0] == "wheel" or seg[0] == "brake") \
					and CORNERS.has(seg[1]):
				var p := WheelPart.new()
				p.node = mi
				p.centre = _centres[seg[1]]
				p.front = seg[1] == "lf" or seg[1] == "rf"
				p.spins = seg[0] == "wheel"
				p.original = mi.transform
				_parts.append(p)
		for c in n.get_children():
			stack.append(c)
	part_count = _parts.size()


## 每帧应用滚动角 spin（弧度，累计值）与转向角 steer（弧度，物理转角）。
func apply(spin: float, steer: float) -> void:
	for p in _parts:
		var b := Basis.IDENTITY
		if p.front:
			# 原版 rotation.y = -steer（右转 steer>0 → 前轮指向右侧 +X）
			b = Basis(Vector3.UP, -steer)
		if p.spins:
			# 原版 rotation.x = wheelSpin（ Babylon 的 yaw-pitch-roll 合成
			# 顺序 R = Ry·Rx·Rz：先滚转、再叠加转向）
			b = b * Basis(Vector3.RIGHT, spin)
		# T(P)·R·T(−P)·M0 —— 等价于原版 setPivotPoint 后再旋转
		p.node.transform = Transform3D(b, p.centre) \
			* Transform3D(Basis.IDENTITY, -p.centre) * p.original


var _centres := {
	"lf": DEFAULT_CENTRES["lf"],
	"rf": DEFAULT_CENTRES["rf"],
	"lr": DEFAULT_CENTRES["lr"],
	"rr": DEFAULT_CENTRES["rr"],
}


## 读 vehicle-manifest.json 的 wheelRadius / wheelCentresGltf（缺省回退常量）
func _load_manifest() -> void:
	if not FileAccess.file_exists(MANIFEST_PATH):
		return
	var f := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if f == null:
		return
	var data: Variant = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		return
	var dict := data as Dictionary
	if dict.get("wheelRadius") is float:
		wheel_radius = float(dict["wheelRadius"])
	var wc: Variant = dict.get("wheelCentresGltf")
	if wc is Dictionary:
		var wd := wc as Dictionary
		for k in CORNERS:
			var v: Variant = wd.get(k)
			if v is Array and (v as Array).size() == 3:
				var a := v as Array
				_centres[k] = Vector3(float(a[0]), float(a[1]), float(a[2]))
