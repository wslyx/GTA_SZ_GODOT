# 深城纪 · Godot 4.7 重制版

对 `.\GTA_SZ`（Babylon.js 浏览器城市游戏《深城纪》）的 Godot 4.7 一比一重制。

> 逐模块对照与完成度见 **[复刻对照表.md](复刻对照表.md)**。本文件讲怎么跑、架构怎么组织、以及**哪些地方与原版存在已知差异**。

---

## 一、运行方法

1. 安装 **Godot 4.7**（Forward+ 渲染器，需支持 Vulkan 的桌面环境）
2. 用 Godot 打开本目录下的 `project.godot`
3. 首次打开会触发资产导入。城市数据集较大（约 1.2 GB），**首次导入需要等待较长时间**，磁盘占用也会显著增加
4. 按 <kbd>F5</kbd> 运行

> 本目录**不含** `.godot/` 导入缓存 —— 那是本机生成物，不应提交。首次导入是不可避免的一步。

### 先跑一遍资产体检（可选但建议）

```sh
python tools/verify_glb.py
```

确认 `data/` 下没有任何 GLB 把 Godot 不支持的扩展写进 `extensionsRequired`。

---

## 二、资产是怎么来的（关键前提）

原版 `public/` 下的 **219 个 GLB 中有 168 个**使用 `EXT_meshopt_compression` +
`KHR_mesh_quantization`，并且都写在 `extensionsRequired` 里。**Godot 4 不支持这两个扩展，
会直接拒绝导入**。症状是模型不显示、`.import` 里写着 `valid=false`、脚本静默回退到占位盒 —— 
原版 Babylon 用 `meshopt_decoder.js` 在运行时解码，Godot 没有这条路径。

所以本重制版的第一步是资产转换：

```sh
# 需要 Node.js；先安装依赖
npm i @gltf-transform/core @gltf-transform/extensions meshoptimizer

# 转换：pubilc/ → data/，顺带把非 GLB 文件原样拷贝
node tools/convert_glb.mjs ../GTA_SZ/public ./data
```

脚本做四件事：
1. 注册 meshopt 解码器读出被压缩的几何
2. 卸载 `EXT_meshopt_compression` 与 `KHR_mesh_quantization`
3. 把 `normalized` 整型 accessor 还原成 `FLOAT`（`Accessor` 没有 `setComponentType()`，
   组件类型由 `setArray()` 传入的 TypedArray 自动推断）
4. 把 `KHR_texture_transform` **烘焙进 UV** 后再卸载该扩展（有 2 个文件用了它）

**转换结果**：170 个文件被改写，0 失败；体积从 383.6 MB 涨到 1248.1 MB
（解量化必然膨胀，这是 Godot 能读的代价）。

**未迁移的文件**（原版部署时同样跳过，属构建中间产物）：

| 文件 | 原因 |
|---|---|
| `city/facades.glb`（294 MB） | 已被 `facade-tiles/` 取代 |
| `city/street-surfaces.json`（35 MB） | 仅构建期使用，运行时无代码请求 |
| `city/ground-surfaces.json`、`city/surfaces.json` | 同上 |
| `city/meshopt_decoder.js` | Godot 不需要 |

> 依据：原版 `cloudflare/README.md` 明确写「`city/street-surfaces.json` 与 `city/facades.glb`
> 是构建中间产物，运行时没有代码请求，不上传也不部署」。

---

## 三、坐标系（先读这一段，否则所有位置都会错）

**Godot 世界 = `(x 东, y 上, z = −北)`**

这不是随意选择，而是唯一能避免大坑的选择：

- Blender 资产经 glTF 导出后为 `(east, up, −north)`
- 上述约定与它**完全一致** → **所有 GLB 无需任何旋转或镜像即可直接导入**
- 若改成 `z = +北`，就必须给每个 GLB 根节点做 Z 镜像，而**镜像会反转三角形绕序**，
  Godot 不保证自动补偿，是移植中最容易踩且最难排查的问题之一

数据侧的 `(east, north)` 只在入场景时做一次 `z = −north` 转换（`CoordinateUtil.to_world`）。

朝向换算（`CoordinateUtil`）：

| 模型在 glTF 里的前向 | 节点 `rotation.y` |
|---|---|
| `+Z` | `PI − yaw` |
| `−Z` | `−yaw` |

> **注意：不要凭"多数资产是 +Z"去猜，逐个实测过才知道。** 下面这张表是按各个零件
> 的几何包围盒中心量出来的（模型局部坐标），之前文档写反了，导致车倒着开：

| 资产 | 判据 | 实际前向 |
|---|---|---|
| `city/car.glb` | 前轮 `wheel_lf/rf_rubber` Z=−1.43 ／ 后轮 `wheel_lr/rr_rubber` Z=+1.78 | **−Z** |
| `city/traffic-car.glb` | 前灯 `car_led` Z=−2.24 ／ 尾灯 `car_redled` Z=+1.62 | **−Z** |
| `city/floatplane.glb` | 螺旋桨 Z=−4.19，座舱玻璃 Z=−0.52（桨在座舱前 3.7m，拉进式） | **−Z** |
| `city/tank/tank.glb` | 炮管 `tank_barrel_tube` Z=+3.54 ／ 炮塔座圈 Z=−0.90 | **+Z** |

对应到代码：`_place_car_model()` 与 `TrafficSystem` 用 `ModelForward.MINUS_Z`，
坦克仍用 `PLUS_Z`，飞机构基时 z 轴取 `−fwd`。

`yaw` 的方向定义与原版一致：`方向 = (sin yaw, cos yaw)`，即 `yaw=0` 指向正北。
另有 `yaw_to_direction()` / `direction_to_yaw()` 供需要在世界向量与数据朝向之间往返的地方使用。

---

## 四、目录结构

```
GTA_SZ_GODOT/
├── project.godot               Godot 4.7 配置（autoload / 输入映射 / 层名 / 渲染）
├── icon.svg
├── data/                       ← 由 tools/convert_glb.mjs 从 GTA_SZ/public 生成
│   ├── city/                     city.json、各紧凑 JSON、GLB、贴图、HDR
│   │                             blocks/ + blocks-manifest.json（640m 建筑流式区块）
│   ├── assets/                   旧城原型资产（street/room/chenye/linxia/bicycle）
│   └── characters/               MMD 角色（kuki / yelan）
├── tools/
│   ├── convert_glb.mjs           资产转换（meshopt/量化/texture-transform 剥离）
│   ├── split_city_blocks.py      把 buildings.glb 按 640m 区块切成流式 GLB + manifest
│   ├── verify_glb.py             转换后体检
│   ├── validate_project.py       静态体检（路径 / 括号 / class_name 引用）
│   ├── _shot.gd / _shot.tscn     截图探针：一次启动按 shot_plan.json 批量抓多组参数
│   ├── compare_shots.py          原版截图 vs 复刻截图的像素级量化比对
│   └── _inspect.gd               无头材质体检：dump 任意 GLB 的材质名/反照率/粗糙度
├── scripts/
│   ├── utils/                    coordinate_util / data_loader / geom_util
│   │                             glb_loader / spatial_hash
│   ├── core/                     main_game（主控制器）、city_data、game_state、
│   │                             game_content、save_system、graphics_quality、
│   │                             procedural_audio
│   ├── world/                    city_world（主编排）、height_field、city_collision、
│   │                             road_graph、chunk_streamer、facade_streamer、sky_system、
│   │                             lighting_director、bay_water、weather_system、
│   │                             scenery_system、sign_system、distant_system、
│   │                             traffic_signals、traffic_system、
│   │                             pedestrian_system、ebike_system、road_surface
│   ├── vehicles/                 car_drive、tank_sim、flight_sim、city_walk、
│   │                             observer、autopilot、chase_camera、vehicle_lights
│   ├── life/                     rides、career_system、story_system
│   └── ui/                       game_hud、map_ui、panels_ui
├── scenes/main.tscn              唯一场景，挂 MainGame
└── shaders/                      sky / night_sky / water / minimap
```

### autoload 单例

`CoordinateUtil`、`GameContent`、`GameState`、`SaveSystem`、`GraphicsQuality`、`CityData`

对应原版散落在各模块里的全局状态与常量表。

---

## 五、地面高度是五层叠加的

原版的 `world.groundHeight(x, z)` 由多次包裹而成，顺序不能变。`HeightField` 照搬：

| 顺序 | 层 | 数据源 | 算法 |
|---:|---|---|---|
| 0 | 城市基准平面 | — | 恒为 `0` |
| 1 | 莲花山高程 | `city/terrain-detail.json` | 网格 `x0=1179, z0=999, dx=dz=9, 126×86`；**每格按 SW→NE 剖分**做重心插值 |
| 2 | 远山 | `mountain-relief/heights.bin` | float32 行主序，`x0=−6804, z0=−2628, step=36, 379×324`；双线性 + 对角线 `a–e` |
| 3 | 近山 | `mountain-relief/near-heights.bin` | 同原点，`step=12, 1135×439` |
| 4 | 公园缓坡 | `ground-relief/relief-mesh.bin` | 46 块三角面（float32 顶点/法线 + uint32 索引），XZ 重心测试取高度 |
| 5 | 跨海桥梁 | `coastal/infrastructure.json` | `lift = height × (1 − t²(3−2t))`，`t = 沿桥距离 / ramp` |

水面高度取 `coastal/infrastructure.json` 的 `waterHeight = −0.25`。

两层山体数据都是**整块 float32 网格**：`379×324×4 = 491184` 字节、
`1135×439×4 = 1993060` 字节，与清单里 `budgets.bytes` 完全吻合。

---

## 六、碰撞不是物理引擎

原版 `CityCollision` 是解析式判定，本版逐行搬过来。`blocked(x, z)` 的判定顺序：

1. 若最近路段的距离 `< 路宽/2 − 0.65` → **不阻挡**（站在路面上）
2. 落在建筑环内，或距任意建筑外墙 `< 1.15 m` → 阻挡
3. 距某地标中心 `< 24 m` → 阻挡（`civic` 例外 65 m、`tencent` 例外 46 m）
4. 不在任何陆地环内 → 阻挡
5. 在某个水面外环内、且不在其任何内环（洞）里 → 阻挡

索引是边长 90 的均匀网格（路网格 / 建筑格分开），与原版一致。

载具撞击用固定子步推进：`steps = ceil(|speed| × dt / 0.7)`，车头检测点距车心 1.45 m
（坦克 3.4 m），命中回滚并把速度置 0 或 `−speed × 0.15`。

---

## 七、已知差异与未完成项

以下是**确实与原版不同**或**尚未实现**的部分。列在这里而不是藏起来。

> 2026-09-24 做过一轮「按原版截图一比一对齐」，路面 / 车道线 / 天空 / 环境光
> 结构 / 林冠与对岸材质 / HUD 版式（含左下圆形雷达与右下圆形表盘）都已按原版
> 源码逐项对齐，量化结果见 **[修复记录.md](修复记录.md) 第十三节**。
> 下表是那一轮**之后**仍然存在的差异。

### 渲染表现上的近似

| 项 | 原版 | 本版 | 影响 |
|---|---|---|---|
| 天空色调映射 | Babylon ACES（把 0.42~0.94 压到显示端 0.30~0.70） | Godot ACES + `sky_gain = 0.42` | 天空着色器是逐行译本，亮度差来自两家 ACES 的肩部差异，用增益标定；云的块感比原版略重 |
| 水面反射 | 512 平面镜（`MirrorTexture`，refreshRate 3） | 环境天空反射（IBL）+ SSR | 建筑在水中的倒影不如原版清晰；天空倒影基本一致 |
| 湿路面反射 | 512 平面镜（refreshRate 2，blurKernel 7） | 材质变暗 + 降粗糙度 | 雨天路面的镜面感弱于原版 |
| 雾 | Babylon `FOGMODE_EXP2` | Godot 指数雾，密度 ×100 换算 | 衰减曲线形状相近但非数学等价 |
| 局部照明 | 2 个池化 SpotLight + ~600 盏 OmniLight | 24 盏 OmniLight 池，按距离分配 | 远处路灯同时点亮数量少于原版 |
| 招牌文字 | 自建 2048×1024 动态图集 + 单 mesh | `Label3D` 池（≤64），用 `SystemFont` 取系统中文字体 | 视觉等价；无系统中文字体时文字会缺字 |
| 建筑材质 | 31 个 profile 的 PBR 参数表 | 直接使用 GLB 自带材质 | 立面质感差别最大的一项；实测建筑比原版亮约 1.7 倍 |
| 逐材质环境光强度 | `material.environmentIntensity`（沥青 .55 / 林冠 .82） | 无 | `StandardMaterial3D` 没有这个属性；林冠因此比原版亮 |
| 环境光遮蔽 | SSAO2 + 烘焙 `occlusion.png`（3399×1307） | 仅 SSAO | 街角接触阴影弱于原版 |
| HUD 绝对尺寸 | 小地图直径 246px（来自更早的构建） | 265.7px（按当前源码 CSS） | 当前 `city-hud.ts` 的 CSS 常量与用户提供的那张截图所属构建不同，本版以源码为准 |

### 尚未实现

| 原版模块 | 说明 |
|---|---|
| `city-facade-diversity.ts` | 立面多样性（同一建筑的窗格/阳台差异化） |
| `city-rooftops.ts`、`city-roof-surface.ts` | 屋顶装置与屋顶表面材质 |
| `city-architecture-materials.ts` | 31 个建筑材质 profile |
| `city-ambient-occlusion.ts` | 烘焙 AO 的应用（`data/city/ambient/occlusion.png` 已迁移但未接入着色器） |
| `city-meadow.ts` | 草地细节（`grassland-v2/meadow.json` 已迁移未接入） |
| `city-roadside-planting.ts` | 路边种植的完整布点规则（间距/否决项/密度） |
| `city-bamboo-cafe.ts`、`city-bamboo-corridor.ts`、`city-cafe-characters.ts` | 月白咖啡馆、竹廊、咖啡厅角色 |
| `city-local-characters.ts`、`city-character-hud.ts` | 原版 MMD 步行角色与角色 HUD（本版步行用 `pedestrian.glb`） |
| `pedestrian-impact.ts` | 行人被撞倒地（airborne → sliding → recovering） |
| `city-observer-beacons.ts`、`city-observer-destination.ts` | 观察信标与观察目标 |
| `city-cinematic.ts`、`trailer*.ts`、`aerial-film*.ts`、`combat-lab*.ts` | 宣传片管线、空中摄制、战斗实验室（原版专属非核心功能） |
| `city-graphics-quality.ts` 的档位切换重建 | 档位参数已实现并套用，但"切档时重建阴影/镜面/SSAO"未逐一落实 |
| `city-cockpit.ts` 的舱内模型 | 只实现司机位第一人称相机，无仪表盘 / 方向盘 / 内舱几何 |
| `city-vehicle-finish.ts`、`city-vehicle-materials.ts` | 车漆 PBR 独立调优 |
| `city-map-geometry.ts` 的完整标注避让 | 实现了标注门限与绘制，未实现 64px 网格的碰撞避让排布 |

### 结构性说明

- **旧城原型未接入**：`src/world.ts` + `src/state.ts`（青禾公寓、分拣配送小活）是原版更早的
  `world.ts` 客户端，`main.ts` 并未引用它。本版把它的**状态模型与数值**完整搬进了
  `GameState` + `GameContent`（`start_work` / `sort_parcel` / `advance_checkpoint` /
  `payout` / `buy` / `meet` / `next_day` 与校验规则全部照搬），但**没有做那套街区场景与 UI**。
- **地标候选的地面片过滤**：原版会丢弃候选地标里 `_water` 平板与扁平的 `_park` 平板
  （避免正射视角下出现"发亮的蓝薄片"）。本版保留了这个判断所需的 `isCandidateGroundSlab`
  等价逻辑，但简化了包围盒计算 —— 极端情况下可能有少量平板残留。

---

## 八、静态体检

```sh
python tools/validate_project.py
```

检查项：
- 所有 `res://` 路径是否真实存在
- 括号 / 引号是否平衡
- `class_name` 是否重复、跨文件引用是否悬空
- autoload 是否齐全

按项目约定不做编译校验，所以这是最接近"能不能跑"的静态保障。

---

## 九、许可与来源

代码沿用原版的 **MIT** 许可。`data/` 下的资产各自遵循原版声明的条款，
逐项见原版 `public/licenses/` 与 `data/ATTRIBUTION.md` —— 已随资产一并迁移：

- 道路、建筑轮廓：© OpenStreetMap contributors，ODbL
- 地形与地标：Copernicus DEM、各来源见 `data/city/LANDMARK_ATTRIBUTION.md`
- 天空 / 树木 / 座椅：Poly Haven / OpenGameArt（CC0 / CC BY）
- 主角车辆：Khronos CarConcept（DGG / Eric Chadwick），CC BY 4.0
- 久岐忍 / 夜兰：模型提供 miHoYo，MMD 模型改造 观海；**原包禁止商业用途与二次配布**，
  本项目未取得超出原条款的授权，与 miHoYo / HoYoverse 无隶属或官方合作关系

城市布局经过压缩，建筑高度与外观含游戏改编，**不是深圳全域的测绘级数字孪生**。
