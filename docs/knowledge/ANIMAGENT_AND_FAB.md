# AnimAgent 与 Fab（AI 资产管线 / 平台对接）

> 状态：2026-09-18 首次成文（此前只存在于代码与机器索引里，`docs/` 零覆盖）。
> 依据：C++/Lua/INI/JSON 中的直接事实（标记为「已验证」）；`.uasset` 侧的组件挂载、UI 绑定等离线不可确认，统一列入「待验证」。
> 范围：`Source/FPS/AnimAgent/`、`Content/Script/Gameplay/AnimAgent/`、`Content/Script/Gameplay/Fab/`、`Content/Script/System/UI/Fab/`。

## 1. 定位

两条相互衔接、但状态归属不同的链路：

| 链路 | 内容 | 当前阶段 |
|---|---|---|
| **AnimAgent** | 本地/生成资产（GLB）→ 落盘 → 资产库 → 注册为 UGC 可放置物（`dyn:{uuid}`）→ 在 UGC 编辑器里摆放、存档、Undo/Redo | Phase L1（本地导入）已验证；Phase F 由 Fab 侧独立组件承担 |
| **Fab** | 平台对接：登录/注册、资产列表与详情、上传下载、AI 文生/图生 3D 任务；C++ REST 客户端 + UMG(CEF) 面板 | 路线 A（C++ 直连）+ 路线 B（UMG 内嵌网页）均已落地，端到端待编辑器/服务端验证 |

两者的交汇点：Fab 下载的资产与本地导入的资产**走同一条落盘与注册管线**（`Saved/AnimAgent/assets/{uuid}/` + `library.json` + `UGCPrefabRegistry.DynamicGLB`）。

## 2. 文件地图

### C++（`Source/FPS/AnimAgent/`）

| 文件 | 职责 |
|---|---|
| `AnimGen/AnimGenClient.h/.cpp` | `UAnimGenClient`（挂在 PlayerController 上的组件）。`ImportLocalGLB(路径, 显示名)`：校验扩展名 → 拷贝到 `Saved/AnimAgent/assets/{uuid}/source.glb` → 写 `meta.json`（uuid/name/source/source_note/original_path/created_at）→ 广播 `OnAssetImported`；`ExportLocalGLB`：回写 GLB 并附带 `.meta.json`；两个文件对话框方法为编辑器专属（见 §6.8） |
| `AnimImportBridge.h/.cpp` | `UAnimImportBridge`：用 **glTFRuntime** 解析 GLB → `UStaticMesh*`，维护 `uuid → mesh` 缓存（`FindCachedMesh`）；`ImportGLBAsync` 当前实际是**同步**加载（注释自陈） |
| `AnimAgentDynamicPlaceable.h` | `AAnimAgentDynamicPlaceable : AStaticMeshActor`：让 GLB 资产复用整套 UGC Placeable 基建（高亮/Gizmo/SceneData/存档/Undo）。设计为单一 native 类，spawn 时 mesh 为空，由 `SetDynMesh(Mesh, AssetUuid)` 注入；`SetDebugVisible`/`SetProgramID` 是空实现，避免 Lua 侧 pcall 失败 |
| `AnimAgentTypes.h` | `EAnimAssetSource{Local,Fab,Generated}`、`FAnimAssetRecord{uuid,name,GLBPath,Source,SourceNote,CreatedAtSeconds}` |
| `Fab/FabClientBridge.h/.cpp` | `UFabClientBridge`（挂在 PlayerController 上的组件）：**Auth** `Login/Register/LoginSimple/RegisterSimple/Logout/IsLoggedIn/GetAccessToken/GetRefreshToken`；**Asset** `ListAssets/GetAsset/DownloadAsset/UploadAsset/UploadModelSimple/UpdateAsset/DeleteAsset`；**AI** `CreateAiTextTask/CreateAiImageTask`(+Simple)；多播事件 `OnAuthChanged/OnAuthExpired/OnGlobalError/OnLoginCompleted/OnUploadCompleted/OnAiTaskCompleted` 等 |
| `Fab/FabConfig.h/.cpp` | `UFabConfig::Get()`：运行时配置 `Saved/Fab/config.json`（`BaseUrl`、请求/下载/上传超时、AI 轮询间隔 5s→封顶 15s、token refresh leeway 60s）。首次启动按 CDO 默认值落盘，**不热加载**，改完重启生效 |
| `Fab/FabTokenStore.h/.cpp` | 登录态 `Saved/Fab/token.dat`：`FFabTokenRecord{AccessToken,RefreshToken,AccessIssuedAtSec,AccessExpiresAtSec,User,SavedAtSec}` → UTF-8 JSON → XOR 混淆 → base64。注释明说"不是强加密"，只是防误传 |
| `Fab/FabUrlDispatcher.h` | 解析 `uefab://{action}?{k}={v}`：`IsFabScheme` / `Parse`；当前唯一 action 为 `download?id=N` → `UFabClientBridge` 下载链；预留 `logout`、`open-ugc` |
| `Fab/FabTypes.h` | 与后端契约 1:1 的类型（`EFabAssetType/Status`、`EFabUserRole`、`EFabAiTaskStatus`、`FFabUser`、`FFabAssetItem/Query/Patch`、`FFabDownloadResult/UploadRequest`、`FFabAiTask`…）。注释指明对齐 `Backend/fab/Docs/v2.0.0.md` |

### Lua

| 文件 | 职责 |
|---|---|
| `Gameplay/AnimAgent/AnimAgentCore.lua` | 顶层编排器：`Init(PC)` 找 `UAnimGenClient`（必需，找不到会给出"去 PC 蓝图 AddComponent"的提示）与 `UAnimImportBridge`（可选）；API `ImportLocal/ExportLocal/ListAssets/RemoveAsset`；`_processImportedAsset` 做三件事（见 §3） |
| `Gameplay/AnimAgent/AnimAssetLibrary.lua` | 资产库，落盘 `Saved/AnimAgent/library.json`；`Add/Remove/Find/GetAll(时间倒序)/Search(名或 prompt)/Save/Load/ClearAll` |
| `Gameplay/Fab/FabClient.lua` | Fab 门面：`Init(PC)` → 取 `UFabClientBridge`（必需）与 `UAnimImportBridge`（可选）；`IsLoggedIn/GetUser/GetAccessToken/GetRefreshToken/Logout/GetDownloadedFabIds`；`RegisterDownloadedAsset(downloadResult, meta)` 把 Fab 下载结果接入本地管线 |
| `System/UI/Fab/WBP_FabLogin.lua` | 登录/注册面板（**零 BP 节点**：Lua 直调 `LoginSimple/RegisterSimple`，订阅完成多播；成功后 `CreateWidget WBP_FabPanel` 并自移除） |
| `System/UI/Fab/WBP_FabPanel.lua` | Fab 面板：控件树 `w_border_Root / w_panel_Title / w_text_Title / w_btn_Close / w_browser_Web(CEF) / w_panel_Status / w_text_Status / w_bar_Progress`；向网页注入 access_token cookie 与"已在 Project 中"的 localStorage |
| `System/UI/Fab/WBP_FabPanel/lua.lua` | 兼容 shim：某处 BP 的 `GetModuleName` 被写成 `System.UI.Fab.WBP_FabPanel.lua`，此文件仅转发到正式模块 |

### 依赖插件（均在 `FPS.uproject` 中启用）

- `glTFRuntime`：GLB 解析（`AnimImportBridge.cpp` 直接 include 其头文件）。
- `WebBrowserWidget`：Fab 面板的 CEF 内嵌网页。

## 3. 流程一：本地 GLB 导入 → 成为可放置物（已验证）

```text
WBP_UGCEditor「导入 GLB」按钮
  -> _ensureAnimAgent(pc)                     -- 初始化 Core
  -> AnimAgentCore:ImportLocal(filePath, name)
  -> UAnimGenClient::ImportLocalGLB           -- 扩展名校验 + 拷贝 + 写 meta.json
       Saved/AnimAgent/assets/{uuid}/source.glb
       Saved/AnimAgent/assets/{uuid}/meta.json
  -> AnimAgentCore:_processImportedAsset
       ① AnimAssetLibrary:Add(...)             -- 落 Saved/AnimAgent/library.json
       ② UGCPrefabRegistry:RegisterDynamicGLB  -- id "dyn:{uuid}"，GetKind()=="dynamic_glb"
       ③ UAnimImportBridge::ImportGLBAsync     -- 预热 mesh（同步实现）
```

放置与读档（与 UGC 编辑链的接缝）：

```text
UGC 编辑器从 PrefabRegistry 取 dyn:{uuid}
  -> SceneData 的 spawn 路径（CreateEntity / RestoreEntity / DeserializePackageTable）
  -> spawn 后触发 SetActorCreatedHook
  -> UGCEditorCore:_InjectDynMesh(actor, prefabName)
       PrefabRegistry.GetKind(prefabName) == "dynamic_glb"
       -> UAnimImportBridge:FindCachedMesh(uuid) 或 ImportGLBAsync
       -> AAnimAgentDynamicPlaceable::SetDynMesh(mesh, uuid)
```

要点：dyn 资产的 mesh 注入**必须挂在 spawn 钩子上**（而不是某个调用点），否则创建、Undo/Redo、读档三条路径表现不一致。2026-09-18 修复合并损伤时，把钩子显式接进了上述三条 spawn 路径。

## 4. 流程二/三：Fab 下载与 AI 生成

```text
【下载】
WBP_FabPanel 内网页按钮 -> uefab://download?id=N
  -> UFabUrlDispatcher:IsFabScheme / Parse
  -> UFabClientBridge::DownloadAsset(AssetId)         -- 取 presigned URL 后直连 MinIO 流式下载
       Saved/AnimAgent/assets/{uuid}/
  -> FabClient:RegisterDownloadedAsset(downloadResult, meta)
       -> AnimAssetLibrary + UGCPrefabRegistry（provider="fab"）

【AI 生成】
LLM 工具 fab_create_ai_model / fab_create_ai_model_from_image
  -> UFabClientBridge::CreateAiTextTask / CreateAiImageTask   -- provider = Meshy（服务端沉淀为 Fab 资产）
  -> fab_check_ai_task 轮询任务状态（起始 5s，退避封顶 15s；结果同时写日志 LogFabClient 并广播 OnAiTaskCompleted）
  -> 完成后走上面的下载链进入 Project
```

LLM 可用工具（`UGCFunctionRegistry`）：`fab_publish_local_asset`（发布本地 dyn 资产，可传 uuid 或按 name 搜索）、`fab_create_ai_model`、`fab_create_ai_model_from_image`、`fab_check_ai_task`，以及 `begin_batch` / `end_batch`（具名 batch，见 §5）。

## 5. 硬编码约定与落盘布局

| 类别 | 值 |
|---|---|
| 资产目录 | `Saved/AnimAgent/assets/{uuid}/source.glb`、同目录 `meta.json` |
| 资产库 | `Saved/AnimAgent/library.json` |
| Fab 配置 / 登录态 | `Saved/Fab/config.json`、`Saved/Fab/token.dat` |
| 资产 uuid | `FGuid::NewGuid().ToString(EGuidFormats::DigitsWithHyphensLower)` |
| Prefab id / kind | `dyn:{uuid}`、`GetKind() == "dynamic_glb"` |
| 具名 batch | `batch_<name>`（`begin_batch`/`end_batch`，同名复用，存 Document 的 generatedGroups，可存档往返） |
| URL scheme | `uefab://<action>?k=v`（当前仅 `download`） |
| 组件挂载 | PlayerController 上：`UAnimGenClient`（本地导入必需）、`UAnimImportBridge`（可选，缺则只登记元数据）、`UFabClientBridge`（Fab 必需）——**蓝图中配置，待编辑器确认** |

## 6. 风险、缺口与漂移

> 前三条是本次成文时新发现的问题，建议单独排期。

1. **【安全·高】默认 BaseUrl 是明文 HTTP 的公网 IP**：`UFabConfig` CDO 默认 `http://111.229.172.143:8765`（`FabConfig.cpp:18`）。登录口令（`LoginSimple/RegisterSimple`）与 token 刷新都会走明文；应改 https 或至少限制到内网/VPN，并把它从 CDO 移出到环境配置。
2. **【安全·中】token.dat 非加密**：UTF-8 JSON → XOR → base64（`FabTokenStore.h` 自陈"不是强加密"）。Windows 下可替换 DPAPI。
3. **【安全·中】下载无完整性校验**：未发现 checksum / 签名 / 大小校验（`Fab/*` 全文 grep 无命中）。下载目标在用户可写的 `Saved/`，内容随后被 glTFRuntime 解析并进场景。
4. **【漂移】`AnimImportBridge.h` 顶部注释**仍写"当前 cpp 仅留 stub，待 glTFRuntime 安装后填充"，而 `.cpp` 已真实实现（glTFRuntime 解析 + 静态网格构建 + 缓存）。
5. **【漂移】`AnimGenClient.h` 顶部注释**说"Phase F 会在此组件加 Fab REST 客户端"，实际由独立的 `UFabClientBridge` 承担。
6. **【命名】`ImportGLBAsync` 实为同步**：`ImportGLBAsync` 内部直接 `glTFLoadAssetFromFilename` 同步解析，注释也说"后续若资产规模变大再升级到异步"。
7. **【耦合】入口都在 UGC 编辑器里**：GLB 导入按钮与 Fab 面板都由 `WBP_UGCEditor` 创建（面板类路径 `/Game/_UGC/UI/WBP_FabPanel`），AnimAgent/Fab 自身没有独立 UI 入口。
8. **【编辑器专属】文件对话框**：`AnimGenClient` 的 `OpenFileDialog/SaveFileDialog` 已按 T19 加 `#if WITH_EDITOR`（非编辑器返回空并告警），运行时导入需调用方直接给路径。
9. **【占位】`System/UI/Fab/WBP_FabPanel/lua.lua`** 是为兼容某处 BP 的 `GetModuleName` 误写而加的转发 shim；根因修掉后可删。

## 7. 待验证（需要编辑器 / 服务端）

- PC 蓝图（`BP_UGCPlayerController` / `BP_FPSPlayerControll`）上 `UAnimGenClient`、`UAnimImportBridge`、`UFabClientBridge` 是否已挂载、是否用到 `GetAnimGenClient` 蓝图 getter。
- `WBP_FabLogin` / `WBP_FabPanel` 的控件命名与 `Is Variable` 是否与 Lua 期望一致（BindWidget 名称完整性）。
- 有 token.dat 时的登录态恢复、401 单飞 refresh 与并发重放。
- Fab 端到端：登录 → 列表 → 下载 → 进入 Project → 发布本地资产 → AI 生成任务闭环。
- dyn 资产在关卡存档往返、Undo/Redo、以及 `UGCPlaceableConfig.lua`（打包 Catalog）里的可见性——当前 Catalog 只登记 Box/Sphere/TriggerZone，**Shipping 下 dyn 资产是否可用需实测**。
