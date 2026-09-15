--[[
    WBP_UGCNode.lua
    单个蓝图节点的 Widget 逻辑

    蓝图 Widget 结构（WBP_UGCNode）：
    尺寸框 SizeBox
      最小期望宽度 MinDesiredWidth = 220
      └─ 边框 Border [w_border_bg]
           外观-画刷颜色 Brush Color = #2A2A2A
           内边距 Padding = 0
           └─ 垂直框 VerticalBox
                ├─ 覆层 Overlay
                │    ├─ 边框 Border [w_border_title]  外观-画刷颜色=运行时覆盖  可见性=命中测试不可见
                │    │    内边距 Padding = 8,4,8,4
                │    │    └─ 文本块 TextBlock [w_text_title]  字体大小=12  颜色=#FFFFFF
                │    └─ 按钮 Button [w_btn_title]  槽位-对齐=Fill(1,1)  外观全透明
                │         （无子节点）
                └─ 垂直框 VerticalBox [w_vbox_content]
                     内边距 Padding = 4,4,4,4
                     （引脚行动态填充）

    点击路由（OnPreviewMouseButtonDown，比子控件优先）：
      ① 点中引脚锚点 Image → OnPinAnchorClicked → 编辑器连线逻辑
      ② 点中标题按钮区域  → CaptureMouse → OnMouseMove 拖拽节点
      ③ 其他（参数输入框）→ Unhandled，透传给子控件
]]

local NodeRegistry = require("System.UI.UGC.UGCNodeRegistry")

local M = UnLua.Class()

--- T16：错误列表点击定位时的高亮色 / 还原用的默认背景色（结构注释里写的 #2A2A2A）
local HIGHLIGHT_BG = UE.FLinearColor(0.95, 0.72, 0.10, 1.0)
local DEFAULT_BG   = UE.FLinearColor(0.165, 0.165, 0.165, 1.0)

local PIN_ROW_PATH = "/Game/_UGC/UI/WBP_UGCNodePinRow.WBP_UGCNodePinRow_C"
local _pinRowClass = nil
local function getPinRowClass()
    if not _pinRowClass then
        _pinRowClass = UE.UClass.Load(PIN_ROW_PATH)
    end
    return _pinRowClass
end

--============================================================
-- 生命周期
--============================================================

function M:Construct()
    -- 点击路由全部由 OnPreviewMouseButtonDown 处理，此处无需绑定任何委托
end

--============================================================
-- 初始化（由编辑器调用）
--============================================================

--- @param nodeData table  {id, type, pos, params}
--- @param editor   table  WBP_UGCBlueprintEditor Lua 实例
function M:InitNode(nodeData, editor)
    self._data    = nodeData
    self._editor  = editor
    self._pinRows = {}   -- {[pinName] = pinRowWidget}

    local def = NodeRegistry.Definitions[nodeData.type]
    if not def then return end

    if self.w_text_title then
        self.w_text_title:SetText(def.label)
    end

    if self.w_border_title then
        local c = def.color
        self.w_border_title:SetBrushColor(UE.FLinearColor(c.r, c.g, c.b, 1.0))
    end

    self:BuildContent(def, nodeData.params)
    self:CaptureBackgroundColor()
end

--- T16：记录背景色，高亮结束后还原（取不到就用结构注释里的默认色）
function M:CaptureBackgroundColor()
    if not self.w_border_bg then return end
    local ok, color = pcall(function() return self.w_border_bg:GetBrushColor() end)
    if ok and color then
        self._bgColor = color
    end
end

--- T16：错误列表点击定位到本节点时的高亮开关
function M:SetHighlight(on)
    self._highlighted = on and true or false
    if not self.w_border_bg then return end
    self.w_border_bg:SetBrushColor(self._highlighted and HIGHLIGHT_BG or (self._bgColor or DEFAULT_BG))
end

function M:IsHighlighted()
    return self._highlighted == true
end

function M:BuildContent(def, params)
    if not self.w_vbox_content then return end
    self.w_vbox_content:ClearChildren()
    self._pinRows = {}

    local pc  = self:GetOwningPlayer()
    local cls = getPinRowClass()
    if not pc or not cls then return end

    local function addPinRow(pinName, label, isInput, rightAlign)
        local row = UE.UWidgetBlueprintLibrary.Create(pc, cls, pc)
        if not row then return end
        row:SetLabel(label)
        if rightAlign then
            row:SetLabelJustification(UE.ETextJustify.Right)
        end
        row:InitPin(self._data.id, pinName, isInput, self._editor)
        self.w_vbox_content:AddChild(row)
        self._pinRows[pinName] = row
    end

    local function addParamRow(p)
        local row = UE.UWidgetBlueprintLibrary.Create(pc, cls, pc)
        if not row then return end
        if row.InitParam then
            row:InitParam(self._data, p.name, p.label, p.default)
        else
            local val = (params and params[p.name]) or p.default
            row:SetLabel(p.label .. ": " .. tostring(val))
            row:InitPin(self._data.id, p.name, nil, self._editor)
        end
        self.w_vbox_content:AddChild(row)
        self._pinRows[p.name] = row
    end

    if def.exec_in        then addPinRow("exec_in",        "▶ 执行",  true,  false) end
    if def.exec_out       then addPinRow("exec_out",       "执行 ▶",  false, true)  end
    if def.exec_out_true  then addPinRow("exec_out_true",  "True ▶",  false, true)  end
    if def.exec_out_false then addPinRow("exec_out_false", "False ▶", false, true)  end

    for _, p in ipairs(def.params or {}) do
        addParamRow(p)
    end
end

--============================================================
-- 对外接口
--============================================================

function M:GetPinRow(pinName)
    return self._pinRows and self._pinRows[pinName]
end

function M:GetNodeID()  return self._data and self._data.id     end
function M:GetParams()  return self._data and self._data.params end

--============================================================
-- 命中测试辅助
--   判断屏幕坐标 (sx, sy) 是否落在某个控件的包围盒内
--   Hidden / Collapsed / HitTestInvisible 控件直接跳过
--============================================================

local function hitTest(w, sx, sy)
    if not w then return false end
    -- 跳过不可见 / 不接受命中的控件
    local vok, vis = pcall(function() return w:GetVisibility() end)
    if not vok then return false end
    if vis == UE.ESlateVisibility.Hidden
    or vis == UE.ESlateVisibility.Collapsed
    or vis == UE.ESlateVisibility.HitTestInvisible then
        return false
    end
    -- 几何包围盒检测
    local gok, geo = pcall(function() return w:GetCachedGeometry() end)
    if not gok then return false end
    local size = UE.USlateBlueprintLibrary.GetLocalSize(geo)
    if size.X == 0 and size.Y == 0 then return false end
    local lp = UE.USlateBlueprintLibrary.AbsoluteToLocal(geo, UE.FVector2D(sx, sy))
    return lp.X >= 0 and lp.X <= size.X and lp.Y >= 0 and lp.Y <= size.Y
end

--============================================================
-- 点击路由（OnPreviewMouseButtonDown：比子控件优先触发）
--============================================================

function M:OnPreviewMouseButtonDown(geometry, pointerEvent)
    if not self._editor or not self._data then
        return UE.UWidgetBlueprintLibrary.Unhandled()
    end

    local ok, pos = pcall(function()
        return UE.UKismetInputLibrary.PointerEvent_GetScreenSpacePosition(pointerEvent)
    end)
    if not ok or not pos then
        return UE.UWidgetBlueprintLibrary.Unhandled()
    end
    local sx, sy = pos.X, pos.Y

    -- ① 引脚锚点点击 → 触发连线
    --    命中测试在 PinRow 内部执行（self.w_img_pin_in 跨 widget 访问可能为 nil）
    if self._pinRows then
        for _, row in pairs(self._pinRows) do
            if row and row.HitTestPinAnchors and row:HitTestPinAnchors(sx, sy) then
                row:OnPinAnchorClicked()
                return UE.UWidgetBlueprintLibrary.Handled()
            end
        end
    end

    -- ② 标题区域点击 → 拖拽节点
    if hitTest(self.w_btn_title, sx, sy) then
        self._isDraggingLocal  = true
        self._dragStartScreen  = { x = sx, y = sy }
        self._dragStartNodePos = { x = self._data.pos.x, y = self._data.pos.y }
        local reply = UE.UWidgetBlueprintLibrary.Handled()
        reply = UE.UWidgetBlueprintLibrary.CaptureMouse(reply, self)
        return reply
    end

    -- ③ 其他区域（参数输入框等）→ 不消费，透传给子控件
    return UE.UWidgetBlueprintLibrary.Unhandled()
end

--============================================================
-- 拖拽：OnMouseMove / OnMouseButtonUp
--============================================================

function M:OnMouseMove(geometry, pointerEvent)
    if not self._isDraggingLocal or not self._editor or not self._data then
        return UE.UWidgetBlueprintLibrary.Unhandled()
    end
    local ok, pos = pcall(function()
        return UE.UKismetInputLibrary.PointerEvent_GetScreenSpacePosition(pointerEvent)
    end)
    if not ok or not pos then return UE.UWidgetBlueprintLibrary.Handled() end

    -- 同步 Slate 绝对坐标到编辑器缓存，用于 UpdateWires 的非全屏偏移修正
    self._editor._slateMX = pos.X
    self._editor._slateMY = pos.Y

    local screenDX = pos.X - self._dragStartScreen.x
    local screenDY = pos.Y - self._dragStartScreen.y
    local cdx, cdy = self._editor:ScreenDeltaToCanvas(screenDX, screenDY)
    self._editor:MoveNodeTo(
        self._data.id,
        self._dragStartNodePos.x + cdx,
        self._dragStartNodePos.y + cdy
    )
    return UE.UWidgetBlueprintLibrary.Handled()
end

function M:OnMouseButtonUp(geometry, pointerEvent)
    if self._isDraggingLocal then
        self._isDraggingLocal = false
        local reply = UE.UWidgetBlueprintLibrary.Handled()
        reply = UE.UWidgetBlueprintLibrary.ReleaseMouseCapture(reply)
        return reply
    end
    return UE.UWidgetBlueprintLibrary.Unhandled()
end

return M
