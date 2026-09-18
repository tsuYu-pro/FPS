--[[
    UGCSceneData.lua

    Compatibility facade over the professional UGC foundation:
      - UGCDocument owns pure serializable state (no UObject references)
      - UGCWorldProjection owns Entity -> Actor runtime references
      - UGCCommandBus is the only mutation/undo boundary

    Existing UI, LLM, generators, and EditorCore APIs are preserved while they
    migrate to command-first calls.
]]

local PrefabRegistry = require("Gameplay.UGC.UGCPrefabRegistry")
local json = require("Util.json")
local Log = require("Gameplay.UGC.UGCLog")
local Document = require("Gameplay.UGC.UGCDocument")
local CommandBus = require("Gameplay.UGC.UGCCommandBus")
local WorldProjection = require("Gameplay.UGC.UGCWorldProjection")

local SceneData = {}
SceneData.__index = SceneData

local _document = nil
local _projection = nil
local _commandBus = nil
local _bridge = nil
local _listeners = {}
local _externalRestorers = {}
local _externalDestroyers = {}
local _worldRuleAdapter = nil
local _notificationBuffer = nil

-- post-spawn 钩子：function(actor, prefabName)
-- 所有从 PrefabRegistry 路径 spawn 的 actor 都会触发一次；创建 / 恢复 / Undo / Redo / 读盘
-- 都汇到下面三处 spawn 点。AnimAgent 的 dynamic_glb 资产靠它注入 UStaticMesh。
local _onActorCreated = nil

-- begin_batch / end_batch 显式管理的具名 batch：跨多次原子/生成器调用共享同一 batchID
local _activeBatch = nil

local function fireActorCreated(actor, prefabName)
    if _onActorCreated and actor then
        pcall(_onActorCreated, actor, prefabName)
    end
end

local ACTOR_MAX = 50
local HISTORY_LIMIT = 64

local function dataToTransform(data)
    return WorldProjection.ToTransform(data)
end

local function transformToData(transform)
    return WorldProjection.ToData(transform)
end

local function copy(value)
    return Document.DeepCopy(value)
end

local function deepEqual(a, b, seen)
    if a == b then return true end
    if type(a) ~= type(b) or type(a) ~= "table" then return false end
    seen = seen or {}
    if seen[a] == b then return true end
    seen[a] = b
    for key, value in pairs(a) do
        if not deepEqual(value, b[key], seen) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

local function actorEntry(record)
    if not record then return nil end
    return {
        actor = _projection and _projection:GetActor(record.sceneID) or nil,
        prefabName = record.prefabName,
        sceneID = record.sceneID,
        entityId = record.entityId,
        actorId = record.actorId,
        programId = record.programId,
        external = record.external,
        metadata = copy(record.metadata),
        tags = copy(record.tags),
        properties = copy(record.properties),
        transform = copy(record.transform),
    }
end

local function notify(eventName, payload)
    if _notificationBuffer then
        _notificationBuffer[#_notificationBuffer + 1] = { name = eventName, payload = payload }
        return
    end
    local listeners = _listeners[eventName]
    if not listeners then return end
    for _, listener in ipairs(listeners) do
        local ok, err = pcall(listener, payload)
        if not ok then Log.Error("listener_error", err, { origin = "scene_data", event = eventName }) end
    end
end

local function ensureInitialized()
    return _document ~= nil and _projection ~= nil and _commandBus ~= nil
end

local function restoreExternal(record)
    local metadata = record.metadata or {}
    local restorer = _externalRestorers[metadata.kind]
    if not restorer then return false, "未知 external 类型: " .. tostring(metadata.kind) end
    local ok, result, err = pcall(restorer, copy(record))
    if not ok then return false, tostring(result) end
    return result == true, err
end

local function destroyExternal(record, projection)
    projection = projection or _projection
    local actor = projection and projection:GetActor(record.sceneID) or nil
    local destroyer = _externalDestroyers[(record.metadata or {}).kind]
    if destroyer and actor then
        local ok, result, err = pcall(destroyer, actor, copy(record))
        if not ok then return false, tostring(result) end
        if result == false then return false, err or "external cleanup failed" end
        projection:Destroy(record.sceneID, true)
        return true
    end
    if projection then projection:Destroy(record.sceneID, false) end
    return true
end

local function clearProjection(document, projection)
    if not document or not projection then return end
    local records = {}
    for _, record in pairs(document.entities or {}) do records[#records + 1] = record end
    for _, record in ipairs(records) do
        if record.external then destroyExternal(record, projection)
        else projection:Destroy(record.sceneID, false) end
    end
end

local function registerHandlers()
    _commandBus:Register("CreateEntity", {
        validate = function(command)
            if not command.prefabName or not PrefabRegistry.IsValid(command.prefabName) then
                return false, "未知预制体: " .. tostring(command.prefabName)
            end
            if _document:Count() >= ACTOR_MAX then return false, "场景 Actor 已达到上限" end
            return true
        end,
        execute = function(command)
            local record = _document:MakeEntityRecord(command.prefabName, command.transform, command.options)
            local ok, err = _document:InsertEntity(record)
            if not ok then return CommandBus.Failure("duplicate_entity", err) end
            local actor, spawnErr = _projection:Spawn(record)
            if not actor then
                _document:RemoveEntity(record.sceneID)
                return CommandBus.Failure("spawn_failed", spawnErr)
            end
            fireActorCreated(actor, record.prefabName)
            for _, groupId in ipairs(command.groups or {}) do
                _document:CreateGroup(groupId)
                _document:AddToGroup(groupId, record.sceneID)
            end
            _document:Touch()
            notify("changed", { kind = "entity_created", sceneID = record.sceneID })
            return CommandBus.Success("实体已创建", actorEntry(record), {
                type = "DeleteEntity", sceneID = record.sceneID,
            })
        end,
    })

    _commandBus:Register("CreateExternalEntity", {
        validate = function(command)
            local metadata = command.metadata or {}
            if type(metadata.kind) ~= "string" or not _externalRestorers[metadata.kind] then
                return false, "未知 external 类型: " .. tostring(metadata.kind)
            end
            if _document:Count() >= ACTOR_MAX then return false, "场景 Actor 已达到上限" end
            if type(command.transform) ~= "table" or #command.transform ~= 9 then
                return false, "Transform 数据无效"
            end
            return true
        end,
        execute = function(command)
            local options = copy(command.options or {})
            options.external = true
            options.metadata = copy(command.metadata or {})
            local record = _document:MakeEntityRecord(command.prefabName or "External", command.transform, options)
            local ok, err = _document:InsertEntity(record)
            if not ok then return CommandBus.Failure("duplicate_entity", err) end
            local restored, restoreErr = restoreExternal(record)
            local actor = restored and _projection:GetActor(record.sceneID) or nil
            if not actor then
                _document:RemoveEntity(record.sceneID)
                return CommandBus.Failure("spawn_failed", restoreErr or "external restore failed")
            end
            _document:Touch()
            notify("changed", { kind = "external_created", sceneID = record.sceneID })
            return CommandBus.Success("外部实体已创建", actorEntry(record), {
                type = "DeleteEntity", sceneID = record.sceneID,
            })
        end,
    })

    _commandBus:Register("RestoreEntity", {
        validate = function(command)
            if not command.record then return false, "缺少实体快照" end
            if _document:GetEntity(command.record.sceneID) then return false, "实体 ID 已存在" end
            return true
        end,
        execute = function(command)
            local record = copy(command.record)
            local ok, err = _document:InsertEntity(record)
            if not ok then return CommandBus.Failure("restore_failed", err) end
            local actor, spawnErr
            if record.external then
                local restored, restoreErr = restoreExternal(record)
                actor = restored and _projection:GetActor(record.sceneID) or nil
                spawnErr = restoreErr
            else
                actor, spawnErr = _projection:Spawn(record)
            end
            if not actor then
                _document:RemoveEntity(record.sceneID)
                return CommandBus.Failure("spawn_failed", spawnErr)
            end
            if not record.external then fireActorCreated(actor, record.prefabName) end
            if command.program then _document.programs[record.programId] = copy(command.program) end
            for _, groupId in ipairs(command.groups or {}) do
                _document:CreateGroup(groupId)
                _document:AddToGroup(groupId, record.sceneID)
            end
            _document:Touch()
            notify("changed", { kind = "entity_restored", sceneID = record.sceneID })
            return CommandBus.Success("实体已恢复", actorEntry(record), {
                type = "DeleteEntity", sceneID = record.sceneID,
            })
        end,
    })

    _commandBus:Register("DeleteEntity", {
        validate = function(command)
            if not _document:GetEntity(tonumber(command.sceneID)) then return false, "实体不存在" end
            return true
        end,
        execute = function(command)
            local sceneID = tonumber(command.sceneID)
            local record = copy(_document:GetEntity(sceneID))
            local program = copy(_document.programs[record.programId])
            local groups = {}
            for groupId, members in pairs(_document.generatedGroups) do
                for _, memberId in ipairs(members) do
                    if memberId == sceneID then groups[#groups + 1] = groupId; break end
                end
            end
            if record.external and command.skipDestroy ~= true then
                local destroyed, destroyErr = destroyExternal(record)
                if not destroyed then return CommandBus.Failure("external_cleanup_failed", destroyErr) end
            elseif not _projection:Destroy(sceneID, command.skipDestroy == true) then
                return CommandBus.Failure("projection_failed", "Actor 删除失败")
            end
            _document:RemoveEntity(sceneID)
            _document:Touch()
            notify("changed", { kind = "entity_deleted", sceneID = sceneID })
            return CommandBus.Success("实体已删除", record, {
                type = "RestoreEntity", record = record, program = program, groups = groups,
            })
        end,
    })

    _commandBus:Register("SetTransform", {
        validate = function(command)
            if not _document:GetEntity(tonumber(command.sceneID)) then return false, "实体不存在" end
            if type(command.transform) ~= "table" or #command.transform ~= 9 then return false, "Transform 数据无效" end
            return true
        end,
        execute = function(command)
            local sceneID = tonumber(command.sceneID)
            local record = _document:GetEntity(sceneID)
            local oldTransform = copy(record.transform)
            if not _projection:SetTransform(sceneID, command.transform) then
                return CommandBus.Failure("projection_failed", "Actor 投影不存在")
            end
            _document:SetTransform(sceneID, command.transform)
            _document:Touch()
            notify("changed", { kind = "transform_changed", sceneID = sceneID })
            return CommandBus.Success("Transform 已更新", actorEntry(record), {
                type = "SetTransform", sceneID = sceneID, transform = oldTransform,
            })
        end,
    })

    _commandBus:Register("SetWorldRule", {
        validate = function(command)
            if type(command.rule) ~= "string" or command.rule == "" then return false, "缺少 rule" end
            if tonumber(command.value) == nil then return false, "规则值必须是 number" end
            if not _worldRuleAdapter or type(_worldRuleAdapter.set) ~= "function" then
                return false, "WorldRule adapter 未初始化"
            end
            return true
        end,
        execute = function(command)
            local oldValue = _document.worldSettings[command.rule]
            if oldValue == nil and _worldRuleAdapter.get then oldValue = _worldRuleAdapter.get(command.rule) end
            if oldValue == nil or oldValue < 0 then
                return CommandBus.Failure("invalid_rule", "未知规则: " .. tostring(command.rule))
            end
            local value = tonumber(command.value)
            if not _worldRuleAdapter.set(command.rule, value) then
                return CommandBus.Failure("rule_apply_failed", "规则应用失败: " .. tostring(command.rule))
            end
            local appliedValue = _worldRuleAdapter.get and _worldRuleAdapter.get(command.rule) or value
            if appliedValue == nil or appliedValue < 0 then appliedValue = value end
            _document.worldSettings[command.rule] = appliedValue
            _document:Touch()
            notify("changed", { kind = "world_rule_changed", rule = command.rule })
            return CommandBus.Success("世界规则已更新", { rule=command.rule, value=appliedValue }, {
                type="SetWorldRule", rule=command.rule, value=oldValue,
            })
        end,
    })

    _commandBus:Register("UpdateProgram", {
        validate = function(command)
            if type(command.programId) ~= "string" or command.programId == "" then
                return false, "缺少 programId"
            end
            if type(command.data) ~= "table" then return false, "程序数据必须是 table" end
            return true
        end,
        execute = function(command)
            local oldProgram = copy(_document:GetProgram(command.programId))
            _document:SetProgram(command.programId, command.data)
            _document:Touch()
            notify("changed", { kind = "program_changed", programId = command.programId })
            local inverse = oldProgram and {
                type = "UpdateProgram", programId = command.programId, data = oldProgram,
            } or {
                type = "DeleteProgram", programId = command.programId,
            }
            return CommandBus.Success("程序已更新", { programId = command.programId }, inverse)
        end,
    })

    _commandBus:Register("DeleteProgram", {
        validate = function(command)
            if type(command.programId) ~= "string" or command.programId == "" then
                return false, "缺少 programId"
            end
            if _document:GetProgram(command.programId) == nil then return false, "程序不存在" end
            return true
        end,
        execute = function(command)
            local oldProgram = copy(_document:RemoveProgram(command.programId))
            _document:Touch()
            notify("changed", { kind = "program_changed", programId = command.programId })
            return CommandBus.Success("程序已删除", { programId = command.programId }, {
                type = "UpdateProgram", programId = command.programId, data = oldProgram,
            })
        end,
    })
end

function SceneData:Init(editorBridge)
    if _document and _projection then clearProjection(_document, _projection) end
    _bridge = editorBridge
    _document = Document.New()
    _projection = WorldProjection.New(editorBridge)
    _commandBus = CommandBus.New({ historyLimit = HISTORY_LIMIT })
    _notificationBuffer = nil
    _activeBatch = nil
    registerHandlers()
    Log.SetContext({ document = _document.header.documentId })
    Log.NewSession("scene_init")
    Log.Info("scene_initialized", { schemaVersion = _document.header.schemaVersion, maxActors = ACTOR_MAX, historyLimit = HISTORY_LIMIT })
end

--- 注册"actor spawn 后"回调，所有从 PrefabRegistry 路径 spawn 的 actor 都会触发一次
--- @param fn function(actor, prefabName)
function SceneData:SetActorCreatedHook(fn)
    _onActorCreated = fn
end

function SceneData:Shutdown()
    if _document and _projection then clearProjection(_document, _projection) end
    if _worldRuleAdapter and _worldRuleAdapter.reset then _worldRuleAdapter.reset() end
    _document, _projection, _commandBus, _bridge = nil, nil, nil, nil
    _listeners, _externalRestorers, _externalDestroyers = {}, {}, {}
    _worldRuleAdapter, _notificationBuffer = nil, nil
    Log.ClearContext()
end

function SceneData:GetDocument() return _document end
function SceneData:GetCommandBus() return _commandBus end
function SceneData:GetRevision() return _document and _document.header.revision or 0 end

function SceneData:Subscribe(eventName, listener)
    _listeners[eventName] = _listeners[eventName] or {}
    _listeners[eventName][#_listeners[eventName] + 1] = listener
end

function SceneData:RegisterExternalAdapter(kind, restorer, destroyer)
    if not kind or type(restorer) ~= "function" then return false end
    _externalRestorers[kind] = restorer
    _externalDestroyers[kind] = type(destroyer) == "function" and destroyer or nil
    return true
end

function SceneData:RegisterExternalRestorer(kind, restorer)
    return self:RegisterExternalAdapter(kind, restorer, nil)
end

function SceneData:RegisterWorldRuleAdapter(setter, getter, resetter)
    if type(setter) ~= "function" or type(getter) ~= "function" then return false end
    _worldRuleAdapter = { set=setter, get=getter, reset=resetter }
    return true
end

function SceneData:SetWorldRule(rule, value, context)
    return self:ExecuteCommand({type="SetWorldRule", rule=rule, value=value}, context or {source="local", approved=true})
end

function SceneData:GetWorldRule(rule)
    local stored = _document and _document.worldSettings[rule] or nil
    if stored ~= nil then return stored end
    if _worldRuleAdapter and _worldRuleAdapter.get then return _worldRuleAdapter.get(rule) end
    return -1
end

function SceneData:AttachExternalActor(sceneID, actor)
    local record = _document and _document:GetEntity(tonumber(sceneID)) or nil
    if not record or not record.external then return false end
    return _projection:AttachExternal(record, actor)
end

function SceneData:ExecuteCommand(command, context, options)
    if not ensureInitialized() then return { ok = false, code = "not_initialized", message = "SceneData 未初始化" } end
    context = context or { source = "local" }
    if context.baseRevision ~= nil and tonumber(context.baseRevision) ~= _document.header.revision then
        return {
            ok = false, code = "revision_conflict",
            message = string.format("文档版本冲突：期望 %s，当前 %s", tostring(context.baseRevision), tostring(_document.header.revision)),
        }
    end
    return _commandBus:Execute(command, context, options)
end

function SceneData:ExecuteComposite(commands, label, context)
    if not ensureInitialized() then
        return { ok = false, code = "not_initialized", message = "SceneData 未初始化" }
    end

    local before = {
        revision = _document.header.revision,
        dirty = _document.dirty,
        nextSceneID = _document.nextSceneID,
        nextBatchID = _document.nextBatchID,
    }
    local previousBuffer = _notificationBuffer
    local events = {}
    _notificationBuffer = events
    local result = self:ExecuteCommand({ type = "Composite", label = label, commands = commands }, context)
    _notificationBuffer = previousBuffer

    if not result.ok then
        if result.code ~= "rollback_failed" then
            _document.header.revision = before.revision
            _document.dirty = before.dirty
            _document.nextSceneID = before.nextSceneID
            _document.nextBatchID = before.nextBatchID
        end
        return result
    end

    _document.header.revision = before.revision + 1
    _document.dirty = true
    if previousBuffer then
        for _, event in ipairs(events) do previousBuffer[#previousBuffer + 1] = event end
    else
        for _, event in ipairs(events) do notify(event.name, event.payload) end
    end
    return result
end

function SceneData:Clear()
    if not ensureInitialized() then return end
    clearProjection(_document, _projection)
    if _worldRuleAdapter and _worldRuleAdapter.reset then _worldRuleAdapter.reset() end
    _document = Document.New()
    _projection = WorldProjection.New(_bridge)
    _commandBus:ClearHistory()
    _activeBatch = nil
    notify("changed", { kind = "document_cleared" })
    Log.Info("scene_cleared", { entities = _document:Count() })
end

function SceneData:IsDirty() return _document and _document.dirty or false end
function SceneData:MarkDirty() if _document then _document:Touch() end end
function SceneData:ClearDirty() if _document then _document.dirty = false end end

function SceneData:SetScript(programId, data)
    if not _document then return false end
    if deepEqual(_document:GetProgram(programId), data) then return true end
    local result = self:ExecuteCommand({
        type = "UpdateProgram", programId = programId, data = data,
    }, { source = "program_editor", approved = true })
    return result.ok
end
function SceneData:GetScript(programId) return _document and _document:GetProgram(programId) or nil end
function SceneData:SetLevelScript(data) return self:SetScript("level_main", data) end
function SceneData:GetLevelScript() return self:GetScript("level_main") end
function SceneData:SetActorScript(sceneID, data) return self:SetScript("actor_prog_" .. tostring(sceneID), data) end
function SceneData:GetActorScript(sceneID) return self:GetScript("actor_prog_" .. tostring(sceneID)) end
function SceneData:GetAllScripts() return _document and _document.programs or {} end
function SceneData:LoadAllScripts(scriptMap)
    if not _document then return end
    _document.programs = copy(scriptMap or {})
end

function SceneData:CreateActor(prefabName, location, rotation, context)
    local transform = UE.UKismetMathLibrary.MakeTransform(
        location, rotation or UE.FRotator(0, 0, 0), UE.FVector(1, 1, 1))
    return self:CreateActorWithTransform(prefabName, transform, context)
end

function SceneData:CreateActorWithTransform(prefabName, transform, context)
    local result = self:ExecuteCommand({
        type = "CreateEntity", prefabName = prefabName, transform = transformToData(transform),
    }, context or { source = "legacy_api" })
    if not result.ok then
        Log.Error(result.code, result.message, { type = "CreateEntity", prefab = prefabName, source = "legacy_api" })
        return nil, nil
    end
    return result.data.sceneID, result.data.actor
end

function SceneData:CreateExternalEntity(prefabName, transform, metadata, options, context)
    local result = self:ExecuteCommand({
        type = "CreateExternalEntity",
        prefabName = prefabName,
        transform = transform,
        metadata = metadata,
        options = options,
    }, context or { source = "external", approved = true })
    if not result.ok then return nil, result.message end
    return result.data.sceneID, result.data.actor
end

function SceneData:RegisterExternalActor(actor, prefabName, metadata, options)
    if not ensureInitialized() or not actor then return nil end
    options = options or {}
    local transform = _bridge:GetActorTransform(actor)
    local record = _document:MakeEntityRecord(prefabName or "External", transformToData(transform), {
        sceneID = options.sceneID,
        entityId = options.entityId,
        external = true,
        metadata = metadata or {},
    })
    local ok = _document:InsertEntity(record)
    if not ok then return nil end
    _projection:AttachExternal(record, actor)
    _document:Touch()
    notify("changed", { kind = "external_registered", sceneID = record.sceneID })
    return record.sceneID
end

function SceneData:DeleteExternalByKind(kind, context)
    if not ensureInitialized() then return 0, "SceneData 未初始化" end
    local commands = {}
    for sceneID, record in pairs(_document.entities) do
        if record.external and ((not kind) or (record.metadata or {}).kind == kind) then
            commands[#commands + 1] = { type = "DeleteEntity", sceneID = sceneID }
        end
    end
    table.sort(commands, function(a, b) return a.sceneID < b.sceneID end)
    if #commands == 0 then return 0 end
    local result = self:ExecuteComposite(commands, "Delete external " .. tostring(kind or "all"), context or { source = "external", approved = true })
    if not result.ok then return 0, result.message end
    return #commands
end

function SceneData:UnregisterExternalByKind(kind, context)
    return self:DeleteExternalByKind(kind, context)
end

--- 开启一个具名 batch：之后的原子/生成器调用共享同一个 batchID（同名重复调用复用同一 ID）
--- @param name string 自定义 batch 名（如 city_block / forest_a）
--- @return string batchID
function SceneData:BeginNamedBatch(name)
    if not ensureInitialized() then return nil end
    local batchID = "batch_" .. tostring(name or "anon")
    _document:CreateGroup(batchID)
    _document:Touch()
    _activeBatch = batchID
    Log.Info("batch_begun", { batch = batchID })
    return batchID
end

--- 关闭当前 active batch；返回被关闭的 batchID（无 active 时返回 nil）
function SceneData:EndActiveBatch()
    local batchID = _activeBatch
    _activeBatch = nil
    if batchID then Log.Info("batch_ended", { batch = batchID }) end
    return batchID
end

function SceneData:GetActiveBatch()
    return _activeBatch
end

function SceneData:BeginBatch()
    if not _document then return nil end
    local id = _document:CreateGroup()
    _document:Touch()
    return id
end
function SceneData:AllocateBatchID()
    return _document and _document:PeekGroupID() or nil
end
function SceneData:AddToBatch(batchID, sceneID)
    if _document and _document:AddToGroup(batchID, sceneID) then _document:Touch(); return true end
    return false
end
function SceneData:GetBatchActors(batchID) return _document and _document.generatedGroups[batchID] or nil end
function SceneData:DeleteBatch(batchID, context)
    if not _document then return 0 end
    local members = copy(_document.generatedGroups[batchID] or {})
    if #members == 0 then return 0 end
    local commands = {}
    for _, sceneID in ipairs(members) do commands[#commands + 1] = { type = "DeleteEntity", sceneID = sceneID } end
    local result = self:ExecuteComposite(commands, "Delete " .. tostring(batchID), context or { source = "batch" })
    if result.ok then _document:RemoveGroup(batchID); return #members end
    return 0
end
function SceneData:ListBatches()
    local result = {}
    if not _document then return result end
    for id, members in pairs(_document.generatedGroups) do result[#result + 1] = { id = id, count = #members } end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

function SceneData:DeleteActor(sceneID, context)
    local result = self:ExecuteCommand({ type = "DeleteEntity", sceneID = sceneID }, context or { source = "legacy_api" })
    if not result.ok then Log.Error(result.code, result.message, { type = "DeleteEntity", entity = sceneID }) end
    return result.ok
end

function SceneData:ModifyActor(sceneID, newTransform, context)
    local result = self:ExecuteCommand({
        type = "SetTransform", sceneID = sceneID, transform = transformToData(newTransform),
    }, context or { source = "legacy_api" })
    if not result.ok then Log.Error(result.code, result.message, { type = "SetTransform", entity = sceneID }) end
    return result.ok
end

function SceneData:QueryActor(sceneID)
    if not _document then return nil end
    return actorEntry(_document:GetEntity(tonumber(sceneID)))
end
function SceneData:Count() return _document and _document:Count() or 0 end
function SceneData:ForEach(callback)
    if not _document then return end
    local ids = {}
    for sceneID in pairs(_document.entities) do ids[#ids + 1] = sceneID end
    table.sort(ids)
    for _, sceneID in ipairs(ids) do callback(actorEntry(_document.entities[sceneID])) end
end
function SceneData:GetAllActors()
    local result = {}
    self:ForEach(function(entry) result[entry.sceneID] = entry end)
    return result
end

function SceneData:PushUndo(_) Log.Warn("push_undo_deprecated", { hint = "提交 Command 而不是手动压栈" }) end
local function executeHistory(operation, source)
    if not _commandBus or not _document then return false end
    local before = {
        revision = _document.header.revision,
        dirty = _document.dirty,
        nextSceneID = _document.nextSceneID,
        nextBatchID = _document.nextBatchID,
    }
    local previousBuffer = _notificationBuffer
    local events = {}
    _notificationBuffer = events
    local result = operation(_commandBus, { source = source, approved = true })
    _notificationBuffer = previousBuffer
    if not result.ok then
        if result.code ~= "rollback_failed" then
            _document.header.revision = before.revision
            _document.dirty = before.dirty
            _document.nextSceneID = before.nextSceneID
            _document.nextBatchID = before.nextBatchID
        end
        return false
    end
    _document.header.revision = before.revision + 1
    _document.dirty = true
    if previousBuffer then
        for _, event in ipairs(events) do previousBuffer[#previousBuffer + 1] = event end
    else
        for _, event in ipairs(events) do notify(event.name, event.payload) end
    end
    return true
end

function SceneData:Undo()
    return executeHistory(function(bus, context) return bus:Undo(context) end, "undo")
end
function SceneData:Redo()
    return executeHistory(function(bus, context) return bus:Redo(context) end, "redo")
end

function SceneData:SerializePackageTable(editorState)
    return {
        packageVersion = 1,
        savedAt = os.time and os.time() or 0,
        document = _document and _document:Snapshot() or Document.New():Snapshot(),
        editor = copy(editorState or {}),
    }
end

function SceneData:DeserializePackageTable(package)
    if type(package) ~= "table" or type(package.document) ~= "table" then return false, "存档缺少 document" end

    local oldDocument, oldProjection = _document, _projection
    local loaded, loadError = Document.FromSnapshot(package.document)
    if not loaded then return false, "Document 校验失败: " .. tostring(loadError) end
    local stagedProjection = WorldProjection.New(_bridge)
    _document, _projection = loaded, stagedProjection

    for _, record in ipairs(package.document.entities or {}) do
        local stored = loaded:GetEntity(record.sceneID)
        local actor, err
        if stored.external then
            local restored
            restored, err = restoreExternal(stored)
            actor = restored and stagedProjection:GetActor(stored.sceneID) or nil
        else
            actor, err = stagedProjection:Spawn(stored)
        end
        if not actor then
            clearProjection(loaded, stagedProjection)
            _document, _projection = oldDocument, oldProjection
            return false, "实体恢复失败 SceneID=" .. tostring(record.sceneID) .. ": " .. tostring(err)
        end
        if not stored.external then fireActorCreated(actor, stored.prefabName) end
    end

    if _worldRuleAdapter and _worldRuleAdapter.reset then _worldRuleAdapter.reset() end
    for rule, value in pairs(loaded.worldSettings or {}) do
        if not _worldRuleAdapter or not _worldRuleAdapter.set(rule, value) then
            clearProjection(loaded, stagedProjection)
            _document, _projection = oldDocument, oldProjection
            if _worldRuleAdapter and _worldRuleAdapter.reset then
                _worldRuleAdapter.reset()
                for oldRule, oldValue in pairs(oldDocument.worldSettings or {}) do
                    _worldRuleAdapter.set(oldRule, oldValue)
                end
            end
            return false, "世界规则恢复失败: " .. tostring(rule)
        end
    end

    clearProjection(oldDocument, oldProjection)
    _commandBus:ClearHistory()
    loaded.dirty = false
    notify("changed", { kind = "document_loaded" })
    return true, "loaded"
end

--============================================================
-- Legacy 存档格式兼容层（旧 scene.json / programs.json）
--
-- 运行时存档只经 UGCPersistence，写出的永远是单一 *.ugc.json 包。
-- 本段落只保留两件事：
--   * Deserialize*：旧存档「只读兼容」入口，UGCPersistence 的迁移路径仍在调用。
--   * Serialize*  ：迁移/回归导出专用，运行时没有任何调用点；删除时必须同步
--                   Tools/UGCTests/run_serialization.lua（它锁定了旧格式字段名）。
-- 历史上这里另有一套 UGCSerialize 实现，已在 T1 收敛到 Util.json。
--============================================================

--- @deprecated 旧 scene.json 导出，仅用于迁移与回归；运行时写入请用 UGCPersistence。
function SceneData:SerializeToJSON()
    local snapshot = _document and _document:Snapshot() or Document.New():Snapshot()
    local actors = {}
    for _, record in ipairs(snapshot.entities) do
        actors[#actors + 1] = {
            sceneID = record.sceneID,
            entityId = record.entityId,
            actorId = record.actorId,
            programId = record.programId,
            prefab = record.prefabName,
            t = record.transform,
            external = record.external or nil,
            metadata = record.external and record.metadata or nil,
        }
    end
    return json.encode({
        version = 3,
        documentId = snapshot.header.documentId,
        revision = snapshot.header.revision,
        nextID = snapshot.nextSceneID,
        nextBatchID = snapshot.nextBatchID,
        actors = actors,
        generatedGroups = snapshot.generatedGroups,
        worldSettings = snapshot.worldSettings,
    }, "  ")
end

function SceneData:DeserializeFromJSON(encoded)
    local data = json.decode(encoded)
    if type(data) ~= "table" then return false, "scene.json decode 失败" end
    local entities = {}
    for _, actor in ipairs(data.actors or {}) do
        entities[#entities + 1] = {
            sceneID = actor.sceneID or actor.id,
            entityId = actor.entityId,
            actorId = actor.actorId,
            programId = actor.programId,
            prefabName = actor.prefab or actor.prefabName,
            transform = actor.t,
            external = actor.external,
            metadata = actor.metadata,
        }
    end
    return self:DeserializePackageTable({
        packageVersion = 1,
        document = {
            header = {
                documentId = data.documentId,
                schemaVersion = tonumber(data.version) or 1,
                revision = tonumber(data.revision) or 0,
                contentVersion = "legacy",
            },
            nextSceneID = data.nextID,
            nextBatchID = data.nextBatchID,
            entities = entities,
            programs = {},
            generatedGroups = data.generatedGroups or {},
            worldSettings = data.worldSettings or {},
        },
    })
end

--- @deprecated 旧 programs.json 导出，仅用于迁移与回归；运行时写入请用 UGCPersistence。
function SceneData:SerializeProgramsJSON()
    return json.encode({ version = 2, programs = copy(_document and _document.programs or {}) }, "  ")
end
--- 旧 programs.json 只读兼容入口（迁移路径）。
function SceneData:DeserializeProgramsJSON(encoded)
    local data = json.decode(encoded)
    if type(data) ~= "table" or type(data.programs) ~= "table" then return false end
    _document.programs = copy(data.programs)
    _document.dirty = false
    return true
end

return SceneData
