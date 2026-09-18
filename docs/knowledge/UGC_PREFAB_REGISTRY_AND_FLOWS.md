# UGC Prefab Registry 与放置/生成链路

> 状态：2026-09-18 首次成文；与 HEAD `84c1e4e`（含 `43ad6bf` 的 UGCSceneData 重建）后的代码一致。
> 依据：Lua/C++ 源码中的直接事实（带 `文件:行号`），已标注「已验证」；编辑器内端到端行为（PIE 实际渲染、面板刷新、Fab 下载回调）离线不可确认，统一列入「待验证」。
> 范围：`UGCPrefabRegistry` 及其上下游（C++ 桥 → Lua 服务 → UI）。Fab 平台服务端细节见 `ANIMAGENT_AND_FAB.md`。

## 1. Registry 是什么、不是什么

`UGCPrefabRegistry` 是**放置物登记表 + 路径解析器**，不是资产管理器：它不持有资产本体（蓝图类/UStaticMesh 在 UE 里、GLB 在 `Saved/AnimAgent/` 下），只维护「id → 类路径/元数据 + 分类顺序」。

它同时服务两条内容轨，二者共用同一张 `Prefabs` 表（UI 也混在同一面板）：

| 轨 | 内容 | 注册入口 | 生存期 |
|---|---|---|---|
| A 出厂 Catalog | 设计师随包发布的可放置物（当前 3 项） | `LoadDynamic`（`UGCPrefabRegistry.lua:119-158`） | 进程内重建、打包后仅剩 `UGCPlaceableConfig.lua` 硬编码项 |
| B 运行时动态资产 | 本地导入 / Fab 下载的 GLB（`dyn:{uuid}`） | `RegisterDynamicGLB`（`:243-278`） | **仅内存**（见 §5 缺口 1） |

四块状态（`:14-25`）：

| 字段 | 内容 |
|---|---|
| `Prefabs[id]` | id → 类路径。dyn 条目固定为 `/Script/FPS.AnimAgentDynamicPlaceable`（`:260`） |
| `Meta[id]` | `{label, category, description, tags}`：UI 按钮文案 + LLM 语义描述来源 |
| `Categories[]` | 有序分类（UI 面板按此顺序渲染） |
| `DynamicGLB[dyn:id]` | `{uuid, name, glb_path, provider, prompt}` 明细 |

- 写口 2 个：`LoadDynamic(bridge)` = ⓪ 打包目录 `UGCPlaceableConfig.lua`（`:9-28`，3 项）∪ ① `bridge:FindFilesInDirectory` 扫 `Content/_UGC/Placeables/*.uasset`（仅 PIE，打包返回空）→ 去重 → `buildRegistry`（`:76-104`）；`RegisterDynamicGLB(def)` → 追加「AI 生成」分类。
- 读口：`GetPath`、`IsValid`、`GetKind`（`"blueprint"` / `"dynamic_glb"`，双轨分派开关）、`GetMeta`、`GetDynamicGLB`、`ListIDs`、`GetSemanticDesc`、`ListDynamicGLB`。
- 安全口：`AddCustomPrefab`（玩家任意蓝图路径）已禁用（`:212-215`）、`SaveDynamic` 为 no-op（`:164-166`）。

## 2. 分层职责与上下家

### C++ 基建层（挂在 `AUGCPlayerController` 上的组件 + native actor）

| 类 | 职责 | 上游 | 下游 |
|---|---|---|---|
| `UUGCEditorBridge` | 唯一世界操作口：`SpawnPlaceable`（路径白名单校验 `UGCEditorBridge.cpp:25-26`）/ `DestroyActor` / `SetActorTransform` / `LineTraceScreen` / `LineTraceScreenPosition` / `SetActorHighlight` / 原生文件对话框 / `FindFilesInDirectory`（仅 Editor，`UGCEditorBridge.h:111-119`） | EditorCore、WorldProjection、WBP | UWorld |
| `UAnimGenClient` | GLB 文件进出：`ImportLocalGLB`（落盘 `Saved/AnimAgent/assets/{uuid}/source.glb` + `meta.json`，同步返回 uuid）/ `ExportLocalGLB` / `OpenFileDialog` | AnimAgentCore、"+ GLB" 按钮 | 磁盘 |
| `UAnimImportBridge` | GLB → `UStaticMesh`：`ImportGLBAsync`（当前实为同步）/ `FindCachedMesh` | AnimAgentCore 预载、`_InjectDynMesh` | 渲染资源 |
| `AAnimAgentDynamicPlaceable` | dyn 宿主壳：`SetDynMesh(mesh, uuid)` + `SetProgramID`/`SetSourceEntityID`/`SetDebugVisible` | EditorCore / spawn 钩子 | `AStaticMeshActor` |
| 旁支 | `UGCStorageBridge`（原子文件 IO）、`UGCHttpClient`（HTTP）、`UGCEventRouterSubsystem`（事件路由）、Fab 桥（`FabClientBridge`） | — | — |

### Lua 数据/登记层

| 类 | 职责 | 上游 | 下游 |
|---|---|---|---|
| `UGCPrefabRegistry` | 见 §1 | 资产来源（Lua 表 / PIE 扫目录 / 导入回调） | UI、EditorCore、WorldProjection、FunctionRegistry |
| `AnimAssetLibrary` | dyn 资产账本（`Saved/AnimAgent/library.json`，`:50-53/130-140`）：Add/Remove/Search/GetAll | AnimAgentCore、FabClient | 磁盘 |
| `UGCDocument` + `UGCCommandBus` | 纯数据真相源 + 命令事务（Undo/Redo/Revision） | SceneData、FunctionRegistry | Projection |
| `UGCSceneData`（`43ad6bf` 重建后） | 兼容 facade：`Init:368` / `SetActorCreatedHook:384` / `ExecuteCommand:440` / `CreateActor:524` / 具名 batch `BeginNamedBatch:593`→`Document:CreateGroup` / 序列化 `SerializePackageTable:719`、`DeserializeProgramsJSON:856`（旧格式只读兼容） | PlayerController、EditorCore、UI、FunctionRegistry | CommandBus、Document、Projection、Persistence |
| `UGCWorldProjection` | **唯一持有 SceneID → Actor 引用的 Lua 层**（`Spawn:38-53`，经 `GetPath(record.prefabName)` 解析路径） | SceneData、Document | EditorBridge |
| `UGCEditorCore` | Idle/Edit/Play 状态机 + 放置交互（ghost/吸附/Gizmo/拖拽/选中）。`Init:306-330` 三件事：`SceneData:Init` → `LoadDynamic` → 挂 actor-created 钩子（dyn 注 mesh） | PlayerController（Tick 驱动）、WBP | EditorBridge、SceneData、Registry |
| `UGCPersistence` | `*.ugc.json` 原子读写（temp→verify→rename） | WBP 保存/加载 | 磁盘 |
| `UGCFunctionRegistry`/`LLMGateway`/`Generators` | AI 面：`place_object:277-319`（enum=`Registry.ListIDs()`、描述=`GetSemanticDesc()`）、`fab_publish_local_asset:510`、`fab_create_meshy_text_to_3d:544`/`image_to_3d:564` | AI 对话 | SceneData、Registry |
| `AnimAgentCore` / `FabClient` | 两条导入编排：本地 GLB（`ImportLocal:112-128`、`_processImportedAsset:152-196`）/ Fab 云下载（`RegisterDownloadedAsset:170-215`） | UI、AI 函数 | C++ 组件、Library、Registry |

### UI 层

- `WBP_UGCEditor.lua`：预制体面板渲染（`BuildPrefabList:229-323` 读 `Categories` 生成标题+按钮）、"+ GLB" 按钮（`_BuildImportGLBButton:348-362`）、保存/加载/试玩。
- `WBP_UGCBlueprintEditor`/`Node`/`WireOverlay`、`WBP_FabPanel`（蓝图侧触发 Fab 下载回调，待验证）。

## 3. 四条链路（验证于代码，未经 PIE 实测）

```
A 建按钮（启动）
UGCPlayerController:BeginPlay（接线见 UGCPlayerController.lua:34-38）
  → EditorCore:Init → SceneData:Init(bridge)
                   → Registry:LoadDynamic(bridge)
                       ⓪ UGCPlaceableConfig.lua 硬编码目录（打包环境唯一真相）
                       ① bridge:FindFilesInDirectory 扫 Content/_UGC/Placeables/*.uasset（仅 PIE）
                       → 去重合并 → buildRegistry 建 Prefabs/Meta/Categories
                   → SceneData:SetActorCreatedHook(dyn 注 mesh)
WBP_UGCEditor 打开 → BuildPrefabList 读 Categories → 渲染分类标题 + 按钮

B 点击放置
按钮 OnPressed → OnClickPrefab → EditorCore:SelectPrefab(id)
  → Registry.IsValid / GetPath → bridge:SpawnPlaceable 出 ghost（隐藏位）
  → 每 Tick UpdateGhostPosition（射线 + 网格吸附，EditorCore.lua:494-512）
  → 点击落点 → OnViewportClick → SceneData:CreateActor
       → CommandBus 提交 CreateEntity → Document 增实体
       → WorldProjection:Spawn（GetPath → SpawnPlaceable → 记 actor 引用）
       → actor-created 钩子（GetKind=="dynamic_glb" → _InjectDynMesh）
  → 自动重生 ghost 保持连放；ESC 退出

C 生成 → 注册 → 按钮
C1 本地："+ GLB" → OpenFileDialog → AnimAgentCore:ImportLocal
      → C++ 落盘 Saved/AnimAgent/assets/{uuid}/ → Library:Add
      → ★ Registry:RegisterDynamicGLB（Prefabs[dyn:uuid]=dynamic placeable、分类"AI 生成"）
      → UI RebuildPrefabList（WBP_UGCEditor.lua:388）→ 新按钮出现
C2 云：AI 对话 → fab_create_meshy_* → FabClient 提交/轮询/下载
      → ★ FabClient:RegisterDownloadedAsset → 同一个 RegisterDynamicGLB → 同上
  放置 dyn 资产：ghost 是空壳 → _InjectDynMesh（FindCachedMesh / ImportGLBAsync 同步）
      → 落点后 SceneData 钩子再注一次（读盘 / Undo / Redo 路径同样走钩子）

D 存档/恢复（43ad6bf 重建后贯通）
保存：Persistence.SaveProject → SceneData 序列化 → temp→verify→rename
恢复：DeserializePackageTable:728 → RestoreEntity → Projection:Spawn（按 prefabName 查路径）
```

## 4. 与「上帝类 Scene」原型模型的差异

| 原型理解 | 现状 | 差异 |
|---|---|---|
| C++ 做底层基建给 Lua | 一致 | EditorBridge=手；AnimGenClient/ImportBridge=dyn 资产进出；DynamicPlaceable=dyn 宿主 |
| 上帝类 Scene 生成 UI 的 prefab 按钮 | 按钮由 `WBP_UGCEditor:BuildPrefabList` 直接读 `Registry.Categories` 渲染；Scene 只管场景实体且已降级为 facade | 原型"上帝类"职责现拆为 4 份：数据真相=Document、实体↔actor=WorldProjection、交互状态机=EditorCore、按钮渲染=WBP |
| Agent 调接口 / 走 meshy 生成 | 两条都在：本地导入 + Fab/Meshy 云任务 | — |
| 回调时上帝类创建按钮 | 回调只注册进 Registry；按钮由 UI 自己 `RebuildPrefabList` 重建，且**无变更事件** | 见 §5 缺口 2 |

### T5 在这张地图上的位置

T5（`UGC_REMAINING_TODO.md`）只替换链路 A 中出厂目录的来源（`:LoadDynamic` 的 ⓪① 两段：Lua 硬编码 + PIE 物理扫目录 → `UUPrimaryDataAsset` + AssetManager 扫描），B/C/D 不受影响。AssetManager 属于「出厂轨」的目录服务与加载器；玩家内容永远不走它（安全边界，`UGCPrefabRegistry.lua:152-154`）。现状 bug：打包后 Catalog 只剩硬编码 3 项（`Content/_UGC/Placeables/*.uasset` 扫不到）。

## 5. 已知缺口（含证据）

1. **dyn 条目仅内存，重启后不重注册**：`SaveDynamic` 为 no-op（`:164-166`）；`RegisterDynamicGLB` 全仓调用点只有两处——导入完成（`AnimAgentCore.lua:182`）与 Fab 下载完成（`FabClient.lua:200`），均为事件后即时注册；`AnimAssetLibrary:Load`（`:140+`）只填库、不回注册 Registry。
   后果：重启后旧存档里的 `dyn:` 实体恢复失败（`UGCWorldProjection.lua:40-41` 返回「预制体路径不存在」），面板「AI 生成」分类为空。
2. **Registry 无变更通知**：按钮刷新依赖调用方自觉（导入路径在 `WBP_UGCEditor.lua:388` 手动 `RebuildPrefabList`；Fab/AI 路径的刷新挂在上层，待验证）。建议补 `Registry.OnChanged` 回调。
3. **T5 范围**：见 §4；仅缺口 1、2 是纯 Lua 小改，不依赖编辑器。

## 6. 待验证

- PIE 端到端：`BuildPrefabList` 实际渲染结果、ghost 跟随与吸附、dyn mesh 注入、Undo/Redo/读盘路径下的 dyn 恢复。
- Fab 链路：下载完成事件是否确实调用到 `FabClient:RegisterDownloadedAsset`（触发方在 `WBP_FabPanel` 蓝图侧，离线不可确认）。
- 打包行为：`FindFilesInDirectory` 非 Editor 返回空、Shipping 目录仅 3 项（由代码与注释为证，未做打包实测）。

## 7. 关联

- `docs/knowledge/ANIMAGENT_AND_FAB.md`：dyn 资产管线与 Fab 对接细节。
- `docs/knowledge/SYSTEMS.md` §8：UGC 运行时编辑器总览。
- `docs/knowledge/UGC_ARCHITECTURE_REVIEW_2026-09-10.md` §4.5：Prefab Catalog 资产化改造方案。
- `docs/knowledge/UGC_REMAINING_TODO.md`：T5（Prefab 迁移）与 T19（整体验收）。
- 提交 `43ad6bf`：UGCSceneData 重建（本文件的代码基线前提）。
