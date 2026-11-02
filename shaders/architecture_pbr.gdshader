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

/// 分区染色（GTA化 §3.1）：按城市象限逐 MeshInstance 设置（instance uniform），
/// 材质仍按 profile 键共享 —— 材质数零增长，染色纯 GPU。
/// 只乘反照率（墙/玻璃），不动自发光（窗光不该被分区色染）。
instance uniform vec3 district_tint = vec3(1.0);

// ---------------------------------------------------------------------------
// 立面多样性 —— 原版 city-facade-diversity.ts（MaterialPluginBase → gdshader）
//
// 输入 UV2：x = 材质族 + .25（0..7，f<2 office / f==6 industrial）、
//           y = 建筑稳定种子（0..65520，着色器里取整后 mod 4093）。
// 只对 block_* 网格启用（office/residential 图元带 TEXCOORD_1，已实测）；
// 材质仍按 profile 键共享（:fv 变体），不加 draw call、不拆网格。
//
// 整楼主题（12 套"深圳常见类型学"，线性反射率，墙色是旧调色板的 55%、
// 玻璃 75%）替换掉逐顶点调色板乘法；窗格从 facade-atlas（1024²，4×2 张
// 256×512 瓦片）取样；夜间按 套房/楼层 分组点亮 + 稀有彩色窗（红蓝绿各 2 格）。
// 已知近似（相对原版）：CITY_FACADE_RELIEF（凹凸坡度/框mask）与窗光互反照
// （bounce）未搬——原版把 relief 也标为可选，失败时同样只保留主题/窗格语法。
// ---------------------------------------------------------------------------

uniform bool use_facade_variety = false;
uniform sampler2D facade_atlas : source_color, hint_default_white, filter_linear_mipmap;
uniform sampler2D facade_windows : source_color, hint_default_white, filter_linear_mipmap;
/// 光照档：night=1 夜里；glow.x = 自发光增益（白天 0 / 黄昏 .55 / 夜 1）
uniform float facade_night = 0.0;
uniform vec2 facade_glow = vec2(0.0);

varying vec2 fv_info;      // UV2 原值
varying vec2 fv_uv;        // UV0 原值（未乘 uv_scale）
varying vec3 fv_normal_w;  // 世界空间法线（pattern 相位要用）

void vertex() {
	fv_info = UV2;
	fv_uv = UV;
	fv_normal_w = normalize(mat3(MODEL_MATRIX) * NORMAL);
	UV = UV * uv_scale;
}

// ---------------------------------------------------------------------------
// 立面多样性：主题函数（对应原版 THEME_GLSL，逐行直译）
// ---------------------------------------------------------------------------

float fv_hash(vec2 v) {
	return fract(sin(dot(v, vec2(127.1, 311.7))) * 43758.5453123);
}

float fv_stable_seed(vec2 info) {
	return mod(floor(info.y + 0.5), 4093.0);
}

/// THEME_POOLS 加权池：f==0→池0，f==1→池1，f==6(industrial)→池3，其余→池2
float fv_theme_index(vec2 info) {
	float f = floor(info.x);
	float slot = mod(floor(info.y + 0.5) * 17.0 + f * 13.0, 12.0);
	if (f < 0.5) {
		if (slot < 3.5) return 0.0;   // blue-steel
		if (slot < 5.5) return 1.0;   // sage-glass
		if (slot < 6.5) return 2.0;   // silver-glass
		if (slot < 7.5) return 5.0;   // graphite
		if (slot < 9.5) return 6.0;   // near-black
		if (slot < 10.5) return 10.0; // champagne-glass
		return 11.0;                  // slate-blue
	} else if (f < 1.5) {
		if (slot < 2.5) return 2.0;
		if (slot < 4.5) return 7.0;   // pale-cool
		if (slot < 6.5) return 10.0;
		if (slot < 7.5) return 0.0;
		if (slot < 8.5) return 1.0;
		if (slot < 9.5) return 3.0;   // warm-white
		if (slot < 10.5) return 5.0;
		if (slot < 11.5) return 6.0;
		return 11.0;
	} else if (f < 5.5 || f > 6.5) {
		if (slot < 3.5) return 3.0;
		if (slot < 5.5) return 4.0;   // sandstone
		if (slot < 7.5) return 7.0;
		if (slot < 9.5) return 8.0;   // clay-render
		if (slot < 11.5) return 9.0;  // olive-render
		return 5.0;
	} else {
		if (slot < 2.5) return 5.0;
		if (slot < 4.5) return 7.0;
		if (slot < 6.5) return 2.0;
		if (slot < 7.5) return 9.0;
		if (slot < 9.5) return 4.0;
		if (slot < 10.5) return 6.0;
		if (slot < 11.5) return 10.0;
		return 3.0;
	}
}

/// 墙色 = 主题墙色 × shade（.85–1.10）
vec3 fv_theme_wall(vec2 info) {
	float theme = fv_theme_index(info);
	float shade = 0.85 + mod(floor(info.y + 0.5) * 5.0, 13.0) / 12.0 * 0.25;
	vec3 wall = vec3(0.5);
	if (theme < 0.5) wall = vec3(0.166, 0.210, 0.257);
	else if (theme < 1.5) wall = vec3(0.272, 0.333, 0.302);
	else if (theme < 2.5) wall = vec3(0.518, 0.559, 0.581);
	else if (theme < 3.5) wall = vec3(0.690, 0.666, 0.605);
	else if (theme < 4.5) wall = vec3(0.477, 0.416, 0.348);
	else if (theme < 5.5) wall = vec3(0.109, 0.123, 0.131);
	else if (theme < 6.5) wall = vec3(0.030, 0.035, 0.040);
	else if (theme < 7.5) wall = vec3(0.645, 0.676, 0.689);
	else if (theme < 8.5) wall = vec3(0.344, 0.253, 0.212);
	else if (theme < 9.5) wall = vec3(0.326, 0.373, 0.301);
	else if (theme < 10.5) wall = vec3(0.314, 0.292, 0.256);
	else wall = vec3(0.085, 0.113, 0.154);
	return wall * shade;
}

/// 玻璃色 = 主题玻璃色 × shade（.91–1.07），a = 玻璃粗糙度
vec4 fv_theme_glass(vec2 info) {
	float theme = fv_theme_index(info);
	float seed = floor(info.y + 0.5);
	float f = floor(info.x);
	float shade = 0.91 + mod(floor(seed / 13.0) * 7.0 + f, 11.0) / 10.0 * 0.16;
	vec3 glass = vec3(0.2);
	float roughness = 0.35;
	if (theme < 0.5) { glass = vec3(0.095, 0.166, 0.230); roughness = 0.30; }
	else if (theme < 1.5) { glass = vec3(0.101, 0.206, 0.161); roughness = 0.35; }
	else if (theme < 2.5) { glass = vec3(0.265, 0.336, 0.377); roughness = 0.32; }
	else if (theme < 3.5) { glass = vec3(0.233, 0.267, 0.252); roughness = 0.43; }
	else if (theme < 4.5) { glass = vec3(0.188, 0.218, 0.206); roughness = 0.45; }
	else if (theme < 5.5) { glass = vec3(0.095, 0.133, 0.148); roughness = 0.34; }
	else if (theme < 6.5) { glass = vec3(0.043, 0.059, 0.073); roughness = 0.28; }
	else if (theme < 7.5) { glass = vec3(0.325, 0.400, 0.430); roughness = 0.38; }
	else if (theme < 8.5) { glass = vec3(0.131, 0.153, 0.150); roughness = 0.46; }
	else if (theme < 9.5) { glass = vec3(0.149, 0.228, 0.172); roughness = 0.44; }
	else if (theme < 10.5) { glass = vec3(0.232, 0.206, 0.149); roughness = 0.31; }
	else { glass = vec3(0.070, 0.123, 0.206); roughness = 0.29; }
	return vec4(glass * shade, roughness);
}

/// 夜间辐射档（NIGHT_LEVELS × .93–1.05）
float fv_night_level(vec2 info) {
	float seed = floor(info.y + 0.5);
	float f = floor(info.x);
	float level = mod(floor(seed / 11.0) + f * 3.0, 6.0);
	float value = 1.10;
	if (level > 0.5) value = 1.25;
	if (level > 1.5) value = 1.45;
	if (level > 2.5) value = 1.65;
	if (level > 3.5) value = 1.90;
	if (level > 4.5) value = 2.10;
	return value * (0.93 + mod(seed * 5.0, 7.0) / 6.0 * 0.12);
}

/// 窗光色温：office/industrial 用办公灯组，其余用家用灯组；a = 夜间辐射档
vec4 fv_light(vec2 info) {
	float seed = floor(info.y + 0.5);
	float f = floor(info.x);
	float slot = mod(floor(seed / 7.0) + f * 3.0, 4.0);
	vec3 color;
	if (f < 1.5 || (f > 5.5 && f < 6.5)) {
		if (slot < 0.5) color = vec3(1.0, 0.68, 0.40);
		else if (slot < 1.5) color = vec3(1.0, 0.77, 0.57);
		else if (slot < 2.5) color = vec3(1.0, 0.86, 0.74);
		else color = vec3(0.88, 0.93, 1.0);
	} else {
		if (slot < 0.5) color = vec3(1.0, 0.57, 0.26);
		else if (slot < 1.5) color = vec3(1.0, 0.65, 0.35);
		else if (slot < 2.5) color = vec3(1.0, 0.72, 0.46);
		else color = vec3(1.0, 0.78, 0.58);
	}
	return vec4(color, fv_night_level(info));
}

/// 活动度：x = 黄昏辐射，y = 楼层点亮概率，z = 套房概率，w = 整层概率
vec4 fv_activity(vec2 info) {
	float seed = floor(info.y + 0.5);
	float f = floor(info.x);
	float a = mod(floor(seed / 17.0) + f * 7.0, 13.0) / 12.0;
	float floor_p;
	float suite_p;
	float whole_p = 0.0;
	if (f > 5.5 && f < 6.5) {
		floor_p = 0.23 + a * 0.25;
		suite_p = 0.37 + a * 0.18;
	} else if (f < 1.5) {
		floor_p = 0.36 + a * 0.30;
		suite_p = 0.35 + a * 0.20;
		whole_p = 0.025 + a * 0.035;
	} else {
		floor_p = 0.73 + a * 0.15;
		suite_p = 0.13 + a * 0.24;
	}
	float dusk = fv_night_level(info) * (0.26 + mod(seed * 3.0, 5.0) / 4.0 * 0.10);
	return vec4(dusk, floor_p, suite_p, whole_p);
}

/// 窗格网格密度（x = 每层跨数，y = 每图元层数）
vec2 fv_grid(vec2 info) {
	float f = floor(info.x);
	float gx = f < 0.5 ? 6.0 : (f < 2.5 ? 4.0 : ((f > 5.5 && f < 6.5) ? 5.0 : 3.0));
	float gy = (f > 5.5 && f < 6.5) ? 4.0 : 8.0;
	return vec2(gx, gy);
}

/// 每族的窗格周期（米/重复）
vec2 fv_period(vec2 info) {
	float f = floor(info.x);
	vec2 period = vec2(14.0, 19.2);
	if (f > 0.5) period = vec2(18.0, 20.4);
	if (f > 1.5) period = vec2(14.0, 17.6);
	if (f > 2.5) period = vec2(20.0, 17.6);
	if (f > 3.5) period = vec2(16.0, 22.4);
	if (f > 4.5) period = vec2(12.0, 16.8);
	if (f > 5.5) period = vec2(20.0, 16.0);
	if (f > 6.5) period = vec2(20.0, 18.4);
	return period;
}

/// 24×16 稀有彩色窗格图案（红蓝绿各 2 格）
vec2 fv_accent(vec2 cell, float seed) {
	float x = mod(cell.x + mod(seed * 5.0, 24.0), 24.0);
	float y = mod(cell.y + mod(floor(seed / 24.0) * 3.0, 16.0), 16.0);
	float slot = -1.0;
	if ((abs(x - 1.0) < 0.5 && abs(y - 1.0) < 0.5) || (abs(x - 20.0) < 0.5 && abs(y - 13.0) < 0.5)) slot = 0.0;
	else if ((abs(x - 17.0) < 0.5 && abs(y - 2.0) < 0.5) || (abs(x - 2.0) < 0.5 && abs(y - 14.0) < 0.5)) slot = 1.0;
	else if ((abs(x - 10.0) < 0.5 && abs(y - 9.0) < 0.5) || (abs(x - 18.0) < 0.5 && abs(y - 6.0) < 0.5)) slot = 2.0;
	return vec2(step(0.0, slot), max(0.0, slot));
}

/// 逐窗 HDR/bloom/kernel 光学变化
vec3 fv_window_variation(vec2 cell, float seed) {
	float hdr_slot = floor(fv_hash(vec2(cell.x + seed * 0.41 + 211.0, cell.y + seed * 0.23 + 337.0)) * 4.0);
	float hdr = 0.92;
	if (hdr_slot > 0.5) hdr = 0.98;
	if (hdr_slot > 1.5) hdr = 1.04;
	if (hdr_slot > 2.5) hdr = 1.10;
	float bloom_slot = floor(fv_hash(vec2(cell.x + seed * 0.19 + 433.0, cell.y + seed * 0.47 + 557.0)) * 3.0);
	float bloom = 0.94;
	if (bloom_slot > 0.5) bloom = 1.0;
	if (bloom_slot > 1.5) bloom = 1.06;
	float kernel_slot = floor(fv_hash(vec2(cell.x + seed * 0.53 + 619.0, cell.y + seed * 0.11 + 773.0)) * 3.0);
	float kernel = 0.88;
	if (kernel_slot > 0.5) kernel = 1.0;
	if (kernel_slot > 1.5) kernel = 1.12;
	return vec3(hdr, bloom, kernel);
}

/// 图集寻址：4×2 张 256×512 瓦片，留 8px 边距
vec2 fv_atlas_uv(vec2 info, vec2 pattern) {
	float f = floor(info.x);
	vec2 tile = vec2(mod(f, 4.0), floor(f / 4.0));
	return (tile * vec2(256.0, 512.0) + vec2(8.0) + fract(pattern) * vec2(240.0, 496.0)) / 1024.0;
}

void fragment() {
	// 双面光照（Babylon twoSidedLighting）：背面法线取反，否则内壁全黑
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}

	if (use_facade_variety) {
		// —— 立面多样性路径：整楼主题 + 图集窗格 + 分组窗光（原版
		// cityFacadeAlbedo / cityFacadeEmission 的直译，relief/bounce 未搬）——
		vec2 info = fv_info;
		float seed = fv_stable_seed(info);
		float family = floor(info.x);
		float office = 1.0 - step(1.5, family);
		float industrial = step(5.5, family) * (1.0 - step(6.5, family));
		vec3 theme_wall = fv_theme_wall(info);
		vec4 theme_glass = fv_theme_glass(info);
		vec4 light_col = fv_light(info);
		vec4 activity = fv_activity(info);
		vec2 grid = fv_grid(info);
		// 逐楼相位 + 朝向：相邻墙共享合理的楼层尺度，不同楼不从图集第 0 列开始
		float face = dot(floor(normalize(fv_normal_w) * 32.0 + 0.5), vec3(3.7, 1.1, 7.3));
		vec2 phase = vec2(fv_hash(vec2(seed, face)), fv_hash(vec2(seed, 17.0)));
		vec2 pattern = fv_uv * 24.0 / fv_period(info) + phase;

		// —— 反照率：图集 texel 的 alpha 是 玻璃(.333)/墙(.780) 的线性混合 ——
		vec4 texel = texture(facade_atlas, fv_atlas_uv(info, pattern));
		float glazing = clamp((0.780 - texel.a) / (0.780 - 0.333), 0.0, 1.0);
		float glass_roughness = clamp(theme_glass.a * 0.52, 0.14, 0.24);
		// source_color 已做 sRGB→linear（对应原版 toLinearSpace）
		float luminance = dot(texel.rgb, vec3(0.2126, 0.7152, 0.0722));
		float wall_detail = clamp(luminance / 0.48, 0.78, 1.10);
		float glass_detail = clamp(luminance / 0.105, 0.94, 1.06);
		vec2 cell_dx = dFdx(pattern * grid);
		vec2 cell_dy = dFdy(pattern * grid);
		float unresolved = smoothstep(0.35, 1.2, max(length(cell_dx), length(cell_dy)));
		float rows_unresolved = smoothstep(0.35, 1.2, length(vec2(cell_dx.y, cell_dy.y)));
		// 世界 Y 分层：楼层高度 = (1-v)*24（city_mesh.py 写 v=z/24，glTF 翻转 V）
		float height = (1.0 - fv_uv.y) * 24.0;
		float row = floor(pattern.y * grid.y);
		// office 塔楼 55%：每 9–13 行一层百叶设备层（实心、78% 反照率、夜里不亮）
		float plant_period = 9.0 + mod(seed, 5.0);
		float plant = office * step(0.45, fv_hash(vec2(seed, 131.0))) * step(12.0, height)
			* step(mod(row + floor(seed / 5.0), plant_period), 0.5) * (1.0 - rows_unresolved);
		float ground_t = smoothstep(3.0, 9.0, height);
		float ground_wall = mix(0.72, 1.0, ground_t);
		glazing *= 1.0 - plant;
		// 过梁阴影：图集窗格贴着格顶（fract 小 = 高处）
		vec2 pane_uv = fract(pattern * grid) - 0.5;
		float lintel = (1.0 - smoothstep(-0.46, -0.10, pane_uv.y)) * glazing * (1.0 - unresolved);
		vec3 wall = theme_wall * wall_detail * mix(1.0, 0.78, plant) * ground_wall;
		vec3 glass = theme_glass.rgb * glass_detail * 0.32 * mix(0.86, 1.0, ground_t) * (1.0 - 0.42 * lintel);
		// 白天拉上的窗帘（与夜里调暗的是同一批窗：同 hash）
		vec2 pane_cell = floor(pattern * grid);
		float blind_hash = fv_hash(vec2(pane_cell.x * 1.7 + seed * 0.031 + 911.0, pane_cell.y * 2.3 + seed * 0.017 + 1213.0));
		float blind_drawn = (1.0 - smoothstep(0.22, 0.34, blind_hash)) * (1.0 - unresolved) * (1.0 - plant);
		vec3 blind_colour = mix(vec3(0.26, 0.25, 0.23), vec3(0.44, 0.43, 0.40),
			fv_hash(vec2(pane_cell.y + seed * 0.013 + 37.0, pane_cell.x * 0.7 + seed * 0.041 + 59.0))) * mix(0.86, 1.0, ground_t);
		glass = mix(glass, blind_colour, blind_drawn * 0.85);
		vec3 surface = mix(wall, glass, glazing);
		// 亚像素时显示整楼平均反照率，而不是黑白格子
		float mean_glass = 0.568;
		if (family > 0.5) mean_glass = 0.475;
		if (family > 1.5) mean_glass = 0.311;
		if (family > 2.5) mean_glass = 0.406;
		if (family > 3.5) mean_glass = 0.355;
		if (family > 4.5) mean_glass = 0.232;
		if (family > 5.5) mean_glass = 0.263;
		if (family > 6.5) mean_glass = 0.411;
		vec3 mean_glass_colour = mix(theme_glass.rgb * 0.32, vec3(0.35, 0.34, 0.315), 0.238);
		vec3 mean_surface = mix(theme_wall * ground_wall, mean_glass_colour, mean_glass);
		surface = mix(surface, mean_surface, unresolved * 0.82);
		glazing = mix(glazing, mean_glass, unresolved);
		// 双瓣近似：玻璃覆盖决定粗糙度/镜面，天空倒影不糊
		float glass_lobe = smoothstep(0.03, 0.20, glazing);
		ALBEDO = clamp(surface * district_tint, vec3(0.009), vec3(0.82));
		ROUGHNESS = mix(0.78, glass_roughness, glass_lobe);
		METALLIC = 0.0;
		SPECULAR = 0.5 * mix(1.0, glazing, glass_lobe);

		// —— 窗光：套房/楼层 分组点亮 + 稀有彩色窗 ——
		vec2 cell = pane_cell;
		vec2 accent = fv_accent(cell, seed);
		float suite_width = mix(mix(2.0, 4.0, industrial), 3.0 + mod(seed, 3.0), office);
		float floor_group = floor(cell.y / mix(1.0, 2.0, office));
		float suite = floor((cell.x + mod(seed, 3.0)) / suite_width);
		float floor_p = activity.y * mix(0.34, 1.0, facade_night);
		float suite_p = activity.z;
		float whole_p = activity.w * mix(0.30, 1.0, facade_night);
		float floor_lit = 1.0 - step(floor_p, fv_hash(vec2(floor_group + 71.0, seed + 53.0)));
		float suite_lit = 1.0 - step(suite_p, fv_hash(vec2(suite + floor_group * 23.0, seed + 193.0)));
		float whole_lit = 1.0 - step(whole_p, fv_hash(vec2(floor_group + 113.0, seed + 317.0)));
		float normal_p = mix(0.06, 0.10, facade_night);
		float normal_lit = 1.0 - step(normal_p, fv_hash(vec2(suite + floor_group * 31.0 + 587.0, seed + 881.0)));
		float suite_expected = 1.0 - (1.0 - suite_p) * (1.0 - normal_p);
		float base_expected = floor_p * (whole_p + (1.0 - whole_p) * suite_expected);
		// 掠射视角会把套房横向压扁而楼层仍有若干像素高——两组门控独立滤波
		float suite_fade = smoothstep(0.65, 1.4, length(vec2(cell_dx.x, cell_dy.x)) / suite_width);
		float floor_fade = smoothstep(0.65, 1.4, length(vec2(cell_dx.y, cell_dy.y)) / mix(1.0, 2.0, office));
		float pane_fade = smoothstep(0.55, 1.25, max(length(cell_dx), length(cell_dy)));
		float subpixel = max(suite_fade, floor_fade);
		float suites = mix(max(suite_lit, normal_lit), suite_expected, suite_fade);
		float base_lit = mix(floor_lit * max(whole_lit, suites), base_expected, floor_fade);
		float accent_lit = mix(accent.x, 0.015625, pane_fade);  // 6/(24*16)
		float lit = 1.0 - (1.0 - base_lit) * (1.0 - accent_lit);
		vec3 variation = fv_window_variation(cell, seed) * vec3(mix(1.0, 1.22, accent.x), mix(1.0, 1.12, accent.x), 1.0);
		variation = mix(variation, vec3(1.0), pane_fade);
		// 窗格模板：kernelScale 当作离散预滤波核的足迹缩放
		vec2 wdx = dFdx(pattern) * vec2(240.0, 496.0) / 1024.0 * variation.z;
		vec2 wdy = dFdy(pattern) * vec2(240.0, 496.0) / 1024.0 * variation.z;
		float stencil = textureGrad(facade_windows, fv_atlas_uv(info, pattern), wdx, wdy).r;
		float blind = fv_hash(vec2(cell.x * 1.7 + seed * 0.031 + 911.0, cell.y * 2.3 + seed * 0.017 + 1213.0));
		float curtain = mix(0.28, 1.0, smoothstep(0.12, 0.92, blind));
		float interior = mix(0.66, 1.0, 1.0 - smoothstep(0.12, 0.52, length(pane_uv * vec2(1.0, 0.85))));
		float pane_shade = mix(curtain * interior, 0.52, pane_fade);
		// 设备层是实心百叶：没有房间、没有灯光
		float coverage = stencil * lit * pane_shade * (1.0 - plant);
		float room_brightness = mix(mix(0.86, 1.08, fv_hash(vec2(suite + floor_group * 7.0, seed + 419.0))), 1.0, subpixel);
		float radiance = mix(activity.x, light_col.a * 1.10, facade_night) * room_brightness * facade_glow.x * variation.x;
		// Bloom 只提取 HDR 肩部
		radiance += max(0.0, radiance - 0.9) * (variation.y - 1.0);
		vec3 win_light = light_col.rgb;
		if (accent.x > 0.5) {
			if (accent.y < 0.5) win_light = vec3(1.35, 0.025, 0.012);
			else if (accent.y < 1.5) win_light = vec3(0.018, 0.26, 1.40);
			else win_light = vec3(0.018, 1.18, 0.075);
			win_light = mix(win_light, light_col.rgb, pane_fade);
		}
		EMISSION = win_light * coverage * radiance;
	} else {
		vec3 base = albedo_tint.rgb;
		if (use_albedo_tex) {
			base *= texture(albedo_tex, UV).rgb;
		}
		// 顶点色是乘性的（原版：有顶点色就 useVertexColors=true）；
		// 网格没有顶点色时 Godot 会把它设成白色，等于不生效。
		base *= COLOR.rgb;
		base *= district_tint;
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
	}

	// 逐材质环境光强度：AO 只缩放环境光与反射，不影响直射
	AO = 1.0 / max(env_scale, 0.02);
	AO_LIGHT_AFFECT = 0.0;
}
