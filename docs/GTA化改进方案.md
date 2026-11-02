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
  警灯 v1 先不做频闪（MultiMesh 逐实例颜色成本高），v1.1 用"红/蓝两张贴图各一个
  MultiMesh 交替显隐"实现。
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

### 2.3 武器与战斗（二期内）

- 3 把枪（手枪/冲锋枪/霰弹枪）：射线命中 + 行人 `create_body` 复用倒地 + 车辆表面弹孔贴花。
- 开枪 → `report_crime("weapon")`；警车会向开枪点收拢。
- 命中玩家：生命/护甲 HUD（复用表盘旁能量圈），死亡 → 医院重生扣钱。

### 2.4 任务链（二期内）

- JSON 数据驱动任务：`{trigger_pos, type: deliver/race/eliminate, reward, steps[]}`。
- 触发点从路网主分量 + landmark 列表选；奖励进金钱（为商店铺路）。
- 竞速任务复用 `road_graph.route()` 生成检查点折线。

---

## 三、二级：地图精致度

1. **分区色板**：`architecture_materials.gd` 按城市象限换 4 套建筑色板/材质密度
   （老城暖砖 / 金融玻璃 / 海滨低层 / 工业灰），`CityData` 增分区查询函数。
2. **地标剪影**：挑 3 个手工地标（塔/桥/体育场）进 `distant_city.gd` 远景层。
3. **路面贴花**：`road_surface.gd` 纹理 atlas 扩：车道线/斑马线/井盖/油渍；
   路缘石几何（30cm 高差）只做 detail 区块。
4. **烘焙光照**：detail 区块静态建筑 LightmapGI 一版；与 `lighting_director` 动态天光分层。
5. **室内与天台**：5–10 个功能室内 + 天台可达（`rooftop_layer` 补楼梯交互）。

## 四、三级：世界可信度

1. 行为生态：行人等灯/避让/惊逃，交通让行应急车辆（警笛半径内靠边）。
2. 环境音：分区 ambient loop + 警笛（`procedural_audio` 合成，不开音频文件）。
3. 商店经济：金钱 + 2 个商店（武器/改装）最小闭环。
4. 存档循环：死亡医院扣钱、被捕警局扣枪（接 `save_system.gd`）。

## 五、多人同步（三期，需扩 kcp_tauri 协议）

- binary_protocol 增 `WANTED` 消息（1 字节星级 + 1 字节 heat/255），
  `RoomBroadcast` 转发；远程玩家头顶显示其通缉星。
- 警察仍由**各客户端本地模拟**追自己（GTA 线上模式同款，避免服务器权威 NPC 的成本）。

---

## 六、本期实施清单

- [x] `docs/GTA化改进方案.md`（本文档）
- [x] `scripts/gameplay/wanted_system.gd` —— 通缉值/警力部署/警车 AI/被捕脱捕/诊断
- [x] `scripts/ui/game_hud.gd` —— `set_wanted(level, heat)` 五星 UI
- [x] `scripts/world/city_world.gd` —— 挂载 `wanted` 子系统
- [x] `scripts/core/main_game.gd` —— 触发接线 + 诊断 + 挂载
- [x] 抢车交互（§2.2）：F 键抢 AI 车 + 惊散波 + 通缉 +1★
- [ ] 武器战斗（§2.3）→ 任务链（§2.4）
