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
// 白天的红色日落"。
//
// 日落 = 原版 city-sunset-environment.ts 的**摄影 HDR 分级链**：
// belfast-sunset-4k.hdr 经 `gradeSunsetRadiance()`（火色半球 + 云掩码 + 局部
// 对比）逐方向分级；可见天空再叠一次高光肩部滚降（`sunsetDisplayScale`，
// knee 1.8 / 天花板 4.3）并乘原版 `skyMaterial.primaryColor`（.20）。
// IBL 用的是**同一份分级后**的辐照度 —— 原版 `scene.environmentTexture` 就是
// 这个分级立方图（肩部只加在显示纹理上），所以湿路/水面的天空倒影与头顶的
// 天空同色。程序化 `sunset_sky()`（原版 szSky）在原版里只是 HDR 解码完之前的
// 兜底，这里保留为日落 HDR 缺失时的兜底（`sunset_uses_hdr = false`）。
//
// IBL 标定：白天一路与改造前一致；夜晚从 rooftop HDR × .55 换成原版中性立方图
// × .55（原版 scene.environmentIntensity=.55 × 环境立方图）；日落改用分级后的
// belfast HDR × .40（原版 .40 × 分级立方图 —— 此前用的是**未分级**的原始 HDR）。
//
// HDR 全景的绕 Y 旋转：原版三套 HDR 各带一个 rotationY（白天 1.85 /
// 日落 2.80 / 夜 0.65，见 city-daylight.ts:10、city-sunset-environment.ts:12、
// city-cinematic.ts:234）。以前这里是**漏的** —— sky_system.gd 的 HDR_ROTATION
// 常量定义了却零读取点，兜底路径的 PanoramaSkyMaterial.rotation 也从没赋值，
// 于是三档全景一律按未旋转方向贴上去。现在由 hdr_rot_a / hdr_rot_b 显式传入，
// 在 dir_to_panorama() 里以 −rot 旋转采样方向补偿（见 rotate_y 的说明）。
//
// ⚠️ 夜间槽**不采样 HDR**（走 night_environment），所以夜间那个0.65 没有
// 对应纹理，hdr_rot_* 传 0 即可 —— 原版那个 0.65 是给 rooftop-night HDR 用的，
// 而那张图在本移植里已不参与夜间 IBL。
//
// 太阳/月亮方向与原版一致：原版在 Babylon 空间（z = 北），本项目的世界是 z = −北。

render_mode disable_fog;

/// 连续档位轴：0 夜晚（星空）/ 1 日落（摄影 HDR）/ 2 白天（HDR 全景）
uniform float sky_mode : hint_range(0.0, 2.0) = 1.0;
/// 程序化天空的显示增益（对两家 ACES 肩部差异的实测补偿，见 sky_system.gd）。
/// ⚠️ 只作用于 `sunset_uses_hdr = false` 的兜底路径 —— 日落档默认走摄影 HDR，
/// 那条路的显示增益是 `sunset_bg_gain`（原版 `skyMaterial.primaryColor`）。
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
/// A/B 槽各自的 HDR 绕 Y 旋转角（弧度）= 原版 HDRCubeTexture.rotationY
/// （白天 1.85 / 日落 2.80，见 city-daylight.ts:10 与
/// city-sunset-environment.ts:12）。夜间槽走解析式中性环境、不采样 HDR，
/// 所以夜间没有旋转角（sky_system 里填 0）。
///
/// ⚠️ 这两个角以前是**死常量**（HDR_ROTATION 定义了但全项目零读取点，
/// 兜底路径的 PanoramaSkyMaterial.rotation 也从没赋过值），于是三档 HDR
/// 全景一直按未旋转的方向贴上去，与原版差一个固定角。
uniform float hdr_rot_a = 0.0;
uniform float hdr_rot_b = 0.0;
/// 可见背景的白天档该读哪个槽 —— 由 sky_system 显式给出。
///
/// ⚠️ 以前这里是`m > 1.5 && mode_b > 1.5 && env_blend > 0.001`：
/// 把「可见背景读哪张图」耦合到了「IBL 淡化进度」上，而这两件事本该各自
/// 独立。env_blend 提前归零、或槽位下标与实际贴图错配时就会读错档。
uniform bool day_uses_b = false;
/// 日落档的摄影 HDR 全景（belfast-sunset-4k）。
///
/// 用**独立采样器**而不是 A/B 槽：`cycle_mode` 的 夜→白天 是直接过渡
/// （sky_mode 0→2），中途会掠过日落档，而那时 A/B 槽里只有夜/白天两张图
/// —— 日落图没有槽位可放。独立采样器只吃一张常驻贴图，随时可用。
uniform sampler2D sunset_pano : source_color, hint_default_white;
/// 该 HDR 自己的绕 Y 旋转角（弧度）= 原版 CITY_SUNSET_SOURCE.rotationY（2.80）。
/// 分级是在 HDR **自身未旋转** 的空间里逐面做的，采样才用这个角（见 sunset_hdr_sky）。
uniform float sunset_rot = 0.0;
/// 日落**可见天空**的显示增益 = 原版 `skyMaterial.primaryColor`（.20,.20,.20）。
///
/// 2026-10-21 核实：Babylon `background.fragment` 里
/// `finalColor = reflectionColor.rgb * vPrimaryColor.rgb` —— 对 BackgroundMaterial
/// 的摄影显示立方图，primaryColor **就是线性乘子**，0.20 直译无误。
/// （此前一轮把它当成"误译"而改 1.0 是错的：旧图靛蓝的真正根因是下方
/// dir_to_panorama 缺 π 偏移导致火区没命中，与增益无关。）
uniform float sunset_bg_gain = 0.20;
/// 日落 HDR 是否可用；不可用时退回程序化 szSky（保留 sky_gain 旧标定）。
uniform bool sunset_uses_hdr = true;

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
// 日落档：摄影 HDR 的分级链（原版 city-sunset-environment.ts，逐行照搬）
// ---------------------------------------------------------------------------

/// 原版 city-sunset-environment.ts 的 smooth(lo,hi,value)（三次平滑阶跃）。
float sunset_smooth(float lo, float hi, float value) {
	float t = clamp((value - lo) / (hi - lo), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

/// 火色半球权重（原版 sunsetFireWeight）：朝阳半球 → 1，背阳 → 0。
float sunset_fire_weight(vec3 d) {
	float len = max(length(d), 0.000001);
	return sunset_smooth(-0.48, 0.25, (0.6 * d.x + 0.8 * d.z - 0.08 * d.y) / len);
}

/// 逐方向复算原版 gradeSunsetRadiance：火色半球 + 云掩码 + 局部对比。
/// d 是**分级空间**方向（原版逐面做，与 rotationY 无关）；c 是该方向的原始
/// HDR 辐照度。保留照片里的暗云底与橙色缝隙，反朝阳的天空压到深靛蓝。
vec3 grade_sunset_radiance(vec3 d, vec3 c) {
	float len = max(length(d), 0.000001);
	float r = max(c.r, 0.0);
	float g = max(c.g, 0.0);
	float b = max(c.b, 0.0);
	float hemisphere = sunset_fire_weight(d);
	// 太阳眩光：朝阳方向 ^18 的窄峰，越靠地平线越强（exp(-y*6)）。
	// 它是"这不是云、是太阳"的判据，用来把日轮从云掩码里剔掉。
	float solarGlare = 1.0 + 9.0
		* pow(max(0.0, (0.6 * d.x + 0.8 * d.z) / len), 18.0)
		* exp(-max(0.0, d.y / len) * 6.0);
	float luminance = r * 0.2126 + g * 0.7152 + b * 0.0722;
	// 云掩码用 r/b 比值（暖云 → 1）。局部曝光只进掩码，不改原始辐照度。
	float cloud = sunset_smooth(0.56, 1.03, r / (b + 0.0001));
	float lit = sunset_smooth(0.50, 1.45, luminance / solarGlare);
	// 未点火那一支让反朝阳的天空停在"亮云亮度的一成"而不是全黑：
	// 真实黄昏的背阳天空仍在发光，那份能量正是城市暗面的补光。
	float fire = hemisphere * cloud * (0.06 + 0.94 * lit);
	float contrast = 0.70 + 0.68 * lit;
	return vec3(
		((r * 0.28 + b * 0.11) * (1.0 - fire) + (r * 1.72 + g * 0.25) * fire) * contrast,
		((g * 0.32 + b * 0.09) * (1.0 - fire) + (g * 0.58 + r * 0.10) * fire) * contrast,
		((b * 0.72 + r * 0.15) * (1.0 - fire) + (b * 0.17 + r * 0.022) * fire) * contrast);
}

/// 仅显示用的高光滚降（原版 sunsetDisplayScale：knee 1.8 / 天花板 4.3）。
/// 返回**乘子**：峰值 ≤1.8 时为 1，否则把峰值压进 [1.8, 4.3)。
/// ⚠️ 只作用于可见天空，绝不能进 IBL —— 原版注释写明它不该压 PBR 能量。
float sunset_display_scale(float peak) {
	if (peak <= 1.8) {
		return 1.0;
	}
	return (1.8 + 2.5 * (peak - 1.8) / (2.5 + peak - 1.8)) / peak;
}

// ---------------------------------------------------------------------------
// 日落天色（原版 city-world.ts 的 szSky 片元，逐行照搬）
//  ⚠️ 原版日落档露的是摄影 HDR；这一段只是 HDR 解码完之前的兜底。
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

/// 绕 Y 轴旋转采样方向（弧度）。
///
/// 方向约定与 PanoramaSkyMaterial.rotation 一致：HDR 的 rotationY 转的是
/// **贴图内容**，所以反查贴图时要用 −angle 旋转视线方向。
/// 参考引擎 sky.glsl：`panorama_coords = atan2(x, −z)`，全景 UV 的 u 轴
/// 随绕 Y 的旋转按同一方向平移。
vec3 rotate_y(vec3 d, float angle) {
	if (angle == 0.0) {
		return d;
	}
	float c = cos(angle);
	float s = sin(angle);
	// 绕 +Y 的标准旋转（Godot 右手系：x' = x·cos + z·sin, z' = −x·sin + z·cos）
	return vec3(d.x * c + d.z * s, d.y, -d.x * s + d.z * c);
}

/// 全景的 UV 约定照抄引擎源码（`environment/sky.glsl` 的 `panorama_coords`）：
///   u = atan2(x, −z)（负值加 2π）/ 2π，v = acos(y) / π
/// d 必须是**已经转到该 HDR 自身空间**的方向（不再含旋转）。
vec2 panorama_uv(vec3 d) {
	float u = atan(d.x, -d.z);
	if (u < 0.0) {
		u += PI * 2.0;
	}
	return vec2(u / (PI * 2.0), acos(clamp(d.y, -1.0, 1.0)) / PI);
}

/// Babylon 来源 HDR 全景的统一采样（等距柱状文件）：
/// 先 z 镜像换到 Babylon 空间（z=北），再 R(−rot)，再补 90°
/// （Babylon CalcProjectionSpherical 的 u 原点在 +X 轴，Godot panorama_uv
/// 的 u 原点在 −Z 轴）。逐点核对依据见 sunset_hdr_sky 的注（修复记录 二十九）。
vec2 babylon_panorama(vec3 d, float rot) {
	vec3 t = rotate_y(vec3(d.x, d.y, -d.z), -rot);
	return panorama_uv(rotate_y(t, PI * 0.5));
}

/// 立方图空间方向（火掩码 / 任何「Babylon 面方向」语义的计算都用它）
vec3 babylon_cube_dir(vec3 d, float rot) {
	return rotate_y(vec3(d.x, d.y, -d.z), -rot);
}

/// rot 是该 HDR 自己的绕 Y 旋转角（弧度）。
/// ⚠️ 只用于白天档（无分级的原始 HDR）。日落档的采样/分级走
/// babylon_panorama / babylon_cube_dir，两者方向不同（见 sunset_hdr_sky）。
vec2 dir_to_panorama(vec3 d, float rot) {
	return babylon_panorama(d, rot);
}

/// 日落档可见天空 = 摄影 HDR × 原版分级链 × 高光肩部 × primaryColor。
///
/// ⚠️ 采样方向与分级方向**不是同一个方向**（修复记录 二十九，2026-10-21）：
/// 立方图空间方向 t = R(−rot)·Mz·d（火掩码在此计算），文件采样列 =
/// u_b(t) = panorama_uv(R(π/2)·t)。分级链的火区掩码在立方图空间「朝阳」
/// （dump 实测：火区在 +X 面），落到文件网格上命中的是别的列 ——
/// 分级链的本质是把文件里的蓝灰云**染成**橙金色。
/// 逐点核对：视线中心 → t=(0.982,0,−0.191) → dump right 面 60% 列 =
/// (246,119,50) 亮火 → ×0.20 过 ACES ≈ 原版实测 (171,88,53) ✓。
vec3 sunset_hdr_sky(vec3 p) {
	vec3 t = babylon_cube_dir(p, sunset_rot);
	vec3 raw = texture(sunset_pano, babylon_panorama(p, sunset_rot)).rgb;
	vec3 graded = grade_sunset_radiance(t, raw);
	float peak = max(max(graded.r, graded.g), graded.b);
	return graded * sunset_display_scale(peak) * sunset_bg_gain;
}

/// 白天可见背景 = HDR 全景。
///
/// ⚠️ 读哪个槽由 `day_uses_b` 显式决定（GDScript 侧知道当前白天档在A 还是 B），
/// 不再靠 mode_b / env_blend 反推 —— 可见背景与 IBL 淡化是两件独立的事。
vec3 panorama_sky(vec3 p) {
	if (day_uses_b) {
		return texture(base_sky_b, dir_to_panorama(p, hdr_rot_b)).rgb * base_energy_b;
	}
	return texture(base_sky, dir_to_panorama(p, hdr_rot_a)).rgb * base_energy;
}

/// IBL 立方图的一个槽：夜晚 = 中性环境；日落 = 分级后的摄影 HDR；白天 = 原始 HDR 全景。
/// 三者都乘各自的能量（= 原版 scene.environmentIntensity）。
/// d 是**世界空间**方向（不做 z 取反 —— 旋转在各自的 HDR 角度里处理）。
vec3 env_slot(float m, vec3 d, sampler2D tex, float energy, float rot) {
	if (m < 0.5) {
		return night_environment(d) * energy;
	}
	if (m < 1.5) {
		// 日落档：原版 `scene.environmentTexture` 就是**分级后**的 belfast HDR
		// （ShenzhenSunsetEnvironment 在解码时逐面跑 gradeSunsetRadiance）。
		// 只有可见天空才叠肩部滚降，辐照度保持全动态范围。
		// ⚠️ 分级方向（立方图空间）与文件采样列不同（见 sunset_hdr_sky）
		vec3 t = babylon_cube_dir(d, rot);
		vec3 raw = texture(tex, babylon_panorama(d, rot)).rgb;
		return grade_sunset_radiance(t, raw) * energy;
	}
	return texture(tex, dir_to_panorama(d, rot)).rgb * energy;
}

/// 单档可见天空：0 夜晚 / 1 日落 / 2 白天（整数档的画面）
vec3 sky_look_at(float m, vec3 p) {
	if (m < 0.5) {
		return night_sky(p);
	}
	if (m < 1.5) {
		return sunset_uses_hdr ? sunset_hdr_sky(p) : sunset_sky(p) * sky_gain;
	}
	return panorama_sky(p);
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
		// 辐照度立方图：夜晚档 = 原版中性环境 × 能量；日落 = 分级后的摄影 HDR × 能量；
		// 白天 = HDR 全景 × 能量。静止时单槽单次采样；过渡期间 A/B 两槽按 env_blend 交叉淡化。
		//
		// ⚠️ 这里用**世界空间**方向（不做 z 取反）。以前写的是
		// `vec3(EYEDIR.x, EYEDIR.y, -EYEDIR.z)`，那是给 night_environment 的
		// Babylon 空间约定准备的 —— 但它内部只读d.y，那个取反其实毫无作用；
		// 而同一个取反却被顺手带给了 HDR 全景采样，导致**立方图里的 HDR 是
		// 可见背景那张全景的镜像**（可见背景用未取反的 EYEDIR）。
		// 表现：湿路/水面的天空倒影与头顶的天空左右相反。
		vec3 a = env_slot(mode_a, EYEDIR, base_sky, base_energy, hdr_rot_a);
		if (env_blend <= 0.001) {
			COLOR = a;
		} else {
			vec3 b = env_slot(mode_b, EYEDIR, base_sky_b, base_energy_b, hdr_rot_b);
			COLOR = mix(a, b, env_blend);
		}
	} else {
		// 可见背景：全分辨率逐像素（原版同款），不做半分辨率降采样。
		COLOR = visible_sky(EYEDIR);
	}
}
