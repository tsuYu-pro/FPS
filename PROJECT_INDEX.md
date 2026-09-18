# FPS 项目快速索引

> 用途：后续开发先查这里和 `docs/knowledge/generated/index.json`，不要默认重扫整个仓库。
> 基线：Unreal Engine 5.4；最后人工梳理日期 2026-09-10。

## 30 秒定位

- **项目总览与分层**：`docs/knowledge/ARCHITECTURE.md`
- **按功能找入口、状态所有者、调用链**：`docs/knowledge/SYSTEMS.md`
- **地图、Blueprint、Lua 绑定、配置、插件、数据文件**：`docs/knowledge/ASSETS_AND_CONFIG.md`
- **已发现的断链、重复实现和高风险点**：`docs/knowledge/RISKS_AND_GAPS.md`
- **AnimAgent 与 Fab（AI 资产管线 / 平台对接）**：`docs/knowledge/ANIMAGENT_AND_FAB.md`
- **UGC 专业化架构评审与迁移方案**：`docs/knowledge/UGC_ARCHITECTURE_REVIEW_2026-09-10.md`
- **机器生成的逐文件/符号索引**：`docs/knowledge/generated/SYMBOL_INDEX.md`
- **机器可读索引**：`docs/knowledge/generated/index.json`
- **可视化架构导航**：由本项目对应的 Codex Canvas 提供；Markdown 知识库仍是版本库内的事实来源。

## 项目一句话

这是一个 UE 5.4 的多人 FPS/撤离玩法原型，采用：

- C++：网络权威、GAS、武器/弹体、库存、关卡流程和引擎桥接；
- Blueprint：资产装配、组件配置、Widget 布局、UnLua 模块绑定；
- Lua/UnLua：UI、热更玩法表现、UGC 运行时编辑器、LLM Function Calling；
- DataAsset/DataTable/JSON：武器、物品、地图、弹道和 UGC 预制体配置；
- Wwise：音频集成，目前业务事件表大多仍为占位。

## 真正需要优先阅读的范围

1. `Source/FPS/`
2. `Content/Script/`
3. `Content/_FPS/`
4. `Content/_UGC/`
5. `Plugins/GamePlay/Source/`
6. `Config/`
7. `Tools/DataTableConverter/`

下列目录默认只看版本/接口边界，不全文重读：

- `Plugins/UnLua/`
- `Plugins/UnLuaExtensions/`
- `Plugins/UnLuaTestSuite/`
- `Plugins/Wwise/`
- `Plugins/WwiseNiagara/`
- `Plugins/WwiseSoundEngine/`
- `Content/FPS/`、`Content/ShootingAI/`、`Content/StarterContent/`、`Content/SpaceshipInterior/`
- `Plugins/UEEditorMCP/Python/.venv/`

## 当前架构主线

```text
输入资产 / Blueprint Defaults
        |
        v
AFPSPlayerController + AFPSCharacter
        |
        +--> PlayerState 上的 ASC + CombatAttributeSet
        |       |
        |       +--> Weapon GAS abilities --> AFPSWeaponBase --> AFPSProjectile
        |
        +--> UFPSWeaponSlotComponent --> 武器 Actor / 世界拾取物
        |
        +--> Lua PlayerController --> Lua UIManager --> UMG Widgets
        |
        +--> AUGCPlayerController
                +--> UUGCEditorBridge --> Lua EditorCore / SceneData
                +--> UUGCFunctionBridge --> Lua FunctionRegistry
                +--> UUGCHttpClient --> Lua LLMGateway
                +--> UUGCPCGBridge --> PCG
```

## 后续任务的读取策略

1. 先读本文件。
2. 按任务只读 `SYSTEMS.md` 中对应系统。
3. 用查询脚本定位符号和资产：

   ```powershell
   python Tools/ProjectIndex/query_index.py weapon reload
   python Tools/ProjectIndex/query_index.py --kind lua UGCSceneData
   python Tools/ProjectIndex/query_index.py --kind asset WBP_UGC
   ```

4. 只有索引显示不充分或代码已变化时，才打开具体源码。
5. 涉及 Blueprint 内部图、CDO 属性或组件层级时，需要 Unreal Editor 在线并通过 UEEditorMCP 查询；当前离线索引只确认了资产名、父类/绑定字符串和文件存在性。

## 刷新与校验

```powershell
python Tools/ProjectIndex/build_index.py
python Tools/ProjectIndex/build_index.py --check
```

- 第一条重建 `index.json` 和 `SYMBOL_INDEX.md`。
- 第二条不写文件，只检查索引是否因源码/配置变化而过期。
- 改动核心源码、Lua、Config、自研插件或核心资产后应刷新索引。

## 关键事实

- 主模块：`FPS`，运行时模块，UE 5.4。
- 核心规模：约 113 个 C++/Build 文件、13k 行；46 个 Lua 文件、9.7k 行。
- 默认启动/游戏地图：`/Game/_FPS/Level/Level_MainMenu/Level_LoginMap`。
- 默认全局 GameMode：`BP_MenuGameMode`。
- ASC 与战斗 AttributeSet 归属 `AFPSPlayerState`，Character 是 Avatar。
- 当前项目主 UI 路径实际由 Lua `Gameplay.Core.UIManager` 驱动；C++ `UFPSMenuSubsystem` 是并行实现，不能混为同一状态栈。
- UGC 已采用 `UGCDocument + UGCCommandBus + UGCWorldProjection`：Actor 上限 50，Undo/Redo 上限 64，项目保存为单一版本化 `*.ugc.json`，旧三文件格式仅保留读取兼容。
- UEEditorMCP 使用本机 TCP `127.0.0.1:55558`；本次建库时端口未在线，因此未读取 Blueprint 图内部拓扑。

## 维护原则

- 文档中的“已验证”来自源码、配置或离线资产字符串；“推断”必须显式标记。
- 不把 `README.pdf` 当作当前实现的唯一事实来源；它记录了历史设计，但多处已与代码漂移。
- 新增系统时同时更新 `SYSTEMS.md`，新增硬编码资产/数据路径时刷新机器索引。
- 不在知识库复制大段源码；记录职责、状态所有者、入口、关键不变量和文件位置。
