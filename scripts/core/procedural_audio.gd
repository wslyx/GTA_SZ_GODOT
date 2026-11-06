extends Node
class_name ProceduralAudio
##
## 程序化音频 —— 对应原版 src/city-audio.ts。
##
## 原版**完全没有音频文件**，全部实时合成：
##   链路        master → 压缩器 → analyser → destination，effects / music 双总线
##   音源        48Hz 正弦（电机基频）+ 98Hz 三角波（谐波）
##               + 3 条 LCG 白噪声（滚动 / 风 / 打滑），分别过
##               lowpass 680、bandpass 480、bandpass 1750
##   BGM         原创 16 小节 72 BPM《海湾晚风》，每 100ms 提前 0.35s 排程
##   触发        impact(speed)（行人碰撞，间隔 ≥0.09s）、explosion()（导弹）、
##               cue('arrival'|'engage'|'cancel'|'horn')
##   解锁        首次 pointerdown / keydown 后启动；页面隐藏自动 suspend
##
## Godot 用 AudioStreamGenerator 做等价实现：每帧填充缓冲区，
## 电机/风噪声频率与包络照搬原版的数值，BGM 用同一套 72 BPM 音序。

const SAMPLE_RATE := 22050.0
const BUFFER_LENGTH := 0.15

## 电机与噪声（原版数值）
const MOTOR_SINE_HZ := 48.0
const MOTOR_TRI_HZ := 98.0
const ROLL_LOWPASS_HZ := 680.0
const WIND_BANDPASS_HZ := 480.0
const SLIP_BANDPASS_HZ := 1750.0
const IMPACT_MIN_GAP := 0.09

## BGM《海湾晚风》：72 BPM，16 小节
const BGM_BPM := 72.0
const BGM_BARS := 16
## 音阶（半音偏移，A 小调五声）
const BGM_SCALE := [0, 3, 5, 7, 10]
const BGM_ROOT_HZ := 220.0

var player: AudioStreamPlayer
var bgm_player: AudioStreamPlayer
var bgm_stream: AudioStreamWAV
var playback: AudioStreamGeneratorPlayback
var enabled := true

var speed := 0.0
var throttle := 0.0
var slipping := false

var _phase_motor := 0.0
var _phase_tri := 0.0
var _lcg := 1
## 滤波器状态池：0 滚动 / 1 风 / 2 打滑（原版）＋
## 3 城市底噪 / 4 分区特色声 / 5 雨声（GTA化 §4.2 扩展）
var _noise_state := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
var _impact_gap := 0.0
var _bgm_sample := 0
var _bgm_phase := 0.0
var _explosion_env := 0.0
var _horn_env := 0.0
var _unlocked := false

# --- 环境音 / 警笛 / 枪声（GTA化 §4.2）---
## 当前分区（architecture_materials 的 district 名）：决定特色环境声
var _amb_kind := "core"
var _raining := false
## 警笛强度 0–1（wanted → main_game 每帧喂，内部平滑）
var _siren := 0.0
var _siren_target := 0.0
var _siren_lfo := 0.0     ## 滑频周期相位（wail）
var _siren_tone := 0.0    ## 警笛音调相位
var _amb_lfo := 0.0       ## 海浪起伏 LFO
var _hum_phase := 0.0     ## 工业电力嗡鸣相位
var _gun_env := 0.0       ## 枪声包络（快衰减）
## 音频批量合成缓冲（性能优化方案 §2.3）：复用，避免每帧分配
var _frame_buf := PackedVector2Array()

## 播放偏好（原版 city-audio.ts 的 AudioPreferences，暂停页可调）：
##   effects = 车辆 / 环境音量，music = 海湾晚风 · BGM 音量
var effects_volume := 0.6
var music_volume := 0.4
var muted := false


func _ready() -> void:
	player = AudioStreamPlayer.new()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = SAMPLE_RATE
	gen.buffer_length = BUFFER_LENGTH
	player.stream = gen
	player.volume_db = -6.0
	add_child(player)

	# 海湾晚风 · BGM：预渲染循环（见 prepare_bgm），独立播放器 —— 对应原版
	# WebAudio 的 music 总线（city-audio.ts 的 this.music gain 节点）
	bgm_player = AudioStreamPlayer.new()
	bgm_player.volume_db = -80.0
	add_child(bgm_player)

	# —— 母线压缩器（原版 city-audio.ts:43）——
	#   master → compressor → analyser → destination
	#   threshold −17 dB / knee 16 / ratio 3 / attack .01s / release .2s
	# Godot 对应 AudioEffectCompressor，挂在 Master 总线（bus 0）末端。
	# ⚠️ knee 在 Godot 的压缩器里没有对应项（它是软拐点宽度），AudioEffectCompressor
	# 只有 threshold/ratio/attack/release/gain；硬拐点比原版稍"硬"，其余四项一致。
	# ⚠️ 单位不统一：Godot 是 attack_us（微秒）与 release_ms（毫秒）
	#（实跑抓到：Invalid assignment of property 'attack' —— 该属性名不存在）。
	# 原版 .01 s = 10000 µs；原版 .2 s = 200 ms。
	var comp := AudioEffectCompressor.new()
	comp.threshold = -17.0
	comp.ratio = 3.0
	comp.attack_us = 10000.0    ## 原版 .01 s
	comp.release_ms = 200.0     ## 原版 .2 s
	comp.gain = 0.0
	AudioServer.add_bus_effect(0, comp)


## 窗口失焦 / 回到前台 —— 原版 city-audio.ts:25 的 visibilitychange：
##   document.hidden → context.suspend()；回到前台且是被可见性挂起的 → resume()
## Godot 里等价的是 APPLICATION_FOCUS_OUT / _IN 通知（切走窗口时把合成停下来，
## 避免后台继续跑 22kHz 的逐样本合成空耗 CPU）。
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			_suspend_by_focus(true)
		NOTIFICATION_APPLICATION_FOCUS_IN:
			_suspend_by_focus(false)


func _suspend_by_focus(hidden: bool) -> void:
	if hidden:
		if player != null:
			player.stream_paused = true
		if bgm_player != null:
			bgm_player.stream_paused = true
		return
	# 只有"当时确实在播"的才恢复 —— 否则会把尚未 unlock 的播放器提前启动
	if player != null and _unlocked:
		player.stream_paused = false
	if bgm_player != null and bgm_player.stream != null:
		bgm_player.stream_paused = false


func unlock() -> void:
	if _unlocked or not enabled:
		return
	player.play()
	playback = player.get_stream_playback()
	if bgm_player != null and bgm_player.stream != null:
		bgm_player.play()
	_unlocked = playback != null


## 线性同余白噪声（原版用 LCG）
func _noise() -> float:
	_lcg = (int(_lcg) * 1664525 + 1013904223) & 0xFFFFFFFF
	return float(_lcg) / 2147483648.0 - 1.0


## 一阶低通 / 带通近似（用两个一阶滤波串出带通）
func _filter(idx: int, input: float, cutoff: float) -> float:
	var alpha := clampf(TAU * cutoff / SAMPLE_RATE, 0.0, 1.0)
	_noise_state[idx] += alpha * (input - _noise_state[idx])
	return _noise_state[idx]


func set_drive_state(p_speed: float, p_throttle: float, p_slipping: bool) -> void:
	speed = p_speed
	throttle = p_throttle
	slipping = p_slipping


## 行人碰撞 / 撞击音
func impact(strength: float) -> void:
	if _impact_gap > 0.0:
		return
	_impact_gap = IMPACT_MIN_GAP
	_explosion_env = clampf(strength * 0.6, 0.15, 1.0)


## 爆炸音（导弹 / 炮弹）
func explosion() -> void:
	_explosion_env = 1.0


## 提示音：arrival / engage / cancel / horn
func cue(name: String) -> void:
	match name:
		"horn":
			_horn_env = 1.0
		"arrival", "engage", "cancel":
			_horn_env = 0.5


# ---------------------------------------------------------------------------
# 环境音 / 警笛 / 枪声（GTA化 §4.2）—— 全程序化合成，零音频文件
# ---------------------------------------------------------------------------

## 分区环境声：main_game 每帧（或按需）喂当前分区名与雨情。
## 未知分区名按 core 处理。
func set_world_audio(district: String, raining: bool) -> void:
	_amb_kind = district
	_raining = raining


## 警笛强度 0–1（wanted_system.siren_level() → main_game 每帧喂）
func set_siren(v: float) -> void:
	_siren_target = clampf(v, 0.0, 1.0)


## 枪声：白噪爆破 + 快衰减（半自动连点也各自触发，不做间隔限制 ——
## 射速上限 750rpm = 80ms，天然不会糊成一片）
func gunshot() -> void:
	_gun_env = 1.0


func _process(delta: float) -> void:
	if not enabled:
		if player.playing:
			player.stop()
		if bgm_player != null and bgm_player.playing:
			bgm_player.stop()
		return
	if not _unlocked:
		if Input.is_anything_pressed():
			unlock()
		return
	if playback == null:
		return

	_impact_gap = maxf(0.0, _impact_gap - delta)
	_explosion_env = maxf(0.0, _explosion_env - delta * 1.6)
	_horn_env = maxf(0.0, _horn_env - delta * 2.2)
	# 枪声衰减要快（爆破感来自短包络）
	_gun_env = maxf(0.0, _gun_env - delta * 9.0)
	# 警笛强度平滑进场/退场（避免出入视野时咔哒）
	_siren = lerpf(_siren, _siren_target, minf(1.0, delta * 2.5))

	# BGM 音量 = music_volume × 静音（原版 applyPreferences 的 music 总线）
	if bgm_player != null:
		var mv := 0.0 if muted else clampf(music_volume, 0.0, 1.0)
		bgm_player.volume_db = linear_to_db(maxf(mv, 0.0001))

	var ev := 0.0 if muted else clampf(effects_volume, 0.0, 1.0)
	var frames := playback.get_frames_available()
	if frames <= 0:
		return
	# 批量合成（性能优化方案 §2.3）：此前逐样本 push_frame，每帧几百次
	# 跨 GDScript/引擎边界的调用 + 同样多的 Vector2 装箱；改为先填一块
	# 复用的 PackedVector2Array 再一次性 push_buffer。静音时连 _sample()
	# 都不跑（相位停走无听感影响），直接推静音帧。
	if _frame_buf.size() != frames:
		_frame_buf.resize(frames)
	if ev <= 0.0005:
		_frame_buf.fill(Vector2.ZERO)
	else:
		for i in frames:
			# 只算一次采样再同时给左右声道。
			# 之前写 Vector2(_sample(), _sample())：_sample() 内部会推进 _bgm_sample
			# 与各个相位，调两次等于每帧推进两个采样点 —— BGM 速度翻倍（72→144 BPM），
			# 而且左右声道取到的是两条互不相关的噪声，听感是散开的双声道而非同一声源。
			var s := _sample() * ev
			_frame_buf[i] = Vector2(s, s)
	playback.push_buffer(_frame_buf)


func _sample() -> float:
	# --- 电机：正弦基频 + 三角波谐波 ---
	var rpm_scale := 0.6 + clampf(absf(speed) / 30.0, 0.0, 2.0)
	_phase_motor = fposmod(_phase_motor + MOTOR_SINE_HZ * rpm_scale / SAMPLE_RATE, 1.0)
	_phase_tri = fposmod(_phase_tri + MOTOR_TRI_HZ * rpm_scale / SAMPLE_RATE, 1.0)
	var motor := sin(_phase_motor * TAU) * (0.16 + throttle * 0.22)
	var tri := (absf(_phase_tri * 4.0 - 2.0) - 1.0) * 0.06 * (0.4 + throttle)

	# --- 三条噪声 ---
	var n := _noise()
	var roll := _filter(0, n, ROLL_LOWPASS_HZ) * clampf(absf(speed) / 26.0, 0.0, 1.0) * 0.10
	var wind := _filter(1, n, WIND_BANDPASS_HZ) * clampf(absf(speed) / 40.0, 0.0, 1.0) * 0.055
	var slip := 0.0
	if slipping:
		slip = _filter(2, n, SLIP_BANDPASS_HZ) * 0.14

	# --- 环境底噪（GTA化 §4.2）：城市嗡鸣 + 分区特色 + 雨 ---
	# 城市基础层：远距离车流/人声的低频混合（所有分区都有，音量很低）
	var city := _filter(3, n, 220.0) * 0.016
	var amb := 0.0
	match _amb_kind:
		"waterfront":
			# 海浪：低通噪声 × 慢 LFO 起伏（~8s 一个浪头）
			_amb_lfo = fposmod(_amb_lfo + 0.12 / SAMPLE_RATE, 1.0)
			amb = _filter(4, n, 320.0) * (0.55 + 0.45 * sin(_amb_lfo * TAU)) * 0.045
		"industrial":
			# 电力嗡鸣：55Hz 正弦 + 低频噪声（变压器的听感）
			_hum_phase = fposmod(_hum_phase + 55.0 / SAMPLE_RATE, 1.0)
			amb = (sin(_hum_phase * TAU) * 0.5 + _filter(4, n, 140.0) * 0.7) * 0.030
		"old_town":
			# 街市：中频细碎人声/店铺感
			amb = _filter(4, n, 500.0) * 0.020
		"finance":
			# 商务区：比基础层略高一点的宽频风噪（玻璃幕墙区空旷回响感）
			amb = _filter(4, n, 900.0) * 0.012
		_:
			amb = 0.0
	var rain := 0.0
	if _raining:
		rain = _filter(5, n, 3000.0) * 0.030

	# --- 警笛：滑频 wail（700±240Hz，0.16Hz 周期）---
	var siren := 0.0
	if _siren > 0.001:
		_siren_lfo = fposmod(_siren_lfo + 0.16 / SAMPLE_RATE, 1.0)
		var sf := 700.0 + 240.0 * sin(_siren_lfo * TAU)
		_siren_tone = fposmod(_siren_tone + sf / SAMPLE_RATE, 1.0)
		siren = sin(_siren_tone * TAU) * 0.05 * _siren

	# --- BGM：已改为预渲染循环（prepare_bgm → bgm_player），不再逐样本合成 ---

	# --- 一次性事件 ---
	var boom := _noise() * _explosion_env * 0.5
	var gun := _noise() * _gun_env * 0.30
	var horn := sin(_bgm_phase * TAU * 2.0) * _horn_env * 0.12
	_bgm_phase = fposmod(_bgm_phase + 320.0 / SAMPLE_RATE, 1.0)

	return clampf(motor + tri + roll + wind + slip
		+ city + amb + rain + siren + boom + gun + horn, -1.0, 1.0)


## 把一整段《海湾晚风》循环离线渲染成 16-bit WAV，交给独立播放器循环播放。
##
## **为什么必须预渲染**：BGM 原本在 `_sample()` 里逐样本合成，而
## AudioStreamGenerator 每帧要补上"实时消耗"的样本数 —— 帧率越低每帧补得越多，
## 合成成本又推高帧时长，正反馈把自动驾驶的帧率钉死在 60~80
## （实测 autoperf：关掉音频 12.1ms → 5.1ms）。原版把 BGM 交给 WebAudio 节点图
## 实时合成，游戏线程零成本；Godot 没有节点图，等价做法就是**离线烘一段循环**。
##
## 成本：22050Hz × 53.3s ≈ 1.18M 样本，一次性 ~1.5s，在启动加载画面里完成。
func prepare_bgm() -> void:
	if bgm_stream != null:
		return
	var sr := int(SAMPLE_RATE)
	var spb := maxi(1, sr * 60 / BGM_BPM)          ## 每拍样本数
	var total := BGM_BARS * 4 * spb                ## 16 小节 × 4 拍
	var data := PackedByteArray()
	data.resize(total * 2)
	for i in total:
		var v: float = _bgm_note_at(i, spb)
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32000.0))
	bgm_stream = AudioStreamWAV.new()
	bgm_stream.format = AudioStreamWAV.FORMAT_16_BITS
	bgm_stream.mix_rate = sr
	bgm_stream.stereo = false
	bgm_stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	bgm_stream.loop_begin = 0
	bgm_stream.loop_end = total
	bgm_stream.data = data
	if bgm_player != null:
		bgm_player.stream = bgm_stream
	print("[Audio] 海湾晚风 BGM 已预渲染：%d 样本（%.1fs 循环）" % [total, float(total) / float(sr)])


## 与 _bgm() 同一套数学，但用**绝对样本下标**（不推进任何状态），
## 便于离线渲染出无缝循环。
func _bgm_note_at(i: int, spb: int) -> float:
	var beat := float(i) / float(spb)
	var note := int(beat) % BGM_SCALE.size()
	var bar := int(beat / 4) % BGM_BARS
	var octave := 1.0 + float(bar % 3) * 0.12
	var semis: int = BGM_SCALE[note] + (12 if bar % 4 >= 2 else 0)
	var freq := BGM_ROOT_HZ * octave * pow(2.0, float(semis) / 12.0)
	var beat_pos := float(i % spb) / float(spb)
	var env := exp(-beat_pos * 3.2) * 0.8
	return sin(float(i) * TAU * freq / float(spb * 60 / BGM_BPM)) * env


## 《海湾晚风》：72 BPM，每拍换音，五声音阶游走
func _bgm() -> float:
	var samples_per_beat := int(SAMPLE_RATE * 60.0 / BGM_BPM)
	var beat := _bgm_sample / maxi(1, samples_per_beat)
	if beat >= BGM_BARS * 4:
		_bgm_sample = 0
		beat = 0
	var note := int(beat) % BGM_SCALE.size()
	# 每 4 拍换一次根音，制造 16 小节循环感
	var bar := int(beat / 4) % BGM_BARS
	var octave := 1.0 + float(bar % 3) * 0.12
	var semis: int = BGM_SCALE[note] + (12 if bar % 4 >= 2 else 0)
	var freq := BGM_ROOT_HZ * octave * pow(2.0, float(semis) / 12.0)

	var beat_pos := float(_bgm_sample % maxi(1, samples_per_beat)) / float(samples_per_beat)
	# 拨弦式包络：起音快、衰减慢
	var env := exp(-beat_pos * 3.2) * 0.8
	_bgm_sample += 1
	return sin(float(_bgm_sample) * TAU * freq / SAMPLE_RATE) * env


func diagnostics() -> Dictionary:
	return {"enabled": enabled, "unlocked": _unlocked, "speed": speed,
			"sampleRate": SAMPLE_RATE, "bgmBar": int(_bgm_sample / (SAMPLE_RATE * 60.0 / BGM_BPM) / 4.0) % BGM_BARS}
