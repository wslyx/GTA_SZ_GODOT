extends Node3D
class_name Rider
##
## 玩家角色本体 —— 对应原版 src/city-rider.ts（久岐忍）。
##
## 原版要点（city-rider.ts + city-world.ts:500）：
##   · 锚点随步行位置摆放，yaw 平滑跟随**移动方向**（不是视线方向，
##     视线由相机自己管），速率 exp(−dt·16)
##   · idle/walk/run 三段步态按速度加权混合，并用「一个步态周期的步幅」把
##     播放速度锁到实际移速（phaseClock.speedRatio = speed / 步幅米数），
##     脚底不打滑
##   · 第一人称时整个模型隐藏（setEnabled(false)）
##
## Godot 的 AnimationPlayer 一次只播一个动作，这里用「按速度选段 + 交叉淡入 +
## speed_scale = 实际移速 / 该段标定步速」近似原版的相位锁；分档阈值取原版
## running 权重 ramp（(speed−1.8)/2.2）的中点。
## 步态标定来自 data/characters/manifest.json 的 gait 字段。

const CHARACTER_GLB := "res://data/characters/kuki.glb"
const CHARACTER_NAME := "久岐忍"
## 一个步态周期走过的米数（manifest.gait）：
##   walk: cycleSeconds 1.0    × authoredSpeed 1.0323 = 1.0323 m
##   run : cycleSeconds 0.7333 × authoredSpeed 2.5909 = 1.9000 m
const WALK_STRIDE := 1.032258064516129
const RUN_STRIDE := 1.9
## 走/跑动画的分档速度（原版 running ramp 的中点）
const WALK_RUN_SPLIT := 2.9

## 角色 GLB 的前向轴。MMD 改造模型按 glTF 惯例面朝 +Z；若实机看着背对镜头，
## 把这里换成 CoordinateUtil.ModelForward.MINUS_Z。
var model_forward: int = CoordinateUtil.ModelForward.PLUS_Z

var enabled := false
var ready_ok := false

var _anim: AnimationPlayer
var _clip_idle := ""
var _clip_walk := ""
var _clip_run := ""
var _current := ""


func setup() -> void:
	if ready_ok:
		return
	if not ResourceLoader.exists(CHARACTER_GLB):
		push_warning("[Rider] 缺少角色模型 %s" % CHARACTER_GLB)
		return
	var scene: PackedScene = load(CHARACTER_GLB)
	if scene == null:
		push_warning("[Rider] 角色模型加载失败 %s" % CHARACTER_GLB)
		return
	var inst: Node = scene.instantiate()
	add_child(inst)
	# 接阴影：原版把步行时的骑手网格加进阴影 caster 列表
	GlbLoader.configure_meshes(GlbLoader.meshes_of(inst), true, true)
	# 蒙皮网格的包围盒在动画下会变形，给足剔除余量避免走两步就被裁掉
	for m in GlbLoader.meshes_of(inst):
		m.extra_cull_margin = 5.0

	for c in inst.find_children("*", "AnimationPlayer", true, false):
		_anim = c as AnimationPlayer
		break
	if _anim != null:
		for clip in _anim.get_animation_list():
			var lower := String(clip).to_lower()
			if lower.contains("idle"):
				_clip_idle = clip
			elif lower.contains("walk"):
				_clip_walk = clip
			elif lower.contains("run"):
				_clip_run = clip
		# ⚠️ GLB 导入的动画默认**不循环**：walk 播完一遍（~0.65s，此时速度表刚爬到
		# 6km/h）就冻在最后一帧，看起来就是"腿部动画不播了"。原版是
		# group.start(true) 循环 + ANIMATIONLOOPMODE_CYCLE，这里对齐成线性循环。
		for clip in [_clip_idle, _clip_walk, _clip_run]:
			if clip != "":
				_anim.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
		_current = _clip_idle if _clip_idle != "" else ""
		if _current != "":
			_anim.play(_current)
			_anim.seek(0.0, true)
			_anim.pause()
	else:
		push_warning("[Rider] 角色模型里没有 AnimationPlayer（只有静模）")
	visible = false
	ready_ok = true


## 原版 setEnabled()：步行时显示并继续播动画，其余时间隐藏并暂停
func set_enabled(value: bool) -> void:
	if enabled == value:
		return
	enabled = value
	visible = value
	if _anim == null:
		return
	if value:
		if _current == "":
			_current = _clip_idle
		if _current != "":
			_anim.play(_current, 0.2)
	else:
		_anim.pause()


## 原版 setPose()：位置/朝向 + 按速度选段与锁步
func set_pose(x: float, y: float, z: float, yaw: float, speed: float, dt: float) -> void:
	position = Vector3(x, y, z)
	rotation.y = CoordinateUtil.node_yaw(yaw, model_forward)
	if not enabled or _anim == null:
		return
	var moving := absf(speed) > 0.1
	# 选段：速度 < 分档 → walk（步幅锁速）；≥ 分档 → run；静止 → idle
	var target := _clip_idle
	var speed_scale := 1.0
	if moving:
		if speed < WALK_RUN_SPLIT or _clip_run == "":
			if _clip_walk != "":
				target = _clip_walk
				# 原版 phaseClock.speedRatio = speed / 步幅；等价成动画播放速率
				speed_scale = clampf(speed / WALK_STRIDE, 0.4, 2.4)
		else:
			target = _clip_run
			speed_scale = clampf(speed / RUN_STRIDE, 0.4, 2.4)
	if target == "":
		return
	if _current != target:
		_current = target
		_anim.play(target, 0.25)
	_anim.speed_scale = speed_scale
