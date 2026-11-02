# GTA 化改进方案（深城纪）

> 2026-11-02 固化。目标：在不推翻现有"数据驱动城市 + MultiMesh 大规模渲染"架构的前提下，
> 把玩法补成 GTA 式闭环，并把地图从"规模像"推进到"精致像"。
> 实施顺序 = 优先级：**一级（玩法手感）→ 二级（地图精致）→ 三级（世界可信）**。

---

## 一、现有基础盘点（对接点）

| 已有系统 | 位置 | 本方案的复用方式 |
|---|---|---|
| 路网图 + A* | `scripts/world/road_graph.gd`（42829 节点，网格索引 + 主分量兜底） | 警车寻路、任务点选址 |
| AI 车流 | `scripts/world/traffic_system.gd`（40 辆，MultiMesh，10Hz 同步） | 警车行为模板（数据坐标 + 边行走）；撞车判定来源 |
| 行人撞击 | `scripts/world/pedestrian_impact.gd` + `pedestrian_system.apply_car_motion()` | 通缉触发源（撞人） |
| 红绿灯 | `scripts/world/traffic_signals.gd` | 警车闯灯（忽略 hold） |
| HUD | `scripts/ui/game_hud.gd`（纯程序化 UI，`_label()` 约定） | 通缉星 UI |
| 生存/生涯/剧情 | `main_game` 的 rides/career/story | 任务链的数据驱动参照 |
| 程序化音频 | `scripts/core/procedural_audio.gd`（`audio.cue()`） | 警笛/环境音 |
| 多人战局 | `scripts/net/*`（GameData 二进制协议） | 三期：通缉状态同步（需扩协议） |
| 存档 | `scripts/core/save_system.gd` | 三期：通缉/金钱持久化 |

**架构铁律**（全部沿用，违反即返工）：

1. 世界逻辑一律走**数据坐标**（x=东，z=北），渲染前才经 `CoordinateUtil.to_world()` 转世界坐标；
   世界 z = -数据北。
2. 大规模同构体用 **MultiMesh**，实例同步节流（10Hz 量级），`cast_shadow = OFF`。
3. 新脚本不写 `class_name` 依赖的裸 `new()`，统一 `preload` + 常量（编辑器重扫缓存问题）。
4. 每帧 GDScript 开销敏感：查距离用平方距离，节流到 0.1–0.25s， Diagnostics 可查。

---

## 二、一级：核心手感（现在开始）

### 2.1 通缉与警察系统 ✅ 本期实施

**文件**：`scripts/gameplay/wanted_system.gd`（新增 `gameplay` 目录，后续武器/任务都放这里）

**通缉值模型**：

- `wanted_level: int`（0–5 星，玩家可见），`heat: float`（当前星内进度 0–1）。
- 犯罪上报 `report_crime(kind: String, pos: Vector2, severity: float)`：
  - `hit_ped`（撞倒行人，severity=撞击速度归一）+0.4~0.7 星；
  - `hit_car`（撞 AI 车辆）+0.15~0.25 星（带 2s 冷却，防贴墙刷星）；
  - `hit_cop`（撞警车）+0.5 星；`weapon`（开枪，预留）+0.3 星。
  - heat 溢出 1.0 → 升一星；同 3 秒内重复同种犯罪有收益递减（×0.6/次），防抖。
- **衰减**：无新犯罪且最近警车 > 250m 或视野脱离 → 每档 `COOL_SEC`（星级越高越久：
  12/16/20/26/34/45s）掉 0.25 heat；heat 归零降一星。掉到 0 星清空全部警力。

**警力部署**（按星级，直接决定追捕强度）：

| 星级 | 警车数 | 警车极速 (m/s) | 说明 |
|---|---|---|---|
| 1 | 2 | 14 | 巡逻式尾随 |
| 2 | 3 | 15 | |
| 3 | 4 | 16 | |
| 4 | 6 | 18 | |
| 5 | 8 | 20 | 全力拦截 |

**警车 AI**（数据字典 + MultiMesh，完全对齐 TrafficSystem 风格）：

- 生成：路网主分量节点上，距玩家 80–200m、degree≥2，彼此间隔 ≥15m；
  增星时**只补差额**，掉星时按距离最远的先回收。
- 追击：沿图行走，到节点后选"使到玩家距离最小"的邻边（贪心，O(度数)，
  不跑全量 A*）；被 `signals.signal_hold` 拦住时 3 星以上**无视红灯**。
- 顶撞判定：警车与玩家车距离 < 4m 且相对速度 > 8m/s → 玩家车 speed 打 0.55 折
  （撞停感），并 `report_crime("hit_cop")` 冷却版（0.2 星）。
- **Busted（被捕）**：玩家 speed < 2m/s 且 2 辆以上警车 8m 内持续 4s → 发 `busted`
  信号 + toast；本期只做信号与提示，医院/警局重生循环接 `save_system` 时再落。
- **脱捕**：见衰减；清星时 toast "已摆脱通缉"。
- 渲染：复用 `data/city/traffic-car.glb`，车漆面改**黑白警用涂装**（白车身黑引擎盖的
  双色靠两个 group：group0 白车身、group1 黑盖，实现为两个 MultiMesh 集合）；
  **警灯频闪** ✅（2026-11-02 v1.1）：车顶灯条为程序化 BoxMesh（无模型资产），
  自发光红/蓝两组 MultiMesh 在 10Hz 车身同步 tick 交替写入（单色 5Hz 闪烁），
  车模缺失时灯条仍渲染（逻辑照跑）。
- 诊断：`diagnostics()` 返回 `{level, heat, cops, nearest_cop_m, state}`，
  并入 `main_game.diagnostics()`。

**触发接线**（`main_game.gd`）：

- `_step_car()`：`apply_car_motion()` 返回击倒数 > 0 → `report_crime("hit_ped")`；
  子步碰撞后扫 `world.traffic.car_poses()` 距离 < 3.5m 且车速 > 5 →
  `report_crime("hit_car")`（内部自带冷却）。
- 挂载：`world.wanted = _add_system(WANTED_SCRIPT, "WantedSystem")`，
  `city_world.gd` 增 `var wanted` 并加入 `_update_subsystems` 列表。
- HUD：`hud.set_wanted(level, heat)` —— 顶部居中 5 颗星（`★` 实/虚，亮色
  `#e8b64c`，熄色 22% 白），当前星按 heat 做半透明脉冲；通缉 ≥1 星才显示。

**验收**：撞倒 1 名行人 → 1 星 + 2 辆警车 15s 内到场；持续逃跑 → 星升高、警车变多；
甩开 250m+ 冷却 → 逐星熄灭；F3 诊断可见 `wanted` 字段。headless 冒烟不报错。

### 2.2 抢车与载具交互 ✅ v1 已实施（2026-11-02）

- 步行按 F：先判自己的车（5m）；够不到时改判 **3m 内的 AI 车流车** → 抢车：
  1. `TrafficSystem.nearest_car()` 选目标，`walk.can_enter()` 用目标位姿**预探测**
     落脚点（被挡就不动手）；
  2. 通过后目标车从车流摘除（`remove_car`），玩家轿车 `reset_to` 瞬移到目标位姿，
     走标准上车链路 —— MultiMesh 少一辆、玩家车模型出现在同一位置，视觉无缝；
  3. `report_crime("carjack")` 通缉 +1★；`TrafficSystem.panic()` 惊散波：
     40m 内车流 6 秒内提速 1.6 倍逃散。
- 下车：既有逻辑已是 GTA 式停车（模型留在原地 + ALS 障碍盒），无需改动。
- 待补（v1.1）：抢车动画（拽驾驶员下车，依赖 ALS 交互动作）；
  玩家 OwnedVehicle 多车留存池（当前被抢的车即玩家唯一轿车）。

### 2.3 武器与战斗 ✅ v1 已实施（2026-11-02）

- **`scripts/gameplay/weapon_system.gd`**（RefCounted 纯数据）：三把枪
  （9mm 手枪 300RPM / 冲锋枪 750RPM 全自动 / 霰弹枪 7 弹丸），弹匣 + 换弹计时。
- **弹道**：数据坐标 2D 射线（本作命中判定全是平面数据，俯仰 v1 忽略）——
  步进 1.2m 查 `CityCollision.blocked`（建筑挡弹）；行人命中走
  `pedestrian_system.shoot_hit()`（段-点 0.7m 半径，复用车辆撞击的
  `create_body` 刚体击倒链路）；车流/警车扫过 1.6m 内算命中（v1 无车辆伤害）。
- **操作**：步行按 1/2/3 选枪（再按同键收枪）、左键开火（全自动可按住）。
  LMB 在步行模式原本空闲（观战模式的信标长按不受影响）。
- **警察开火**：3 星起，70m 内每辆警车 1.3s 一发，命中率随距离衰减（8%–50%），
  伤害 8–14；**车内免伤**（v1 只打步行玩家）。
- **生命与死亡**：HUD 血条（左上 150×5，<30 变红）；归零 → 清通缉 +
  就近路网主分量节点苏醒（ALS 传送按"先退出→改落点→再进入"顺序）。
- 开火 → `report_crime("weapon")`（wanted 内部 2s 冷却去抖）。
- **待补（v1.1）**：枪声（procedural_audio 加噪声包络，`cue()` 是 match 静默
  兜底，加 "gunshot" 分支即可）、持枪模型/动画、车辆伤害、drive-by。

### 2.4 任务链 ✅ v1 已实施（2026-11-02）

- **`scripts/gameplay/mission_system.gd`**（RefCounted）+ **`data/game/missions.json`**：
  任务模板（名称/文案/赏金/限时/参数）全部在 JSON；触发点/目标点**运行时**从
  路网 degree≥2 节点选（城市坐标不写死，换图不用改数据）；JSON 缺失时用内置兜底。
- **三种任务**：
  - `deliver` 送货：光标触发 → 目标点 20m 内完成；限时 = JSON 或按路程推导
    （同生涯合约的 11m/s + 60s 底）；
  - `race` 竞速：`graph.route()` 折线按 350m 采样检查点，按序 30m 内过点，
    限时按折线总长 / 12m/s 放宽 35%；
  - `eliminate` 清场：目标街区半径内用武器放倒 N 人（`note_hit()` 进度上报，
    通缉会自然涨，脱身是任务的一部分）。
- **光标经济**：同时最多 2 个任务光标（300–1500m 内），20s 周期或走远 1500m 才重排，
  触发半径 12m；光标/目标用 `maps.set_destination_marker()` 上图（只设标记，
  不触发自动驾驶；玩家在用自动驾驶时不动他的标记）。
- **失败条件**：超时 / 被捕 / 被击倒 → toast + 光标重铺；赏金走 `GameState.add_cash`
  （与生涯共用钱包，随存档持久化）。
- **待补（v1.1）**：任务完成度存档（当前可重复接）、mission UI 面板（当前 toast +
  地图标记）、eliminate 的敌对 NPC（当前打路人算数）。

---

## 三、二级：地图精致度

1. **分区色板** ✅ v1 已实施（2026-11-02）
   - 实现：`architecture_pbr.gdshader` 增 `instance uniform vec3 district_tint`
     （只乘反照率，不动窗光自发光）；`architecture_materials.gd` 按 MeshInstance
     **世界坐标**判分区并 `set_instance_shader_parameter` 染色——材质仍按
     profile 键共享，**材质数零增长**，染色纯 GPU。
   - 分区（城市 extent x∈±6788 / z∈±2605，归一化后）：
     | 分区 | 判定 | tint（线性） | 身份 |
     |---|---|---|---|
     | 中央 core | \|nx\|<0.30 且 \|nz\|<0.55 | 不染 | 保持原版观感 |
     | 金融 finance | nx ≥ 0.30 | (0.88, 0.94, 1.06) | 冷蓝白玻璃感 |
     | 工业 industrial | nx ≤ −0.30 | (0.82, 0.82, 0.80) | 灰暗去饱和 |
     | 老城 old_town | 中带 nz > 0 | (1.09, 0.97, 0.86) | 暖砖 |
     | 海滨 waterfront | 中带 nz ≤ 0 | (1.02, 1.04, 0.97) | 暖白偏绿 |
   - 只染普通楼体/立面（landmark 有独有配色不染）；诊断加 `districts` 计数。
   - ⚠️ headless 检查不编译 shader：`instance uniform` 若在运行时报错，
     症状是立面材质失效——回退方案是把 instance uniform 降级为普通 uniform
     + 全城统一 tint（或撤掉 shader 改动即可，GDScript 侧无害）。
2. **地标剪影**（待做）：3 个手工地标进 `distant_city.gd` 远景层——需要模型/程序化
   几何设计，单独一轮做。
3. **路面贴花**（部分已有）：`roads.glb` 自带 roadline 车道线几何且已按原版校准；
   斑马线/井盖/油渍需要新贴图 atlas，待美术资产。
4. **烘焙光照**（待做）：detail 区块 LightmapGI——流式区块与烘焙光照的兼容性
   需要先小范围验证，单独一轮做。
5. **室内与天台**（待做）：5–10 个功能室内 + 天台可达。

## 四、三级：世界可信度

1. **行为生态** ✅ v1 已实施（2026-11-02）—— 行为比数量优先：
   - **行人惊逃**（`pedestrian_system.panic_at(threat, radius)`）：半径内行人
     加速 ×2.2 逃离 6 秒，且把行进方向翻成背离威胁的一侧（行人沿人行道段走，
     "沿段加速 + 选对方向"即可读出四散奔逃）。触发源：开枪（40m）、撞倒行人（30m）。
   - **车流让行**（`traffic_system.yield_positions`）：通缉中警笛范围内
     （警车 22m）的 AI 车靠边停车——警车逆行超车的街景由此成立。
     main_game 每帧把 wanted 的警车位喂给车流；通缉结束自动清空。
   - 待补（v1.1）：行人等红灯过街（需要人行横道数据）、围观事故、
     逃跑姿态（当前是加速的走路动画，非奔跑骨骼）。
2. **环境音** ✅ v1 已实施（2026-11-02）—— 全程序化合成，零音频文件，扩展 `procedural_audio.gd`：
   - **城市底噪**：220Hz 低通白噪 0.016（所有分区常驻的远处车流/人声层）；
   - **分区特色声**（`set_world_audio(district, rain)`，按 §3.1 的分区函数切换）：
     海滨 = 320Hz 低通噪声 × 8s 周期 LFO 浪涌；工业 = 55Hz 正弦嗡鸣 + 140Hz 噪声
     （变压器听感）；老城 = 500Hz 中频街市碎响；金融 = 900Hz 宽频空旷风噪；
   - **雨声**：3000Hz 高频噪声 0.030，随 `GameState.rain` 进出；
   - **警笛**：wail 滑频（700±240Hz、0.16Hz 周期），强度 =
     `wanted_system.siren_level()`（1 星起 0.3 底噪，最近警车 300m 线性到 1.0），
     强度在音频侧再平滑 2.5/s 进出场，避免出入视野咔哒；
   - **枪声**：白噪爆破 × 快衰减包络（9/s），射速上限天然防糊。
   - 滤波器状态池从 3 条扩到 6 条；全部走 effects 总线，随静音/effects_volume 生效。
3. **商店经济** ✅ v1 已实施（2026-11-02）：
   - **`scripts/gameplay/shop_system.gd`**：军品店（挂在 workshop 站点）——
     补满弹药 ¥150／解锁冲锋枪 ¥800／霰弹枪 ¥1200；老码头面馆（hub 站点）——
     牛肉面 ¥100 回满血。位置复用 `CareerSystem.place_position`，E 键进店、
     复用对话面板选购（数字键确认）。
   - **武器门控**：手枪默认拥有，冲锋枪/霰弹枪要在军品店买（`weapon_system.owned`
     运行时镜像 shop 的持久化拥有表）；已购齐后军品店只剩补弹。
   - **闭环**：任务/打工赚钱 → 军品店提升火力 → 更敢接 eliminate/冲更高星
     → 面馆回血续航。购买记录（owned_guns/累计消费）经 SaveSystem 持久化。
   - 待补（v1.1）：改装店（车辆调校，需 CarDrive 参数挂钩）、商店外观（门前
     3D 招牌/光标，需美术或程序化几何）。
4. **存档循环** ✅ v1 已实施（2026-11-02）：
   - **被捕**：罚款 ¥200（实扣 min(应付, 现金)，钱包不为负）+ **没收武器**
     （只剩手枪、弹匣清空、强制收枪）；
   - **被击倒**：医院治疗费 ¥300（保留武器——被捕才没收，GTA 同款区别）；
   - 两个惩罚都接在既有钩子上（`_on_wanted_busted` / `_respawn_player`），
     钱包 `GameState.add_cash` 随全局存档持久化。
   - 待补（v1.1）：警察局出现点（当前被捕原地释放）、罚金随星级浮动。

## 五、多人同步 ✅ v1 已实施（2026-11-02）

- **协议**：`kcp_tauri` 的 `binary_protocol.rs` 增 **WANTED 字段（bit9，0x0200）**：
  载荷 2 字节 = 星级 u8（0-5，越界钳制）+ 热度 u8（heat×255），排在 VELOCITY 之后
  （尾部）。roundtrip 单测 + 撞位防回归测试已覆盖，`cargo test` 7/7 通过。
- **转发**：服务器对 GameData 是透明转发（只拆目标会话 ID，不解析载荷），
  **零服务端流程改动**——旧客户端不带 bit9 自然兼容，新客户端解码时按位跳过。
- **客户端（GTA_SZ_GODOT）**：
  - `net_session.gd`：`bind_wanted_provider(Callable)`（main_game 返回
    `[level, heat]`），15Hz 状态包按位附加 WANTED；解码按 field_mask 消费；
  - `net_remote_player.gd`：`wanted_level` 属性，名牌缀星（"漫游者07 ★★★"）；
  - `main_game.gd`：`_net_wanted_state()` 把本地 WantedSystem 的星级/热度接进上报。
- 警察仍由**各客户端本地模拟**追自己（GTA 线上模式同款，避免服务器权威 NPC 成本）。
- 待补（v1.1）：小地图显示他人通缉、通缉者高亮描边。
  已补（2026-11-02 HUD 完善包）：小地图显示**自己的追捕态势**（警车红点）与
  任务光标/目标（金点），任务进度常驻栏（任务名 · 进度 · 剩余时间）。

---

## 六、本期实施清单

- [x] `docs/GTA化改进方案.md`（本文档）
- [x] `scripts/gameplay/wanted_system.gd` —— 通缉值/警力部署/警车 AI/被捕脱捕/诊断
- [x] `scripts/ui/game_hud.gd` —— `set_wanted(level, heat)` 五星 UI
- [x] `scripts/world/city_world.gd` —— 挂载 `wanted` 子系统
- [x] `scripts/core/main_game.gd` —— 触发接线 + 诊断 + 挂载
- [x] 抢车交互（§2.2）：F 键抢 AI 车 + 惊散波 + 通缉 +1★
- [x] 武器战斗（§2.3）：三把枪 + 2D 弹道 + 行人击倒 + 警察开火 + 血量/死亡重生
- [x] 任务链（§2.4）：JSON 模板 + deliver/race/eliminate + 光标上图 + 赏金入账
- [x] 分区色板（§3.1）：instance uniform 分区染色，材质数零增长
- [x] 环境音（§4.2）：城市底噪/分区特色声/雨声/警笛/枪声，全程序化合成
- [x] 行为生态（§4.1）：行人惊逃（枪声/撞击触发）+ 车流让行应急车辆
- [x] 商店经济（§4.3）：军品店（买枪/补弹）+ 面馆（回血），武器门控 + 持久化
- [x] 存档循环（§4.4）：被捕罚款没收武器 / 死亡医疗费
- [x] 多人同步（§五）：WANTED 字段跨端同步，远程名牌缀星
- [ ] 地标剪影（§3.2）/ 路面贴花补全（§3.3）/ 烘焙光照（§3.4）/ 室内天台（§3.5）

---

## 七、大地图流式加载优化（2026-11-02）

对照 PUBG / UE World Partition 的结论：chunk_streamer 骨架已正确（640m 块 +
3km/3.6km 迟滞 + 串行队列 + 纹理 dedup；碰撞是数据驱动解析判定，天然与渲染解耦）。
PUBG 的 8×8km 没有任何一块地被"完整加载"——地形是虚拟高度场、楼是离线烘焙的
GPU 就绪资产包、远处全是 LOD2/3 与 impostor。本项目落地两项，一项待做：

1. **方向性预取** ✅（`chunk_streamer.gd`）：加载评分从"距离² 最近"改为
   `距离² × (1 − 0.6 × 前进对齐度)`，前进方向由焦点位移每帧平滑估计（lerp 0.25）。
   高速直行时前方区块优先入队，身后刚出视野的块不再插队——飙车 pop-in 缓解。
2. **GLB→.scn 离线烘焙** ✅（`tools/bake_chunk_scn.gd`，UE cook 的等价物）：
   逐块 `ResourceSaver.save` 成原生二进制 .scn（FLAG_COMPRESS，
   CACHE_MODE_IGNORE 逐块释放内存）；运行时 `_resolve_load_path()` 优先 .scn，
   **比源 GLB 旧时自动回退 GLB**（烘焙永不锁死旧数据）。已烘焙 150/150 块。
   重烘用法：`godot --headless --script res://tools/bake_chunk_scn.gd [-- --force]`
   注意 .scn 随包分发（原生资源无 .import 侧车，导出即用）。
3. **区块 Impostor**（待做，aerial 观感质变）：块加载后 SubViewport 烘一张顶视
   thumbnail（256² ≈ 0.25MB/块），卸载时保留作远景 billboard——补上 3–6km 的
   细节真空。"远处的地图"其实是数据的照片。
4. **不需要抄的**：虚拟高度场地形（本项目平地 + ground_field 无此负担）、
   纹理 Mip 流送（Godot 无运行时 mip 流送，dedup 已是该约束下最优）、
   物理分块（city_collision 本就与渲染解耦）。
