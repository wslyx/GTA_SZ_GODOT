extends RefCounted
class_name BakeHeightFix
##
## B-2 修正高度网格烘焙 —— 把视觉地形三角形栅格化成 8m 均匀网格，
## 写成 data/city/height-fix/height-grid.bin，HeightField 优先采样它。
##
## 物理与视觉从此**同源**：体检（§八）发现的坡地浮空/下陷一次性消灭。
## 排除项：桥面（桥下要通行，由原生 bridge_lift 层继续负责）、雨面覆盖层、
## 楼体（只收地面材质）。
##
## 触发：godot --path . -- --bake-heights（main_game 接线，跑完自动退出）
## 网格：east -6800..6800 / north -2620..2620，8m 步长 → 1701×656 ≈ 111 万格
## 文件：'SHF1' + cols/rows u32 + east0/north0/step f32 + heights f32（-9999=无视觉地面）

const MAP_HEALTH_SCRIPT := preload("res://scripts/dev/map_health.gd")
const OUT_PATH := "res://data/city/height-fix/height-grid.bin"
const E0 := -6800.0
const N0 := -2620.0
const STEP := 8.0
const COLS := 1701
const ROWS := 656


static func bake(world: CityWorld) -> Dictionary:
	var mh = MAP_HEALTH_SCRIPT.new()
	mh.collect_visual_ground(world, true)
	var tris: PackedFloat32Array = mh._tris
	var tri_total := tris.size() / 9
	print("[HeightFix] 视觉地面三角形 %d，开始栅格化 %dx%d" % [tri_total, COLS, ROWS])

	var heights := PackedFloat32Array()
	heights.resize(COLS * ROWS)
	heights.fill(-9999.0)

	var i := 0
	var covered := 0
	var skipped_steep := 0
	while i < tri_total:
		var b := i * 9
		var ax := tris[b]; var az := tris[b + 1]; var ay := tris[b + 2]
		var bx := tris[b + 3]; var bz := tris[b + 4]; var by := tris[b + 5]
		var cx := tris[b + 6]; var cz := tris[b + 7]; var cy := tris[b + 8]
		# ---- 竖直面剔除（关键）----
		# 山体贴片/挡土墙/裙边都是**竖直**三角形：XZ 投影几乎退化成线，
		# 一个格点落在上面就会取到墙顶高度 —— 实测因此在南山边缘留下
		# 孤立的 +122m / +81m 尖刺，车开过去直接被抛上天。
		# 高度场本身只能表达"俯视可见的地面"，竖直面一律不属于地面。
		# 判据：竖直高差 > 6 × 最长水平边（≈ 坡角 > 80°）。
		var lh := maxf(sqrt((bx - ax) * (bx - ax) + (bz - az) * (bz - az)),
			maxf(sqrt((cx - bx) * (cx - bx) + (cz - bz) * (cz - bz)),
				sqrt((ax - cx) * (ax - cx) + (az - cz) * (az - cz))))
		var dy := maxf(ay, maxf(by, cy)) - minf(ay, minf(by, cy))
		if lh < 0.05 or dy > 6.0 * lh:
			skipped_steep += 1
			i += 1
			continue
		var minx := minf(ax, minf(bx, cx)) - E0
		var maxx := maxf(ax, maxf(bx, cx)) - E0
		var minz := minf(az, minf(bz, cz)) - N0
		var maxz := maxf(az, maxf(bz, cz)) - N0
		var gx0 := maxi(0, int(floor(minx / STEP)) - 1)
		var gx1 := mini(COLS - 1, int(ceil(maxx / STEP)) + 1)
		var gz0 := maxi(0, int(floor(minz / STEP)) - 1)
		var gz1 := mini(ROWS - 1, int(ceil(maxz / STEP)) + 1)
		for gx in range(gx0, gx1 + 1):
			var px := E0 + gx * STEP
			for gz in range(gz0, gz1 + 1):
				var pz := N0 + gz * STEP
				var d := (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
				if absf(d) < 1e-9:
					continue
				var l1 := ((bz - cz) * (px - cx) + (cx - bx) * (pz - cz)) / d
				var l2 := ((cz - az) * (px - cx) + (ax - cx) * (pz - cz)) / d
				var l3 := 1.0 - l1 - l2
				if l1 < 0.0 or l2 < 0.0 or l3 < 0.0:
					continue
				var y := l1 * ay + l2 * by + l3 * cy
				var cell := gz * COLS + gx
				var cur := heights[cell]
				if cur < -9000.0 or y > cur:
					if cur < -9000.0:
						covered += 1
					heights[cell] = y
		i += 1
	print("[HeightFix] 覆盖 %d / %d 格（%.0f%%），剔除竖直面 %d / %d 三角形" % [
		covered, COLS * ROWS, 100.0 * covered / (COLS * ROWS), skipped_steep, tri_total])

	# ---- 去尖刺：孤立高点（比 8 邻域最高点还高 6m 以上）压回邻域 ----
	# 竖直面剔除后仍会漏网的（斜裙边、贴片接缝）在这里兜底。真实地形在 8m
	# 尺度上不会孤立高出邻域 6m，所以这条规则只吃掉伪影，不动真陡坡。
	var despiked := 0
	var src := heights.duplicate()
	for gz in range(1, ROWS - 1):
		for gx in range(1, COLS - 1):
			var cell := gz * COLS + gx
			var v := src[cell]
			if v < -9000.0:
				continue
			var nb_max := -9999.0
			var nb_n := 0
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					if dx == 0 and dz == 0:
						continue
					var w := src[cell + dz * COLS + dx]
					if w > -9000.0:
						nb_n += 1
						if w > nb_max:
							nb_max = w
			if nb_n >= 5 and v - nb_max > 6.0:
				heights[cell] = nb_max
				despiked += 1
	print("[HeightFix] 去尖刺 %d 个格点" % despiked)


	# ---- 写文件（StreamPeerBuffer = 小端，与 HeightField._load_height_fix 对齐）----
	var dir := DirAccess.open("res://")
	if dir != null and not dir.dir_exists("data/city/height-fix"):
		dir.make_dir_recursive("data/city/height-fix")
	var sp := StreamPeerBuffer.new()
	sp.big_endian = false
	sp.put_32(0x31464853)            # "SHF1"（LE）
	sp.put_32(COLS)
	sp.put_32(ROWS)
	sp.put_float(E0)
	sp.put_float(N0)
	sp.put_float(STEP)
	for v in heights:
		sp.put_float(v)
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "写文件失败 " + OUT_PATH}
	f.store_buffer(sp.data_array)
	f.close()

	# ---- 与当前高度场的差异统计（每 4 格抽样）----
	var hf = world.height_field
	var diff1 := 0
	var sampled := 0
	var worst := 0.0
	var worst_cell := Vector2i.ZERO
	for gz in range(0, ROWS, 2):
		for gx in range(0, COLS, 2):
			var cell := gz * COLS + gx
			var v := heights[cell]
			if v < -9000.0:
				continue
			sampled += 1
			var hfv: float = hf.height_at(E0 + gx * STEP, N0 + gz * STEP)
			var dd := absf(v - hfv)
			if dd > 1.0:
				diff1 += 1
			if dd > worst:
				worst = dd
				worst_cell = Vector2i(gx, gz)
	print("[HeightFix] 与现高度场差>1m 的格：%d / %d（%.1f%%），最差 %.1fm @(%d,%d)" % [
		diff1, sampled, 100.0 * diff1 / maxi(1, sampled), worst,
		E0 + worst_cell.x * STEP, N0 + worst_cell.y * STEP])
	return {"ok": true, "covered": covered, "cells": COLS * ROWS,
		"diff_gt1m": diff1, "sampled": sampled, "path": OUT_PATH}
