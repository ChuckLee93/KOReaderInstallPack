-- KOAI conversation_handler.lua
-- 基于 AI Reading Assistant（支持追问、保存历史），新增两个可选回调键：
--   callbacks.display_mode == "answer"  → 查看器只显示 AI 回答（KOAI 精读用，避免大段上下文刷屏）
--   callbacks.rich_text == true         → KOAI 富文本分层显示（默认仍为轻量纯文本行为）
-- DeepSeek Key 已写死在 ai_query.lua，此处不再校验。
-- 所有对话（含精读对话）均照常写入历史记录文件。
local AICompanionViewer = require("aicompanionviewer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")
local queryAI = require("ai_query")
local Utils = require("utils")
local HistoryManager = require("history_manager")
local Event = require("ui/event")

local CONFIGURATION
local success, result = pcall(function() return require("configuration") end)
if success then
  CONFIGURATION = result
else
  CONFIGURATION = { max_ai_response_lines = 0 }
end

local ConversationHandler = {}

function ConversationHandler.start(title, initial_messages, highlight_instance, callbacks, ui, UIManagerInstance)
    callbacks = callbacks or {}
    local message_history = initial_messages
    local _UIManager = UIManagerInstance or UIManager

    local function truncate_response(text)
        if CONFIGURATION.max_ai_response_lines and CONFIGURATION.max_ai_response_lines > 0 then
            local lines = {}
            for line in text:gmatch("[^\n]+") do
                table.insert(lines, line)
            end
            if #lines > CONFIGURATION.max_ai_response_lines then
                local truncated_text = table.concat(lines, "\n", 1, CONFIGURATION.max_ai_response_lines)
                return truncated_text .. "\n[...]\n" .. _("（内容已截断，共") .. #lines .. _("行，显示前") .. CONFIGURATION.max_ai_response_lines .. _("行）")
            end
        end
        return text
    end

    local function build_display_text()
        if callbacks.display_mode == "answer" then
            return Utils.createResultText(message_history)
        end
        return Utils.createConversationText(message_history)
    end

    local function handleResponse(answer_raw)
         local normalized_answer = Utils.normalize_whitespace(answer_raw)
         local answer_display = truncate_response(normalized_answer)
         table.insert(message_history, { role = "assistant", content = answer_raw })

         local result_text = build_display_text()

         local viewer
          local function onAsk(v, question)
             table.insert(message_history, { role = "user", content = question })
             local follow_up_waiting = InfoMessage:new{ text = _("KOAI 正在思考，请稍候...") }
             _UIManager:show(follow_up_waiting)

             _UIManager:nextTick(function()
                 local success, res = pcall(function() return queryAI(message_history) end)
                 _UIManager:close(follow_up_waiting)
                 if success and res then
                     local ans = Utils.normalize_whitespace(res)
                     table.insert(message_history, { role = "assistant", content = res })
                     v:update(build_display_text(), truncate_response(ans))
                 else
                     _UIManager:show(InfoMessage:new{ text = _("Error: ") .. tostring(res), timeout = 5 })
                 end
             end)
          end

         viewer = AICompanionViewer:new{
             title = title,
             text = result_text,
             reader_highlight_instance = highlight_instance,
             latest_response = answer_display,
             disable_save_note = callbacks.disable_save_note,
             rich_text = callbacks.rich_text,
             onAskQuestion = onAsk,
            close_callback = function()
                HistoryManager:saveConversation(message_history)
                _UIManager:scheduleIn(0.2, function()
                    if ui and ui.onClearSelection then
                        ui:onClearSelection()
                    end
                    _UIManager:broadcastEvent(Event:new("ClearSelection"))
                    if callbacks.onClose then callbacks.onClose() end
                end)
            end
         }
         UIManager:show(viewer)
    end

    local waiting_dialog = InfoMessage:new{ text = _("正在连接 KOAI，请稍候...") }
    _UIManager:show(waiting_dialog)

    _UIManager:nextTick(function()
        local success, result = pcall(function() return queryAI(initial_messages) end)
        _UIManager:close(waiting_dialog)
        if success and result then
            handleResponse(result)
        else
            _UIManager:show(InfoMessage:new{ text = _("KOAI 出错: ") .. tostring(result), timeout = 5 })
            _UIManager:broadcastEvent(Event:new("ClearSelection"))
        end
    end)
end

return ConversationHandler
