extends RefCounted
class_name DataLoader
##
## 统一的 `res://data/**` 读取 + 内存缓存。
##
## 原版是 fetch() 拿 JSON；Godot 里对应 FileAccess。城市数据集有几个大文件
## （navigation.json 1.2MB、building-signs.json 1.8MB、canopy-trees.json 1.2MB、
## planting.json 2.6MB），同一份数据会被多个子系统查询，所以这里做引用缓存，
## 避免重复解析。缓存的是已解析对象，调用方**不要就地修改**。

const DATA_ROOT := "res://data"

static var _cache: Dictionary = {}
static var _text_cache: Dictionary = {}
static var _missing: Dictionary = {}


static func path_for(rel: String) -> String:
	if rel.begins_with("res://"):
		return rel
	if rel.begins_with("/"):
		rel = rel.substr(1)
	# 原版资源路径形如 "/city/city.json"，映射到 res://data/city/city.json
	return DATA_ROOT + "/" + rel


static func exists(rel: String) -> bool:
	return FileAccess.file_exists(path_for(rel))


## 读取并解析 JSON。解析失败返回 null 并记录一次警告（同一路径只警告一次）。
##
## 返回类型显式写成 Variant（JSON 结构是运行时才知道的）。
## 也正因为如此，调用方**必须**显式标注类型或使用 `=`：
##     var d: Dictionary = DataLoader.json(...)     ✓
##     var d := DataLoader.json(...)                ✗ 推断失败，Godot 会报
##                                                  "Cannot infer the type of d variable"
static func json(rel: String) -> Variant:
	var p := path_for(rel)
	if _cache.has(p):
		return _cache[p]
	if _missing.has(p):
		return null
	if not FileAccess.file_exists(p):
		_missing[p] = true
		push_warning("[DataLoader] 缺少数据文件: %s" % p)
		return null
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		_missing[p] = true
		push_warning("[DataLoader] 无法打开: %s" % p)
		return null
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed == null:
		_missing[p] = true
		push_warning("[DataLoader] JSON 解析失败: %s" % p)
		return null
	_cache[p] = parsed
	return parsed


## 原始文本
static func text(rel: String) -> String:
	var p := path_for(rel)
	if _text_cache.has(p):
		return _text_cache[p]
	if not FileAccess.file_exists(p):
		push_warning("[DataLoader] 缺少文件: %s" % p)
		return ""
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	_text_cache[p] = t
	return t


## 解析失败时返回默认值。
##
## **不要**写成 `DataLoader.json(x) or {}` —— GDScript 的 `or` 返回的是**布尔值**
## （不像 JS/TS 的 `||` 会返回操作数），那样会得到 true/false，
## 赋给 Dictionary 变量时报
## "Trying to assign value of type bool to a variable of type Dictionary"。
## 用下面这两个带类型的助手代替。
static func json_dict(rel: String) -> Dictionary:
	var v = json(rel)
	return v if v is Dictionary else {}


static func json_arr(rel: String) -> Array:
	var v = json(rel)
	return v if v is Array else []


## 读整个二进制文件（heights.bin / relief-mesh.bin）
static func bytes(rel: String) -> PackedByteArray:
	var p := path_for(rel)
	if not FileAccess.file_exists(p):
		push_warning("[DataLoader] 缺少二进制文件: %s" % p)
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(p)


static func clear_cache() -> void:
	_cache.clear()
	_text_cache.clear()
	_missing.clear()


## 供诊断面板使用
static func cache_stats() -> Dictionary:
	return {"json_entries": _cache.size(), "text_entries": _text_cache.size(), "missing": _missing.size()}
