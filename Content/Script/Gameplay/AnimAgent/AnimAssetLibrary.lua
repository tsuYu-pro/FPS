--[[
    AnimAssetLibrary.lua
    本地"我的资产"索引 —— Phase 1 极简实现

    职责：
    - 保存玩家本地生成 / 导入的 3D 资产元数据
    - 持久化到 Saved/AnimAgent/library.json
    - 提供 Add / Remove / Find / List / Save / Load API

    资产记录 schema：
    {
        uuid       = "xxx-xxx-xxx",          -- 同 AnimGenJob.JobUuid
        name       = "fire sword",            -- 玩家可改写
        prompt     = "a glowing fire sword",
        provider   = "meshy" | "tripo" | "mock" | "import",
        glb_path   = "Saved/AnimAgent/assets/{uuid}/source.glb",
        thumb_path = "Saved/AnimAgent/assets/{uuid}/thumb.png",  -- 可选
        created_at = 1701234567,              -- unix timestamp
        tags       = { "weapon", "fire" },    -- 可选
    }

    用法：
        local Library = require("Gameplay.AnimAgent.AnimAssetLibrary")
        Library:Init()
        Library:Add({ uuid=..., name=..., prompt=..., glb_path=... })
        local list = Library:GetAll()
]]

local json = require("Util.json")

local Library = {}
Library.__index = Library

local _entries  = {}        -- uuid → record
local _filePath = nil
local _initialized = false

local function _getSavedDir()
    return UE.UKismetSystemLibrary.GetProjectDirectory() .. "Saved/AnimAgent/"
end

local function _ensureDir()
    pcall(function() UE.UKismetSystemLibrary.MakeDirectory(_getSavedDir()) end)
end

--============================================================
-- 初始化
--============================================================

function Library:Init()
    if _initialized then return end
    _filePath = _getSavedDir() .. "library.json"
    self:Load()
    _initialized = true
    print(string.format("[AnimAssetLibrary] 初始化完成，记录数=%d", self:Count()))
end

function Library:IsInitialized()
    return _initialized
end

--============================================================
-- 增删查
--============================================================

--- 新增 / 更新一条记录（按 uuid 覆盖）
function Library:Add(record)
    if type(record) ~= "table" or not record.uuid or record.uuid == "" then
        print("[AnimAssetLibrary] Add 失败：缺少 uuid")
        return false
    end
    record.created_at = record.created_at or os.time()
    record.tags = record.tags or {}
    _entries[record.uuid] = record
    self:Save()
    return true
end

function Library:Remove(uuid)
    if not _entries[uuid] then return false end
    _entries[uuid] = nil
    self:Save()
    return true
end

function Library:Find(uuid)
    return _entries[uuid]
end

--- 返回所有记录的拷贝（按 created_at 倒序）
function Library:GetAll()
    local list = {}
    for _, v in pairs(_entries) do
        table.insert(list, v)
    end
    table.sort(list, function(a, b)
        return (a.created_at or 0) > (b.created_at or 0)
    end)
    return list
end

function Library:Count()
    local n = 0
    for _ in pairs(_entries) do n = n + 1 end
    return n
end

--- 按 prompt / name 模糊匹配
function Library:Search(keyword)
    if not keyword or keyword == "" then return self:GetAll() end
    local kw = string.lower(keyword)
    local matched = {}
    for _, v in pairs(_entries) do
        local name = string.lower(v.name or "")
        local prompt = string.lower(v.prompt or "")
        if string.find(name, kw, 1, true) or string.find(prompt, kw, 1, true) then
            table.insert(matched, v)
        end
    end
    table.sort(matched, function(a, b)
        return (a.created_at or 0) > (b.created_at or 0)
    end)
    return matched
end

--============================================================
-- 持久化
--============================================================

function Library:Save()
    if not _filePath then return end
    _ensureDir()
    local f = io.open(_filePath, "w")
    if f then
        f:write(json.encode(_entries))
        f:close()
    end
end

function Library:Load()
    _entries = {}
    if not _filePath then return false end
    local f = io.open(_filePath, "r")
    if not f then return false end
    local content = f:read("*a")
    f:close()
    local data = json.decode(content)
    if type(data) == "table" then
        _entries = data
        return true
    end
    return false
end

--- 调试用：清空所有
function Library:ClearAll()
    _entries = {}
    self:Save()
end

return Library
