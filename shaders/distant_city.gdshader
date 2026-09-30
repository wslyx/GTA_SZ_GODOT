shader_type spatial;
render_mode cull_disabled, shadows_disabled, specular_schlick_ggx;

// 远景城市壳 —— 对应原版 city-distant-city.ts 的 DistantWindows 材质插件
// （MaterialPluginBase 译成 gdshader）+ PBRMaterial 的固定参数。
//
// 原版逻辑（fragment 里 CUSTOM_FRAGMENT_BEFORE_FINALCOLORCOMPOSITION）：
//   · 只在墙面发光（|normal.y| 越小越是墙）；
//   · 窗格按世界坐标切成 3.2m × 3.3m 的格子，每 3×2 格一间"房"，
//     用房间号 + 建筑种子做哈希决定这间房是否亮灯（48% 占用）；
//   · 远处格子（屏幕导数大到分辨不清）退化为 0.18 的均匀微光，避免闪烁；
//   · 色温按种子插值：暖黄 (1,.73,.45) → 冷白 (.75,.84,1)；
//   · 夜间增益 night_gain 由 set_mode 控制：夜 2.4 / 黄昏 .85 / 白天 0。
//
// 注意：网格顶点即世界坐标（节点无变换），所以 vertex 里的 NORMAL/VERTEX
// 就是世界空间法线/位置，不必再做 model_to_world。

uniform float night_gain = 0.85;

varying vec3 w_normal;
varying vec3 w_pos;
varying float v_seed;

void vertex() {
	w_normal = NORMAL;
	w_pos = VERTEX;
	v_seed = COLOR.a;
}

void fragment() {
	// PBRMaterial：albedo 白、metallic 0、roughness .88、specular .18、
	// environmentIntensity .65（本版用 0.85 的整体压暗近似环境强度差）。
	ALBEDO = COLOR.rgb * 0.85;
	METALLIC = 0.0;
	ROUGHNESS = 0.88;
	SPECULAR = 0.18;

	// —— 以下逐行对应原版 DistantWindows 的 GLSL ——
	float distant_wall = 1.0 - smoothstep(0.3, 0.75, abs(w_normal.y));
	vec2 distant_cell = vec2(dot(w_pos.xz, vec2(w_normal.z, -w_normal.x)) / 3.2, w_pos.y / 3.3);
	vec2 distant_room = floor(distant_cell / vec2(3.0, 2.0));
	float distant_occupied = step(0.48, fract(sin(dot(distant_room, vec2(12.9898, 78.233)) + v_seed * 97.0) * 43758.5453));
	vec2 pane = fract(distant_cell);
	float distant_pane = step(0.22, pane.x) * step(pane.x, 0.78) * step(0.20, pane.y) * step(pane.y, 0.79);
	// Vulkan（WEBGL2 分支）永远有 dFdx/dFdy
	float distant_unresolved = smoothstep(0.24, 1.1, max(length(dFdx(distant_cell)), length(dFdy(distant_cell))));
	float distant_light = mix(distant_pane * distant_occupied, 0.18, distant_unresolved);
	vec3 distant_tint = mix(vec3(1.0, 0.73, 0.45), vec3(0.75, 0.84, 1.0), smoothstep(0.70, 0.95, v_seed));
	EMISSION += distant_tint * distant_light * night_gain * distant_wall;
}
