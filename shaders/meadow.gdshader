shader_type spatial;
// 草叶层材质 —— 对应原版 city-meadow.ts 的 `city-meadow-pbr` + MeadowMotion。
//
// 与原版逐项对应：
//   · 不透明 PBR，metallic 0 / roughness .95 / 无自发光贴图 / 无双面剔除（草叶是薄片）
//   · 顶点色（每片叶片的明度渐变）× 逐实例色（暖度与干湿变化）
//   · 逐实例风摆与距离淡出：range/phase 走 INSTANCE_CUSTOM
//     （原版是自定义顶点属性 `meadowParams`，Babylon 的 thin instance 每实例两分量；
//      Godot 里对应的就是 MultiMesh 的 custom data，`set_instance_custom_data`）
//   · 夜里叠加一层很低的天空地板（原版 applyLandscapeNightLight(...,'grass') = .05）

render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 albedo_tint : source_color = vec4(0.10, 0.15, 0.045, 1.0);
uniform float roughness_value : hint_range(0.0, 1.0) = 0.95;
/// xyz = 相机世界位置，w = 累计时间（原版 meadowEyeTime）
uniform vec4 meadow_eye_time = vec4(0.0, 0.0, 0.0, 0.0);
/// x = 夜间强度 0/1，y = 地面自发光地板 .05，z = 漫射增益，w = 粗糙度下压量
uniform vec4 city_landscape_night = vec4(0.0, 0.05, 1.12, 0.12);
/// 逐材质环境光强度（原版 city-meadow.ts:187 的 `environmentIntensity = .85`）。
/// Godot 的 `AO` 乘的正是「环境光 + 反射」，所以用它表达。
uniform float env_scale = 0.85;

void vertex() {
	vec3 local = VERTEX;
	vec3 root = (MODEL_MATRIX * vec4(local, 1.0)).xyz;

	// 距离淡出：超过 range 乘以 fade → 叶片向根部收缩（不是缩小整株）
	float mrange = max(INSTANCE_CUSTOM.x, 1.0);
	float fade = 1.0 - smoothstep(mrange * 0.70, mrange, distance(meadow_eye_time.xz, root.xz));
	fade *= 1.0 - smoothstep(9.0, 16.0, abs(meadow_eye_time.y - root.y));

	float y = local.y;
	float phase = INSTANCE_CUSTOM.y + root.x * 0.23 + root.z * 0.19;
	vec2 wind = vec2(sin(meadow_eye_time.w * 1.38 + phase),
		cos(meadow_eye_time.w * 1.07 + phase) * 0.45) * 0.10;
	VERTEX.xz += wind * y * y;
	VERTEX *= fade;
}

void fragment() {
	// COLOR = 网格顶点色 × MultiMesh 逐实例色
	vec3 base = albedo_tint.rgb * COLOR.rgb;
	ALBEDO = base;
	ROUGHNESS = roughness_value;
	METALLIC = 0.0;
	SPECULAR = 0.32;
	// 逐材质环境光强度：AO 只用来缩放环境光，不影响直射
	AO = 1.0 / max(env_scale, 0.02);
	AO_LIGHT_AFFECT = 0.0;

	// 夜间天空地板（原版 NIGHT_GROUND_FLOOR.grass）
	if (city_landscape_night.x > 0.001) {
		float sky_facing = 0.72 + 0.28 * clamp(NORMAL.y, 0.0, 1.0);
		EMISSION += base * city_landscape_night.x * city_landscape_night.y * sky_facing;
	}
}
