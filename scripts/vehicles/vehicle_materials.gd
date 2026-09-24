extends RefCounted
class_name VehicleMaterials
##
## 主角车辆材质标定 —— 对应原版 src/city-vehicle-materials.ts 的
## `refineHeroVehicleMaterials`。
##
## 原版注释写得很清楚：几何 / UV / 牌照 / 灯罩都保留授权资产原样，
## **只**把车漆与玻璃等几个材质在**线性空间**里重新标定。
##
## ⚠️ 为什么必须做：`data/city/car.glb` 里 `carpaint` 的 baseColorFactor 是
## `(0.7255, 0.098, 0.1451)`，而 glTF 规范要求 baseColorFactor 是**线性**值。
## 原版把 `#B91925` 做 sRGB→线性后再赋给 `albedoColor`，得到
## `(0.485, 0.0097, 0.0185)`；两者相比，绿/蓝分量差了 **约 8 倍** ——
## 直接吃 GLB 自带值，车漆就从深枣红变成明艳的亮红。
##
## 玻璃同理：原版是 `albedo (.018,.021,.024)` + `alpha .72` 的**半透明近黑**玻璃，
## 而 GLB 自带的 `car_glass` 是 `(0.3035,0.41,0.4845)`、**不透明**、metallic .5 ——
## 于是整块后窗渲染成一大片浅蓝镜面。
##
## 各项数值逐条对照原版（左：原版 TS；右：本文件）：
##
## | 材质 | 原版 | 本文件 |
## |---|---|---|
## | carpaint | albedo #B91925→linear / metal .25 / rough .30 / clearCoat 1.0·.12 | 同 |
## | car_glass | albedo (.018,.021,.024) alpha .72 / metal 0 / rough .12 | 同 |
## | car_chrome | (.58,.62,.65) / metal 1 / rough .2 | 同 |
## | wheel_alloy | (.38,.43,.47) / metal .92 / rough .27 | 同 |
## | wheel_rubber | (.021,.024,.027) / rough .84 | 同 |
##
## 另外原版给车漆与轮胎各贴了一张 128×128 的程序化"微颗粒"法线
## （`paintGrain` strength .055 重复 28 次、`rubberGrain` strength .2 重复 14 次），
## 用的是同一个 LCG 种子 47919 —— 这里也照同一个种子复算。

## 原版 grain() 的 LCG 参数与种子
const GRAIN_SEED := 47919
const GRAIN_SIZE := 128
const PAINT_GRAIN_VARIATION := 5
const PAINT_GRAIN_REPEATS := 28.0
const PAINT_GRAIN_STRENGTH := 0.055
const RUBBER_GRAIN_VARIATION := 28
const RUBBER_GRAIN_REPEATS := 14.0
const RUBBER_GRAIN_STRENGTH := 0.2

## #B91925 的**线性**值（原版 `Color3.FromHexString('#B91925').toLinearSpace()`）
const PAINT_ALBEDO := Color(0.485, 0.0097, 0.0185)
## 玻璃近黑 + alpha .72（原版 material.alpha 与 albedoColor 是两个字段）
const GLASS_ALBEDO := Color(0.018, 0.021, 0.024, 0.72)
const CHROME_ALBEDO := Color(0.58, 0.62, 0.65)
const ALLOY_ALBEDO := Color(0.38, 0.43, 0.47)
const RUBBER_ALBEDO := Color(0.021, 0.024, 0.027)

var changed: Array[String] = []


## 对整棵车辆节点树按材质名套用标定。返回被改动的材质名列表。
func apply(car_root: Node) -> Array[String]:
	changed.clear()
	if car_root == null:
		return changed
	var seen := {}
	var paint_grain := _grain("hero-paint", PAINT_GRAIN_VARIATION)
	var rubber_grain := _grain("hero-rubber", RUBBER_GRAIN_VARIATION)
	for mat in _materials_of(car_root):
		var name := _base_name(mat.resource_name)
		var rid := mat.get_instance_id()
		if seen.has(rid):
			continue
		match name:
			"carpaint":
				mat.albedo_color = PAINT_ALBEDO
				mat.metallic = 0.25
				mat.roughness = 0.30
				mat.metallic_specular = 1.0
				# 原版 clearCoat：intensity 1、roughness .12（Babylon 默认 IOR 1.5）
				mat.clearcoat_enabled = true
				mat.clearcoat = 1.0
				mat.clearcoat_roughness = 0.12
				if paint_grain != null:
					mat.normal_enabled = true
					mat.normal_texture = paint_grain
					mat.normal_scale = PAINT_GRAIN_STRENGTH
					mat.uv1_scale = Vector3(PAINT_GRAIN_REPEATS, PAINT_GRAIN_REPEATS, 1.0)
			"car_glass":
				mat.albedo_color = GLASS_ALBEDO
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				mat.metallic = 0.0
				mat.roughness = 0.12
				mat.metallic_specular = 0.88
				# 半透明物体不自投影，避免车顶出现一条自遮挡黑边
				mat.cull_mode = BaseMaterial3D.CULL_BACK
			"car_chrome":
				mat.albedo_color = CHROME_ALBEDO
				mat.metallic = 1.0
				mat.roughness = 0.2
			"wheel_alloy":
				mat.albedo_color = ALLOY_ALBEDO
				mat.metallic = 0.92
				mat.roughness = 0.27
			"wheel_rubber":
				mat.albedo_color = RUBBER_ALBEDO
				mat.roughness = 0.84
				if rubber_grain != null:
					mat.normal_enabled = true
					mat.normal_texture = rubber_grain
					mat.normal_scale = RUBBER_GRAIN_STRENGTH
					mat.uv1_scale = Vector3(RUBBER_GRAIN_REPEATS, RUBBER_GRAIN_REPEATS, 1.0)
			_:
				continue
		seen[rid] = true
		changed.append(name)
	print("[VehicleMaterials] 已标定 %s" % str(changed))
	return changed


## 原版 material.name.replace(/\.\d+$/,'')：GLB 里同名材质会带 `.001` 后缀
func _base_name(n: String) -> String:
	var dot := n.rfind(".")
	if dot <= 0:
		return n
	return n.substr(0, dot)


## 原版 grain()：LCG 生成 128×128 的"平法线 + 微小扰动"贴图。
## 数据是 R/G 在 128 附近抖动、B 恒为 255 —— 就是这个 LCG 的前三个字节。
##
## 注意 Godot 里 B 分量要写满 1.0 才是"无扰动"，所以这里直接写 255。
func _grain(grain_name: String, variation: int) -> ImageTexture:
	var data := PackedByteArray()
	data.resize(GRAIN_SIZE * GRAIN_SIZE * 3)
	var seed := GRAIN_SEED
	var i := 0
	while i < data.size():
		# 与 TS 的 Math.imul(seed,1664525)+1013904223 逐位等价。
		# GDScript 的 int 是 64 位：seed < 2^32，乘 1664525 约 2^52.7，仍在
		# double 的精确整数区间（< 2^53）内，所以这里不会丢低位。
		seed = int((seed * 1664525 + 1013904223) & 0xFFFFFFFF)
		data[i] = clampi(128 + int(round(((seed & 255) / 255.0 - 0.5) * variation)), 0, 255)
		data[i + 1] = clampi(128 + int(round((((seed >> 8) & 255) / 255.0 - 0.5) * variation)), 0, 255)
		data[i + 2] = 255
		i += 3
	# 注意：Godot 4 没有 Image.set_data_from_packed_byte_array，
	# 从字节建图要用 Image.create_from_data。
	var img := Image.create_from_data(GRAIN_SIZE, GRAIN_SIZE, false,
		Image.FORMAT_RGB8, data)
	var tex := ImageTexture.create_from_image(img)
	tex.resource_name = grain_name
	return tex


## 收集一棵子树里所有 BaseMaterial3D（去重由调用方按 instance_id 做）
func _materials_of(root: Node) -> Array[BaseMaterial3D]:
	var out: Array[BaseMaterial3D] = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mesh: Mesh = null
		if n is MeshInstance3D:
			mesh = (n as MeshInstance3D).mesh
		elif n is MultiMeshInstance3D:
			var mmi := n as MultiMeshInstance3D
			if mmi.multimesh != null:
				mesh = mmi.multimesh.mesh
		if mesh != null:
			for s in mesh.get_surface_count():
				var mat: Material = mesh.surface_get_material(s)
				if mat == null and n is MeshInstance3D:
					mat = (n as MeshInstance3D).get_active_material(s)
				if mat is BaseMaterial3D:
					out.append(mat as BaseMaterial3D)
		for c in n.get_children():
			stack.append(c)
	return out
