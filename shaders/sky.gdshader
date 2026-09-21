shader_type spatial;
// 程序化城市天空 —— 移植原版 city-world.ts 的 szSky 着色器。
//
// 原版关键项（逐项对应）：
//   sd    = normalize(-.95, .16, -.18)   太阳方向
//   glow  = pow(dot(p, sd), 22)          地平线暖辉
//   sun   = pow(dot(p, sd), 4200) * vec3(5, 2.2, .6)   日轮
//   云    5 阶 fbm（FBM_OCTAVES）
//   末行  c = mix(c, c * vec3(.12,.22,.44), night)
//
// 挂在直径 8000 的球上。
//
// ⚠️ 这里曾经写成 depth_draw_never + depth_test_disabled，注释说"保证永远在最后方"，
// 但那是**反的**：depth_test_disabled 意味着天空球不参与深度测试，它的片元一律通过，
// 而不透明队列是按由近及远排的，天空球（4000m）排在城市之后绘制 —— 于是它把已经
// 画好的城市、车辆全部盖掉，画面只剩天空。
//
// 正确写法是保留 depth_draw_never（天空球不写深度，不遮挡任何东西），
// 但**开启深度测试**：这样天空只在"还没有任何东西"的像素上着色，
// 先画后画都安全，远处山体（>4000m）也能正常压在天空之上。
render_mode unshaded, cull_disabled, depth_draw_never, fog_disabled;

const int FBM_OCTAVES = 5;

uniform float night : hint_range(0.0, 1.0) = 0.0;
uniform vec3 horizon_color : source_color = vec3(0.79, 0.79, 0.68);
uniform vec3 zenith_color : source_color = vec3(0.36, 0.54, 0.66);
uniform float sun_glow : hint_range(0.0, 1.0) = 1.0;
uniform float cloud_amount : hint_range(0.0, 1.0) = 0.42;
uniform float time_scale : hint_range(0.0, 1.0) = 0.004;

varying vec3 v_local;

void vertex() {
	v_local = VERTEX;
}

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float amp = 0.5;
	for (int i = 0; i < FBM_OCTAVES; i++) {
		v += amp * vnoise(p);
		p *= 2.03;
		amp *= 0.5;
	}
	return v;
}

void fragment() {
	vec3 p = normalize(v_local);
	float h = smoothstep(-0.05, 0.85, p.y);
	vec3 c = mix(horizon_color, zenith_color, h);

	// 日轮方向与地平辉光（原版 sd = normalize(-.95,.16,-.18)）
	vec3 sd = normalize(vec3(-0.95, 0.16, -0.18));
	float sd_dot = dot(p, sd);
	c += horizon_color * 0.25 * pow(max(sd_dot, 0.0), 22.0) * sun_glow;
	float sun = pow(max(sd_dot, 0.0), 4200.0);
	c += vec3(5.0, 2.2, 0.6) * sun * sun_glow;

	// 云：把方向投到水平面做 fbm，再按仰角遮罩
	vec2 cp = p.xz / max(abs(p.y) + 0.22, 0.12);
	cp = cp * 1.6 + vec2(TIME * time_scale, TIME * time_scale * 0.4);
	float cloud = fbm(cp);
	cloud = smoothstep(0.52, 0.86, cloud) * cloud_amount * smoothstep(0.0, 0.35, p.y);
	vec3 cloud_light = mix(horizon_color * 1.15, vec3(0.92), 0.35);
	vec3 cloud_dark = mix(horizon_color * 0.55, zenith_color * 0.7, 0.4);
	vec3 cloud_color = mix(cloud_dark, cloud_light, smoothstep(0.35, 0.75, sun_glow));
	c = mix(c, cloud_color, cloud);

	// 夜幕压暗并偏蓝（原版末行）
	c = mix(c, c * vec3(0.12, 0.22, 0.44), night);

	ALBEDO = c;
}
