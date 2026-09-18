--[[
    UGCEditorCore.lua
    编辑器状态机（Lua 单例）

    状态：
      Idle      → 未进入编辑器
      Edit      → 编辑模式（放置/选中/移动）
      Play      → 试玩模式（正常 FPS 游戏逻辑）

    对标元梦之星的 UGCEditorGameV2，业务逻辑全在 Lua。
    C++ EditorBridge 只提供 SpawnPlaceable / LineTraceScreen 等原子操作。
]]

local UIManager       = require("Gameplay.Core.UIManager")
local PrefabRegistry  = require("Gameplay.UGC.UGCPrefabRegistry")
local SceneData       = require("Gameplay.UGC.UGCSceneData")
local Log             = require("Gameplay.UGC.UGCLog")

local EditorCore = {}
EditorCore.__index = EditorCore

--============================================================
-- 内部状态
--============================================================

local State = { Idle = "Idle", Edit = "Edit", Play = "Play" }

local _pc              = nil
local _bridge          = nil   -- UUGCEditorBridge
local _currentState    = State.Idle
local _selectedID      = nil   -- 当前选中的 SceneID
local _pendingPrefab   = nil   -- 待放置的预制体名，nil=选择模式
local _ghostActor      = nil   -- 跟随鼠标的预览 Actor
local _onStateChanged     = nil   -- 外部监听回调
local _onSelectionChanged = nil   -- 选中变化回调（供 UI 刷新 Transform 面板）

-- 网格对齐状态
local _snapEnabled  = true     -- 是否开启网格对齐
local _snapSize     = 50.0     -- 当前网格尺度（UE 单位，1单位≈1cm）

-- 拖拽移动状态
local _isDragging       = false  -- 是否正在拖拽已选中 Actor
local _dragStartX       = 0
local _dragStartY       = 0
local _preDragTransform = nil    -- 拖拽前的 Transform，用于撤销
local DRAG_THRESHOLD    = 15     -- 像素，超过才认为是拖拽而非点击

-- 防重复放置标志：点预制体按钮时 IA_EditorClick 会在同帧触发，此标志让 OnViewportClick 跳过一次
local _justEnteredPlacement = false

-- Gizmo 轴箭头状态
local _gizmoX       = nil   -- X 轴箭头 Actor（红色）
local _gizmoY       = nil   -- Y 轴箭头 Actor（绿色）
local _gizmoZ       = nil   -- Z 轴箭头 Actor（蓝色）
local _activeAxis   = nil   -- 当前约束拖拽轴："X"/"Y"/"Z"/nil
local _gizmoOffsetX = 0     -- X 箭头：根部到 Actor 原点的真实偏移（由资产本地边界计算）
local _gizmoOffsetY = 0     -- Y 箭头：根部到 Actor 原点的真实偏移（由资产本地边界计算）
local _gizmoOffsetZ = 0     -- Z 箭头：根部到 Actor 原点的真实偏移（由资产本地边界计算）

-- 轴约束拖拽 delta-based 计算参数（避免首帧跳变到 Gizmo 箭头尖端位置）
local _axisOriginWorld = nil  -- 拖拽开始时 Actor 的世界位置（FVector）
local _axisParamStart  = nil  -- 拖拽开始时鼠标射线在轴上的投影参数 t（number）

-- Gizmo 蓝图路径（默认朝 Z 轴，Shaft+Head+HitBox 组合）
local GIZMO_X_PATH = "/Game/_UGC/Editor/Actor/BP_GizmoArrow_X.BP_GizmoArrow_X_C"
local GIZMO_Y_PATH = "/Game/_UGC/Editor/Actor/BP_GizmoArrow_Y.BP_GizmoArrow_Y_C"
local GIZMO_Z_PATH = "/Game/_UGC/Editor/Actor/BP_GizmoArrow_Z.BP_GizmoArrow_Z_C"

-- Gizmo 缩放与渲染参数。
-- 当前最小值抬到 2.0，避免摄像头贴近后 Gizmo 缩到方块内部，
-- 并把半透明排序优先级提到 5，尽量让操纵轴显示在更靠前的渲染层。
local GIZMO_SCALE_BY_DISTANCE = 0.003
local GIZMO_MIN_SCALE = 2.0
local GIZMO_RENDER_SORT_PRIORITY = 5

--- 将数值对齐到最近的网格格点
local function snapToGrid(v, grid)
    return math.floor(v / grid + 0.5) * grid
end

--============================================================
-- Gizmo 内部辅助函数
--============================================================

--- 判断一个 Actor 是否是三个 Gizmo 箭头之一
local function isGizmoActor(actor)
    if not actor then return false end
    return actor == _gizmoX or actor == _gizmoY or actor == _gizmoZ
end

--- 根据 Gizmo Actor 返回对应的轴字符串，不是 Gizmo 则返回 nil
local function getAxisForGizmo(actor)
    if actor == _gizmoX then return "X" end
    if actor == _gizmoY then return "Y" end
    if actor == _gizmoZ then return "Z" end
    return nil
end

--- 安全获取编辑视角位置：优先 CameraManager，其次 Pawn。
--- UnLua 下部分 Controller 方法反射不稳定，统一走 pcall + 多级回退避免 Tick 中断。
local function getEditorViewLocation()
    if not _pc then return nil end

    local cameraManager = _pc.PlayerCameraManager
    if not cameraManager and _pc.GetPlayerCameraManager then
        local okMgr, mgr = pcall(function()
            return _pc:GetPlayerCameraManager()
        end)
        if okMgr then
            cameraManager = mgr
        end
    end

    if cameraManager and cameraManager.GetCameraLocation then
        local okLoc, camLoc = pcall(function()
            return cameraManager:GetCameraLocation()
        end)
        if okLoc and camLoc then
            return camLoc
        end
    end

    local pawn = _pc.Pawn
    if not pawn and _pc.K2_GetPawn then
        local okPawn, result = pcall(function()
            return _pc:K2_GetPawn()
        end)
        if okPawn then
            pawn = result
        end
    end
    if not pawn and _pc.GetPawn then
        local okPawn, result = pcall(function()
            return _pc:GetPawn()
        end)
        if okPawn then
            pawn = result
        end
    end
    if not pawn and _pc.GetControlledPawn then
        local okPawn, result = pcall(function()
            return _pc:GetControlledPawn()
        end)
        if okPawn then
            pawn = result
        end
    end

    if pawn and pawn.GetActorLocation then
        local okLoc, pawnLoc = pcall(function()
            return pawn:GetActorLocation()
        end)
        if okLoc and pawnLoc then
            return pawnLoc
        end
    end

    return nil
end

--- 读取 Gizmo 资产本地包围盒的最小 Z，换算为“根部到 Actor 原点的真实偏移”。
--- 箭头默认沿本地 +Z 指向前方，因此只要取 -MinZ 就能知道根部需要外移多少。
local function getGizmoRootOffset(actor)
    if not actor or not _bridge or not _bridge.GetActorLocalBoundsMinZ then
        return 0
    end

    local minZ = _bridge:GetActorLocalBoundsMinZ(actor)
    if not minZ then
        return 0
    end
    return math.max(0, -minZ)
end

--- 计算单根 Gizmo 的世界 Transform。
--- 三轴共点的锚点始终是“选中物体的位置”；
--- 真实外移距离取自 Gizmo 自身本地包围盒，而不是估算常量，因此不会随相机距离累积误差。
local function makeGizmoTransform(axis, posX, posY, posZ, scale)
    local offset = 0
    local loc = nil
    local rot = nil

    if axis == "X" then
        offset = _gizmoOffsetX * scale
        loc = UE.FVector(posX + offset, posY, posZ)
        rot = UE.FRotator(-90, 0, 0)
    elseif axis == "Y" then
        offset = _gizmoOffsetY * scale
        loc = UE.FVector(posX, posY + offset, posZ)
        rot = UE.FRotator(0, 0, 90)
    else
        offset = _gizmoOffsetZ * scale
        loc = UE.FVector(posX, posY, posZ + offset)
        rot = UE.FRotator(0, 0, 0)
    end

    return UE.UKismetMathLibrary.MakeTransform(loc, rot, UE.FVector(scale, scale, scale)), loc, rot
end

--- 在指定位置 Spawn 3 个 Gizmo 箭头 Actor
--- 旋转约定（箭头默认朝 +Z）：
---   X 轴箭头 = Pitch -90（绕 Y 轴转，使 +Z 朝向 +X）
---   Y 轴箭头 = Roll  +90（绕 X 轴转，使 +Z 朝向 +Y）
---   Z 轴箭头 = 无旋转
local function spawnGizmo(posX, posY, posZ)
    local rootLoc = UE.FVector(posX, posY, posZ)
    local rotX = UE.FRotator(-90, 0, 0)
    local rotY = UE.FRotator(0, 0, 90)
    local rotZ = UE.FRotator(0, 0, 0)

    _gizmoX = _bridge:SpawnPlaceable(GIZMO_X_PATH, rootLoc, rotX)
    _gizmoY = _bridge:SpawnPlaceable(GIZMO_Y_PATH, rootLoc, rotY)
    _gizmoZ = _bridge:SpawnPlaceable(GIZMO_Z_PATH, rootLoc, rotZ)

    if _bridge then
        if _bridge.SetActorTranslucencySortPriority then
            if _gizmoX then _bridge:SetActorTranslucencySortPriority(_gizmoX, GIZMO_RENDER_SORT_PRIORITY) end
            if _gizmoY then _bridge:SetActorTranslucencySortPriority(_gizmoY, GIZMO_RENDER_SORT_PRIORITY) end
            if _gizmoZ then _bridge:SetActorTranslucencySortPriority(_gizmoZ, GIZMO_RENDER_SORT_PRIORITY) end
        end
        if _bridge.SetActorDepthPriorityForeground then
            if _gizmoX then _bridge:SetActorDepthPriorityForeground(_gizmoX, true) end
            if _gizmoY then _bridge:SetActorDepthPriorityForeground(_gizmoY, true) end
            if _gizmoZ then _bridge:SetActorDepthPriorityForeground(_gizmoZ, true) end
        end
    end

    _gizmoOffsetX = getGizmoRootOffset(_gizmoX)
    _gizmoOffsetY = getGizmoRootOffset(_gizmoY)
    _gizmoOffsetZ = getGizmoRootOffset(_gizmoZ)
    Log.Debug("gizmo_spawned", {
        arrows = { tostring(_gizmoX), tostring(_gizmoY), tostring(_gizmoZ) },
        root = { posX, posY, posZ },
        offsets = { _gizmoOffsetX, _gizmoOffsetY, _gizmoOffsetZ },
    })
end

--- 销毁全部 Gizmo 箭头并清除活动轴
local function destroyGizmo()
    if _gizmoX then _bridge:DestroyActor(_gizmoX); _gizmoX = nil end
    if _gizmoY then _bridge:DestroyActor(_gizmoY); _gizmoY = nil end
    if _gizmoZ then _bridge:DestroyActor(_gizmoZ); _gizmoZ = nil end
    _gizmoOffsetX = 0
    _gizmoOffsetY = 0
    _gizmoOffsetZ = 0
    _activeAxis = nil
end

--- 将 3 个 Gizmo 箭头移动到新位置，同时根据相机距离缩放，保持各自固定旋转
--- 缩放系数 = max(GIZMO_MIN_SCALE, 距离 * GIZMO_SCALE_BY_DISTANCE)
local function updateGizmoTransform(posX, posY, posZ)
    if not (_gizmoX or _gizmoY or _gizmoZ) then return end

    -- 根据编辑视角距离计算统一缩放系数
    -- 优先用 CameraManager，失败再回退到 Pawn；任一路径失败都不应中断 Tick
    local scale = GIZMO_MIN_SCALE
    local viewLoc = getEditorViewLocation()
    if viewLoc then
        local dx = viewLoc.X - posX
        local dy = viewLoc.Y - posY
        local dz = viewLoc.Z - posZ
        local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
        scale = math.max(GIZMO_MIN_SCALE, dist * GIZMO_SCALE_BY_DISTANCE)
    end

    -- 各轴保持自己固定的旋转方向，但位置不是中心重合。
    -- 真实偏移来自 Gizmo 资产本地包围盒，因此根部会稳定贴在选中物体锚点上。
    if _gizmoX then
        local t = makeGizmoTransform("X", posX, posY, posZ, scale)
        _bridge:SetActorTransform(_gizmoX, t)
    end
    if _gizmoY then
        local t = makeGizmoTransform("Y", posX, posY, posZ, scale)
        _bridge:SetActorTransform(_gizmoY, t)
    end
    if _gizmoZ then
        local t = makeGizmoTransform("Z", posX, posY, posZ, scale)
        _bridge:SetActorTransform(_gizmoZ, t)
    end
end

--- 计算射线与有向轴线之间的最近点（轴约束拖拽的核心数学）
--- 参数：轴原点 (aoX,aoY,aoZ)，轴方向单位向量 (adX,adY,adZ)
---       射线原点 (roX,roY,roZ)，射线方向单位向量 (rdX,rdY,rdZ)
--- 返回：轴上与射线距离最近的点坐标
local function closestOnAxis(aoX, aoY, aoZ, adX, adY, adZ, roX, roY, roZ, rdX, rdY, rdZ)
    local wx  = roX - aoX
    local wy  = roY - aoY
    local wz  = roZ - aoZ
    local b   = adX*rdX + adY*rdY + adZ*rdZ   -- cos(轴与射线夹角)
    local denom = 1.0 - b * b                 -- sin²(夹角)，平行时为 0
    if math.abs(denom) < 1e-6 then
        -- 射线与轴近似平行，回退到轴原点
        return aoX, aoY, aoZ
    end
    local d = adX*wx + adY*wy + adZ*wz
    local e = rdX*wx + rdY*wy + rdZ*wz
    local t = (b*e - d) / denom               -- 轴参数值
    return aoX + adX*t, aoY + adY*t, aoZ + adZ*t
end

--============================================================
-- 初始化
--============================================================

function EditorCore:Init(playerController)
    _pc     = playerController
    _bridge = playerController:GetUGCEditorBridge()

    if not _bridge then
        Log.Error("bridge_unavailable", "GetUGCEditorBridge() 返回 nil，编辑器功能不可用", { hint = "确认 BP_UGCPlayerController 继承自 AUGCPlayerController" })
        return
    end

    SceneData:Init(_bridge)
    PrefabRegistry:LoadDynamic(_bridge)   -- 扫描 Placeables 目录 + 加载自定义 JSON

    -- AnimAgent dyn 资产：所有 SpawnPlaceable 后自动注入 mesh
    -- 这样 Save/Load/Undo/Redo 全流程通用，SceneData 无需感知 dyn 细节
    SceneData:SetActorCreatedHook(function(actor, prefabName)
        if PrefabRegistry.GetKind(prefabName) == "dynamic_glb" then
            EditorCore:_InjectDynMesh(actor, prefabName)
        end
    end)

    Log.Info("editor_core_initialized", {})
end

--- 内部：确保 _bridge 有效；若为 nil 则尝试从 _pc 懒初始化，仍失败返回 false
local function _ensureBridge()
    if _bridge then return true end
    if not _pc then
        Log.Error("bridge_unavailable", "_bridge 为 nil 且 _pc 未初始化", { hint = "先调用 EditorCore:Init()" })
        return false
    end
    _bridge = _pc:GetUGCEditorBridge()
    if not _bridge then
        Log.Error("bridge_unavailable", "懒初始化失败：GetUGCEditorBridge() 仍返回 nil")
        return false
    end
    Log.Info("editor_bridge_lazy_init", { ok = true })
    SceneData:Init(_bridge)
    return true
end

--============================================================
-- 状态切换
--============================================================

function EditorCore:GetState()
    return _currentState
end

--- 对 SceneData 中所有 Actor 调用 SetDebugVisible（pcall 保护，非 TriggerZone 自动忽略）
local function setAllTriggerZoneDebugVisible(visible)
    local ok, SceneData = pcall(require, "Gameplay.UGC.UGCSceneData")
    if not ok or not SceneData then return end
    local actors = SceneData:GetAllActors()
    if not actors then return end
    for _, entry in pairs(actors) do
        if entry.actor then
            pcall(function() entry.actor:SetDebugVisible(visible) end)
        end
    end
end

function EditorCore:EnterEditMode()
    if _currentState == State.Edit then return end
    local ProgramRunner = require("Gameplay.UGC.UGCProgramRunner")
    ProgramRunner:CancelAllTasks()
    if _pc and _pc.ExitPlaytestPawn then _pc:ExitPlaytestPawn() end
    _currentState  = State.Edit
    _selectedID    = nil
    _pendingPrefab = nil

    if _pc then
        _pc.bShowMouseCursor = true
    end

    UIManager:OpenWindow("WBP_UGCEditor")

    -- 显示所有 TriggerZone 的编辑模式可视化方块
    setAllTriggerZoneDebugVisible(true)

    if _onStateChanged then _onStateChanged(State.Edit) end
    Log.Info("editor_state", { state = State.Edit })
end

function EditorCore:EnterPlayMode()
    if _currentState == State.Play then return end

    local blueprintEditor = UIManager:GetWindow("WBP_UGCBlueprintEditor")
    if blueprintEditor and blueprintEditor.OnClickClose then
        blueprintEditor:OnClickClose()
    elseif blueprintEditor then
        if blueprintEditor.SaveCurrentGraphToSceneData then blueprintEditor:SaveCurrentGraphToSceneData() end
        UIManager:CloseWindow("WBP_UGCBlueprintEditor")
    end

    if _pc and _pc.EnterPlaytestPawn and not _pc:EnterPlaytestPawn() then
        Log.Error("playtest_unavailable", "PlaytestPawnClass 未配置或当前实例无 Authority")
        return false
    end

    -- 取消选中
    self:ClearSelection()
    _pendingPrefab = nil
    _currentState  = State.Play

    if _pc then
        _pc.bShowMouseCursor = false
    end

    UIManager:CloseWindow("WBP_UGCEditor")

    -- 隐藏所有 TriggerZone 的编辑模式可视化方块
    setAllTriggerZoneDebugVisible(false)

    local ProgramRunner = require("Gameplay.UGC.UGCProgramRunner")
    ProgramRunner:CancelAllTasks()
    ProgramRunner:TriggerGameStart()

    if _onStateChanged then _onStateChanged(State.Play) end
    Log.Info("editor_state", { state = State.Play })
    return true
end

function EditorCore:ToggleEditMode()
    if _currentState == State.Edit then
        self:EnterPlayMode()
    else
        self:EnterEditMode()
    end
end

--- 注册状态切换监听（供 WBP_UGCEditor 按钮刷新用）
function EditorCore:OnStateChanged(callback)
    _onStateChanged = callback
end

--- 注册选中变化监听（供 WBP_UGCEditor 刷新 Transform 面板用）
--- callback(sceneID)  sceneID=nil 表示取消选中
function EditorCore:OnSelectionChanged(callback)
    _onSelectionChanged = callback
end

--============================================================
-- 预制体放置
--============================================================

--- 选择要放置的预制体（点击 UI 预制体列表后调用）
function EditorCore:SelectPrefab(prefabName)
    if not _ensureBridge() then return end
    if not PrefabRegistry.IsValid(prefabName) then
        Log.Error("unknown_prefab", nil, { prefab = prefabName })
        return
    end

    -- 清除旧 ghost
    self:_destroyGhost()
    self:ClearSelection()

    _pendingPrefab = prefabName
    -- 按钮点击触发 SelectPrefab 时，同帧的 IA_EditorClick 也会调用 OnViewportClick，
    -- 设置此标志让 OnViewportClick 跳过一次，避免立即放置。
    _justEnteredPlacement = true

    -- 生成 ghost（放到不可见位置，等第一次 UpdateGhostPosition 再移过来）
    local path = PrefabRegistry.GetPath(prefabName)
    local spawnLoc = UE.FVector(0, 0, -99999)
    _ghostActor = _bridge:SpawnPlaceable(path, spawnLoc, UE.FRotator(0, 0, 0))

    -- dyn 资产：spawn 出来的是空壳 AAnimAgentDynamicPlaceable，立即注入 mesh
    if _ghostActor and PrefabRegistry.GetKind(prefabName) == "dynamic_glb" then
        self:_InjectDynMesh(_ghostActor, prefabName)
    end

    if _ghostActor then
        _bridge:SetActorHighlight(_ghostActor, true)
        pcall(function() _ghostActor:SetDebugVisible(true) end)
    end
    Log.Info("placement_mode", { prefab = prefabName })
end

function EditorCore:_destroyGhost()
    if _ghostActor then
        _bridge:DestroyActor(_ghostActor)
        _ghostActor = nil
    end
    _pendingPrefab = nil
end

--- 每 Tick 由 PlayerController 调用，让 Ghost 跟随鼠标
function EditorCore:UpdateGhostPosition(screenX, screenY)
    if not _ghostActor then return end
    if not _ensureBridge() then return end
    -- 传入 _ghostActor 让射线忽略自身，避免自碰撞反馈
    local hitPos = _bridge:LineTraceScreenPosition(screenX, screenY, _ghostActor)
    -- ZeroVector 表示没打到任何东西，保持原位（不归零）
    if hitPos.X ~= 0 or hitPos.Y ~= 0 or hitPos.Z ~= 0 then
        -- 网格对齐：将 Ghost 位置吸附到最近格点
        if _snapEnabled then
            hitPos = UE.FVector(
                snapToGrid(hitPos.X, _snapSize),
                snapToGrid(hitPos.Y, _snapSize),
                snapToGrid(hitPos.Z, _snapSize)
            )
        end
        _bridge:SetActorTransform(_ghostActor,
            UE.UKismetMathLibrary.MakeTransform(hitPos, UE.FRotator(0,0,0), UE.FVector(1,1,1)))
    end
end

--- 取消放置模式，切回选择模式（ESC 调用）
function EditorCore:CancelPrefab()
    _justEnteredPlacement = false
    self:_destroyGhost()
end

function EditorCore:GetPendingPrefab()
    return _pendingPrefab
end

--============================================================
-- 点击处理（由 WBP_UGCEditor 的 Viewport MouseDown 触发）
-- screenX / screenY 为屏幕像素坐标
--============================================================

function EditorCore:OnViewportClick(screenX, screenY)
    if _currentState ~= State.Edit then return end
    if _isDragging then return end   -- 拖拽中忽略点击选中
    if not _ensureBridge() then return end

    if _pendingPrefab then
        -- 点预制体按钮时同帧触发的 IA_EditorClick，跳过一次不放置
        if _justEnteredPlacement then
            _justEnteredPlacement = false
            return
        end

        -- 放置模式：取 Ghost 当前位置作为落点（忽略 Ghost 自身）
        local loc = _bridge:LineTraceScreenPosition(screenX, screenY, _ghostActor)
        if loc.X == 0 and loc.Y == 0 and loc.Z == 0 then
            loc = UE.FVector(0, 0, 100)   -- 没打到地面时的兜底
        end
        -- 确认放置坐标同样做网格对齐
        if _snapEnabled then
            loc = UE.FVector(
                snapToGrid(loc.X, _snapSize),
                snapToGrid(loc.Y, _snapSize),
                snapToGrid(loc.Z, _snapSize)
            )
        end

        local prefabName = _pendingPrefab
        self:_destroyGhost()   -- 先销毁 Ghost，再放真实 Actor

        local isDyn = (PrefabRegistry.GetKind(prefabName) == "dynamic_glb")

        -- SceneData:CreateActor 内部已通过 hook 自动注入 dyn mesh
        local sceneID, actor = SceneData:CreateActor(prefabName, loc)
        if actor then
            self:SelectByID(sceneID)
        end

        -- 放置后自动重生同款 Ghost，保持放置模式（ESC 退出）
        local continuePath = PrefabRegistry.GetPath(prefabName)
        if continuePath then
            local spawnLoc = UE.FVector(0, 0, -99999)
            _ghostActor = _bridge:SpawnPlaceable(continuePath, spawnLoc, UE.FRotator(0, 0, 0))
            if _ghostActor and isDyn then
                self:_InjectDynMesh(_ghostActor, prefabName)
            end
            if _ghostActor then
                _bridge:SetActorHighlight(_ghostActor, true)
                pcall(function() _ghostActor:SetDebugVisible(true) end)
            end
            _pendingPrefab = prefabName
        end

    else
        -- 选择模式：点击选中/取消选中
        local hitActor = _bridge:LineTraceScreen(screenX, screenY)
        if hitActor then
            -- 优先判断是否击中 Gizmo 轴箭头
            local axis = getAxisForGizmo(hitActor)
            if axis then
                -- 激活轴约束拖拽，不改变当前选中状态
                _activeAxis = axis
                return
            end

            -- 找出对应的 SceneID
            local found = nil
            SceneData:ForEach(function(entry)
                if entry.actor == hitActor then
                    found = entry.sceneID
                end
            end)
            if found then
                self:SelectByID(found)
            else
                self:ClearSelection()
            end
        else
            self:ClearSelection()
        end
    end
end

--============================================================
-- 选中管理
--============================================================

function EditorCore:SelectByID(sceneID)
    -- 取消旧选中的高亮
    if _selectedID then
        local old = SceneData:QueryActor(_selectedID)
        if old and old.actor then
            _bridge:SetActorHighlight(old.actor, false)
        end
    end

    _selectedID  = sceneID
    _activeAxis  = nil   -- 切换选中时清除残留的轴约束
    local entry = SceneData:QueryActor(sceneID)
    if entry and entry.actor then
        _bridge:SetActorHighlight(entry.actor, true)
        -- 在选中 Actor 位置 Spawn 真实 Gizmo 箭头（替代 DrawDebug 轴线）
        local t = _bridge:GetActorTransform(entry.actor)
        local loc, _, _ = UE.UKismetMathLibrary.BreakTransform(t)
        destroyGizmo()   -- 先销毁旧 Gizmo，再重建
        spawnGizmo(loc.X, loc.Y, loc.Z)
        updateGizmoTransform(loc.X, loc.Y, loc.Z)
    end

    if _onSelectionChanged then _onSelectionChanged(sceneID) end
    Log.Debug("editor_selection", { entity = sceneID })
end

function EditorCore:ClearSelection()
    if _selectedID then
        local entry = SceneData:QueryActor(_selectedID)
        if entry and entry.actor then
            _bridge:SetActorHighlight(entry.actor, false)
        end
        _selectedID = nil
    end
    -- 销毁 Gizmo 箭头（替代旧的 ClearDebugAxes）
    destroyGizmo()
    if _onSelectionChanged then _onSelectionChanged(nil) end
end

function EditorCore:GetSelectedID()
    return _selectedID
end

function EditorCore:GetBridge()
    return _bridge
end

--============================================================
-- 网格对齐接口
--============================================================

function EditorCore:SetSnapEnabled(enabled)  _snapEnabled = enabled  end
function EditorCore:SetSnapSize(size)         _snapSize = size        end
function EditorCore:GetSnapEnabled()          return _snapEnabled     end
function EditorCore:GetSnapSize()             return _snapSize        end


function EditorCore:GetSelectedEntry()
    if not _selectedID then return nil end
    return SceneData:QueryActor(_selectedID)
end

--============================================================
-- 删除选中
--============================================================

function EditorCore:DeleteSelected()
    if not _selectedID then return end
    local id = _selectedID
    _selectedID = nil
    SceneData:DeleteActor(id)
end

--============================================================
-- Transform 修改（由 UI 输入框触发）
--============================================================

function EditorCore:SetSelectedTransform(x, y, z, pitch, yaw, roll, sx, sy, sz)
    if not _selectedID then return end
    local loc = UE.FVector(x, y, z)
    local rot = UE.FRotator(pitch, yaw, roll)
    local scl = UE.FVector(sx, sy, sz)
    -- UnLua 不暴露 FRotator:Quaternion()，用 MakeTransform 替代
    local t   = UE.UKismetMathLibrary.MakeTransform(loc, rot, scl)
    SceneData:ModifyActor(_selectedID, t)
end

--- 读取当前选中的 Transform（返回 9 个数字：x,y,z, pitch,yaw,roll, sx,sy,sz）
function EditorCore:GetSelectedTransformValues()
    if not _selectedID then return 0,0,0, 0,0,0, 1,1,1 end
    local entry = SceneData:QueryActor(_selectedID)
    if not entry or not entry.actor then return 0,0,0, 0,0,0, 1,1,1 end

    local t             = _bridge:GetActorTransform(entry.actor)
    -- FTransform 在 UnLua 不暴露 GetLocation/GetRotation，用 BreakTransform
    local loc, rot, scl = UE.UKismetMathLibrary.BreakTransform(t)
    return loc.X, loc.Y, loc.Z, rot.Pitch, rot.Yaw, rot.Roll, scl.X, scl.Y, scl.Z
end

--============================================================
-- 撤销/重做（快捷键由 UGCPlayerController.lua 绑定）
--============================================================

function EditorCore:Undo()
    if _currentState ~= State.Edit then return end
    SceneData:Undo()
    self:ClearSelection()
end

function EditorCore:Redo()
    if _currentState ~= State.Edit then return end
    SceneData:Redo()
end

--============================================================
-- 场景清空
--
-- 存档/读档不在 EditorCore：运行时只有 UGCPersistence（单一 *.ugc.json 包，
-- 旧 scene.json + programs.json 走它的只读迁移路径）。原先这里的
-- SaveSceneJSON / LoadSceneJSON 是无人调用的透传包装，已于 T18 删除，
-- 不要再加回来——需要导出旧格式请直接用 SceneData 上的 legacy 入口。
--============================================================

function EditorCore:ClearScene()
    self:ClearSelection()
    SceneData:Clear()
end

--============================================================
-- 拖拽移动已选中 Actor（由 UGCPlayerController Tick 驱动）
--============================================================

--- 鼠标按下时调用，记录拖拽起点和当前选中 Actor 的原始 Transform
function EditorCore:BeginDrag(x, y)
    if not _ensureBridge() then return end
    _dragStartX, _dragStartY = x, y
    _isDragging       = false
    _preDragTransform = nil
    _axisOriginWorld  = nil
    _axisParamStart   = nil

    if _selectedID then
        local entry = SceneData:QueryActor(_selectedID)
        if entry and entry.actor then
            _preDragTransform = _bridge:GetActorTransform(entry.actor)

            -- Gizmo 轴约束模式：跳过像素阈值，立即激活拖拽；
            -- 同时用当前帧鼠标位置锚定 delta 基准，消除首帧跳变
            if _activeAxis then
                local ok, rayOrigin, rayDir = _pc:DeprojectScreenPositionToWorld(x, y)
                if ok then
                    local adX, adY, adZ = 0, 0, 0
                    if _activeAxis == "X" then adX = 1
                    elseif _activeAxis == "Y" then adY = 1
                    else adZ = 1 end
                    local loc, _, _ = UE.UKismetMathLibrary.BreakTransform(_preDragTransform)
                    _axisOriginWorld = loc
                    local px, py, pz = closestOnAxis(
                        loc.X, loc.Y, loc.Z, adX, adY, adZ,
                        rayOrigin.X, rayOrigin.Y, rayOrigin.Z,
                        rayDir.X, rayDir.Y, rayDir.Z
                    )
                    _axisParamStart = (px - loc.X)*adX + (py - loc.Y)*adY + (pz - loc.Z)*adZ
                    _isDragging = true   -- Gizmo 轴：立即拖拽，无需阈值
                end
            end
        end
    end
end

--- 鼠标持续按下时调用，超过阈值后开始移动选中 Actor
function EditorCore:OnDragUpdate(x, y)
    if not _selectedID then return end
    -- 判断是否超过拖拽阈值（防止普通点击误触发）
    if not _isDragging then
        local dx = x - _dragStartX
        local dy = y - _dragStartY
        if dx * dx + dy * dy < DRAG_THRESHOLD * DRAG_THRESHOLD then return end
        _isDragging = true
    end

    local entry = SceneData:QueryActor(_selectedID)
    if not entry or not entry.actor then return end

    -- 获取当前 Actor 的位置、旋转、缩放（旋转/缩放在移动中保持不变）
    local curT = _bridge:GetActorTransform(entry.actor)
    local curLoc, rot, scl = UE.UKismetMathLibrary.BreakTransform(curT)

    local newX, newY, newZ

    if _activeAxis then
        -- 轴约束模式（Delta-based）：
        -- 以拖拽开始时的 Actor 位置为固定轴原点，用每帧鼠标射线在轴上的投影参数减去
        -- 起始参数，得到纯位移增量，杜绝首帧跳变到 Gizmo 箭头尖端的问题。
        local ok, rayOrigin, rayDir = _pc:DeprojectScreenPositionToWorld(x, y)
        if not ok then return end

        local adX, adY, adZ = 0, 0, 0
        if _activeAxis == "X" then adX = 1
        elseif _activeAxis == "Y" then adY = 1
        else adZ = 1 end

        -- 用固定锚点（拖拽起始 Actor 位置）作为轴原点，防止累积漂移
        local originX = _axisOriginWorld and _axisOriginWorld.X or curLoc.X
        local originY = _axisOriginWorld and _axisOriginWorld.Y or curLoc.Y
        local originZ = _axisOriginWorld and _axisOriginWorld.Z or curLoc.Z
        local startT  = _axisParamStart or 0

        local px, py, pz = closestOnAxis(
            originX, originY, originZ,
            adX, adY, adZ,
            rayOrigin.X, rayOrigin.Y, rayOrigin.Z,
            rayDir.X, rayDir.Y, rayDir.Z
        )
        local paramNow = (px - originX)*adX + (py - originY)*adY + (pz - originZ)*adZ
        local delta    = startT - paramNow

        newX = originX + adX * delta
        newY = originY + adY * delta
        newZ = originZ + adZ * delta
    else
        -- 自由拖拽：射线打到地面，XY 跟随鼠标，Z 贴地（已知限制，用 Gizmo Z 轴调高度）
        local ignoreList = UE.TArray(UE.AActor)
        ignoreList:Add(entry.actor)
        if _gizmoX then ignoreList:Add(_gizmoX) end
        if _gizmoY then ignoreList:Add(_gizmoY) end
        if _gizmoZ then ignoreList:Add(_gizmoZ) end

        local hitPos = _bridge:LineTraceScreenPositionMulti(x, y, ignoreList)
        if hitPos.X == 0 and hitPos.Y == 0 and hitPos.Z == 0 then return end

        newX = hitPos.X
        newY = hitPos.Y
        newZ = hitPos.Z
    end

    -- 网格对齐（轴约束和地面投影两条路径统一处理）
    if _snapEnabled then
        newX = snapToGrid(newX, _snapSize)
        newY = snapToGrid(newY, _snapSize)
        newZ = snapToGrid(newZ, _snapSize)
    end

    -- 应用新位置（保持原旋转和缩放）
    local newLoc = UE.FVector(newX, newY, newZ)
    local newT   = UE.UKismetMathLibrary.MakeTransform(newLoc, rot, scl)
    _bridge:SetActorTransform(entry.actor, newT)

    -- 同步移动 Gizmo 箭头到新位置
    updateGizmoTransform(newX, newY, newZ)
end

--- 鼠标松开时调用，若发生了拖拽则将移动记录到撤销栈
function EditorCore:EndDrag()
    if _isDragging and _selectedID and _preDragTransform then
        local entry = SceneData:QueryActor(_selectedID)
        if entry and entry.actor then
            local finalT = _bridge:GetActorTransform(entry.actor)
            -- 临时恢复原位 → ModifyActor 读到旧位置后再设为新位置，正确入撤销栈
            _bridge:SetActorTransform(entry.actor, _preDragTransform)
            SceneData:ModifyActor(_selectedID, finalT)
        end
        -- 通知 UI 刷新 Transform 面板
        if _onSelectionChanged then _onSelectionChanged(_selectedID) end
    end
    _isDragging       = false
    _preDragTransform = nil
    _axisOriginWorld  = nil
    _axisParamStart   = nil
    -- _activeAxis 不在此处清除：保持轴约束「粘滞」，下次 BeginDrag 可直接沿同轴拖拽；
    -- 点击其他位置 / 切换选中时由 ClearSelection / SelectByID（→destroyGizmo）清除。
end

--- 查询当前是否正在拖拽（供 PlayerController 判断）
function EditorCore:IsMouseDown()
    if not _bridge then return false end
    return _bridge:IsMouseButtonDown()
end

--- 查询 Escape 键当前是否按下（供 PlayerController 做边沿检测）
function EditorCore:IsEscapeDown()
    if not _bridge then return false end
    return _bridge:IsEscapeDown()
end

--- 每帧由 PlayerController Tick 调用，根据相机距离刷新 Gizmo 缩放
--- 只在有选中且 Gizmo 存在时生效，其余情况为空操作
function EditorCore:UpdateGizmoScale()
    if not _selectedID then return end
    if not (_gizmoX or _gizmoY or _gizmoZ) then return end

    local entry = SceneData:QueryActor(_selectedID)
    if not entry or not entry.actor then return end

    -- 读取 Actor 当前位置，重新调用 updateGizmoTransform 触发缩放计算
    local t = _bridge:GetActorTransform(entry.actor)
    local loc, _, _ = UE.UKismetMathLibrary.BreakTransform(t)
    updateGizmoTransform(loc.X, loc.Y, loc.Z)
end

--============================================================
-- AnimAgent 动态 GLB 资产支持
--
-- 设计：dyn 资产走和其他 placeable 完全一致的 SpawnPlaceable + SceneData 流程，
-- 区别仅在 spawn 出来后立即向 AAnimAgentDynamicPlaceable 注入实际的 UStaticMesh。
--============================================================

--- 通过 _bridge:GetOwner() 拿 PC，再 GetComponentByClass 取 ImportBridge
local function _getImportBridge()
    if not _bridge then return nil end
    local pc = nil
    pcall(function() pc = _bridge:GetOwner() end)
    if not pc then return nil end
    local importBridge = nil
    pcall(function() importBridge = pc:GetComponentByClass(UE.UAnimImportBridge) end)
    return importBridge
end

--- 给一个刚 spawn 出来的 AAnimAgentDynamicPlaceable 注入 mesh
function EditorCore:_InjectDynMesh(actor, prefabName)
    if not actor then return end
    local dyn = PrefabRegistry.GetDynamicGLB(prefabName)
    if not dyn then return end

    local importBridge = _getImportBridge()
    if not importBridge then
        Log.Warn("dyn_mesh_bridge_missing", { hint = "UAnimImportBridge 未挂载，跳过 dyn mesh 注入" })
        return
    end

    local mesh = nil
    pcall(function() mesh = importBridge:FindCachedMesh(dyn.uuid) end)
    if not mesh then
        -- ImportGLBAsync 当前同步：调完立刻能从缓存拿
        pcall(function() importBridge:ImportGLBAsync(dyn.uuid, dyn.glb_path) end)
        pcall(function() mesh = importBridge:FindCachedMesh(dyn.uuid) end)
    end
    if not mesh then
        Log.Warn("dyn_mesh_load_failed", { uuid = tostring(dyn.uuid) })
        return
    end

    pcall(function() actor:SetDynMesh(mesh, dyn.uuid) end)
end

return EditorCore
