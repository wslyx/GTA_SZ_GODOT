extends Control
class_name NetRadar
## 深城纪多人战局 · 雷达小地图
##
## 以本地玩家为中心的俯视方位盘：战局内其他玩家按相对位置绘制，
## 朝向固定为世界 -Z 向上（北向），超出量程的点钳制在圆环边缘（空心）。
## 数据由 NetSession 每帧提供（get_tree 遍历化身即可，无需额外同步通道）。

## 量程（米）：超过该距离的玩家显示在圆环边缘
const RANGE_M := 60.0
## 本地点颜色
const SELF_COLOR := Color(1, 1, 1, 0.95)
## 盘面底色与描边
const DISC_COLOR := Color(0.08, 0.10, 0.14, 0.55)
const RING_COLOR := Color(0.55, 0.62, 0.75, 0.6)

## 数据提供者：返回 [{pos: Vector2(东西, 南北偏移, 米), color: Color, name: String}]
var provider: Callable = Callable()


func _ready() -> void:
	custom_minimum_size = Vector2(132, 132)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	# 重绘节流到 ~30fps：雷达不需要满帧率
	_frame += 1
	if _frame % 2 == 0:
		queue_redraw()

var _frame := 0


func _draw() -> void:
	var center := size / 2.0
	var radius := minf(center.x, center.y) - 4.0

	# 盘面与刻度环
	draw_circle(center, radius, DISC_COLOR)
	draw_arc(center, radius, 0.0, TAU, 48, RING_COLOR, 1.5, true)
	draw_arc(center, radius * 0.5, 0.0, TAU, 32, RING_COLOR * Color(1, 1, 1, 0.4), 1.0, true)
	# 北向标记（-Z 为上）
	draw_string(ThemeDB.fallback_font, center + Vector2(-3, -radius + 12), "N",
		HORIZONTAL_ALIGNMENT_CENTER, -1, 10, RING_COLOR)

	# 本地玩家中心点
	draw_circle(center, 3.0, SELF_COLOR)

	if not provider.is_valid():
		return
	var entries: Array = provider.call()
	for e in entries:
		var offset: Vector2 = e.pos   # (x=东, y=南)，米
		var dist := offset.length()
		var clamped := dist > RANGE_M
		var dir := offset.normalized() if dist > 0.001 else Vector2.ZERO
		var plot := center + dir * minf(dist, RANGE_M) / RANGE_M * (radius - 6.0)
		var color: Color = e.color
		if clamped:
			# 超出量程：边缘空心点
			draw_arc(plot, 3.0, 0.0, TAU, 12, color, 1.5, true)
		else:
			draw_circle(plot, 3.0, color)
		# 近距离显示昵称首字符
		if dist <= RANGE_M * 0.5:
			var nm: String = str(e.name)
			if nm.length() > 0:
				draw_string(ThemeDB.fallback_font, plot + Vector2(5, 3),
					nm.substr(0, 2), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, color * Color(1, 1, 1, 0.85))
