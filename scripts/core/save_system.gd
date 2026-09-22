extends Node
##
## 存档（autoload: SaveSystem）。
##
## 原版用 localStorage 三个键：
##   shenchengji-city-life-v1        —— {version:1, cash, completed[]}，送达结算时写
##   shenchengji-graphics-quality-v1 —— 画质档位
##   shenchengji.audio.v1            —— 音频开关
## 另有一个更早的 IndexedDB 存档（src/save.ts，库 shenchengji-v1 / store saves / key main），
## 只有旧的 world.ts 使用，main.ts 并未引用。这里保留其数据结构以便完整复刻，
## 落在 user:// 下的同名文件中。
##
## 注意：原版只在"送达结算成功"时写 city-life 存档，不是每帧写；这里保持一致。

const KEY_CITY_LIFE := "shenchengji-city-life-v1.json"
const KEY_GRAPHICS := "shenchengji-graphics-quality-v1.json"
const KEY_AUDIO := "shenchengji.audio.v1.json"
const KEY_FULL_STATE := "shenchengji-save-v1.json"
const KEY_CAREER := "shenchengji-career-v1.json"
const KEY_STORY := "shenchengji-story-v1.json"

signal city_life_saved()
signal full_state_saved()


func _ready() -> void:
	load_audio()
	# 画质存档由 GraphicsQuality._ready 主动拉取（load_graphics_quality），
	# 这里不调 —— 本文件不引用 GraphicsQuality，避免 autoload 循环引用。


func _write(key: String, d: Dictionary) -> bool:
	var f := FileAccess.open("user://" + key, FileAccess.WRITE)
	if f == null:
		push_warning("[SaveSystem] 无法写入 %s" % key)
		return false
	f.store_string(JSON.stringify(d, "  "))
	f.close()
	return true


func _read(key: String) -> Dictionary:
	var path := "user://" + key
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	return {}


func has(key: String) -> bool:
	return FileAccess.file_exists("user://" + key)


# ---------------------------------------------------------------------------
# city-life：与原版写入时机一致（送达结算）
# ---------------------------------------------------------------------------

func save_city_life() -> void:
	_write(KEY_CITY_LIFE, {
		"version": 1,
		"cash": GameState.cash,
		"completed": GameState.completed_rides,
	})
	city_life_saved.emit()


func load_city_life() -> void:
	var d := _read(KEY_CITY_LIFE)
	if d.is_empty():
		return
	if int(d.get("version", 1)) != 1:
		return
	GameState.cash = int(d.get("cash", GameState.cash))
	GameState.completed_rides.clear()
	for r in d.get("completed", []):
		GameState.completed_rides.append(str(r))


# ---------------------------------------------------------------------------
# 完整状态（含旧城小活）
# ---------------------------------------------------------------------------

func save_full_state() -> bool:
	var d := GameState.to_dict()
	var ok := _write(KEY_FULL_STATE, d)
	if ok:
		full_state_saved.emit()
	return ok


func load_full_state() -> bool:
	var d := _read(KEY_FULL_STATE)
	if d.is_empty():
		return false
	var err: Array = []
	if not GameState.validate_save(d, err):
		push_warning("[SaveSystem] 存档校验未通过: %s" % str(err))
		return false
	GameState.from_dict(d)
	return true


## 所有存档文件名。
##
## 两个限制叠在一起，注意写法：
##
## 1) `const SAVE_KEYS := PackedStringArray([...])` **非法** —— 会报
##    "Assigned value for constant isnt a constant expression"。
##    Godot 只对**值类型**（Vector2 / Vector3 / Color / Basis …）的构造做常量折叠，
##    Packed*Array 的构造不是常量表达式。
##
## 2) 退回普通数组字面量也还不够：`for k in [A, B]` 遍历**无类型数组**时，
##    循环变量 k 是 Variant，`var p := "user://" + k` 会报
##    "Cannot infer the type of p variable"。
##
## 解法：const 里放普通数组，遍历前在**函数体内**转成 PackedStringArray ——
## 构造函数在函数里是完全合法的，而且元素类型是 String，循环变量也就有了类型。
## （不要用 `for k: String in ...` 这种带类型标注的循环变量写法，语法兼容性不确定。）
const SAVE_KEYS := [
	KEY_CITY_LIFE, KEY_FULL_STATE, KEY_GRAPHICS, KEY_AUDIO, KEY_CAREER, KEY_STORY,
]


func erase_all() -> void:
	var keys := PackedStringArray(SAVE_KEYS)
	for k in keys:
		var p := "user://" + k
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


# ---------------------------------------------------------------------------
# 画质 / 音频
# ---------------------------------------------------------------------------

## 画质存档 v2：档位 + 玩家逐项覆盖（overrides）。
## v1 只有 tier —— 旧存档照常读取，overrides 取默认空表。
## 只放行白名单里的键与类型，防止手改存档把脏数据灌进渲染管线。
##
## 注意：这里**不能引用 GraphicsQuality**（autoload 循环引用会让两边都编译失败，
## "Identifier not declared"）。本文件只负责读写与白名单校验，把解析结果原样
## 返回，由 GraphicsQuality._ready 主动拉取并写回自己。
const GRAPHICS_OVERRIDE_KEYS := {
	"scaling": "float", "aa": "int", "shadows": "int",
	"ao": "bool", "bloom": "bool", "lamps": "int",
	"tree_budget": "int", "fps": "bool",
}


func save_graphics_quality(tier: String, overrides: Dictionary = {}) -> void:
	_write(KEY_GRAPHICS, {"version": 2, "tier": tier, "overrides": overrides})


## 读取画质存档，返回 {"tier": String, "overrides": Dictionary}（已白名单过滤）。
func load_graphics_quality() -> Dictionary:
	var out := {"tier": "medium", "overrides": {}}
	var d := _read(KEY_GRAPHICS)
	if d.is_empty():
		return out
	var tier := str(d.get("tier", "medium"))
	if ["low", "medium", "high"].has(tier):
		out["tier"] = tier
	var raw = d.get("overrides", {})
	if raw is Dictionary:
		var clean: Dictionary = {}
		for k in raw:
			if not GRAPHICS_OVERRIDE_KEYS.has(str(k)):
				continue
			var v = raw[k]
			match str(GRAPHICS_OVERRIDE_KEYS[str(k)]):
				"int":
					if v is int or v is float:
						clean[str(k)] = int(v)
				"float":
					if v is int or v is float:
						clean[str(k)] = float(v)
				"bool":
					if v is bool:
						clean[str(k)] = bool(v)
		out["overrides"] = clean
	return out


func save_audio(enabled: bool) -> void:
	_write(KEY_AUDIO, {"version": 1, "enabled": enabled})


func load_audio() -> void:
	var d := _read(KEY_AUDIO)
	if d.is_empty():
		return
	GameState.audio_enabled = bool(d.get("enabled", true))


# ---------------------------------------------------------------------------
# 职业 / 故事进度（供 career_system.gd、story_system.gd 存取）
# ---------------------------------------------------------------------------

func save_section(key: String, payload: Dictionary) -> void:
	_write(key, payload)


func load_section(key: String) -> Dictionary:
	return _read(key)


func career_key() -> String:
	return KEY_CAREER


func story_key() -> String:
	return KEY_STORY
