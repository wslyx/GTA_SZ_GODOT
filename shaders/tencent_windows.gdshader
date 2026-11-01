shader_type spatial;
// 腾讯滨海大厦幕墙：逐窗格亮灯（移植原版 city-landmark-lighting.ts 的
// MaterialPlugin 片元注入，并按本仓库资产做了等价调整）。
//
// 输入来自 tencent_windows.gd 重建的顶点数据：
//   UV    = (u, v)  —— 该条玻璃自己的局部坐标（0..1；u 横跨竖条，v 从底到顶）
//   COLOR = (seed, is_pane, 0, 1)
//             seed:    每条一个稳定随机种子（偏冷 / 偏暖）
//             is_pane: 1 = 这块属于恢复出来的窗列，0 = 大墙/屋顶等，不发光
//
// ⚠️ 原版是"每个四边形就是一个窗格"，逐格直接按 active 点亮；本仓库的幕墙是
// 6058 条**通高竖条**，所以竖直方向按 `floors` 切格、逐格 hash 决定亮不亮。
// 视觉结果一致：随机点亮的窗格 + 顶部标识带留暗 + 窗框分隔。

render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 base_albedo : source_color = vec4(0.10, 0.12, 0.14, 1.0);
uniform float metallic : hint_range(0.0, 1.0) = 0.55;
uniform float roughness : hint_range(0.0, 1.0) = 0.22;

// 光照档增益（脚本按 day / sunset / night 写 0 / 0.55 / 1.5）
uniform float window_hdr : hint_range(0.0, 3.0) = 0.0;

// 楼层数：整楼 148.8m / 约 3.6m 一层 ≈ 41
uniform float floors : hint_range(1.0, 80.0) = 41.0;
// 开灯比例（原版 hash > .68 ≈ 三成）
uniform float lit_ratio : hint_range(0.0, 1.0) = 0.32;
// 顶部标识带（原版 centre.y < 137m，占全高约 0.92）保持暗，好让白色顶标读得出来
uniform float top_dark : hint_range(0.0, 1.0) = 0.92;

varying vec2 v_pane;
varying float v_seed;
varying float v_is_pane;

float hash11(float x) {
	return fract(sin(x * 127.1) * 43758.5453123);
}

void vertex() {
	v_pane = UV;
	v_seed = COLOR.r;
	v_is_pane = COLOR.g;
}

void fragment() {
	// 到格边的距离 → 窗框（原版 .015/.055 的 smoothstep 边距，同一组数）
	// uv.x 已在 CPU 侧乘过"这一条的列数"，这里只补竖直方向的楼层切格
	vec2 cell = vec2(v_pane.x, v_pane.y * floors);
	vec2 edge = min(fract(cell), vec2(1.0) - fract(cell));
	// 边距比原版略宽一点：这块幕墙的格子是"按 2.4m 折出来的"，留出看得见的窗框
	float mask = smoothstep(0.02, 0.10, edge.x) * smoothstep(0.02, 0.10, edge.y);
	mask *= v_is_pane;

	// 逐格点亮：**列号 × 层号 × 该列种子** 三者一起决定这一格亮不亮、多亮。
	// ⚠️ 必须带列号：uv.x 是 CPU 侧乘过列数的，floor(uv.x) 就是列下标；
	// 只用种子 + 层号会让整条（十几米宽）一起亮，看着是一条条横杠。
	float col_index = floor(v_pane.x);
	float floor_index = floor(v_pane.y * floors);
	float rnd = hash11(v_seed * 977.0 + col_index * 137.3 + floor_index * 31.7);
	float lit = step(1.0 - lit_ratio, rnd);
	float level = 0.90 + 0.20 * hash11(v_seed * 613.0 + col_index * 53.1 + floor_index * 7.3);

	// 顶部标识带不亮（原版同一意图）
	float band = step(v_pane.y, top_dark);

	vec3 room = mix(vec3(0.85, 0.92, 1.0), vec3(1.0, 0.86, 0.66), v_seed);

	ALBEDO = base_albedo.rgb;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	EMISSION = room * window_hdr * (lit * level * band) * mask;
}
