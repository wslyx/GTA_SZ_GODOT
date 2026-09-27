shader_type spatial;
// 建筑立面 PBR —— 给 city-architecture-materials.ts 用。
//
// 为什么必须换成 ShaderMaterial：原版每个 profile 都有
// `material.environmentIntensity`（.96 基准，0.85–1.08 不等），而
// `StandardMaterial3D` **没有**这个属性、`fragment()` 里也没有 `AMBIENT_LIGHT`
// （实测报 `Unknown identifier`）。但 Godot 的 `AO` 乘的正是「环境光 + 反射」，
// 与原版 `environmentIntensity` 的作用对象一致 —— 于是
//
//     AO = 1.0 / env_scale;  AO_LIGHT_AFFECT = 0.0;
//
// 就是逐材质的环境光缩放（`AO_LIGHT_AFFECT = 0` 保证不波及直射）。
// 这也是 README 里"建筑比原版亮约 1.7 倍"的正解 —— 原版是把环境光压到 .96 以下。
//
// 其余参数逐项对应 profile / 源材质：
//   反照率（贴图 × 颜色 × 顶点色）、UV 缩放、法线贴图、粗糙度、金属度、镜面强度、
//   自发光（窗格掩码贴图 × 颜色 × 强度，白天 0 / 黄昏 .45 / 夜 1.35）。
//
// 剔除：⚠️ 建筑/地标 GLB 的材质全部是 **doubleSided: true**（370/370），原版
// Babylon 导入后 backFaceCulling=false（双面渲染，从不剔除这些面——楼体三角形
// 绕序是混合的，64% 反向，单面剔除必然"看见楼内远墙、近墙消失"）。这里必须
// cull_disabled；双面光照按 Babylon twoSidedLighting 的做法在 fragment 里
// 对背面法线取反。

render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform bool use_albedo_tex = false;
uniform sampler2D albedo_tex : source_color, hint_default_white;
uniform vec4 albedo_tint : source_color = vec4(1.0);
uniform vec2 uv_scale = vec2(1.0, 1.0);

uniform bool use_normal_tex = false;
uniform sampler2D normal_tex : hint_normal;
uniform float normal_depth : hint_range(0.0, 2.0) = 1.0;

uniform float roughness_value : hint_range(0.0, 1.0) = 0.8;
uniform float metallic_value : hint_range(0.0, 1.0) = 0.0;
uniform float specular_value : hint_range(0.0, 1.0) = 0.5;

/// 窗光：颜色 ×（掩码贴图）× 强度。强度为 0 时整项不参与。
uniform bool use_emission_tex = false;
uniform sampler2D emission_tex : source_color, hint_default_white;
uniform vec4 emission_color : source_color = vec4(1.0, 0.94, 0.83, 1.0);
uniform float emission_energy = 0.0;

/// 逐材质环境光强度（原版 `profile.environment ?? .96`）
uniform float env_scale = 0.96;

void vertex() {
	UV = UV * uv_scale;
}

void fragment() {
	// 双面光照（Babylon twoSidedLighting）：背面法线取反，否则内壁全黑
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	vec3 base = albedo_tint.rgb;
	if (use_albedo_tex) {
		base *= texture(albedo_tex, UV).rgb;
	}
	// 顶点色是乘性的（原版：有顶点色就 useVertexColors=true）；
	// 网格没有顶点色时 Godot 会把它设成白色，等于不生效。
	base *= COLOR.rgb;
	ALBEDO = base;

	if (use_normal_tex) {
		NORMAL_MAP = texture(normal_tex, UV).rgb;
		NORMAL_MAP_DEPTH = normal_depth;
	}

	ROUGHNESS = roughness_value;
	METALLIC = metallic_value;
	SPECULAR = specular_value;

	if (emission_energy > 0.0001) {
		vec3 e = emission_color.rgb;
		if (use_emission_tex) {
			e *= texture(emission_tex, UV).rgb;
		}
		EMISSION = e * emission_energy;
	}

	// 逐材质环境光强度：AO 只缩放环境光与反射，不影响直射
	AO = 1.0 / max(env_scale, 0.02);
	AO_LIGHT_AFFECT = 0.0;
}
