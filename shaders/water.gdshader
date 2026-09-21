shader_type spatial;
// 深圳湾水面 —— 移植原版 city-bay-water.ts 的 `living-bay` 材质。
//
// 原版要点（逐项对应）：
//   - 材质 albedo (.025,.095,.105)、metallic 0、roughness .13、ior 1.333、env 1（夜 .78）
//   - 波法线全部在着色器里算：4 组世界空间正弦相位
//         (.092, .171)、(-.238, .114)、(1.62, .83)、(-.74, 2.31)
//     用 fwidth 做抗混叠，并把亚像素斜率方差回灌到 roughness
//   - 近岸用 shore-distance.png 控制浅水色与泡沫（foam = min(p1, p2)）
//   - 反射：原版是 512 平面镜（refreshRate 3）。Godot 没有内置平面镜，
//     这里用「环境天空反射（IBL）+ 屏幕空间反射」，并把 fresnel 权重调成
//     相近的观感；质上是近似，见项目 README「已知差异」。

render_mode cull_disabled, depth_draw_opaque;

uniform vec3 shallow_color : source_color = vec3(0.055, 0.16, 0.17);
uniform vec3 deep_color : source_color = vec3(0.025, 0.095, 0.105);
uniform vec3 foam_color : source_color = vec3(0.62, 0.72, 0.74);
uniform float wave_scale = 1.0;
uniform float wave_speed = 1.0;
uniform float roughness_base : hint_range(0.0, 1.0) = 0.13;
uniform float shore_max_distance = 120.0;
uniform vec4 shore_extent = vec4(-10000.0, -13000.0, 10000.0, 3000.0);
uniform sampler2D shore_distance : hint_default_black;

varying vec3 v_world;
varying vec3 v_normal_ws;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_normal_ws = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// 一组方向波：返回 (梯度x, 梯度z)
vec2 wave_grad(vec2 p, vec2 dir, float freq, float amp, float t) {
	float phase = dot(p, dir) * freq + t;
	float c = cos(phase) * freq * amp;
	return dir * c;
}

void fragment() {
	vec2 p = v_world.xz;
	float t = TIME * wave_speed;

	// 原版的四组相位，频率与振幅按同比例放大到游戏尺度
	vec2 g = vec2(0.0);
	g += wave_grad(p, normalize(vec2(0.092, 0.171)), 1.0, 0.055 * wave_scale, t * 0.9);
	g += wave_grad(p, normalize(vec2(-0.238, 0.114)), 1.7, 0.038 * wave_scale, t * 1.25);
	g += wave_grad(p, normalize(vec2(1.62, 0.83)), 3.1, 0.020 * wave_scale, t * 1.7);
	g += wave_grad(p, normalize(vec2(-0.74, 2.31)), 5.3, 0.011 * wave_scale, t * 2.2);

	// fwidth 抗混叠：波长小于一个像素时把梯度压掉
	float footprint = max(fwidth(p.x), fwidth(p.y)) + 0.0001;
	float cutoff = clamp(footprint * 3.0, 0.0, 1.0);
	g *= (1.0 - cutoff);

	vec3 n = normalize(vec3(-g.x, 1.0, -g.y));

	// 亚像素斜率方差 → 粗糙度回灌（原版做法）
	float slope_var = (g.x * g.x + g.y * g.y) * 40.0;
	float rough = clamp(roughness_base + slope_var + cutoff * 0.35, 0.03, 0.6);

	// 岸距：R 通道 = 距离 / 120
	vec2 uv = (p - shore_extent.xy) / (shore_extent.zw - shore_extent.xy);
	float shore = 1.0;
	if (uv.x > 0.0 && uv.x < 1.0 && uv.y > 0.0 && uv.y < 1.0) {
		vec4 s = texture(shore_distance, vec2(uv.x, 1.0 - uv.y));
		shore = clamp(s.r * shore_max_distance / shore_max_distance, 0.0, 1.0);
	}
	// 浅水 → 深水
	float depth_mix = smoothstep(0.02, 0.30, shore);
	vec3 water = mix(shallow_color, deep_color, depth_mix);

	// 泡沫：靠岸处两条波叠加取最小值（原版 foam = min(p1, p2)）
	float p1 = sin(dot(p, normalize(vec2(0.092, 0.171))) * 3.0 + t * 1.8) * 0.5 + 0.5;
	float p2 = sin(dot(p, normalize(vec2(-0.238, 0.114))) * 4.3 + t * 2.4) * 0.5 + 0.5;
	float foam = min(p1, p2);
	float foam_mask = smoothstep(0.22, 0.0, shore) * smoothstep(0.35, 0.85, foam);
	water = mix(water, foam_color, foam_mask * 0.75);

	ALBEDO = water;
	ROUGHNESS = rough;
	METALLIC = 0.0;
	SPECULAR = 0.85;
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	// 让天空/环境反射明显（对应原版 envIntensity 1，夜 .78）
	AO = 1.0;
}
