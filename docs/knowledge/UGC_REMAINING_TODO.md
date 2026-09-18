# UGC 整改剩余待办（可挑选执行）

> 来源：`docs/knowledge/UGC_ARCHITECTURE_REVIEW_2026-09-10.md` 的 Phase 0-5、第 9/10 节，对照 2026-09-14 代码复核后的缺口清单。
> 状态基线：整体执行度约 64%；Phase 1（85%）与 Phase 3（95%）骨架已成立。
> 用法：按 ID 点单即可，例如「做 T5」。每项都写了目标、验收标准和依赖，避免做完无法判定。

## 快速选择建议

- **已完成**：T1（序列化收敛）、T13（结构化日志）、T18（死代码清理）、T19（依赖瘦身 + UE 5.4.4 Shipping 构建验证）
- **低成本对齐（半天内）**：T2（需编辑器）
- **产品化主干**：T3、T5、T10、T6
- **多人方向**（需先定目标）：T7、T12
- **长尾治理**：T8、T9、T11、T14、T15、T16、T17

## 待办清单

### ~~T1 序列化收敛：3 份 JSON 实现收敛为 1 份~~ ✅ 已完成
- 优先级：P0 ｜ 规模：S ｜ 依赖：无
- 目标：`Util/json.lua`、`Gameplay/UGC/json.lua`、`UGCSerialize.lua` 收敛为单一实现，文档持久化只保留一个经测试的编解码器。
- 验收：仓库只剩 1 个 JSON 模块；新格式 `project.ugc.json` 与旧 `scene.json + programs.json` 都经该实现读写并有回归测试；`json.lua` 对 NaN/Inf 输出合法 JSON。
- 状态：**已完成（2026-09-14）**，验收全部满足；详见「已执行记录」。

### T2 蓝图编辑器「编译」按钮改名「验证」
- 优先级：P1 ｜ 规模：XS ｜ 依赖：UE 5.4 编辑器
- 目标：按钮文案与按钮语义一致（当前按钮只做校验，产出 IR 的是 Runner）。
- 验收：`WBP_UGCBlueprintEditor` 中按钮显示「验证」；Lua 侧状态文案一致。
- 备注：改动在 `.uasset` 内，必须编辑器内改名（字节级已确认资产仍为 UTF-16「编译」）。

### T3 UE 5.4 编辑器内 PIE 验收
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
- 备注：这是当前最高价值项，代码改动只有跑过才算数。

### T4 Golden Scene 与序列化 Golden 回归
- 优先级：P1 ｜ 规模：M ｜ 依赖：T1
- 目标：把「存档不漂移」变成可自动判定的回归，而不是靠人工看。
- 验收：仓库内 3 个 Golden 场景样本（含 external/PCG、Group、Program）；CI 或脚本可比对序列化输出差异并给出定位。

### T5 Prefab 迁移 `UPrimaryDataAsset` + `AssetManager`
- 优先级：P1 ｜ 规模：L ｜ 依赖：无
- 目标：替换 Lua 硬编码 Catalog，使 Prefab 定义可被资产化、可被 AssetManager 扫描、可在 Shipping 生效。
- 验收：`UUGCPrefabDefinition : UPrimaryDataAsset`；ID 用 `FPrimaryAssetId`；Definition 含 ActorClass / DisplayName / Category / Tags / Bounds / Cost / AllowedModes / Version；`UGCPlaceableConfig.lua` 退化为迁移期兼容或删除。

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

### T8 实体属性与层级（SetProperty + parent/children + Typed Property Bag）
- 优先级：P2 ｜ 规模：M ｜ 依赖：无
- 目标：Document 的 `properties` 目前只被搬运、无命令写入；缺少层级表达。
- 验收：`SetProperty` 命令（可 Undo/Redo）；`parentId/children` 或等价层级字段；属性带类型校验（数值/字符串/枚举/引用）。

### T9 entityId 收敛为 FGuid（或明确保留字符串）
- 优先级：P2 ｜ 规模：S ｜ 依赖：无
- 目标：方案要求 `Guid` EntityId；当前为字符串（`docId-entity-N`）。
- 验收：要么改为 Guid 并保证存档/PCG/网络稳定；要么在文档中记录「字符串 ID 为最终设计」的理由与约束。

### T10 UI ViewModel 化 + 事件驱动刷新
- 优先级：P1 ｜ 规模：L ｜ 依赖：无
- 目标：UI 仍由 PlayerController 的 Tick 驱动（`ReceiveTick → UpdateWires`），未引入 ViewModel / Subsystem。
- 验收：图编辑器与编辑面板改为事件驱动刷新；Tick 只保留必要的输入采样；ViewModel 持弱引用并在 Destruct 解绑。

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

### T15 显式迁移链 V1 → V2 → V3
- 优先级：P2 ｜ 规模：M ｜ 依赖：T14
- 目标：当前只有「旧格式只读兼容」，没有版本化迁移链与迁移测试。
- 验收：每级迁移有独立函数与样本文件；迁移失败可回滚且不损坏原文件。

### T16 Compiler 错误列表 UI
- 优先级：P3 ｜ 规模：S ｜ 依赖：无
- 目标：Compiler 已返回 `nodeId` / `pin`，但 UI 只展示首条错误。
- 验收：可滚动错误列表；点击定位到节点与引脚。

### T17 编解码统一到单一实现（含武器弹道 JSON）
- 优先级：P3 ｜ 规模：M ｜ 依赖：T1
- 目标：`BP_WeaponBase.lua` 仍用 `rapidjson` 读弹道配置，与 UGC 编解码不一致。
- 验收：明确「谁负责哪类 JSON」，或统一到单一编解码路径；配置格式有 schema 与校验。

### ~~T18 移除死代码：`EditorCore:SaveSceneJSON / LoadSceneJSON`~~ ✅ 已完成
- 优先级：P3 ｜ 规模：XS ｜ 依赖：T1
- 目标：这两个包装函数无任何调用点（旧三文件存档路径已迁到 Persistence）。
- 验收：删除或标注 deprecated；`SceneData` 旧序列化入口收敛为「仅加载兼容」。
- 状态：**已完成（2026-09-14）**；详见「已执行记录」。

### ~~T19 Runtime 依赖瘦身 + Shipping 构建验证~~ ✅ 已完成
- 优先级：P2 ｜ 规模：L ｜ 依赖：T11
- 目标：`FPS.Build.cs` 的 Runtime 依赖仍含 UMG/Slate/HTTP/PCG。
- 验收：至少完成一次 Shipping 目标构建验证；Runtime Core 不依赖 DesktopPlatform 与裸磁盘资产扫描。
- 状态：**已完成（2026-09-18）**。依赖与守卫在 09-14 落地；09-18 在 UE 5.4.4（`E:\Engine\UE_5.4`）上完成
  `FPS Win64 Shipping` 完整构建（BUILD_EXIT=0，产出 `FPS-Win64-Shipping.exe` 147 MB），并同步修复了
  09-14 合并回退的 `FPS.Build.cs` 形态与 `AnimGenClient.cpp` 的编辑器守卫。详见「已执行记录」与
  `RISKS_AND_GAPS.md` 的「Shipping 构建验证」一节。

## 已执行记录

- **合并损伤修复 + T19 Shipping 验证（2026-09-18）**
  - 背景：`5553fd8`（2026-09-14）的冲突处理把老分支片段整段覆盖到重构版 `UGCSceneData.lua` 上，产生 Lua 语法错误，
    UGC 运行时编辑器在 Lua 5.4 下不可用；事实与流程守则见 `RISKS_AND_GAPS.md` 的「合并事故与修复」。
  - 修复范围：`UGCSceneData.lua` 按重构基准 `368cefb` 重建（相对基准 +50/−0，补回调用方仍需的 4 个老 API，
    并把具名 batch 与 spawn 钩子接到 Document/spawn 路径上）；4 处 `Gameplay.UGC.json` 引用改回 `Util.json`；
    7 处裸 `print` 改走 `UGCLog`；`FPS.Build.cs` 恢复 T19 依赖形态（Niagara 移除、ApplicationCore 因剪贴板调用保留为 Private）；
    `AnimGenClient.cpp` 的 DesktopPlatform 加编辑器守卫。
  - 验证：`run_tests.ps1` 退出码 0（5 道静态守卫 + Lua 回归全过）；UE 5.4.4 下 `FPSEditor Win64 Development`
    与 `FPS Win64 Shipping` 均构建通过（Shipping 产出 `FPS-Win64-Shipping.exe` 147 MB）。
  - 未完成：编辑器内 PIE/Blueprint/存档往返验证仍属 T3 范围。

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
  - 静态守卫：编辑器专用 include/符号必须位于 `#if WITH_EDITOR` 内；`FPS.Build.cs` 必须保留 `Target.bBuildEditor` 且不得重新引入 Niagara/ApplicationCore。
  - Shipping 探针（UE 5.7 + 临时补丁）抓到并修复真实缺陷：`InventoryGridComponent.cpp` 误引 Editor-only 的 `IDetailTreeNode.h`（未使用）导致 `fatal error C1083`。
  - 验证情况：新增 `UGCLog.cpp` 在 Shipping 配置下单文件编译通过；完整 Shipping 构建被 UnLua 5.7 不兼容阻塞（net6 UBT 插件 + UHT API 变更），**需在 UE 5.4 环境复验**；细节见 `RISKS_AND_GAPS.md`。
  - 所有探针临时改动已逐字节还原（SHA256 校验通过）。