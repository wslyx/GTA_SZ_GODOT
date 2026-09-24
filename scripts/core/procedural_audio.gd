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

const SAMPLE_RATE := 44100.0
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
var playback: AudioStreamGeneratorPlayback
var enabled := true

var speed := 0.0
var throttle := 0.0
var slipping := false

var _phase_motor := 0.0
var _phase_tri := 0.0
var _lcg := 1
var _noise_state := [0.0, 0.0, 0.0]
var _impact_gap := 0.0
var _bgm_sample := 0
var _bgm_phase := 0.0
var _explosion_env := 0.0
var _horn_env := 0.0
var _unlocked := false

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


func unlock() -> void:
	if _unlocked or not enabled:
		return
	player.play()
	playback = player.get_stream_playback()
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


func _process(delta: float) -> void:
	if not enabled:
		if player.playing:
			player.stop()
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

	var frames := playback.get_frames_available()
	for i in frames:
		# 只算一次采样再同时给左右声道。
		# 之前写 Vector2(_sample(), _sample())：_sample() 内部会推进 _bgm_sample
		# 与各个相位，调两次等于每帧推进两个采样点 —— BGM 速度翻倍（72→144 BPM），
		# 而且左右声道取到的是两条互不相关的噪声，听感是散开的双声道而非同一声源。
		var s := _sample()
		playback.push_frame(Vector2(s, s))


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

	# --- BGM ---
	var bgm := _bgm() * 0.10

	# --- 一次性事件 ---
	var boom := _noise() * _explosion_env * 0.5
	var horn := sin(_bgm_phase * TAU * 2.0) * _horn_env * 0.12
	_bgm_phase = fposmod(_bgm_phase + 320.0 / SAMPLE_RATE, 1.0)

	return clampf(
		(motor + tri + roll + wind + slip + boom + horn) * (0.0 if muted else effects_volume)
		+ bgm * (0.0 if muted else music_volume), -1.0, 1.0)


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
