--[[
    WBP_UGCNodePinRow.lua
    单条引脚行（同时支持 exec 引脚连线行 和 参数输入行）

    蓝图 Widget 结构（WBP_UGCNodePinRow）：
    水平框 HorizontalBox
      内边距 Padding = 4,2,4,2
      ├─ 图像 Image           [w_img_pin_in]   宽高=10×10  颜色=#FFFFFF  （输入锚点）
      ├─ 文本块 TextBlock      [w_text_label]   槽位-尺寸=填充Fill
      ├─ 可编辑文本框 EditableTextBox [w_text_input]  槽位-尺寸=填充Fill  默认 Hidden
      │    提示文字="值"  字体大小=11  内边距=2,0,2,0
      └─ 图像 Image           [w_img_pin_out]  宽高=10×10  颜色=#FFFFFF  （输出锚点）

    ★ w_text_input 需在 UE 蓝图编辑器里手动添加（在 w_text_label 和 w_img_pin_out 之间）。
      若 Blueprint 中没有该控件，参数行将回退为纯标签显示（向后兼容）。

    用法：
      InitPin(nodeID, pinName, isInput, editor)   → exec 引脚行
      InitParam(nodeData, paramName)               → 参数输入行
]]

local LOG_TAG = "[WBP_UGCNodePinRow]"
local function Log(msg) print(LOG_TAG .. " " .. tostring(msg)) end

local VISIBLE    = UE.ESlateVisibility.Visible
local HIDDEN     = UE.ESlateVisibility.Hidden
local COLLAPSED  = UE.ESlateVisibility.Collapsed

local M = UnLua.Class()

local function setVisibility(widget, visibility)
    if widget then
        widget:SetVisibility(visibility)
    end
end

local function getLabelContainer(self)
    local parent = nil
    if self and self.w_text_label and self.w_text_label.GetParent then
        parent = self.w_text_label:GetParent()
    end
    if not parent and self and self.w_text_input and self.w_text_input.GetParent then
        parent = self.w_text_input:GetParent()
    end
    return parent
end

local function setLabelContainerVisibility(self, visibility)
    local parent = getLabelContainer(self)
    if parent and parent.SetVisibility then
        parent:SetVisibility(visibility)
    end
end

local function setLabelContainerOffset(self, offsetX)
    local parent = getLabelContainer(self)
    if parent and parent.SetRenderTranslation then
        parent:SetRenderTranslation(UE.FVector2D(offsetX or 0, 0))
    end
end

--============================================================
-- T16：错误列表点击定位到引脚时的高亮
--============================================================

local HIGHLIGHT_LABEL = UE.FLinearColor(1.0, 0.78, 0.15, 1.0)
local NORMAL_ANCHOR   = UE.FLinearColor(1.0, 1.0, 1.0, 1.0)   -- 结构注释里锚点默认色 #FFFFFF

--- 高亮 / 还原本引脚行（标签变琥珀色，两个锚点图片一起变色）
function M:SetHighlight(on)
    self._highlighted = on and true or false

    local label = self.w_text_label
    if label then
        if self._highlighted then
            if not self._savedLabelColor then
                local ok, color = pcall(function() return label:GetColorAndOpacity() end)
                if ok and color then self._savedLabelColor = color end
            end
            label:SetColorAndOpacity(HIGHLIGHT_LABEL)
        else
            label:SetColorAndOpacity(self._savedLabelColor or NORMAL_ANCHOR)
        end
    end

    for _, name in ipairs({ "w_img_pin_in", "w_img_pin_out" }) do
        local img = self[name]
        if img then
            img:SetColorAndOpacity(self._highlighted and HIGHLIGHT_LABEL or NORMAL_ANCHOR)
        end
    end
end

function M:IsHighlighted()
    return self._highlighted == true
end

--============================================================
-- 初始化：exec 引脚行
--============================================================

--- @param nodeID  string   所属节点 ID
--- @param pinName string   引脚名（exec_in / exec_out / exec_out_true / exec_out_false / 参数名）
--- @param isInput boolean  true = 输入引脚，false = 输出引脚，nil = 双向均隐藏锚点
--- @param editor  table    WBP_UGCBlueprintEditor 实例
function M:InitPin(nodeID, pinName, isInput, editor)
    self._nodeID  = nodeID
    self._pinName = pinName
    self._isInput = isInput
    self._editor  = editor

    setVisibility(self.w_img_pin_in,  isInput == true  and VISIBLE or HIDDEN)
    setVisibility(self.w_img_pin_out, isInput == false and VISIBLE or HIDDEN)
    setLabelContainerVisibility(self, VISIBLE)
    setLabelContainerOffset(self, isInput == true and 8 or 0)
    setVisibility(self.w_text_input, COLLAPSED)
    setVisibility(self.w_text_label, VISIBLE)

    if self.w_text_label then
        self.w_text_label:SetJustification(
            isInput == false and UE.ETextJustify.Right or UE.ETextJustify.Left)
    end

    -- Image 没有 OnClicked，实际点击由 WBP_UGCNode 层路由，见 OnPinAnchorClicked
end

--============================================================
-- 初始化：参数输入行
--============================================================

--- 将本行配置为参数输入行：隐藏引脚锚点，显示 EditableTextBox
--- @param nodeData   table  节点数据 {id, type, pos, params}（直接引用，修改即生效）
--- @param paramName  string 参数键名
--- @param paramLabel string 参数显示名
--- @param defaultVal any    默认值
function M:InitParam(nodeData, paramName, paramLabel, defaultVal)
    self._nodeData  = nodeData
    self._paramName = paramName
    self._isInput   = nil  -- 非引脚行，不参与连线

    setVisibility(self.w_img_pin_in,  HIDDEN)
    setVisibility(self.w_img_pin_out, HIDDEN)
    setLabelContainerVisibility(self, VISIBLE)
    setLabelContainerOffset(self, 12)

    if self.w_text_label then
        self.w_text_label:SetText(paramLabel or paramName or "参数")
        self.w_text_label:SetJustification(UE.ETextJustify.Left)
        setVisibility(self.w_text_label, VISIBLE)
    end

    -- 显示输入框并填入当前参数值；你蓝图里 label/input 在同一个 VerticalBox 中，
    -- 这样会形成更接近 UE 节点细节参数行的“名称在上、值在下”。
    if self.w_text_input then
        nodeData.params = nodeData.params or {}
        local val = nodeData.params[paramName]
        if val == nil then
            val = defaultVal
        end
        self.w_text_input:SetText(tostring(val or ""))
        setVisibility(self.w_text_input, VISIBLE)
        if self.w_text_input.SetIsEnabled then
            self.w_text_input:SetIsEnabled(true)
        end
        if self.w_text_input.SetIsReadOnly then
            self.w_text_input:SetIsReadOnly(false)
        end
        if self.w_text_input.OnTextCommitted and not self._inputCommittedBound then
            self.w_text_input.OnTextCommitted:Add(self, M.OnInputCommitted)
            self._inputCommittedBound = true
        end
    end
    -- 若 w_text_input 不存在（Blueprint 未添加该控件），回退为纯标签显示（由调用方兜底）
end

--- EditableTextBox OnTextCommitted 回调：将新值写回 nodeData.params
--- @param text         string      用户输入的新文本
--- @param commitMethod ETextCommit 提交触发方式（Enter / 失去焦点 等）
function M:OnInputCommitted(text, commitMethod)
    if self._nodeData and self._paramName then
        self._nodeData.params[self._paramName] = tostring(text)
        Log("参数写回: " .. tostring(self._paramName) .. " = " .. tostring(text))
    end
end

--============================================================
-- 引脚命中测试（供 WBP_UGCNode 调用，在 PinRow 内部执行避免跨 widget 访问 nil）
--============================================================

--- 判断屏幕绝对坐标 (sx, sy) 是否命中本行任意可见引脚锚点
--- @return boolean
function M:HitTestPinAnchors(sx, sy)
    if self._isInput == nil then return false end  -- 参数行，不参与连线

    local function hit(w)
        if not w then return false end
        local vok, vis = pcall(function() return w:GetVisibility() end)
        if not vok then return false end
        if vis == UE.ESlateVisibility.Hidden
        or vis == UE.ESlateVisibility.Collapsed
        or vis == UE.ESlateVisibility.HitTestInvisible then return false end
        local gok, geo = pcall(function() return w:GetCachedGeometry() end)
        if not gok then return false end
        local size = UE.USlateBlueprintLibrary.GetLocalSize(geo)
        if size.X == 0 and size.Y == 0 then return false end
        local lp = UE.USlateBlueprintLibrary.AbsoluteToLocal(geo, UE.FVector2D(sx, sy))
        return lp.X >= 0 and lp.X <= size.X and lp.Y >= 0 and lp.Y <= size.Y
    end

    return hit(self.w_img_pin_in) or hit(self.w_img_pin_out)
end

--- 由 WBP_UGCNode 在用户点击该行锚点区域时调用
function M:OnPinAnchorClicked()
    if self._editor and self._nodeID and self._pinName then
        -- isOutput = (isInput == false)，即输出引脚传 true，输入引脚传 false
        self._editor:OnPinClicked(self._nodeID, self._pinName, self._isInput == false)
    end
end

--============================================================
-- 坐标查询（供编辑器获取连线端点）
--============================================================

--- 返回输入锚点中心的绝对屏幕坐标，不可用时返回 nil
function M:GetPinInAbsPos()
    return self:_getAnchorAbsPos(self.w_img_pin_in)
end

--- 返回输出锚点中心的绝对屏幕坐标，不可用时返回 nil
function M:GetPinOutAbsPos()
    return self:_getAnchorAbsPos(self.w_img_pin_out)
end

function M:_getAnchorAbsPos(anchorWidget)
    if not anchorWidget then return nil end
    local geo  = anchorWidget:GetCachedGeometry()
    local size = UE.USlateBlueprintLibrary.GetLocalSize(geo)
    if size.X == 0 and size.Y == 0 then return nil end  -- 未完成首帧布局
    return UE.USlateBlueprintLibrary.LocalToAbsolute(
        geo, UE.FVector2D(size.X * 0.5, size.Y * 0.5))
end

--============================================================
-- 标签
--============================================================

function M:SetLabel(text)
    if self.w_text_label then
        self.w_text_label:SetText(text)
    end
end

function M:SetLabelJustification(justification)
    if self.w_text_label then
        self.w_text_label:SetJustification(justification)
    end
end

return M
