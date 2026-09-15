--[[
    WBP_UGCErrorRow.lua（T16：Compiler 错误列表的一行）

    蓝图 Widget 结构（WBP_UGCErrorRow，由 UGC.SetupErrorListUI 生成）：
    边框 Border [w_border_bg]  外观-画刷颜色=按级别覆盖  内边距=10,6,10,6
      └─ 文本块 TextBlock [w_text_label]  字体大小=12  自动换行

    为什么行控件是 Border 而不是 Button：
      行是运行时按错误条数动态创建的（错误数量不定），只需要「点击定位」这一个交互，
      Border + 鼠标事件即可，省掉 Button 的样式与焦点开销；点击判定与节点库按钮一致
      （鼠标抬起时指针仍在行内，拖动/移出后松手不算点击）。

    用法（由 WBP_UGCBlueprintEditor 调用）：
      SetErrorRow(row, onClick)   row = UGCErrorList 产出的行，onClick(row) 在点击时回调
]]

local M = UnLua.Class()

local COLOR_ERROR   = UE.FLinearColor(0.36, 0.10, 0.10, 0.85)
local COLOR_WARNING = UE.FLinearColor(0.36, 0.27, 0.06, 0.85)
local COLOR_HOVER_E = UE.FLinearColor(0.50, 0.15, 0.15, 0.95)
local COLOR_HOVER_W = UE.FLinearColor(0.50, 0.38, 0.08, 0.95)

local function baseColor(severity)
    return (severity == "warning") and COLOR_WARNING or COLOR_ERROR
end

local function hoverColor(severity)
    return (severity == "warning") and COLOR_HOVER_W or COLOR_HOVER_E
end

--============================================================
-- 生命周期
--============================================================

function M:Construct()
    -- 注意：控件是「创建」与「构造」两个时机 —— UWidgetBlueprintLibrary.Create 之后，
    -- 直到 AddChild 进可见树里才会调到这里。所以 Construct 可能在 SetErrorRow **之后**才发生，
    -- 这里绝不能重置 _row / _onClicked，否则刚填好的一行会被清空
    -- （2026-09-15 PIE 实测：列表 6 行渲染正常，但 GetErrorRow() 全是 nil，点击定位拿不到 nodeId）。
    self._isHovered = self._isHovered == true
    self:RefreshColor()
end

--- 由错误列表填充时调用
--- @param row     table     UGCErrorList.Build 产出的行
--- @param onClick function  点击回调（收到该行）
function M:SetErrorRow(row, onClick)
    self._row       = row
    self._severity  = (row and row.severity) or "error"
    self._onClicked = onClick
    self._isHovered = false

    if self.w_text_label then
        self.w_text_label:SetText((row and row.text) or "")
    end
    self:RefreshColor()
end

function M:GetErrorRow()
    return self._row
end

function M:RefreshColor()
    if not self.w_border_bg then return end
    local color = self._isHovered and hoverColor(self._severity) or baseColor(self._severity)
    self.w_border_bg:SetBrushColor(color)
end

--============================================================
-- 鼠标事件：悬停高亮 + 点击回调
--============================================================

function M:OnMouseEnter(geometry, pointerEvent)
    self._isHovered = true
    self:RefreshColor()
end

function M:OnMouseLeave(pointerEvent)
    self._isHovered = false
    self:RefreshColor()
end

--- 指针是否仍然落在本行内（松手时的边界判定）
local function isPointerInside(self, geometry, pointerEvent)
    if not geometry or not pointerEvent then return false end
    local ok, pos = pcall(function()
        return UE.UKismetInputLibrary.PointerEvent_GetScreenSpacePosition(pointerEvent)
    end)
    if not ok or not pos then return false end
    local localPos = UE.USlateBlueprintLibrary.AbsoluteToLocal(geometry, pos)
    -- FGeometry 的方法在 Lua 里不可直接调用，尺寸同样走 USlateBlueprintLibrary
    local size = UE.USlateBlueprintLibrary.GetLocalSize(geometry)
    return localPos.X >= 0 and localPos.Y >= 0
        and localPos.X <= size.X and localPos.Y <= size.Y
end

function M:OnMouseButtonUp(geometry, pointerEvent)
    if not isPointerInside(self, geometry, pointerEvent) then
        return UE.UWidgetBlueprintLibrary.Unhandled()
    end
    self:Activate()
    return UE.UWidgetBlueprintLibrary.Handled()
end

--- 触发本行的点击动作。鼠标路径（OnMouseButtonUp）与脚本化验收都走这一个入口，
--- 这样 PIE 冒烟里"点一行"验证的就是真实点击会执行的同一段代码。
function M:Activate()
    if self._onClicked and self._row then
        self._onClicked(self._row)
        return true
    end
    return false
end

return M
