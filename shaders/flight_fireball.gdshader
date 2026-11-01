shader_type spatial;
// 飞行撞毁的火球体积 —— 移植原版 src/city-flight-explosion.ts 的片元
// （球体内部 28 步 fbm 光线步进、自遮挡、烟尘夹层）。
//
// 与原版的对应关系：
//   - 原版盒子 size=2（局部 ±1），解析求单位球交点后沿视线 28 步步进；
//     本移植同样用 ±1 的 BoxMesh，ro 由 `eye_world` uniform 经模型逆矩阵变换到局部。
//   - `eye_world` 由脚本每帧喂（= 相机世界坐标），与原版 onBind 里 setVector3 同款。
//   - age / seed / heat / opacity 也由脚本按 fireballEnvelope 驱动。
//
// 纪录片式细节都保留：噪声团块自遮挡、热褶皱之间的烟尘口袋、随 age 下沉的
// 湍流场与左右摆动。

render_mode blend_mix, unshaded, cull_back, depth_draw_never, shadows_disabled;

uniform vec3 eye_world = vec3(0.0, 2.0, 0.0);
uniform float age = 0.0;
uniform float seed = 1.3;
uniform float heat = 1.0;
uniform float opacity = 1.0;

varying vec3 v_local;
varying vec3 v_ro;

float hash(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash(i), hash(i + vec3(1.0, 0.0, 0.0)), f.x),
			mix(hash(i + vec3(0.0, 1.0, 0.0)), hash(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
		mix(mix(hash(i + vec3(0.0, 0.0, 1.0)), hash(i + vec3(1.0, 0.0, 1.0)), f.x),
			mix(hash(i + vec3(0.0, 1.0, 1.0)), hash(i + vec3(1.0, 1.0, 1.0)), f.x), f.y), f.z);
}

float fbm(vec3 p) {
	float n = noise(p) * 0.56;
	n += noise(p * 2.07 + 8.3) * 0.28;
	n += noise(p * 4.13 + 19.1) * 0.16;
	return n;
}

// fire(h)：暗 → 红 → 橙 → 黄白 的四段 smoothstep（与原版逐字一致）
vec3 fire(float h) {
	vec3 c = mix(vec3(0.038, 0.030, 0.029), vec3(0.32, 0.047, 0.008), smoothstep(0.12, 0.42, h));
	c = mix(c, vec3(1.9, 0.26, 0.012), smoothstep(0.38, 0.74, h));
	c = mix(c, vec3(3.1, 1.12, 0.075), smoothstep(0.72, 1.03, h));
	return mix(c, vec3(3.6, 2.05, 0.58), smoothstep(1.08, 1.34, h));
}

void vertex() {
	v_local = VERTEX;
	v_ro = (inverse(MODEL_MATRIX) * vec4(eye_world, 1.0)).xyz;
}

void fragment() {
	vec3 ro = v_ro;
	vec3 rd = normalize(v_local - ro);
	float b = dot(ro, rd);
	float disc = b * b - dot(ro, ro) + 1.0;
	if (disc <= 0.0) {
		discard;
	}
	float root = sqrt(disc);
	float enter = max(0.0, -b - root);
	float leave = -b + root;
	if (leave <= enter) {
		discard;
	}
	float stride = (leave - enter) / 28.0;
	vec3 sum = vec3(0.0);
	float alpha = 0.0;
	// 步进一个真正的噪声体积，而不是叠自发光软圆：每团云自遮挡，
	// 热褶皱之间夹着烟尘。
	for (int i = 0; i < 28; i++) {
		vec3 p = ro + rd * (enter + (float(i) + 0.45) * stride);
		vec3 q = p * 3.35 + vec3(seed, seed * 0.27, -seed * 0.43);
		q.y -= age * 0.88;
		q.x += sin(q.y * 1.7 + age * 1.9) * 0.23;
		float n = fbm(q);
		float r = length(p);
		float shell = 1.0 - r;
		float density = smoothstep(0.05, 0.40, shell + (n - 0.53) * 0.69) * 2.9;
		float a = 1.0 - exp(-density * stride * 3.6);
		float temperature = heat + (n - 0.5) * 1.95 - shell * 0.06 - r * 0.12;
		vec3 col = fire(temperature);
		float soot_light = 0.55 + 0.45 * clamp(p.y * 0.6 - p.x * 0.25 + 0.5, 0.0, 1.0);
		col = mix(vec3(0.052, 0.057, 0.062) * soot_light, col, smoothstep(0.12, 0.40, temperature));
		sum += (1.0 - alpha) * col * a;
		alpha += (1.0 - alpha) * a;
		if (alpha > 0.985) {
			break;
		}
	}
	if (alpha < 0.015) {
		discard;
	}
	// unshaded + blend_mix：EMISSION 不参与，颜色直接走 ALBEDO（HDR 值交给色调映射）
	ALBEDO = sum / max(alpha, 0.001);
	ALPHA = alpha * opacity;
}
