shader_type spatial;
// 观察信标光柱 —— 逐行对应原版 city-observer-beacons.ts 里那段内联 GLSL。
//
// 三个实例共用本着色器，只有 opacity / ring 两个 uniform 不同：
//   外层光晕 .20 / 内芯 .82 / 地面圆环 .54（ring=1）
// 颜色是 (0.55, 4.8, 3.10) —— 刻意超过 1，走 HDR 触发 Bloom 的辉光。
//
// 混合与原版对应：Babylon ALPHA_ADD → Godot blend_add；
// disableDepthWrite → depth_draw_never；自写着色器不参与光照 → unshaded。

render_mode blend_add, depth_draw_never, cull_back, unshaded;

uniform float opacity : hint_range(0.0, 1.0) = 0.2;
uniform float pulse = 1.0;
/// 0 = 柱体（按朝向边缘 + 高度渐变），1 = 地面圆环（按到中心的距离）
uniform float ring : hint_range(0.0, 1.0) = 0.0;
uniform vec3 beacon_color = vec3(0.55, 4.8, 3.10);

void fragment() {
	vec3 wpos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 wnormal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// 相机世界位置取 INV_VIEW_MATRIX 的平移列（等价 CAMERA_POSITION_WORLD）
	vec3 eye = INV_VIEW_MATRIX[3].xyz;

	// 正对相机的部分最亮（柱体读作一层薄雾），掠射角淡出
	float facing = abs(dot(wnormal, normalize(eye - wpos)));
	float edge = smoothstep(0.02, 0.8, facing);
	// 上下两端都收口，柱体不会是一根生硬的柱子
	float height_fade = (1.0 - smoothstep(0.48, 1.0, UV.y)) * smoothstep(0.0, 0.025, UV.y);
	// 地面圆环：以 UV 中心为圆心，在半径 .45 处画一圈带宽随屏幕导数自适应的环
	float ring_distance = abs(length(UV - vec2(0.5)) - 0.45);
	float aa = max(fwidth(ring_distance), 0.002);
	float ring_mask = 1.0 - smoothstep(max(0.0, 0.009 - aa), 0.009 + aa, ring_distance);

	float alpha = mix(edge * height_fade, ring_mask, ring) * opacity * pulse;
	ALBEDO = beacon_color;
	ALPHA = clamp(alpha, 0.0, 1.0);
}
