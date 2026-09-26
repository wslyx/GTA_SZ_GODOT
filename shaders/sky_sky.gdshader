shader_type sky;
// 天空 —— 把三档天空合并成**一个 Sky 着色器**，替代原来的两个 8000 直径球体网格。
//
// 原版是"同一个天空球换三份材质"（city-cinematic.ts:280）：
//   night ? 夜空材质 : (day && 白天 HDR 就绪) ? 白天 HDR : 摄影日落天空
// 本移植对应成同一个 Sky 的 `sky_mode` uniform（0 日落 / 1 白天 / 2 夜晚）。
//
// 比原来的球体网格好在哪：
//   · 天空本来就是"方向 → 颜色"的函数，不需要几何体、不需要每帧跟着相机搬球；
//   · Sky 的辐照度立方图**只在需要时才重渲**（官方文档列的触发条件是：用了 TIME、
//     用了 POSITION 且相机移动、灯变了、uniform 变了、或屏幕尺寸变化）。
//     本着色器**不用 TIME、不用 POSITION**（云也没有时间项），所以立方图基本是静态的；
//   · 背景 pass 仍然是每帧逐像素 —— 真正的性能杠杆是 `use_half_res_pass`：
//     云的 fbm（原本每像素 44 次 sin）只在**半分辨率的像素**上跑，
//     全屏背景只做一次带线性过滤的采样 ≈ 4 倍便宜。
//
// IBL 标定一点没动：辐照度立方图这一路仍然只输出 `HDR 全景 × base_energy`，
// 与改造前的 `PanoramaSkyMaterial.energy_multiplier = ENV_INTENSITY[mode]` 完全一致。
//
// 太阳/月亮方向与原版一致：原版在 Babylon 空间（z = 北），本项目的世界是 z = −北，
// 所以凡是用到方向常量的地方 z 都要取反（日落辉光的 `sd`、月球的 `moon_direction`）。

render_mode use_half_res_pass, disable_fog;

/// 0 日落（程序化） / 1 白天（HDR 全景） / 2 夜晚（星空）
uniform float sky_mode : hint_range(0.0, 2.0) = 0.0;
/// 程序化天空的显示增益（对两家 ACES 肩部差异的实测补偿，见 sky_system.gd）
uniform float sky_gain : hint_range(0.0, 2.0) = 0.42;
/// 辐照度立方图用的 HDR 全景（与改造前的 IBL 是同一张图）
uniform sampler2D base_sky : source_color, hint_default_white;
/// = 原版 scene.environmentIntensity（白天 .78 / 日落 .40 / 夜晚 .55）
uniform float base_energy = 1.0;

// --- 夜空参数（原版 city-night-sky.ts）---
uniform vec3 zenith_color : source_color = vec3(0.015, 0.02, 0.05);
uniform vec3 horizon_color : source_color = vec3(0.07, 0.09, 0.16);
/// ⚠️ 原版常量是 (.72,.48,−.5)（z = 北）；本项目 z = −北，所以这里取 **+.5**。
/// 取 −.5 会让月盘画在月光来源的反面 —— 光照架里月光来自 (0.72,0.48,0.5)。
uniform vec3 moon_direction = vec3(0.72, 0.48, 0.5);
uniform float moon_radius : hint_range(0.001, 0.05) = 0.0082;
uniform float moon_diffuse : hint_range(0.0, 2.0) = 0.42;
uniform float star_density : hint_range(0.0, 1.0) = 0.85;
uniform float galaxy_strength : hint_range(0.0, 2.0) = 0.55;

// ---------------------------------------------------------------------------
// 噪声（szSky 原样）
// ---------------------------------------------------------------------------

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
	           mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

// 逐倍频抗锯齿的 fbm。
//   pixel = 一个像素在 uv 空间里的足迹；某一倍频的格距小于足迹时，
//   **用该倍频的均值 0.5 顶替**（不能跳过：跳过会丢掉正值、云整体变淡，
//   smoothstep(.40,.66) 的阈值跟着漂）。pixel 很小时五个倍频全都采样，
//   输出与原版逐位相同。
float fbm_lod(vec2 p, float pixel) {
	float f = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		if (pixel > 1.0) {
			f += 0.5 * a;
		} else {
			f += noise(p) * a;
		}
		p = p * 2.03 + 17.0;
		pixel *= 2.03;
		a *= 0.5;
	}
	return f;
}

// ---------------------------------------------------------------------------
// 日落天色（原版 city-world.ts 的 szSky 片元，逐行照搬）
// ---------------------------------------------------------------------------

vec3 sunset_sky(vec3 p) {
	vec3 sd = normalize(vec3(-0.95, 0.16, 0.18));   // z 取反，见文件头
	float west = pow(max(0.0, dot(p, sd)), 4.0);
	float h = smoothstep(-0.05, 0.72, p.y);
	vec3 horizon = mix(vec3(0.42, 0.24, 0.35), vec3(0.94, 0.32, 0.115), west);
	vec3 c = mix(horizon, vec3(0.047, 0.12, 0.25), h);
	float glow = pow(max(0.0, dot(p, sd)), 22.0);
	c += vec3(0.5, 0.18, 0.055) * glow;
	float sun = pow(max(0.0, dot(p, sd)), 4200.0);
	c += vec3(5.0, 2.2, 0.6) * sun;

	vec2 uv = p.xz / max(0.14, p.y + 0.08) * 2.0;
	uv.x *= 0.52;
	// 一个像素在 uv 空间里的足迹：地平线附近 `p.y + .08` 趋近 0，这个值随之爆掉
	float pixel = max(length(dFdx(uv)), length(dFdy(uv)));
	float cloud = fbm_lod(uv + fbm_lod(uv * 0.4, pixel * 0.4) * 1.6, pixel);
	float stripe = noise(vec2(uv.x * 0.8, uv.y * 4.0)) * 0.13
		* (1.0 - smoothstep(0.25, 1.2, pixel));
	float mask = smoothstep(0.40, 0.66, cloud + stripe)
		* smoothstep(0.01, 0.12, p.y)
		* (1.0 - smoothstep(0.55, 0.99, p.y));
	vec3 cloudDark = mix(vec3(0.18, 0.17, 0.29), vec3(0.38, 0.16, 0.20), west);
	vec3 cloudLit = mix(vec3(0.68, 0.31, 0.38), vec3(1.25, 0.34, 0.10), west);
	float rim = smoothstep(0.46, 0.53, cloud) * (1.0 - smoothstep(0.54, 0.65, cloud));
	vec3 cloudColor = mix(cloudDark, cloudLit, rim * 0.85 + 0.24 * west);
	return mix(c, cloudColor, mask * 0.85);
}

// ---------------------------------------------------------------------------
// 夜空（原版 city-night-sky.ts）
// ---------------------------------------------------------------------------

float hash31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float stars(vec3 dir, float scale) {
	vec3 p = dir * scale;
	vec3 i = floor(p);
	float h = hash31(i);
	if (h < 1.0 - star_density) {
		return 0.0;
	}
	vec3 f = fract(p) - 0.5;
	float d = length(f);
	return smoothstep(0.5, 0.0, d) * (0.35 + h * 0.65);
}

vec3 night_sky(vec3 p) {
	float h = smoothstep(-0.08, 0.9, p.y);
	vec3 c = mix(horizon_color, zenith_color, h);
	float s = stars(p, 220.0) + stars(p, 480.0) * 0.6;
	c += vec3(0.92, 0.94, 1.0) * s * smoothstep(-0.02, 0.25, p.y);
	vec3 axis = normalize(vec3(0.42, 0.36, -0.83));
	float band = 1.0 - abs(dot(p, axis));
	float galaxy = pow(clamp(band, 0.0, 1.0), 6.0);
	float dust = 0.5 + 0.5 * sin(dot(p, vec3(11.0, 7.0, 5.0)) * 1.7);
	c += mix(vec3(0.16, 0.17, 0.26), vec3(0.34, 0.30, 0.42), dust) * galaxy * galaxy_strength;
	vec3 md = normalize(moon_direction);
	float md_dot = dot(p, md);
	float disc = smoothstep(1.0 - moon_radius, 1.0 - moon_radius * 0.72, md_dot);
	c += vec3(0.86, 0.90, 1.0) * disc * (0.55 + moon_diffuse);
	c += vec3(0.30, 0.36, 0.52) * pow(max(md_dot, 0.0), 90.0) * moon_diffuse;
	return c;
}

// ---------------------------------------------------------------------------
// 三种可见天空 + IBL
// ---------------------------------------------------------------------------

/// 辐照度立方图用：只放低频的 HDR 全景。
/// 这一路与改造前的 `PanoramaSkyMaterial(energy_multiplier = ENV_INTENSITY)` 等价，
/// 所以环境光/反射的标定完全没变。
///
/// 全景的 UV 约定照抄引擎源码（`environment/sky.glsl` 的 `panorama_coords`）：
///   u = atan2(x, −z)（负值加 2π）/ 2π，v = acos(y) / π
/// 也就是**图片的第一行是正上方**——v 轴如果接反，环境光就会从"下半球"来。
vec2 dir_to_panorama(vec3 d) {
	float u = atan(d.x, -d.z);
	if (u < 0.0) {
		u += PI * 2.0;
	}
	return vec2(u / (PI * 2.0), acos(clamp(d.y, -1.0, 1.0)) / PI);
}

vec3 hdr_sky(vec3 p) {
	return texture(base_sky, dir_to_panorama(p)).rgb * base_energy;
}

/// 屏幕上真正看到的天空（与 sky_mode 对应）
vec3 visible_sky(vec3 p) {
	if (sky_mode > 1.5) {
		return night_sky(p);
	}
	if (sky_mode > 0.5) {
		return hdr_sky(p);
	}
	return sunset_sky(p) * sky_gain;
}

void sky() {
	// ⚠️ sky 处理器**不允许 `return`**（会报 "Using 'return' in the 'sky'
	// processor function is incorrect"），所以这里必须用 if/else 层级，不能提前返回。
	if (AT_CUBEMAP_PASS) {
		// 辐照度立方图：低频 HDR。立方图只在参数变化时重渲，所以这一路几乎不花时间。
		COLOR = hdr_sky(EYEDIR);
	} else if (AT_HALF_RES_PASS) {
		// 半分辨率子通道：云的 fbm 在这里跑（像素数只有全屏的 1/4）。
		// 顺带写 ALPHA 当"我已产出"的标记，给下面的兜底用。
		COLOR = visible_sky(EYEDIR);
		ALPHA = 1.0;
	} else {
		// 背景：一次带线性过滤的采样。
		// 兜底：万一子通道这一帧没产出，就自己算一遍 —— 退化成改造前的开销，
		// 而不是留一片黑天。
		vec4 half_color = HALF_RES_COLOR;
		COLOR = half_color.a > 0.5 ? half_color.rgb : visible_sky(EYEDIR);
	}
}
