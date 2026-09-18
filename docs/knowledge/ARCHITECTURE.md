# 架构总览

## 1. 系统定位

FPS 是一个 Unreal Engine 5.4 多人 FPS/撤离与 UGC 原型。当前代码包含三条相互叠加的产品线：

1. 多人 PVP：队伍、计分、复活、比赛状态、射击与 GAS。
2. 撤离/背包：网格库存、物品 DataTable、地图选择、撤离区和结算数据。
3. UGC：运行时场景编辑、节点程序、LLM Function Calling 和 PCG 生成。

工程仍保留 UE 模板、迁移素材和早期实现，因此“目录中存在”不等于“当前运行路径正在使用”。

## 2. 分层与职责

### C++：稳定框架与权威逻辑

- `Source/FPS/FPSCharacter.*`：角色输入、移动、体力、GAS Avatar、武器槽入口、死亡通知。
- `Source/FPS/FPSGameMode.*`：服务端队伍分配、比赛状态、计分、助攻、复活、胜负。
- `Source/FPS/Team/`：PlayerState/GameState 复制状态及队伍工具。
- `Source/FPS/GAS/`：ASC、AttributeSet、GameplayAbility、Tag、后坐力组件。
- `Source/FPS/Weapon/`：武器配置、武器 Actor、弹体、配件、携带槽。
- `Source/FPS/Inventory/`：网格库存模型、物品查询和 C++ Widget 基类。
- `Source/FPS/UI/`：HUD/菜单的 C++ 数据接口与基础行为。
- `Source/FPS/UGC/`：UGC Authoring GameMode、Playtest Pawn 切换、事件路由、原子存储、HTTP/PCG 与 Lua 无法直接完成的引擎能力。
- `Source/FPS/AnimAgent/`：GLB 本地导入与运行时网格注入（`UAnimGenClient` / `UAnimImportBridge` / `AAnimAgentDynamicPlaceable`），以及 Fab 平台客户端（`Fab/`：REST 桥、配置、登录态、`uefab://` scheme）。详见 `ANIMAGENT_AND_FAB.md`。
- `Plugins/GamePlay/Source/`：独立交互接口与射线检测组件；当前未发现核心 FPS 模块直接引用。

### Blueprint：装配与可视资源

- `Content/_FPS/Blueprints/`：GameMode、Player、PlayerController、菜单 Controller。
- `Content/_FPS/System/UI/`：实际 UMG Widget 资产。
- `Content/_FPS/Weapon/`：武器、能力、伤害 GE、弹体 Blueprint。
- `Content/_UGC/`：UGC GameMode、Controller、编辑器 Widget、Gizmo、Placeable。
- Blueprint 负责给 C++ 的 `EditAnywhere/EditDefaultsOnly` 字段赋值，并配置 UnLua 模块名。

### Lua：热更业务与 UI

- `Content/Script/Gameplay/Core/`：UIManager、文本、音效、调试指令、背包整理。
- `Content/Script/Gameplay/`：普通与菜单 PlayerController。
- `Content/Script/System/UI/`：HUD、菜单、库存、UGC Widget 行为。
- `Content/Script/Gameplay/UGC/`：编辑状态机、场景数据、预制体、LLM、节点程序、生成器。
- `Content/Script/Gameplay/AnimAgent/`、`Gameplay/Fab/`、`System/UI/Fab/`：资产库与编排器、Fab 门面、Fab 登录/面板 UI。
- `Content/Script/Gameplay/UGC/UGCLog.lua`：UGC 唯一日志出口（结构化单行 + 稳定 ErrorCode，经 `UUGCLog` 落到独立分类 `LogFPSUGC`）。

### 数据

- `Content/_FPS/Data/Items/DT_ItemDefinition.uasset`：运行时物品定义。
- `SourceData/Items.csv` -> `Tools/DataTableConverter/converter.py` -> `Output/CSV/DT_ItemDefinition.csv`：策划数据流水线。
- `Content/_FPS/Data/Maps/DT_MapList.uasset`：Lua 地图选择页读取的数据表。
- `Content/Data/WeaponBallistics.json`：旧/并行 Lua 武器弹道配置。
- `Content/Script/Util/json.lua`：UGC 文档持久化的唯一 JSON 编解码实现；读写 `*.ugc.json` 与旧 `scene.json + programs.json`，不要再新增第二个 JSON 模块。
- `Content/Script/Gameplay/UGC/UGCPlaceableConfig.lua`：当前打包运行时的审核 Prefab Catalog；`placeable_manifest.json` 暂保留为资产侧元数据候选。
- `Saved/UGC/`：运行时场景、程序、编辑器状态、聊天历史；被 Git 忽略。
- `Saved/AnimAgent/`（`library.json` + `assets/{uuid}/`）与 `Saved/Fab/`（`config.json`、`token.dat`）：AnimAgent/Fab 运行时数据；同样被 Git 忽略。详见 `ANIMAGENT_AND_FAB.md`。

## 3. 启动与主要运行流

### 主菜单启动

```text
DefaultEngine.ini
  -> Level_LoginMap
  -> BP_MenuGameMode
  -> BP_MenuPlayerController
  -> Gameplay.MenuPlayerController:ReceiveBeginPlay
  -> Lua UIManager:OpenWindow("UI/Menu/WBP_MainMenu")
```

离线扫描已确认 `BP_MenuPlayerController` 绑定 `Gameplay.MenuPlayerController`，主菜单 Widget 绑定 `System.UI.Menu.WBP_MainMenu`。

### 普通玩家启动

```text
BP_FPSGameMode
  -> BP_FPSPlayerControll
  -> BP_FPSPlayer
  -> PlayerState owns ASC + CombatAttributeSet
  -> Character PossessedBy/OnRep_PlayerState initializes ASC
  -> Lua Gameplay.PlayerController initializes UIManager and HUD
```

### 开火链

```text
Enhanced Input
  -> AFPSCharacter::HandleFire
  -> ASC TryActivateAbilitiesByTag(FPS.Ability.Weapon.Fire)
  -> UGA_WeaponFire
  -> AFPSWeaponBase::Fire
  -> client predicted effects / ServerFire RPC
  -> server SpawnProjectile
  -> AFPSProjectile hit
  -> GameplayEffect SetByCaller(FPS.Effect.Damage)
  -> UFPSCombatAttributeSet::HandleDamage
  -> death delegate
  -> AFPSGameMode::HandlePlayerDeath
```

注意：当前同时存在 `UFPSRecoilComponent` 与 `BP_WeaponBase.lua` 两套弹道/Pattern 状态，详见风险文档。

### UGC 指令链

```text
WBP_UGCChat.lua
  -> AUGCPlayerController Lua:SendToLLM
  -> LLMGateway -> UUGCHttpClient
  -> model tool_calls -> validated Proposal {baseRevision, risk, calls}
  -> read-only auto-run / write-high risk explicit approval
  -> UGCFunctionRegistry policy + allowlists
  -> UGCCommandBus / authoritative C++ bridge
  -> tool results return to model until final response or round budget
```

### UGC 编辑链

```text
F9 / UI
  -> UGCEditorCore state Idle/Edit/Play
  -> UGCDocument (pure data) <- UGCCommandBus (validate/execute/inverse)
  -> UGCWorldProjection -> UUGCEditorBridge -> World Actors
  -> UGCPersistence -> UUGCStorageBridge -> atomic *.ugc.json
  -> Play mode swaps Spectator authoring pawn to BP_FPSPlayer
  -> TriggerZone -> UUGCEventRouterSubsystem -> ProgramRunner
```

## 4. 网络权威模型

- GameMode 只在服务端存在并处理比赛、得分、复活。
- PlayerState 持有 ASC 和属性，跨 Pawn 重生保留。
- GameState 复制比赛状态、队伍分数和剩余时间。
- WeaponSlotComponent 复制槽位 Actor、物品实例和当前槽。
- Weapon Actor 复制 Actor 本体及配件 ID，但当前弹药和武器状态未标记复制。
- Projectile 由服务端生成并复制移动；伤害只在服务端命中回调中应用。
- Client RPC 用于击杀信息与比赛状态提示。

## 5. 模块与插件边界

### 项目模块

- `FPS`：唯一主运行时模块。
- `GamePlay`：启用的自研 Runtime 插件，提供通用交互接口/组件；核心 FPS 源码当前没有静态依赖或直接引用。
- `Web`：空壳 Runtime 插件，未在 `FPS.uproject` 显式启用。
- `UEEditorMCP`：启用、Editor-only，本机 55558 端口，供编辑器资产自动化。
- `UnrealMCP`：旧插件，当前禁用。

### 第三方

- UnLua 2.3.6 及 LuaRapidjson/LuaSocket/LuaProtobuf。
- Wwise 2024.1.8.8898.3839。
- UE 内置 GameplayAbilities、EnhancedInput、PCG、EditorScriptingUtilities。

## 6. 热点文件

最值得优先局部读取的文件：

- `Source/FPS/Weapon/FPSWeaponBase.cpp`
- `Source/FPS/FPSCharacter.cpp`
- `Source/FPS/FPSGameMode.cpp`
- `Source/FPS/System/FPSMenuSubsystem.cpp`
- `Content/Script/System/UI/Inventory/WBP_InventoryGrid.lua`
- `Content/Script/System/UI/UGC/WBP_UGCBlueprintEditor.lua`
- `Content/Script/Gameplay/UGC/UGCEditorCore.lua`
- `Content/Script/Gameplay/UGC/UGCSceneData.lua`

逐文件函数清单见 `generated/SYMBOL_INDEX.md`。

## 7. 事实置信度

- **高**：C++、Lua、INI、JSON、插件描述文件中的直接事实。
- **中**：对 `.uasset` 做离线字符串扫描得到的父类、模块名、控件/资产引用。
- **待验证**：Blueprint 图连接、默认属性最终值、关卡 World Settings、DataTable 行内容。需要启动 Unreal Editor 并让 UEEditorMCP 55558 端口在线后读取。
