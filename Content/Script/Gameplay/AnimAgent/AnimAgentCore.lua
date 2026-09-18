--[[
    AnimAgentCore.lua
    AnimAgent 顶层编排器（Phase L1：本地导入）

    职责：
    - 持有 UAnimGenClient（C++ 组件）的引用
    - 订阅 OnAssetImported / OnAssetImportFailed
    - 资产导入完成后：
        ① 写入 AnimAssetLibrary
        ② 注册到 UGCPrefabRegistry 的 dyn:{uuid} 命名空间
        ③ （可选）触发 ImportBridge 加载为 UStaticMesh，缓存待用
    - 提供 Lua 侧 API 给 UI 调用：
        Core:ImportLocal(filePath, name)  → uuid
        Core:ExportLocal(uuid, targetPath) → bool
        Core:ListAssets()
        Core:RemoveAsset(uuid)

    依赖：
    - PlayerController 必须挂 UAnimGenClient（蓝图配置）
    - 可选挂 UAnimImportBridge（无则跳过 mesh 加载，仅做元数据登记）
]]

local Library  = require("Gameplay.AnimAgent.AnimAssetLibrary")
local Registry = require("Gameplay.UGC.UGCPrefabRegistry")

local Core = {}

local _pc      = nil
local _client  = nil   -- UAnimGenClient*
local _import  = nil   -- UAnimImportBridge*  (可选)
local _initialized = false

--============================================================
-- 初始化
--============================================================

--- @param playerController APlayerController*
--- @param opts? { import_bridge?: UAnimImportBridge* }
function Core:Init(playerController, opts)
    if _initialized then return true end
    if not playerController then
        print("[AnimAgentCore] Init 失败：playerController 为 nil")
        return false
    end

    -- 优先用 GetAnimGenClient 蓝图 getter（需在 BP 里实现），失败兜底 GetComponentByClass
    local client = nil
    pcall(function() client = playerController:GetAnimGenClient() end)
    if not client then
        pcall(function() client = playerController:GetComponentByClass(UE.UAnimGenClient) end)
    end

    -- UnLua 的 GetComponentByClass 在没找到时可能返回"包了 nullptr 的 wrapper"而不是 nil；
    -- 用 IsValid 二次校验
    local valid = false
    if client then
        local ok, isValid = pcall(function() return UE.UKismetSystemLibrary.IsValid(client) end)
        valid = ok and isValid
    end
    if not valid then
        print("[AnimAgentCore] Init 失败：PlayerController 上没找到 UAnimGenClient 组件")
        print("[AnimAgentCore]   → 请打开 PlayerController 蓝图，Add Component 加 AnimGenClient")
        print("[AnimAgentCore]   → 当前 PlayerController 类: " .. tostring(playerController:GetClass():GetName()))
        return false
    end

    -- 同样 try import bridge（蓝图里挂没挂都能用，没挂就 nil，跳过 mesh 预加载）
    local importBridge = opts and opts.import_bridge or nil
    if not importBridge then
        pcall(function() importBridge = playerController:GetComponentByClass(UE.UAnimImportBridge) end)
        if importBridge then
            local ok, isValid = pcall(function() return UE.UKismetSystemLibrary.IsValid(importBridge) end)
            if not (ok and isValid) then importBridge = nil end
        end
    end

    _pc     = playerController
    _client = client
    _import = importBridge

    Library:Init()

    -- 注：UnLua 的 multicast delegate :Add 要求 self 必须是 UObject，Core 是 Lua table 不行。
    -- 当前 ImportLocalGLB 是同步实现，调用方拿到 uuid 立刻自己处理（见 ImportLocal 函数），
    -- 因此不订阅 OnAssetImported / OnAssetImportFailed。
    -- 后续 Fab 阶段如需异步事件，应让 PlayerController 作为接收 UObject 中转到 Lua。

    _initialized = true
    print(string.format("[AnimAgentCore] 初始化完成（local-import 模式，import_bridge=%s）",
        importBridge and "yes" or "no"))
    return true
end

function Core:Shutdown()
    if not _initialized then return end
    _client, _pc, _import = nil, nil, nil
    _initialized = false
end

function Core:IsReady()
    return _initialized and _client ~= nil
end

--============================================================
-- 公共 API
--============================================================

--- 从本地 .glb 文件导入（同步流程：拷贝 → 写库 → 注册 → 预加载 mesh）
--- @param filePath string  绝对路径
--- @param desiredName? string
--- @return string uuid（失败返回 ""）
function Core:ImportLocal(filePath, desiredName)
    if not self:IsReady() then
        print("[AnimAgentCore] ImportLocal 失败：未初始化")
        return ""
    end
    if not filePath or filePath == "" then return "" end

    local uuid = _client:ImportLocalGLB(filePath, desiredName or "")
    if not uuid or uuid == "" then return "" end

    -- C++ 已经把 source.glb + meta.json 落在 Saved/AnimAgent/assets/{uuid}/
    local glbPath = string.format("%sSaved/AnimAgent/assets/%s/source.glb",
        UE.UKismetSystemLibrary.GetProjectDirectory(), uuid)

    self:_processImportedAsset(uuid, glbPath, desiredName or "")
    return uuid
end

--- 导出到本地路径
function Core:ExportLocal(uuid, targetPath)
    if not self:IsReady() or not uuid or uuid == "" then return false end
    return _client:ExportLocalGLB(uuid, targetPath or "")
end

--- 列出已导入资产（按时间倒序）
function Core:ListAssets()
    return Library:GetAll()
end

--- 删除资产（仅 Library / Registry 元数据；不删 Saved 目录文件）
function Core:RemoveAsset(uuid)
    if not uuid or uuid == "" then return false end
    Registry:RemovePrefab("dyn:" .. uuid)
    return Library:Remove(uuid)
end

--============================================================
-- 内部：导入完成后的统一处理
--============================================================

function Core:_processImportedAsset(uuid, glbPath, desiredName)
    -- ① 优先用 desiredName，否则解析 meta.json 取显示名
    local name = desiredName ~= "" and desiredName or uuid
    local sourceNote = ""
    pcall(function()
        local metaPath = glbPath:gsub("source%.glb$", "meta.json")
        local f = io.open(metaPath, "r")
        if f then
            local content = f:read("*a")
            f:close()
            local json = require("Util.json")
            local meta = json.decode(content)
            if meta then
                if desiredName == "" then name = meta.name or name end
                sourceNote = meta.source_note or ""
            end
        end
    end)

    -- ② 写入资产库
    Library:Add({
        uuid       = uuid,
        name       = name,
        prompt     = sourceNote,
        provider   = "local",
        glb_path   = glbPath,
        created_at = os.time(),
    })

    -- ③ 注册到 UGCPrefabRegistry（出现在 UGC 编辑器的"AI 生成"分类下）
    Registry:RegisterDynamicGLB({
        uuid     = uuid,
        name     = name,
        glb_path = glbPath,
        provider = "local",
        prompt   = sourceNote,
    })

    -- ④ 让 ImportBridge 预加载 mesh（首次放置时无 IO 卡顿）
    if _import then
        pcall(function() _import:ImportGLBAsync(uuid, glbPath) end)
    end

    print(string.format("[AnimAgentCore] 资产已就绪 uuid=%s name=%s", uuid, name))
end

return Core
