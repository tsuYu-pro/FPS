# 系统索引

## 1. 角色、输入与 GAS 初始化

### 入口

- `AFPSCharacter`
- `AFPSPlayerController`
- `AFPSPlayerState`
- `Content/_FPS/Blueprints/BP_FPSPlayer.uasset`
- `Content/_FPS/Blueprints/BP_FPSPlayerControll.uasset`
- `Content/Script/Gameplay/Character/BP_FPSPlayer.lua`
- `Content/Script/Gameplay/PlayerController.lua`

### 状态所有者

- ASC 与 `UFPSCombatAttributeSet` 在 `AFPSPlayerState`。
- `AFPSCharacter` 缓存 ASC/AttributeSet，仅作为 Avatar。
- Character 本身复制 `bDead`、`bIsSprinting`。
- 输入资产由 Blueprint Defaults 注入 C++ 指针。

### 初始化链

1. 服务端 `PossessedBy`、客户端 `OnRep_PlayerState` 调用 `InitializeAbilitySystem`。
2. `ASC->InitAbilityActorInfo(PlayerState, Character)`。
3. 服务端授予 `DefaultAbilities` 并应用 `DefaultEffects`。
4. Character 绑定 AttributeSet 的 `OnDeath`。

### 输入

- Character：Jump、Move、Look、Sprint、Fire、Aim、Crouch、Reload。
- PlayerController：Pause、Inventory、三个武器槽、Cycle、Interact。
- UGC Controller：ToggleEditor、EditorClick。
- 映射资产主要位于 `Content/_FPS/Blueprints/Input/` 和 `Content/_UGC/Input/`。

### 修改时注意

- ASC 在 PlayerState 上，重生时不要按“新 Character = 新 ASC”理解。
- 所有修改属性、授予能力、死亡和武器切换的写操作应保持服务端权威。
- Blueprint 必须正确配置 InputAction/MappingContext，否则 C++ 只会跳过绑定。

## 2. 比赛、队伍、计分与复活

### 入口

- `AFPSGameMode`
- `AFPSGameState`
- `AFPSPlayerState`
- `AFPSPlayerStart`
- `UFPSScoreboardWidget`

### 状态机

`WaitingForPlayers -> Countdown -> InProgress -> GameOver`

- `MinPlayersToStart`：C++ 当前默认 1。
- `CountdownDuration`：5 秒。
- `ScoreToWin`：30。
- `MatchTimeLimitSeconds`：600 秒。
- `RespawnDelay`：5 秒。
- `KillScore`：1。

### 服务端流程

- `HandleStartingNewPlayer_Implementation`：先分队，再直接 `RestartPlayer`。
- `ChooseTeamForPlayer`：人数少的一队；相等时 TeamA。
- `ChoosePlayerStart_Implementation`：优先同队 `AFPSPlayerStart`，再普通 PlayerStart。
- `HandlePlayerDeath`：死亡、击杀、分数、助攻、击杀播报、胜负检查、延迟复活。
- 助攻：死亡前 10 秒内，实际生命伤害达到 MaxHealth 的 20%，排除最终击杀者。

### 复制

- PlayerState：Team、K/D/A、MatchScore、DamageDealt/Taken。
- GameState：自定义 MatchState、队伍分数、剩余时间、规则参数。

## 3. 战斗属性与伤害

### 属性

- Health / MaxHealth
- Armor / MaxArmor / ArmorReduction
- Stamina / MaxStamina / StaminaRegenRate
- MovementSpeed
- Meta：IncomingDamage / IncomingHeal

### GAS 伤害链

1. Projectile 或 Melee 创建 Damage GE spec。
2. 通过 `FPS.Effect.Damage` SetByCaller 写入伤害。
3. `PostGameplayEffectExecute` 处理 `IncomingDamage`。
4. GAS Armor 按 `ArmorReduction` 吸收一部分。
5. 剩余伤害扣 Health，并记录双方伤害统计和助攻记录。
6. Health <= 0 广播 `OnDeath`。

### 额外护甲层

`UFPSArmorComponent` 维护：

- ArmorLevel
- MaxDurability / CurrentDurability
- CoveredBones
- `TakeDurabilityDamage`

Projectile Lua 根据弹级与 ArmorLevel 计算肉伤/甲伤；随后 C++ AttributeSet 还可能按 GAS Armor 再吸收。此处存在双护甲模型，修改前先看风险文档。

## 4. 武器、弹体、后坐力与配件

### 数据

- `UFPSWeaponDataAsset`：基础数值、弹药、表现、动画、Projectile、GAS ability、RecoilProfile、支持配件槽。
- `UFPSWeaponAttachmentData`：配件 ID、槽位、属性增量、Mesh/Icon、物品表映射。
- `UFPSRecoilProfile`：Pattern/Spread 参数。
- `Content/Data/WeaponBallistics.json`：Lua 并行弹道配置。

### 武器 Actor

- `AFPSWeaponBase`：装备/卸下、开火、RPC、装弹、GAS ability 授予、配件有效属性。
- 开火客户端先播表现，再 `ServerFire`；服务端生成 Projectile 并 Multicast 表现。
- 枪口 Socket 固定名：`Muzzle`。
- 装备 Socket 固定名：`hand_r`。
- Lua 角色脚本还要求 `weapon_back_1`、`weapon_back_2`、`LeftHandSocket`。

### 武器槽

- `UFPSWeaponSlotComponent` 固定 3 格：
  - 0 = Primary1
  - 1 = Primary2
  - 2 = Pistol
- 服务端 Spawn 武器 Actor，复制槽数组和 ActiveSlot。
- 切换时旧武器卸下/隐藏，新武器装备并挂到 `hand_r`。

### 世界拾取

- `AFPSWorldWeapon` 用半径 150 的 Sphere 做近距离判断。
- PlayerController 按 E 后枚举重叠的 `AFPSWorldWeapon`。
- 优先放入空武器槽；失败后尝试放进 Character 上的 `UInventoryGridComponent` 的 `(0,0)`。
- UGC `SpawnWeapon` 当前只设置 `WeaponItemDefID`，不会自动设置 `WeaponActorClass`。

### 后坐力

- C++ `UFPSRecoilComponent`：Pattern、Spread、Lazy Recovery、ADS 查询。
- Lua `BP_WeaponBase.lua`：从 JSON 读取另一套 Pattern/随机散布并覆盖武器方向。
- HUD 展示读取 C++ RecoilComponent 的 `CurrentSpread`。

## 5. 库存与物品

### 数据模型

- `FItemDefinitionRow`：静态定义。
- `FInventoryItem`：实例 ID、堆叠、耐久、自定义属性。
- `FInventoryItemPlacement`：实例 + 网格坐标 + 旋转。
- `FInventoryRegion`：背包分区，物品不能跨区。

### 运行时

- `UItemDataManager` 是 GameInstanceSubsystem。
- 当前同步加载固定路径 `/Game/_FPS/Data/Items/DT_ItemDefinition`，构建行指针缓存。
- `UInventoryGridComponent` 用：
  - `TMap<FGuid, FInventoryItemPlacement> Items`
  - 一维 `TArray<FGuid> OccupancyGrid`
  - 边界、区域和占用校验
- 默认网格 3x3；蓝图可覆盖。

### UI

- C++ `UInventoryGridWidget` 负责绑定组件、创建 ItemIcon。
- Lua `WBP_InventoryGrid.lua` 负责拖拽、旋转、上下文菜单、Tooltip、整理和武器装备。
- `InventorySorter.lua` 使用按类型/面积排序后的 First Fit Decreasing。

### 数据流水线

`SourceData/Items.csv` -> `Tools/DataTableConverter/converter.py` -> `Output/CSV/DT_ItemDefinition.csv` -> UE 导入 DataTable。

源 CSV 当前中文显示为乱码，而 Output CSV 正常；不要直接覆盖输出前先确认源编码。

## 6. UI 与菜单

### 实际 Lua 窗口栈

- `Gameplay.Core.UIManager`
- `Gameplay.PlayerController`
- `Gameplay.MenuPlayerController`

UIManager 使用逻辑名注册表加载 Widget Blueprint，维护 `_openWindows` 与 `_windowStack`，并切换输入模式。

### C++ 菜单栈

- `UFPSMenuSubsystem`
- `UFPSMenuWidgetBase`
- Main/Pause/Settings/MapSelect/Loadout C++ Widget

C++ 也维护 `MenuStack`、设置、地图与 Raid 流程。当前运行资产的 Lua 脚本多数直接调用 Lua UIManager，所以两套栈并存。

### HUD

- C++ `UFPSHUDWidget` 绑定 AttributeSet 委托和武器弹药委托。
- Lua `WBP_HUD.lua` 实现具体视觉。
- C++ HUD 每 Tick 检查武器切换、状态效果倒计时和准星 Spread。

## 7. 撤离流程

- `AFPSExtractionZone`：Trigger、驻留进度、可选钥匙要求、消费钥匙。
- `FFPSRaidResult`：成功、最终状态、时长、伤害、击杀、经验。
- 当前 `AFPSGameMode::OnPlayerExtracted` 仅日志，尚未完成 Raid 结束、保存库存和结算。
- `UFPSMenuSubsystem` 有 Raid 结果 UI，但完整流程尚未接通。

## 8. UGC 运行时编辑器

### 核心对象

- `AUGCGameMode`：独立继承 `AGameModeBase`，Authoring 默认使用 SpectatorPawn，不再进入 PVP 分队/比赛逻辑。
- `AUGCPlayerController`：承载 Function/HTTP/Editor/PCG/Storage Bridge，并管理 Authoring Pawn 与 Playtest Pawn 的切换。
- `UGCDocument.lua`：纯数据文档、稳定 EntityId、Revision、Programs、GeneratedGroups。
- `UGCCommandBus.lua`：统一命令、Composite 回滚、动态 inverse Undo/Redo，历史上限 64。
- `UGCWorldProjection.lua`：唯一持有 SceneID -> Actor 引用的 Lua 层。
- `UGCSceneData.lua`：兼容 facade；旧 CRUD API 仍可用，但内部走 Document/Command/Projection。
- `UUGCEventRouterSubsystem`：TriggerZone 与具体 PlayerController/Pawn 解耦。
- `UGCEditorCore.lua`：Idle/Edit/Play、Ghost、选中、Gizmo；进入 Play 时保存图、切换 Gameplay Pawn、启动程序，回到 Edit 时取消任务。
- UMG：Editor、Chat、BlueprintEditor、Node、PinRow、WireOverlay；Graph 文档不再持有 Widget/CanvasSlot。

### Prefab Catalog

- Shipping 使用 `UGCPlaceableConfig.lua` 的审核 Catalog，目前只登记仓库真实存在的 Box、Sphere、TriggerZone。
- Editor PIE 可通过 `FindFilesInDirectory` 发现开发中的 Placeable；该接口在非 Editor 构建返回空。
- 任意玩家 BlueprintClass 路径导入已禁用，后续应由 `PrimaryDataAsset + AssetManager + 内容校验 Provider` 替代。

### 存档

- 主格式：单一版本化 `*.ugc.json`，包含 Document、Programs、Groups、WorldSettings 和 editor state。
- `UUGCStorageBridge` 提供 UTF-8 读取和 temp/verify/backup/rename 原子写入；Widget、LLM、Prefab Registry 不再直接 `io.open/os.execute`。
- 旧 `scene.json + programs.json` 仍可读取迁移。
- 编解码只有一份：`Content/Script/Util/json.lua`。对象键按字典序输出以保证存档可 diff；非有限数（NaN/Inf）编码为 `null`；decode 失败返回 nil 而不抛异常。`Gameplay/UGC/json.lua` 与 `UGCSerialize.lua` 已删除，`Tools/UGCTests/run_tests.ps1` 有静态守卫断言它们不再出现。
- `Saved/UGC/` 不进 Git。

### 日志

- 唯一出口：`Content/Script/Gameplay/UGC/UGCLog.lua`。UGC 服务层（CommandBus / SceneData / Persistence / FunctionRegistry / LLMGateway / EditorCore / ProgramRunner / PrefabRegistry / PlayerController / Generators）不再直接 `print`。
- 单行格式：`event=... severity=... session=... document=... command=... type=... ok=... code=... program=... entity=... fields={...}`。已知字段扁平可 grep，其余进 `fields` JSON（经 `Util.json` 编码，键序稳定可 diff）。
- UE 侧分类：`Source/FPS/UGC/UGCLog.h/.cpp` 定义独立 `LogFPSUGC`，Lua 经 `UUGCLog::WriteLine` 落地；编辑器外/单测无 UE 环境时退回 `print`（UnLua 会转发到 LogUnLua）。可用 `-LogCmds="LogFPSUGC Verbose"` 单独开关。
- 稳定 ErrorCode：`UGCLog.Codes` 是白名单，未登记的 code 会被写成 `code=unregistered_code` 并把原值放进 fields；`Tools/UGCTests/run_logging.lua` 会扫描 `Content/Script`，出现未登记 code 直接判失败。
- SessionId 由 `SceneData:Init` 调 `Log.NewSession("scene_init")` 生成，命令/存档/图程序日志都会带上它。

## 9. UGC LLM 与函数调用

### C++ HTTP

- 默认端点：DeepSeek OpenAI-compatible Chat Completions。
- 模型枚举：DeepSeek Chat/Reasoner、Qwen Plus/Turbo/Max。
- API Key 从进程环境变量 `FPS_UGC_LLM_API_KEY` 读取；只有 transient 开发覆盖字段，不序列化进资产。
- Lua 维护最近 20 轮历史，经 `UUGCStorageBridge` 原子写入 `Saved/UGC/chat_history.json`。

### 注册函数

- 属性：`set_attribute`、`get_attribute`
- GAS：`grant_ability`、`remove_ability`
- 武器：`spawn_weapon`
- 规则：`set_rule`、`get_rule`
- 场景：`place_object`、`move_object`、`delete_object`、`list_objects`
- PCG：`pcg_generate`、`pcg_clear`
- 生成器：`list_generators`、`delete_batch`、`list_batches`
- 自动导出：`generate_coverfield`、`generate_room`、`generate_wall`

### 节点程序

- `UGCGraphSchema.lua` 是 UI 与 Compiler 的共享类型定义。
- `UGCGraphCompiler.lua` 校验节点、参数 allowlist、Pin、连接基数、不可达节点和所有执行流循环，并输出不可变 IR。
- `UGCProgramRunner.lua` 只执行 IR；Delay/Interval 使用真实 DeltaTime，单次执行预算 128、每帧任务预算 64，支持取消和程序失效。
- 事件：OnEnter、OnExit、OnInterval、OnGameStart；Play 模式启动时统一编译并注册 Interval。
- AI Tool Schema 使用 `additionalProperties=false`；写操作先形成 Proposal，确认前会校验 Document `baseRevision` 防止陈旧提案执行。
- Ability、Weapon、Attribute、Rule、PCG Graph 均使用共享显式 allowlist；不接受任意 Ability/PCG 资产路径。

## 10. 编辑器自动化

- `UEEditorMCP` 启用且为 Editor-only。
- C++ TCP 服务默认 `127.0.0.1:55558`。
- Python 提供统一 MCP 服务、CLI 和约 98 个编辑器命令。
- 能力包括 Blueprint 摘要/完整描述、组件/节点/图编辑、UMG、Material、关卡 Actor、PIE、日志。
- 本次索引创建时 55558 不在线，因此未把 Blueprint 图内部数据写入基线。

## 11. AnimAgent（本地 / 生成资产管线）

- 入口：`UAnimGenClient`（组件，挂 PlayerController）、`Gameplay.AnimAgent.AnimAgentCore`（编排器）。
- 落盘：`Saved/AnimAgent/assets/{uuid}/source.glb` + `meta.json`、资产库 `Saved/AnimAgent/library.json`。
- 注册：`UGCPrefabRegistry.RegisterDynamicGLB` → id `dyn:{uuid}`、`GetKind() == "dynamic_glb"`；
  spawn 后由 `UGCEditorCore:_InjectDynMesh` 经 `UAnimImportBridge`（glTFRuntime）把 mesh 注入
  `AAnimAgentDynamicPlaceable`（继承 `AStaticMeshActor`，复用 UGC Placeable 基建）。
- 修改时注意：mesh 注入挂在 `SceneData:SetActorCreatedHook` 上，**必须覆盖 CreateEntity / RestoreEntity / 读档
  三条 spawn 路径**，否则创建与 Undo/Redo、读档表现不一致。
- 详情：`ANIMAGENT_AND_FAB.md`。

## 12. Fab 平台对接

- C++：`UFabClientBridge`（Auth / Asset / AI 三组 API + 多播事件）、`UFabConfig`（`Saved/Fab/config.json`）、
  `UFabTokenStore`（`Saved/Fab/token.dat`，JSON→XOR→base64）、`UFabUrlDispatcher`（`uefab://` scheme）。
- Lua：`Gameplay.Fab.FabClient`（门面）、`System.UI.Fab.WBP_FabLogin`（零 BP 节点登录）、`WBP_FabPanel`（CEF 面板）。
- LLM 工具：`fab_publish_local_asset`、`fab_create_ai_model`、`fab_create_ai_model_from_image`、`fab_check_ai_task`。
- 风险：默认 BaseUrl 是明文 HTTP 公网 IP、token 非强加密、下载无完整性校验——详见 `ANIMAGENT_AND_FAB.md` §6。
