-- KOAI history_viewer.lua —— 查询历史回查（v1.34 新增）。
-- 纯本地读取 KOAI_history.json，不调用 AI、不消耗 token；轻量与精读两种模式的
-- 划词问答记录都在这里（每次关闭 KOAI 结果查看器时自动保存，最多 50 条）。
-- 入口：搜索菜单（放大镜）→ KOAI 精读 → 查询历史。
local AICompanionViewer = require("aicompanionviewer")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local Utils = require("utils")
local HistoryManager = require("history_manager")

local HistoryViewer = {}

local function formatTimestamp(ts)
    return os.date("%Y-%m-%d %H:%M", tonumber(ts) or os.time())
end

-- 列表摘要：取第一条用户提问（划词原文）的前 40 字。
local function firstUserText(entry)
    for _, msg in ipairs(entry.messages or {}) do
        if msg.role == "user" and msg.content and msg.content ~= "" then
            local text = Utils.normalize_whitespace(msg.content)
            if Utils.utf8Length(text) > 40 then
                text = Utils.utf8Truncate(text, 40, "…")
            end
            return text
        end
    end
    return "（无提问内容）"
end

-- 完整对话文本：原文与 KOAI 回答逐条排版。
local function entryToText(entry)
    local parts = { "时间｜" .. formatTimestamp(entry.timestamp) }
    for _, msg in ipairs(entry.messages or {}) do
        if msg.role == "user" then
            parts[#parts + 1] = "原文: " .. tostring(msg.content or "")
        elseif msg.role == "assistant" then
            parts[#parts + 1] = "KOAI: " .. tostring(msg.content or "")
        end
    end
    return table.concat(parts, "\n\n")
end

local function showEntry(entry)
    UIManager:show(AICompanionViewer:new {
        title = "KOAI 查询历史",
        text = Utils.normalize_whitespace(entryToText(entry)),
        disable_save_note = true,
    })
end

function HistoryViewer.show()
    local history = HistoryManager:loadHistory()
    if #history == 0 then
        UIManager:show(InfoMessage:new { text = "暂无查询历史记录。", timeout = 4 })
        return
    end

    local item_table = {}
    -- 列表按时间倒序（最新在最上）；首条固定为清空入口。
    item_table[#item_table + 1] = {
        text = "——清空全部历史记录——",
        on_hold = function()
            UIManager:show(ConfirmBox:new {
                text = "确认清空全部 " .. #history .. " 条查询历史？\n此操作不可恢复。",
                ok_text = "清空",
                cancel_text = "取消",
                ok_callback = function()
                    HistoryManager:saveHistory({})
                    UIManager:show(InfoMessage:new { text = "查询历史已清空。", timeout = 3 })
                end,
            })
        end,
        callback = function()
            -- 点击"清空"也弹出确认框，防止误触。
            item_table[1].on_hold()
        end,
    }
    for index = #history, 1, -1 do
        local entry = history[index]
        local item = {
            text = formatTimestamp(entry.timestamp) .. "｜" .. firstUserText(entry),
            callback = function()
                showEntry(entry)
            end,
            on_hold = function()
                UIManager:show(ConfirmBox:new {
                    text = "删除这条查询记录？\n" .. firstUserText(entry),
                    ok_text = "删除",
                    cancel_text = "取消",
                    ok_callback = function()
                        local fresh = HistoryManager:loadHistory()
                        table.remove(fresh, index)
                        HistoryManager:saveHistory(fresh)
                        UIManager:show(InfoMessage:new { text = "已删除该条记录。", timeout = 3 })
                    end,
                })
            end,
        }
        item_table[#item_table + 1] = item
    end

    local menu = Menu:new {
        title = "KOAI 查询历史（" .. #history .. " 条）",
        item_table = item_table,
        is_borderless = true,
        title_multilines = true,
    }
    -- Menu 默认不处理长按，这里接上单条删除。
    function menu:onMenuHold(item)
        if item.on_hold then
            item.on_hold()
        end
        return true
    end
    UIManager:show(menu)
end

return HistoryViewer
