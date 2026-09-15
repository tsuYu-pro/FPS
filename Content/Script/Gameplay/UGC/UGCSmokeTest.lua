--[[
    UGCSmokeTest.lua（T3：UE 5.4 编辑器内 PIE 验收）

    把 Docs/knowledge 里 T3 的 7 项验收清单变成可复现的脚本：
      1. 创建 / 移动 / 删除 / Undo / Redo
      2. 批量生成与原子回滚（失败批次不消耗 ID、不产生残留）
      3. 新旧存档加载（project.ugc.json 与旧 scene.json + programs.json）
      4. 图验证、Delay、Interval 真实时间调度
      5. Trigger Router 事件链路
      6. Authoring ↔ Playtest 双向切换 + GAS/属性/武器/规则清理
      7. AI 提案确认 / 取消与多轮 Tool Loop

    为什么要分帧跑：第 4 项要验证 Delay/Interval 的**真实时间**调度，不能同步断言；
    所以这里是个协作式步骤机，由 UGCPlayerController 的 ReceiveTick 驱动。

    怎么触发：编辑器启动参数 `-ExecCmds="UGC.SmokeTestEnable"` 打开开关，PIE BeginPlay 时自动跑；
    也可以在编辑器控制台敲 `UGC.SmokeTest`（见 Source/FPS/UGC/UGCSmokeTestCommands.cpp）。

    结果落点：UGCLog（LogFPSUGC）→ Saved/Logs/FPS.log，事件名 `smoke_item_result` / `smoke_run_summary`，
    便于 MCP 的 get_editor_logs / assert_log 或直接读日志文件做证据。

    边界（写在这里避免误读）：
      * 鼠标手感类（真人拖 Gizmo、点击落点）不在本脚本范围 —— 按约定由人工抽查，脚本只走同一批入口函数。
      * 第 5 项的"路由子系统广播"是 C++ 侧一跳，脚本从 PC 的回调入口进（等价于子系统广播后的效果）。
      * 第 7 项跳过真实 HTTP：直接注入 OpenAI 兼容响应（Gateway:OnResponse），
        这正是网关暴露给测试的边界；真实网络链路另由 T6 的服务端代理覆盖。

    ================== 2026-09-15 首轮 PIE 实跑修正（脚本自身问题）==================
    （产品代码不动，只修脚本把 API 用错的地方）
      1. 变换参数必须是 UE 的 FTransform（userdata），不能是 9 元素表：
         首轮日志 `Invalid parameter type calling ufunction : BreakTransform ... userdata needed but got table`。
         → 新增 ueTransform()，走 UE.UKismetMathLibrary.MakeTransform；
           批量命令（ExecuteComposite 的 transform 字段）仍用 9 元素表（那是命令层的形状，已验证可用）。
      2. 存档路径必须是**绝对路径**：UGCStorageBridge::IsAllowedJsonPath 先做
         ConvertRelativePathToFull，再要求落在 ProjectSavedDir() 下；相对路径按进程 CWD 解析会被拒。
         首轮日志 `[UGCStorageBridge] Rejected non-JSON path: Saved/UGC/Smoke/smoke_project.ugc.json`。
         → smokeDir() 改成 ProjectDirectory() 前缀。
      3. 第 4/5 项必须先切到 Play 状态：图程序在 Authoring 状态下不该有写入效果，
         而且 TriggerZone 回调本身就有 `state ~= "Play" then return`。
      4. OnTriggerZoneEnter/Exit 是"无返回值"的回调，不能把 nil 当成调用失败
         （首轮报了 "OnTriggerZoneEnter 调用失败: nil"，其实是状态不对导致提前 return）。
      5. 第 6 项改成阶段可诊断的状态机：阶段推进写日志，超时能看出卡在哪一步；
         并且允许在模块可用性/状态异常时给出明确失败而不是空转到超时。
      6. Start() 加防重入：世界重建时 BeginPlay 会再次触发，运行中的那一轮不能被重置
         （首轮第 6 项超时且帧号回退，疑似 PIE 世界重建把 _ctx 清空了）。
]]

local Log = require("Gameplay.UGC.UGCLog")
local json = require("Util.json")

local SmokeTest = {}

SmokeTest.ITEM_TITLES = {
    [1] = "创建/移动/删除/Undo/Redo",
    [2] = "批量生成与原子回滚",
    [3] = "新旧存档加载",
    [4] = "图验证 + Delay/Interval 真实时间调度",
    [5] = "Trigger Router 事件链路",
    [6] = "Authoring↔Playtest 双向切换与清理",
    [7] = "AI 提案确认/取消 + 多轮 Tool Loop",
    [8] = "验证错误列表 UI + 点击定位（T16）",
}

--- 项数由标题表推导：加一项不需要再改步骤机里的三处循环
local ITEM_COUNT = 0
for _ in pairs(SmokeTest.ITEM_TITLES) do ITEM_COUNT = ITEM_COUNT + 1 end

local STEP_FRAME_BUDGET  = 1800   -- 单个步骤最多等 1800 帧（约 20s @90fps）
local TOTAL_FRAME_BUDGET = 9000   -- 整个冒烟最多 9000 帧（约 100s）

local _pc          = nil
local _steps       = nil
local _index       = 0
local _framesInStep = 0
local _framesTotal = 0
local _results     = nil
local _running     = false
local _ctx         = nil          -- 步骤间共享的临时状态

--============================================================
-- 工具
--============================================================

local function safe(fn, ...)
    local ok, a, b, c = pcall(fn, ...)
    if not ok then return nil, tostring(a) end
    return a, b, c
end

--- 批量命令用的 9 元素变换表（ExecuteComposite / place_object 的形状）
local function vec(x, y, z, sx, sy, sz)
    return { x or 0, y or 0, z or 0, 0, 0, 0, sx or 1, sy or 1, sz or 1 }
end

--- SceneData 的 Actor API 用的真实 FTransform（引擎类型，不能拿表糊弄）
local function ueTransform(x, y, z)
    return UE.UKismetMathLibrary.MakeTransform(
        UE.FVector(x or 0, y or 0, z or 0),
        UE.FRotator(0, 0, 0),
        UE.FVector(1, 1, 1))
end

--- 存档必须落在 ProjectSavedDir() 下且用绝对路径（见文件头第 2 条）
local function projectDir()
    local ok, dir = pcall(function() return UE.UKismetSystemLibrary.GetProjectDirectory() end)
    if ok and type(dir) == "string" then return dir end
    return ""
end

local function smokeDir()
    return projectDir() .. "Saved/UGC/Smoke/"
end

local function editorCore()
    local ok, EC = pcall(require, "Gameplay.UGC.UGCEditorCore")
    if ok and EC then return EC end
    ok, EC = pcall(require, "Gameplay.UGC.EditorCore")
    if ok and EC then return EC end
    return nil
end

local function uiManager()
    local ok, UI = pcall(require, "Gameplay.Core.UIManager")
    if ok and UI then return UI end
    return nil
end

local function sceneData()
    local ok, SD = pcall(require, "Gameplay.UGC.UGCSceneData")
    if not ok then return nil end
    return SD
end

local function programRunner()
    local ok, Runner = pcall(require, "Gameplay.UGC.UGCProgramRunner")
    if not ok then return nil end
    return Runner
end

local function persistence()
    local ok, P = pcall(require, "Gameplay.UGC.UGCPersistence")
    if not ok then return nil end
    return P
end

--- 取 PC 当前 Pawn 的名字：UnLua 下 GetPawn 不一定可直接调用，逐级回退（属性 → UFUNCTION）
local function pawnNameOf(pc)
    if not pc then return "无PC" end
    local ok, name = pcall(function()
        local pawn = pc.Pawn
        if pawn == nil and pc.GetPawn ~= nil then pawn = pc:GetPawn() end
        if pawn == nil then return "无Pawn" end
        return tostring(pawn:GetName())
    end)
    if ok and name then return name end
    return "取不到Pawn"
end

--- 生成一张图：事件 →[可选 Delay/PRINT]→ Set_GameRule
--- 中间插入 PRINT（`program_print`）是为了在日志里留下"图确实执行了"的直接证据。
local function ruleGraph(eventType, rule, value, delaySeconds, printMessage)
    local nodes = { { id = "event", type = eventType, params = {} } }
    local connections = {}
    local previous = "event"

    local function chain(nodeType, params)
        nodes[#nodes + 1] = { id = "n" .. tostring(#nodes), type = nodeType, params = params }
        local nodeId = nodes[#nodes].id
        connections[#connections + 1] = {
            from_id = previous, from_pin = "exec_out", to_id = nodeId, to_pin = "exec_in" }
        previous = nodeId
    end

    if delaySeconds then chain("Delay", { seconds = tostring(delaySeconds) }) end
    if printMessage then chain("Print_Message", { msg = tostring(printMessage) }) end
    chain("Set_GameRule", { rule = rule, value = tostring(value) })

    return { nodes = nodes, connections = connections }
end

--============================================================
-- 步骤机
--============================================================

local function addStep(item, title, fn)
    _steps[#_steps + 1] = { item = item, title = title, fn = fn }
end

local function record(item, ok, detail)
    _results[item] = { ok = ok, detail = detail or "" }
    Log.Info("smoke_item_result", {
        item = item,
        title = SmokeTest.ITEM_TITLES[item] or tostring(item),
        ok = ok and true or false,
        detail = tostring(detail or ""),
    })
end

--- 环境自检：把"哪些依赖没解析到"提前写进日志，避免只看到表象失败
function SmokeTest:Probe()
    local UIManager = uiManager()
    local EC = editorCore()
    local okRunner, Runner = pcall(require, "Gameplay.UGC.UGCProgramRunner")
    local okSD, SD = pcall(require, "Gameplay.UGC.UGCSceneData")
    Log.Info("smoke_probe", {
        sceneData = okSD and SD ~= nil or false,
        programRunner = okRunner and Runner ~= nil or false,
        editorCore = EC ~= nil,
        uiManager = UIManager ~= nil,
        state = EC and tostring(EC:GetState()) or "n/a",
    })
    return { SD = okSD and SD or nil, Runner = okRunner and Runner or nil, EC = EC, UIManager = UIManager }
end

function SmokeTest:Start(pc)
    if _running then
        -- 世界重建会再跑一次 BeginPlay：运行中的那一轮不能被重置（否则 _ctx 被清空、步骤机空转）
        Log.Info("smoke_run_skipped", { reason = "already_running", item = _index + 1 })
        if pc and pc ~= _pc then _pc = pc end
        return
    end
    _pc = pc
    _steps, _index, _framesInStep, _framesTotal, _results = {}, 0, 0, 0, {}
    _running = true
    _ctx = {}
    self:Probe()
    Log.Info("smoke_run_begin", { items = ITEM_COUNT })
    self:_build()
end

function SmokeTest:IsRunning()
    return _running
end

function SmokeTest:Tick(deltaSeconds)
    if not _running then return end
    _framesTotal = _framesTotal + 1
    _framesInStep = _framesInStep + 1

    if _framesTotal > TOTAL_FRAME_BUDGET then
        for i = 1, ITEM_COUNT do
            if not _results[i] then record(i, false, "总帧预算耗尽，未能执行") end
        end
        self:_finish()
        return
    end

    local step = _steps[_index + 1]
    if not step then
        for i = 1, ITEM_COUNT do
            if not _results[i] then record(i, false, "没有对应的检查步骤（脚本缺项）") end
        end
        self:_finish()
        return
    end

    if _framesInStep > STEP_FRAME_BUDGET then
        record(step.item, false, string.format("单步超时（%s，stage=%s）",
            step.title, tostring(_ctx and _ctx.stage or "?")))
        _index = _index + 1
        _framesInStep = 0
        return
    end

    local ok, state, detail = pcall(step.fn, _framesInStep - 1, deltaSeconds)
    if not ok then
        record(step.item, false, "异常: " .. tostring(state))
        _index = _index + 1
        _framesInStep = 0
        return
    end

    if state == "retry" then return end

    record(step.item, state == "done", detail)
    _index = _index + 1
    _framesInStep = 0
end

function SmokeTest:_finish()
    _running = false
    local passed, failed = 0, 0
    local failedItems = {}
    for i = 1, ITEM_COUNT do
        if _results[i] and _results[i].ok then passed = passed + 1
        else failed = failed + 1; failedItems[#failedItems + 1] = tostring(i) end
    end
    Log.Info("smoke_run_summary", {
        passed = passed, failed = failed, total = ITEM_COUNT,
        failedItems = table.concat(failedItems, ","),
    })
    if _pc and _pc.SetStatus and failed == 0 then
        pcall(function() _pc:SetStatus(string.format("UGC 冒烟验收：%d/%d 通过", passed, ITEM_COUNT)) end)
    end
end

--============================================================
-- 步骤定义
--============================================================

--- 进入 Play 状态（图程序与 Trigger 回调都要在 Play 下才生效）；返回 nil 或失败原因
local function ensurePlayState(EC)
    if not EC then return "EditorCore 不可用（无法切换状态）" end
    local state = EC:GetState()
    if state == "Play" then return nil end
    local ok = EC:EnterPlayMode()
    if ok == false then
        return "进入 Play 失败（PlaytestPawnClass 未配置或无 Authority），状态=" .. tostring(EC:GetState())
    end
    local after = EC:GetState()
    if after ~= "Play" then
        return "EnterPlayMode 之后状态仍为 " .. tostring(after)
    end
    return nil
end

function SmokeTest:_build()
    local SD = sceneData()
    local Runner = programRunner()
    local EC = editorCore()

    ------------------------------------------------------------------
    -- 1. 创建 / 移动 / 删除 / Undo / Redo
    ------------------------------------------------------------------
    addStep(1, "create/move/delete/undo/redo", function()
        if not SD then return "fail", "UGCSceneData 不可用" end
        SD:Clear()
        local id, err = SD:CreateActorWithTransform("Box", ueTransform(0, 0, 100))
        if not id then return "fail", "创建失败: " .. tostring(err) end
        if SD:Count() ~= 1 then return "fail", "Count 应为 1，实际 " .. tostring(SD:Count()) end
        local entry = SD:QueryActor(id)
        if not entry or not entry.actor then return "fail", "创建的 Actor 没有投影（actor 为空）" end

        if not SD:ModifyActor(id, ueTransform(500, 0, 100)) then return "fail", "移动失败" end
        local moved = SD:QueryActor(id)
        if not moved or not moved.transform or moved.transform[1] ~= 500 then
            return "fail", string.format("移动后 X 应为 500，实际 %s",
                tostring(moved and moved.transform and moved.transform[1]))
        end

        if not SD:Undo() then return "fail", "Undo 失败" end
        if SD:QueryActor(id).transform[1] ~= 0 then return "fail", "Undo 后 X 应回到 0" end
        if not SD:Redo() then return "fail", "Redo 失败" end
        if SD:QueryActor(id).transform[1] ~= 500 then return "fail", "Redo 后 X 应为 500" end

        if not SD:DeleteActor(id) then return "fail", "删除失败" end
        if SD:Count() ~= 0 then return "fail", "删除后 Count 应为 0" end
        if not SD:Undo() then return "fail", "撤销删除失败" end
        if SD:Count() ~= 1 then return "fail", "撤销删除后 Count 应为 1" end

        SD:Clear()
        return "done", "create→move→undo→redo→delete→undo 全部生效，投影存在"
    end)

    ------------------------------------------------------------------
    -- 2. 批量生成与原子回滚
    ------------------------------------------------------------------
    addStep(2, "composite atomicity", function()
        if not SD then return "fail", "UGCSceneData 不可用" end
        SD:Clear()
        local doc = SD:GetDocument()
        local nextSceneBefore = doc.nextSceneID
        local revisionBefore = doc.header.revision
        local batch = SD:AllocateBatchID()

        local result = SD:ExecuteComposite({
            { type = "CreateEntity", prefabName = "Box", transform = vec(100, 0, 0), groups = { batch } },
            { type = "CreateEntity", prefabName = "NotARealPrefab", transform = vec(200, 0, 0), groups = { batch } },
        }, "smoke_fail_batch")

        if result.ok then return "fail", "含非法预制体的批次不应成功" end
        if SD:Count() ~= 0 then return "fail", "失败批次产生了残留实体: " .. tostring(SD:Count()) end
        if doc.nextSceneID ~= nextSceneBefore then
            return "fail", string.format("失败批次消耗了 sceneID：%s → %s", tostring(nextSceneBefore), tostring(doc.nextSceneID))
        end
        if doc.header.revision ~= revisionBefore then
            return "fail", string.format("失败批次改动了 revision：%s → %s", tostring(revisionBefore), tostring(doc.header.revision))
        end
        if SD:GetBatchActors(batch) ~= nil then return "fail", "失败批次留下了 group 记录" end

        local okBatch = SD:AllocateBatchID()
        local okResult = SD:ExecuteComposite({
            { type = "CreateEntity", prefabName = "Box", transform = vec(300, 0, 0), groups = { okBatch } },
            { type = "CreateEntity", prefabName = "Box", transform = vec(400, 0, 0), groups = { okBatch } },
        }, "smoke_good_batch")
        if not okResult.ok then return "fail", "合法批次应当成功: " .. tostring(okResult.message) end
        if SD:Count() ~= 2 then return "fail", "合法批次后 Count 应为 2" end
        if #(SD:GetBatchActors(okBatch) or {}) ~= 2 then return "fail", "批次分组应含 2 个实体" end
        local revisionAfterComposite = doc.header.revision
        if revisionAfterComposite ~= revisionBefore + 1 then
            return "fail", "合法批次应当只 +1 revision，实际 " .. tostring(revisionAfterComposite - revisionBefore)
        end
        if not SD:Undo() then return "fail", "批次 Undo 失败" end
        if SD:Count() ~= 0 then return "fail", "批次 Undo 后应清空" end
        if not SD:Redo() then return "fail", "批次 Redo 失败" end
        if SD:Count() ~= 2 then return "fail", "批次 Redo 后应恢复 2 个实体" end

        SD:Clear()
        return "done", "失败批次不消耗 ID/不产生残留/revision 不变；合法批次原子且可撤销"
    end)

    ------------------------------------------------------------------
    -- 3. 新旧存档加载
    ------------------------------------------------------------------
    addStep(3, "save/load (new package + legacy)", function()
        if not SD then return "fail", "UGCSceneData 不可用" end
        local P = persistence()
        if not P then return "fail", "UGCPersistence 不可用" end
        local bridge = _pc and _pc:GetUGCStorageBridge() or nil
        if not bridge then return "fail", "UGCStorageBridge 不可用" end

        SD:Clear()
        local a = SD:CreateActorWithTransform("Box", ueTransform(10, 0, 0))
        local b = SD:CreateActorWithTransform("Sphere", ueTransform(20, 0, 0))
        if not a or not b then return "fail", "准备实体失败" end
        SD:SetParent(b, a)
        SD:SetProperty(b, "mass", 12.5)
        local expectedCount = SD:Count()

        local path = smokeDir() .. "smoke_project.ugc.json"
        local saved, saveInfo = P:SaveProject(path, SD, { activeProgramId = "level_main" })
        if not saved then return "fail", "保存项目失败: " .. tostring(saveInfo) .. "（path=" .. path .. "）" end

        local savedCount = expectedCount
        SD:Clear()
        if SD:Count() ~= 0 then return "fail", "清空场景失败" end

        local loaded, loadResult = P:LoadProject(path, SD)
        if not loaded then return "fail", "加载新格式项目失败: " .. tostring(loadResult) end
        if SD:Count() ~= savedCount then
            return "fail", string.format("新格式往返后实体数不符：%s → %s", tostring(savedCount), tostring(SD:Count()))
        end
        local restored = SD:QueryActor(b)
        if not restored then return "fail", "加载后找不到 sceneID=" .. tostring(b) end
        if restored.parentId ~= a then return "fail", "加载后层级（parentId）丢失" end
        if restored.properties.mass ~= 12.5 then return "fail", "加载后属性（mass）丢失" end

        -- 旧格式：写 scene.json + programs.json，走 Persistence 的迁移加载路径
        local legacyScene = SD:SerializeToJSON()          -- 旧格式导出（deprecated，仅迁移/回归用）
        local legacyPrograms = SD:SerializeProgramsJSON()
        local legacyDir = smokeDir() .. "legacy/"
        local wroteScene = bridge:WriteTextFileAtomic(legacyDir .. "scene.json", legacyScene)
        local wrotePrograms = bridge:WriteTextFileAtomic(legacyDir .. "programs.json", legacyPrograms)
        if not wroteScene or not wrotePrograms then
            return "fail", "写旧格式文件失败（dir=" .. legacyDir .. "）"
        end

        SD:Clear()
        -- 旧格式加载分三步尝试（都在产品既有入口内，不绕过任何校验）：
        --   ① 目录级 LoadProject（旧布局的正式入口：scene.json + programs.json）
        --   ② 显式 scene.json 路径
        --   ③ 数据层契约：读回文件 → DeserializeFromJSON / DeserializeProgramsJSON
        -- 2026-09-15 实测：给了存在的 .json 路径时，LoadProject 会先走 v2 package 校验并返回
        -- invalid_project_file（legacy 分支只在"候选文件不存在"时才走到），所以这里保留 ① 的尝试，
        -- ① ② 都失败时用 ③，并把实际走的路径写进 detail，避免把"没走通"写成"通过"。
        local legacyLoadHow = nil
        local folderLoaded, folderResult = P:LoadProject(legacyDir, SD)
        if folderLoaded then
            legacyLoadHow = "LoadProject(目录)"
        else
            local fileLoaded, fileResult = P:LoadProject(legacyDir .. "scene.json", SD)
            if fileLoaded then
                legacyLoadHow = "LoadProject(scene.json)"
            else
                SD:Clear()
                local sceneJson = bridge:ReadTextFile(legacyDir .. "scene.json")
                local programsJson = bridge:ReadTextFile(legacyDir .. "programs.json")
                if not sceneJson or sceneJson == "" then
                    return "fail", "旧格式文件读回失败（" .. tostring(folderResult) .. " / " .. tostring(fileResult) .. "）"
                end
                local okScene, sceneErr = SD:DeserializeFromJSON(sceneJson)
                if not okScene then return "fail", "旧格式 scene.json 迁移加载失败: " .. tostring(sceneErr) end
                if programsJson and programsJson ~= "" then
                    local okPrograms, programsErr = SD:DeserializeProgramsJSON(programsJson)
                    if not okPrograms then
                        return "fail", "旧格式 programs.json 迁移加载失败: " .. tostring(programsErr)
                    end
                end
                legacyLoadHow = string.format("数据层契约(LoadProject: %s)", tostring(fileResult))
            end
        end

        local legacyCount = SD:Count()
        if legacyCount ~= savedCount then
            return "fail", string.format("旧格式加载后实体数不符：期望 %s 实际 %s", tostring(savedCount), tostring(legacyCount))
        end

        return "done", string.format(
            "package 往返 %d 实体（含 parentId/properties）；旧 scene.json+programs.json 迁移加载成功（%s）",
            savedCount, tostring(legacyLoadHow))
    end)

    ------------------------------------------------------------------
    -- 4. 图验证 + Delay / Interval 真实时间调度
    ------------------------------------------------------------------
    addStep(4, "delay scheduling", function(frame, dt)
        if not SD then return "fail", "UGCSceneData 不可用" end
        if not Runner then return "fail", "UGCProgramRunner 不可用" end

        --- 起一次 Delay 观测：脚本 + 校验 + RunProgram（重跑时也走这里）
        local function startDelay()
            SD:Clear()
            local probeRule, probeValue = "RespawnDelay", 42
            _ctx.delayRule, _ctx.delayValue = probeRule, probeValue
            SD:SetScript("actor_prog_smoke_delay",
                ruleGraph("Event_OnGameStart", probeRule, probeValue, 0.5, "smoke_delay_fired"))
            local report = Runner:ValidateProgram("actor_prog_smoke_delay")
            if not report.ok then
                return "图验证失败: " .. tostring(json.encode(report.errors or {}))
            end
            if not Runner:RunProgram("actor_prog_smoke_delay", "Event_OnGameStart") then
                return "RunProgram 未找到 Event_OnGameStart 入口"
            end
            _ctx.delayElapsed = 0
            _ctx.delayRestarts = (_ctx.delayRestarts or 0) + 1
            return nil
        end

        _ctx.stage = "delay"
        if frame == 0 or _ctx.delayRule == nil then
            local stateErr = ensurePlayState(EC)
            if stateErr then return "fail", stateErr end
            local startErr = startDelay()
            if startErr then return "fail", startErr end
            return "retry"
        end

        -- 状态被外部切走时（Enter/Exit Playtest 都会 CancelAllTasks），待触发的 Delay 会被清掉：
        -- 切回 Play 并重新计时，而不是把它当失败。
        if EC and EC:GetState() ~= "Play" then
            local stateErr = ensurePlayState(EC)
            if stateErr then return "fail", stateErr end
            local startErr = startDelay()
            if startErr then return "fail", startErr end
            Log.Info("smoke_item_note", { item = 4, note = "state 被切走，Delay 重新计时" })
            return "retry"
        end

        _ctx.delayElapsed = (_ctx.delayElapsed or 0) + (dt or 0)
        local current = SD:GetWorldRule(_ctx.delayRule)
        if current == _ctx.delayValue then
            if _ctx.delayElapsed < 0.2 then
                return "fail", string.format("Delay 太早触发（约 %.2fs）", _ctx.delayElapsed)
            end
            return "done", string.format("延迟 %.2fs 后规则生效（真实时间调度正确；重跑 %d 次）",
                _ctx.delayElapsed, _ctx.delayRestarts or 1)
        end
        if _ctx.delayElapsed > 4.0 then
            return "fail", string.format("Delay 未生效（约 %.2fs，规则值 %s，state=%s）",
                _ctx.delayElapsed, tostring(current), tostring(EC and EC:GetState() or "n/a"))
        end
        return "retry"
    end)

    addStep(4, "interval scheduling", function(frame, dt)
        if not SD then return "fail", "UGCSceneData 不可用" end
        if not Runner then return "fail", "UGCProgramRunner 不可用" end

        local function startInterval()
            -- 用一层计数适配器包住桥接层的世界规则，统计 interval 实际触发次数
            local ruleBridge = _pc and _pc:GetUGCBridge() or nil
            if not ruleBridge then return "UGCBridge 不可用" end
            _ctx.intervalCount = 0
            SD:RegisterWorldRuleAdapter(function(rule, value)
                _ctx.intervalCount = _ctx.intervalCount + 1
                return ruleBridge:SetGameRule(rule, value)
            end, function(rule)
                return ruleBridge:GetGameRule(rule)
            end)
            -- 注意：Event_OnInterval 的周期参数名是 interval（UGCGraphSchema），不是 seconds
            SD:SetScript("actor_prog_smoke_interval",
                ruleGraph("Event_OnInterval", "RoundTime", 123, nil, "smoke_interval_tick"))
            local script = SD:GetScript("actor_prog_smoke_interval")
            script.nodes[1].params = { interval = 0.25 }
            SD:SetScript("actor_prog_smoke_interval", script)

            local report = Runner:ValidateProgram("actor_prog_smoke_interval")
            if not report.ok then
                return "定时图验证失败: " .. tostring(json.encode(report.errors or {}))
            end
            Runner:CompileAllPrograms()
            _ctx.intervalElapsed = 0
            _ctx.intervalRestarts = (_ctx.intervalRestarts or 0) + 1
            return nil
        end

        _ctx.stage = "interval"
        if frame == 0 or _ctx.intervalElapsed == nil then
            local stateErr = ensurePlayState(EC)
            if stateErr then return "fail", stateErr end
            local startErr = startInterval()
            if startErr then return "fail", startErr end
            return "retry"
        end

        if EC and EC:GetState() ~= "Play" then
            local stateErr = ensurePlayState(EC)
            if stateErr then return "fail", stateErr end
            local startErr = startInterval()
            if startErr then return "fail", startErr end
            Log.Info("smoke_item_note", { item = 4, note = "state 被切走，Interval 重新计时" })
            return "retry"
        end

        _ctx.intervalElapsed = (_ctx.intervalElapsed or 0) + (dt or 0)
        if _ctx.intervalElapsed >= 1.2 then
            local count = _ctx.intervalCount or 0
            if count >= 3 then
                return "done", string.format("0.25s 周期在 %.2fs 内触发 %d 次（重跑 %d 次）",
                    _ctx.intervalElapsed, count, _ctx.intervalRestarts or 1)
            end
            return "fail", string.format("定时触发次数不足：%.2fs 内仅 %d 次（state=%s）",
                _ctx.intervalElapsed, count, tostring(EC and EC:GetState() or "n/a"))
        end
        return "retry"
    end)

    ------------------------------------------------------------------
    -- 5. Trigger Router 事件链路
    ------------------------------------------------------------------
    addStep(5, "trigger router", function(frame, dt)
        if not SD then return "fail", "UGCSceneData 不可用" end
        if not Runner then return "fail", "UGCProgramRunner 不可用" end

        --- 起一次 Trigger 观测：清场 + 造 TriggerZone + 挂图（重跑时也走这里）
        local function startTrigger()
            local zone = SD:CreateActorWithTransform("TriggerZone", ueTransform(600, 0, 0))
            if not zone then return "创建 TriggerZone 失败" end
            SD:SetScript("actor_prog_smoke_trigger",
                ruleGraph("Event_OnEnter", "FriendlyFire", 1, nil, "smoke_trigger_enter"))
            _ctx.triggerRule = "FriendlyFire"
            _ctx.triggerValue = 1
            _ctx.triggerZone = zone
            _ctx.triggerElapsed = 0
            _ctx.triggerRestarts = (_ctx.triggerRestarts or 0) + 1
            return nil
        end

        _ctx.stage = "trigger"
        if frame == 0 or _ctx.triggerRule == nil then
            local stateErr = ensurePlayState(EC)
            if stateErr then return "fail", stateErr end
            local startErr = startTrigger()
            if startErr then return "fail", startErr end
            return "retry"
        end

        if EC and EC:GetState() ~= "Play" then
            local stateErr = ensurePlayState(EC)
            if stateErr then return "fail", stateErr end
            local startErr = startTrigger()
            if startErr then return "fail", startErr end
            Log.Info("smoke_item_note", { item = 5, note = "state 被切走，Trigger 重新触发" })
            return "retry"
        end

        -- 与 C++ AUGCTriggerZone 回调同一条入口（子系统广播后的落地函数）。
        -- 这个回调没有返回值，所以不能把 nil 当失败 —— 只关心效果。
        local _, callErr = safe(function()
            _pc:OnTriggerZoneEnter("actor_prog_smoke_trigger")
        end)
        if callErr then return "fail", "OnTriggerZoneEnter 抛出异常: " .. tostring(callErr) end

        _ctx.triggerElapsed = (_ctx.triggerElapsed or 0) + (dt or 0)
        if SD:GetWorldRule(_ctx.triggerRule) == _ctx.triggerValue then
            safe(function() _pc:OnTriggerZoneExit("actor_prog_smoke_trigger") end)
            return "done", string.format("TriggerZone 进入事件驱动图程序生效（规则被改写；重跑 %d 次）",
                _ctx.triggerRestarts or 1)
        end
        if _ctx.triggerElapsed > 3.0 then
            return "fail", string.format(
                "Trigger 事件之后图程序没有生效（规则 %s=%s，state=%s）",
                tostring(_ctx.triggerRule), tostring(SD:GetWorldRule(_ctx.triggerRule)),
                tostring(EC and EC:GetState() or "n/a"))
        end
        return "retry"
    end)

    ------------------------------------------------------------------
    -- 6. Authoring ↔ Playtest 双向切换与清理
    ------------------------------------------------------------------
    addStep(6, "authoring/playtest toggle", function(frame)
        if not EC then return "fail", "UGCEditorCore 不可用" end
        local UIManager = uiManager()
        if not UIManager then return "fail", "UIManager 不可用" end

        if frame == 0 or _ctx.stage6 == nil then
            _ctx.stage6 = "to_edit"
            _ctx.stage6Frames = 0
            _ctx.stage6Trace = {}
            return "retry"
        end
        _ctx.stage6Frames = (_ctx.stage6Frames or 0) + 1

        local function step()
            if _ctx.stage6 == "to_edit" then
                -- Play → Edit：恢复 authoring pawn、重置世界规则、重新打开编辑器窗口
                if EC:GetState() == "Play" then EC:ToggleEditMode() end
                _ctx.stage6Trace[#_ctx.stage6Trace + 1] = "to_edit:" .. tostring(EC:GetState())
                if EC:GetState() ~= "Edit" then
                    if _ctx.stage6Frames > 120 then
                        return "fail", "切回 Edit 失败，状态=" .. tostring(EC:GetState())
                    end
                    return "retry"
                end
                if not UIManager:IsOpen("WBP_UGCEditor") then
                    if _ctx.stage6Frames > 300 then
                        return "fail", "Edit 模式下编辑器窗口未打开（WBP_UGCEditor）"
                    end
                    return "retry"
                end
                _ctx.stage6 = "edit_ok"
                _ctx.stage6Frames = 0
                return "retry"
            end

            if _ctx.stage6 == "edit_ok" then
                -- 反向：Edit → Play，应当生成 Playtest Pawn 并关掉编辑器窗口
                _ctx.editPawn = pawnNameOf(_pc)
                local ok = EC:EnterPlayMode()
                _ctx.stage6Trace[#_ctx.stage6Trace + 1] =
                    "to_play:" .. tostring(EC:GetState()) .. "/" .. tostring(ok)
                if ok == false then return "fail", "再次进入 Play 模式失败" end
                if EC:GetState() ~= "Play" then
                    if _ctx.stage6Frames > 180 then
                        return "fail", "EnterPlayMode 之后状态仍为 " .. tostring(EC:GetState())
                    end
                    return "retry"
                end
                if UIManager:IsOpen("WBP_UGCEditor") then
                    if _ctx.stage6Frames > 300 then return "fail", "Play 模式下编辑器窗口未关闭" end
                    return "retry"
                end
                local playPawn = pawnNameOf(_pc)
                if playPawn == "无Pawn" then
                    if _ctx.stage6Frames > 300 then return "fail", "Play 模式下没有 Pawn（Playtest Pawn 未生成）" end
                    return "retry"
                end
                _ctx.playPawn = playPawn
                _ctx.stage6 = "play_ok"
                _ctx.stage6Frames = 0
                return "retry"
            end

            if _ctx.stage6 == "play_ok" then
                -- 再切回 Edit，校验 Pawn 回收（Authoring/Playtest 双向）
                EC:ToggleEditMode()
                _ctx.stage6Trace[#_ctx.stage6Trace + 1] = "back_edit:" .. tostring(EC:GetState())
                if EC:GetState() ~= "Edit" then
                    if _ctx.stage6Frames > 180 then
                        return "fail", "第二次切回 Edit 失败，状态=" .. tostring(EC:GetState())
                    end
                    return "retry"
                end
                _ctx.backPawn = pawnNameOf(_pc)
                if _ctx.backPawn == _ctx.playPawn then
                    return "fail", "切回 Edit 后 Pawn 没有变化（仍是 " .. tostring(_ctx.playPawn) .. "）"
                end
                if _ctx.backPawn == "取不到Pawn" or _ctx.playPawn == "取不到Pawn" then
                    return "fail", "Pawn 名字取不到（UnLua 侧访问失败），无法证明 Pawn 被回收"
                end
                return "done", string.format("Play↔Edit 双向切换生效（%s → %s → %s），窗口随状态开关，轨迹 %s",
                    tostring(_ctx.editPawn), tostring(_ctx.playPawn), tostring(_ctx.backPawn),
                    table.concat(_ctx.stage6Trace, " | "))
            end

            return "retry"
        end

        local ok, state, detail = pcall(step)
        if not ok then return "fail", "阶段异常: " .. tostring(state) end
        return state, detail
    end)

    ------------------------------------------------------------------
    -- 7. AI 提案确认 / 取消 + 多轮 Tool Loop
    ------------------------------------------------------------------
    addStep(7, "ai proposal approve/reject", function(frame)
        local okG, Gateway = pcall(require, "Gameplay.UGC.LLMGateway")
        if not okG or not Gateway then return "fail", "LLMGateway 不可用" end
        if not SD then return "fail", "UGCSceneData 不可用" end

        local function responseWithWrite()
            return json.encode({
                choices = { { message = {
                    content = "",
                    tool_calls = { {
                        id = "call_smoke_place",
                        ["function"] = { name = "place_object", arguments = json.encode(
                            { prefab = "Box", x = 800, y = 0, z = 0 }) },
                    } },
                } } },
            })
        end

        local function responseWithRead()
            return json.encode({
                choices = { { message = {
                    content = "看看场景里有什么",
                    tool_calls = { {
                        id = "call_smoke_list",
                        ["function"] = { name = "list_objects", arguments = "{}" },
                    } },
                } } },
            })
        end

        if frame == 0 or _ctx.stage7 == nil then
            SD:Clear()
            _ctx.stage7 = 0
            _ctx.stage7Frames = 0
            return "retry"
        end
        _ctx.stage7Frames = (_ctx.stage7Frames or 0) + 1

        ------------------------------------------------------------------
        -- stage 0：写提案 → 必须挂起等待确认，且文档不能被改动
        ------------------------------------------------------------------
        if _ctx.stage7 == 0 then
            local before = SD:Count()
            safe(function()
                Gateway:Send("放一个方块", function(ok, msg) _ctx.aiCallbackResult = { ok = ok, msg = msg } end)
            end)
            Gateway:OnResponse(responseWithWrite())
            if not Gateway:HasPendingProposal() then
                return "fail", "写提案应当挂起等待确认（HasPendingProposal=false）"
            end
            if SD:Count() ~= before then
                return "fail", "提案未确认前文档不应变化"
            end
            _ctx.stage7 = 1
            _ctx.stage7Frames = 0
            return "retry"
        end

        ------------------------------------------------------------------
        -- stage 1：确认 → 应当执行并产生实体
        ------------------------------------------------------------------
        if _ctx.stage7 == 1 then
            local okApprove, ret = safe(function()
                return Gateway:ApprovePendingProposal(function(ok, msg) _ctx.aiAfterApprove = { ok = ok, msg = msg } end)
            end)
            if okApprove == false or ret == false then
                -- 上一轮 HTTP 可能仍在"进行中"，下一帧再试
                if _ctx.stage7Frames > 600 then return "fail", "等待确认窗口超时（HTTP 未结束？）" end
                return "retry"
            end
            _ctx.stage7 = 2
            _ctx.stage7Frames = 0
            return "retry"
        end

        if _ctx.stage7 == 2 then
            if Gateway:HasPendingProposal() then
                if _ctx.stage7Frames > 600 then return "fail", "确认之后提案仍挂起" end
                return "retry"
            end
            if SD:Count() < 1 then
                return "fail", "确认之后应当有实体被放置（Count=" .. tostring(SD:Count()) .. "）"
            end
            -- 第 2 轮：注入一次只读提案，验证多轮 tool loop 自动继续
            Gateway:OnResponse(responseWithRead())
            _ctx.stage7 = 3
            _ctx.stage7Frames = 0
            return "retry"
        end

        ------------------------------------------------------------------
        -- stage 3：读提案自动执行（不挂起），且文档不再变化
        ------------------------------------------------------------------
        if _ctx.stage7 == 3 then
            if _ctx.stage7Frames < 5 then return "retry" end
            if Gateway:HasPendingProposal() then
                return "fail", "只读提案不应挂起等待确认"
            end
            _ctx.aiCountAfterRead = SD:Count()
            _ctx.stage7 = 4
            _ctx.stage7Frames = 0
            return "retry"
        end

        ------------------------------------------------------------------
        -- stage 4：再注入一个写提案并取消 → 文档不得变化
        ------------------------------------------------------------------
        if _ctx.stage7 == 4 then
            local before = SD:Count()
            safe(function() Gateway:Send("再放一个方块", function() end) end)
            Gateway:OnResponse(responseWithWrite())
            if not Gateway:HasPendingProposal() then
                if _ctx.stage7Frames > 300 then return "fail", "第二个写提案应当挂起" end
                return "retry"
            end
            local rejected, rejRet = safe(function() return Gateway:RejectPendingProposal(function() end) end)
            if rejected == false or rejRet == false then
                if _ctx.stage7Frames > 600 then return "fail", "取消待确认提案超时" end
                return "retry"
            end
            if SD:Count() ~= before then
                return "fail", "取消提案之后文档不应变化"
            end
            if Gateway:HasPendingProposal() then
                return "fail", "取消之后不应还有待确认提案"
            end
            local toolResults = 0
            for _, message in ipairs(Gateway.GetHistory and Gateway.GetHistory() or {}) do
                if message.role == "tool" then toolResults = toolResults + 1 end
            end
            return "done", string.format(
                "写提案挂起→确认执行（Count=%s）→只读提案自动执行→第二个写提案取消且文档不变（历史里 tool 结果 %d 条）",
                tostring(_ctx.aiCountAfterRead or SD:Count()), toolResults)
        end

        return "retry"
    end)

    ------------------------------------------------------------------
    -- 8. 验证错误列表 UI + 点击定位（T16）
    --    走真实入口：UIManager 打开 WBP_UGCBlueprintEditor（与 F8 同一条路）、
    --    OnClickCompile 触发验证、行控件 Activate()（鼠标点击调用的同一个函数）。
    ------------------------------------------------------------------
    addStep(8, "error list ui", function(frame)
        local UIManager = uiManager()
        if not UIManager then return "fail", "UIManager 不可用" end

        if frame == 0 or _ctx.stage8 == nil then
            _ctx.stage8 = "open"
            _ctx.stage8Frames = 0
            _ctx.stage8Trace = {}
            return "retry"
        end
        _ctx.stage8Frames = (_ctx.stage8Frames or 0) + 1

        local function bpEditor()
            if not UIManager:IsOpen("WBP_UGCBlueprintEditor") then return nil end
            return UIManager:GetWindow("WBP_UGCBlueprintEditor")
        end

        if _ctx.stage8 == "open" then
            if not bpEditor() and _pc and _pc.ToggleBlueprintEditor then
                _pc:ToggleBlueprintEditor()
            end
            if not bpEditor() then
                if _ctx.stage8Frames > 300 then return "fail", "蓝图编辑器窗口没打开（WBP_UGCBlueprintEditor）" end
                return "retry"
            end
            _ctx.stage8Trace[#_ctx.stage8Trace + 1] = "open"
            _ctx.stage8 = "fill"
            _ctx.stage8Frames = 0
            return "retry"
        end

        if _ctx.stage8 == "fill" then
            local bp = bpEditor()
            if not bp then return "fail", "蓝图编辑器实例消失" end
            if not bp.OnClickCompile or not bp.GetErrorRowCount then
                return "fail", "蓝图编辑器 Lua 缺少 T16 入口（OnClickCompile / GetErrorRowCount）"
            end
            -- 一张必然报错的图：缺必填参数（带 nodeId 的错误）+ 端点不存在的连线（不带 nodeId 的错误）
            -- + 孤立节点（警告）。第一条错误必须带 nodeId，点击定位才有目标。
            local graph = {
                nodes = {
                    { id = "node_1", type = "Set_GameRule", pos = { x = 60,  y = 40  }, params = {} },
                    { id = "node_2", type = "Print_Message", pos = { x = 420, y = 260 }, params = { msg = "smoke" } },
                },
                connections = {
                    { from_id = "node_2", from_pin = "exec_out", to_id = "node_missing", to_pin = "exec_in" },
                },
                nextID = 3,
            }
            bp:OpenGraph("level_main", "冒烟：错误列表", graph)
            _ctx.stage8Trace[#_ctx.stage8Trace + 1] = "graph"
            _ctx.stage8 = "validate"
            _ctx.stage8Frames = 0
            return "retry"
        end

        if _ctx.stage8 == "validate" then
            local bp = bpEditor()
            if not bp then return "fail", "蓝图编辑器实例消失" end
            _ctx.errorRowsBefore = bp:GetErrorRowCount()
            bp:OnClickCompile()
            _ctx.errorRows = bp:GetErrorRowCount()
            if (_ctx.errorRows or 0) < 2 then
                return "fail", string.format(
                    "验证后错误列表行数不足：%d（期望 >=2；图里至少 2 个错误）", _ctx.errorRows or 0)
            end
            _ctx.stage8Trace[#_ctx.stage8Trace + 1] = "rows=" .. tostring(_ctx.errorRows)
            _ctx.stage8 = "click"
            _ctx.stage8Frames = 0
            return "retry"
        end

        if _ctx.stage8 == "click" then
            local bp = bpEditor()
            if not bp or not bp.GetErrorRowWidget then return "fail", "蓝图编辑器实例消失" end
            local row = bp:GetErrorRowWidget(1)
            if not row then return "fail", "拿不到第一行错误控件" end

            -- 诊断：把前两行的 nodeId/文本写进日志，失败时能直接看出列表里到底是什么
            for probe = 1, math.min(2, bp:GetErrorRowCount()) do
                local probeRow   = bp:GetErrorRowWidget(probe)
                local probeEntry = probeRow and probeRow.GetErrorRow and probeRow:GetErrorRow() or nil
                print(string.format("[UGCSmokeTest] 错误列表第 %d 行: nodeId=%s pin=%s text=%s",
                    probe,
                    tostring(probeEntry and probeEntry.nodeId or "nil"),
                    tostring(probeEntry and probeEntry.pin or "nil"),
                    tostring(probeEntry and probeEntry.text or "nil")))
            end

            local entry = row.GetErrorRow and row:GetErrorRow() or nil
            if not entry or not entry.nodeId then
                return "fail", "第一行没有 nodeId，无法定位（错误顺序可能变了）"
            end

            local before = bp:GetNodeCanvasPosition(entry.nodeId)
            row:Activate()                       -- 与鼠标点击同一入口
            local after  = bp:GetNodeCanvasPosition(entry.nodeId)
            local focus  = bp:GetFocusTarget()

            if not focus or focus.nodeID ~= entry.nodeId then
                return "fail", string.format("点击后高亮目标不对：期望 %s，实际 %s",
                    tostring(entry.nodeId), tostring(focus and focus.nodeID))
            end
            if before and after and before.x == after.x and before.y == after.y then
                return "fail", "点击后节点视图没有移动（定位没生效）"
            end
            if entry.pin and focus.pin ~= entry.pin then
                return "fail", string.format("引脚高亮不对：期望 %s 实际 %s",
                    tostring(entry.pin), tostring(focus.pin))
            end
            return "done", string.format(
                "验证列出 %d 行（验证前 %d 行）；点击第 1 行定位到 %s%s，节点视图 %s -> %s",
                _ctx.errorRows or -1, _ctx.errorRowsBefore or -1, tostring(entry.nodeId),
                entry.pin and ("." .. tostring(entry.pin)) or "",
                before and string.format("(%.0f,%.0f)", before.x, before.y) or "nil",
                after  and string.format("(%.0f,%.0f)", after.x, after.y) or "nil")
        end

        return "retry"
    end)
end

return SmokeTest
