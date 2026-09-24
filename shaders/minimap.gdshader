shader_type canvas_item;
// 小地图显示端 —— 移植原版 city-hud.ts `drawCinematicMinimap` 的后半段。
//
// 原版把 1024×1024 的 source plane（地图内容，随玩家朝向旋转）按**逐扫描线**
// 的方式做透视压扁投到 320×320 的输出上：
//
//   c = cos(tilt), s = sin(tilt)
//   project(y) = { q = (y-208)/(c + (y-208)*s/480), stretch = 1 - q*s/480 }
//   对 y 每 2px 一行：
//     a = project(y); b = project(y+2)
//     drawImage(plane, 512-160*a.stretch, 740+a.y, 320*a.stretch, b.y-a.y,  0, y, 320, 2.1)
//
// 这个映射是**逐行可逆**的，所以不必真的逐行 drawImage —— 在着色器里求逆即可：
//
//   dy = Y-208;  q = dy/(c + dy*s/480);  stretch = 1 - q*s/480
//   plane.x = 512 + (X-160)*stretch;      plane.y = 740 + q
//
// 之后依次叠加原版的三步：圆形裁切（圆心 (160,160)、半径 159）、
// 顶部雾霭渐变（y 0→245 由 rgba(48,83,99,.30) 渐隐）、底色 #19343e。

// 采样源是 TextureRect 自带的贴图（= source plane 的 SubViewport 纹理），
// 用 TEXTURE 而不是额外的 uniform，UV 一定有效。
uniform float tilt : hint_range(0.0, 1.2) = 0.40;
uniform float haze_amount : hint_range(0.0, 1.0) = 0.30;

// 输出按 320 逻辑像素设计（与原版 MAP_SIZE 一致）
const float OUT_SIZE = 320.0;
const float PLANE_PX = 1024.0;
// source plane 画布是 768×768（原版 setTransform(.75) 之后），即 1024 × 0.75
const float TEX_SCALE = 0.75;

void fragment() {
	vec2 p = UV * OUT_SIZE;
	float c = cos(tilt);
	float s = sin(tilt);
	float dy = p.y - 208.0;
	float q = dy / (c + dy * s / 480.0);
	float stretch = 1.0 - q * s / 480.0;
	vec2 uvp = vec2(512.0 + (p.x - 160.0) * stretch, 740.0 + q) / PLANE_PX * TEX_SCALE;

	float inside = step(0.0, uvp.x) * step(uvp.x, 1.0) * step(0.0, uvp.y) * step(uvp.y, 1.0);
	vec4 tex = texture(TEXTURE, clamp(uvp, vec2(0.0), vec2(1.0)));

	vec3 base = vec3(0.098, 0.204, 0.243);              // #19343e
	vec3 col = mix(base, tex.rgb, tex.a * inside);

	float hy = clamp(p.y / 245.0, 0.0, 1.0);
	col = mix(col, vec3(0.188, 0.325, 0.388), (1.0 - hy) * haze_amount);

	float r = length(p - vec2(160.0, 160.0));
	float a = 1.0 - smoothstep(158.0, 160.0, r);
	COLOR = vec4(col, a);
}
