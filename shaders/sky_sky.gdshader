shader_type sky;
// 天空 —— 把三档天空合并成**一个 Sky 着色器**，替代原来的两个 8000 直径球体网格。
//
// 原版是"同一个天空球换三份材质"（city-cinematic.ts:280）：
//   night ? 夜空材质 : (day && 白天 HDR 就绪) ? 白天 HDR : 摄影日落天空
// 本移植对应成同一个 Sky 的 `sky_mode` uniform，且是**连续值**：
//   0 夜晚 —— 1 日落 —— 2 白天
// 切换光照档时 sky_mode 在这条轴上平滑滑动（sky_system.gd 驱动），
// 夜→白天会自然掠过日落色（= 黎明），日落→夜直接淡入星空。
// 相邻两档的可见天空按 smoothstep(fract) 混合，静止时与旧的三选一逐像素一致。
//
// 比原来的球体网格好在哪：
//   · 天空本来就是"方向 → 颜色"的函数，不需要几何体、不需要每帧跟着相机搬球；
//   · Sky 的辐照度立方图**只在需要时才重渲**（uniform 变化等），静止时立方图是静态的。
//
// ⚠️ 刻意**不用** `use_half_res_pass`（曾经开过，为日落云的 fbm 提速）：
//   夜空的星尘/星点/月盘边缘是高频细节，半分辨率渲染 + 双线性放大会把每个
//   计算像素铺成屏幕上的 2×2 色块 —— 星空出现马赛克；而 ALPHA 置 0 让背景段
//   全分辨率重算的兜底并不可靠（半分辨率渲染目标的 alpha 不保证保留）。
//   原版 Babylon 的天空本来就是全屏逐像素渲染，这里保持一致；fbm_lod 自带
//   像素足迹 LOD，远处像素仍会自动省掉高频倍频，性能可控。
//   可见背景因此全分辨率逐像素（见 sky()）。
//
// 夜空 = 原版 city-night-sky.ts 片元**逐行照搬**（银河带/尘埃带/银心隆起/
// 月光卷云/网格主星/亚像素星尘/带月海的月盘），坐标在函数入口做一次 z 取反
// （本世界 z = −北，原版 Babylon z = 北），此后所有常量与原版数字一致。
// 夜间 IBL 同样按原版：**解析式中性深蓝环境**（原版 RawCubeTexture 生成式的
// 逐方向复算），不再用 rooftop-night HDR —— 原版注释明说"夜间反射不能残留
// 白天的红色日落"。日落/白天 IBL 仍是对应 HDR 全景 × base_energy。
//
// IBL 标定：日落/白天一路与改造前完全一致；夜晚从 rooftop HDR × .55 换成
// 原版中性立方图 × .55（原版 scene.environmentIntensity=.55 × 环境立方图）。
//
// 太阳/月亮方向与原版一致：原版在 Babylon 空间（z = 北），本项目的世界是 z = −北。

render_mode disable_fog;

/// 连续档位轴：0 夜晚（星空）/ 1 日落（程序化）/ 2 白天（HDR 全景）
uniform float sky_mode : hint_range(0.0, 2.0) = 1.0;
/// 程序化天空的显示增益（对两家 ACES 肩部差异的实测补偿，见 sky_system.gd）
uniform float sky_gain : hint_range(0.0, 2.0) = 0.42;
/// 辐照度立方图用的 HDR 全景（与改造前的 IBL 是同一张图）
uniform sampler2D base_sky : source_color, hint_default_white;
/// = 原版 scene.environmentIntensity（白天 .78 / 日落 .40 / 夜晚 .55）
uniform float base_energy = 1.0;
/// IBL 交叉淡化的 B 槽：切换光照档时 A=旧档 / B=新档，env_blend 0→1；
/// 过渡结束把 B 烘回 A（env_blend 归零，输出不变，立方图恢复静态）。
uniform sampler2D base_sky_b : source_color, hint_default_white;
uniform float base_energy_b = 1.0;
uniform float env_blend : hint_range(0.0, 1.0) = 0.0;
/// A/B 槽各自的档位（立方图槽按档位决定用 HDR 全景还是夜晚中性环境）
uniform float mode_a : hint_range(0.0, 2.0) = 1.0;
uniform float mode_b : hint_range(0.0, 2.0) = 1.0;

/// 月亮方向（Godot 世界空间；原版 CITY_MOON_DIRECTION=(.72,.48,−.5) 是
/// Babylon 空间 z=北，本项目 z=−北 所以取 +.5。night_sky() 内部会转回原版空间）
uniform vec3 moon_direction = vec3(0.72, 0.48, 0.5);


// ---------------------------------------------------------------------------
// 噪声（hash/sz_noise/fbm = szSky 原样；skyNoise = city-night-sky.ts 的 3D 值噪声，
// 经 2D sz_noise 按 z 切片混合等价实现 —— 直接三重嵌套 mix 的 3D 版在本机
// Godot 4.7.1 sky 处理器上会退化成分片常数瓦片，见 git 历史）
// ---------------------------------------------------------------------------

float hash(highp vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float sz_noise(highp vec2 p) {
	highp vec2 i = floor(p);
	highp vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
	           mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float skyNoise(highp vec3 p) {
	// 3D 值噪声 = 用**在本引擎里验证平滑的 2D 值噪声 sz_noise** 按 z 切片混合：
	// 每个 z 整数层给 2D 噪声一个固定偏移，两层之间按 smoothstep(fract(p.z)) 插值，
	// 数学上与三线性 3D 值噪声等价（8 角哈希 → 2×4 角哈希）。
	// （直接写三重嵌套 mix 的 3D 版在本机 Godot 4.7.1 sky 处理器上会退化成
	//   分片常数瓦片 —— 原因未明，2D 版无此问题，故用此等价实现。）
	highp float zi = floor(p.z);
	highp float zf = fract(p.z);
	zf = zf * zf * (3.0 - 2.0 * zf);
	highp vec2 pxy = p.xy;
	highp float z0 = sz_noise(pxy + 57.0 * zi + 11.0);
	highp float z1 = sz_noise(pxy + 57.0 * (zi + 1.0) + 11.0);
	return mix(z0, z1, zf);
}

// 逐倍频抗锯齿的 fbm（日落云用）。
//   pixel = 一个像素在 uv 空间里的足迹；某一倍频的格距小于足迹时，
//   **用该倍频的均值 0.5 顶替**（不能跳过：跳过会丢掉正值、云整体变淡）。
float fbm_lod(vec2 p, float pixel) {
	float f = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		if (pixel > 1.0) {
			f += 0.5 * a;
		} else {
			f += sz_noise(p) * a;
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
	float pixel = max(length(dFdx(uv)), length(dFdy(uv)));
	float cloud = fbm_lod(uv + fbm_lod(uv * 0.4, pixel * 0.4) * 1.6, pixel);
	float stripe = sz_noise(vec2(uv.x * 0.8, uv.y * 4.0)) * 0.13
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
// 夜空（原版 city-night-sky.ts 片元，逐行照搬）
// ---------------------------------------------------------------------------

vec3 night_sky(vec3 p) {
	// 入口做一次坐标转换：Godot 世界 (x, y, −北) → 原版 Babylon (x, y, 北)。
	// 之后所有常量（银道面法线、银心方向、月亮方向）与原版数字逐位一致。
	vec3 d = normalize(vec3(p.x, p.y, -p.z));
	float elevation = max(d.y, 0.0);
	float aboveHorizon = smoothstep(-0.025, 0.16, d.y);
	vec3 color = mix(vec3(0.042, 0.043, 0.075), vec3(0.009, 0.017, 0.042),
		smoothstep(0.0, 0.65, elevation));

	// 倾斜银道面：银-紫星云 + 更暗的尘埃带（全部保持线性，交给 ACES）
	float grain = skyNoise(d * 13.0 + 7.3) * 0.30 + skyNoise(d * 34.0 - 5.1) * 0.40
		+ skyNoise(d * 89.0) * 0.30;
	float latitude = dot(d, normalize(vec3(0.12, 0.78, -0.62))) + (grain - 0.5) * 0.055;
	float band = exp(-latitude * latitude / 0.030);
	float ridge = exp(-latitude * latitude / 0.0048);
	float dustLane = latitude + (skyNoise(d * 47.0 + 23.0) - 0.5) * 0.068;
	float dust = exp(-dustLane * dustLane / 0.00028) * (0.24 + grain * 0.27);
	float bulge = pow(max(0.0, dot(d, normalize(vec3(-0.35, 0.54, 0.77)))), 12.0);
	vec3 galaxy = vec3(0.056, 0.062, 0.135) * band
		+ mix(vec3(0.17, 0.19, 0.28), vec3(0.32, 0.22, 0.17), bulge) * ridge;
	color += galaxy * (0.36 + grain * 1.12) * (1.0 - dust) * aboveHorizon;

	// 月光照亮的卷云帷幔
	vec2 uv = vec2(atan(d.z, d.x) / 6.283185307 + 0.5,
		asin(clamp(d.y, -1.0, 1.0)) / 3.141592654 + 0.5);
	float cloud = skyNoise(d * vec3(5.0, 12.0, 5.0) + vec3(2.3, 7.4, 4.1)) * 0.57
		+ skyNoise(d * vec3(13.0, 28.0, 13.0) - 6.2) * 0.29
		+ skyNoise(d * 31.0 + 14.0) * 0.14;
	float veil = smoothstep(0.46, 0.72, cloud) * 0.40 * aboveHorizon;
	// 网格主星：逐格哈希（出现概率 / 星等 / 偏心位置），fwidth 抗锯齿
	vec2 grid = uv * vec2(420.0, 210.0);
	vec2 cell = floor(grid);
	float chance = hash(cell);
	float magnitude = hash(cell + 71.3);
	vec2 center = vec2(hash(cell + 13.7), hash(cell + 97.1)) * 0.64 + 0.18;
	vec2 delta = fract(grid) - center;
	delta.x *= max(0.25, sqrt(max(0.0, 1.0 - d.y * d.y)));
	float radius = mix(0.045, 0.080, pow(magnitude, 5.0));
	float aa = max(length(fwidth(grid)) * 0.45, 0.018);
	float core = 1.0 - smoothstep(max(0.0, radius - aa), radius + aa, length(delta));
	float stars = step(0.963 - band * 0.035, chance) * core
		* smoothstep(0.025, 0.20, elevation) * min(1.0, radius / aa);
	vec3 tint = mix(vec3(0.76, 0.84, 1.0), vec3(1.0, 0.87, 0.72), hash(cell + 4.8));
	color += stars * tint * mix(0.52, 2.2, pow(magnitude, 4.0));

	// 亚像素星尘：给银道面细颗粒，而不是一坨坨云斑
	vec2 fine = uv * vec2(1180.0, 590.0);
	vec2 fc = floor(fine);
	vec2 fp = fract(fine) - vec2(hash(fc + 25.1), hash(fc + 82.7));
	fp.x *= max(0.25, sqrt(max(0.0, 1.0 - d.y * d.y)));
	float footprint = 0.0064 + dot(fwidth(fine), fwidth(fine)) * 0.16;
	float sparks = step(0.965 - band * 0.11, hash(fc + 147.0))
		* exp(-dot(fp, fp) / footprint) * 0.0064 / footprint;
	color += vec3(0.30, 0.34, 0.44) * sparks * band * aboveHorizon;

	// 月亮方向（转回原版 Babylon 空间：z 取反）
	vec3 mb = normalize(vec3(moon_direction.x, moon_direction.y, -moon_direction.z));
	float angle = length(d - mb);
	float moonScatter = exp(-angle * angle / 0.42);
	vec3 cirrus = vec3(0.09, 0.125, 0.20) + vec3(0.15, 0.18, 0.23) * moonScatter;
	color = mix(color, cirrus, veil);

	// 月盘：局部切平面 + 月海 + 边缘抗锯齿 + 克制的晕
	vec3 mx = normalize(cross(mb, vec3(0.0, 1.0, 0.0)));
	vec3 my = cross(mx, mb);
	vec2 lunar = vec2(dot(d, mx), dot(d, my)) / 0.0082;
	float mr = length(lunar);
	float maa = max(fwidth(mr), 0.025);
	float disc = (1.0 - smoothstep(1.0 - maa, 1.0 + maa, mr)) * step(0.0, dot(d, mb));
	float maria = sz_noise(lunar * 4.2 + 7.0) * 0.7 + sz_noise(lunar * 10.0 + 1.7) * 0.3;
	float relief = mix(0.56, 1.0, smoothstep(0.25, 0.70, maria))
		* (0.7 + 0.3 * sqrt(max(0.0, 1.0 - mr * mr)));
	color = mix(color, vec3(1.8, 1.86, 1.96) * relief * (1.0 - veil * 0.45), disc);
	color += vec3(0.022, 0.032, 0.049) * exp(-angle * angle / 0.00075) * (1.0 - disc);
	return color;
}

/// 夜间中性环境（原版 createCityNightSky 的 RawCubeTexture 生成式，逐方向复算）。
/// d：**原版 Babylon 空间**方向（z=北）。线性辐照度，供夜间 IBL/反射。
vec3 night_environment(vec3 d) {
	if (d.y < 0.0) {
		return vec3(0.040, 0.037, 0.038);
	}
	float h = max(0.0, d.y);
	float horizon = exp(-abs(d.y) * 5.0);
	return vec3(0.043 - 0.018 * h + 0.012 * horizon,
	            0.051 - 0.017 * h + 0.006 * horizon,
	            0.078 - 0.021 * h);
}

// ---------------------------------------------------------------------------
// 三种可见天空 + IBL
// ---------------------------------------------------------------------------

/// 全景的 UV 约定照抄引擎源码（`environment/sky.glsl` 的 `panorama_coords`）：
///   u = atan2(x, −z)（负值加 2π）/ 2π，v = acos(y) / π
vec2 dir_to_panorama(vec3 d) {
	float u = atan(d.x, -d.z);
	if (u < 0.0) {
		u += PI * 2.0;
	}
	return vec2(u / (PI * 2.0), acos(clamp(d.y, -1.0, 1.0)) / PI);
}

/// 白天可见背景 = HDR 全景。过渡期间白天档来自 B 槽（A 槽还是旧档的全景）。
vec3 panorama_sky(vec3 p, float m) {
	if (m > 1.5 && mode_b > 1.5 && env_blend > 0.001) {
		return texture(base_sky_b, dir_to_panorama(p)).rgb * base_energy_b;
	}
	return texture(base_sky, dir_to_panorama(p)).rgb * base_energy;
}

/// IBL 立方图的一个槽：夜晚 = 中性环境 × 能量；日落/白天 = HDR 全景 × 能量。
/// d 必须是**原版 Babylon 空间**方向（night_environment 的约定）。
vec3 env_slot(float m, vec3 d, sampler2D tex, float energy) {
	if (m < 0.5) {
		return night_environment(d) * energy;
	}
	return texture(tex, dir_to_panorama(d)).rgb * energy;
}

/// 单档可见天空：0 夜晚 / 1 日落 / 2 白天（整数档的画面）
vec3 sky_look_at(float m, vec3 p) {
	if (m < 0.5) {
		return night_sky(p);
	}
	if (m < 1.5) {
		return sunset_sky(p) * sky_gain;
	}
	return panorama_sky(p, m);
}

/// 屏幕上真正看到的天空：沿 夜0—日落1—白天2 的轴做相邻档混合。
/// 静止（sky_mode 为整数）时与旧的三选一逐像素一致，只有过渡期间才算两份。
vec3 visible_sky(vec3 p) {
	float i = floor(min(sky_mode, 1.999));
	float f = sky_mode - i;
	if (f <= 0.001) {
		return sky_look_at(i, p);
	}
	if (f >= 0.999) {
		return sky_look_at(i + 1.0, p);
	}
	return mix(sky_look_at(i, p), sky_look_at(i + 1.0, p), smoothstep(0.0, 1.0, f));
}

void sky() {
	// ⚠️ sky 处理器**不允许 `return`**（会报 "Using 'return' in the 'sky'
	// processor function is incorrect"），所以这里必须用 if/else 层级，不能提前返回。
	if (AT_CUBEMAP_PASS) {
		// 辐照度立方图：夜晚档 = 原版中性环境 × 能量；日落/白天 = HDR 全景 × 能量。
		// 静止时单槽单次采样；过渡期间 A/B 两槽按 env_blend 交叉淡化。
		vec3 d = vec3(EYEDIR.x, EYEDIR.y, -EYEDIR.z);
		vec3 a = env_slot(mode_a, d, base_sky, base_energy);
		if (env_blend <= 0.001) {
			COLOR = a;
		} else {
			vec3 b = env_slot(mode_b, d, base_sky_b, base_energy_b);
			COLOR = mix(a, b, env_blend);
		}
	} else {
		// 可见背景：全分辨率逐像素（原版同款），不做半分辨率降采样。
		COLOR = visible_sky(EYEDIR);
	}
}
