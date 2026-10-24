shader_type spatial;
// 雨天积水片（P2b）—— 替代旧的暗色 StandardMaterial3D。
//
// 旧材质只有 IBL/SSR 反射；现在接入 planar_mirror 的平面镜纹理（与水面
// 同源），路边积水里能读到建筑/天空的真实倒影。
// ⚠️ 镜面平面标定在水面高度（−0.25m），积水片在 0.10m，SCREEN_UV 投影
// 有 ~0.35m 的视差偏移 —— 车行视角下不可感，接受该近似（修复记录 三十）。
// mirror_strength = 0 时（低画质档）退回纯暗色 + SSR 旧路径。

render_mode blend_mix, depth_draw_opaque, cull_disabled;

uniform vec4 base_color : source_color = vec4(0.025, 0.036, 0.045, 0.85);
uniform float rough : hint_range(0.0, 1.0) = 0.075;
uniform float spec : hint_range(0.0, 1.0) = 0.85;
uniform float rim_amount : hint_range(0.0, 1.0) = 0.2;
uniform sampler2D mirror_tex : hint_default_black, filter_linear_mipmap;
uniform float mirror_strength : hint_range(0.0, 1.0) = 0.0;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	ALBEDO = base_color.rgb;
	ALPHA = base_color.a;
	ROUGHNESS = rough;
	METALLIC = 0.0;
	SPECULAR = spec;
	RIM = rim_amount;
	if (mirror_strength > 0.0) {
		vec3 V = normalize(CAMERA_POSITION_WORLD - v_world);
		float cos_i = clamp(V.y, 0.0, 1.0);   // 积水面法线恒朝上
		float fresnel = 0.04 + 0.96 * pow(1.0 - cos_i, 5.0);
		vec2 muv = vec2(SCREEN_UV.x, 1.0 - SCREEN_UV.y);
		muv = clamp(muv, vec2(0.002), vec2(0.998));
		vec3 refl = texture(mirror_tex, muv).rgb;
		EMISSION += refl * fresnel * mirror_strength;
	}
}
