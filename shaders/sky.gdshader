shader_type spatial;
// 程序化城市天空 —— **逐行**移植原版 city-world.ts 的 szSky 片元着色器。
//
// 原版源码（src/city-world.ts:230-242，保持 GLSL 语句顺序与常量不变）：
//
//   vec3 p = normalize(vP);
//   vec3 sd = normalize(vec3(-.95,.16,-.18));
//   float west  = pow(max(0.,dot(p,sd)),4.);
//   float h     = smoothstep(-.05,.72,p.y);
//   vec3 horizon = mix(vec3(.42,.24,.35), vec3(.94,.32,.115), west);
//   vec3 c = mix(horizon, vec3(.047,.12,.25), h);
//   float glow = pow(max(0.,dot(p,sd)),22.);
//   c += vec3(.5,.18,.055)*glow;
//   float sun  = pow(max(0.,dot(p,sd)),4200.);
//   c += vec3(5.,2.2,.6)*sun;
//   vec2 uv = p.xz/max(.14, p.y+.08)*2.0;
//   uv.x *= .52;
//   float cloud  = fbm(uv + fbm(uv*.4)*1.6);
//   float stripe = noise(vec2(uv.x*.8, uv.y*4.)) * .13;
//   float mask   = smoothstep(.40,.66, cloud+stripe) * smoothstep(.01,.12,p.y)
//                  * (1.-smoothstep(.55,.99,p.y));
//   vec3 cloudDark = mix(vec3(.18,.17,.29), vec3(.38,.16,.20), west);
//   vec3 cloudLit  = mix(vec3(.68,.31,.38), vec3(1.25,.34,.10), west);
//   float rim = smoothstep(.46,.53,cloud)*(1.-smoothstep(.54,.65,cloud));
//   vec3 cloudColor = mix(cloudDark, cloudLit, rim*.85 + .24*west);
//   c = mix(c, cloudColor, mask*.85);
//   c = mix(c, c*vec3(.12,.22,.44), night);
//
// ⚠️ 移植版原先用自己的 horizon/zenith 两个 uniform 重新调了一版（天顶色
// 写成 0.20/0.30/0.52 的蓝、地平线写死一个暖色、完全没有 west 方向混合），
// 云也换成了完全不同的公式（无 domain warp、按仰角遮罩）。结果是日落天空
// 从「背阳紫 + 朝阳橙」的双色结构退化成一整片均匀的粉橙色 —— 实测天顶行
// 均值 #c88b87，原版是 #976451。所以这里回到逐行照搬，不再自创参数。
//
// 深度：保留 depth_draw_never（天空球不写深度）+ 开启深度测试。
// 天空只落在「还没有任何东西」的像素上，远处山体（>4000m）也能压在天空之上。
// sd 的方向常量做了**一次坐标符号修正**（其余逐字照搬）：
//
//   原版     vec3 sd = normalize(vec3(-.95, .16, -.18));
//   本移植版 vec3 sd = normalize(vec3(-.95, .16,  .18));
//
// 原因：本项目的世界约定是 `z = −北`（见 README 第三节）。原版源码里这个常量
// 写在 Babylon 的世界坐标下（z = +北），照抄到 Godot 会把日落辉光的方位角
// 翻到天空的另一侧 —— 实测辉光中心落在画面 x≈1400（中心偏右），而原版截图里
// 它在消失点正上方。z 取反后与 DirectionalLight3D 的太阳方位
// (`sun_dir_data` = (.934,-.187,.305) → Godot (.934,-.187,-.305)，太阳在西南)
// 才互相吻合。
render_mode unshaded, cull_disabled, depth_draw_never, fog_disabled;

uniform float night : hint_range(0.0, 1.0) = 0.0;
// 整片天空的显示增益。原版天空不是"物理正确"的亮度：Babylon 的曝光/ACES 把
// 0.42~0.94 的着色器输出压到显示端 0.30~0.70，而 Godot 的 ACES 在同曝光下
// 几乎不做压缩。按原版截图实测标定（见 tools/compare_shots.py 的天空列）。
uniform float sky_gain : hint_range(0.0, 2.0) = 1.0;

varying vec3 v_local;

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

float fbm(vec2 p) {
	float f = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		f += noise(p) * a;
		p = p * 2.03 + 17.0;
		a *= 0.5;
	}
	return f;
}

void vertex() {
	v_local = VERTEX;
}

void fragment() {
	vec3 p = normalize(v_local);
	vec3 sd = normalize(vec3(-0.95, 0.16, 0.18));
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
	float cloud = fbm(uv + fbm(uv * 0.4) * 1.6);
	float stripe = noise(vec2(uv.x * 0.8, uv.y * 4.0)) * 0.13;
	float mask = smoothstep(0.40, 0.66, cloud + stripe)
		* smoothstep(0.01, 0.12, p.y)
		* (1.0 - smoothstep(0.55, 0.99, p.y));
	vec3 cloudDark = mix(vec3(0.18, 0.17, 0.29), vec3(0.38, 0.16, 0.20), west);
	vec3 cloudLit = mix(vec3(0.68, 0.31, 0.38), vec3(1.25, 0.34, 0.10), west);
	float rim = smoothstep(0.46, 0.53, cloud) * (1.0 - smoothstep(0.54, 0.65, cloud));
	vec3 cloudColor = mix(cloudDark, cloudLit, rim * 0.85 + 0.24 * west);
	c = mix(c, cloudColor, mask * 0.85);
	c = mix(c, c * vec3(0.12, 0.22, 0.44), night);

	ALBEDO = c * sky_gain;
}
