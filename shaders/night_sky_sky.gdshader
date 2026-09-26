shader_type sky;
// 夜空 —— 移植原版 src/city-night-sky.ts。
//
// 原版内容：方向性银河带（沿一条斜轴的密度起伏）、星群（哈希亮点 + 亮度分级）、
// 月球盘（半径 .0082，漫射 .42）。三部分都按视线方向做，所以天空随相机移动不受影响。
//
// ⚠️ 2026-09-26 从 `shader_type spatial`（球体网格）迁入 Sky 着色器：
//   · `EYEDIR` 取代 `normalize(v_local)`（不再需要 8000 直径的球）；
//   · `COLOR = c` 取代 `ALBEDO = c`；
//   · `AT_CUBEMAP_PASS` 一路只出低频 HDR —— **保证夜间 IBL 的标定不变**
//     （改造前这里是 `PanoramaSkyMaterial(rooftop-night-2k.hdr) × .55`）；
//   · 星空不用 TIME / POSITION，所以立方图不会每帧重渲。
//
// ⚠️ 顺手修掉一个月盘方向的符号错：
//   原版常量 `CITY_MOON_DIRECTION = (.72,.48,−.5)` 是 **Babylon 空间（z = 北）**；
//   本项目的世界是 `z = −北`，所以 Godot 里应为 `(.72,.48,+.5)`。
//   取 −.5 会把月盘画在月光来源的反面 —— 光照架里月光来自
//   `lighting_director.gd` 的 `sun_dir_data = (−.72,−.48,+.5)` 取反 = (.72,.48,.5)。

render_mode disable_fog;

uniform vec3 zenith_color : source_color = vec3(0.015, 0.02, 0.05);
uniform vec3 horizon_color : source_color = vec3(0.07, 0.09, 0.16);
uniform vec3 moon_direction = vec3(0.72, 0.48, 0.5);
uniform float moon_radius : hint_range(0.001, 0.05) = 0.0082;
uniform float moon_diffuse : hint_range(0.0, 2.0) = 0.42;
uniform float star_density : hint_range(0.0, 1.0) = 0.85;
uniform float galaxy_strength : hint_range(0.0, 2.0) = 0.55;
/// 夜间辐照度立方图用的低频 HDR（= 改造前的 rooftop-night-2k.hdr）
uniform sampler2D base_sky : source_color, hint_default_white;
uniform float base_energy = 0.55;

float hash31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float stars(vec3 dir, float scale) {
	vec3 p = dir * scale;
	vec3 i = floor(p);
	float h = hash31(i);
	// 只有约 (1 - star_density) 的单元格没有星
	if (h < 1.0 - star_density) {
		return 0.0;
	}
	vec3 f = fract(p) - 0.5;
	float d = length(f);
	// 星点核心 + 亮度分级
	float mag = fract(h * 97.13);
	float core = smoothstep(0.34, 0.0, d);
	return core * (0.25 + pow(mag, 3.0) * 1.35);
}

vec3 night_sky(vec3 p) {
	float h = smoothstep(-0.08, 0.9, p.y);
	vec3 c = mix(horizon_color, zenith_color, h);

	// 星群：两层不同尺度，避免规则排布
	float s = stars(p, 220.0) + stars(p, 480.0) * 0.6;
	c += vec3(0.92, 0.94, 1.0) * s * smoothstep(-0.02, 0.25, p.y);

	// 银河带：沿一条倾斜大圆做密度起伏
	vec3 axis = normalize(vec3(0.42, 0.36, -0.83));
	float band = 1.0 - abs(dot(p, axis));
	float galaxy = pow(clamp(band, 0.0, 1.0), 6.0);
	float dust = 0.5 + 0.5 * sin(dot(p, vec3(11.0, 7.0, 5.0)) * 1.7);
	c += mix(vec3(0.16, 0.17, 0.26), vec3(0.34, 0.30, 0.42), dust) * galaxy * galaxy_strength;

	// 月球盘
	vec3 md = normalize(moon_direction);
	float md_dot = dot(p, md);
	float disc = smoothstep(1.0 - moon_radius, 1.0 - moon_radius * 0.72, md_dot);
	c += vec3(0.86, 0.90, 1.0) * disc * (0.55 + moon_diffuse);
	// 月晕
	c += vec3(0.30, 0.36, 0.52) * pow(max(md_dot, 0.0), 90.0) * moon_diffuse;
	return c;
}

vec2 dir_to_panorama(vec3 d) {
	float u = atan(d.x, -d.z);
	if (u < 0.0) {
		u += PI * 2.0;
	}
	return vec2(u / (PI * 2.0), acos(clamp(d.y, -1.0, 1.0)) / PI);
}

void sky() {
	// 夜间 IBL：与改造前的 PanoramaSkyMaterial(rooftop-night-2k) × .55 完全一致
	if (AT_CUBEMAP_PASS) {
		COLOR = texture(base_sky, dir_to_panorama(EYEDIR)).rgb * base_energy;
	} else if (AT_HALF_RES_PASS) {
		COLOR = night_sky(EYEDIR);
		ALPHA = 1.0;
	} else {
		vec4 half_color = HALF_RES_COLOR;
		COLOR = half_color.a > 0.5 ? half_color.rgb : night_sky(EYEDIR);
	}
}
