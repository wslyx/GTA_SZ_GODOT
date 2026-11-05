shader_type spatial;
// 地面材质总着色器 —— 逐项复刻原版三个 MaterialPluginBase：
//   CityPublicLightField（city-public-lighting.ts, 优先级 210）公共照明场
//   CityAmbient        （city-ambient-occlusion.ts, 190）烘焙环境光遮蔽
//   CityGrassPBR       （city-grass-material.ts, 205）草地分层材质
//
// 为什么是「整体替换」而不是 StandardMaterial3D + 外挂：Godot 没有
// MaterialPluginBase 那种往任意材质里注入片元的机制。所以这里把被替换材质的
// 反照率 / 法线 / 粗糙度 / 金属度 / 镜面强度整份抄进 uniform，再自行叠加三项注入。
// 参数同步由 ground_field.gd 负责（每 0.25s 从源材质回抄一次），
// 保证 road_surface.gd 的昼夜 / 干湿切换仍然有效。
//
// 判据（原版）：
//   公共照明场 —— 覆盖在 `^(roads_|terrain_(land|park|pavement)|ground_relief_|
//                  detail_lianhua_|rain-|rain_|coastal_bridge_|city_meadow_)` 的网格上
//   烘焙 AO   —— strength 地面 .85 / 墙 .60 / 屋顶 .70，direct 份额 day .30 / sunset .24 / night 0
//   草地      —— 材质名 `land` / `park`

// 剔除：⚠️ 本着色器覆盖的网格里，屋顶（block_<i>_<j>_roof）属于 buildings.glb
// 的混合绕序数据（约 64% 三角形绕序反，见 architecture_pbr.gdshader 头注）；
// 原版材质全部 doubleSided（双面渲染）。必须 cull_disabled + 背面法线取反，
// 否则绕序反的屋顶从上方被剔除、楼体呈"敞顶"状。

render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// 烘焙 AO 的环境光下限（见 fragment 里 A6 段的说明）：楼影/楼脚不许把
// 天空回弹压到 0，否则阴影区整片死黑。
const float AO_MIN = 0.5;

// ---------------------------------------------------------------------------
// 基础参数（从被替换的 StandardMaterial3D 抄来）
// ---------------------------------------------------------------------------
uniform bool use_albedo_tex = false;
uniform sampler2D albedo_tex : source_color, hint_default_white;
uniform vec4 albedo_tint : source_color = vec4(1.0);
uniform vec2 uv_scale = vec2(1.0, 1.0);
uniform bool use_normal_tex = false;
uniform sampler2D normal_tex : hint_normal;
uniform float normal_depth : hint_range(0.0, 2.0) = 1.0;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.92;
uniform float metallic_value : hint_range(0.0, 1.0) = 0.0;
uniform float specular_value : hint_range(0.0, 1.0) = 0.5;

// ---------------------------------------------------------------------------
// A2 公共照明场（原版 CityPublicLightField）
//   public_irradiance: 1024×1024 RGB8 线性数据，2048m 覆盖（2m/texel）
//   city_light_field = (中心x, 中心z, 场宽 2048, 夜强度 0/0.17/1)
// ---------------------------------------------------------------------------
uniform sampler2D public_irradiance : hint_default_black, filter_linear, repeat_disable;
uniform vec4 city_light_field = vec4(0.0, 0.0, 2048.0, 0.0);

// ---------------------------------------------------------------------------
// A6 烘焙环境光遮蔽（原版 CityAmbient）
//   city_ambient 三通道 = 0 / 12 / 40 m 处的天空可见度
//   params = (强度, 法线内缩米数, 直射份额)
// ---------------------------------------------------------------------------
uniform bool use_city_ambient = false;
uniform sampler2D city_ambient : hint_default_white, filter_linear, repeat_disable;
uniform vec2 city_ambient_origin = vec2(0.0);
uniform vec2 city_ambient_size = vec2(1.0);
uniform vec3 city_ambient_params = vec3(1.0, 0.0, 0.0);
uniform vec4 city_ambient_heights = vec4(0.0, 12.0, 40.0, 150.0);

// ---------------------------------------------------------------------------
// 逐材质环境光强度（原版 Babylon 的 `material.environmentIntensity`）
//   Godot 的 StandardMaterial3D 没这个属性，fragment 里也没有 AMBIENT_LIGHT
//   （实测报 Unknown identifier）。但 `AO` 乘的正是「环境光 + 反射」，作用对象
//   与原版一致 —— 所以 `AO = 1/env_scale` 就是逐材质的环境光缩放。
//   沥青 day 1 / 昏夜 .55 / 雨天 1.18–1.10，草地 .75（见 road_surface / 草地那两处）。
// ---------------------------------------------------------------------------
uniform float env_scale = 1.0;
uniform sampler2D mirror_tex : hint_default_black, filter_linear_mipmap;
uniform float mirror_strength = 0.0;

// ---- A5 中湾铺装（baypark_look.gd 按网格写 kind；0 = 不在样例内）----
uniform float baypark_kind = 0.0;
uniform vec2 baypark_center = vec2(-2283.27, 794.82); // 世界 xz（数据 z 取负）
uniform float baypark_full_radius = 420.0;
uniform float baypark_outer_radius = 600.0;
uniform float baypark_detail_near = 22.0;
uniform float baypark_detail_far = 115.0;
uniform vec3 baypark_paver_mean = vec3(0.166116, 0.195645, 0.185488);

// ---------------------------------------------------------------------------
// A5 草地分层（原版 CityGrassPBR）
// ---------------------------------------------------------------------------
uniform bool is_lawn = false;
uniform sampler2D lawn_color : source_color, hint_default_white;
uniform sampler2D lawn_normal : hint_normal;
uniform sampler2D soil_color : source_color, hint_default_white;
uniform sampler2D soil_normal : hint_normal;
uniform sampler2D litter_color : source_color, hint_default_white;
uniform sampler2D litter_normal : hint_normal;
uniform float grass_park = 1.0;
uniform float grass_detail_range = 110.0;
// 原版 cityGrassPark.y（森林档）：山体层用 —— 树冠 tint + 双尺度冠簇噪声，
// 逐顶点色（树冠簇/高地/岩石）由 mesh COLOR 承担（仅山地网格有色，故加门控）
uniform float grass_forest : hint_range(0.0, 1.0) = 0.0;
uniform float use_vertex_color : hint_range(0.0, 1.0) = 0.0;

// ---------------------------------------------------------------------------
// A6b 植被夜间地面补光（原版 city-landscape-lighting.ts）
//   x = 夜间强度 0/1，y = 地面自发光地板（terrain .07 / grass .05），
//   z = 漫射增益（原版 1.12，Godot 无 fragment 漫射出口，见 ground_field.gd 说明），
//   w = 粗糙度下压量（.12）
// ---------------------------------------------------------------------------
uniform vec4 city_landscape_night = vec4(0.0, 0.07, 1.12, 0.12);

// ---------------------------------------------------------------------------
// C 屋顶表面 finish（原版 city-roof-surface.ts）
//   city_roof_lookup：全城 4m/px 的 R8 码图，code = 1 + finish*16 + tint
//   city_roof_detail：8m 周期的细节瓦片（r 缝隙 / g 颗粒 / b 雨渍 / a 高度）
// ---------------------------------------------------------------------------
uniform bool is_roof = false;
uniform sampler2D city_roof_lookup : hint_default_black, filter_nearest, repeat_disable;
uniform sampler2D city_roof_detail : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec2 city_roof_origin = vec2(0.0);
uniform vec2 city_roof_size = vec2(1.0);
uniform float city_roof_detail_period = 8.0;

// 原版 ROOF_FINISHES（8 项，逐字对应 id / color / seams / grain / stains）
vec3 city_roof_finish_color(float f) {
	if (f < 0.5) return vec3(0.130, 0.145, 0.155);  // membrane-dark
	if (f < 1.5) return vec3(0.320, 0.330, 0.320);  // concrete-grey
	if (f < 2.5) return vec3(0.440, 0.440, 0.410);  // cement-pale
	if (f < 3.5) return vec3(0.420, 0.390, 0.340);  // gravel-warm
	if (f < 4.5) return vec3(0.360, 0.200, 0.140);  // terracotta
	if (f < 5.5) return vec3(0.110, 0.190, 0.085);  // green-roof
	if (f < 6.5) return vec3(0.560, 0.570, 0.560);  // tpo-white
	return vec3(0.330, 0.150, 0.110);               // tile-red
}

vec3 city_roof_params(float f) {
	if (f < 0.5) return vec3(1.00, 0.25, 0.60);
	if (f < 1.5) return vec3(0.60, 0.50, 0.70);
	if (f < 2.5) return vec3(0.50, 0.60, 0.80);
	if (f < 3.5) return vec3(0.00, 1.00, 0.40);
	if (f < 4.5) return vec3(0.35, 0.30, 0.50);
	if (f < 5.5) return vec3(0.00, 0.90, 0.20);
	if (f < 6.5) return vec3(1.00, 0.15, 0.70);
	return vec3(0.50, 0.35, 0.40);
}

void vertex() {
	UV = UV * uv_scale;
}

// 原版 cityGrassNoise：二维 value noise（和 GLSL 逐字对应）
float city_grass_noise(vec2 p) {
	vec2 q = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	vec4 h = fract(sin(vec4(
		dot(q, vec2(127.1, 311.7)),
		dot(q + vec2(1.0, 0.0), vec2(127.1, 311.7)),
		dot(q + vec2(0.0, 1.0), vec2(127.1, 311.7)),
		dot(q + vec2(1.0, 1.0), vec2(127.1, 311.7)))) * 43758.5453);
	return mix(mix(h.x, h.y, f.x), mix(h.z, h.w, f.x), f.y);
}

// 原版 cityAmbientAt：按世界高度混合三层，超出栅格即视为无遮挡
float city_ambient_at(vec3 p, vec3 n) {
	// 数据坐标 = (east, north) = (world.x, -world.z)
	vec2 pd = vec2(p.x, -p.z);
	vec2 nd = vec2(n.x, -n.z);
	vec2 uv = (pd - nd * city_ambient_params.y - city_ambient_origin) / city_ambient_size;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return 1.0;
	}
	vec3 s = texture(city_ambient, uv).rgb;
	float y = max(p.y, 0.0);
	float h0 = city_ambient_heights.x;
	float h1 = city_ambient_heights.y;
	float h2 = city_ambient_heights.z;
	float ao = y < h1
		? mix(s.r, s.g, clamp((y - h0) / max(h1 - h0, 0.001), 0.0, 1.0))
		: mix(s.g, s.b, clamp((y - h1) / max(h2 - h1, 0.001), 0.0, 1.0));
	ao = mix(ao, 1.0, smoothstep(h2, city_ambient_heights.w, y));
	return mix(1.0, ao, city_ambient_params.x);
}

float bp_hash(vec2 p) {
	vec3 q = fract(vec3(p.xyx) * 0.1031);
	q += dot(q, q.yzx + 33.33);
	return fract((q.x + q.y) * q.z);
}

float bp_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(bp_hash(i), bp_hash(i + vec2(1.0, 0.0)), f.x),
		mix(bp_hash(i + vec2(0.0, 1.0)), bp_hash(i + vec2(1.0)), f.x), f.y);
}

// 盒式滤波接缝：缩到亚像素时保持能量，而不是糊成黑条
float bp_line(float sd, float half_width, float footprint) {
	float w = max(footprint, 0.0005);
	return clamp((half_width - sd) / w + 0.5, 0.0, 1.0)
		- clamp((-half_width - sd) / w + 0.5, 0.0, 1.0);
}

float bp_bevel(float p) {
	float t = clamp((abs(p) - 0.003) / 0.022, 0.0, 1.0);
	return sign(p) * 6.0 * t * (1.0 - t);
}

void fragment() {
	// 双面光照：背面法线取反（Babylon twoSidedLighting），否则背面全黑
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	vec3 wpos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 wnormal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);

	vec3 base = albedo_tint.rgb;
	if (use_albedo_tex) {
		base *= texture(albedo_tex, UV).rgb;
	}
	float rough = roughness_value;
	float metal = metallic_value;
	float city_grass_roughness = rough;

	// ---- C 屋顶表面 finish ----
	// 原版完全替换 surfaceAlbedo（建筑自带的 `roof` 材质只是一块深色平色）。
	if (is_roof) {
		vec2 gp_roof = vec2(wpos.x, -wpos.z);
		vec2 ruv = (gp_roof - city_roof_origin) / city_roof_size;
		if (ruv.x >= 0.0 && ruv.x <= 1.0 && ruv.y >= 0.0 && ruv.y <= 1.0) {
			float code = texture(city_roof_lookup, ruv).r * 255.0;
			if (code > 0.5) {
				float fid = floor((code - 1.0) / 16.0 + 0.001);
				float rtint = mod(code - 1.0, 16.0) / 15.0;
				vec4 d = texture(city_roof_detail, gp_roof / city_roof_detail_period);
				vec3 p = city_roof_params(fid);
				vec3 rbase = city_roof_finish_color(fid) * (0.84 + rtint * 0.30);
				float seams = d.r * p.x;
				float grain = (d.g - 0.5) * p.y;
				float stains = d.b * p.z;
				base = clamp(rbase * (1.0 - seams * 0.35) * (1.0 + grain * 0.55)
					* (1.0 - stains * 0.42), vec3(0.004), vec3(0.9));
				rough = clamp(0.78 + grain * 0.22 + stains * 0.12 - seams * 0.08, 0.5, 1.0);
				metal = 0.0;
			}
		}
	}

	if (is_lawn) {
		// —— 原版：世界空间 UV 的两级草皮混合 + 泥土 / 落叶 ——
		vec2 gp = vec2(wpos.x, -wpos.z);
		float grass_patch = city_grass_noise(gp * 0.043);
		float grass_fine = city_grass_noise(gp * 0.22 + 13.0);
		// 相机世界位置取 INV_VIEW_MATRIX 的平移列 —— 等价于 CAMERA_POSITION_WORLD，
		// 但少依赖一个内置量（本项目对这个文件已经踩过一次"标识符不存在"）
		float grass_distance = length(INV_VIEW_MATRIX[3].xyz - wpos);
		float grass_detail = 1.0 - smoothstep(24.0, grass_detail_range, grass_distance);

		vec2 lawn_uv = gp / 0.84;
		vec2 lawn_uv2 = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * lawn_uv * 0.83 + vec2(23.7, 5.1);
		vec3 lawn_a = texture(lawn_color, lawn_uv).rgb;
		vec3 lawn_b = texture(lawn_color, lawn_uv2).rgb;
		vec3 soil = texture(soil_color, gp / 1.2 + vec2(7.0)).rgb;
		vec3 litter = texture(litter_color, mat2(vec2(0.0, 1.0), vec2(-1.0, 0.0)) * gp / 1.2).rgb;

		// cityGrassSoil 在原版里恒为 0
		float worn = clamp((1.0 - grass_park) * 0.06 + smoothstep(0.65, 0.92, grass_patch) * 0.06, 0.0, 0.40);
		float leafy = smoothstep(0.62, 0.86, grass_fine) * 0.04;
		vec3 lawn = mix(lawn_a, lawn_b, 0.25 + 0.45 * grass_patch);
		base = mix(mix(lawn, soil, worn), litter, leafy);
		base *= mix(vec3(0.95, 0.98, 0.93), vec3(1.02, 1.01, 0.95), grass_patch);
		// 原版 VERTEXCOLOR：山地网格带逐顶点烘焙色（树冠簇/高地压暗/岩石暖灰），
		// 普通草地网格无 COLOR（Godot 缺省=白，等价 vColor=1）
		if (use_vertex_color > 0.5) {
			base *= COLOR.rgb;
		}
		// 原版森林档（cityGrassPark.y>.5）：亚热带树冠 tint + 冠簇噪声
		if (grass_forest > 0.5) {
			float crown = city_grass_noise(gp * 0.11 + 3.0);
			float crown_fine = city_grass_noise(gp * 0.31 + 71.0);
			base *= vec3(0.66, 0.74, 0.58) * mix(0.62, 1.08, crown) * mix(0.86, 1.06, crown_fine);
		}

		city_grass_roughness = 0.96;
		// 近处叠加细节法线（远距离省掉三次细法线采样）
		if (grass_detail > 0.001) {
			vec3 gn = texture(lawn_normal, lawn_uv).rgb;
			vec3 sn = texture(soil_normal, gp / 1.2 + vec2(7.0)).rgb;
			vec3 ln = texture(litter_normal, mat2(vec2(0.0, 1.0), vec2(-1.0, 0.0)) * gp / 1.2).rgb;
			vec2 litter_slope = vec2(ln.g * 2.0 - 1.0, -(ln.r * 2.0 - 1.0));
			vec2 grass_slope = mix(mix(gn.rg * 2.0 - 1.0, sn.rg * 2.0 - 1.0, worn), litter_slope, leafy);
			vec3 gt = normalize(vec3(1.0, 0.0, 0.0) - wnormal * wnormal.x);
			vec3 gb = normalize(cross(gt, wnormal));
			vec2 packed_normal = (grass_slope * 0.42 * grass_detail) * 0.5 + 0.5;
			NORMAL_MAP = vec3(packed_normal, 0.5);
			NORMAL_MAP_DEPTH = 1.0;
			city_grass_roughness = mix(0.96, mix(mix(gn.b, sn.b, worn), ln.b, leafy), grass_detail);
		}
		rough = city_grass_roughness;
	} else if (use_normal_tex) {
		NORMAL_MAP = texture(normal_tex, UV).rgb;
		NORMAL_MAP_DEPTH = normal_depth;
	}

	ALBEDO = base;

	// ---- A6b 植被夜间地面补光 ----
	// 原版：夜里给草地/地形一个很低的「天光地板」，让坡面在夜里仍可读，
	// 但整体仍然是「暗地面 + 一洼洼路灯」，不是均匀发亮的绿毯。
	if (city_landscape_night.x > 0.001) {
		rough = mix(rough, max(0.72, rough - city_landscape_night.w), city_landscape_night.x);
		float sky_facing = 0.72 + 0.28 * clamp(wnormal.y, 0.0, 1.0);
		EMISSION += base * city_landscape_night.x * city_landscape_night.y * sky_facing;
	}
	// 原版还有 `finalDiffuse *= mix(1., 1.12, night)`。Godot 的 fragment() 没有漫射
	// 出口，而 light() 是**全权接管**（默认 PBR 整段不编译），所以这里用 ALBEDO 近似：
	// 偏差是「环境光也一起被放大 12%」，夜间地面本来就以环境光 + 路灯为主，
	// 观感上是略亮一点点。见差异清单 §10.3。
	if (city_landscape_night.x > 0.001) {
		base *= mix(1.0, city_landscape_night.z, city_landscape_night.x);
	}

	// ---- A5 中湾铺装（原版 city-baypark-look.ts 片元逐段移植）----
	// 与原版 MaterialPlugin 同语义：只改 albedo/roughness/normal，圈外不动。
	// 石材铺装区用标定均值替换原贴图（原贴图自带的粗网格会与细缝叠两层）。
	if (baypark_kind > 0.5) {
		vec2 bp_local = wpos.xz - baypark_center;
		float bp_radius = length(bp_local);
		float bp_mask = (1.0 - smoothstep(baypark_full_radius, baypark_outer_radius, bp_radius));
		if (bp_mask > 0.0001) {
			float paver = 1.0 - step(1.5, baypark_kind);
			float cap = step(1.5, baypark_kind) * (1.0 - step(2.5, baypark_kind));
			float wall = step(2.5, baypark_kind) * (1.0 - step(3.5, baypark_kind));
			float rock = step(3.5, baypark_kind);

			vec2 bp_dx = dFdx(wpos.xz);
			vec2 bp_dy = dFdy(wpos.xz);
			float bp_pixel = max(length(bp_dx), length(bp_dy));
			float bp_dist = length(INV_VIEW_MATRIX[3].xyz - wpos);
			float detail = 1.0 - smoothstep(baypark_detail_near, baypark_detail_far, bp_dist);
			float relief = detail * (1.0 - smoothstep(0.012, 0.075, bp_pixel));

			float patch = bp_noise(bp_local * 0.075 + 17.0);
			float grain = bp_noise(bp_local * 2.6 + wpos.y * 0.7);

			vec2 along = vec2(0.9396926, 0.3420201);
			vec2 across = vec2(-0.3420201, 0.9396926);
			vec2 q = vec2(dot(bp_local, along), dot(bp_local, across));

			float joint = 0.0;
			vec2 slope = vec2(0.0);
			float slab = 0.0;
			if (paver > 0.5) {
				vec2 size = vec2(0.72, 0.36);
				float row = floor(q.y / size.y);
				vec2 cell = vec2(q.x / size.x + mod(row, 2.0) * 0.5, q.y / size.y);
				vec2 signed_d = (fract(cell + 0.5) - 0.5) * size;
				vec2 footprint = abs(vec2(dot(bp_dx, along), dot(bp_dx, across)))
					+ abs(vec2(dot(bp_dy, along), dot(bp_dy, across)));
				joint = max(bp_line(signed_d.x, 0.003, footprint.x),
					bp_line(signed_d.y, 0.003, footprint.y));
				slope = vec2(bp_bevel(signed_d.x), bp_bevel(signed_d.y)) * 0.07;
				slab = (bp_hash(floor(cell)) - 0.5) * 0.10 * detail;
			} else if (cap + wall > 0.5) {
				// 既有混凝土上稀疏的伸缩缝，不是新砌的砖
				float signed_d = (fract(q.x / 2.4 + 0.5) - 0.5) * 2.4;
				joint = bp_line(signed_d, 0.004, bp_pixel);
				slope.x = bp_bevel(signed_d) * 0.075;
			}

			float wet = (1.0 - smoothstep(-0.34, 0.17, wpos.y + (patch - 0.5) * 0.16)) * (1.0 - paver);
			wet += paver * smoothstep(0.66, 0.91, patch) * 0.16;

			float dry_rough = mix(0.83, 0.92, rock);
			dry_rough += mix(-0.045, 0.04, patch);
			rough = mix(rough, clamp(dry_rough - wet * mix(0.21, 0.34, wall + rock) + joint * 0.06, 0.56, 0.98), bp_mask);

			vec3 tint = mix(vec3(1.025, 1.015, 0.98), vec3(0.98, 1.005, 1.015), patch);
			float aggregate = (grain - 0.5) * mix(0.085, 0.04, paver) * detail;
			float fine_fade = 1.0 - smoothstep(0.006, 0.020, bp_pixel);
			if (paver > 0.5 && fine_fade > 0.001) {
				aggregate += (bp_noise(bp_local * 72.0) - 0.5) * 0.04 * fine_fade;
			}

			float tone = (1.0 + slab + aggregate)
				* (1.0 - joint * mix(0.30, 0.20, paver) * detail)
				* (1.0 - wet * 0.23);

			vec3 bp_base = base;
			if (paver > 0.5) {
				bp_base = baypark_paver_mean * albedo_tint.rgb;
			}
			base = mix(base, bp_base * tint * tone, bp_mask);

			// 解析倒角 → 世界空间梯度 → 视空间扰动法线
			if (relief > 0.0001) {
				vec3 grad = vec3(along.x * slope.x + across.x * slope.y, 0.0,
					along.y * slope.x + across.y * slope.y);
				grad += vec3(grain - 0.5, 0.0, patch - 0.5) * mix(0.035, 0.09, rock);
				grad -= wnormal * dot(wnormal, grad);
				NORMAL = normalize(NORMAL - (VIEW_MATRIX * vec4(grad, 0.0)).xyz * relief * bp_mask);
			}
		}
	}

	ALBEDO = base;
	ROUGHNESS = rough;
	METALLIC = metal;
	SPECULAR = specular_value;

	// ---- A6 烘焙 AO + 逐材质环境光强度 ----
	// ⚠️ Godot 4 的 fragment() 里**没有** DIFFUSE_LIGHT（那个只在 light() 里可写），
	// 所以要表达原版 `finalDiffuse *= mix(1, ao, direct)` 只能用 AO_LIGHT_AFFECT：
	// Godot 会自行把直射光乘上 mix(1, AO, AO_LIGHT_AFFECT)，语义完全一致。
	float ao_scale = 1.0 / max(env_scale, 0.02);
	if (use_city_ambient) {
		// 2026-11-05 环境光配平：烘焙 AO 在楼影/楼脚会压到 0.2~0.3，而阴影区
		// **没有直射光**，环境光再被 AO 一乘就归零 —— 实测整片草地 RGB≈0.00
		// （关掉实时阴影同一片区域是亮的，证明是"环境光被 AO 吃掉"而不是阴影过深）。
		// 这里给 AO 一个下限 AO_MIN：保留原版"楼脚更暗"的遮蔽语义，但不允许
		// 把天空回弹压没；上限 3.0 防止 env_scale 极小时过曝。
		AO = clamp(city_ambient_at(wpos, wnormal) * ao_scale, AO_MIN, 3.0);
		AO_LIGHT_AFFECT = city_ambient_params.z;
	} else if (abs(env_scale - 1.0) > 0.001) {
		// 没有烘焙 AO 时，AO 只用来表达环境光强度，不该影响直射
		AO = ao_scale;
		AO_LIGHT_AFFECT = 0.0;
	}

	// ---- A2 公共照明场：作为入射漫射照度加进去，不是地面发光贴图 ----
	// 原版注入的是 `finalDiffuse += surfaceAlbedo * publicLux * …`；Godot 里等价的
	// 无光照附加项就是 EMISSION（同样不吃 AO，同样在色调映射前叠加）。
	if (city_light_field.w > 0.0001) {
		vec2 public_uv = (wpos.xz - city_light_field.xy) / city_light_field.z + 0.5;
		float public_inside = 1.0 - smoothstep(0.42, 0.49, max(abs(public_uv.x - 0.5), abs(public_uv.y - 0.5)));
		vec3 public_lux = texture(public_irradiance, public_uv).rgb;
		EMISSION += ALBEDO * public_lux * city_light_field.w * public_inside
			* max(0.0, wnormal.y) * 3.6;
	}

	// ---- P2c 雨天沥青平面镜（2026-10-24）----
	// 原版 setupReflections() 给 asphalt 直接挂 512 镜像（雨天 RAIN_LOOK 粗糙度
	// 0.455 时锐利，干路 0.92 时糊没）—— 雨天路面的金色眩光就是它。
	// 移植版镜像只在雨天开（mirror_strength 由 ground_field.gd 按档位写入）。
	// SCREEN_UV 投影采样 + v 翻转，与水面/积水同一套约定（修复记录 二十八）。
	if (mirror_strength > 0.0) {
		vec3 V = normalize(CAMERA_POSITION_WORLD - wpos);
		float cos_i = clamp(dot(V, wnormal), 0.0, 1.0);
		float fresnel = 0.04 + 0.96 * pow(1.0 - cos_i, 5.0);
		vec2 muv = clamp(vec2(SCREEN_UV.x, 1.0 - SCREEN_UV.y),
			vec2(0.002), vec2(0.998));
		EMISSION += texture(mirror_tex, muv).rgb * fresnel * mirror_strength;
	}
}
