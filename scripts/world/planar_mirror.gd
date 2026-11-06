extends Node3D
##
## 平面镜反射（未完成项清单 B1）—— 水面倒影的根治方案。
##
## 原版（city-bay-water.ts）用 512px Babylon MirrorTexture（refreshRate 3）；
## 本移植此前用 IBL + SSR 近似，建筑倒影不清晰。本节点用 SubViewport +
## 跨水面镜像相机渲染真实倒影，水面着色器按屏幕 UV 投影采样。
##
## 镜像相机的数学（关键决策，见 修复记录 二十八）：
##   真正的镜像视矩阵是**反常矩阵**（det<0），会让整个场景绕序翻转、
##   背面剔除全部出错；Godot 不支持按 pass 翻转 cull。
##   等价解法：用 proper 相机 —— 位置与 forward 取镜像、up 取共轭
##   （basis 列 = (M·bx, −M·by, M·bz)，M = diag(1,−1,1)），渲染出的图
##   = 真镜像图**垂直翻转**，水面着色器采样时把 v 翻回来即可
##   （`vec2(u, 1.0−v)`），绕序安全、与 SCREEN_UV 逐像素对齐。
##
## 性能（2026-11-06 优化，见 docs/性能优化方案.md §2.1）：
##   1. 降频：UPDATE_ALWAYS → 按 update_hz 节流的 UPDATE_ONCE（手动触发）。
##      倒影内容只随玩家移动/昼夜变化，10–15 Hz 足够，GPU 上把整场景
##      重渲染从每帧一次降到每秒十几次。
##   2. 分辨率：跟随画质档 mirror_size（256/384/512）作为**宽度**像素，
##      高度按主视口长宽比推 —— 水面着色器用归一化 SCREEN_UV 采样，
##      绝对分辨率不影响对齐，只影响清晰度。
##   3. 裁剪：镜像相机 cull_mask 跟随主相机并**剔除行人 / 道具层**
##      （倒影里几乎不可感知），水面层照旧剔除防自反射递归。
##   4. 阴影：方向光阴影图由 RenderingServer 每帧全局渲染一次、各视口共享，
##      镜像 pass 不重复渲染方向光阴影；位置光阴影图集已设为 0。
##      （此前注释"含阴影"实为方向光阴影图共享，真正的重复开销是几何 pass。）

## 水面网格专用层位（镜像相机剔除，防自反射递归）
const WATER_LAYER_BIT := 20
## 渲染层（project.godot layer_names）：5=Pedestrians、8=Props
const PEDESTRIAN_LAYER_BIT := 4
const PROPS_LAYER_BIT := 7

## 倒影刷新频率：384px 档（中）10Hz / 512px 档（高）15Hz；低档整关
const UPDATE_HZ_MEDIUM := 10.0
const UPDATE_HZ_HIGH := 15.0

var viewport: SubViewport
var mirror_cam: Camera3D
var mirror_plane_y := -0.25
var enabled := true
## 倒影目标宽度（像素），高度按主视口长宽比推；0 = 旧模式 0.5× 主视口
var mirror_px := 512
var update_hz := UPDATE_HZ_HIGH
var frame_skip := 1
var _frame := 0
var _acc := 0.0
var _last_size := Vector2i.ZERO


func setup(plane_y: float) -> void:
	mirror_plane_y = plane_y
	viewport = SubViewport.new()
	viewport.name = "MirrorViewport"
	# 降频手动触发：初始 DISABLED，首次 update_mirror 到节拍才 UPDATE_ONCE 渲一帧
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport.handle_input_locally = false
	viewport.gui_disable_input = true
	viewport.audio_listener_enable_3d = false
	viewport.positional_shadow_atlas_size = 0   # 位置光阴影不进镜像 pass
	add_child(viewport)
	mirror_cam = Camera3D.new()
	mirror_cam.name = "MirrorCamera"
	# 剔除水面层位（防递归）+ 行人/道具层（倒影中不可感知，省几何 pass）
	mirror_cam.cull_mask = 0xFFFFF & ~((1 << WATER_LAYER_BIT) \
		| (1 << PEDESTRIAN_LAYER_BIT) | (1 << PROPS_LAYER_BIT))
	viewport.add_child(mirror_cam)


func get_texture() -> Texture2D:
	return viewport.get_texture() if viewport != null else null


func set_quality(p: Dictionary) -> void:
	# 与 SSR 同档：中/高档开，低档关（低档雨天由 lighting_director 的 SSR
	# 兜底逻辑负责，这里不做雨天特例 —— 档位切换重建见 set_quality 调用链）
	enabled = bool(p.get("ssr", false))
	var px := int(p.get("mirror_size", 512))
	if px > 0:
		mirror_px = px
	# 档位联动刷新率：小图低频、大图高频（倒影是低频内容，10–15Hz 无感）
	update_hz = UPDATE_HZ_MEDIUM if mirror_px <= 384 else UPDATE_HZ_HIGH
	if viewport != null:
		viewport.render_target_update_mode = (
			SubViewport.UPDATE_DISABLED if not enabled else viewport.render_target_update_mode)
	_acc = 0.0
	_frame = 0


func update_mirror(main_cam: Camera3D, delta: float = 0.016) -> void:
	if viewport == null or mirror_cam == null:
		return
	if not enabled or main_cam == null:
		return
	_frame += 1
	if frame_skip > 1 and _frame % frame_skip != 0:
		return

	# 节流：不到节拍只推进相机参数，不触发渲染。
	# 相机变换每帧照常更新，保证触发那一帧的镜像视角是新鲜的。
	_acc += delta
	if _acc < 1.0 / update_hz:
		return
	_acc = 0.0

	# SubViewport 尺寸：宽度 = mirror_px，高度按主视口长宽比
	# （水面着色器用归一化 SCREEN_UV 采样，分辨率不参与对齐）
	var vp := main_cam.get_viewport()
	if vp != null:
		var full: Vector2i = vp.get_visible_rect().size
		var want := Vector2i.ZERO
		if mirror_px > 0 and full.x > 0:
			want = Vector2i(
				maxi(64, mirror_px) & ~1,
				maxi(64, int(round(mirror_px * float(full.y) / float(full.x)))) & ~1)
		else:
			want = Vector2i(
				maxi(64, int(full.x * 0.5)) & ~1,
				maxi(64, int(full.y * 0.5)) & ~1)
		if want != _last_size:
			viewport.size = want
			_last_size = want

	# 投影参数与主相机一致
	mirror_cam.fov = main_cam.fov
	mirror_cam.near = main_cam.near
	mirror_cam.far = main_cam.far
	# cull_mask 跟随主相机（新增图层自动进倒影），再叠加固定剔除项
	var exclude := (1 << WATER_LAYER_BIT) | (1 << PEDESTRIAN_LAYER_BIT) | (1 << PROPS_LAYER_BIT)
	mirror_cam.cull_mask = main_cam.cull_mask & ~exclude

	# 镜像变换：位置跨水面反射；basis 列 = (M·bx, −M·by, M·bz)
	# （M = diag(1,−1,1)：各列先翻 y 分量，up 列再取负 —— proper 化，
	#   渲染结果 = 真镜像垂直翻转，由水面着色器采样时翻回）
	var xf := main_cam.global_transform
	var b := xf.basis
	var mb := Basis(
		Vector3(b.x.x, -b.x.y, b.x.z),
		Vector3(-b.y.x, b.y.y, -b.y.z),
		Vector3(b.z.x, -b.z.y, b.z.z))
	var o := xf.origin
	var mt := Transform3D(
		mb,
		Vector3(o.x, 2.0 * mirror_plane_y - o.y, o.z))
	mirror_cam.global_transform = mt

	# 手动触发一帧渲染（UPDATE_ONCE 赋值即标记 dirty，本帧末渲染一次）
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func diagnostics() -> Dictionary:
	return {
		"mirrorEnabled": enabled,
		"mirrorSize": _last_size,
		"mirrorPlaneY": mirror_plane_y,
		"mirrorHz": update_hz,
	}
