extends Node
##
## 静态游戏内容表（原版散落在 state.ts / world.ts / city-life.ts / city-bamboo-cafe.ts）。
## 这里集中放"不会在运行时变化"的内容常量，供 HUD、玩法系统与地图共用。
##
## 全部坐标都是**数据坐标** (east, north)。取用后必须经 CoordinateUtil.to_world()。

# ---------------------------------------------------------------------------
# 旧城小活：分拣 + 配送（原 state.ts / world.ts）
# ---------------------------------------------------------------------------

enum WorkStatus { AVAILABLE, SORTING, HAULING, DELIVERED, PAID }

## 包裹类型：0 电子产品 / 1 冷藏食品 / 2 易碎物品
##
## 不加 `: Array[Dictionary]` 类型标注 —— const 上带 Array[T] 标注有兼容风险
## （Godot 的常量表达式对引用类型容器的支持比值类型保守）。
## 代价是取元素时是 Variant，调用方需要显式标注类型，例如
## `var is_correct: bool = PACKAGES[i]["type"] == category`。
const PACKAGES := [
	{"name": "蓝牙耳机", "detail": "电子产品 · 防压", "type": 0},
	{"name": "玻璃杯", "detail": "易碎物品 · 轻放", "type": 2},
	{"name": "鲜牛奶", "detail": "冷藏食品 · 优先", "type": 1},
	{"name": "手机充电器", "detail": "电子产品 · 防潮", "type": 0},
	{"name": "冰鲜水果", "detail": "冷藏食品 · 优先", "type": 1},
	{"name": "陶瓷碗", "detail": "易碎物品 · 轻放", "type": 2},
	{"name": "小音箱", "detail": "电子产品 · 防压", "type": 0},
	{"name": "酸奶", "detail": "冷藏食品 · 优先", "type": 1},
	{"name": "相框", "detail": "易碎物品 · 轻放", "type": 2},
]

const ITEM_PRICES := {"raincoat": 60, "mattress": 260, "bicycle": 480}

const ITEMS := {
	"raincoat": {"name": "一件好雨衣", "description": "备着就安心。运货时更稳，操作失误不再减少质量奖励。"},
	"mattress": {"name": "舒服一点的床垫", "description": "回房间就能看到新床品和一盏暖灯。明天开始，多留十五分钟给自己。"},
	"bicycle": {"name": "二手通勤车", "description": "车子不新，刹车很稳。在街上按 B 骑行，少花一点时间在路上。"},
}

## 配送检查点（原 world.ts CHECKPOINTS）。
## 同上：不带 Array[Vector2] 标注，保持普通 const 数组。
const CHECKPOINTS := [Vector2(-2, 25), Vector2(2, 49), Vector2(-1, 83)]

## 街区交互点（原 world.ts PLACES）
const PLACES := {
	"work": {"pos": Vector2(6.8, 6), "label": "何志 · 接日结"},
	"used": {"pos": Vector2(-6.9, 30), "label": "旧物新生活"},
	"home": {"pos": Vector2(-6.9, 54), "label": "青禾公寓 · 回家"},
	"friend": {"pos": Vector2(-5.6, 8), "label": "林夏 · 聊聊"},
	"finish": {"pos": Vector2(-1, 86), "label": "装车点 · 结算"},
	"food": {"pos": Vector2(-6.8, 4), "label": "阿芳 · 晚饭"},
}

# ---------------------------------------------------------------------------
# 街区布局常量（原 world.ts）
# ---------------------------------------------------------------------------

const STREET_X_LIMIT := Vector2(-5.55, 5.55)
const ZONE_Z_LIMIT := Vector2(1.5, 98.0)
const ROOM_X_LIMIT := Vector2(-5.4, 5.4)
const ROOM_Z_LIMIT := Vector2(2.0, 98.0)

## 会挡路的固定手推车
const PARKED_TROLLEYS := [Vector2(5, 7), Vector2(4.8, 10), Vector2(-5, 43)]

const WALK_SPEED := 3.0
const RUN_SPEED := 5.0
const BIKE_SPEED := 7.5
const HAUL_SPEED := 2.8

# ---------------------------------------------------------------------------
# 月白 · 女仆咖啡馆（原 city-bamboo-cafe.ts）
# ---------------------------------------------------------------------------

const CAFE := {
	"id": "bamboo-cafe",
	"name": "月白 · 女仆咖啡馆",
	"subtitle": "MAISON LUNE · COFFEE & PATISSERIE",
	"site": Vector2(-5088, -1304),
	"heading": 2.605,
	"arrival": Vector2(-5101.077262119414, -1281.992 ),
	"road_yaw": 1.0346452212862278,
	"footprint": {"width": 18.0, "depth": 14.0, "height": 4.2, "floor": 0.24, "patio_depth": 5.0},
	## 局部坐标（x 右、z 前）
	"staff": [
		{"id": "zhixia", "name": "知夏", "role": "主理人", "local": Vector2(-2.25, -3.45), "height": 1.96,
		 "line": "欢迎回来。今天想喝点热的，还是冰的？"},
		{"id": "wangshu", "name": "望舒", "role": "咖啡师", "local": Vector2(5.65, 5.0), "height": 1.93,
		 "line": "手冲刚闷蒸完，再等一分钟就好。"},
		{"id": "xiaolan", "name": "小岚", "role": "侍应", "local": Vector2(4.0, -0.2), "height": 1.95,
		 "line": "靠窗那张桌子能看到湾里的船。"},
	],
	"entry_local": Vector2(0, -6.15),
	"door_local": Vector2(0, -7.8),
	"menu_local": Vector2(2.3, 2.2),
	"menu": [
		{"name": "海盐拿铁", "price": 32},
		{"name": "手冲", "price": 38},
		{"name": "草莓千层", "price": 46},
		{"name": "可露丽", "price": 24},
	],
}

# ---------------------------------------------------------------------------
# 路名与路型
# ---------------------------------------------------------------------------

## 未命名路的判定（原 city-road-names.ts）
const UNNAMED_ROAD_PATTERN := "^(支路|未命名(道路)?|道路|无名路|unnamed|road)?$"

## 路型 → 中文类型名，用于"两邻路名附近 · 类型"式命名
const ROAD_KIND_LABEL := {
	"motorway": "高速",
	"trunk": "城市快速路",
	"primary": "主路",
	"secondary": "次干道",
	"tertiary": "支路",
	"residential": "街巷",
	"service": "内部道路",
	"unclassified": "街巷",
	"living_street": "街巷",
	"footway": "步行道",
	"path": "小径",
	"cycleway": "自行车道",
}

## 地图标注优先级（原 city-map.ts）
const ROAD_LABEL_PRIORITY := {
	"motorway": 90, "trunk": 80, "primary": 70, "secondary": 55,
	"tertiary": 40, "residential": 20, "unclassified": 18,
	"service": 12, "living_street": 14,
}

# ---------------------------------------------------------------------------
# 光照模式 / 地面片区名
# ---------------------------------------------------------------------------

enum LightMode { DAY, SUNSET, NIGHT }

const AREA_LABELS := {
	Vector2(-5146, -1216): "南山 · 后海",
	Vector2(1564.66, 42.75): "福田 · CBD",
}

## 时钟读数（原 city-hud.ts）
const CLOCK := {
	"day": "14:20",
	"night": "20:10",
	"default": "18:25",
}


func work_status_name(s: int) -> String:
	match s:
		WorkStatus.AVAILABLE: return "待接单"
		WorkStatus.SORTING: return "分拣中"
		WorkStatus.HAULING: return "配送中"
		WorkStatus.DELIVERED: return "已送达"
		WorkStatus.PAID: return "已结算"
	return "未知"


func item_name(id: String) -> String:
	return ITEMS.get(id, {}).get("name", id)
