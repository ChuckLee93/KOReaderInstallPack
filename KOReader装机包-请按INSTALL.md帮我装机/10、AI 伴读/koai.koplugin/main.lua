-- KOAI main.lua（合并版 v1.34）
-- = 轻量划词/词典（默认）+ KOAI 精读（按需开启）=
-- v1.34：①设置/历史文件改名为 KOAI_settings.json / KOAI_history.json（自动回读旧文件）；
-- ②新增"查询历史"回查入口（KOAI 精读菜单第一项，纯本地读取，不耗 token）。
-- power_mode 关（默认）：只有原 10 号插件的轻量功能，KOAI 大模块不加载、不采集、不耗 token；
-- power_mode 开：激活 KOAI 全部能力（划词附已读上下文、人物卡、复盘、久读回顾、本地档案）。
-- 两个原插件的相似功能已合并：划词菜单沿用 10 号的 5 槽 Prompt 体系；API 层为 DeepSeek 专用（Key 写死）。
-- 菜单清洁功能已删除（该需求已由 KOReader 本体实现）。
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

local Utils = require("utils")

local AIReadingAssistant = InputContainer:new {
  name = "aireadingassistant",
  is_doc_only = true,
}

-- ============ 工具函数 ============

local function getConfiguration()
  local ok, config = pcall(function() return require("configuration") end)
  if ok and type(config) == "table" then return config end
  return nil
end

local function isPowerMode()
  local config = getConfiguration()
  return config ~= nil and config.power_mode == true
end

local optional_modules = {}

local function optionalRequire(module_name)
  local cached = optional_modules[module_name]
  if cached then
    return cached.module, cached.error
  end
  local ok, result = pcall(require, module_name)
  if ok then
    optional_modules[module_name] = { module = result }
    return result, nil
  end
  optional_modules[module_name] = { error = tostring(result) }
  return nil, tostring(result)
end

local function showError(title, err)
  UIManager:show(InfoMessage:new {
    text = title .. "\n\n" .. tostring(err or "未知错误")
        .. "\n\n其他本地功能通常仍可继续使用。",
    timeout = 12,
  })
end

function AIReadingAssistant:callCompanion(method_name, ...)
  local Logic, load_err = optionalRequire("companion_logic")
  if not Logic then
    showError("精读模块未能加载", load_err)
    return nil
  end
  local method = Logic[method_name]
  if type(method) ~= "function" then
    showError("精读功能不存在", method_name)
    return nil
  end
  local args = { ... }
  local ok, result = pcall(function()
    return method(unpack(args))
  end)
  if not ok then
    showError("精读功能运行失败", result)
    return nil
  end
  return result
end

function AIReadingAssistant:getStorage()
  return optionalRequire("companion_storage")
end

-- ============ 初始化 ============

function AIReadingAssistant:onDispatcherRegisterActions()
  if self._dispatcher_registered then return end
  local Dispatcher = optionalRequire("dispatcher")
  if not Dispatcher or type(Dispatcher.registerAction) ~= "function" then return end

  local actions = {
    { id = "ai_reading_companion", event = "AIReadingCompanion", title = "KOAI 精读中心" },
    { id = "ai_continue_reading", event = "AIContinueReading", title = "KOAI 继续阅读回顾" },
    { id = "ai_chapter_recap", event = "AIChapterRecap", title = "KOAI 当前进度复盘" },
  }
  for _, action in ipairs(actions) do
    pcall(function()
      Dispatcher:registerAction(action.id, {
        category = "none",
        event = action.event,
        title = action.title,
        section = "reader",
        general = true,
      })
    end)
  end
  self._dispatcher_registered = true
end

function AIReadingAssistant:init()
  self:onDispatcherRegisterActions()

  if self.ui and self.ui.menu then
    self.ui.menu:registerToMainMenu(self)
  end

  if not (self.ui and self.ui.highlight and self.ui.highlight.addToHighlightDialog) then
    return
  end

  -- ===== 划词入口：沿用原 10 号的 5 个 Prompt 槽（两种模式共用同一套 Prompt） =====
  for i = 1, 5 do
    local key = "koai_prompt_" .. i
    self.ui.highlight:addToHighlightDialog(key, function(_reader_highlight_instance)
      local enabled_key = "enabled" .. i
      local text_key = "menu_text" .. i
      local prompt_key = "prompt" .. i
      local CONFIGURATION = getConfiguration()

      return {
        text = CONFIGURATION and CONFIGURATION[text_key] or ("KOAI Prompt " .. i),
        enabled = true,
        show_in_highlight_dialog_func = function()
          if CONFIGURATION and CONFIGURATION[enabled_key] == false then
            return false
          end
          return true
        end,
        callback = function()
          local text = _reader_highlight_instance.selected_text.text
          -- 使用 nextTick 确保 UI 响应
          UIManager:nextTick(function()
            self:handlePrompt(CONFIGURATION and CONFIGURATION[prompt_key], _reader_highlight_instance, text)
          end)
        end,
      }
    end)
  end

  -- ===== KOAI 划词入口：人物／典故卡（仅在精读模式开启时显示） =====
  self.ui.highlight:addToHighlightDialog("koaireader_card", function(reader_highlight)
    return {
      text = "人物／典故",
      enabled = true,
      show_in_highlight_dialog_func = function()
        return isPowerMode()
      end,
      callback = function()
        local selected_text = ""
        if reader_highlight.selected_text and reader_highlight.selected_text.text then
          selected_text = reader_highlight.selected_text.text
        end
        local context = self:getSelectionContext(reader_highlight, selected_text)
        UIManager:nextTick(function()
          self:callCompanion("createCard", self.ui, selected_text, context)
        end)
      end,
    }
  end)
end

-- ============ 划词处理（轻量模式 = 10 号原逻辑） ============

function AIReadingAssistant:handlePrompt(system_prompt_override, _reader_highlight_instance, captured_text)
  -- 精读模式开启时走 KOAI 逻辑（附已读上下文），否则走轻量逻辑。
  if isPowerMode() then
    return self:koaiHandlePrompt(system_prompt_override, _reader_highlight_instance, captured_text)
  end

  local highlightedText = captured_text or (_reader_highlight_instance.selected_text and _reader_highlight_instance.selected_text.text) or ""
  local CONFIGURATION = getConfiguration()

  if CONFIGURATION and CONFIGURATION.auto_expand_to_sentence then
    local success_ctx, prev, next_ctx = pcall(function()
      return _reader_highlight_instance:getSelectedWordContext(50)
    end)
    if success_ctx then
      highlightedText = Utils.expand_to_sentence(highlightedText, prev, next_ctx)
    end
  end

  NetworkMgr:runWhenOnline(function()
    -- 懒加载：首次实际发起对话时才载入对话模块（含查看器/历史/请求层），轻量待机不占内存。
    local ConversationHandler = require("conversation_handler")
    local system_prompt = (system_prompt_override or "") .. "\n\n请返回纯文本，不要包含markdown格式符号"

    local message_history = {
      { role = "system", content = system_prompt },
      { role = "user", content = highlightedText }
    }

    ConversationHandler.start(_("KOAI"), message_history, _reader_highlight_instance, {
      onClose = function()
        if _reader_highlight_instance and _reader_highlight_instance.onClose then
          pcall(function()
            _reader_highlight_instance:onClose()
          end)
        end
      end
    }, self.ui, UIManager)
  end)
end

-- ============ 划词处理（精读模式 = 11 号 KOAI 逻辑） ============

function AIReadingAssistant:getSelectionContext(reader_highlight, selected_text)
  local CONFIGURATION = getConfiguration() or {}
  selected_text = Utils.normalize_whitespace(selected_text or "")
  if not CONFIGURATION.auto_expand_to_sentence
      or not reader_highlight
      or not reader_highlight.getSelectedWordContext then
    return ""
  end
  local ok, previous_context, next_context = pcall(function()
    return reader_highlight:getSelectedWordContext(50)
  end)
  if not ok then return "" end
  return Utils.expand_to_sentence(
    selected_text,
    previous_context or "",
    next_context or ""
  )
end

function AIReadingAssistant:koaiHandlePrompt(system_prompt, reader_highlight, selected_text)
  selected_text = Utils.normalize_whitespace(selected_text or "")
  if selected_text == "" then return end

  local context_sentence = self:getSelectionContext(reader_highlight, selected_text)
  local user_content = "选中内容：\n" .. selected_text
  if context_sentence ~= "" and context_sentence ~= selected_text then
    user_content = user_content
        .. "\n\n所在语境（只用于判断选中内容，不要把回答对象改成整句）：\n"
        .. context_sentence
  end

  -- 精读不再只看当前划词：已确认的前文与累计复盘作为“已读依据”一并提供。
  local Storage = self:getStorage()
  if Storage and self.ui and self.ui.document then
    local ok_ctx, reading_context = pcall(function()
      local book = Storage.getBookInfo(self.ui)
      return Storage.getPrecisionContext(book)
    end)
    if ok_ctx and reading_context and reading_context ~= "" then
      user_content = user_content
          .. "\n\nKOAI 已读上下文（只用于理解当前选区；不得把未读后文带入回答）：\n"
          .. reading_context
    end
  end

  NetworkMgr:runWhenOnline(function()
    local ConversationHandler = require("conversation_handler")
    -- 精读模式统一附上防剧透规则（原 KOAI 两槽 Prompt 的核心保护，防止模型用“熟悉整本书”剧透）。
    local system_prompt_with_guard = (system_prompt or "")
        .. "\n\n【KOAI 精读规则】回答只能基于请求中提供的已读内容；小说/剧情类文本严禁提前透露尚未读到的情节、伏笔或结局。"
    local message_history = {
      { role = "system", content = system_prompt_with_guard },
      { role = "user", content = user_content },
    }
    ConversationHandler.start(_("KOAI 精读"), message_history, reader_highlight, {
      display_mode = "answer",  -- 查看器只显示回答，不把大段已读上下文刷进屏幕
      rich_text = true,         -- KOAI 富文本分层显示
      onClose = function()
        if reader_highlight and reader_highlight.onClose then
          pcall(function() reader_highlight:onClose() end)
        end
      end,
    }, self.ui, UIManager)
  end)
end

-- ============ AI 词典（10 号功能，两种模式均可用） ============

function AIReadingAssistant:onDictButtonsReady(dict_popup, buttons)
  table.insert(buttons, 1, {{
    id = "ai_reading_assistant_dictionary",
    text = _("KOAI 词典"),
    callback = function()
      local word = dict_popup.word
      local highlight = dict_popup.highlight

      if dict_popup.onClose then
        dict_popup:onClose()
      else
        UIManager:close(dict_popup)
      end

      if self.ui and self.ui.onClearSelection then
        self.ui:onClearSelection()
      end

      NetworkMgr:runWhenOnline(function()
        local showAIDictionary = require("ai_dictionary")
        showAIDictionary(self.ui, word, highlight)
      end)
    end,
  }})
end

-- ============ KOAI 自动采集与回顾（仅精读模式开启时工作） ============

function AIReadingAssistant:captureCurrentView()
  local CONFIGURATION = getConfiguration() or {}
  if CONFIGURATION.auto_capture_enabled == false
      or not self.ui
      or not self.ui.document then
    return
  end

  local Storage = self:getStorage()
  if not Storage then return end

  pcall(function()
    local book = Storage.getBookInfo(self.ui)
    local position = Storage.getPosition(self.ui)
    local text = Storage.readVisibleText(self.ui)
    if text == "" then return end

    local digest = Storage.hashText(position.chapter_key .. "|" .. text)
    if self._last_capture_digest ~= digest then
      self._last_capture_digest = digest
      Storage.appendVisibleText(book, position, text)
    end
    -- 当前停留位置与最远已读位置分开保存；回看旧页不会让最远进度倒退。
    Storage.updateReadingPositions(book, position)
  end)
end

function AIReadingAssistant:saveLeaveTime()
  if not self.ui or not self.ui.document then return end
  self:captureCurrentView()
  local Storage = self:getStorage()
  if not Storage then return end

  pcall(function()
    local book = Storage.getBookInfo(self.ui)
    local position = Storage.getPosition(self.ui)
    local state = Storage.updateReadingPositions(book, position)
    state.last_left_at = os.time()
    state.last_active_at = state.last_left_at
    Storage.saveState(book, state)
  end)
end

function AIReadingAssistant:maybePromptResume()
  local CONFIGURATION = getConfiguration() or {}
  if CONFIGURATION.resume_prompt_enabled == false
      or not self.ui
      or not self.ui.document then
    return
  end

  local Storage = self:getStorage()
  if not Storage then return end

  local should_prompt = false
  local session_key
  pcall(function()
    local book = Storage.getBookInfo(self.ui)
    local state = Storage.loadState(book)
    local left_at = tonumber(state.last_left_at) or 0
    if left_at <= 0 then return end
    local threshold = (tonumber(CONFIGURATION.resume_after_hours) or 10) * 3600
    if os.time() - left_at < threshold then return end
    session_key = book.id .. "|" .. tostring(left_at)
    -- ReaderReady 与 Resume 可能连续触发；运行期锁与持久化标记双重防重。
    if self._resume_prompt_pending or self._resume_prompt_session_key == session_key then return end
    if tostring(state.last_prompted_for_left_at or "") == tostring(left_at) then return end
    self._resume_prompt_pending = true
    self._resume_prompt_session_key = session_key
    state.last_prompted_for_left_at = left_at
    Storage.saveState(book, state)
    should_prompt = true
  end)

  if should_prompt then
    UIManager:scheduleIn(0.6, function()
      self._resume_prompt_pending = false
      if self.ui and self.ui.document then
        self:callCompanion("showResumePrompt", self.ui)
      end
    end)
  end
end

function AIReadingAssistant:onReaderReady()
  if not isPowerMode() then return end
  self._last_capture_digest = nil
  -- 若第一次在书籍中途启用精读，先问“前文是否已读”。
  local prior_prompted = self:callCompanion("maybePromptPriorReading", self.ui)
  if not prior_prompted then self:maybePromptResume() end
  UIManager:scheduleIn(1.0, function()
    if self.ui and self.ui.document then self:captureCurrentView() end
  end)
end

function AIReadingAssistant:onPageUpdate()
  if not isPowerMode() then return end
  UIManager:scheduleIn(0.35, function()
    if self.ui and self.ui.document then self:captureCurrentView() end
  end)
end

function AIReadingAssistant:onSuspend()
  if not isPowerMode() then return end
  self:saveLeaveTime()
end

function AIReadingAssistant:onResume()
  if not isPowerMode() then return end
  self:maybePromptResume()
  UIManager:scheduleIn(0.8, function()
    if self.ui and self.ui.document then self:captureCurrentView() end
  end)
end

function AIReadingAssistant:onCloseDocument()
  if not isPowerMode() then return end
  self:saveLeaveTime()
end

-- ============ Dispatcher 手势/快捷动作 ============

function AIReadingAssistant:onAIReadingCompanion()
  if not isPowerMode() then
    UIManager:show(InfoMessage:new { text = _("精读模式未开启：可在工具菜单的 KOAI 设置中打开。"), timeout = 4 })
    return true
  end
  self:callCompanion("showHub", self.ui)
  return true
end

function AIReadingAssistant:onAIContinueReading()
  if not isPowerMode() then
    UIManager:show(InfoMessage:new { text = _("精读模式未开启：可在工具菜单的 KOAI 设置中打开。"), timeout = 4 })
    return true
  end
  self:callCompanion("showResume", self.ui)
  return true
end

function AIReadingAssistant:onAIChapterRecap()
  if not isPowerMode() then
    UIManager:show(InfoMessage:new { text = _("精读模式未开启：可在工具菜单的 KOAI 设置中打开。"), timeout = 4 })
    return true
  end
  self:callCompanion("generateChapterRecap", self.ui)
  return true
end

-- ============ 主菜单 ============

function AIReadingAssistant:addToMainMenu(menu_items)
  local CONFIGURATION = getConfiguration() or {}
  local SettingsMenu = require("settings_menu")
  local menu = SettingsMenu.getMenu(CONFIGURATION)
  menu.sorting_hint = "tools"
  menu_items.koai_settings = menu

  -- KOAI 精读菜单：始终显示在搜索（放大镜）页。
  -- 精读模式关闭时：查看类功能（人物卡/档案/回顾等纯本地读取）照常可用，不调 AI、不耗 token；
  -- 生成/采集类功能灰色禁选（enabled_func 实时判断，切开关后重开菜单即更新，无需重开书籍）。
  local sub_items = {
    {
      text = "查询历史（回查 AI 问答记录）",
      callback = function()
        local HistoryViewer = require("history_viewer")
        HistoryViewer.show()
      end,
    },
    {
      text = "本书阅读模式",
      enabled_func = function() return isPowerMode() end,
      callback = function() self:callCompanion("showReadingModeMenu", self.ui) end,
    },
    {
      text = "前序阅读状态",
      enabled_func = function() return isPowerMode() end,
      callback = function() self:callCompanion("showPriorReadingMenu", self.ui, false) end,
    },
    {
      text = "继续阅读回顾",
      callback = function() self:callCompanion("showResume", self.ui) end,
    },
    {
      text = "生成／更新当前进度复盘",
      enabled_func = function() return isPowerMode() end,
      callback = function() self:callCompanion("generateChapterRecap", self.ui) end,
    },
    {
      text = "人物与典故",
      callback = function() self:callCompanion("showCards", self.ui) end,
    },
    {
      text = "故事线、人物关系与时间线",
      callback = function() self:callCompanion("showWorld", self.ui) end,
    },
    {
      text = "全书阅读档案",
      callback = function() self:callCompanion("showArchive", self.ui) end,
    },
    {
      text = "导出 Markdown 阅读档案",
      callback = function() self:callCompanion("exportArchive", self.ui) end,
    },
    {
      text = "本地数据管理",
      callback = function() self:callCompanion("showDataManager", self.ui) end,
    },
    {
      text = "插件诊断",
      callback = function()
        local _, logic_err = optionalRequire("companion_logic")
        local _, storage_err = optionalRequire("companion_storage")
        local text = "KOAI 基础模块：已加载"
            .. "\n精读模块（companion_logic）：" .. (logic_err and ("失败\n" .. logic_err) or "已加载")
            .. "\n本地存储模块（companion_storage）：" .. (storage_err and ("失败\n" .. storage_err) or "已加载")
        UIManager:show(InfoMessage:new { text = text, timeout = 15 })
      end,
    },
  }
  menu_items.koai_reader = {
    text = "KOAI 精读",
    sorting_hint = "search",
    sub_item_table = sub_items,
  }
end

return AIReadingAssistant
