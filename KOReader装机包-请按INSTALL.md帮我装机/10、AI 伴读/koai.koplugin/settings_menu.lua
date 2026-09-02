-- KOAI settings_menu.lua —— DeepSeek 专用设置菜单
-- 划词菜单管理 + DeepSeek 模型选择 + 精读模式总开关 + KOAI 专属设置。
local _ = require("gettext")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")

local DEEPSEEK_MODELS = {
  "deepseek-v4-flash",
  "deepseek-v4-pro",
}

local SettingsMenu = {}

function SettingsMenu.getMenu(CONFIGURATION, on_change_callback)
  -- Helper to save changes and refresh touchmenu
  local function save_and_notify(updates, touchmenu)
    CONFIGURATION:update(updates)
    if on_change_callback then
      on_change_callback(touchmenu)
    end
    UIManager:show(InfoMessage:new{ text = _("设置已保存"), timeout = 1 })
    if touchmenu and touchmenu.updateItems then
      touchmenu:updateItems()
    end
  end

  -- 模型选择菜单（DeepSeek 专用；直接持有表引用，无需按索引定位）
  local models_menu = {
    text_func = function()
      return _("DeepSeek 模型: ") .. (CONFIGURATION.deepseek_model or "deepseek-v4-flash")
    end,
    sub_item_table = {},
  }

  local function rebuild_models_submenu()
    for k in pairs(models_menu.sub_item_table) do
      models_menu.sub_item_table[k] = nil
    end
    for _, model_name in ipairs(DEEPSEEK_MODELS) do
      table.insert(models_menu.sub_item_table, {
        text = model_name,
        checked_func = function()
          return (CONFIGURATION.deepseek_model or "deepseek-v4-flash") == model_name
        end,
        keep_menu_open = true,
        callback = function(touchmenu)
          save_and_notify({ deepseek_model = model_name }, touchmenu)
        end,
      })
    end
    table.insert(models_menu.sub_item_table, {
      text = _("自定义模型名称..."),
      callback = function(touchmenu)
        local input_dialog
        input_dialog = InputDialog:new {
          title = _("输入 DeepSeek 模型名称"),
          input = CONFIGURATION.deepseek_model or "deepseek-v4-flash",
          input_type = "text",
          buttons = {
            {
              {
                text = _("取消"),
                callback = function()
                  UIManager:close(input_dialog)
                end,
              },
              {
                text = _("保存"),
                is_enter_default = true,
                callback = function()
                  local model = input_dialog:getInputText()
                  save_and_notify({ deepseek_model = model }, touchmenu)
                  UIManager:close(input_dialog)
                end,
              },
            },
          },
        }
        UIManager:show(input_dialog)
        input_dialog:onShowKeyboard()
      end,
    })
  end

  rebuild_models_submenu()

  -- Main menu structure
  local menu = {
    text = _("KOAI 设置"),
    sub_item_table = {
      {
        text = _("划词常用菜单管理"),
        sub_item_table = (function()
          local sub = {}
          for i = 1, 5 do
            local enabled_key = "enabled" .. i
            local text_key = "menu_text" .. i
            local prompt_key = "prompt" .. i

            table.insert(sub, {
              text_func = function()
                local name = CONFIGURATION[text_key] or ("Prompt " .. i)
                local is_enabled = CONFIGURATION[enabled_key]
                if is_enabled == nil then is_enabled = true end
                return name .. (is_enabled and "" or " (" .. _("已禁用") .. ")")
              end,
              sub_item_table = {
                {
                  text_func = function()
                    local is_enabled = CONFIGURATION[enabled_key]
                    if is_enabled == nil then is_enabled = true end
                    return _("启用该菜单: ") .. (is_enabled and _("开启") or _("关闭"))
                  end,
                  checked_func = function()
                    local is_enabled = CONFIGURATION[enabled_key]
                    if is_enabled == nil then is_enabled = true end
                    return is_enabled
                  end,
                  keep_menu_open = true,
                  callback = function(touchmenu)
                    local is_enabled = CONFIGURATION[enabled_key]
                    if is_enabled == nil then is_enabled = true end
                    local updates = {}
                    updates[enabled_key] = not is_enabled
                    save_and_notify(updates, touchmenu)
                  end,
                },
                {
                  text_func = function()
                    return _("菜单名称: ") .. (CONFIGURATION[text_key] or "")
                  end,
                  callback = function(touchmenu)
                    local input_dialog
                    input_dialog = InputDialog:new {
                      title = _("修改菜单名称"),
                      input = CONFIGURATION[text_key] or "",
                      input_type = "text",
                      buttons = {
                        {
                          {
                            text = _("取消"),
                            callback = function()
                              UIManager:close(input_dialog)
                            end,
                          },
                          {
                            text = _("保存"),
                            is_enter_default = true,
                            callback = function()
                              local name = input_dialog:getInputText()
                              local updates = {}
                              updates[text_key] = name
                              save_and_notify(updates, touchmenu)
                              UIManager:close(input_dialog)
                            end,
                          },
                        },
                      },
                    }
                    UIManager:show(input_dialog)
                    input_dialog:onShowKeyboard()
                  end,
                },
                {
                  text_func = function()
                    local val = CONFIGURATION[prompt_key] or ""
                    if #val > 30 then
                      val = val:sub(1, 30) .. "..."
                    end
                    return _("Prompt 内容: ") .. val
                  end,
                  callback = function(touchmenu)
                    local input_dialog
                    input_dialog = InputDialog:new {
                      title = _("修改 Prompt 内容"),
                      input = CONFIGURATION[prompt_key] or "",
                      input_type = "text",
                      buttons = {
                        {
                          {
                            text = _("取消"),
                            callback = function()
                              UIManager:close(input_dialog)
                            end,
                          },
                          {
                            text = _("保存"),
                            is_enter_default = true,
                            callback = function()
                              local pr = input_dialog:getInputText()
                              local updates = {}
                              updates[prompt_key] = pr
                              save_and_notify(updates, touchmenu)
                              UIManager:close(input_dialog)
                            end,
                          },
                        },
                      },
                    }
                    UIManager:show(input_dialog)
                    input_dialog:onShowKeyboard()
                  end,
                }
              }
            })
          end
          return sub
        end)(),
      },
      {
        separator = true,
      },
      models_menu,
      {
        separator = true,
      },
      {
        text_func = function()
          return _("自动扩展整句: ") .. (CONFIGURATION.auto_expand_to_sentence and _("开启") or _("关闭"))
        end,
        checked_func = function()
          return CONFIGURATION.auto_expand_to_sentence
        end,
        keep_menu_open = true,
        callback = function(touchmenu)
          save_and_notify({ auto_expand_to_sentence = not CONFIGURATION.auto_expand_to_sentence }, touchmenu)
        end,
      },
      {
        text_func = function()
          return _("KOAI 响应最大行数: ") .. (CONFIGURATION.max_ai_response_lines or 0)
        end,
        callback = function(touchmenu)
          local input_dialog
          input_dialog = InputDialog:new {
            title = _("最大显示行数 (0表示不限制)"),
            input = tostring(CONFIGURATION.max_ai_response_lines or 0),
            input_type = "number",
            buttons = {
              {
                {
                  text = _("取消"),
                  callback = function()
                    UIManager:close(input_dialog)
                  end,
                },
                {
                  text = _("保存"),
                  is_enter_default = true,
                  callback = function()
                    local val = tonumber(input_dialog:getInputText()) or 0
                    save_and_notify({ max_ai_response_lines = val }, touchmenu)
                    UIManager:close(input_dialog)
                  end,
                },
              },
            },
          }
          UIManager:show(input_dialog)
          input_dialog:onShowKeyboard()
        end,
      },
      -- ===== 精读模式（KOAI）=====
      {
        separator = true,
      },
      {
        text_func = function()
          return _("精读模式: ") .. (CONFIGURATION.power_mode and _("开启") or _("关闭"))
        end,
        checked_func = function()
          return CONFIGURATION.power_mode == true
        end,
        keep_menu_open = true,
        callback = function(touchmenu)
          save_and_notify({ power_mode = not CONFIGURATION.power_mode }, touchmenu)
        end,
      },
      {
        text = _("开启后划词附已读上下文、人物卡与复盘"),
        enabled_func = function() return false end,
      },
      {
        text_func = function()
          return _("思考模式：")
              .. (CONFIGURATION.thinking_enabled and _("开启") or _("关闭（推荐）"))
        end,
        checked_func = function() return CONFIGURATION.thinking_enabled == true end,
        keep_menu_open = true,
        callback = function(touchmenu)
          save_and_notify({ thinking_enabled = not CONFIGURATION.thinking_enabled }, touchmenu)
        end,
      },
      {
        text_func = function()
          return _("超过10小时提示回顾：")
              .. (CONFIGURATION.resume_prompt_enabled and _("开启") or _("关闭"))
        end,
        checked_func = function() return CONFIGURATION.resume_prompt_enabled ~= false end,
        keep_menu_open = true,
        callback = function(touchmenu)
          save_and_notify({ resume_prompt_enabled = not CONFIGURATION.resume_prompt_enabled }, touchmenu)
        end,
      },
      {
        text_func = function()
          return _("自动采集已读页面：")
              .. (CONFIGURATION.auto_capture_enabled and _("开启") or _("关闭"))
        end,
        checked_func = function() return CONFIGURATION.auto_capture_enabled ~= false end,
        keep_menu_open = true,
        callback = function(touchmenu)
          save_and_notify({ auto_capture_enabled = not CONFIGURATION.auto_capture_enabled }, touchmenu)
        end,
      },
      {
        text_func = function()
          local mode = CONFIGURATION.storage_mode or "standard"
          local label = mode == "compact" and _("节省空间") or (mode == "full" and _("完整档案") or _("标准"))
          return _("本地保存模式：") .. label
        end,
        sub_item_table = {
          {
            text = _("标准｜完整保留去重原文，自动控制备份"),
            checked_func = function() return (CONFIGURATION.storage_mode or "standard") == "standard" end,
            keep_menu_open = true,
            callback = function(touchmenu)
              save_and_notify({ storage_mode = "standard" }, touchmenu)
            end,
          },
          {
            text = _("节省空间｜复盘后仅保留最近原始文字"),
            checked_func = function() return (CONFIGURATION.storage_mode or "standard") == "compact" end,
            keep_menu_open = true,
            callback = function(touchmenu)
              save_and_notify({ storage_mode = "compact" }, touchmenu)
            end,
          },
          {
            text = _("完整档案｜完整保留原文并保留更多备份"),
            checked_func = function() return (CONFIGURATION.storage_mode or "standard") == "full" end,
            keep_menu_open = true,
            callback = function(touchmenu)
              save_and_notify({ storage_mode = "full" }, touchmenu)
            end,
          },
        },
      },
      {
        text = _("查看本地数据位置"),
        callback = function()
          local ok, Storage = pcall(function() return require("companion_storage") end)
          local text
          if ok and Storage and Storage.getBaseDir then
            text = tostring(Storage.getBaseDir())
          else
            text = _("精读模式未启用或存储模块未加载。")
          end
          UIManager:show(InfoMessage:new { text = text, timeout = 8 })
        end,
      },
    }
  }

  return menu
end

return SettingsMenu
