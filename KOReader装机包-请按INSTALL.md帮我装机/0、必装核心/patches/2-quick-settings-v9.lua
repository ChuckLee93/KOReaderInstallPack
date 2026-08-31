-- Quick Settings tab for KOReader top menu
-- Adds a new tab at the far left with Wi-Fi, action buttons, and frontlight/warmth sliders.
-- Works in both File Manager and Book Reader views.
-- Additional buttons for the Quick Settings tab.
-- Adds optional buttons for OPDS Catalog, NotionSync, and Reading Streak.
-- OPDS Catalog is included with KOReader and allows browsing OPDS book catalogs.
-- NotionSync plugin by Cezary Pukownik: https://github.com/CezaryPukownik/notionsync.koplugin
-- Reading Streak plugin by advokatb: https://github.com/advokatb/readingstreak.koplugin

-- KOReader 顶部菜单的快速设置标签页
-- 在最左侧新增一个标签页，包含 Wi-Fi、操作按钮以及前光/色温滑块。
-- 在文件管理器和阅读器视图中均可使用。
-- 快速设置标签页的附加按钮。
-- 为 OPDS 目录、NotionSync 和阅读 streak 添加可选按钮。
-- OPDS 目录是 KOReader 自带的，用于浏览 OPDS 电子书目录。
-- NotionSync 插件作者：Cezary Pukownik：https://github.com/CezaryPukownik/notionsync.koplugin
-- Reading Streak 插件作者：advokatb：https://github.com/advokatb/readingstreak.koplugin

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Math = require("optmath")
local NetworkMgr = require("ui/network/manager")
local Button = require("ui/widget/button")
local ConfirmBox = require("ui/widget/confirmbox")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local Screen = Device.screen

-- Directory for custom quick-settings icons (relative to KOReader working directory)
-- 自定义快速设置图标目录（相对于 KOReader 工作目录）
local ICON_DIR = "./icons/quick_settings/"

-- ============================================================
-- SlimSlider: Win11-style thin track + vertical thumb slider
-- ============================================================
local SlimSlider = Widget:extend{
    width = 200,
    height = Screen:scaleBySize(28),
    minimum = 0,
    maximum = 100,
    value = 0,
    show_parent = nil,
    enabled = true,
}

function SlimSlider:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function SlimSlider:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function SlimSlider:setValue(v)
    self.value = math.max(self.minimum, math.min(self.maximum, v or 0))
end

function SlimSlider:getValueFromPosition(pos)
    if not self.dimen or not pos then 
        return nil 
    end
    
    if not pos.x or not pos.y then
        return nil
    end
    
    local rel_x = pos.x - self.dimen.x
    rel_x = math.max(0, math.min(self.width, rel_x))
    
    local range = self.maximum - self.minimum
    if range <= 0 then return self.minimum end
    
    local value = self.minimum + (rel_x / self.width) * range
    return math.floor(value + 0.5)
end

function SlimSlider:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    
    local track_h = Screen:scaleBySize(2)
    local thumb_w = Screen:scaleBySize(3)
    local thumb_h = Screen:scaleBySize(14)
    local cy = y + math.floor(self.height / 2)
    local range = math.max(1, self.maximum - self.minimum)
    local pct = (self.value - self.minimum) / range
    local fill_w = math.floor(pct * self.width)

    fill_w = math.max(0, math.min(self.width, fill_w))

    bb:paintRect(x, cy - math.floor(track_h / 2), self.width, track_h, Blitbuffer.COLOR_LIGHT_GRAY)
    if fill_w > 0 then
        bb:paintRect(x, cy - math.floor(track_h / 2), fill_w, track_h, Blitbuffer.COLOR_BLACK)
    end
    local tx = x + fill_w - math.floor(thumb_w / 2)
    tx = math.max(x, math.min(x + self.width - thumb_w, tx))
    bb:paintRect(tx, cy - math.floor(thumb_h / 2), thumb_w, thumb_h, Blitbuffer.COLOR_BLACK)
end

-- Patch IconWidget to also search in our custom subfolder
-- 给 IconWidget 打补丁，让它优先在自定义子文件夹中查找图标
local IconWidget = require("ui/widget/iconwidget")
local orig_IconWidget_init = IconWidget.init
function IconWidget:init()
    if self.icon and not self.image and not self.file then
        local custom_path = ICON_DIR .. self.icon .. ".svg"
        if lfs.attributes(custom_path, "mode") == "file" then
            self.file = custom_path
        end
    end
    orig_IconWidget_init(self)
end

-- ============================================================
-- Configuration
-- ============================================================
-- 配置

local config_default = {
    button_order = { "wifi", "night", "rotate", "usb", "search", "quickrss", "cloud", "zlibrary", "calibre", "notion", "streak", "opds", "filebrowser", "restart", "exit", "sleep" },
    show_buttons = {
        wifi = true,
        night = true,
        rotate = true,
        usb = true,
        search = false,
        quickrss = false,
        cloud = false,
        zlibrary = false,
        calibre = false,
        restart = true,
        exit = true,
        sleep = true,
        notion = false,
        streak = false,
        opds = false,
        filebrowser = false,
    },
    show_frontlight = true,
    show_warmth = true,
    open_on_start = false,
}

local config

local function loadConfig()
    config = G_reader_settings:readSetting("quick_settings_panel", config_default)
    for k, v in pairs(config_default) do
        if config[k] == nil then
            config[k] = v
        end
    end
    if type(config.show_buttons) == "table" then
        for k, v in pairs(config_default.show_buttons) do
            if config.show_buttons[k] == nil then
                config.show_buttons[k] = v
            end
        end
    else
        config.show_buttons = config_default.show_buttons
    end
    if type(config.button_order) ~= "table" then
        config.button_order = config_default.button_order
    else
        local known = {}
        for _, id in ipairs(config.button_order) do
            known[id] = true
        end
        for _, id in ipairs(config_default.button_order) do
            if not known[id] then
                table.insert(config.button_order, id)
                known[id] = true
            end
        end
        local seen = {}
        local deduped = {}
        for _, id in ipairs(config.button_order) do
            if not seen[id] then
                seen[id] = true
                table.insert(deduped, id)
            end
        end
        config.button_order = deduped
    end
end

local function saveConfig()
    G_reader_settings:saveSetting("quick_settings_panel", config)
end

loadConfig()

-- ============================================================
-- Button definitions (data-driven)
-- ============================================================
-- 按钮定义（数据驱动）

local button_defs = {
    wifi = {
        icon = "quick_wifi",
        label = "Wi-Fi",
        label_func = function()
            if NetworkMgr:isWifiOn() then
                local net = NetworkMgr:getCurrentNetwork()
                if net and net.ssid then
                    return net.ssid
                end
            end
            return "Wi-Fi"
        end,
        active_func = function() return NetworkMgr:isWifiOn() end,
        callback = function(touch_menu)
            if NetworkMgr:isWifiOn() then
                NetworkMgr:toggleWifiOff()
            else
                NetworkMgr:toggleWifiOn()
            end
            -- 延迟刷新面板，让图标状态更新
            UIManager:scheduleIn(0.5, function()
                if touch_menu and touch_menu.item_table and touch_menu.item_table.panel then
                    touch_menu:updateItems(1)  -- 刷新当前面板
                end
            end)
        end,
    },
    night = {
        icon = "quick_nightmode",
        label = "夜间模式",
        active_func = function() return G_reader_settings:isTrue("night_mode") end,
        callback = function(touch_menu)
            local night_mode = G_reader_settings:isTrue("night_mode")
            Screen:toggleNightMode()
            UIManager:ToggleNightMode(not night_mode)
            G_reader_settings:saveSetting("night_mode", not night_mode)
            touch_menu:updateItems(1)
            UIManager:setDirty("all", "full")
        end,
    },
    rotate = {
        icon = "quick_rotate",
        label = "旋转",
        callback = function()
            UIManager:broadcastEvent(Event:new("SwapRotation"))
        end,
    },
    usb = {
        icon = "quick_usb",
        label = "USB",
        callback = function()
            if Device:canToggleMassStorage() then
                UIManager:broadcastEvent(Event:new("RequestUSBMS"))
            end
        end,
    },
    restart = {
        icon = "quick_restart",
        label = "重启",
        callback = function()
            UIManager:show(require("ui/widget/infomessage"):new{
                text = _("正在重启……"),
            })
            UIManager:scheduleIn(0.5, function()
                UIManager:broadcastEvent(Event:new("Restart"))
            end)
        end,
    },
    exit = {
        icon = "quick_exit",
        label = "退出",
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("确定要退出 KOReader 吗？"),
                ok_text = _("退出"),
                ok_callback = function()
                    UIManager:broadcastEvent(Event:new("Exit"))
                end,
            })
        end,
    },
    sleep = {
        icon = "quick_sleep",
        label = "睡眠",
        callback = function()
            if Device:canSuspend() then
                UIManager:broadcastEvent(Event:new("RequestSuspend"))
            elseif Device:canPowerOff() then
                UIManager:broadcastEvent(Event:new("RequestPowerOff"))
            end
        end,
    },
    search = {
        icon = "quick_search",
        label = "搜索",
        callback = function()
            UIManager:broadcastEvent(Event:new("ShowFileSearch"))
        end,
    },
    quickrss = {
        icon = "quick_quickrss",
        label = "QuickRSS",
        callback = function()
            local ok, QuickRSSUI = pcall(require, "modules/ui/feed_view")
            if ok and QuickRSSUI then
                local view = QuickRSSUI:new{}
                UIManager:show(view)
                view:_fetch()
            else
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{
                    text = _("QuickRSS 插件未安装。"),
                })
            end
        end,
    },
    cloud = {
        icon = "quick_cloud",
        label = "云存储",
        callback = function()
            UIManager:broadcastEvent(Event:new("ShowCloudStorage"))
        end,
    },
    zlibrary = {
        icon = "quick_zlib",
        label = "Z-Library",
        callback = function()
            UIManager:broadcastEvent(Event:new("ZlibrarySearch"))
        end,
    },
    calibre = {
        icon = "quick_calibre",
        label = "Calibre",
        active_func = function()
            local CW = package.loaded["wireless"]
            return CW ~= nil and CW.calibre_socket ~= nil
        end,
        callback = function(touch_menu)
            local CW = package.loaded["wireless"]
            if CW and CW.calibre_socket ~= nil then
                UIManager:broadcastEvent(Event:new("CloseWirelessConnection"))
            else
                UIManager:broadcastEvent(Event:new("StartWirelessConnection"))
            end
            UIManager:scheduleIn(1, function()
                touch_menu:updateItems(1)
            end)
        end,
    },
	notion = {
        icon = "quick_notion",
        label = "NotionSync",
        callback = function()
            local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
            local ok_f, FileManager = pcall(require, "apps/filemanager/filemanager")
            local ui = (ok_r and ReaderUI.instance) or (ok_f and FileManager.instance)
            if ui and ui.NotionSync then
                ui.NotionSync:onSyncAllBooksRequested()
            end
        end,
    },
    streak = {
        icon = "quick_streak",
        label = "阅读 Streak",
        callback = function()
            UIManager:broadcastEvent(Event:new("ShowReadingStreakCalendar"))
        end,
    },
    opds = {
        icon = "quick_opds",
        label = "OPDS 目录",
        callback = function()
            UIManager:broadcastEvent(Event:new("ShowOPDSCatalog"))
        end,
    },
    filebrowser = {
        icon = "quick_filebrowserplus",
        label = "FilebrowserPlus",
        active_func = function()
            -- 检查 pid 文件是否存在来判断服务是否运行
            local pid_file = "/tmp/filebrowserplus_koreader.pid"
            local file_exists = lfs.attributes(pid_file, "mode") == "file"
            
            -- 如果 pid 文件存在，再检查进程是否真的在运行
            if file_exists then
                local pid = io.open(pid_file):read()
                if pid then
                    -- 检查进程是否存在
                    local cmd = "kill -0 " .. pid .. " 2>/dev/null"
                    local success = os.execute(cmd)
                    return success == 0 or success == true
                end
            end
            return false
        end,
        callback = function(touch_menu)
            UIManager:broadcastEvent(Event:new("ToggleFilebrowserPlusServer"))
            -- 延长延迟时间，确保服务有足够时间启动/停止
            UIManager:scheduleIn(2, function()
                if touch_menu.item_table and touch_menu.item_table.panel then
                    touch_menu:updateItems(1)
                end
            end)
        end,
    },
}

-- Display names for the settings menu
-- 设置菜单中显示的名称
local button_display_names = {
    wifi = _("Wi-Fi"),
    night = _("夜间模式"),
    rotate = _("旋转"),
    usb = _("USB"),
    restart = _("重启"),
    exit = _("退出"),
    sleep = _("睡眠"),
    search = _("文件搜索"),
    quickrss = _("QuickRSS"),
    cloud = _("云存储"),
    zlibrary = _("Z-Library"),
    calibre = _("Calibre"),
	notion   = _("Notion"),
    streak   = _("阅读 Streak"),
    opds     = _("OPDS 目录"),
    filebrowser = _("FilebrowserPlus"),
}

-- ============================================================
-- Panel builder — returns panel widget + refs for tap handling
-- ============================================================
-- 面板构建器 — 返回面板部件 + 用于点击处理的引用

local function createQuickSettingsPanel(touch_menu)
    local panel_width = touch_menu.item_width
    local padding = Screen:scaleBySize(10)
    local inner_width = panel_width - padding * 2
    local powerd = Device:getPowerDevice()
    
    -- 使用等宽字体确保文字宽度一致
    local monospace_font = Font:getFace("cfont", 16)  -- cfont 通常是等宽字体

    -- Refs table: stored on touch_menu for gesture handling
    -- 引用表：存储在 touch_menu 上，用于手势处理
    local refs = { buttons = {} }

    -- ----- Top row: action buttons -----
    -- ----- 顶行：操作按钮 -----

    -- Collect visible buttons in order
    -- 按顺序收集可见按钮
    local visible_buttons = {}
    for _, id in ipairs(config.button_order) do
        if config.show_buttons[id] and button_defs[id] then
            table.insert(visible_buttons, { id = id, def = button_defs[id] })
        end
    end

    local num_buttons = #visible_buttons
    local action_btn_size = Screen:scaleBySize(48)
    local icon_size = math.floor(action_btn_size * 0.5)
    local label_font = Font:getFace("cfont", 12)

    -- Active styling
    -- 激活状态样式
    local normal_border = Screen:scaleBySize(1)

    local function makeActionButton(icon_name, label_text, active)
        local icon = IconWidget:new{
            icon = icon_name,
            width = icon_size,
            height = icon_size,
            alpha = true,
        }
        
        -- 如果激活，使用深灰色背景
        local bg_color = nil
        if active then
            bg_color = Blitbuffer.COLOR_DARK_GRAY
        end
        
        local circle = FrameContainer:new{
            width = action_btn_size,
            height = action_btn_size,
            radius = math.floor(action_btn_size / 2),
            bordersize = normal_border,
            bordercolor = Blitbuffer.COLOR_BLACK,
            background = bg_color,
            padding = 0,
            CenterContainer:new{
                dimen = Geom:new{
                    w = action_btn_size - normal_border * 2,
                    h = action_btn_size - normal_border * 2,
                },
                icon,
            },
        }
        local label = TextWidget:new{
            text = label_text,
            face = label_font,
            max_width = action_btn_size + Screen:scaleBySize(4),
        }
        local group = VerticalGroup:new{
            align = "center",
            circle,
            VerticalSpan:new{ width = Screen:scaleBySize(2) },
            label,
        }
        return group, circle
    end

    -- Build button row
    -- 构建按钮行
    local top_row = HorizontalGroup:new{ align = "center" }

    if num_buttons > 0 then
        -- gap between buttons = gap from edge, so total gaps = num_buttons + 1
        local btn_gap = math.floor((inner_width - num_buttons * action_btn_size) / (num_buttons + 1))

        table.insert(top_row, HorizontalSpan:new{ width = btn_gap })
        for i, entry in ipairs(visible_buttons) do
            local def = entry.def
            local label_text = def.label
            if def.label_func then
                label_text = def.label_func()
            end
            local active = def.active_func and def.active_func() or false
            local btn_widget, btn_circle = makeActionButton(def.icon, label_text, active)

            table.insert(refs.buttons, {
                widget = btn_circle,
                callback = function()
                    def.callback(touch_menu)
                end,
            })

            table.insert(top_row, btn_widget)
            if i < num_buttons then
                table.insert(top_row, HorizontalSpan:new{ width = btn_gap })
            end
        end
        table.insert(top_row, HorizontalSpan:new{ width = btn_gap })
    end

    -- ----- Frontlight section -----
    -- ----- 前光部分 -----

    local medium_font = Font:getFace("ffont")
    local small_btn_width = Screen:scaleBySize(30)
    -- 统一按钮宽度，让 ON/OFF 和 MAX 按钮大小一致
    local unified_btn_width = Screen:scaleBySize(45)  -- 可以根据需要调整这个值
    local slider_gap = Screen:scaleBySize(3)
    -- Slider width is fixed based on original button sizes so it doesn't grow when buttons shrink
    -- 滑块宽度固定，基于原始按钮尺寸计算，防止按钮缩小后滑块变宽
    local orig_small = Screen:scaleBySize(40)
    local orig_max = Screen:scaleBySize(50)
    local orig_gap = Screen:scaleBySize(4)
    local slider_width = inner_width - 2 * orig_small - unified_btn_width - 3 * orig_gap
    local slider_height = Screen:scaleBySize(20)  -- for progress bar height
    local section_span = VerticalSpan:new{ width = Screen:scaleBySize(6) }

    local fl_group = VerticalGroup:new{ align = "center" }

    if config.show_frontlight then
        -- Frontlight state
        -- 前光状态
        local fl = {
            min = powerd.fl_min,
            max = powerd.fl_max,
            cur = powerd:frontlightIntensity(),
        }
        local fl_steps = fl.max - fl.min + 1
        local fl_stride = math.ceil(fl_steps * (1/25))

        -- Ticks for the progress bar
        -- 进度条的刻度
        local fl_ticks = {}
        local fl_num_ticks = math.ceil(fl_steps / fl_stride)
        if (fl_num_ticks - 1) * fl_stride < fl.max - fl.min then
            fl_num_ticks = fl_num_ticks + 1
        end
        fl_num_ticks = math.min(fl_num_ticks, fl_steps)
        for i = 1, fl_num_ticks - 2 do
            table.insert(fl_ticks, i * fl_stride)
        end

        local fl_label = TextWidget:new{
            text = _("前光") .. ": " .. tostring(fl.cur),
            face = medium_font,
            max_width = inner_width,
        }

        -- Create buttons first to measure height
        -- 先创建按钮以测量高度
        local fl_minus = Button:new{
            text = "−",
            width = small_btn_width,
            show_parent = touch_menu.show_parent,
            callback = function() end,
            bordersize = 0,
        }
        local btn_height = fl_minus:getSize().h

        local fl_slider = SlimSlider:new{
            width = slider_width,
            height = btn_height,
            minimum = fl.min,
            maximum = fl.max,
            value = fl.cur,
            show_parent = touch_menu.show_parent,
            enabled = true,
        }

        -- Saved brightness for ON restore
        -- 保存的亮度用于 ON 恢复
        local fl_saved_brightness = (fl.cur > fl.min) and fl.cur or fl.max
        local fl_toggle_btn  -- forward declaration / 前向声明

        local function updateBrightnessWidgets()
            fl_slider:setValue(fl.cur)
            fl_label:setText(_("前光") .. ": " .. tostring(fl.cur))
            if fl_toggle_btn then
                fl_toggle_btn:setText(fl.cur > fl.min and "ON" or "OFF")  -- 使用大写，保持三字符
            end
            UIManager:setDirty(touch_menu.show_parent, "ui")
        end

        local function setBrightness(intensity)
            if intensity ~= fl.min and intensity == fl.cur then return end
            intensity = math.max(fl.min, math.min(fl.max, intensity))
            powerd:setIntensity(intensity)
            fl.cur = powerd:frontlightIntensity()
            updateBrightnessWidgets()
        end

        fl_minus.callback = function() setBrightness(fl.cur - 1) end
        local fl_plus = Button:new{
            text = "＋",
            width = small_btn_width,
            show_parent = touch_menu.show_parent,
            callback = function() setBrightness(fl.cur + 1) end,
            bordersize = 0,
        }
        
        -- 创建统一宽度的 ON/OFF 按钮，使用等宽字体
        fl_toggle_btn = Button:new{
            text = fl.cur > fl.min and "ON" or "OFF",  -- 使用大写
            width = unified_btn_width,
            height = btn_height,
            show_parent = touch_menu.show_parent,
            callback = function()
                if fl.cur > fl.min then
                    fl_saved_brightness = fl.cur
                    setBrightness(fl.min)
                else
                    setBrightness(fl_saved_brightness)
                end
            end,
            bordersize = 0,
            text_font = monospace_font,  -- 使用等宽字体确保宽度一致
        }

        local fl_row = HorizontalGroup:new{
            align = "center",
            fl_minus,
            HorizontalSpan:new{ width = slider_gap },
            fl_slider,
            HorizontalSpan:new{ width = slider_gap },
            fl_plus,
            HorizontalSpan:new{ width = slider_gap },
            fl_toggle_btn,
        }

        refs.fl_slider = fl_slider
        refs.fl_state = fl
        refs.setBrightness = setBrightness

        table.insert(fl_group, fl_label)
        table.insert(fl_group, section_span)
        table.insert(fl_group, fl_row)
    end

    -- ----- Warmth section (conditional) -----
    -- ----- 色温部分（有条件） -----

    local warmth_group = VerticalGroup:new{ align = "center" }
    if config.show_warmth and Device:hasNaturalLight() then
        local nl = {
            min = powerd.fl_warmth_min,
            max = powerd.fl_warmth_max,
            cur = powerd:toNativeWarmth(powerd:frontlightWarmth()),
        }

        local btn_height_warmth = Button:new{
            text = "−", 
            width = small_btn_width,
            show_parent = touch_menu.show_parent,
            callback = function() end,
            bordersize = 0,
        }:getSize().h

        local warmth_slider_width = inner_width - 2 * orig_small - unified_btn_width - 3 * orig_gap

        local nl_label = TextWidget:new{
            text = _("色温") .. ": " .. tostring(nl.cur),
            face = medium_font,
            max_width = inner_width,
        }

        local nl_slider = SlimSlider:new{
            width = warmth_slider_width,
            height = btn_height_warmth,
            minimum = nl.min,
            maximum = nl.max,
            value = nl.cur,
            show_parent = touch_menu.show_parent,
            enabled = true,
        }

        local function setWarmth(warmth)
            if warmth == nl.cur then return end
            warmth = math.max(nl.min, math.min(nl.max, warmth))
            powerd:setWarmth(powerd:fromNativeWarmth(warmth))
            nl.cur = powerd:toNativeWarmth(powerd:frontlightWarmth())
            nl_slider:setValue(nl.cur)
            nl_label:setText(_("色温") .. ": " .. tostring(nl.cur))
            UIManager:setDirty(touch_menu.show_parent, "ui")
        end

        local nl_minus = Button:new{
            text = "−",
            width = small_btn_width,
            show_parent = touch_menu.show_parent,
            callback = function() setWarmth(nl.cur - 1) end,
            bordersize = 0,
        }
        local nl_plus = Button:new{
            text = "＋",
            width = small_btn_width,
            show_parent = touch_menu.show_parent,
            callback = function() setWarmth(nl.cur + 1) end,
            bordersize = 0,
        }
        -- 创建统一宽度的 MAX 按钮，使用等宽字体
        local nl_max_btn = Button:new{
            text = "MAX",  -- 大写
            width = unified_btn_width,
            show_parent = touch_menu.show_parent,
            callback = function() setWarmth(nl.max) end,
            bordersize = 0,
            text_font = monospace_font,  -- 使用等宽字体确保宽度一致
        }

        local nl_row = HorizontalGroup:new{
            align = "center",
            nl_minus,
            HorizontalSpan:new{ width = slider_gap },
            nl_slider,
            HorizontalSpan:new{ width = slider_gap },
            nl_plus,
            HorizontalSpan:new{ width = slider_gap },
            nl_max_btn,
        }

        refs.nl_slider = nl_slider
        refs.nl_state = nl
        refs.setWarmth = setWarmth

        table.insert(warmth_group, VerticalSpan:new{ width = Screen:scaleBySize(14) })
        table.insert(warmth_group, nl_label)
        table.insert(warmth_group, section_span)
        table.insert(warmth_group, nl_row)
    end

    -- ----- Assemble panel -----
    -- ----- 组装面板 -----

    local panel = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = Screen:scaleBySize(12) },
    }

    if num_buttons > 0 then
        table.insert(panel, CenterContainer:new{
            dimen = Geom:new{ w = panel_width, h = top_row:getSize().h },
            top_row,
        })
        table.insert(panel, VerticalSpan:new{ width = Screen:scaleBySize(8) })
    end

    if #fl_group > 0 then
        table.insert(panel, fl_group)
    end
    if #warmth_group > 0 then
        table.insert(panel, warmth_group)
    end
    table.insert(panel, VerticalSpan:new{ width = Screen:scaleBySize(8) })

    -- Store refs on the touch_menu for gesture handlers
    -- 将引用存储在 touch_menu 上，供手势处理程序使用
    touch_menu._qs_refs = refs

    return panel
end

-- ============================================================
-- Gesture handler for panel taps/pans
-- ============================================================
-- 面板点击/滑动的手势处理程序

local function handlePanelGesture(touch_menu, ges)
    local refs = touch_menu._qs_refs
    if not refs then return false end
    
    if not ges or not ges.pos then return false end
    
    local function isPointInWidget(pos, widget)
        if not widget or not widget.dimen then return false end
        if not pos or not pos.x or not pos.y then return false end
        if not widget.dimen.x or not widget.dimen.y or not widget.dimen.w or not widget.dimen.h then
            return false
        end
        return pos.x >= widget.dimen.x and pos.x <= widget.dimen.x + widget.dimen.w and
               pos.y >= widget.dimen.y and pos.y <= widget.dimen.y + widget.dimen.h
    end

    if refs.fl_slider and refs.fl_slider.dimen and isPointInWidget(ges.pos, refs.fl_slider) then
        local new_val = refs.fl_slider:getValueFromPosition(ges.pos)
        if new_val and refs.setBrightness then
            refs.setBrightness(new_val)
            return true
        end
    end

    if refs.nl_slider and refs.nl_slider.dimen and isPointInWidget(ges.pos, refs.nl_slider) then
        local new_val = refs.nl_slider:getValueFromPosition(ges.pos)
        if new_val and refs.setWarmth then
            refs.setWarmth(new_val)
            return true
        end
    end

    for _, btn_ref in ipairs(refs.buttons) do
        if btn_ref.widget and btn_ref.widget.dimen and isPointInWidget(ges.pos, btn_ref.widget) then
            btn_ref.callback()
            return true
        end
    end

    return false
end

-- ============================================================
-- Hook TouchMenu to support panel tabs
-- ============================================================
-- 挂钩 TouchMenu 以支持面板标签页

local TouchMenu = require("ui/widget/touchmenu")
local FocusManager = require("ui/widget/focusmanager")
local datetime = require("datetime")
local BD = require("ui/bidi")

-- Hook updateItems for panel rendering
-- 挂钩 updateItems 以进行面板渲染
local orig_updateItems = TouchMenu.updateItems

function TouchMenu:updateItems(target_page, target_item_id)
    if not self.item_table or not self.item_table.panel then
        self._qs_refs = nil
        return orig_updateItems(self, target_page, target_item_id)
    end

    self.item_group:clear()
    self.layout = {}
    table.insert(self.item_group, self.bar)
    table.insert(self.layout, self.bar.icon_widgets)

    local panel_fn = self.item_table.panel
    local panel = type(panel_fn) == "function" and panel_fn(self) or panel_fn
    table.insert(self.item_group, panel)

    table.insert(self.item_group, self.footer_top_margin)
    table.insert(self.item_group, self.footer)
    self.page_info_text:setText("")
    self.page_info_left_chev:showHide(false)
    self.page_info_right_chev:showHide(false)

    local time_info_txt = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
    local powerd = Device:getPowerDevice()
    if Device:hasBattery() then
        local batt_lvl = powerd:getCapacity()
        local batt_symbol = powerd:getBatterySymbol(powerd:isCharged(), powerd:isCharging(), batt_lvl)
        time_info_txt = BD.wrap(time_info_txt) .. " " .. BD.wrap("⌁") .. BD.wrap(batt_symbol) ..  BD.wrap(batt_lvl .. "%")
    end
    self.time_info:setText(time_info_txt)

    local old_dimen = self.dimen:copy()
    self.dimen.w = self.width
    self.dimen.h = self.item_group:getSize().h + self.bordersize * 2 + self.padding
    self:moveFocusTo(self.cur_tab, 1, FocusManager.NOT_FOCUS)

    local keep_bg = old_dimen and self.dimen.h >= old_dimen.h
    UIManager:setDirty((self.is_fresh or keep_bg) and self.show_parent or "all", function()
        local refresh_dimen = old_dimen and old_dimen:combine(self.dimen) or self.dimen
        local refresh_type = "ui"
        if self.is_fresh then
            refresh_type = "flashui"
            self.is_fresh = false
        end
        return refresh_type, refresh_dimen
    end)
end

-- Hook onTapCloseAllMenus to intercept taps on panel widgets
-- 挂钩 onTapCloseAllMenus 以拦截对面板部件的点击
local orig_onTapCloseAllMenus = TouchMenu.onTapCloseAllMenus

function TouchMenu:onTapCloseAllMenus(arg, ges_ev)
    if self._qs_refs and self.item_table and self.item_table.panel then
        if handlePanelGesture(self, ges_ev) then
            return true
        end
    end
    return orig_onTapCloseAllMenus(self, arg, ges_ev)
end

-- Hook switchMenuTab to force quick settings tab on menu open
-- 挂钩 switchMenuTab 以在菜单打开时强制显示快速设置标签页
local orig_switchMenuTab = TouchMenu.switchMenuTab

function TouchMenu:switchMenuTab(tab_num)
    orig_switchMenuTab(self, tab_num)
    if config.open_on_start then
        self.last_index = 1
    end
end

-- Hook onSwipe to intercept pan/swipe on sliders
-- 挂钩 onSwipe 以拦截在滑块上的滑动
local orig_onSwipe = TouchMenu.onSwipe

function TouchMenu:onSwipe(arg, ges_ev)
    if self._qs_refs and self.item_table and self.item_table.panel then
        if handlePanelGesture(self, ges_ev) then
            return true
        end
    end
    if orig_onSwipe then
        return orig_onSwipe(self, arg, ges_ev)
    end
end

-- Hook onPan to support dragging sliders
-- 挂钩 onPan 以支持拖动滑块
local orig_onPan = TouchMenu.onPan

function TouchMenu:onPan(arg, ges_ev)
    if self._qs_refs and self.item_table and self.item_table.panel then
        if handlePanelGesture(self, ges_ev) then
            return true
        end
    end
    if orig_onPan then
        return orig_onPan(self, arg, ges_ev)
    end
end

-- ============================================================
-- Quick Settings tab definition
-- ============================================================
-- 快速设置标签页定义

local quick_settings_tab = {
    icon = "quicksettings",
    remember = false,
    panel = createQuickSettingsPanel,
}

-- ============================================================
-- Settings menu builder
-- ============================================================
-- 设置菜单构建器

local function buildSettingsMenu()
    local button_toggle_items = {}
    for _, id in ipairs(config_default.button_order) do
        table.insert(button_toggle_items, {
            text = button_display_names[id],
            checked_func = function() return config.show_buttons[id] end,
            callback = function()
                config.show_buttons[id] = not config.show_buttons[id]
                saveConfig()
            end,
        })
    end

    table.insert(button_toggle_items, 1, {
        text = _("排列按钮"),
        keep_menu_open = true,
        separator = true,
        callback = function()
            local SortWidget = require("ui/widget/sortwidget")
            local sort_items = {}
            for _, id in ipairs(config.button_order) do
                if button_defs[id] then
                    table.insert(sort_items, {
                        text = button_display_names[id],
                        orig_item = id,
                        dim = not config.show_buttons[id],
                    })
                end
            end
            UIManager:show(SortWidget:new{
                title = _("排列快速设置按钮"),
                item_table = sort_items,
                callback = function()
                    for i, item in ipairs(sort_items) do
                        config.button_order[i] = item.orig_item
                    end
                    saveConfig()
                end,
            })
        end,
    })

    return {
        text = _("快速设置"),
        sub_item_table = {
            {
                text = _("按钮"),
                sub_item_table = button_toggle_items,
            },
            {
                text = _("显示前光滑块"),
                checked_func = function() return config.show_frontlight end,
                callback = function()
                    config.show_frontlight = not config.show_frontlight
                    saveConfig()
                end,
            },
            {
                text = _("显示色温滑块"),
                checked_func = function() return config.show_warmth end,
                callback = function()
                    config.show_warmth = not config.show_warmth
                    saveConfig()
                end,
                separator = true,
            },
            {
                text = _("打开时显示此标签页"),
                checked_func = function() return config.open_on_start end,
                callback = function()
                    config.open_on_start = not config.open_on_start
                    saveConfig()
                end,
            },
        },
    }
end

-- ============================================================
-- Inject tab and settings into both FileManager and Reader menus
-- ============================================================
-- 将标签页和设置注入文件管理器和阅读器菜单

local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local FileManagerMenuOrder = require("ui/elements/filemanager_menu_order")
local ReaderMenu = require("apps/reader/modules/readermenu")
local ReaderMenuOrder = require("ui/elements/reader_menu_order")

local orig_fm_setUpdateItemTable = FileManagerMenu.setUpdateItemTable

function FileManagerMenu:setUpdateItemTable()
    local already_in_order = false
    for _, v in ipairs(FileManagerMenuOrder.setting) do
        if v == "quick_settings_config" then already_in_order = true; break end
    end
    if not already_in_order then
        table.insert(FileManagerMenuOrder.setting, "----------------------------")
        table.insert(FileManagerMenuOrder.setting, "quick_settings_config")
    end
    self.menu_items.quick_settings_config = buildSettingsMenu()
    orig_fm_setUpdateItemTable(self)
    if self.tab_item_table then
        for i = #self.tab_item_table, 1, -1 do
            if self.tab_item_table[i].icon == "quicksettings" then
                table.remove(self.tab_item_table, i)
            end
        end
        table.insert(self.tab_item_table, 1, quick_settings_tab)
    end
end

local orig_reader_setUpdateItemTable = ReaderMenu.setUpdateItemTable

function ReaderMenu:setUpdateItemTable()
    local already_in_order = false
    for _, v in ipairs(ReaderMenuOrder.setting) do
        if v == "quick_settings_config" then already_in_order = true; break end
    end
    if not already_in_order then
        table.insert(ReaderMenuOrder.setting, "----------------------------")
        table.insert(ReaderMenuOrder.setting, "quick_settings_config")
    end
    self.menu_items.quick_settings_config = buildSettingsMenu()
    orig_reader_setUpdateItemTable(self)
    if self.tab_item_table then
        for i = #self.tab_item_table, 1, -1 do
            if self.tab_item_table[i].icon == "quicksettings" then
                table.remove(self.tab_item_table, i)
            end
        end
        table.insert(self.tab_item_table, 1, quick_settings_tab)
    end
end