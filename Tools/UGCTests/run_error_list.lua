--[[
    run_error_list.lua

    T16：Compiler 错误列表的回归测试。

    覆盖点：
      1. UGCErrorList.Build 的行模型：错误在前、警告在后，序号/文本/节点引脚都带出来
      2. 行数上限：超出部分计入 overflow，total 仍然完整（状态栏要显示「共 N 条」）
      3. 不指向具体节点的条目（「图缺少事件入口」这类）文本不带方括号，且不可定位
      4. Summary 三种口径：验证成功 / 验证通过 N 个警告 / 验证失败 N 个错误
      5. 空输入与 nil 输入不炸（编译器永远给 report，但 UI 可能在清空后再画一次）
      6. 接线与资产守卫（源码/资产级）：错误面板与行控件的名字必须同时出现在
         Lua 接线、UMG 资产字节、编辑器命令里 —— 三者缺一，UI 就会静默退回「只显示第一条」

    说明：第 6 组是静态断言。错误面板是编辑器里生成的资产（UGC.SetupErrorListUI），
    纯 Lua 环境实例化不了 UMG，所以「面板存在且被接线」只能这样锁。
]]

local root = assert(arg[1], "workspace root required")
package.path = root .. "/Content/Script/?.lua;" .. root .. "/Content/Script/?/init.lua;" .. package.path

local ErrorList = require("Gameplay.UGC.UGCErrorList")

local total, passed = 0, 0
local function check(value, message) if not value then error(message or "check failed", 2) end end
local function equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s got %s", message or "not equal", tostring(expected), tostring(actual)), 2)
    end
end
local function test(name, fn)
    total = total + 1
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
    end
end
local function readSource(relative)
    local handle = io.open(root .. "/" .. relative, "rb")
    if not handle then return nil end
    local content = handle:read("*a")
    handle:close()
    return content
end
local function mustContain(source, needle, where)
    check(source, "读不到文件: " .. tostring(where))
    if not string.find(source, needle, 1, true) then
        error(string.format("%s 缺少 %q", where, needle), 2)
    end
end

--============================================================
-- 1. 行模型
--============================================================

test("rows put errors first and keep node/pin", function()
    local report = {
        ok = false,
        errors = {
            { message = "缺少必填参数: command", nodeId = "node_1" },
            { message = "无效输入引脚: exec_in", nodeId = "node_2", pin = "exec_in" },
        },
        warnings = {
            { message = "节点无法从任何事件入口到达", nodeId = "node_3" },
        },
    }
    local model = ErrorList.Build(report)
    equal(model.total, 3)
    equal(model.errors, 2)
    equal(model.warnings, 1)
    equal(#model.rows, 3)
    equal(model.overflow, 0)

    equal(model.rows[1].index, 1)
    equal(model.rows[1].severity, "error")
    equal(model.rows[1].nodeId, "node_1")
    equal(model.rows[1].pin, nil)
    check(string.find(model.rows[1].text, "#1 错误 [node_1] 缺少必填参数: command", 1, true),
        "错误行文本: " .. tostring(model.rows[1].text))

    equal(model.rows[2].severity, "error")
    equal(model.rows[2].pin, "exec_in")
    check(string.find(model.rows[2].text, "[node_2.exec_in]", 1, true),
        "带引脚的错误行文本: " .. tostring(model.rows[2].text))

    equal(model.rows[3].severity, "warning")
    equal(model.rows[3].index, 3)
    check(string.find(model.rows[3].text, "#3 警告 [node_3]", 1, true),
        "警告行文本: " .. tostring(model.rows[3].text))
end)

test("row limit keeps totals honest", function()
    local errors = {}
    for index = 1, 5 do
        errors[index] = { message = "错误 " .. index, nodeId = "node_" .. index }
    end
    local model = ErrorList.Build({ ok = false, errors = errors, warnings = {} }, 3)
    equal(model.total, 5, "total 要按真实条数算")
    equal(model.shown, 3)
    equal(#model.rows, 3)
    equal(model.overflow, 2)
    equal(model.rows[3].index, 3)
end)

--============================================================
-- 2. 无节点条目 / 可定位性
--============================================================

test("entries without a node are listed but not focusable", function()
    local model = ErrorList.Build({
        ok = false,
        errors = { { message = "图缺少事件入口" } },
        warnings = {},
    })
    equal(#model.rows, 1)
    equal(model.rows[1].nodeId, nil)
    check(not string.find(model.rows[1].text, "[", 1, true), "无节点条目不该有方括号: " .. model.rows[1].text)
    check(not ErrorList.IsFocusable(model.rows[1]), "无 nodeId 的行不可定位")

    check(ErrorList.IsFocusable({ nodeId = "node_1" }))
    check(not ErrorList.IsFocusable({ nodeId = "" }))
    check(not ErrorList.IsFocusable(nil))
end)

--============================================================
-- 3. Summary 口径
--============================================================

test("summary matches the compiler wording", function()
    equal(ErrorList.Summary({ ok = true, errors = {}, warnings = {} }), "验证成功")
    equal(ErrorList.Summary({ ok = true, errors = {}, warnings = { { message = "w" }, { message = "w2" } } }),
        "验证通过，2 个警告")
    equal(ErrorList.Summary({ ok = false, errors = { { message = "e" }, { message = "e2" } }, warnings = {} }),
        "验证失败，2 个错误")
end)

test("empty and nil reports are safe", function()
    local model = ErrorList.Build(nil)
    equal(model.total, 0)
    equal(#model.rows, 0)
    equal(model.overflow, 0)
    equal(ErrorList.Summary(nil), "验证失败，0 个错误")
end)

--============================================================
-- 4. 接线与资产守卫（静态）
--============================================================

test("editor widget wires the error list", function()
    local source = readSource("Content/Script/System/UI/UGC/WBP_UGCBlueprintEditor.lua")
    mustContain(source, "w_scroll_errors", "WBP_UGCBlueprintEditor.lua")
    mustContain(source, "w_error_panel", "WBP_UGCBlueprintEditor.lua")
    mustContain(source, "WBP_UGCErrorRow.WBP_UGCErrorRow_C", "WBP_UGCBlueprintEditor.lua")
    mustContain(source, "function M:ShowErrors(report)", "WBP_UGCBlueprintEditor.lua")
    mustContain(source, "function M:FocusError(row)", "WBP_UGCBlueprintEditor.lua")
    mustContain(source, "function M:RelayoutNodes()", "WBP_UGCBlueprintEditor.lua")
    mustContain(source, "function M:HighlightNode(nodeID, pinName)", "WBP_UGCBlueprintEditor.lua")
end)

test("row widget and node highlight hooks exist", function()
    local row = readSource("Content/Script/System/UI/UGC/WBP_UGCErrorRow.lua")
    mustContain(row, "function M:SetErrorRow(row, onClick)", "WBP_UGCErrorRow.lua")
    mustContain(row, "function M:OnMouseButtonUp(geometry, pointerEvent)", "WBP_UGCErrorRow.lua")
    mustContain(row, "w_text_label", "WBP_UGCErrorRow.lua")

    local node = readSource("Content/Script/System/UI/UGC/WBP_UGCNode.lua")
    mustContain(node, "function M:SetHighlight(on)", "WBP_UGCNode.lua")

    local pinRow = readSource("Content/Script/System/UI/UGC/WBP_UGCNodePinRow.lua")
    mustContain(pinRow, "function M:SetHighlight(on)", "WBP_UGCNodePinRow.lua")
end)

test("editor command and UMG assets carry the panel", function()
    local command = readSource("Source/FPS/UGC/UGCWidgetSetupCommands.cpp")
    mustContain(command, "UGC.SetupErrorListUI", "UGCWidgetSetupCommands.cpp")
    mustContain(command, "w_scroll_errors", "UGCWidgetSetupCommands.cpp")
    mustContain(command, "w_error_panel", "UGCWidgetSetupCommands.cpp")

    local rowAsset = io.open(root .. "/Content/_UGC/UI/WBP_UGCErrorRow.uasset", "rb")
    check(rowAsset, "缺少 WBP_UGCErrorRow.uasset（在编辑器里跑 UGC.SetupErrorListUI 生成）")
    rowAsset:close()

    local asset = io.open(root .. "/Content/_UGC/UI/WBP_UGCBlueprintEditor.uasset", "rb")
    check(asset, "缺少 WBP_UGCBlueprintEditor.uasset")
    local bytes = asset:read("*a")
    asset:close()
    for _, name in ipairs({ "w_error_panel", "w_error_border_bg", "w_scroll_errors" }) do
        check(string.find(bytes, name, 1, true),
            "WBP_UGCBlueprintEditor.uasset 里没有控件 " .. name .. "（跑 UGC.SetupErrorListUI 补齐）")
    end
end)

if passed ~= total then error(string.format("%d/%d tests passed", passed, total)) end
print(string.format("ALL PASS %d/%d", passed, total))
