# 风险、断链与未完成项

## 2026-09-15 T16 实跑抓到的问题（含一个真崩溃，已修）

- **Prefab Catalog 静态容器里的 GC 悬垂指针（已修，崩过一次）**：`FUGCPrefabCatalog::RuntimeDefinitions` 原先是
  `static TMap<FName, TObjectPtr<UUGCPrefabDefinition>>`，装的是 `NewObject(GetTransientPackage(), RF_Transient)` 出来的定义。
  静态容器不在 GC 引用图里（不是 UPROPERTY），一次 GC 之后指针就悬垂，`GetDefinitions()` 的运行时定义循环直接
  `EXCEPTION_ACCESS_VIOLATION`。minidump 调用栈：
  `UUGCPrefabDefinition::ToPlaceableInfo ← FUGCPrefabCatalog::GetDefinitions ← UUGCEditorBridge::GetPrefabDefinitionsJson
  ← UnLua FFunctionDesc::CallUE ← UGCPrefabRegistry.definitionsFromBridge ← UGCEditorCore:Init ← UGCPlayerController.ReceiveBeginPlay`。
  修法：容器类型改 `TStrongObjectPtr`（头文件里写了原因）。**教训：任何不在 UPROPERTY 里的 UObject 容器都必须用强引用包装。**
  修完之后 warm-up PIE + 8 项冒烟各跑一遍无复现；此前同一症状表现为「首个 PIE 偶发崩编辑器 / prefab 定义取不到」。

- **UnLua 绑定前提**：新建的控件蓝图要被 Lua 用，必须在类上实现 `UnLuaInterface::GetModuleName`
  （`ULuaModuleLocator` 只看 CDO 有没有实现接口）。蓝图侧实现是 BlueprintNativeEvent（要画事件图），
  项目的做法是给控件一个实现接口的 C++ 基类（例：`UUGCErrorRowWidget`）。

- **FGeometry 方法不可从 Lua 直接调用**：`GetCachedGeometry()` 返回的是结构体，`geo:GetLocalSize()` 会报
  `method 'GetLocalSize' is not callable`；用 `UE.USlateBlueprintLibrary.GetLocalSize(geo)`。

- **控件「创建」与「构造」是两个时机**：`UWidgetBlueprintLibrary.Create` 之后，直到 `AddChild` 进可见树才会调 `Construct`。
  在 `Construct` 里重置 `SetXxx` 写入的数据 → UI 看起来正常，但点击回调/取数据全是 nil。

- **PIE 冒烟必须在 UGC 关卡里跑**：冒烟驱动挂在 `AUGCPlayerController` 上，编辑器默认打开的登录地图只有菜单 PC，
  PIE 起来后 `smoke_*` 一条都不会出现。已加 `UGC.SmokeTestOpenUGCLevel`（`UEditorLoadingAndSavingUtils::LoadMap`），
  `run_pie_smoke.py` 起编辑器时带上它。

- **run_tests.ps1 的 Shipping 守卫误报**：`$EditorOnlySymbols` 里的 `GEditor\b` 会命中 Build.cs 里合法的依赖名
  `"UMGEditor"`；已改成 `\bGEditor\b`（左侧也要词边界）。

> 这是“导航和验证清单”，不是已修复列表。修改前先重新确认对应 Blueprint Defaults/关卡配置。

## 2026-09-14 合并损伤与修复（已修复，回归全绿）

`5553fd8 "Merge branch 'develop' into develop"` 把「新架构侧（`368cefb`：Document + CommandBus + Projection，含 T18 死代码清理）」
和「Anim/Fab 侧（`5ea0204`：UGC 适配 AnimAgent）」合成了一个**新旧两份实现互相拼接**的结果，不是一次正常的三方合并。

### 症状（修复前实测）

- `Content/Script/Gameplay/UGC/UGCSceneData.lua` 在 `857` 行留下旧实现的片段，Lua 5.4 直接语法失败
  （`'end' expected (to close 'function' at line 831) near 'elseif'`）；`run_tests.ps1` 的语法门是全仓第一道，
  因此整个 Lua 回归在这之前就跑不到。
- 该文件同时丢掉新架构的函数：`GetWorldRule`（`UGCFunctionRegistry` 与两个回归脚本都在调用）、
  `IsDirty/MarkDirty/ClearDirty`（`UGCPersistence` 调用 `ClearDirty`）、`DeleteEntity` 命令注册、世界规则恢复循环。
- `Source/FPS/FPS.Build.cs` 被回退成 T19 之前的样子（`Niagara`/`ApplicationCore`/`DesktopPlatform` 回 Public、无 `Target.bBuildEditor`）。
- T1/T13 的补漏没有覆盖 Anim/Fab 侧的新文件：仍有 4 处 `require("Gameplay.UGC.json")`、10 处裸 `print`。

按 UGC 作用域（`Content/Script` + `Source/FPS/UGC` + `Tools/UGCTests`，91 个文件）比对两个合并父提交：
45 个文件来自新架构侧、10 个来自 Anim 侧、12 个三方都不同（Anim/Fab 新文件 + 合并产物）。

### 修复（2026-09-14）

- `UGCSceneData.lua` 以新架构版本重建，并把 Anim 侧**真正新增**的 4 个 API 补回新架构上：
  `SetActorCreatedHook`（调用方 `UGCEditorCore`）、`BeginNamedBatch`/`EndActiveBatch`（`UGCFunctionRegistry`）、
  `GetActiveBatch`（`Generators/Init`）。这 4 个是合并里唯一值得保留的增量，其余差异全部是旧架构代码。
- `UGCWorldProjection` 增加 `onSpawn` 钩子（`New(bridge, onSpawn)`），`Spawn`/`AttachExternal` 成功后回调；
  这样 `SetActorCreatedHook` 覆盖创建、Undo/Redo、加载、外部接管全部路径。
- T1 补漏：`AnimAgentCore.lua`、`AnimAssetLibrary.lua`、`Generators/Init.lua` 共 4 处改用 `Util.json`。
- T19 补漏：`AnimAgent/AnimGen/AnimGenClient.cpp` 的 `DesktopPlatformModule.h`/`IDesktopPlatform.h` 与两个
  文件对话框实现（连同 `GetParentWindowHandle`）收进 `#if WITH_EDITOR`，Shipping 记录警告并返回空；
  `FPS.Build.cs` 恢复 T19 布局并新增 `glTFRuntime`（仅 `AnimImportBridge.cpp` 使用，故为 Private）。
  **与 T19 记录的一处修正**：`HTTP` 保留在 Public —— `UGC/UGCHttpClient.h` 与 `AnimAgent/Fab/FabClientBridge.h`
  是本模块公开头且都 `include "Interfaces/IHttpRequest.h"`，实际不是「只在 .cpp 内使用」。
- T13 补漏：`UGCEditorCore`、`UGCPrefabRegistry`、`Generators/Init` 共 10 处裸 `print` 改为 `UGCLog`。

### 验证

`Tools/UGCTests/run_tests.ps1` 全绿：59 个 Lua 文件语法 + 5 组静态守卫（序列化收敛 / 死代码 / Shipping 安全 /
依赖 / 日志与 code 白名单）+ 32 项 Lua 回归（8 + 7 + 7 + 7 + 1 + 1 + 1）。此外对全仓做了「别名跨模块调用」
静态检查（`local X = require(...)` 后调用的方法必须在目标模块里存在）：0 处悬空调用。

### 已知语义缺口（本轮未改，仅记录）

- `begin_batch` 的语义是「预开一个 group ID 供生成器复用」，**不是**「之后所有原子写操作自动入组」；
  LLM 工具描述里写的「后续调用都会归到此 batch」与实现不一致（合并前的两份实现同样如此）。
  若要让原子写操作自动入组，应在 `ExecuteCommand` 里把 `_activeBatch` 注入 `command.groups`。

## 2026-09-15 T8/T9/T10/T17 的已知边界（本次交付明确不做的事）

- 旧 `scene.json` 兼容层**不携带** `properties` / `parentId`：`SceneData:SerializeToJSON` 的字段集是历史格式（T1/T4 的回归锁定了它）。
  影响：把新文档导出成旧格式再导回来会丢属性与层级。运行时存档走 `*.ugc.json` 包，不受影响；要保留属性必须走 package 路径。
- 弹道配置没有热重载：`BP_WeaponBase` 首次访问读一次并缓存（`BallisticsCache`），改 JSON 需要重启 / 重开 PIE。
- 属性 schema 是白名单式的 6 个键，`UGCPropertySchema.MAX_PROPERTIES = 16` 在只有 6 个键时不可能自然触发 ——
  它是给后续扩键留的守卫，回归测试通过临时下调上限来覆盖 `property_limit_reached` 分支。
- `EditorCore:OnSelectionChanged / OnStateChanged` 保留为 `@deprecated` 单槽 API（仓库内已无调用者）：新界面应订阅 ViewModel 通道。
- UI 的运行时行为（PIE 里连线重绘是否正常、UnLua 是否真的调用 `Destruct`）**未在编辑器内验证** —— 本机 Editor 目标仍被第三方
  `UnLuaEditor` 链接失败阻塞（见 T19 记录）。纯 Lua 侧可验证的都已验证（`run_viewmodel.lua` 10 项），UE Widget 侧靠源码守卫锁接线。
- 武器弹道数据仍是两份（`Content/Data/WeaponBallistics.json` 与 `UFPSRecoilProfile` 资产），T17 只收敛了编解码与校验，没有合并数据源。

## 2026-09-15 首次编辑器内实跑抓到的问题（T3/T5）

- **Editor 目标建不出来的两个前置**（都已处理）：
  1. `Plugins/UnLua/Source/UnLuaEditor/UnLuaEditor.Build.cs` 缺 `DeveloperSettings` / `ContentBrowser`，
     `UnrealEditor-UnLuaEditor.dll` 直接链接失败（14 个未解析符号：`UDeveloperSettings` 系列 +
     `UContentBrowserAssetContextMenuContext`）。插件源码在 `.gitignore` 里，只能本机修，不进版本库。
  2. `Source/FPS/UGC/UGCEditorBridge.cpp` 的文件级 helper `GetParentWindowHandle` 与
     `AnimGenClient.cpp` 里的同名 helper 在 **unity build** 下撞名（`C2668 对重载函数的调用不明确`、
     `C2737`）。这是 T19 提交留下的：UBT 把同模块多个 .cpp 编进一个 TU，文件级 helper 必须带模块前缀。
     已改名 `GetUGCWindowHandle`。**教训：`#if WITH_EDITOR` 内的文件级 helper 也要用唯一名字。**
- **`UAssetManager::AddDynamicAsset` 不能用在被扫描的 PrimaryAssetType 上**：
  引擎在 `AssetManager.cpp:1304` `ensure(TypeData.Info.bIsDynamicAsset)`，而"来自磁盘扫描的类型"这条是
  false（引擎不允许一个类型既扫描又 dynamic）。运行时导入的预制体定义改用独立类型 `UGCPrefabRuntime`
  （纯 dynamic），磁盘定义保持 `UGCPrefab`（`PrimaryAssetTypesToScan`），两者由
  `FUGCPrefabCatalog::GetDefinitions` 合并成同一个查询入口。
- **纯 Lua 回归抓不到的运行时断链**：`UGCFunctionRegistry.lua:288` 调
  `require("Gameplay.UGC.UGCPrefabRegistry").ListIDs()`，而该函数在 `05a55fe 重构解耦` 时被删掉。
  结果 `RegisterAll` 在运行时整体抛异常，**整张 LLM 工具注册表起不来**（place_object / set_attribute /
  提案循环全部不可用），而所有纯 Lua 测试都 mock 了 PrefabRegistry 所以全绿。
  已补 `ListIDs` + 在 `run_prefab_definitions.lua` 加「注册表对外调用面」静态回归（扫描其它模块对注册表的
  `require(...).Fn` / `PrefabReg:Fn` 调用，逐个断言函数存在）。这条是 T3「代码改动只有跑过才算数」的直接证据。
- **T5 迁移工具**：`UGC.CreatePrefabDefinitions`（`Source/FPS/UGC/UGCPrefabDevCommands.cpp`，整体 `#if WITH_EDITOR`）
  可无头重跑：读 `Content/_UGC/Placeables/placeable_manifest.json` 的语义 + 扫描该目录的 Placeable 蓝图，
  生成/回填 `Content/_UGC/Prefabs/PDA_Prefab_<Id>`。首次执行结果：新建 Box / Sphere / TriggerZone 三个定义资产，
  保存 3/3 个包。它需要 `UnrealEd`（`GEditor` 等编辑器符号）与 `AssetRegistry`，都放在 `bBuildEditor` 分支里。
- **`GetPrimaryAssetObject` 只返回"已在内存"的对象**（不是惰性加载）：只调它会让定义静默解析不到、
  注册表退回旧 Catalog（首轮实跑 `definitions:0`）。取定义要 `GetPrimaryAssetPath(id).TryLoad()`。
- **旧存档入口的尖锐行为（未改，属"待定"）**：`UGCPersistence:LoadProject` 在收到**存在的** `.json` 文件路径时，
  会先按 v2 package 校验并返回 `invalid_project_file`；legacy 布局（`scene.json + programs.json`）只在
  "候选文件都不存在"时才走到，所以旧存档必须用**目录级**入口加载（实测 `LoadProject("<dir>/")` 可用）。
  T3 冒烟脚本会把实际走的入口写进结果串；若将来要支持"直接点选 scene.json"，需要改 Persistence。
- **`UGCStorageBridge::IsAllowedJsonPath` 对相对路径敏感**：它先 `ConvertRelativePathToFull`（相对**进程 CWD**）
  再要求落在 `ProjectSavedDir()` 下，因此 Lua 侧传相对路径 `Saved/UGC/...` 会被拒（`Rejected non-JSON path`）。
  调用方应传绝对路径（T3 冒烟脚本已改为 `ProjectDirectory()` 前缀）。
- **进 Play 时 `level_main` 编译失败**：`EditorCore:EnterPlayMode` → `ProgramRunner:TriggerGameStart()`
  → `CompileAllPrograms()` 会编译测试地图里残留的 `level_main` 并报 `compilation_failed`（每次进 Play 一条 Error，
  不阻塞其它程序）。待确认是测试地图内的旧数据还是 schema 漂移。
- **UnLua 侧 `AController:GetPawn()` 不可直接调用**（`method 'GetPawn' is not callable (a nil value)`）：
  读 `pc.Pawn` 属性可用（T3 冒烟脚本的 Pawn 切换断言就是这么写的）。

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

2026-09-14 的探针用的是当时本机唯一的 UE 5.7（项目目标 5.4）+ 临时补丁；另一台开发机（tsuYu-pro 线所在机器）自
2026-09-18 起装有 UE 5.4.4（`E:\Engine\UE_5.4`，自带 .NET 6，Installed Build 且带 DebugGame/Development/Shipping
三套 UnrealGame 中间产物），因此 09-18 当天的 Shipping 验证直接在项目目标版本上完成（记录见本节末）。

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

### UE 5.4 开发构建实测（2026-09-14，本机 UE_5.4 已安装）

本机现在同时装有 UE 5.1 / 5.4 / 5.5，因此用项目目标版本 5.4 跑了一次真实构建：

```powershell
Build.bat FPSEditor Win64 Development -Project="<repo>/FPS.uproject" -WaitMutex -NoHotReload
```

- **FPS 模块编译 + 链接成功**：`Module.FPS.*.cpp` 全部编译通过，`Link [x64] UnrealEditor-FPS.dll` 成功，
  产物 `Binaries/Win64/UnrealEditor-FPS.dll` 已更新。这是本项目第一次在 5.4 上真正链过 FPS 模块。
- **抓到并修复一个真实缺陷（T19 的依赖瘦身结论有误）**：`ApplicationCore` 不是"无直接引用"——
  `Source/FPS/UGC/UGCPlayerController.cpp` 调 `FPlatformApplicationMisc::ClipboardCopy`
  （`HAL/PlatformApplicationMisc.h`），删掉后链接期报
  `LNK2019: 无法解析的外部符号 FWindowsPlatformApplicationMisc::ClipboardCopy`（1 个未解析符号）。
  已把它加回 `PrivateDependencyModuleNames`，并把 `run_tests.ps1` 的依赖守卫从"禁止 ApplicationCore"
  改成"必须保留 ApplicationCore"（Niagara 仍然禁止）。T19 之前只有 UBT/UHT 解析级证据，没有链接级证据，
  这条差值正是"完整构建必须在 5.4 上跑"的原因。
- **其余瘦身结论成立**：`HTTP` 留 Public、`Json`/`PCG`/`glTFRuntime` 放 Private、移除 `Niagara`/`JsonUtilities`
  在链接期均无未解析符号；`DesktopPlatform` 的 `#if WITH_EDITOR` 守卫与 `Target.bBuildEditor` 也通过编译。
- **仍未通过：整个 Editor 目标**。唯一阻塞是第三方插件 UnLua 的 `UnLuaEditor` 模块链接失败
  （13 个未解析符号：`UDeveloperSettings` 系列来自 `DeveloperSettings` 模块、
  `UContentBrowserAssetContextMenuContext` 来自 `ContentBrowser` 模块），与本项目代码无关；
  `UnLuaEditor.Build.cs` 只列了 `DeveloperToolSettings`，没有 `DeveloperSettings` / `ContentBrowser`。
  注意 `Plugins/UnLua/Source` 在当前 `.gitignore` 里，改动无法进版本库，所以这一项是**本机环境修复**，
  修好之后才能编译出可启动的编辑器、进而做 T3 的 PIE 验收。
- 顺带一条工具链坑：`Tools/UGCTests/run_tests.ps1` 必须保持纯 ASCII。本机 `powershell`（5.1）按 ANSI
  解码无 BOM 文件，往里写中文注释会直接让脚本解析失败（本次实际踩到，报
  `UnexpectedToken`）。该文件当前只有一处历史遗留的 em dash，保持现状即可，新增内容一律用 ASCII。

### UE 5.4 Shipping 构建实测（2026-09-14，T19 验收项）

```powershell
Build.bat FPS Win64 Shipping -Project="<repo>/FPS.uproject" -WaitMutex -NoHotReload
```

- **通过（exit 0）**：`Module.FPS.*.cpp` 共 9 个 TU 在 Shipping 配置下全部编译，`[102/103] Link [x64] FPS-Win64-Shipping.exe`
  与 `[103/103] WriteMetadata` 均成功，产物 `Binaries/Win64/FPS-Win64-Shipping.exe`（147 MB）+ `.pdb` + `.target` 已产出。
- 链接期零未解析符号：说明 `HTTP`(Public)/`Json`/`PCG`/`glTFRuntime`/`ApplicationCore`(Private)、
  被移除的 `Niagara`/`JsonUtilities`、以及 `DesktopPlatform` 的「仅编辑器」处理在 Shipping 下都成立。
- 这一条同时反证了编辑器专用守卫是真的有效：`UGCEditorBridge.cpp`、`AnimGenClient.cpp` 的
  DesktopPlatform 调用若没被 `#if WITH_EDITOR` 包住，Shipping 链接必然失败。
- 第三方噪音（不影响结论）：LuaSocket 在 Windows SDK 10.0.22621 下有 `gai_strerror` 宏重定义
  `warning C4005`（third-party，未处理）。
- 结论：T19 的「至少完成一次 Shipping 目标构建验证」达成。Editor 目标仍被第三方 UnLua 的
  `UnLuaEditor` 模块阻塞（见上一节），与本项验收无关，但它是 T3 PIE 的前置条件。

### Shipping 构建验证（UE 5.4.4，2026-09-18，tsuYu-pro 线开发机）

- 命令：`Build.bat FPS Win64 Shipping -project=F:\github\FPS\FPS.uproject`（UE 5.4.4，`E:\Engine\UE_5.4`）。
- 结果：**BUILD_EXIT=0**，109 个动作 / 67.7 秒；产出 `Binaries/Win64/FPS-Win64-Shipping.exe`（147 MB，含 `.lib`/`.exp`/`.pdb`）。
- 同一天 `FPSEditor Win64 Development` 亦构建通过，说明新依赖表在编辑器配置下同样成立。
- 仅第三方警告：`Plugins/UnLuaExtensions/LuaSocket` 的 `gai_strerror` 宏重定义（无害）。
- 结论：T19 里「最终 Shipping 验证必须在 UE 5.4 环境执行」的要求已满足，且这是在**项目 + 全部启用插件**上的完整 Shipping 编译，不是单文件探针。

## 验证缺口

（2026-09-15 更新）T3 的编辑器自动化已打通：本项目现在能起 UE 5.4 编辑器、能通过 UEEditorMCP 拉起 PIE、
能脚本化跑 7 项验收（`python Tools/UGCTests/run_pie_smoke.py`，当前 7/7）。以下内容仍**没有被验证过**：

- 鼠标手感类：真人拖 Gizmo、真实点击落点、拖拽跟手度（按约定由人工抽查，不在自动化范围）。
- PIE 双客户端的 RPC、复制、重生和 UI 状态（多人链路，依赖 T6/T12 的方向决策）。
- 进 Play 时 `level_main` 的 `compilation_failed`（见上文，待确认是地图内旧数据还是 schema 漂移）。
- Blueprint 的实际父类、CDO 默认属性与组件引用（MCP 在线时才方便核对，索引基线里没有）。
- 各地图 World Settings/GameMode Override、DataTable 的实际行值、Widget Designer 里 BindWidget 名称完整性。
- Blueprint 编译状态和资源重定向器。
- Shipping 包内的 AssetManager 定义是否随包（配置已写 `CookRule=AlwaysCook`，但没有实测打包后的加载）。
