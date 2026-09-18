--[[
    Generators/Init.lua
    场景生成器注册表 + 调度器（Lua 单例）

    职责：
    - 维护所有 Gen_*.lua 注册的生成器
    - Generate(name, params)：执行生成器，把生成点列表落到 SceneData，并归入一个 batch
    - ExportFunctions(targetRegistry)：把每个生成器以 generate_<name> 形式
      注册到 UGCFunctionRegistry，让 LLM Function Calling 直接看到独立函数

    每个 Gen_*.lua 模块需返回一个表，提供：
        M.Register(Generators)
            内部调 Generators.Register(name, def)
            def = {
              desc   = "对外说明",
              params = { {name,type,desc,required}, ... },
              func   = function(p) return { points = {...}, prefab = "Box" } end
            }

    生成器 func 应返回：
        { points = { {x,y,z[,yaw,pitch,roll,prefab]}, ... },
          prefab = "默认 prefab id（可被 point.prefab 覆盖）" }
]]

local SceneData = require("Gameplay.UGC.UGCSceneData")
local PrefabReg = require("Gameplay.UGC.UGCPrefabRegistry")
local Atoms     = require("Gameplay.UGC.Generators.Atoms")

local M = {}

local _gens = {}   -- name → def

--============================================================
-- 公共落地：把点列表 spawn 进 SceneData，归到一个 batch
-- 若当前存在 active named batch，则共用之；否则新建一个匿名 batch
-- 返回 batchID, successCount, skipCount
--============================================================

local function _placePoints(points, default_prefab)
    if type(points) ~= "table" or #points == 0 then
        return nil, 0, 0
    end

    local active = SceneData:GetActiveBatch()
    local batchID = active or SceneData:BeginBatch()
    local successCount, skipCount = 0, 0

    for _, p in ipairs(points) do
        local prefab = p.prefab or default_prefab
        if not prefab or not PrefabReg.IsValid(prefab) then
            skipCount = skipCount + 1
        else
            local loc = UE.FVector(p.x or 0, p.y or 0, p.z or 0)
            local rot = UE.FRotator(p.pitch or 0, p.yaw or 0, p.roll or 0)
            local sceneID = SceneData:CreateActor(prefab, loc, rot)
            if sceneID then
                SceneData:AddToBatch(batchID, sceneID)
                successCount = successCount + 1
            else
                break  -- 上限或失败 → 提前停止
            end
        end
    end
    return batchID, successCount, skipCount
end

M._placePoints = _placePoints

--============================================================
-- 注册接口（供 Gen_*.lua 调用）
--============================================================

function M.Register(name, def)
    if not name or not def or not def.func then
        UGCLog.Error("registry_error", "Register 缺少 name/def/func")
        return
    end
    _gens[name] = def
end

function M.GetDef(name) return _gens[name] end

function M.List()
    local names = {}
    for k in pairs(_gens) do names[#names+1] = k end
    table.sort(names)
    return names
end

function M.GetSchemas()
    local list = {}
    for name, def in pairs(_gens) do
        list[#list+1] = { name = name, desc = def.desc, params = def.params }
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

--============================================================
-- 执行
--============================================================

--- 调用指定生成器，把生成结果落到 SceneData
--- @return batchID(string) | nil, count(number) | errMsg(string)
function M:Generate(name, params, context)
    local def = _gens[name]
    if not def then
        return nil, "未知生成器: " .. tostring(name)
    end

    local ok, result = pcall(def.func, params or {})
    if not ok then
        return nil, "生成器异常: " .. tostring(result)
    end
    if type(result) ~= "table" or type(result.points) ~= "table" then
        return nil, "生成器返回格式错误（需要 {points={...}, prefab=...}）"
    end

    local default_prefab = result.prefab
    local points = result.points
    if #points == 0 then
        return nil, "生成 0 个点（参数可能太小或种子问题）"
    end

    local batchID, successCount, skipCount = _placePoints(points, default_prefab)
    if not batchID then
        return nil, "落地失败"
    end
    if #commands == 0 then return nil, "没有有效的生成点" end

    local result = SceneData:ExecuteComposite(commands, "Generate " .. tostring(name), context or {source="generator", approved=true})
    if not result.ok then return nil, result.message end

    local successCount = 0
    for _, childResult in ipairs(result.data or {}) do
        if childResult.ok and childResult.data and childResult.data.sceneID then
            successCount = successCount + 1
        end
    end
    UGCLog.Info("generator_batch", {
        generator = name, batch = batchID,
        created = successCount, skipped = skipCount, requested = #points,
    })
    return batchID, successCount
end

--============================================================
-- LLM 函数导出
-- 把每个生成器以 generate_<name>（小写）注册到 UGCFunctionRegistry
--============================================================

function M:ExportFunctions(targetRegistry)
    if not targetRegistry or not targetRegistry.Register then
        UGCLog.Error("registry_error", "ExportFunctions: targetRegistry 不合法")
        return
    end
    local self_ = self
    for name, def in pairs(_gens) do
        local funcName = "generate_" .. string.lower(name)
        targetRegistry:Register(funcName, {
            desc   = "[场景生成器] " .. (def.desc or name),
            params = def.params or {},
            func   = function(p, context)
                local batchID, countOrErr = self_:Generate(name, p, context)
                if not batchID then
                    return false, "生成失败: " .. tostring(countOrErr)
                end
                return true, string.format(
                    "已生成 %d 个 Actor，batch_id=%s（用 delete_batch 整批清除）",
                    countOrErr, batchID)
            end,
        })
    end
    local exported = 0
    for _ in pairs(_gens) do exported = exported + 1 end
    UGCLog.Info("generators_exported", { count = exported })
end

--============================================================
-- 原子函数 LLM 导出
-- 把 Atoms.lua 里的 8 个原子封装成参数明确的 LLM 函数：
--   scatter_box / scatter_circle / place_grid / place_line /
--   place_circle / build_wall / place_at / place_along_path / fill_polygon
-- 每个原子先算点，再统一走 _placePoints 落到 SceneData
--============================================================

--- 标准结果包装：把 _placePoints 的输出转成 LLM 字串回执
local function _wrap(funcName, points, default_prefab)
    if not points or #points == 0 then
        return false, funcName .. ": 生成 0 个点（参数可能太小或不合法）"
    end
    local batchID, ok, skip = _placePoints(points, default_prefab)
    if not batchID then return false, funcName .. ": 落地失败" end
    return true, string.format(
        "[%s] 已生成 %d 个 Actor，batch_id=%s%s",
        funcName, ok, batchID,
        (skip > 0) and string.format("（跳过 %d 个无效 prefab）", skip) or "")
end

local AtomDefs = {

    {
        name = "scatter_box",
        desc = "[原子] 在矩形盒子区域内随机散布 prefab。最适合：散落的箱子/路障/碎石/丛林石块",
        params = {
            { name="prefab", type="string", desc="预制体名（如 Box）",  required=true },
            { name="x",      type="number", desc="中心 X(cm)",         required=true },
            { name="y",      type="number", desc="中心 Y(cm)",         required=true },
            { name="z",      type="number", desc="中心 Z(cm)",         required=true },
            { name="size_x", type="number", desc="X 方向尺寸(cm)",     required=true },
            { name="size_y", type="number", desc="Y 方向尺寸(cm)",     required=true },
            { name="size_z", type="number", desc="Z 方向尺寸(cm)，默认0", required=false },
            { name="count",  type="number", desc="数量（≤30）",         required=true },
            { name="seed",   type="number", desc="随机种子，0=时间种子", required=false },
            { name="yaw_random", type="number", desc="是否随机朝向 0/1，默认0", required=false },
        },
        run = function(p)
            local count = math.min(tonumber(p.count) or 0, 30)
            local pts = Atoms.RandomScatter(
                { kind="box",
                  center={ x=tonumber(p.x) or 0, y=tonumber(p.y) or 0, z=tonumber(p.z) or 0 },
                  sx=tonumber(p.size_x) or 0, sy=tonumber(p.size_y) or 0, sz=tonumber(p.size_z) or 0 },
                count, tonumber(p.seed) or 0,
                { rotation = (tonumber(p.yaw_random) == 1) and "yaw_random" or "none" })
            return pts, tostring(p.prefab or "Box")
        end,
    },

    {
        name = "scatter_circle",
        desc = "[原子] 在 XY 圆盘内随机散布 prefab。最适合：环绕中心点的散布物（树/路灯/掩体）",
        params = {
            { name="prefab", type="string", desc="预制体名", required=true },
            { name="x",      type="number", desc="圆心 X",   required=true },
            { name="y",      type="number", desc="圆心 Y",   required=true },
            { name="z",      type="number", desc="高度 Z",   required=true },
            { name="radius", type="number", desc="半径(cm)", required=true },
            { name="count",  type="number", desc="数量（≤30）", required=true },
            { name="seed",   type="number", desc="随机种子",  required=false },
            { name="yaw_random", type="number", desc="是否随机朝向 0/1，默认0", required=false },
        },
        run = function(p)
            local count = math.min(tonumber(p.count) or 0, 30)
            local pts = Atoms.RandomScatter(
                { kind="circle",
                  center={ x=tonumber(p.x) or 0, y=tonumber(p.y) or 0, z=tonumber(p.z) or 0 },
                  radius=tonumber(p.radius) or 0 },
                count, tonumber(p.seed) or 0,
                { rotation = (tonumber(p.yaw_random) == 1) and "yaw_random" or "none" })
            return pts, tostring(p.prefab or "Box")
        end,
    },

    {
        name = "place_grid",
        desc = "[原子] 整齐网格放置。最适合：地砖/方阵/陈列墙/座椅",
        params = {
            { name="prefab",    type="string", desc="预制体名", required=true },
            { name="x",         type="number", desc="网格中心 X", required=true },
            { name="y",         type="number", desc="网格中心 Y", required=true },
            { name="z",         type="number", desc="高度 Z",     required=true },
            { name="rows",      type="number", desc="行数 (Y 方向)", required=true },
            { name="cols",      type="number", desc="列数 (X 方向)", required=true },
            { name="spacing_x", type="number", desc="X 间距(cm)",   required=true },
            { name="spacing_y", type="number", desc="Y 间距(cm)",   required=true },
        },
        run = function(p)
            local rows = math.min(tonumber(p.rows) or 0, 20)
            local cols = math.min(tonumber(p.cols) or 0, 20)
            local pts = Atoms.Grid(
                { x=tonumber(p.x) or 0, y=tonumber(p.y) or 0, z=tonumber(p.z) or 0 },
                rows, cols,
                tonumber(p.spacing_x) or 200, tonumber(p.spacing_y) or 200,
                tonumber(p.z) or 0)
            return pts, tostring(p.prefab or "Box")
        end,
    },

    {
        name = "place_line",
        desc = "[原子] 两点之间均匀放置 N 个 prefab（朝向沿线）。最适合：栏杆柱/路灯/路标",
        params = {
            { name="prefab", type="string", desc="预制体名", required=true },
            { name="x1", type="number", desc="起点 X", required=true },
            { name="y1", type="number", desc="起点 Y", required=true },
            { name="x2", type="number", desc="终点 X", required=true },
            { name="y2", type="number", desc="终点 Y", required=true },
            { name="z",  type="number", desc="高度 Z", required=true },
            { name="count", type="number", desc="数量（≤30）", required=true },
        },
        run = function(p)
            local count = math.min(tonumber(p.count) or 0, 30)
            local z = tonumber(p.z) or 0
            local pts = Atoms.Line(
                { x=tonumber(p.x1) or 0, y=tonumber(p.y1) or 0, z=z },
                { x=tonumber(p.x2) or 0, y=tonumber(p.y2) or 0, z=z },
                count, 0)
            return pts, tostring(p.prefab or "Box")
        end,
    },

    {
        name = "place_circle",
        desc = "[原子] 沿圆周均匀放置 N 个 prefab。最适合：圆形栅栏/篝火围坐/柱阵",
        params = {
            { name="prefab", type="string", desc="预制体名", required=true },
            { name="x",      type="number", desc="圆心 X",   required=true },
            { name="y",      type="number", desc="圆心 Y",   required=true },
            { name="z",      type="number", desc="高度 Z",   required=true },
            { name="radius", type="number", desc="半径(cm)", required=true },
            { name="count",  type="number", desc="数量（≤30）", required=true },
            { name="yaw_facing", type="number", desc="是否朝向圆心切线 0/1，默认0", required=false },
        },
        run = function(p)
            local count = math.min(tonumber(p.count) or 0, 30)
            local pts = Atoms.Circle(
                { x=tonumber(p.x) or 0, y=tonumber(p.y) or 0, z=tonumber(p.z) or 0 },
                tonumber(p.radius) or 0, count, tonumber(p.z) or 0,
                tonumber(p.yaw_facing) == 1)
            return pts, tostring(p.prefab or "Box")
        end,
    },

    {
        name = "build_wall",
        desc = "[原子] 两点之间垒一面 prefab 墙（自动按 block_size 分段+堆叠 layers 层）。最适合：城墙段/防御工事",
        params = {
            { name="prefab", type="string", desc="预制体名", required=true },
            { name="x1", type="number", desc="起点 X", required=true },
            { name="y1", type="number", desc="起点 Y", required=true },
            { name="x2", type="number", desc="终点 X", required=true },
            { name="y2", type="number", desc="终点 Y", required=true },
            { name="z",  type="number", desc="底部 Z", required=true },
            { name="block_size", type="number", desc="单块尺寸(cm)，默认100", required=false },
            { name="layers",     type="number", desc="堆叠层数，默认1", required=false },
        },
        run = function(p)
            local block = tonumber(p.block_size) or 100
            local layers = math.min(tonumber(p.layers) or 1, 8)
            local pts = Atoms.Wall(
                { x=tonumber(p.x1) or 0, y=tonumber(p.y1) or 0, z=tonumber(p.z) or 0 },
                { x=tonumber(p.x2) or 0, y=tonumber(p.y2) or 0, z=tonumber(p.z) or 0 },
                block, layers, block)
            return pts, tostring(p.prefab or "Box")
        end,
    },

    {
        name = "place_at",
        desc = "[原子] 单点精确放置 prefab，含完整旋转。最适合：单个关键道具/特定位置的雕像/门",
        params = {
            { name="prefab", type="string", desc="预制体名", required=true },
            { name="x",     type="number", desc="X(cm)", required=true },
            { name="y",     type="number", desc="Y(cm)", required=true },
            { name="z",     type="number", desc="Z(cm)", required=true },
            { name="yaw",   type="number", desc="Yaw(°)，默认0",   required=false },
            { name="pitch", type="number", desc="Pitch(°)，默认0", required=false },
            { name="roll",  type="number", desc="Roll(°)，默认0",  required=false },
        },
        run = function(p)
            local pts = Atoms.PlaceAt(
                tonumber(p.x) or 0, tonumber(p.y) or 0, tonumber(p.z) or 0,
                tonumber(p.yaw) or 0, tonumber(p.pitch) or 0, tonumber(p.roll) or 0)
            return pts, tostring(p.prefab or "Box")
        end,
    },

    {
        name = "place_along_path",
        desc = "[原子] 沿任意折线均匀放置 prefab（按 spacing 间距）。最适合：弯曲道路/河岸标记/巡逻路径点",
        params = {
            { name="prefab",  type="string", desc="预制体名", required=true },
            { name="points",  type="string", desc="折线顶点 JSON 字串，如 '[[0,0,0],[500,200,0],[1000,0,0]]'", required=true },
            { name="spacing", type="number", desc="相邻 Actor 间距(cm)", required=true },
            { name="yaw_align", type="number", desc="是否对齐路径方向 0/1，默认0", required=false },
        },
        run = function(p)
            local json = require("Util.json")
            local raw = p.points
            local arr
            if type(raw) == "string" then arr = json.decode(raw) else arr = raw end
            if type(arr) ~= "table" or #arr < 2 then
                return {}, tostring(p.prefab or "Box")
            end
            local vs = {}
            for _, v in ipairs(arr) do
                vs[#vs+1] = { x=tonumber(v[1]) or 0, y=tonumber(v[2]) or 0, z=tonumber(v[3]) or 0 }
            end
            local pts = Atoms.PlaceAlongPath(vs, tonumber(p.spacing) or 200,
                tonumber(p.yaw_align) == 1)
            return pts, tostring(p.prefab or "Box")
        end,
    },

    {
        name = "fill_polygon",
        desc = "[原子] 在任意 2D 多边形内按 density 数量随机填充 prefab。最适合：不规则区域填充（湖面浮标/广场障碍/营地物资）",
        params = {
            { name="prefab",   type="string", desc="预制体名", required=true },
            { name="vertices", type="string", desc="多边形顶点 JSON 字串，如 '[[0,0],[1000,0],[500,800]]'", required=true },
            { name="density",  type="number", desc="目标 Actor 数量（≤30）", required=true },
            { name="z",        type="number", desc="统一高度 Z", required=true },
            { name="seed",     type="number", desc="随机种子",   required=false },
            { name="yaw_random", type="number", desc="是否随机朝向 0/1，默认0", required=false },
        },
        run = function(p)
            local json = require("Util.json")
            local raw = p.vertices
            local arr
            if type(raw) == "string" then arr = json.decode(raw) else arr = raw end
            if type(arr) ~= "table" or #arr < 3 then
                return {}, tostring(p.prefab or "Box")
            end
            local vs = {}
            for _, v in ipairs(arr) do
                vs[#vs+1] = { x=tonumber(v[1]) or 0, y=tonumber(v[2]) or 0 }
            end
            local density = math.min(tonumber(p.density) or 0, 30)
            local pts = Atoms.FillPolygon(vs, density, tonumber(p.z) or 0,
                tonumber(p.seed) or 0,
                { rotation = (tonumber(p.yaw_random) == 1) and "yaw_random" or "none" })
            return pts, tostring(p.prefab or "Box")
        end,
    },
}

function M:ExportAtomsAsFunctions(targetRegistry)
    if not targetRegistry or not targetRegistry.Register then
        UGCLog.Warn("atoms_export_skipped", { hint = "targetRegistry 不合法" })
        return
    end
    for _, def in ipairs(AtomDefs) do
        local atomDef = def
        targetRegistry:Register(atomDef.name, {
            desc   = atomDef.desc,
            params = atomDef.params,
            func   = function(params)
                local points, prefab = atomDef.run(params or {})
                return _wrap(atomDef.name, points, prefab)
            end,
        })
    end
    UGCLog.Info("atoms_exported", { count = #AtomDefs })
end

--============================================================
-- 自动加载所有 Gen_*.lua（顺序无关）
-- 新增生成器：在此追加一行 require
--============================================================

local function safeLoad(modPath)
    local ok, mod = pcall(require, modPath)
    if not ok then
        UGCLog.Error("registry_error", "生成器模块加载失败", { module = modPath, reason = tostring(mod) })
        return
    end
    if type(mod) == "table" and type(mod.Register) == "function" then
        mod.Register(M)
    else
        UGCLog.Error("registry_error", "生成器模块未导出 Register", { module = modPath })
    end
end

safeLoad("Gameplay.UGC.Generators.Gen_CoverField")
safeLoad("Gameplay.UGC.Generators.Gen_Room")
safeLoad("Gameplay.UGC.Generators.Gen_Wall")

return M
