shader_type canvas_item;
render_mode unshaded;

// 加载画面暗角 —— 逐值换算原版 src/city-loading.css 的
//
//   .city-loader-vignette{
//     background:
//       linear-gradient(90deg,#f3efe6d9 0,#f1ede3a3 29%,#edf0e50a 60%,transparent 80%),
//       linear-gradient(0deg,#e9e6dccf 0,#e9e6dc66 17%,transparent 40%);
//   }
//
// CSS 的 `background: g1, g2` 是 g1 盖在 g2 之上，两层都是带 alpha 的同一族
// “暖纸色”，所以这里按**直式 alpha 合成**算出图层本身（无预乘），再交给
// Godot 的 mix 混合去叠到海报上 —— 顺序、透明度、色标位置都与 CSS 一致。
//
// 色标 alpha（十六进制 → 浮点）：d9=.851 / a3=.639 / 0a=.039 / cf=.812 / 66=.400
// 顶层竖向的 0deg 是从**下往上**，因此取 t = 1 − UV.y。

const vec3 C1_0 = vec3(0.953, 0.937, 0.902); // #f3efe6
const vec3 C1_1 = vec3(0.945, 0.929, 0.890); // #f1ede3
const vec3 C1_2 = vec3(0.929, 0.941, 0.898); // #edf0e5
const vec3 C2 = vec3(0.914, 0.902, 0.863);   // #e9e6dc

// 顶层：linear-gradient(90deg, ...) —— 0 / 29% / 60% / 80%
void top_layer(vec2 uv, out vec3 rgb, out float a) {
	float x = uv.x / 0.80;
	float s1 = 0.29 / 0.80;              // 0.3625
	float s2 = 0.60 / 0.80;              // 0.75
	if (x <= s1) {
		float k = x / s1;
		rgb = mix(C1_0, C1_1, k);
		a = mix(0.851, 0.639, k);
	} else if (x <= s2) {
		float k = (x - s1) / (s2 - s1);
		rgb = mix(C1_1, C1_2, k);
		a = mix(0.639, 0.039, k);
	} else {
		float k = clamp((x - s2) / (1.0 - s2), 0.0, 1.0);
		rgb = C1_2;
		a = mix(0.039, 0.0, k);
	}
	if (x >= 1.0) {
		a = 0.0;
	}
}

// 底层：linear-gradient(0deg, ...) —— 0 / 17% / 40%（自下而上）
void bottom_layer(vec2 uv, out vec3 rgb, out float a) {
	float t = (1.0 - uv.y) / 0.40;
	float s1 = 0.17 / 0.40;              // 0.425
	rgb = C2;
	if (t <= s1) {
		a = mix(0.812, 0.400, t / s1);
	} else {
		a = mix(0.400, 0.0, clamp((t - s1) / (1.0 - s1), 0.0, 1.0));
	}
	if (t >= 1.0) {
		a = 0.0;
	}
}

void fragment() {
	vec2 uv = UV;
	vec3 rgb_b;
	float a_b;
	bottom_layer(uv, rgb_b, a_b);
	vec3 rgb_t;
	float a_t;
	top_layer(uv, rgb_t, a_t);

	// 直式 alpha 的 src-over：out = top over bottom
	float a = a_t + a_b * (1.0 - a_t);
	vec3 rgb = a > 0.0 ? (rgb_t * a_t + rgb_b * a_b * (1.0 - a_t)) / a : vec3(0.0);
	COLOR = vec4(rgb, a);
}
