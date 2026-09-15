--[[
    UGCErrorList.lua（T16：Compiler 错误列表）

    职责：把 `UGCGraphCompiler:Compile` 的 report 变成「可渲染的行」。
    这里刻意不碰任何 Widget / UObject：行文本、顺序、上限、可定位性都是纯函数，
    因此能在 Tools/UGCTests 里逐条断言（run_error_list.lua），UI 只负责画。

    行结构：
      { index, text, nodeId, pin, severity, message }
      * severity = "error" | "warning"
      * text     = "#2 错误 [node_3.command] 缺少必填参数: command"
      * nodeId/pin 为 nil 表示该条目不指向具体节点（例如「图为空」「图缺少事件入口」）

    为什么错误在前、警告在后：点击定位是给人用的，先修错误；两组内部保持编译器产出顺序，
    这样回归能逐条比对文本，而不是「顺序随便」。

    上限：UI 行数默认 64（超出计入 overflow），避免一条爆炸式报告把 ScrollBox 撑死；
    超出部分仍然计数，状态栏能看见「还有 N 条」。
]]

local M = {}

M.DEFAULT_LIMIT = 64

--- 单行文本：#序号 级别 [节点.引脚] 消息
local function entryText(entry, index, severity)
    local where = ""
    if entry.nodeId then
        where = "[" .. tostring(entry.nodeId)
        if entry.pin then
            where = where .. "." .. tostring(entry.pin)
        end
        where = where .. "] "
    end
    local tag = (severity == "error") and "错误" or "警告"
    return string.format("#%d %s %s%s", index, tag, where, tostring(entry.message or "未知问题"))
end

--- 组装行列表
--- @param report table|nil  UGCGraphCompiler:Compile 的返回
--- @param limit  number|nil 最多渲染多少行（默认 64）
--- @return table { rows, total, shown, overflow, errors, warnings }
function M.Build(report, limit)
    report = report or {}
    limit  = limit or M.DEFAULT_LIMIT

    local rows, total, index = {}, 0, 0
    local errors, warnings = 0, 0

    local function push(entry, severity)
        total = total + 1
        if severity == "error" then errors = errors + 1 else warnings = warnings + 1 end
        index = index + 1
        if #rows < limit then
            rows[#rows + 1] = {
                index    = index,
                text     = entryText(entry, index, severity),
                nodeId   = entry.nodeId,
                pin      = entry.pin,
                severity = severity,
                message  = entry.message,
            }
        end
    end

    for _, entry in ipairs(report.errors or {}) do push(entry, "error") end
    for _, entry in ipairs(report.warnings or {}) do push(entry, "warning") end

    return {
        rows     = rows,
        total    = total,
        shown    = #rows,
        overflow = total - #rows,
        errors   = errors,
        warnings = warnings,
    }
end

--- 状态栏 / 面板标题用的一行总结（与 GraphCompiler:FormatReport 的口径一致）
function M.Summary(report)
    report = report or {}
    local errorCount   = #(report.errors or {})
    local warningCount = #(report.warnings or {})
    if report.ok then
        if warningCount == 0 then return "验证成功" end
        return string.format("验证通过，%d 个警告", warningCount)
    end
    return string.format("验证失败，%d 个错误", errorCount)
end

--- 该行能否定位（点击定位要求有 nodeId）
function M.IsFocusable(row)
    return row ~= nil and row.nodeId ~= nil and tostring(row.nodeId) ~= ""
end

return M
