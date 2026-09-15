# UGC 整改剩余待办（可挑选执行）

> 来源：`docs/knowledge/UGC_ARCHITECTURE_REVIEW_2026-09-10.md` 的 Phase 0-5、第 9/10 节，对照 2026-09-14 代码复核后的缺口清单。
> 状态基线：整体执行度约 64%；Phase 1（85%）与 Phase 3（95%）骨架已成立。
> 用法：按 ID 点单即可，例如「做 T5」。每项都写了目标、验收标准和依赖，避免做完无法判定。

## 快速选择建议

- **已完成**：T1（序列化收敛）、T2（按钮文案「验证」）、T3（PIE 验收 7/7）、T4（Golden 场景回归）、T5（Prefab 资产化 + AssetManager）、T8（属性与层级）、T9（entityId 决策）、T10（UI ViewModel 化）、T13（结构化日志）、T14（备份轮转/自动保存/崩溃恢复）、T15（显式迁移链）、T16（Compiler 错误列表 + 点击定位）、T17（编解码统一 + 弹道 schema）、T18（死代码清理）、T19（依赖瘦身 + 守卫 + UE 5.4 Shipping 构建验证）
- **低成本对齐（半天内）**：无（T2/T16 均已完成）
- **产品化主干**：无（T3/T5 已完成，剩 T11 拆插件）
- **多人方向**（需先定目标）：T6、T7、T12
- **长尾治理**：T11（拆插件，依赖 T5、T10）

## 待办清单

### ~~T1 序列化收敛：3 份 JSON 实现收敛为 1 份~~ ✅ 已完成
- 优先级：P0 ｜ 规模：S ｜ 依赖：无
- 目标：`Util/json.lua`、`Gameplay/UGC/json.lua`、`UGCSerialize.lua` 收敛为单一实现，文档持久化只保留一个经测试的编解码器。
- 验收：仓库只剩 1 个 JSON 模块；新格式 `project.ugc.json` 与旧 `scene.json + programs.json` 都经该实现读写并有回归测试；`json.lua` 对 NaN/Inf 输出合法 JSON。
- 状态：**已完成（2026-09-14）**，验收全部满足；详见「已执行记录」。

### ~~T2 蓝图编辑器「编译」按钮改名「验证」~~ ✅ 已完成
- 优先级：P1 ｜ 规模：XS ｜ 依赖：UE 5.4 编辑器
- 目标：按钮文案与按钮语义一致（当前按钮只做校验，产出 IR 的是 Runner）。
- 验收：`WBP_UGCBlueprintEditor` 中按钮显示「验证」；Lua 侧状态文案一致。
- 状态：**已完成（2026-09-15）**，验收满足；详见「已执行记录 → T2」。
- 备注：改的是 `.uasset` 内 `w_btn_compile` 的按钮文本（编辑器内改，不是字节补丁）；资产里另有 3 处「编译」属于其它文案
  （如节点说明「从引脚连出引线来编译功能」），与本按钮无关，未动。

### ~~T3 UE 5.4 编辑器内 PIE 验收~~ ✅ 已完成
- 优先级：P0 ｜ 规模：M ｜ 依赖：UE 5.4 编辑器
- 目标：把代码层已完成的整改在真实运行环境确认。
- 验收清单：
  1. 创建 / 移动 / 删除 / Undo / Redo
  2. 批量生成与原子回滚（失败批次不消耗 ID、不产生残留）
  3. 新旧存档加载（`project.ugc.json` 与旧 `scene.json + programs.json`）
  4. 图验证、Delay、Interval 真实时间调度
  5. Trigger Router 事件链路
  6. Authoring ↔ Playtest 双向切换 + GAS/属性/武器/规则清理
  7. AI 提案确认 / 取消与多轮 Tool Loop
- 状态：**已完成（2026-09-15）**，7 项在 UE 5.4 编辑器 PIE 内实跑 **7/7 通过**（脚本化、可复现）；
  详见「已执行记录 → T3」。鼠标手感类（真人拖 Gizmo / 点击落点）按先前约定由人工抽查，不在自动化范围。
- 复现方式：`python Tools/UGCTests/run_pie_smoke.py`（自动起编辑器 → MCP 拉起 PIE → 跑 7 项 → 收日志 → 关 PIE）。
- 附带产出：实跑抓出并修掉了两处**只有跑起来才暴露**的运行时断链（详见「已执行记录 → 实跑发现」）。

### T4 Golden Scene 与序列化 Golden 回归
- 优先级：P1 ｜ 规模：M ｜ 依赖：T1
- 目标：把「存档不漂移」变成可自动判定的回归，而不是靠人工看。
- 验收：仓库内 3 个 Golden 场景样本（含 external/PCG、Group、Program）；CI 或脚本可比对序列化输出差异并给出定位。
- 状态：**已完成（2026-09-14）**，验收全部满足；详见「已执行记录」。

### ~~T5 Prefab 迁移 `UPrimaryDataAsset` + `AssetManager`~~ ✅ 已完成
- 优先级：P1 ｜ 规模：L ｜ 依赖：无
- 目标：替换 Lua 硬编码 Catalog，使 Prefab 定义可被资产化、可被 AssetManager 扫描、可在 Shipping 生效。
- 验收：`UUGCPrefabDefinition : UPrimaryDataAsset`；ID 用 `FPrimaryAssetId`；Definition 含 ActorClass / DisplayName / Category / Tags / Bounds / Cost / AllowedModes / Version；`UGCPlaceableConfig.lua` 退化为迁移期兼容或删除。
- 状态：**已完成（2026-09-15）**，验收全部满足（ID 空间 `UGCPrefab:<Id>` / `UGCPrefabRuntime:<Id>` 合并为一份目录，
  磁盘资产与运行时注册（GLB）都在内）；`UGCPlaceableConfig.lua` 按拍板保留为**迁移期兜底**，不再是权威来源。
  实跑日志证据：`prefab_registry_ready {definitions:3, catalogFallback:0, scanned:0, total:3}`，编辑器预制体列表 3 个分类全部来自 Definition。
  详见「已执行记录 → T5」。

### T6 AI 服务端代理 + 配额 + 持久审计
- 优先级：P1 ｜ 规模：L ｜ 依赖：需先定「单机 / 多人」目标
- 目标：把 Key 与策略移出客户端，形成可审计的 AI 修改链路。
- 验收：Provider 抽象与服务端代理；配额 / 限流 / 幂等重放；持久审计日志（谁、何时、基于哪个 Revision、改了哪些命令）；客户端不再直连模型供应商。

### T7 AI 多命令提案 → CompositeCommand 翻译层
- 优先级：P1 ｜ 规模：S ｜ 依赖：你拍板（当前实现主动偏离方案）
- 背景：方案要求「AI 多命令 → CompositeCommand 原子执行」；本轮实现为「单提案最多一个写操作，批量请用原子生成器」，以避免部分成功的中间态。
- 验收：二选一并记录理由：
  - 保留单写限制：在文档中把该约束写成设计决策，并说明批量场景的替代路径；
  - 改回 Composite：所有写命令可编译成一个 CompositeCommand，失败整体回滚，并补提案级测试。

### ~~T8 实体属性与层级（SetProperty + parent/children + Typed Property Bag）~~ ✅ 已完成
- 优先级：P2 ｜ 规模：M ｜ 依赖：无
- 目标：Document 的 `properties` 目前只被搬运、无命令写入；缺少层级表达。
- 验收：`SetProperty` 命令（可 Undo/Redo）；`parentId/children` 或等价层级字段；属性带类型校验（数值/字符串/枚举/引用）。
- 状态：**已完成（2026-09-15）**，验收全部满足；详见「已执行记录」。

### ~~T9 entityId 收敛为 FGuid（或明确保留字符串）~~ ✅ 已完成（保留字符串，见记录）
- 优先级：P2 ｜ 规模：S ｜ 依赖：无
- 目标：方案要求 `Guid` EntityId；当前为字符串（`docId-entity-N`）。
- 验收：要么改为 Guid 并保证存档/PCG/网络稳定；要么在文档中记录「字符串 ID 为最终设计」的理由与约束。
- 状态：**已完成（2026-09-15）**：决定保留派生字符串 ID，并把它的约束用代码 + 测试钉死；详见「已执行记录」。

### ~~T10 UI ViewModel 化 + 事件驱动刷新~~ ✅ 已完成
- 优先级：P1 ｜ 规模：L ｜ 依赖：无
- 目标：UI 仍由 PlayerController 的 Tick 驱动（`ReceiveTick → UpdateWires`），未引入 ViewModel / Subsystem。
- 验收：图编辑器与编辑面板改为事件驱动刷新；Tick 只保留必要的输入采样；ViewModel 持弱引用并在 Destruct 解绑。
- 状态：**已完成（2026-09-15）**，验收全部满足；详见「已执行记录」。

### T11 拆分 FPSUGCCore / Runtime / Scripting / UI / AI / Developer 插件
- 优先级：P2 ｜ 规模：XL ｜ 依赖：T5、T10
- 目标：当前全部挤在 `FPS` 单模块，Runtime 还硬依赖 UMG/Slate/HTTP/PCG。
- 验收：Core（纯数据 + 可无 World 测试）、Runtime、Scripting、UI、AI、Developer 边界清晰；Shipping 目标不需要 DesktopPlatform 与磁盘资产扫描。

### T12 多人：ServerCommandTransport + Revision 冲突 + 增量复制
- 优先级：P2 ｜ 规模：XL ｜ 依赖：需先定「单机 / 多人」目标
- 目标：当前仅单机（无任何 Transport）。
- 验收：`LocalCommandTransport` / `ServerCommandTransport` 抽象；服务端校验与广播；Revision 冲突解决策略；增量事件复制。

### ~~T13 结构化日志~~ ✅ 已完成
- 优先级：P2 ｜ 规模：S ｜ 依赖：无
- 目标：目前只有 CommandBus 的 `print`，缺少 UE Log category 与关联字段。
- 验收：独立 Log category；日志带 SessionId / CommandId / ProgramId / EntityId；错误路径有稳定 ErrorCode。
- 状态：**已完成（2026-09-14）**，验收全部满足；详见「已执行记录」。

### T14 备份轮转 + 自动保存 + 崩溃恢复
- 优先级：P2 ｜ 规模：M ｜ 依赖：T1
- 目标：存档目前只保留 1 代 `.bak`，无自动保存与崩溃恢复。
- 验收：备份轮转（N 代）；自动保存策略与节流；异常退出后可恢复到最近有效版本。
- 状态：**已完成（2026-09-14）**，验收全部满足；详见「已执行记录」。

### T15 显式迁移链 V1 → V2 → V3
- 优先级：P2 ｜ 规模：M ｜ 依赖：T14
- 目标：当前只有「旧格式只读兼容」，没有版本化迁移链与迁移测试。
- 验收：每级迁移有独立函数与样本文件；迁移失败可回滚且不损坏原文件。
- 状态：**已完成（2026-09-14）**，验收全部满足；详见「已执行记录」。

### ~~T16 Compiler 错误列表 UI~~ ✅ 已完成
- 优先级：P3 ｜ 规模：S ｜ 依赖：无
- 目标：Compiler 已返回 `nodeId` / `pin`，但 UI 只展示首条错误。
- 验收：可滚动错误列表；点击定位到节点与引脚。
- 状态：**已完成（2026-09-15）**，验收满足，并在 PIE 冒烟第 8 项里脚本化验收（8/8 通过）；详见「已执行记录 → T16」。

### ~~T17 编解码统一到单一实现（含武器弹道 JSON）~~ ✅ 已完成
- 优先级：P3 ｜ 规模：M ｜ 依赖：T1
- 目标：`BP_WeaponBase.lua` 仍用 `rapidjson` 读弹道配置，与 UGC 编解码不一致。
- 验收：明确「谁负责哪类 JSON」，或统一到单一编解码路径；配置格式有 schema 与校验。
- 状态：**已完成（2026-09-15）**，验收全部满足；详见「已执行记录」。

### ~~T18 移除死代码：`EditorCore:SaveSceneJSON / LoadSceneJSON`~~ ✅ 已完成
- 优先级：P3 ｜ 规模：XS ｜ 依赖：T1
- 目标：这两个包装函数无任何调用点（旧三文件存档路径已迁到 Persistence）。
- 验收：删除或标注 deprecated；`SceneData` 旧序列化入口收敛为「仅加载兼容」。
- 状态：**已完成（2026-09-14）**；详见「已执行记录」。

### ~~T19 Runtime 依赖瘦身 + Shipping 构建验证~~ ✅ 已完成
- 优先级：P2 ｜ 规模：L ｜ 依赖：T11
- 目标：`FPS.Build.cs` 的 Runtime 依赖仍含 UMG/Slate/HTTP/PCG。
- 验收：至少完成一次 Shipping 目标构建验证；Runtime Core 不依赖 DesktopPlatform 与裸磁盘资产扫描。
- 状态：**已完成（2026-09-14）**；UE 5.4 `FPS Win64 Shipping` 构建通过（exit 0，产出 `FPS-Win64-Shipping.exe`），
  细节见「已执行记录」。剩余未做的只有 T11 级别的更进一步拆分（Runtime Core 只依赖 Core/CoreUObject/Engine）。

## 已执行记录

- **T14 备份轮转 + 自动保存 + 崩溃恢复（2026-09-14）**
  - 世代布局：`<file>.bak`（最新，仍由 C++ 原子写维护）→ `<file>.bak1` → `<file>.bak2`；默认 3 代，上限 9
    （`ConfigureBackups`，`MAX_BACKUP_GENERATIONS`）。
  - 轮转只用「读上一代 + 原子写下一代」，不依赖 rename/delete，因此可以在没有删除能力的存储边界上成立；
    **写盘前先轮转**，这样 `.bak` 永远是「上一次成功保存」的内容，轮转中途崩溃最坏只丢一代更旧的备份。
  - 存储边界相应放宽：`UUGCStorageBridge::IsAllowedJsonPath` 现在还接受 `.bak` / `.bakN`（仍是 `Saved/` 下的白名单，
    其余后缀照旧拒绝）。这是 T14 的必要条件，已在 `ASSETS_AND_CONFIG.md` 记录。
  - 自动保存：`AttachProject` 绑定项目 → `UGCPlayerController:ReceiveTick` 调 `Persistence:Tick(deltaSeconds)`；
    受 `intervalSeconds`（默认 120）与 `minIntervalSeconds`（默认 30）双重节流，且只在 revision 相对上次保存变化时才写。
    `ConfigureAutosave` 可改策略，`GetAutosaveRuntime` 可读运行时状态。
  - 崩溃恢复：`LoadProject` 在主文件不可解码/校验失败时按世代从新到旧回退，第三个返回值给
    `{ recovered, generation, from, reason, migration }`，并且**不覆盖主文件**（决策权留给下一次保存）。
    `RestoreFromBackup(path, scene, generation?)` 是显式恢复入口。WBP_UGCEditor 加载后会提示「已从备份恢复」。
  - 回归：`Tools/UGCTests/run_persistence.lua` 从 1 项扩到 7 项（精确保存、N 代顺序、世代数配置与 clamp、
    自动保存 interval/节流/revision 判定/禁用/未绑定、崩溃恢复三级回退、主文件缺失恢复、存储边界后缀）。

- **T15 显式迁移链 V1 → V2 → V3（2026-09-14）**
  - 新增 `Content/Script/Gameplay/UGC/UGCMigrations.lua`：`Steps` 表里每级一个纯函数（只负责 `i → i+1`），
    `Migrate` 先深拷贝再逐级 pcall，任一步失败整链失败并返回原因；入参在任何失败路径下都不被修改。
    `CURRENT` 是唯一版本号来源，`UGCDocument` 的 `CURRENT_SCHEMA_VERSION` 直接取它，避免双维护漂移。
  - V1 → V2：收敛旧字段（`id`/`prefab`/`t` → `sceneID`/`prefabName`/`transform`）、补齐
    `entityId`/`actorId`/`programId`、按最大 sceneID 推导 `nextSceneID`、布尔标志归一化。
  - V2 → V3：补齐 `tags`/`properties`/`metadata` 容器与 `header.contentVersion`，组内成员归一化为 number 并
    丢弃悬空引用（否则 `ValidateSnapshot` 会整份拒绝），世界规则值归一化为 number 并丢弃非数值项，
    这些丢弃项都计入 `report.notes`。
  - 接入点：`Document.FromSnapshot` 对所有入口先迁移再校验（新包 / 旧包 / 旧 scene.json 兼容层同一条链）；
    `UGCPersistence:MigrateProject` 提供显式迁移并原子写回（写前先轮转，迁移前内容留在 `.bak`）。
  - 样本与回归：样本 `Tools/UGCTests/fixtures/migration_v1.ugc.json`、`migration_v2.ugc.json`；
    新增 `Tools/UGCTests/run_migration.lua` 8 项，覆盖两级迁移、当前版本空操作与逐字节稳定、幂等、
    未知版本拒绝且不改入参、步骤抛异常时整链失败且不改入参、`Document.FromSnapshot` 集成、
    加载路径「迁移但不重写文件」、以及 `MigrateProject` 的成功/无操作/失败三条路径。
  - 与 T4 的关系：v3 文档迁移是严格空操作，所以 golden 样本逐字节不变；一旦迁移逻辑改动意外触及 v3，
    `run_golden.lua` 会立刻报差异。

- **T4 Golden 场景与序列化回归（2026-09-14）**
  - 新增 `Tools/UGCTests/golden/`，3 个场景样本（均为可直接加载的版本化存档包）：
    `external_pcg.ugc.json`（外部实体 metadata.kind=pcg + worldSettings）、
    `groups.ugc.json`（匿名 batch_1 + 具名 batch_forest_a）、
    `program.ugc.json`（level_main + actor_prog_1）。
  - 新增 `Tools/UGCTests/run_golden.lua`，每个样本两组判定：
    `construct`（用公开 API 从零构出同一文档 → 序列化 → 与样本逐字节比对）
    与 `roundtrip`（样本 → DeserializePackageTable → 再序列化 → 必须等于样本，不动点）。
    program 样本额外跑 `Compiler:Compile`，保证「存得下来的程序」同时「编译得过」。
  - 归一化只做两件事：`savedAt`（os.time 不可复现）置 0、行尾 CRLF 对齐 LF；其余逐字节比对，
    不存在被忽略的字段。
  - 差异定位：先给 JSON 路径级结构差异（如 `package.document.entities.2.transform.1: expected 999, got 300`），
    再给行号级 LCS diff（`- golden:49` / `+ 输出:49`），最后提示用 `--update` 重新生成样本。
    已用「人为改坏样本」实测过失败路径：报告可定位、退出码非 0。
  - 重新生成样本：`Temp/LuaTools/lua54.exe Tools/UGCTests/run_golden.lua <repo-root> --update`，
    然后 review `git diff Tools/UGCTests/golden/`。
  - 已接入 `Tools/UGCTests/run_tests.ps1`（紧跟 `run_serialization.lua`）；回归总数 32 → 39 项。
  - 注意：任何改动文档/命令/序列化形状的工作（T8 属性、T14 备份、T15 迁移链）都会先在这里看到差异 ——
    这是本项的目的，不要用 `--update` 掩盖非预期漂移。

- **合并损伤修复（2026-09-14，本轮，无 T 编号）**
  - 背景：`5553fd8` 那次 develop 合并把 `UGCSceneData.lua` 解析成新旧两份实现的拼接，
    Lua 5.4 语法失败，`run_tests.ps1` 的语法门直接挂；T19 的 `FPS.Build.cs` 也被回退。
  - 修复：`UGCSceneData.lua` 以新架构（Document + CommandBus + Projection）为基线重建，并补回 Anim 侧唯一有意义的增量
    `SetActorCreatedHook` / `BeginNamedBatch` / `EndActiveBatch` / `GetActiveBatch`；
    `UGCWorldProjection` 增加 `onSpawn` 钩子；4 处 `require("Gameplay.UGC.json")` 改 `Util.json`；
    `AnimGenClient.cpp` 的 DesktopPlatform 与文件对话框收进 `#if WITH_EDITOR`；`FPS.Build.cs` 恢复 T19 布局 + `glTFRuntime`；
    10 处裸 `print` 改 `UGCLog`。
  - 验证：59 文件语法 + 5 组静态守卫 + 32 项 Lua 回归全绿；跨模块别名调用静态检查 0 处悬空。
  - 细节与已知语义缺口见 `RISKS_AND_GAPS.md` 的「2026-09-14 合并损伤与修复」。
  - 修复前请先确认这条记录仍然成立：任何后续合并后都要先跑 `Tools/UGCTests/run_tests.ps1`。

- **T1 序列化收敛（2026-09-14）**
  - 唯一实现：`Content/Script/Util/json.lua`（对象键字典序输出保证可 diff；NaN/Inf 编码为 `null`；decode 失败返回 nil 不抛异常）。
  - 删除：`Content/Script/Gameplay/UGC/json.lua`（仅差 1 行注释的复制品）、`Content/Script/Gameplay/UGC/UGCSerialize.lua`。
  - 引用迁移：`UGCSceneData`、`UGCPersistence`、`UGCFunctionRegistry`、`LLMGateway`、`WBP_UGCChat`、`Tools/UGCTests/run_llm_gateway.lua` 全部改为 `require("Util.json")`；`UGCSceneData` 的 6 处旧调用改写为 `json.encode(..., "  ")` / `json.decode`。
  - 回归测试：新增 `Tools/UGCTests/run_serialization.lua`（6 项）覆盖旧 `scene.json`（含 v1 的 `id`/`prefabName` 写法、external/`metadata.kind` 走 adapter、`generatedGroups`、`worldSettings`）、旧 `programs.json`、`SerializeToJSON` 输出形状与回读、NaN/Inf -> null、键序确定性、非法输入不抛异常。
  - 防回归：`Tools/UGCTests/run_tests.ps1` 断言两个已删模块不存在、`Content/Script` 下只剩 1 个 `json.lua`、全仓无 `UGCSerialize`/`Gameplay.UGC.json` 引用；语法扫描范围扩大到 `Content/Script` 全量 51 个文件。
  - 顺带修复存量缺陷：`Util/json.lua` 第 35 行的非法转义 `'\/'` 在 Lua 5.4 下无法编译——它是死代码所以从未暴露，收敛后立刻被测试捕获（现已改为 `'/'`）。
  - 结果：24 项 Lua 回归全部通过。
  - 未纳入本项：`BP_WeaponBase.lua` 的 `rapidjson` 弹道配置读取记为 T17；`EditorCore:SaveSceneJSON/LoadSceneJSON` 死包装记为 T18。

- **T13 结构化日志（2026-09-14）**
  - 新增 `Content/Script/Gameplay/UGC/UGCLog.lua`：UGC 唯一日志出口，单行 `event= severity= session= document= command= source= type= ok= code= program= entity= fields={json}`；字段 JSON 经 `Util.json`（键序稳定可 diff）。
  - 新增 C++ 独立分类：`Source/FPS/UGC/UGCLog.h/.cpp`（`DECLARE_LOG_CATEGORY_EXTERN(LogFPSUGC)` + `UUGCLog::WriteLine`）；无 UE 环境时 Lua 退回 `print`（UnLua → LogUnLua），因此单测无需 UE。
  - 稳定 ErrorCode：`UGCLog.Codes` 白名单（含本轮新增 `compilation_failed` / `budget_exhausted` / `unknown_instruction` / `node_failed` / `unsupported_opcode`）；未登记 code 记为 `unregistered_code` 并保留原值。
  - 接入范围：CommandBus（命令事件）、SceneData（初始化/清空/失败路径）、Persistence（save/load 及各类失败）、FunctionRegistry、LLMGateway、EditorCore、ProgramRunner（带 program 上下文）、PrefabRegistry、UGCPlayerController、Generators/Init —— 该层已无裸 `print`。
  - SessionId：`SceneData:Init` 调用 `Log.NewSession("scene_init")`，并把 documentId 写入长期上下文。
  - 回归：`Tools/UGCTests/run_logging.lua`（7 项）覆盖格式/字段/级别/未登记 code/全仓 code 白名单扫描/历史与订阅/无裸 print。

- **T18 死代码清理（2026-09-14）**
  - 删除：`EditorCore:SaveSceneJSON`、`EditorCore:LoadSceneJSON`（无调用点，含 `.uasset`/`.umap` 二进制扫描确认）。
  - 删除：`SceneData:SerializeEditorJSON`、`SceneData:DeserializeEditorJSON`（空实现，无调用点）。
  - 保留并显式标注：`DeserializeFromJSON/DeserializeProgramsJSON`（旧存档只读兼容，Persistence 迁移路径在用）、`SerializeToJSON/SerializeProgramsJSON`（标注 `@deprecated`，仅迁移/回归导出，运行时写入走 Persistence）。
  - 防回归：`run_tests.ps1` 断言上述已删 API 不再出现在 `Content/Script`（注释行除外）。
  - 回归：`run_serialization.lua` 新增「legacy serialization surface is load-first」用例（含 EditorCore 面不再暴露序列化透传）。

- **T19 运行时依赖瘦身 + Shipping 验证（2026-09-14，部分完成）**
  - `FPS.Build.cs`：`HTTP`/`Json`/`PCG` 降为 Private；移除未使用的 `Niagara`、`ApplicationCore`；保留 `AIModule`（`FPSCharacter.h` 暴露 `IGenericTeamAgentInterface`）；`DesktopPlatform` 仍 editor-only。
  - **修正（同日 UE 5.4 实测）**：`ApplicationCore` 被上面这条删错了 —— `UGC/UGCPlayerController.cpp` 调
    `FPlatformApplicationMisc::ClipboardCopy`，删掉后开发构建链接报 `LNK2019`（1 个未解析符号）。
    已加回 Private，并把 `run_tests.ps1` 的依赖守卫改成「必须保留 ApplicationCore」。
    教训：UBT/UHT 解析级证据不能替代链接级证据；「没有符号引用」的结论必须在真实链接后成立。
  - 静态守卫：编辑器专用 include/符号必须位于 `#if WITH_EDITOR` 内；`FPS.Build.cs` 必须保留 `Target.bBuildEditor`、不得重新引入 Niagara、且必须保留 ApplicationCore。
  - Shipping 探针（UE 5.7 + 临时补丁）抓到并修复真实缺陷：`InventoryGridComponent.cpp` 误引 Editor-only 的 `IDetailTreeNode.h`（未使用）导致 `fatal error C1083`。
  - 验证情况（UE 5.4 实测，2026-09-14）：
    * **Shipping 目标构建通过（exit 0）**：`Build.bat FPS Win64 Shipping` 编译 9 个 `Module.FPS.*.cpp` 后
      `Link [x64] FPS-Win64-Shipping.exe` 成功，产出 147 MB 可执行文件 + pdb + target；链接期零未解析符号。
      这同时反证 `#if WITH_EDITOR` 守卫有效（DesktopPlatform 若漏出，Shipping 必挂）。T19 验收项达成。
    * 开发（编辑器）目标下 FPS 模块也已编译 + 链接成功，但整个 Editor 目标仍被第三方 UnLua 的
      `UnLuaEditor` 模块链接失败阻塞（13 个 `UDeveloperSettings` / `UContentBrowserAssetContextMenuContext` 符号，
      插件侧 `Build.cs` 缺 `DeveloperSettings`/`ContentBrowser`，且该插件源码被 gitignore，属本机环境修复）。
      它不是 T19 的验收条件，但是 T3（PIE 验收）的前置条件。
  - 所有探针临时改动已逐字节还原（SHA256 校验通过）。
- **T17 编解码统一 + 弹道配置 schema（2026-09-15）**
  - 唯一编解码：`BP_WeaponBase.lua` 的弹道加载从 `require("rapidjson").decode` 改为 `require("Util.json").decode`；
    `Content/Script` 下已无任何 rapidjson 引用（`run_tests.ps1` 新增「Content/Script 内不得出现 rapidjson，注释行除外」守卫）。
  - 新增 `Content/Script/Gameplay/Weapon/WeaponBallisticsSchema.lua`：显式 schema——必填 `recoil_pattern`；
    可选 `random_spread_radius`（0~45）、`pattern_reset_time`（0.01~10）；每个弹道点必须是 2 个有限数值且 |值| ≤ 180；
    单武器最多 64 点、最多 64 个武器条目；**未登记字段直接拒绝**（键名拼错正是最需要被抓住的情况）。
  - 打包路径修复：`Content/Data` 之前没有 staging 条目，`io.open` 在打包后读不到弹道配置，
    会静默退化成「没有 Pattern 偏移」。`Config/DefaultGame.ini` 增加 `+DirectoriesToAlwaysStageAsNonUFS=(Path="Data")`。
  - 回归：`Tools/UGCTests/run_weapon_ballistics.lua`（5 项）：真实配置必须过校验；10 组坏配置必须被拒
    （键名拼错 / 缺必填 / 点结构错 / 数值写成字符串 / 越界 / NaN / 点数超限）；rapidjson 清零；staging 条目存在。
  - 未纳入：弹道配置的运行时热重载（现在首次访问读一次并缓存到 `BallisticsCache`）。

- **T9 entityId 决策 + 约束（2026-09-15）**
  - 决策：保留派生字符串 `<documentId>-entity-<sceneID>`（`Document.MakeEntityId` 唯一实现），不改为随机 GUID。
    理由：随机 GUID 会破坏 Golden 存档逐字节可比性（T4），也会让 v1→v2 迁移里「旧记录没有 entityId 时按 sceneID 派生」
    这条路径失去确定性；而现有 ID 已经确定性，存档 / PCG / 网络侧真正的需求是「稳定 + 不复用」。
  - 约束（代码 + 测试钉死）：`InsertEntity` 校验格式（非空、≤128、无控制字符）并拒绝重复 entityId；
    `ValidateSnapshot` 新增 **nextSceneID 必须严格大于最大 sceneID**（sceneID 复用会让派生 entityId 撞车）、
    以及 self-parent / 悬空 parentId / 环 的校验。
  - 回归：`Tools/UGCTests/run_entity_id.lua`（6 项）：派生规则、跨快照 / 旧 `scene.json` / 迁移的稳定性、
    显式 ID（PCG 路径）保留、重复与非法 ID 拒绝、`nextSceneID` 不变量、删除后重新分配不复用旧 ID。

- **T8 实体属性与层级（2026-09-15）**
  - 新模块 `UGCPropertySchema.lua`：白名单键 + 类型校验（number / string / boolean / enum / reference）：
    `mass`(0~10000) / `note`(≤128) / `lit` / `material`(5 值枚举) / `team`(3 值枚举) / `link`(sceneID 引用)；
    `Schema.Coerce` 让 LLM 用字符串传参（`"42"` / `"true"` / `"Metal"`）后仍走同一套校验。
  - `UGCDocument`：`SetProperty` / `RemoveProperty` / `GetProperty` / `ListProperties`（类型与数量上限在模型层再校验一次，
    加载路径同样受约束）+ `SetParent` / `ClearParent` / `GetParent` / `GetChildren` / `IsAncestor`
    （**parentId 是唯一事实来源**，children 由它推导；防自引用与成环）。
  - 命令层（唯一写入边界）：`SetProperty` / `RemoveProperty` / `SetParent` / `ClearParent` 全部带反操作 → Undo/Redo；
    失败码稳定且已登记：`unknown_property` / `invalid_property_value` / `property_limit_reached` / `reference_not_found` /
    `missing_property` / `entity_not_found` / `invalid_parent` / `hierarchy_cycle`。
  - 删除语义：删除父实体时子节点**上移到祖父**（不留悬空 parentId）；`DeleteEntity` 的反操作带回 `children` 列表，
    撤销删除会把层级挂回去（只处理仍指向祖父的子节点，不覆盖用户后续的层级调整）。
  - 门面与 LLM 工具：`SceneData:SetProperty/GetProperty/ListProperties/SetParent/ClearParent/GetParent/GetChildren`；
    注册表新增 `set_property`(write) / `get_property`(read) / `set_parent`(write) / `list_children`(read)，
    `key` 参数直接把 schema 白名单暴露成 enum，模型绕不过校验。
  - Golden：`groups` 场景加入属性与父子关系，样本 `Tools/UGCTests/golden/groups.ugc.json` 同步更新
    （`properties` 由空数组变对象、新增 `parentId`、revision 10→16）。先在不带 `--update` 的情况下确认 golden 报出
    6 处结构差异，确认是有意变化后才更新样本。
  - 回归：`Tools/UGCTests/run_properties.lua`（11 项）。

- **T10 UI ViewModel 化 + 事件驱动刷新（2026-09-15）**
  - 新模块 `UGCViewModel.lua`：通道化刷新（wires / inspector / outline / toolbar），把 SceneData 的 `changed` 事件
    按 kind 映射到通道（未登记的 kind 保守刷新全部通道）；订阅回调逐个 pcall，单个界面刷新异常不影响其它界面。
  - 弱引用与解绑：`BindView` 只存弱引用；订阅若在「有视图」时建立则与该视图同生命周期 —— 视图被回收后
    `GetView()` 返回 nil，且**即使 Destruct 没被调用**，过期订阅也会在下次广播时被剪掉（用 `collectgarbage` 实测）。
    `Destruct` 做 Unsubscribe + UnbindView + DetachSceneData。
  - `UGCSceneData` 补上 `Unsubscribe` / `UnsubscribeAll` / `ListenerCount`（此前 Subscribe 只增不减，
    界面关闭后监听者会一直留着，被引用的 UObject 无法回收）。
  - 接线：`EditorCore:GetViewModel()`（惰性创建并 AttachSceneData）/ `ReleaseViewModel()`（PC `ReceiveEndPlay` 调用）；
    选中变化与状态切换分别标脏 inspector / toolbar；`WBP_UGCEditor` 与 `WBP_UGCBlueprintEditor` 改为在 `Construct`
    里 BindView + Subscribe、在 `Destruct` 里解绑（这两个界面此前都**没有** Destruct，且用的是 EditorCore 的单槽回调）。
  - Tick 只保留必要的输入采样：`UGCPlayerController:ReceiveTick` 先问 `_bpEditor:NeedsWireRefresh()`
    （正在拖连线 / 事件标脏），不需要就跳过，连鼠标位置都不采样；重绘由 ViewModel 的 wires 通道驱动
    （AI 放置、撤销重做、加载项目都会触发）。
  - 回归：`Tools/UGCTests/run_viewmodel.lua`（10 项）：通道语义、订阅广播与异常隔离、真实 SceneData 事件→通道、
    弱引用剪枝、Detach 不影响销毁，以及 4 组接线守卫（UE Widget 不能在纯 Lua 里实例化，
    「Tick 只在需要时重绘」这一条只能靠源码断言锁住）。

- **实跑发现：两处只有跑起来才暴露的运行时断链（2026-09-15，T3 的附带产出）**
  - `Content/Script/Gameplay/UGC/Generators/Init.lua` 用了 8 处 `UGCLog.Info` 却从未 `require` 它（T13 结构化日志改造漏网）。
    运行时 `UGCLog` 全局是 nil → `ExportFunctions` 抛异常 → `UGCFunctionRegistry:RegisterAll` 中断 →
    **整张 LLM 工具注册表在运行时根本起不来**，`ReceiveBeginPlay` 也在那一行断掉。
    纯 Lua 回归抓不到它，因为 `run_properties.lua` 里手动塞了 `UGCLog = require(...)` 全局 stub 把问题盖住了（已删）。
    ps1 新增静态守卫：`Content/Script` 下任何用到 `UGCLog.` 的文件必须 `require` 它。
  - `UGCPrefabRegistry.ListIDs` 在 `05a55fe 重构解耦` 时被删掉，但 `UGCFunctionRegistry.lua:288`（`place_object` 的 enum 来源）
    仍在调它 → 同样让 `RegisterAll` 整体抛异常。已补 `ListIDs`，并在 `run_prefab_definitions.lua` 加「注册表对外调用面」
    回归（扫描 `require("…").X` 调用点并断言函数存在），防止再出现「调不存在的函数」。

- **T3 UE 5.4 编辑器内 PIE 验收（2026-09-15）7/7 通过**
  - 前置（本机、不进版本库）：`Plugins/UnLua/Source/UnLuaEditor/UnLuaEditor.Build.cs` 补 `DeveloperSettings` + `ContentBrowser`
    （此前 14 个未解析符号、`UnrealEditor-UnLuaEditor.dll` 缺失，Editor 目标整体链接失败）。
    另修一个仓库内编译错误：`Source/FPS/UGC/UGCEditorBridge.cpp` 的文件级 helper `GetParentWindowHandle` 与同模块另一 .cpp 同名，
    unity build 下 C2668 → 改名 `GetUGCWindowHandle`。教训：**同模块的文件级 helper 必须带模块前缀**。
  - 驱动链：`Source/FPS/UGC/UGCSmokeTestCommands.cpp`（`UGC.SmokeTestEnable` / `UGC.SmokeTest`，整体 `#if WITH_EDITOR`）
    + `Content/Script/Gameplay/UGC/UGCSmokeTest.lua`（协作式分帧步骤机，7 项断言，结果写 `smoke_item_result` / `smoke_run_summary`）
    + `Tools/UGCTests/run_pie_smoke.py`（起编辑器 → MCP `start_pie` → 轮询 FPS.log → `stop_pie`）。
  - 结果（`smoke_run_summary {passed:7, failed:0}`）：
    1. 创建/移动/删除/Undo/Redo ✓ 投影存在，Undo/Redo 逐级生效
    2. 批量生成与原子回滚 ✓ 失败批次不消耗 sceneID / 无残留 / revision 不变；合法批次 +1 revision 且可撤销
    3. 新旧存档加载 ✓ `project.ugc.json` 往返 2 实体（含 parentId/properties）；旧布局经 `LoadProject(目录)` 迁移加载成功
    4. 图验证 + Delay/Interval ✓ Delay 0.51s 后生效；0.25s 周期在 1.20s 内触发 4 次（日志有 `program_print` 证明图真的执行）
    5. Trigger Router ✓ `OnTriggerZoneEnter` → 图程序改写世界规则
    6. Authoring↔Playtest ✓ `SpectatorPawn_1 → BP_FPSPlayer_C_0 → SpectatorPawn_1`，编辑器窗口随状态开关
    7. AI 提案确认/取消 + 多轮 Tool Loop ✓ 写提案挂起→确认执行→只读提案自动执行→第二个写提案取消且文档不变
  - 写 PIE 自动化脚本本身踩到的坑（已修，供后续参考）：步骤机首帧必须是 `frame == 0`（先自增会导致初始化分支永不执行）；
    SceneData 的 Actor API 必须传**真实 `FTransform`**（`UKismetMathLibrary.MakeTransform`），9 元素表会在引擎侧 `BreakTransform` 报
    "userdata needed but got table"；`UGCEditorCore:EnterPlayMode/EnterEditMode` 会 `CancelAllTasks()`，
    状态被切走时待触发的 Delay/Interval 会被清掉（要重新计时而不是判失败）；`OnTriggerZoneEnter` 是无返回值回调，nil ≠ 失败。

- **T5 Prefab 迁移 `UPrimaryDataAsset` + `AssetManager`（2026-09-15）**
  - C++：`UUGCPrefabDefinition : UPrimaryDataAsset`（ActorClass / DisplayName / Category / Tags / Bounds / Cost / AllowedModes / Version / Kind）；
    `FUGCPrefabCatalog` 统一查询并输出 JSON；桥接层新增 `GetPrefabDefinitionsJson` / `RegisterRuntimePrefabDefinition` / `IsPrefabClassPathAllowed`。
  - 引擎约束（实跑踩到，写进 RISKS）：`AddDynamicAsset` 要求该 PrimaryAssetType **不参与磁盘扫描**（否则内部 ensure `TypeData.Info.bIsDynamicAsset` 并返回 false）
    → 拆成 `UGCPrefab`（磁盘扫描）+ `UGCPrefabRuntime`（纯 dynamic），查询合并为一份目录；
    `GetPrimaryAssetObject` 只返回**已在内存**的对象 → 取定义走 `GetPrimaryAssetPath(id).TryLoad()`。
  - 配置：`Config/DefaultGame.ini` 新增 `[/Script/Engine.AssetManagerSettings]`（`PrimaryAssetType="UGCPrefab"`，扫
    `/Game/_UGC/Prefabs` 与 `/Game/_UGC/Placeables`，`CookRule=AlwaysCook`、`bIsEditorOnly=False`）。
  - 资产：`Content/_UGC/Prefabs/PDA_Prefab_{Box,Sphere,TriggerZone}.uasset`，由无头迁移命令
    `UGC.CreatePrefabDefinitions` 生成（幂等：已存在则回填，可重复执行）。
  - Lua：`UGCPrefabRegistry` 改为 Definition 优先 → Catalog 兜底 → 扫描报警；`UGCPlaceableConfig.lua` 降级为**迁移期兜底**；
    `SpawnPlaceable` 的路径白名单改为「被定义引用 / 动态占位类 / 历史 `/Game/_UGC/Placeables/` 前缀」。
  - 回归：`Tools/UGCTests/run_prefab_definitions.lua`（9 项，含跨模块调用面检查）。

- **T2 蓝图编辑器按钮文案改为「验证」（2026-09-15）**
  - 编辑器内改 `Content/_UGC/UI/WBP_UGCBlueprintEditor.uasset`：`w_btn_compile` 的按钮文本「编译」→「验证」。
    走 UEEditorMCP（`127.0.0.1:55558`）的 `set_widget_text` → `compile_blueprint` → `save_all`，是编辑器内的属性修改，不是字节补丁。
  - **只改模板不重编译会留下旧文本**：改完磁盘上「编译/验证」命中数是 5/0 → 4/1，`compile_blueprint` 之后才是 3/2
    （生成类 CDO 里也变成「验证」）。这类 UMG 文本改动必须跟一次蓝图重编译。
  - Lua 侧本来就一致：`UGCGraphCompiler:FormatReport` 输出「验证成功 / 验证通过，N 个警告 / 验证失败，N 个错误」，
    按钮回调只把它们写进状态栏，没有「编译」字样（资产内另外 3 处「编译」是节点说明文案，与本按钮无关，未动）。

- **T16 Compiler 错误列表 UI + 点击定位（2026-09-15）**
  - 资产（编辑器命令生成，幂等）：`UGC.SetupErrorListUI`（`Source/FPS/UGC/UGCWidgetSetupCommands.cpp`）
    新增 `Content/_UGC/UI/WBP_UGCErrorRow.uasset`（Border 根 + TextBlock；**根必须是 Border**：CanvasPanel 根的控件 desired size 为 0，
    放进 ScrollBox 会不可见），并给 `WBP_UGCBlueprintEditor.uasset` 插入
    `w_error_panel`(SizeBox 高 150，默认 Collapsed) → `w_error_border_bg`(Border) → `w_scroll_errors`(ScrollBox)，
    作为根 VerticalBox 的最后一个 Auto 子项。为什么用命令而不是手摆：该控件的根是 Border，
    UEEditorMCP 那批 `add_*_to_widget` 动作都要求根是 CanvasPanel，用不上。
  - Lua 绑定：行控件的 Lua 方法靠 UnLua，而 `ULuaModuleLocator` 只在类实现了 `UnLuaInterface` 时才解析模块名
    （`Plugins/UnLua/Source/UnLua/Private/LuaModuleLocator.cpp:36`）；蓝图侧实现该接口是 BlueprintNativeEvent（要画事件图），
    因此改成 C++ 基类 `UUGCErrorRowWidget`（`Source/FPS/UGC/UGCErrorRowWidget.h/.cpp`，`GetModuleName` 返回
    `System.UI.UGC.WBP_UGCErrorRow`），命令把行控件重定向到该基类并摘掉蓝图侧那份空实现。
  - 模型层 `Content/Script/Gameplay/UGC/UGCErrorList.lua`（report → 行：错误在前、警告在后、上限 64、overflow 计数、
    nodeId/pin 原样带出、IsFocusable）；UI 层 `WBP_UGCErrorRow.lua`（悬停高亮 + 点击回调，鼠标与脚本共用 `Activate()`）、
    `WBP_UGCBlueprintEditor.lua`（`ShowErrors / ClearErrors / FocusError / RelayoutNodes / HighlightNode /
    ClearFocusHighlight` + 观测入口 `GetFocusTarget / GetErrorRowCount / GetErrorRowWidget / GetNodeCanvasPosition`）；
    `WBP_UGCNode.lua` 与 `WBP_UGCNodePinRow.lua` 各加 `SetHighlight`。
  - 回归：`Tools/UGCTests/run_error_list.lua`（8 项，含接线与资产守卫）+ `run_tests.ps1` 的 T16 守卫
    （Lua 里必须有 `w_scroll_errors`/`w_error_panel`/行控件类路径/`FocusError`，资产里必须能找到三个面板控件名）。
  - PIE 验收（冒烟第 8 项，**8/8 通过**）：`smoke_item_result item=8 detail="验证列出 6 行（验证前 0 行）；点击第 1 行定位到 node_1，
    节点视图 (60,40) -> (808,391)"`；复现 `python Tools/UGCTests/run_pie_smoke.py`。
  - 实跑踩到的坑（已写进代码注释）：
    1. 控件「创建」与「构造」是两个时机 —— `Create` 之后要 `AddChild` 进可见树才会调 `Construct`，
       在 `Construct` 里重置 `SetErrorRow` 写入的数据会导致「列表显示正常但 `GetErrorRow()` 全是 nil」。
    2. `FGeometry` 的方法不能从 Lua 调（`geo:GetLocalSize()` → `method is not callable`），走
       `UE.USlateBlueprintLibrary.GetLocalSize(geo)`。
    3. 冒烟必须在带 `AUGCPlayerController` 的世界里跑：新增 `UGC.SmokeTestOpenUGCLevel`
       （`UEditorLoadingAndSavingUtils::LoadMap`），driver 起编辑器时带上；否则 PIE 只在登录地图里跑，`smoke_*` 一条都不会出现
       （之前那次 7/7 是先在游戏里手动选图开主机才进到 UGC 关卡的）。
  - 附带修掉一个真崩溃（详见 RISKS_AND_GAPS.md）：`FUGCPrefabCatalog::RuntimeDefinitions` 静态容器存裸 `TObjectPtr` →
    GC 后悬垂 → PIE 启动时 `EXCEPTION_ACCESS_VIOLATION`。改为 `TStrongObjectPtr`。
