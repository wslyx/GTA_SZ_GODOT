shader_type spatial;
// 雨丝（P2a）—— MultiMesh 每实例一个竖直薄片，逐帧朝向相机（billboard）。
//
// 旧实现是轴对齐 BoxMesh：侧对相机时窄成一条线几乎不可见，正对时又是一根
// 均匀实心白条 —— 修记录里「均匀白色短竖条，像渲染故障」的来源。
// 本 shader：
//   - 纵向渐变：两端淡出、中段亮（速度拉伸的视觉暗示）
//   - 横向软边：不再是一根硬边矩形
//   - 逐条亮度随机（按世界位置哈希），避免 240 条一个亮度
// 下落轨迹保持原版公式（竖直、13+g*8 速度差），这里只管外观。

render_mode blend_mix, depth_draw_opaque, cull_disabled, unshaded;

uniform vec4 tint : source_color = vec4(0.72, 0.80, 0.88, 1.0);
uniform float alpha_scale : hint_range(0.0, 2.0) = 1.0;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// QuadMesh UV：x 横向 0..1，y 纵向 0..1
	float head_tail = smoothstep(0.0, 0.30, UV.y) * smoothstep(1.0, 0.70, UV.y);
	float side = smoothstep(0.0, 0.45, UV.x) * smoothstep(1.0, 0.55, UV.x);
	// 逐条随机：用世界位置量化到条带粒度做哈希（同一实例内恒定）
	vec3 cell = floor(v_world * vec3(2.0, 0.5, 2.0));
	float rnd = fract(sin(dot(cell, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
	float a = tint.a * alpha_scale * head_tail * mix(0.35, 1.0, side) * mix(0.45, 1.0, rnd);
	ALBEDO = tint.rgb;
	ALPHA = clamp(a, 0.0, 1.0);
}
