--[[
    WBP_UGCBlueprintEditor.lua
    游戏内蓝图节点图编辑器（支持关卡图 + per-Actor 图）

    蓝图 Widget 结构（WBP_UGCBlueprintEditor）：
    ┌────────────────────────────────────────────────────────┐
    │  垂直框 VerticalBox (Fill)                              │
    │  ├─ 水平框 HorizontalBox (Fill)                         │
    │  │    ├─ 尺寸框 SizeBox (w=200)                         │
    │  │    │    └─ 边框 Border → 滚动框 [w_scroll_nodeLib]   │
    │  │    └─ 覆层 Overlay (Fill)                            │
    │  │         ├─ 画布面板 [w_canvas_main]                  │
    │  │         └─ UUGCWireOverlay [w_wire_overlay]          │
    │  │              可见性 = 命中测试不可见 HitTestInvisible │
    │  └─ 边框 Border (h=auto) → 水平框       底栏            │
    │       w_btn_compile / w_btn_save / w_btn_load           │
    │       w_btn_clear   / w_btn_close / w_text_status       │
    │  └─ 尺寸框 [w_error_panel]（默认折叠，验证失败时展开）     │
    │       └─ 边框 [w_error_border_bg]                        │
    │            └─ 滚动框 [w_scroll_errors]（运行时填行）      │
    └────────────────────────────────────────────────────────┘

    T16：错误列表面板不是手工摆的 —— 由编辑器命令 `UGC.SetupErrorListUI` 生成
    （Source/FPS/UGC/UGCWidgetSetupCommands.cpp），行控件是 `/Game/_UGC/UI/WBP_UGCErrorRow`。
    点击某一行 → FocusError(row)：把该节点挪到画布中心并高亮节点/引脚（再点其它行自动还原）。
]]

local NodeRegistry = require("System.UI.UGC.UGCNodeRegistry")
local GraphCompiler = require("Gameplay.UGC.UGCGraphCompiler")
local ErrorList = require("Gameplay.UGC.UGCErrorList")

local M = UnLua.Class()

--============================================================
-- 内部状态
--============================================================

-- 多图支持：{[programID] = {nodes, connections, nextID}}
-- programID = "level_main"        → 关卡级全局图（F8 打开）
-- programID = "actor_prog_{id}"   → 单个 Actor 的图
local _graphs   = {}
local _activeID = "level_main"
-- Current graph view cache only. Never serialize or store these UObject references in _graphs.
local _nodeViews = {}

local function getG()
    local g = _graphs[_activeID]
    if not g then
        _graphs[_activeID] = { nodes = {}, connections = {}, nextID = 1 }
        g = _graphs[_activeID]
    end
    return g
end

-- 以下状态属于编辑器实例，不随图表切换
local _panOffset        = { x = 0, y = 0 }
local _dragNodeID       = nil
local _dragStartMouse   = nil
local _dragStartNodePos = nil
local _pendingPin       = nil   -- {nodeID, pinName, isOutput}
local _isDirtyWires     = false

-- T10：编辑器共享 ViewModel 与订阅句柄。连线重绘由 ViewModel 的 "wires" 通道（文档事件）驱动，
-- Destruct 里必须解绑，否则界面关闭后仍会被文档事件引用（dead UObject 无法回收）。
local _viewModel        = nil
local _viewSubscription = nil

-- T16：错误列表定位高亮（记着当前高亮的节点/引脚，切换定位时先还原上一个）
local _highlightNodeID  = nil
local _highlightPin     = nil

local NODE_CLASS_PATH    = "/Game/_UGC/UI/WBP_UGCNode.WBP_UGCNode_C"
local NODE_LIB_BTN_PATH  = "/Game/_UGC/UI/WBP_UGCNodeLibBtn.WBP_UGCNodeLibBtn_C"
local ERROR_ROW_PATH     = "/Game/_UGC/UI/WBP_UGCErrorRow.WBP_UGCErrorRow_C"
local _nodeClass         = nil
local _nodeLibBtnClass   = nil
local _errorRowClass     = nil

local LOG_TAG       = "[System.UI.UGC.WBP_UGCBlueprintEditor]"
local DEBUG_VERBOSE = false

local function Log(msg)   print(LOG_TAG .. " " .. tostring(msg)) end
local function Warn(msg)  print(LOG_TAG .. "[Warn] " .. tostring(msg)) end
local function Debug(msg) if DEBUG_VERBOSE then print(LOG_TAG .. "[Debug] " .. tostring(msg)) end end

local function getNodeClass()
    if not _nodeClass then _nodeClass = UE.UClass.Load(NODE_CLASS_PATH) end
    return _nodeClass
end
local function getNodeLibBtnClass()
    if not _nodeLibBtnClass then _nodeLibBtnClass = UE.UClass.Load(NODE_LIB_BTN_PATH) end
    return _nodeLibBtnClass
end
local function getErrorRowClass()
    if not _errorRowClass then _errorRowClass = UE.UClass.Load(ERROR_ROW_PATH) end
    return _errorRowClass
end

--- 取控件：优先 UnLua 绑定字段（self.w_xxx），拿不到就按名字查 WidgetTree。
--- 新加的错误列表面板走的是后一条路径（不依赖控件是否勾了 Is Variable）。
local function widget(self, name)
    local found = self[name]
    if found then return found end
    if self.GetWidgetFromName then
        local ok, resolved = pcall(function() return self:GetWidgetFromName(name) end)
        if ok and resolved then return resolved end
    end
    return nil
end

-- Drop 时 FDragDropEvent 在 UnLua 未注册 GetScreenSpacePosition，多级降级
local function resolveDropScreenPos(self, dragEvent)
    local ok, pos = pcall(function()
        return UE.UKismetInputLibrary.PointerEvent_GetScreenSpacePosition(dragEvent)
    end)
    if ok and pos then return pos.X, pos.Y, "drag_event" end

    local pc = self:GetOwningPlayer()
    if pc then
        local mouseOk, mx, my = pc:GetMousePosition()
        if mouseOk then return mx, my, "player" end
    end

    if self._cachedMouseX and self._cachedMouseY then
        return self._cachedMouseX, self._cachedMouseY, "cache"
    end
    return nil, nil, "none"
end

--============================================================
-- 生命周期
--============================================================

function M:Construct()
    -- BuildNodeLib 延迟到首次 OpenGraph 调用，避免 Construct 期间创建子 Widget
    -- 导致 UnLua TryBind 重入崩溃（0xffffffffffffffff）
    self._nodeLibBuilt = false

    local function bind(name, fn)
        local w = self[name]
        if w and w.OnClicked then w.OnClicked:Add(self, fn)
        else Warn("缺少按钮: " .. name) end
    end
    bind("w_btn_compile", M.OnClickCompile)
    bind("w_btn_save",    M.OnClickSave)
    bind("w_btn_load",    M.OnClickLoad)
    bind("w_btn_clear",   M.OnClickClear)
    bind("w_btn_close",   M.OnClickClose)

    self:SetStatus("关卡蓝图 — 从左侧选择节点类型放置")
    self:BindViewModel()
    Log("构建完成")
end

--============================================================
-- T10：ViewModel 绑定 / 解绑
--============================================================

--- 拉取编辑器共享 ViewModel 并订阅 "wires" 通道（幂等）
function M:BindViewModel()
    if _viewSubscription then return _viewModel end
    local ok, EditorCore = pcall(require, "Gameplay.UGC.UGCEditorCore")
    if not ok or not EditorCore or not EditorCore.GetViewModel then return nil end
    _viewModel = EditorCore:GetViewModel()
    if not _viewModel then return nil end

    _viewModel:BindView(self)
    _viewSubscription = _viewModel:Subscribe(function(channel)
        -- 文档变化（AI 放置/删除、撤销重做恢复图程序、加载项目…）→ 连线需要重绘，
        -- 不需要 Tick 轮询也能刷新。
        if channel == "wires" then _isDirtyWires = true end
    end)
    return _viewModel
end

--- Tick 用：现在是否真的需要重绘（拖连线必须逐帧，其余情况由事件标脏）
function M:NeedsWireRefresh()
    return _isDirtyWires or _pendingPin ~= nil
end

--- 界面销毁：解绑订阅与视图弱引用（T10）
function M:Destruct()
    if _viewModel and _viewSubscription then
        _viewModel:Unsubscribe(_viewSubscription)
    end
    if _viewModel then _viewModel:UnbindView() end
    _viewSubscription = nil
    _viewModel        = nil
    _pendingPin       = nil
    _isDirtyWires     = false
end

--============================================================
-- 侧边栏：节点库
--============================================================

function M:BuildNodeLib()
    if not self.w_scroll_nodeLib then Warn("缺少 w_scroll_nodeLib"); return end
    self.w_scroll_nodeLib:ClearChildren()

    local pc  = self:GetOwningPlayer()
    local cls = getNodeLibBtnClass()
    if not pc or not cls then return end

    local catColor = {
        ["事件"] = UE.FLinearColor(0.63, 0.06, 0.06, 1),
        ["条件"] = UE.FLinearColor(0.06, 0.44, 0.19, 1),
        ["动作"] = UE.FLinearColor(0.06, 0.31, 0.63, 1),
    }

    for _, cat in ipairs(NodeRegistry.Categories) do
        local header = UE.UWidgetBlueprintLibrary.Create(pc, cls, pc)
        if header then
            if header.w_text_label then
                header.w_text_label:SetText(cat.name)
                local col = catColor[cat.name]
                if col then
                    local ok = pcall(function()
                        header.w_text_label:SetColorAndOpacity(UE.FSlateColor(col))
                    end)
                    if not ok then
                        pcall(function() header.w_text_label:SetColorAndOpacity(col) end)
                    end
                end
            end
            self.w_scroll_nodeLib:AddChild(header)
        end

        for _, item in ipairs(cat.items) do
            local btn = UE.UWidgetBlueprintLibrary.Create(pc, cls, pc)
            if btn then
                if btn.w_text_label then btn.w_text_label:SetText(item.label) end
                if btn.SetNodeType  then btn:SetNodeType(item.type) end
                self.w_scroll_nodeLib:AddChild(btn)
            end
        end
    end
end

--============================================================
-- 拖拽放置
--============================================================

function M:OnMouseMove(geometry, pointerEvent)
    -- 缓存 Slate 绝对坐标（PointerEvent 坐标空间），用于 UpdateWires 非全屏偏移修正
    local ok, pos = pcall(function()
        return UE.UKismetInputLibrary.PointerEvent_GetScreenSpacePosition(pointerEvent)
    end)
    if ok and pos then
        self._slateMX = pos.X
        self._slateMY = pos.Y
    end
    return UE.UWidgetBlueprintLibrary.Unhandled()
end

function M:OnDragOver(geometry, pointerEvent, operation)
    -- 从 PointerEvent 缓存 Slate 绝对坐标（替代 PC:GetMousePosition 的视口本地坐标）
    local ok, pos = pcall(function()
        return UE.UKismetInputLibrary.PointerEvent_GetScreenSpacePosition(pointerEvent)
    end)
    if ok and pos then
        self._slateMX = pos.X
        self._slateMY = pos.Y
    end
    Debug("OnDragOver tag=" .. (operation and tostring(operation.Tag) or "nil"))
    return true
end

function M:OnDrop(geometry, pointerEvent, operation)
    if not operation then Warn("OnDrop: operation 为空"); return false end

    local nodeType = tostring(operation.Tag)
    if not nodeType or nodeType == "" or nodeType == "None" then
        Warn("OnDrop: nodeType 非法"); return false
    end
    if not self.w_canvas_main then Warn("OnDrop: 缺少 w_canvas_main"); return false end

    local mx, my, source = resolveDropScreenPos(self, pointerEvent)
    if not mx or not my then Warn("OnDrop: 无法解析鼠标坐标"); return false end

    local canvasGeo = self.w_canvas_main:GetCachedGeometry()
    local local2d   = UE.USlateBlueprintLibrary.AbsoluteToLocal(canvasGeo, UE.FVector2D(mx, my))
    Log(string.format("OnDrop[%s] %s at %.1f,%.1f", source, nodeType, local2d.X, local2d.Y))
    self:SetStatus("放置中: " .. nodeType)
    self:PlaceNode(local2d.X - _panOffset.x, local2d.Y - _panOffset.y, nodeType)
    return true
end

--============================================================
-- 画布点击
--============================================================

function M:OnMouseButtonDown(geometry, pointerEvent)
    if _pendingPin then
        _pendingPin = nil
        if self.w_wire_overlay then
            self.w_wire_overlay:SetPendingWire(UE.FVector2D(0,0), UE.FVector2D(0,0), false)
        end
        self:SetStatus("就绪")
        return UE.UWidgetBlueprintLibrary.Handled()
    end
    return UE.UWidgetBlueprintLibrary.Unhandled()
end

--============================================================
-- 放置节点
--============================================================

function M:PlaceNode(canvasX, canvasY, nodeType)
    local pc  = self:GetOwningPlayer()
    local cls = getNodeClass()
    if not pc or not cls or not self.w_canvas_main then
        Warn("PlaceNode 中止: pc=" .. tostring(pc~=nil)
            .. " cls=" .. tostring(cls~=nil)
            .. " canvas=" .. tostring(self.w_canvas_main~=nil))
        return
    end

    local g  = getG()
    local id = "node_" .. g.nextID
    g.nextID = g.nextID + 1

    local def    = NodeRegistry.Definitions[nodeType]
    local params = {}
    for _, p in ipairs(def and def.params or {}) do
        params[p.name] = p.default
    end

    local nodeData = { id=id, type=nodeType, pos={x=canvasX, y=canvasY}, params=params }

    local widget = UE.UWidgetBlueprintLibrary.Create(pc, cls, pc)
    if not widget then Warn("创建节点 Widget 失败: " .. nodeType); return end

    if widget.InitNode then
        local ok, err = pcall(function() widget:InitNode(nodeData, self) end)
        if not ok then Warn("InitNode 异常: " .. tostring(err)) end
    else
        Warn("节点 Widget 没有 InitNode 方法")
    end

    widget:SetVisibility(UE.ESlateVisibility.Visible)
    g.nodes[id] = nodeData
    _nodeViews[id] = { widget = widget, canvasSlot = nil }

    -- 优先 AddChildToCanvas（返回已有 slot），回退 AddChild + SlotAsCanvasSlot
    local slot = nil
    if self.w_canvas_main.AddChildToCanvas then
        local ok, cs = pcall(function() return self.w_canvas_main:AddChildToCanvas(widget) end)
        if ok then slot = cs end
    end
    if not slot then
        self.w_canvas_main:AddChild(widget)
        slot = UE.UWidgetLayoutLibrary.SlotAsCanvasSlot(widget)
    end

    if slot then
        local px = canvasX + _panOffset.x
        local py = canvasY + _panOffset.y
        slot:SetAutoSize(true)
        slot:SetAlignment(UE.FVector2D(0.5, 0.5))
        slot:SetPosition(UE.FVector2D(px, py))
        _nodeViews[id].canvasSlot = slot
        Log(string.format("SetPosition %.1f,%.1f", px, py))
    else
        Warn("PlaceNode: 未获取到 CanvasSlot，节点可能不可见")
    end

    _isDirtyWires = true
    Log("放置节点: " .. id .. " (" .. nodeType .. ")")
    self:SetStatus("已放置: " .. id)
    return id
end

--============================================================
-- 多图管理（核心 API）
--============================================================

--- 切换到指定 programID 的图，清空画布并重建节点 Widget
--- @param programID string  图标识（"level_main" 或 "actor_prog_N"）
--- @param title     string  可选标题，显示在底栏
--- @param graphData table   可选：直接传入图数据，避免调用方先 LoadGraphData 再 OpenGraph
---                          （分两步调用会导致旧 widget 孤立，Lua GC 在后续 Create 中
---                          触发 UnLua 对象图并发修改崩溃）
function M:OpenGraph(programID, title, graphData)
    -- 首次调用时构建节点库（延迟自 Construct，避免 TryBind 重入崩溃）
    if not self._nodeLibBuilt then
        self._nodeLibBuilt = true
        self:BuildNodeLib()
    end

    -- 先保存当前图到 SceneData（避免切换丢失）
    self:SaveCurrentGraphToSceneData()

    -- 取消中间状态
    _pendingPin    = nil
    _dragNodeID    = nil
    _isDirtyWires  = false

    -- View cache is instance-lifetime state. The graph document stays pure and
    -- never retains Widget/CanvasSlot UObject references.
    for _, view in pairs(_nodeViews) do
        if view.widget and UE.UKismetSystemLibrary.IsValid(view.widget) then
            view.widget:RemoveFromParent()
        end
    end
    _nodeViews = {}
    if self.w_canvas_main then self.w_canvas_main:ClearChildren() end

    if self.w_wire_overlay then
        self.w_wire_overlay:BeginWireUpdate()
        self.w_wire_overlay:EndWireUpdate()
        self.w_wire_overlay:SetPendingWire(UE.FVector2D(0,0), UE.FVector2D(0,0), false)
    end

    -- 切换活动图
    _activeID = programID or "level_main"

    -- 如果直接传入了图数据，写入 _graphs（替代单独调用 LoadGraphData）
    if graphData then
        local g = {
            nodes       = {},
            connections = graphData.connections or {},
            nextID      = graphData.nextID or 1,
        }
        for _, n in ipairs(graphData.nodes or {}) do
            if n.id then
                g.nodes[n.id] = {
                    id     = n.id,
                    type   = n.type or "Unknown",
                    pos    = n.pos or { x = 0, y = 0 },
                    params = n.params or {},
                }
            end
        end
        _graphs[_activeID] = g
    end

    -- 更新底栏提示
    local displayTitle = title
        or ((_activeID == "level_main") and "关卡蓝图 — 全局逻辑"
            or ("Actor 蓝图: " .. _activeID))
    self:SetStatus(displayTitle)

    -- 重建新图的节点 Widget
    if self.w_canvas_main then
        local pc  = self:GetOwningPlayer()
        local cls = getNodeClass()
        if pc and cls then
            for _, nodeData in pairs(getG().nodes) do
                local widget = UE.UWidgetBlueprintLibrary.Create(pc, cls, pc)
                if widget then
                    self.w_canvas_main:AddChild(widget)
                    local slot = UE.UWidgetLayoutLibrary.SlotAsCanvasSlot(widget)
                    _nodeViews[nodeData.id] = { widget = widget, canvasSlot = slot }
                    if slot then
                        slot:SetAutoSize(true)
                        slot:SetAlignment(UE.FVector2D(0.5, 0.5))
                        slot:SetPosition(UE.FVector2D(
                            nodeData.pos.x + _panOffset.x,
                            nodeData.pos.y + _panOffset.y))
                    end
                    if widget.InitNode then
                        pcall(function() widget:InitNode(nodeData, self) end)
                    end
                    widget:SetVisibility(UE.ESlateVisibility.Visible)
                end
            end
        end
    end

    _isDirtyWires = true
    Log("OpenGraph: " .. _activeID)
end

--- 返回当前活动图的可序列化数据（不含 Widget 引用）
function M:GetCurrentGraphData()
    local g = getG()
    local nodes = {}
    for id, n in pairs(g.nodes) do
        table.insert(nodes, {
            id     = id,
            type   = n.type,
            pos    = { x = n.pos.x, y = n.pos.y },
            params = n.params or {},
        })
    end
    return {
        programID   = _activeID,
        nodes       = nodes,
        connections = g.connections,
        nextID      = g.nextID,
    }
end

--- 从序列化数据加载指定图（不立即重建 Widget，需调 OpenGraph 触发重建）
function M:LoadGraphData(programID, data)
    if not data then return end
    local g = {
        nodes       = {},
        connections = data.connections or {},
        nextID      = data.nextID or 1,
    }
    for _, n in ipairs(data.nodes or {}) do
        if n.id then
            g.nodes[n.id] = {
                id     = n.id,
                type   = n.type or "Unknown",
                pos    = n.pos or { x = 0, y = 0 },
                params = n.params or {},
                -- widget = nil，等 OpenGraph 时重建
            }
        end
    end
    _graphs[programID] = g
    Log("LoadGraphData: " .. tostring(programID)
        .. " nodes=" .. tostring(#(data.nodes or {})))
end

--- 返回所有图的可序列化数据（供场景保存一次性打包）
function M:GetAllGraphsData()
    local result = {}
    for pid, g in pairs(_graphs) do
        local nodes = {}
        for id, n in pairs(g.nodes) do
            table.insert(nodes, {
                id     = id,
                type   = n.type,
                pos    = { x = n.pos.x, y = n.pos.y },
                params = n.params or {},
            })
        end
        result[pid] = {
            nodes       = nodes,
            connections = g.connections,
            nextID      = g.nextID,
        }
    end
    return result
end

--- 将当前图写入 UGCSceneData（内存级，文件保存由 WBP_UGCEditor 统一触发）
function M:SaveCurrentGraphToSceneData()
    local ok, SceneData = pcall(require, "Gameplay.UGC.UGCSceneData")
    if not ok or not SceneData then return end

    local data = self:GetCurrentGraphData()
    -- 通用调用：key 就是 programID 字符串（"level_main" / "actor_prog_N"）
    SceneData:SetScript(_activeID, data)
end

--============================================================
-- 引脚连线
--============================================================

function M:OnPinClicked(nodeID, pinName, isOutput)
    if not _pendingPin then
        _pendingPin = { nodeID=nodeID, pinName=pinName, isOutput=isOutput }
        self:SetStatus("连线中 — 点击目标引脚完成，点击空白取消")
        return
    end

    -- 同向引脚：重置起点
    if _pendingPin.isOutput == isOutput then
        _pendingPin = { nodeID=nodeID, pinName=pinName, isOutput=isOutput }
        return
    end

    -- 自连检测
    if _pendingPin.nodeID == nodeID then
        self:SetStatus("不能连接同一节点的引脚")
        return
    end

    local fromID, fromPin, toID, toPin
    if _pendingPin.isOutput then
        fromID, fromPin = _pendingPin.nodeID, _pendingPin.pinName
        toID,   toPin   = nodeID, pinName
    else
        fromID, fromPin = nodeID, pinName
        toID,   toPin   = _pendingPin.nodeID, _pendingPin.pinName
    end

    local g = getG()
    table.insert(g.connections, {
        from_id  = fromID, from_pin = fromPin,
        to_id    = toID,   to_pin   = toPin,
    })
    _pendingPin   = nil
    _isDirtyWires = true

    if self.w_wire_overlay then
        self.w_wire_overlay:SetPendingWire(UE.FVector2D(0,0), UE.FVector2D(0,0), false)
    end
    self:SetStatus("连线已创建")
    Log(string.format("连线: %s.%s → %s.%s", fromID, fromPin, toID, toPin))
end

--============================================================
-- 连线绘制（PC Tick 驱动）
--============================================================

function M:UpdateWires(mouseAbsX, mouseAbsY)
    -- 优先使用从 PointerEvent 缓存的 Slate 绝对坐标（修正非全屏模式下的坐标偏移）
    -- PC:GetMousePosition() 返回视口本地像素，AbsoluteToLocal 需要 Slate 绝对坐标，
    -- 全屏时两者一致，窗口模式时有偏移。PointerEvent 坐标与 AbsoluteToLocal 同一坐标系。
    local mx = self._slateMX or mouseAbsX
    local my = self._slateMY or mouseAbsY
    self._cachedMouseX = mx
    self._cachedMouseY = my

    if not self.w_wire_overlay then return end
    if not self.w_canvas_main  then return end
    if not _isDirtyWires and not _pendingPin then return end

    local canvasGeo = self.w_canvas_main:GetCachedGeometry()
    local function absToCanvas(absPos)
        return UE.USlateBlueprintLibrary.AbsoluteToLocal(canvasGeo, absPos)
    end

    local g = getG()
    self.w_wire_overlay:BeginWireUpdate()

    for _, conn in ipairs(g.connections) do
        local fromNode = g.nodes[conn.from_id]
        local toNode   = g.nodes[conn.to_id]
        local fromView = fromNode and _nodeViews[fromNode.id]
        local toView = toNode and _nodeViews[toNode.id]
        if fromView and fromView.widget and toView and toView.widget then
            local fromRow = fromView.widget:GetPinRow(conn.from_pin)
            local toRow   = toView.widget:GetPinRow(conn.to_pin)
            if fromRow and toRow then
                local startAbs = fromRow:GetPinOutAbsPos()
                local endAbs   = toRow:GetPinInAbsPos()
                if startAbs and endAbs then
                    local s = absToCanvas(startAbs)
                    local e = absToCanvas(endAbs)
                    self.w_wire_overlay:AddWire(s, e, 1, 1, 1, 1, 2.0)
                end
            end
        end
    end

    self.w_wire_overlay:EndWireUpdate()
    if not _pendingPin then _isDirtyWires = false end

    if _pendingPin then
        local fromNode = g.nodes[_pendingPin.nodeID]
        local fromView = fromNode and _nodeViews[fromNode.id]
        if fromView and fromView.widget then
            local row = fromView.widget:GetPinRow(_pendingPin.pinName)
            if row then
                local pinAbs = _pendingPin.isOutput
                    and row:GetPinOutAbsPos()
                    or  row:GetPinInAbsPos()
                if pinAbs then
                    local s = absToCanvas(pinAbs)
                    local e = absToCanvas(UE.FVector2D(mx, my))
                    self.w_wire_overlay:SetPendingWire(s, e, true)
                end
            end
        end
    end
end

function M:IsDraggingPin()
    return _pendingPin ~= nil
end

--============================================================
-- 节点拖拽（PC Tick 驱动）
--============================================================

function M:BeginNodeDrag(nodeID, sx, sy)
    local node = getG().nodes[nodeID]
    if not node then
        Warn("BeginNodeDrag: 节点不存在 " .. tostring(nodeID) .. " (activeID=" .. _activeID .. ")")
        return
    end
    _dragNodeID       = nodeID
    _dragStartMouse   = { x=sx, y=sy }
    _dragStartNodePos = { x=node.pos.x, y=node.pos.y }
    Debug("BeginNodeDrag: " .. nodeID .. " at " .. string.format("%.0f,%.0f", sx, sy))
end

function M:OnDragTick(sx, sy)
    if not _dragNodeID or not _dragStartMouse then return end
    local dx = sx - _dragStartMouse.x
    local dy = sy - _dragStartMouse.y
    self:MoveNodeTo(_dragNodeID,
        _dragStartNodePos.x + dx,
        _dragStartNodePos.y + dy)
    _isDirtyWires = true
end

function M:EndNodeDrag()
    _dragNodeID       = nil
    _dragStartMouse   = nil
    _dragStartNodePos = nil
end

function M:IsDraggingNode()
    return _dragNodeID ~= nil
end

function M:MoveNodeTo(nodeID, cx, cy)
    local node = getG().nodes[nodeID]
    local view = _nodeViews[nodeID]
    if not node or not view or not view.widget then
        Warn("MoveNodeTo: 找不到节点 View: " .. tostring(nodeID))
        return
    end
    node.pos.x = cx
    node.pos.y = cy
    local slot = view.canvasSlot
    if not slot then
        slot = UE.UWidgetLayoutLibrary.SlotAsCanvasSlot(view.widget)
        if slot then
            view.canvasSlot = slot
        else
            Warn("MoveNodeTo: SlotAsCanvasSlot 返回 nil，节点 " .. nodeID .. " 无法移动")
            return
        end
    end
    slot:SetPosition(UE.FVector2D(cx + _panOffset.x, cy + _panOffset.y))
    _isDirtyWires = true   -- 节点移动后连线需要重绘
end

--============================================================
-- 按钮事件
--============================================================

function M:OnClickClose()
    self:SaveCurrentGraphToSceneData()

    for _, view in pairs(_nodeViews) do
        if view.widget and UE.UKismetSystemLibrary.IsValid(view.widget) then view.widget:RemoveFromParent() end
    end
    _nodeViews = {}
    if self.w_canvas_main then self.w_canvas_main:ClearChildren() end

    local UIManager = require("Gameplay.Core.UIManager")
    local pc = self:GetOwningPlayer()
    if pc and pc.SetBlueprintEditor then pc:SetBlueprintEditor(nil) end
    UIManager:CloseWindow("WBP_UGCBlueprintEditor")
end

function M:OnClickCompile()
    local graph = self:GetCurrentGraphData()
    local report = GraphCompiler:Compile(graph)
    local status = GraphCompiler:FormatReport(report)

    if report.ok then
        self:ClearErrors()
        self:SaveCurrentGraphToSceneData()
        local ok, Runner = pcall(require, "Gameplay.UGC.UGCProgramRunner")
        if ok and Runner and Runner.InvalidateProgram then
            Runner:InvalidateProgram(_activeID)
            Runner:CompileProgram(_activeID)
        end
        self:SetStatus(status)
        Log(status)
    else
        -- T16：失败时把整份错误/警告渲染成可点击列表（此前只显示第一条）
        local model = self:ShowErrors(report)
        if model and model.total > model.shown then
            status = status .. string.format("（列表显示前 %d 条，共 %d 条）", model.shown, model.total)
        end
        self:SetStatus(status)
        Warn(status)
    end
end

--============================================================
-- T16：验证错误列表（渲染 + 点击定位）
--============================================================

--- 渲染错误/警告列表；返回 UGCErrorList.Build 的模型（含渲染计数）
--- @param report table UGCGraphCompiler:Compile 的返回
function M:ShowErrors(report)
    local list  = widget(self, "w_scroll_errors")
    local panel = widget(self, "w_error_panel")
    if not list or not panel then
        Warn("错误列表面板缺失：请先在编辑器里执行 UGC.SetupErrorListUI")
        return nil
    end

    local model = ErrorList.Build(report, ErrorList.DEFAULT_LIMIT)
    list:ClearChildren()

    local pc  = self:GetOwningPlayer()
    local cls = getErrorRowClass()
    local rendered = 0
    if pc and cls then
        for _, row in ipairs(model.rows) do
            local rowWidget = UE.UWidgetBlueprintLibrary.Create(pc, cls, pc)
            if rowWidget and rowWidget.SetErrorRow then
                rowWidget:SetErrorRow(row, function(clicked) self:FocusError(clicked) end)
                list:AddChild(rowWidget)
                rendered = rendered + 1
            end
        end
    end
    model.rendered = rendered

    panel:SetVisibility(UE.ESlateVisibility.Visible)
    Log(string.format("错误列表：%d 条（错误 %d / 警告 %d），渲染 %d 行",
        model.total, model.errors, model.warnings, rendered))
    return model
end

--- 清空并收起错误列表（验证通过 / 清空画布 / 关闭界面时调用）
function M:ClearErrors()
    local list = widget(self, "w_scroll_errors")
    if list then list:ClearChildren() end
    local panel = widget(self, "w_error_panel")
    if panel then panel:SetVisibility(UE.ESlateVisibility.Collapsed) end
    self:ClearFocusHighlight()
end

--- 点击错误行：把节点挪到画布中心并高亮节点/引脚
--- @param row table UGCErrorList 产出的行
--- @return boolean 是否定位成功
function M:FocusError(row)
    if not ErrorList.IsFocusable(row) then
        self:SetStatus("该条目不指向具体节点：" .. tostring(row and row.message or "未知问题"))
        return false
    end

    local node = getG().nodes[row.nodeId]
    if not node then
        self:SetStatus("节点已不存在：" .. tostring(row.nodeId))
        return false
    end

    -- canvas 本地坐标 = node.pos + _panOffset，所以把节点摆到画布中心就等于反推 _panOffset
    -- 注意：FGeometry 的方法不能直接在 Lua 里调（GetLocalSize 会报 not callable），
    -- 必须走 USlateBlueprintLibrary 的静态函数 —— 与上面 AbsoluteToLocal 同一套路。
    local okGeo, geo = pcall(function() return self.w_canvas_main:GetCachedGeometry() end)
    if okGeo and geo then
        local size = UE.USlateBlueprintLibrary.GetLocalSize(geo)
        _panOffset.x = size.X * 0.5 - node.pos.x
        _panOffset.y = size.Y * 0.5 - node.pos.y
    end
    self:RelayoutNodes()
    self:HighlightNode(row.nodeId, row.pin)
    _isDirtyWires = true   -- 节点动了，连线要重画

    self:SetStatus(string.format("已定位到 %s%s（来自验证列表）", tostring(node.id),
        row.pin and ("." .. tostring(row.pin)) or ""))
    Log(string.format("定位错误条目 #%s → 节点 %s%s", tostring(row.index), tostring(node.id),
        row.pin and ("." .. tostring(row.pin)) or ""))
    return true
end

--- 按当前 _panOffset 重排所有节点（MoveNodeTo 只动一个节点，这里整屏平移）
function M:RelayoutNodes()
    for id, view in pairs(_nodeViews) do
        local node = getG().nodes[id]
        if node and view.widget then
            local slot = view.canvasSlot
            if not slot then
                slot = UE.UWidgetLayoutLibrary.SlotAsCanvasSlot(view.widget)
                view.canvasSlot = slot
            end
            if slot then
                slot:SetPosition(UE.FVector2D(node.pos.x + _panOffset.x, node.pos.y + _panOffset.y))
            end
        end
    end
end

--- 高亮一个节点（可选再高亮它的某个引脚行）；先还原上一个高亮
function M:HighlightNode(nodeID, pinName)
    self:ClearFocusHighlight()

    local view = _nodeViews[nodeID]
    if view and view.widget and view.widget.SetHighlight then
        pcall(function() view.widget:SetHighlight(true) end)
        _highlightNodeID = nodeID
    end

    if pinName and view and view.widget and view.widget.GetPinRow then
        local row = view.widget:GetPinRow(pinName)
        if row and row.SetHighlight then
            pcall(function() row:SetHighlight(true) end)
            _highlightPin = { nodeID = nodeID, pin = pinName }
        end
    end
end

function M:ClearFocusHighlight()
    if _highlightNodeID then
        local view = _nodeViews[_highlightNodeID]
        if view and view.widget and view.widget.SetHighlight then
            pcall(function() view.widget:SetHighlight(false) end)
        end
        _highlightNodeID = nil
    end
    if _highlightPin then
        local view = _nodeViews[_highlightPin.nodeID]
        if view and view.widget and view.widget.GetPinRow then
            local row = view.widget:GetPinRow(_highlightPin.pin)
            if row and row.SetHighlight then
                pcall(function() row:SetHighlight(false) end)
            end
        end
        _highlightPin = nil
    end
end

function M:OnClickSave()
    self:SaveCurrentGraphToSceneData()
    self:SetStatus("蓝图已暂存 — 请在关卡编辑器点击「保存场景」写入文件")
end

function M:OnClickLoad()
    self:SetStatus("加载 — Day 5 实现")
end

function M:OnClickClear()
    local g = getG()
    for _, view in pairs(_nodeViews) do
        if view.widget and UE.UKismetSystemLibrary.IsValid(view.widget) then view.widget:RemoveFromParent() end
    end
    _nodeViews = {}
    g.nodes       = {}
    g.connections = {}
    g.nextID      = 1
    _pendingPin   = nil
    _isDirtyWires = false
    if self.w_wire_overlay then
        self.w_wire_overlay:BeginWireUpdate()
        self.w_wire_overlay:EndWireUpdate()
        self.w_wire_overlay:SetPendingWire(UE.FVector2D(0,0), UE.FVector2D(0,0), false)
    end
    self:SetStatus("画布已清空")
    self:ClearErrors()
end

--============================================================
-- 工具
--============================================================

function M:SetStatus(msg)
    if self.w_text_status then self.w_text_status:SetText(msg) end
end

--- 将屏幕像素 delta 转换为画布本地坐标 delta（消除 DPI 缩放影响）
--- 由 WBP_UGCNode:OnMouseMove 调用
function M:ScreenDeltaToCanvas(screenDX, screenDY)
    if not self.w_canvas_main then return screenDX, screenDY end
    local ok, geo = pcall(function() return self.w_canvas_main:GetCachedGeometry() end)
    if not ok or not geo then return screenDX, screenDY end
    -- AbsoluteToLocal(零点) 和 AbsoluteToLocal(零点+delta) 之差即为 canvas 单位 delta
    local ok2, origin = pcall(function()
        return UE.USlateBlueprintLibrary.AbsoluteToLocal(geo, UE.FVector2D(0, 0))
    end)
    local ok3, point = pcall(function()
        return UE.USlateBlueprintLibrary.AbsoluteToLocal(geo, UE.FVector2D(screenDX, screenDY))
    end)
    if ok2 and ok3 and origin and point then
        return point.X - origin.X, point.Y - origin.Y
    end
    return screenDX, screenDY
end

function M:GetActiveID()        return _activeID             end
function M:GetNodes()           return getG().nodes          end
function M:GetConnections()     return getG().connections     end

--============================================================
-- T16：错误列表的观测入口（验收脚本/诊断用）
--============================================================

--- 当前高亮的节点与引脚；没有高亮时返回 nil。
--- 纯 Lua 测试实例化不了 UMG，所以 PIE 冒烟靠这个入口断言「点击定位」真的发生了。
function M:GetFocusTarget()
    if not _highlightNodeID then return nil end
    return {
        nodeID = _highlightNodeID,
        pin    = _highlightPin and _highlightPin.pin or nil,
    }
end

--- 节点视图在画布里的当前坐标（没有该节点视图时返回 nil）
function M:GetNodeCanvasPosition(nodeID)
    local view = _nodeViews[nodeID]
    if not view or not view.widget then return nil end
    local slot = view.canvasSlot
    if not slot then
        slot = UE.UWidgetLayoutLibrary.SlotAsCanvasSlot(view.widget)
        view.canvasSlot = slot
    end
    if not slot then return nil end
    local pos = slot:GetPosition()
    return { x = pos.X, y = pos.Y }
end

--- 错误列表当前渲染的行数（面板折叠时为 0）
function M:GetErrorRowCount()
    local list = widget(self, "w_scroll_errors")
    if not list then return 0 end
    return list:GetChildrenCount()
end

--- 取错误列表里的第 index 行控件（1 起，越界返回 nil）。
--- 验收脚本靠它走与鼠标完全相同的那次点击（row:Activate()）。
function M:GetErrorRowWidget(index)
    local list = widget(self, "w_scroll_errors")
    if not list or not index or index < 1 then return nil end
    if index > list:GetChildrenCount() then return nil end
    return list:GetChildAt(index - 1)
end

return M
