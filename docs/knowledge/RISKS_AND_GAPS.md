# 风险、断链与未完成项

> 这是“导航和验证清单”，不是已修复列表。修改前先重新确认对应 Blueprint Defaults/关卡配置。

## P0/P1：优先确认

### 1. PlayerState 上的 AttributeSet 死亡状态可能无法跨重生复位

- `UFPSCombatAttributeSet::bDead` 在死亡后置 true。
- ASC/AttributeSet 位于持久化的 PlayerState。
- `AFPSGameMode::RespawnPlayer` 重新生成 Pawn。
- `AFPSCharacter::ResetForRespawn` 只重置 Character 的 `bDead`，没有重置 AttributeSet 私有 `bDead`。

风险：首次死亡后，新 Pawn 仍使用旧 AttributeSet，后续伤害/治疗和死亡事件可能失效。建议为 AttributeSet 提供显式 Reset，并定义重生时 Ability/Effect 的清理策略。

### 2. 重生可能重复授予默认能力/效果

新 Character 每次 `InitializeAbilitySystem` 都会向 PlayerState ASC 授予 `DefaultAbilities` 和应用 `DefaultEffects`。如果旧能力/效果未清理，会重复叠加。

### 3. 武器弹药和状态没有复制

`AFPSWeaponBase` 复制 Actor 和 `InstalledAttachmentIDs`，但 `AmmoInfo`、`CurrentState` 未复制。客户端预测会本地扣弹，服务端也扣弹，但没有权威校正/OnRep。

风险：丢包、拒绝 RPC、延迟或 Reload 时可能出现 HUD 与服务端不同步。

### 4. 双护甲模型可能重复减伤

- Projectile Lua 按 `UFPSArmorComponent` 的 ArmorLevel/Durability 计算肉伤和甲伤。
- `UFPSCombatAttributeSet::HandleDamage` 又按 GAS `Armor` 与 `ArmorReduction` 吸收伤害。

若两套 Armor 同时有值，伤害可能二次减免。应明确一个模型负责“穿透与耐久”，另一个是否仍代表可消耗护盾。

### 5. UGC Authoring / Playtest 生命周期（已完成基础拆分，待 PIE）

- `AUGCGameMode` 已改为直接继承 `AGameModeBase`，不再进入 PVP 分队、比赛计时和复活流程。
- Authoring 默认使用 SpectatorPawn；进入 Play 时 `AUGCPlayerController` 生成并 Possess `BP_FPSPlayer`，返回 Edit 时恢复 Authoring Pawn。
- `PlayerStateClass` 显式保留 `AFPSPlayerState`，使 Playtest Pawn 可获得 ASC/AttributeSet。
- 仍需 UE 5.4 PIE 验证输入映射、摄像机位置、重复切换与 GAS 默认能力/Effect 是否出现累加。

## P1：资产和运行路径断链

机器检查发现以下硬编码引用在仓库中不存在：

- C++ GameMode fallback Pawn：`/Game/FirstPerson/Blueprints/BP_FirstPersonCharacter`
- PlayerController 返回菜单：`/Game/_FPS/Level/Level_MainMenu`
- C++ MenuSubsystem 配置：`/Game/_FPS/Data/DA_MenuConfig`
- Lua UI：`/Game/_FPS/System/UI/WBP_HUD`
- Lua UI：`/Game/_FPS/System/UI/Menu/WBP_Loadout`
- GM 调试武器：`/Game/_FPS/Blueprints/Weapons/BP_Rifle`
- GM 调试手枪：`/Game/_FPS/Blueprints/Weapons/BP_Pistol`
- UGC Placeable：Cylinder、Ramp、SpawnPoint、Extraction、WeaponSpawn

补充：

- 实际主菜单地图文件是 `.../Level_MainMenu/Level_LoginMap.umap`。
- 实际玩家 Blueprint 是 `Content/_FPS/Blueprints/BP_FPSPlayer.uasset`。
- `BP_FPSGameMode` 很可能在 Blueprint Defaults 覆盖了 C++ fallback，但未在线读取 CDO 验证。

### 6. UI 有两套独立状态栈

- C++：`UFPSMenuSubsystem`
- Lua：`Gameplay.Core.UIManager`

当前 Blueprint/Lua 绑定显示主要运行路径是 Lua UIManager；C++ Widget 默认动作却会调用 MenuSubsystem。两边各自持有打开窗口、栈和输入模式，可能造成状态不一致。

### 7. 后坐力有两套并行实现

- `UGA_WeaponFire` 每发推进 `UFPSRecoilComponent`。
- `AFPSWeaponBase::Fire` 又调用可被 Lua 覆盖的 `OnShotFired`。
- `BP_WeaponBase.lua` 用自己的 `_PatternIndex` 和 JSON 计算实际方向。
- HUD 展示读取 C++ `RecoilComponent.CurrentSpread`。

风险：准星显示与实际弹道不一致；配置来源分裂为 RecoilProfile 与 JSON。

### 8. 配件复制未完成重建

`OnRep_InstalledAttachments` 只清空 `CachedAttachmentData`，注释说应通过 AssetManager 重建，但未实现。因此客户端：

- `GetAttachment` 返回空；
- 有效伤害/装弹时间/弹匣容量无法从复制 ID 恢复；
- 配件 Mesh 展示逻辑也未见实现。

### 9. 击杀/助攻归因需联网实测

AttributeSet 使用 `EffectContext.GetEffectCauser()` 并要求可转为 `AFPSCharacter`；Projectile 创建上下文时只显式 `AddSourceObject(this)`。需验证 EffectCauser 在当前 GAS 路径是否确实为攻击者 Character，否则 DamageDealt、助攻和 Killer 可能为空。

## P2：UGC 数据一致性

以下原问题已在 2026-09-10 的兼容式重构中处理：

- PCG external entity 使用稳定 SceneID/EntityId，并通过 external adapter 支持恢复、清理、Undo/Redo。
- 删除实体会保留并恢复 Program 与 GeneratedGroup 归属。
- Ability/Weapon/Attribute/Rule/PCG Graph 改用共享 allowlist；AI 不再接受任意 Ability 或 PCG 资产路径。
- API Key 改从 `FPS_UGC_LLM_API_KEY` 环境变量读取；Blueprint 中检测到的旧 key-like 值已抹除，旧凭据仍必须在供应商侧吊销/轮换。
- `UUGCFunctionBridge::ExecuteFunction` 假入口已删除；Delay/Interval 改为真实 DeltaTime Scheduler。
- Runtime UGC Lua 路径已移除 `io.open`、`os.execute` 和 `collectgarbage`；JSON IO 统一经 `UUGCStorageBridge`。

仍需关注：

- `UGCPlaceableConfig.lua` 目前是过渡性打包 Catalog；最终仍建议迁移为 `UPrimaryDataAsset + AssetManager`。
- AI 多写 Tool Call 当前被拒绝，要求模型改用单个原子生成器；未来若需任意多命令提案，应增加统一 Proposal -> CompositeCommand 翻译层。
- Document/Command/Compiler 已有纯 Lua 回归，但完整加载、PCG、Trigger Router 与 Authoring/Playtest 仍需 UE 5.4 PIE 验证。

### 15. Android File Server SecurityToken 已提交

`Config/DefaultEngine.ini` 包含 `SecurityToken`。即使只是本地开发令牌，也应确认是否需要轮换或移出共享配置。

## P2/P3：功能未完成或漂移

- `AFPSGameMode::OnPlayerExtracted` 仅日志，Raid 完成/保存/结算未接通。
- MenuSubsystem 设置保存/加载、音频设置、主菜单关卡跳转未完成。
- Settings 的按键读取、应用、重置未完成。
- Inventory C++ 网格线绘制未完成。
- ContextMenu 的 Use/Equip/Drop/Split 多处仍是 TODO。
- `UPlayerInteractComponent` 的 Line/Cone 模式未实现。
- Wwise 事件名多为占位，Events Work Unit 基本为空。
- `Web` 插件为空壳且未启用。
- `README.pdf` 记载 `MinPlayersToStart=2`，代码当前为 1。
- `SourceData/Items.csv` 中文编码异常，`Output/CSV/DT_ItemDefinition.csv` 正常。
- C++ Native GameplayTags 与 INI 同时声明，存在双维护漂移。
- 仓库包含大量重复迁移素材与 StarterContent，搜索时容易命中错误副本。

## 构建与运行时依赖（T19 验证记录，2026-09-14 / 2026-09-18）

2026-09-14 的探针用的是当时本机唯一的 UE 5.7（项目目标 5.4）+ 临时补丁；2026-09-18 起本机已装
UE 5.4.4（`E:\Engine\UE_5.4`，自带 .NET 6，Installed Build 且带 DebugGame/Development/Shipping
三套 UnrealGame 中间产物），因此当天的 Shipping 验证直接在项目目标版本上完成。

### 已修复

- `Source/FPS/Inventory/Private/InventoryGridComponent.cpp` 曾 `#include "IDetailTreeNode.h"`（Editor-only，且全文件未使用）。这一行会让 **Shipping/Game 目标直接编译失败**（`fatal error C1083`），已删除并就地留注释。这是本轮 Shipping 探针抓到的真实缺陷。
- `Tools/UGCTests/run_tests.ps1` 增加守卫：编辑器专用 include/符号（DesktopPlatform、IDetailTreeNode、PropertyEditor、UnrealEd、GEditor 等）必须位于 `#if WITH_EDITOR` 内；`FPS.Build.cs` 必须把 DesktopPlatform 放在 `Target.bBuildEditor` 后面。

### 依赖瘦身（FPS.Build.cs）

- `HTTP` / `Json` / `PCG` 只在 `UGCHttpClient.cpp`、`UGCPCGBridge.cpp` 内部使用 → 从 Public 移到 Private。
- 移除 `Niagara`（全模块零符号引用）；`ApplicationCore` 在 2026-09-14 时无直接引用被移除，但 2026-09-18
  因合并进来的 `UGCPlayerController::CopyToClipboard`（`FPlatformApplicationMisc::ClipboardCopy`）**必须恢复**为
  Private 依赖——模块化编辑器构建缺它会 `LNK2019`，而单体 Shipping 构建不会暴露该问题。
- `DesktopPlatform` 保持 editor-only；`AIModule` 必须保留（`FPSCharacter.h` 暴露 `IGenericTeamAgentInterface`，该头位于 AIModule）。
- 更深一层的"Runtime Core 只依赖 Core/CoreUObject/Engine"需要 T11 拆插件才能达成。

### 探针结果（UE 5.7，非项目目标版本）

- 通过：UBT 解析全部模块规则与 UHT 全量头文件解析；新增 `Source/FPS/UGC/UGCLog.cpp` 在 **Shipping** 配置下单文件编译成功（`-SingleFile`）。
- 阻塞（第三方，非本项目代码）：`Plugins/UnLua/Source/UnLua/Private/DefaultParamCollection.cpp` 依赖 UBT 插件生成的 `DefaultParamCollection.inl`；该插件是 net6.0，UE 5.7 的 UBT 只接受 net8.0，把它重定向到 net8.0 后又因 UHT API 变更（`UhtSession.Packages`、`UhtModule.ModuleType/Name/OutputDirectory` 已移除）编译失败。结论：**UE 5.7 下无法完整构建，与项目代码无关；最终 Shipping 验证必须在 UE 5.4 环境执行（并需要在该机器上装 .NET SDK）。**
- 探针用的临时改动（`FPS.uproject` 引擎关联、`FPS.Target.cs` 的 `bOverrideBuildEnvironment`、`UnLuaSettings.h` 的 `MetaClass`、UnLua collector 的 TFM）均已逐字节还原（SHA256 已校验）。

### Shipping 构建验证（UE 5.4.4，2026-09-18，已完成）

- 命令：`Build.bat FPS Win64 Shipping -project=F:\github\FPS\FPS.uproject`（UE 5.4.4，`E:\Engine\UE_5.4`）。
- 结果：**BUILD_EXIT=0**，109 个动作 / 67.7 秒；产出 `Binaries/Win64/FPS-Win64-Shipping.exe`（147 MB，含 `.lib`/`.exp`/`.pdb`）。
- 同一天 `FPSEditor Win64 Development` 亦构建通过，说明新依赖表在编辑器配置下同样成立。
- 仅第三方警告：`Plugins/UnLuaExtensions/LuaSocket` 的 `gai_strerror` 宏重定义（无害）。
- 结论：T19 里「最终 Shipping 验证必须在 UE 5.4 环境执行」的要求已满足，且这是在**项目 + 全部启用插件**上的完整 Shipping 编译，不是单文件探针。

## 合并事故与修复（`5553fd8`，2026-09-18 修复）

> 记录原因：这次坏的是「载入即失败」的语法错误，任何一次跑 `Tools/UGCTests/run_tests.ps1` 都能立刻发现，
> 但合并后两天没人跑——所以既记事实，也记流程守则。

### 事实

`5553fd8 Merge branch 'develop' into develop`（2026-09-14）把 06-04 老分支（`5ea02040`）的特性
并进重构后的树时，在 `Content/Script/Gameplay/UGC/UGCSceneData.lua` 上采用了「保留双方」式冲突处理：

- 老分支片段被整段覆盖到重构版函数上：`DeleteEntity` 命令处理器、`GetWorldRule`、`Clear`、`Init`；
- 只存在于重构版的函数直接丢失：`IsDirty` / `MarkDirty` / `ClearDirty`、`dataToTransform` / `transformToData`；
- 老版头部状态块（`_actors` / `_batches` / 强制 `collectgarbage` / 裸 `print`）被粘回文件；
- `DeserializePackageTable` 尾部与老代码缝合，形成 **Lua 语法错误**（`'end' expected ... near 'elseif'`，行 857）。
  该文件被 7 个模块 require（`UGCPlayerController`、`UGCEditorCore`、`UGCFunctionRegistry`、`UGCProgramRunner`、
  `Generators/Init`、`WBP_UGCEditor`、`WBP_UGCBlueprintEditor`）——即整个 UGC 运行时编辑器在 Lua 5.4 下不可用。

同一次合并还回退/引入了另外三类问题：4 处 `require("Gameplay.UGC.json")`（T1 已删除的模块）、
7 处裸 `print`（T13 禁止）、`FPS.Build.cs` 回退到 T19 之前的形态、`AnimGenClient.cpp` 的
DesktopPlatform 在 `#if WITH_EDITOR` 之外。

### 修复（已验证）

- 以重构版 `368cefb` 为基准重建 `UGCSceneData.lua`，只补回调用方真正在用的 4 个老分支 API，并把它们落到
  重构架构上：`BeginNamedBatch` / `EndActiveBatch` / `GetActiveBatch` 走 `Document:CreateGroup/AddToGroup`
  （具名 batch 因此可存档往返）；`SetActorCreatedHook` 接进 `CreateEntity` / `RestoreEntity` /
  `DeserializePackageTable` 三条 spawn 路径（dyn GLB 注入在创建、Undo/Redo、读档全流程生效）。
  相对 `368cefb` 净改动 **+50 行 / 0 删除**。
- 同源修复：4 处 `require("Gameplay.UGC.json")` → `require("Util.json")`（`Generators/Init.lua`×2、
  `AnimAgentCore.lua`、`AnimAssetLibrary.lua`）；7 处裸 `print` → `UGCLog`（`UGCEditorCore.lua`×3、
  `UGCPrefabRegistry.lua`×2、`Generators/Init.lua`×2）；`FPS.Build.cs` 恢复 T19 形态（HTTP/Json/PCG → Private，
  去掉 Niagara，DesktopPlatform 收进 `Target.bBuildEditor`；`ApplicationCore` 因合并进来的剪贴板调用必须保留为
  Private，见上「依赖瘦身」）；`AnimGenClient.cpp` 的 DesktopPlatform 包进 `#if WITH_EDITOR`，非编辑器返回空并告警。
- 验证：`run_tests.ps1` 退出码 0（5 道静态守卫 + Lua 回归 run 8/8、run_scene 7/7、run_serialization 7/7、
  run_registry、run_logging 7/7、run_llm_gateway、run_persistence 全通过）；全仓 Lua 无重复顶层定义；
  `UGCSceneData` 的 32 个外部调用方法 0 缺失；UE 5.4.4 下 Editor Development 与 Shipping 均构建通过。

### 流程守则

1. **合并后立刻跑一次 `Tools/UGCTests/run_tests.ps1`**，把「语法扫描 + 静态守卫 + Lua 回归」当作合并的最低闸门。
2. 冲突解决**不允许「两边都留」**：同一函数出现两份实现时，按重构后的架构裁决（Document / CommandBus /
   Projection 是唯一事实源），而不是把老实现粘回去。
3. 大规模冲突后先做语法扫描（`check_syntax.lua` 覆盖 `Content/Script` 全量），再做行为回归；重复定义可用
   「顶层 `function X:Y` 名称去重」快速自检。

## 验证缺口

本次未启动 Unreal Editor，UEEditorMCP 55558 端口不可连接，因此以下内容仍需编辑器内验证：

- Blueprint 的实际父类、CDO 默认属性与组件引用。
- 各地图 World Settings/GameMode Override。
- DataTable 的实际行值。
- Widget Designer 中 BindWidget 名称完整性。
- Blueprint 编译状态和资源重定向器。
- PIE 双客户端的 RPC、复制、重生和 UI 状态。
