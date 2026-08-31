local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local DataStorage = require("datastorage")
local DocumentRegistry = require("document/documentregistry")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")                                                    
local ProgressWidget = require("ui/widget/progresswidget")
local ReaderUI = require("apps/reader/readerui")
local RenderImage = require("ui/renderimage")
local OverlapGroup = require("ui/widget/overlapgroup")
local ScreenSaverWidget = require("ui/widget/screensaverwidget")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Button = require("ui/widget/button")
local lfs = require("libs/libkoreader-lfs")
local bit = require("bit")
local datetime = require("datetime")
local logger = require("logger")
local util = require("util")
local ffiUtil = require("ffi/util")
local SQ3 = require("lua-ljsqlite3/init")
local _ = require("gettext")

local Screen = Device.screen 
local T = ffiUtil.template
-- [设置项常量定义]
local BOOK_RECEIPT_BG_SETTING = "book_receipt_screensaver_background"
local BOOK_RECEIPT_BG_IMAGE_MODE_SETTING = "book_receipt_bg_image_mode"
local BOOK_RECEIPT_CONTENT_MODE_SETTING = "book_receipt_content_mode"
local BOOK_RECEIPT_COVER_SCALE_SETTING = "book_receipt_cover_scale"
local BOOK_RECEIPT_SLEEP_TEXT_SETTING = "book_receipt_sleep_text"

-- 高亮笔记相关的长度限制
local MAX_HIGHLIGHT_SIZE = 500
local HIDE_COVER_FOR_LARGE_HIGHLIGHTS = 300
                                  
local STATISTICS_DB_PATH = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

-- 内容显示模式枚举
local CONTENT_MODE_BOOK_RECEIPT = "book_receipt"
local CONTENT_MODE_HIGHLIGHT_PROGRESS = "highlight_progress"
local CONTENT_MODE_RANDOM = "random"

-- 按最大字符数截断 UTF-8 字符串（防止文本过长撑爆 UI）
local function utf8TrimToLength(str, max_chars)
    if not str or max_chars <= 0 then
        return "", 0, str ~= nil and str ~= ""
    end
    local len = #str
    local index = 1
    local char_count = 0
    local cut_index
    while index <= len do
        local byte = string.byte(str, index)
        if not byte then break end
        local char_len = 1
        if byte >= 0xF0 then
            char_len = 4
        elseif byte >= 0xE0 then
            char_len = 3
        elseif byte >= 0xC0 then
            char_len = 2
        end
        char_count = char_count + 1
        index = index + char_len
        if not cut_index and char_count == max_chars + 1 then
            cut_index = index - char_len
        end
    end
    if cut_index then
        return str:sub(1, cut_index - 1), char_count, true
    end
    return str, char_count, false
end

-- 根据显示权重截断字符串（中文字符权重大于英文，避免中英文混排时布局错乱）
local function getWeightedTruncatedString(str, max_weight)
    if not str or str == "" then return "", false end
    local current_weight = 0
    local len = #str
    local i = 1
    while i <= len do
        local byte = string.byte(str, i)
        local char_len = 1
        local weight = 1
        
        if byte >= 0xF0 then 
            char_len = 4
            weight = 2
        elseif byte >= 0xE0 then 
            char_len = 3 
            weight = 2
        elseif byte >= 0xC0 then 
            char_len = 2
            weight = 2
        end
        
        if current_weight + weight > max_weight then
            return string.sub(str, 1, i - 1) .. "...", true
        end
        
        current_weight = current_weight + weight
        i = i + char_len
    end
    return str, false
end

-- 获取本地化的星期名称（如：星期一、星期二）
local function getLocalizedDayName(timestamp)
    local day_key = timestamp and os.date("%A", timestamp)
    if not day_key then
        return ""
    end
    if datetime and datetime.longDayTranslation and datetime.longDayTranslation[day_key] then
        return datetime.longDayTranslation[day_key]
    end
    return day_key
end

-- 从数据库中读取今日的阅读时长
local function getBookTodayDuration(statistics)
    if not statistics then return nil end
    if statistics.isEnabled and not statistics:isEnabled() then return nil end
    if statistics.insertDB then pcall(statistics.insertDB, statistics) end

    local id_book = statistics.id_curr_book
    if (not id_book) and statistics.getIdBookDB then
        local ok, book_id = pcall(statistics.getIdBookDB, statistics)
        if ok then id_book = book_id end
    end
    if not id_book then return nil end

    if not STATISTICS_DB_PATH or STATISTICS_DB_PATH == "" then return nil end
    local attrs = lfs.attributes(STATISTICS_DB_PATH, "mode")
    if attrs ~= "file" then return nil end

    local now_stamp = os.time()
    local now_t = os.date("*t", now_stamp)
    local from_begin_day = now_t.hour * 3600 + now_t.min * 60 + now_t.sec
    local start_today_time = now_stamp - from_begin_day

    local ok_conn, conn = pcall(SQ3.open, STATISTICS_DB_PATH)
    if not ok_conn or not conn then return nil end

    local sql_stmt = string.format([[SELECT sum(sum_duration)
        FROM (
            SELECT sum(duration) AS sum_duration
            FROM page_stat
            WHERE start_time >= %d AND id_book = %d
            GROUP BY page
        );
    ]], start_today_time, id_book)

    local ok_row, today_duration = pcall(function() return conn:rowexec(sql_stmt) end)
    conn:close()

    if not ok_row or today_duration == nil then return nil end
    today_duration = tonumber(today_duration)
    if not today_duration then return nil end
    if today_duration < 0 then today_duration = 0 end
    return today_duration
end

-- 获取一条随机的高亮/划线笔记
local function getRandomHighlightAnnotation(ui)
    if not ui or not ui.annotation or not ui.annotation.annotations then return nil end
    local candidates = {}
    for _, item in ipairs(ui.annotation.annotations) do
        if item.drawer and item.text then
            local trimmed = util.trim(item.text)
            if trimmed ~= "" then table.insert(candidates, item) end
        end
    end
    if #candidates == 0 then return nil end
    return candidates[math.random(#candidates)]
end

-- 获取阅读小票专用背景图片的目录路径
local function getBookReceiptBackgroundDir()
    local base_dir = DataStorage:getDataDir()
    if not base_dir or base_dir == "" then return nil end
    return string.format("%s/%s", base_dir, "book_receipt_background")
end

-- 从背景文件夹中随机挑选一张图片
local function pickRandomReceiptBackgroundImage()
    local dir = getBookReceiptBackgroundDir()
    if not dir or lfs.attributes(dir, "mode") == "directory" then else return nil end
    local files = {}
    util.findFiles(dir, function(file)
        if not util.stringStartsWith(ffiUtil.basename(file), "._") and DocumentRegistry:isImageFile(file) then
            table.insert(files, file)
        end
    end, false, 512)
    if #files == 0 then return nil end
    return files[math.random(#files)]
end

-- 构建背景图片组件（处理图片的拉伸、缩放适应和居中对齐）
local function buildBackgroundImageWidget(image_source)
    if not image_source then return nil end
    local mode = G_reader_settings:readSetting(BOOK_RECEIPT_BG_IMAGE_MODE_SETTING) or "stretch"
    if mode ~= "center" and mode ~= "stretch" and mode ~= "fit" then mode = "stretch" end
    local screen_size = Screen:getSize()
    local screen_w, screen_h = screen_size.w, screen_size.h
    local image_opts = { alpha = true, file_do_cache = false }
    if type(image_source) == "string" then image_opts.file = image_source else image_opts.image = image_source end
    if mode == "stretch" then
        image_opts.width = screen_w; image_opts.height = screen_h
    elseif mode == "fit" then
        image_opts.width = screen_w; image_opts.height = screen_h; image_opts.scale_factor = 0
    end
    local image_widget = ImageWidget:new(image_opts)
    if mode == "center" then
        return CenterContainer:new{ dimen = screen_size, image_widget }
    end
    return image_widget
end

-- 获取当前文档的书籍封面
local function getActiveDocumentCover(ui)
    if not ui or not ui.document or not ui.bookinfo then return nil end
    return ui.bookinfo:getCoverImage(ui.document)
end

-- 综合判断并返回最终要渲染的小票背景色或背景图片
local function getReceiptBackground(ui)
    local choice = G_reader_settings:readSetting(BOOK_RECEIPT_BG_SETTING) or "white"
    if choice == "transparent" then return nil, nil
    elseif choice == "black" then return Blitbuffer.COLOR_BLACK, nil
    elseif choice == "random_image" then
        local image_path = pickRandomReceiptBackgroundImage()
        if image_path then
            local widget = buildBackgroundImageWidget(image_path)
            if widget then return nil, widget end
        end
        return nil, nil
    elseif choice == "book_cover" then
        local cover_bb = getActiveDocumentCover(ui)
        if cover_bb then
            local widget = buildBackgroundImageWidget(cover_bb)
            if widget then return nil, widget end
        end
        return nil, nil
    end
    return Blitbuffer.COLOR_WHITE, nil
end

-- 检查当前是否在阅读一本书
local function hasActiveDocument(ui)
    return ui and ui.document ~= nil
end

-- 当无法生成阅读小票时，获取系统的后备/默认屏保类型
local function getBookReceiptFallbackType()
    local random_dir = G_reader_settings:readSetting("screensaver_dir")
    if random_dir and lfs.attributes(random_dir, "mode") == "directory" then return "random_image" end
    local document_cover = G_reader_settings:readSetting("screensaver_document_cover")
    if document_cover and lfs.attributes(document_cover, "mode") == "file" then return "document_cover" end
    local lastfile = G_reader_settings:readSetting("lastfile")
    if lastfile and lfs.attributes(lastfile, "mode") == "file" then return "cover" end
    return "random_image"
end

-- 从事件前缀中提取事件名称
local function getEventFromPrefix(prefix)
    if prefix and prefix ~= "" then return prefix:sub(1, -2) end
    return nil
end

-- 触发后备屏保渲染逻辑（当小票生成失败或无书时）
local function showFallbackScreensaver(self, orig_show)
    local fallback_type = getBookReceiptFallbackType()
    local original_type = self.screensaver_type
    local event = getEventFromPrefix(self.prefix)
    local settings = G_reader_settings
    local primary_key = "screensaver_type"
    local had_primary = settings:has(primary_key)
    local original_primary = settings:readSetting(primary_key)
    settings:saveSetting(primary_key, fallback_type)
    local prefixed_key = self.prefix and self.prefix ~= "" and (self.prefix .. "screensaver_type") or nil
    local had_prefixed, original_prefixed
    if prefixed_key then
        had_prefixed = settings:has(prefixed_key)
        original_prefixed = settings:readSetting(prefixed_key)
        settings:saveSetting(prefixed_key, fallback_type)
    end
    self:setup(event, self.event_message)
    self.screensaver_type = fallback_type
    orig_show(self)
    if prefixed_key then
        if had_prefixed then settings:saveSetting(prefixed_key, original_prefixed) else settings:delSetting(prefixed_key) end
    end
    if had_primary then settings:saveSetting(primary_key, original_primary) else settings:delSetting(primary_key) end
    self.screensaver_type = original_type
end

-- [全新升级版胶片组件]：拉高胶带，嵌入标题，保证安全稳定
local FilmStripTitle = FrameContainer:extend{
    background = Blitbuffer.COLOR_BLACK,
    bordersize = 0,
    padding = 0,
    margin = 0,
    title_text = "READING TICKET",
    title_font_size = 36,
}

-- 初始化胶片组件的上下打孔结构和内部文字
function FilmStripTitle:init()
    local w = self.width
    local hole_size = Screen:scaleBySize(5)
    local hole_gap = Screen:scaleBySize(5)
    
    local available_w = w - (hole_gap * 2)
    local num_holes = math.floor((available_w + hole_gap) / (hole_size + hole_gap))
    if num_holes < 1 then num_holes = 1 end
    
    -- 制造胶带上下边缘的小白孔
    local function createHole()
        return FrameContainer:new{
            bordersize = 0,
            padding_left = hole_size, 
            padding_top = hole_size, 
            padding_right = 0, 
            padding_bottom = 0,
            background = Blitbuffer.COLOR_WHITE,
            HorizontalSpan:new{ width = 0 }
        }
    end

    local top_holes = {}
    local bottom_holes = {}
    table.insert(top_holes, HorizontalSpan:new{ width = hole_gap })
    table.insert(bottom_holes, HorizontalSpan:new{ width = hole_gap })
    
    for i = 1, num_holes do
        table.insert(top_holes, createHole())
        table.insert(bottom_holes, createHole())
        if i < num_holes then
            table.insert(top_holes, HorizontalSpan:new{ width = hole_gap })
            table.insert(bottom_holes, HorizontalSpan:new{ width = hole_gap })
        end
    end
    table.insert(top_holes, HorizontalSpan:new{ width = hole_gap })
    table.insert(bottom_holes, HorizontalSpan:new{ width = hole_gap })
    
    local top_row = CenterContainer:new{ dimen = Geom:new{ w = w, h = hole_size }, HorizontalGroup:new(top_holes) }
    local bottom_row = CenterContainer:new{ dimen = Geom:new{ w = w, h = hole_size }, HorizontalGroup:new(bottom_holes) }
    
    -- 生成内嵌的白色标题文字
    local title_widget = TextWidget:new{
        text = self.title_text,
        face = Font:getFace("cfont", self.title_font_size),
        bold = true,
        fgcolor = Blitbuffer.COLOR_WHITE, -- 强制白色字体
        align = "center"
    }

    self[1] = VerticalGroup:new{
        VerticalSpan:new{ width = hole_gap },
        top_row,
        VerticalSpan:new{ width = Screen:scaleBySize(10) }, -- 胶片内顶部留白
        title_widget,
        VerticalSpan:new{ width = Screen:scaleBySize(10) }, -- 胶片内底部留白
        bottom_row,
        VerticalSpan:new{ width = hole_gap },
    }
end

-- [核心函数] 构建阅读小票的卡片实体
local function buildReceipt(ui, state, on_close_callback)
    if not hasActiveDocument(ui) then return nil end

    local doc_props = ui.doc_props or {}
    local book_title = doc_props.display_title or ""
    local book_author = doc_props.authors or ""
    if book_author:find("\n") then
        local authors = util.splitToArray(book_author, "\n")
        if authors and authors[1] then
            book_author = T(_("%1 等"), authors[1] .. ",")
        end
    end

    local doc_settings = ui.doc_settings and ui.doc_settings.data or {}
    local doc_page_no = (state and state.page) or 1
    local doc_page_total = doc_settings.doc_pages or 1
    if doc_page_total <= 0 then doc_page_total = 1 end
    if doc_page_no < 1 then doc_page_no = 1 end
    if doc_page_no > doc_page_total then doc_page_no = doc_page_total end

    local page_no_numeric = doc_page_no
    local page_total_numeric = doc_page_total
    local page_no_display = tostring(page_no_numeric)
    local page_total_display = tostring(page_total_numeric)

    if ui.pagemap and ui.pagemap:wantsPageLabels() then
        local label, idx, count = ui.pagemap:getCurrentPageLabel(true)
        local last_label = ui.pagemap:getLastPageLabel(true)
        if idx and count then page_no_numeric = idx; page_total_numeric = count end
        if label and label ~= "" then page_no_display = label else page_no_display = tostring(page_no_numeric) end
        if last_label and last_label ~= "" then page_total_display = last_label else page_total_display = tostring(page_total_numeric) end
    end

    local page_left = math.max(page_total_numeric - page_no_numeric, 0)
    local toc = ui.toc
    local chapter_title = ""; local chapter_total = page_total_numeric; local chapter_left = 0; local chapter_done = 0
    if toc then
        chapter_title = toc:getTocTitleByPage(doc_page_no) or ""
        chapter_total = toc:getChapterPageCount(doc_page_no) or chapter_total
        chapter_left = toc:getChapterPagesLeft(doc_page_no) or 0
        chapter_done = toc:getChapterPagesDone(doc_page_no) or 0
    end
    chapter_total = chapter_total > 0 and chapter_total or page_total_numeric
    chapter_done = math.max(chapter_done + 1, 1)

    local statistics = ui.statistics
    local avg_time_per_page = statistics and statistics.avg_time
    -- 格式化剩余阅读时间的显示
    local function secs_to_timestring(secs)
        if not secs then return "正在计算时间" end
        local h = math.floor(secs / 3600); local m = math.floor((secs % 3600) / 60)
        local htext = "小时"; local mtext = "分钟"
        if h == 0 and m > 0 then return string.format("%i%s", m, mtext)
        elseif h > 0 and m == 0 then return string.format("%i%s", h, htext)
        elseif h > 0 and m > 0 then return string.format("%i%s %i%s", h, htext, m, mtext)
        elseif h == 0 and m == 0 then return "少于一分钟" end
        return "正在计算时间"
    end
    -- 基于平均速度计算还需多久读完
    local function time_left(pages)
        if not avg_time_per_page then return nil end
        return avg_time_per_page * pages
    end

    local book_time_left = secs_to_timestring(time_left(page_left))
    local chapter_time_left = secs_to_timestring(time_left(chapter_left))
    local current_time = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")) or ""
    local battery = ""
    if Device:hasBattery() then
        local power_dev = Device:getPowerDevice()
        local batt_lvl = power_dev:getCapacity() or 0
        local is_charging = power_dev:isCharging() or false
        local batt_prefix = power_dev:getBatterySymbol(power_dev:isCharged(), is_charging, batt_lvl) or ""
        battery = batt_prefix .. batt_lvl .. "%"
    end

    -- [整体缩小参数与全局样式设定]
    local widget_width = math.floor(Screen:getWidth() * 0.68)
    local db_font_color = Blitbuffer.COLOR_BLACK
    local db_font_color_lighter = Blitbuffer.COLOR_GRAY_3
    local db_font_color_lightest = Blitbuffer.COLOR_GRAY_9
    local db_font_face = "NotoSans-Regular.ttf"
    local db_font_face_italics = "NotoSans-Italic.ttf"
    local db_font_size_huge = 64; local db_font_size_big = 28; local db_font_size_mid = 21; local db_font_size_small = 16
    local db_padding = 20; local db_padding_internal = 8

    -- 判断是否需要展示系统级的屏保留言
    local message_text
    if Device.screen_saver_mode and G_reader_settings:isTrue("screensaver_show_message") then
        local configured_message = G_reader_settings:readSetting("screensaver_message")
        configured_message = configured_message and util.trim(configured_message)
        if configured_message and configured_message ~= "" then
            if ui and ui.bookinfo and ui.bookinfo.expandString then
                message_text = ui.bookinfo:expandString(configured_message) or configured_message
            else
                message_text = configured_message
            end
            if message_text then message_text = util.trim(message_text); if message_text == "" then message_text = nil end end
        end
    end

    -- 生成进度数据区块（带有进度条的章节/全书进度模块）
    local function databox(typename, itemname, pages_done, pages_total, time_left_text, pages_done_display, pages_total_display, options)
        options = options or {}
        local pages_done_num = tonumber(pages_done) or 0
        local pages_total_num = tonumber(pages_total) or 0
        local denom = pages_total_num > 0 and pages_total_num or 1
        local percentage_value = math.max(math.min(pages_done_num / denom, 1), 0)
        local display_done = pages_done_display or pages_done
        local display_total = pages_total_display or pages_total

        local elements = {}
        local progress_side_padding = Screen:scaleBySize(30) 
        local progressbarwidth = widget_width - (progress_side_padding * 2)

        -- 1. 顶部标题
        if not options.hide_title then
            local MAX_WEIGHT = 28 
            local safe_text, was_truncated = getWeightedTruncatedString(itemname, MAX_WEIGHT)
            local adaptive_size = db_font_size_mid
            if was_truncated then adaptive_size = math.floor(db_font_size_mid * 0.9) end

            local title_widget = TextWidget:new{
                face = Font:getFace(db_font_face, adaptive_size), 
                text = safe_text, 
                fgcolor = db_font_color, 
                align = "left",
            }
            local title_right_w = widget_width - progress_side_padding - title_widget:getSize().w
            if title_right_w < 0 then title_right_w = 0 end

            table.insert(elements, HorizontalGroup:new{
                HorizontalSpan:new{ width = progress_side_padding }, 
                title_widget,
                HorizontalSpan:new{ width = title_right_w }, 
            })
            table.insert(elements, VerticalSpan:new{ width = Screen:scaleBySize(4) }) 
        end
        
        -- 2. 剩余时间（移至进度条上方）
        if not options.hide_time and time_left_text then
            local time_text_widget = TextWidget:new{
                text = string.format("%s还需 %s", typename, time_left_text),
                face = Font:getFace(db_font_face_italics, db_font_size_small), 
                bold = false, 
                fgcolor = db_font_color_lighter, 
                padding = 0, 
                align = "left",
            }
            local right_space_w = widget_width - progress_side_padding - time_text_widget:getSize().w
            if right_space_w < 0 then right_space_w = 0 end

            table.insert(elements, HorizontalGroup:new{
                HorizontalSpan:new{ width = progress_side_padding }, 
                time_text_widget,
                HorizontalSpan:new{ width = right_space_w }, 
            })
            -- 与下方进度条的间距
            table.insert(elements, VerticalSpan:new{ width = Screen:scaleBySize(6) }) 
        end

        -- 3. 进度条主体
        local progress_bar = ProgressWidget:new{
            width = progressbarwidth, height = Screen:scaleBySize(6), percentage = percentage_value, margin_v = 0, margin_h = 0, radius = 20, bordersize = 0, bgcolor = db_font_color_lightest, fillcolor = db_font_color,
        }
        table.insert(elements, HorizontalGroup:new{
            HorizontalSpan:new{ width = progress_side_padding }, progress_bar, HorizontalSpan:new{ width = progress_side_padding },
        })

        -- 与下方页码/百分比的间距
        table.insert(elements, VerticalSpan:new{ width = Screen:scaleBySize(6) }) 

        -- 4. 页数 / 百分比（移至进度条下方，并精简了百分比文本）
        local page_progress = TextWidget:new{
            text = string.format("第 %s 页 / 共 %s 页", display_done, display_total),
            face = Font:getFace("cfont", db_font_size_small), bold = false, fgcolor = db_font_color_lighter, padding = 0, align = "left",
        }
        local percentage_display = TextWidget:new{
            -- 核心修改：去掉了后面的 %s 和 typename，只保留纯百分比数字
            text = string.format("%i%%", math.floor(percentage_value * 100 + 0.5)),
            face = Font:getFace("cfont", db_font_size_small), bold = false, fgcolor = db_font_color_lighter, padding = 0, align = "right",
        }

        table.insert(elements, HorizontalGroup:new{
            HorizontalSpan:new{ width = progress_side_padding }, 
            page_progress,
            HorizontalSpan:new{ width = progressbarwidth - page_progress:getSize().w - percentage_display:getSize().w },
            percentage_display,
            HorizontalSpan:new{ width = progress_side_padding }, 
        })

        table.insert(elements, VerticalSpan:new{ width = db_padding_internal })
        return VerticalGroup:new(elements)
    end

    local batt_pct_box = TextWidget:new{ text = battery, face = Font:getFace("cfont", db_font_size_small), bold = false, fgcolor = db_font_color, padding = 0 }
    local glyph_clock = "⌚"
    local time_box = TextWidget:new{ text = string.format("%s%s", glyph_clock, current_time), face = Font:getFace("cfont", db_font_size_small), bold = false, fgcolor = db_font_color, padding = 0 }
    local bottom_bar_inner = HorizontalGroup:new{ batt_pct_box, HorizontalSpan:new{ width = db_padding }, time_box }
    local bottom_bar = CenterContainer:new{ dimen = Geom:new{ w = widget_width, h = bottom_bar_inner:getSize().h }, bottom_bar_inner }

    -- 将原本显示书名的文本变更为固定的提示标题
    local bookboxtitle = "总进度"
    
    local content_mode_setting = G_reader_settings:readSetting(BOOK_RECEIPT_CONTENT_MODE_SETTING) or CONTENT_MODE_BOOK_RECEIPT
    local content_mode = content_mode_setting
    if content_mode_setting == CONTENT_MODE_RANDOM then
        local candidates = { CONTENT_MODE_BOOK_RECEIPT, CONTENT_MODE_HIGHLIGHT_PROGRESS }
        content_mode = candidates[math.random(#candidates)]
    end
    
    local book_total_time_text
    local book_today_time_text
    if statistics and content_mode ~= CONTENT_MODE_HIGHLIGHT_PROGRESS then
        book_total_time_text = string.format("全书已阅读：%s", secs_to_timestring(statistics.book_read_time))
        local today_duration = getBookTodayDuration(statistics)
        if today_duration then
            local day_label = getLocalizedDayName(os.time())
            book_today_time_text = string.format("今天阅读 (%s)：%s", day_label, secs_to_timestring(today_duration))
        end
    end

    local bookbox = databox("全书", bookboxtitle, page_no_numeric, page_total_numeric, book_time_left, page_no_display, page_total_display, {
        hide_title = content_mode == CONTENT_MODE_HIGHLIGHT_PROGRESS, hide_time = content_mode == CONTENT_MODE_HIGHLIGHT_PROGRESS,
    })
    local chapterbox = content_mode ~= CONTENT_MODE_HIGHLIGHT_PROGRESS and databox("本章", chapter_title, chapter_done, chapter_total, chapter_time_left) or nil

    local bg_choice = G_reader_settings:readSetting(BOOK_RECEIPT_BG_SETTING)
    local show_cover = not (Device.screen_saver_mode and bg_choice == "book_cover")
    local top_split_widget = nil
    
    -- 构建卡片顶部的封面、日期区域
    if show_cover and ui.bookinfo and ui.document then
        local cover_bb = ui.bookinfo:getCoverImage(ui.document)
        if cover_bb then
            local cover_scale = G_reader_settings:readSetting(BOOK_RECEIPT_COVER_SCALE_SETTING) or 1
            local cover_width = cover_bb:getWidth(); local cover_height = cover_bb:getHeight()
            local target_width_ratio = 0.25
            local max_width = math.floor(widget_width * target_width_ratio * cover_scale)
            local max_height = math.floor(Screen:getHeight() / 5 * cover_scale)
            local scale = math.min(1, max_width / cover_width, max_height / cover_height)
            if scale < 1 then
                local scaled_w = math.max(1, math.floor(cover_width * scale)); local scaled_h = math.max(1, math.floor(cover_height * scale))
                cover_bb = RenderImage:scaleBlitBuffer(cover_bb, scaled_w, scaled_h, true)
                cover_width = cover_bb:getWidth(); cover_height = cover_bb:getHeight()
            end
            local cover_image_widget = ImageWidget:new{ image = cover_bb, width = cover_width, height = cover_height }
            local framed_cover = FrameContainer:new{ radius = 15, bordersize = 2, padding = 0, background = Blitbuffer.COLOR_WHITE, cover_image_widget }

            local now_t = os.time(); local cal_day = os.date("%d", now_t); local cal_year_month = os.date("%Y.%m", now_t); local cal_weekday = getLocalizedDayName(now_t) 
            local font_scale = (cover_scale and cover_scale > 0.1) and cover_scale or 1
            local f_size_small = math.floor(db_font_size_small * font_scale); local f_size_huge = math.floor(db_font_size_huge * font_scale); local f_size_mid = math.floor(db_font_size_mid * font_scale)
            local gap_size = 0
            if Device.screen_saver_mode then
                cal_year_month = os.date("%m.%d", now_t); cal_day = G_reader_settings:readSetting(BOOK_RECEIPT_SLEEP_TEXT_SETTING) or "休眠中"
                f_size_huge = math.floor(28 * font_scale); gap_size = math.floor(30 * font_scale)
            end
            local f_size_deco = math.floor(10 * font_scale); local span_deco_h = math.floor(4 * font_scale)

            local calendar_group = VerticalGroup:new{
                align = "center",
                TextWidget:new{ text = cal_year_month, face = Font:getFace("cfont", f_size_small), fgcolor = db_font_color_lighter },
                VerticalSpan:new{ width = gap_size },
                TextWidget:new{ text = cal_day, face = Font:getFace("cfont", f_size_huge), bold = true, fgcolor = db_font_color, padding = 0 },
                VerticalSpan:new{ width = gap_size },
                TextWidget:new{ text = cal_weekday, face = Font:getFace("cfont", f_size_mid), fgcolor = db_font_color },
            }
            local deco_group = nil; local deco_w = 0
            if cover_scale < 2 then
                local deco_elements = {}
                local deco_count = 8
                for i = 1, deco_count do
                    table.insert(deco_elements, TextWidget:new{ text = "|", face = Font:getFace("cfont", f_size_deco), fgcolor = db_font_color_lighter, padding = 0 })
                    if i < deco_count then table.insert(deco_elements, VerticalSpan:new{ width = span_deco_h }) end
                end
                deco_group = VerticalGroup:new(deco_elements); deco_w = deco_group:getSize().w
            end
            local available_side_width = math.floor((widget_width - deco_w) / 2)
            local section_height = math.max(framed_cover:getSize().h, calendar_group:getSize().h)
            local left_area = CenterContainer:new{ dimen = Geom:new{ w = available_side_width, h = section_height }, framed_cover }
            local right_area = CenterContainer:new{ dimen = Geom:new{ w = available_side_width, h = section_height }, calendar_group }
            local top_group_elements = { left_area }
            if deco_group then
                 local center_area = CenterContainer:new{ dimen = Geom:new{ w = deco_w, h = section_height }, deco_group }
                table.insert(top_group_elements, center_area)
            end
            table.insert(top_group_elements, right_area)
            top_split_widget = HorizontalGroup:new(top_group_elements)
        end
    end

    local content_children = {}
    
    -- [修复点在此]
    -- 强制撑开整个卡片的宽度基准（原宽度 + 左右边距）
    -- 这样做是为了防止当没有显示与卡片同宽的组件时（例如没有显示胶片），外围的卡片变窄发生萎缩
    local full_ticket_width = widget_width + (db_padding * 2)
    table.insert(content_children, HorizontalSpan:new{ width = full_ticket_width })

    local highlight_widgets
    local highlight_length = 0
    if content_mode == CONTENT_MODE_HIGHLIGHT_PROGRESS then
        local highlight_item = getRandomHighlightAnnotation(ui)
        if highlight_item then
            local highlight_text = util.trim(highlight_item.text or "")
            if highlight_text ~= "" then
                local truncated_text, char_count, was_truncated = utf8TrimToLength(highlight_text, MAX_HIGHLIGHT_SIZE)
                highlight_length = char_count
                if was_truncated then truncated_text = truncated_text .. "..." end
                local meta_parts = {}
                if highlight_item.chapter and highlight_item.chapter ~= "" then table.insert(meta_parts, highlight_item.chapter) end
                local highlight_page = highlight_item.pageref or highlight_item.pageno
                if not highlight_page and highlight_item.page and type(highlight_item.page) == "string" and ui.document and ui.document.getPageFromXPointer then
                    local ok, page_from_xp = pcall(ui.document.getPageFromXPointer, ui.document, highlight_item.page)
                    if ok then highlight_page = page_from_xp end
                end
                if highlight_page then
                    local page_label
                    if type(highlight_page) == "number" then page_label = string.format("%s %s", _("页码"), tostring(highlight_page)) else page_label = highlight_page end
                    table.insert(meta_parts, page_label)
                end
                if #meta_parts > 0 then
                    highlight_widgets = {
                        TextBoxWidget:new{ face = Font:getFace("cfont", db_font_size_big), text = truncated_text, width = widget_width, fgcolor = db_font_color, bold = true, alignment = "center" },
                        VerticalSpan:new{ width = db_padding_internal },
                        TextWidget:new{ text = string.format("(%s)", table.concat(meta_parts, ", ")), face = Font:getFace("cfont", db_font_size_small), bold = false, fgcolor = db_font_color_lighter, padding = 0, align = "center" },
                    }
                else
                    highlight_widgets = { TextBoxWidget:new{ face = Font:getFace("cfont", db_font_size_big), text = truncated_text, width = widget_width, fgcolor = db_font_color, bold = true, alignment = "center" } }
                end
            end
        end
        if not highlight_widgets then content_mode = CONTENT_MODE_BOOK_RECEIPT end
    end

    if content_mode == CONTENT_MODE_BOOK_RECEIPT then
        show_cover = not (Device.screen_saver_mode and bg_choice == "book_cover")
    else
        if bg_choice == "book_cover" or highlight_length > HIDE_COVER_FOR_LARGE_HIGHLIGHTS then show_cover = false end
    end

    if top_split_widget and show_cover then
        table.insert(content_children, top_split_widget)
        table.insert(content_children, VerticalSpan:new{ width = db_padding_internal })
        -- 模拟虚线撕口
        table.insert(content_children, TextWidget:new{ text = "- - - - - - - - - - - - - - - - - - - - - - - -", face = Font:getFace("cfont", db_font_size_small), fgcolor = db_font_color_lighter, align = "center" })
        table.insert(content_children, VerticalSpan:new{ width = db_padding })
        
-- 优先使用书籍标题，没有标题才使用文件名
local display_file_name
-- 先尝试获取书籍标题
if book_title and book_title ~= "" then
    display_file_name = book_title
else
    -- 没有标题时才使用文件名
    local file_path = ui.document and ui.document.file or ""
    local raw_file_name = file_path ~= "" and ffiUtil.basename(file_path) or ""
    local name_no_ext = raw_file_name:match("^(.+)%.[^%.]+$")
    if name_no_ext then raw_file_name = name_no_ext end
    if raw_file_name == "" then raw_file_name = "READING TICKET" end
    display_file_name = raw_file_name
end
-- 防止标题过长，24个权重字符(大约12个汉字)以上会用 ... 截断
display_file_name = getWeightedTruncatedString(display_file_name, 24)

        -- 插入精调版的嵌入文字的大胶片组件（宽度 = 原内容宽度 + 原来的两侧内边距，使其与卡片边缘齐平）
        table.insert(content_children, FilmStripTitle:new{ 
            width = full_ticket_width, 
            title_text = display_file_name, 
            title_font_size = math.floor(db_font_size_huge * 0.45) 
        })
        table.insert(content_children, VerticalSpan:new{ width = db_padding })
    end
    if content_mode ~= CONTENT_MODE_HIGHLIGHT_PROGRESS and chapterbox then
        table.insert(content_children, chapterbox)
        table.insert(content_children, VerticalSpan:new{ width = db_padding })
    end
    table.insert(content_children, bookbox)

    if content_mode ~= CONTENT_MODE_HIGHLIGHT_PROGRESS then
         table.insert(content_children, VerticalSpan:new{ width = db_padding })
        
        local badge_size = Screen:scaleBySize(35)
        local badge_btn = Button:new{
            text = "✿", text_face = Font:getFace("cfont", db_font_size_mid), fg_color = db_font_color, background = Blitbuffer.COLOR_WHITE,
            bordersize = 0, padding = 0, width = badge_size, height = badge_size,
            callback = function()
                if on_close_callback then
                    on_close_callback()
                end
                UIManager:setDirty(nil, "full")
                UIManager:scheduleIn(0.25, function()
                    if ui.onShowReadingInsightsPopup then
                        ui:onShowReadingInsightsPopup()
                    else
                        local InfoMessage = require("ui/widget/infomessage")
                        UIManager:show(InfoMessage:new{ text = _("请先安装阅读统计插件") })
                    end
                end)
            end,
        }

        local separator_row = HorizontalGroup:new{
            align = "center", 
            TextWidget:new{ text = "- - - - - - -", face = Font:getFace("cfont", db_font_size_small), fgcolor = db_font_color_lighter, padding = 0, align = "right" },
            HorizontalSpan:new{ width = db_padding_internal },
            badge_btn,
            HorizontalSpan:new{ width = db_padding_internal },
            TextWidget:new{ text = "- - - - - - -", face = Font:getFace("cfont", db_font_size_small), fgcolor = db_font_color_lighter, padding = 0, align = "left" },
        }
        
        table.insert(content_children, separator_row)
        table.insert(content_children, VerticalSpan:new{ width = db_padding_internal })

        if not Device.screen_saver_mode then
            table.insert(content_children, bottom_bar)
            table.insert(content_children, VerticalSpan:new{ width = db_padding_internal })
        end

        local stats_elements = {}
        if book_total_time_text then table.insert(stats_elements, TextWidget:new{ text = book_total_time_text, face = Font:getFace(db_font_face_italics, db_font_size_small), fgcolor = db_font_color, align = "center" }) end
        if book_total_time_text and book_today_time_text then table.insert(stats_elements, VerticalSpan:new{ width = db_padding_internal }) end
        if book_today_time_text then table.insert(stats_elements, TextWidget:new{ text = book_today_time_text, face = Font:getFace(db_font_face_italics, db_font_size_small), fgcolor = db_font_color, align = "center" }) end
        if #stats_elements > 0 then table.insert(content_children, VerticalGroup:new(stats_elements)) end
    end

    if content_mode == CONTENT_MODE_HIGHLIGHT_PROGRESS and highlight_widgets then
        table.insert(content_children, VerticalSpan:new{ width = db_padding_internal })
        util.arrayAppend(content_children, highlight_widgets)
    end
    if message_text then
        table.insert(content_children, VerticalSpan:new{ width = db_padding_internal })
        table.insert(content_children, VerticalGroup:new{
            TextBoxWidget:new{ face = Font:getFace(db_font_face, db_font_size_mid), text = message_text, width = widget_width, fgcolor = db_font_color, bold = true, alignment = "center" },
            VerticalSpan:new{ width = db_padding_internal },
        })
    end
    
    -- 让容器内的元素保持水平居中，以在取消卡片左右内边距后，依然在左右两侧留出完美的天然边距
    content_children.align = "center"

    -- 白色的卡片本体 (加了一圈1像素黑边框，加大了四个圆角)
    -- 注意：在这里取消了左右两侧的 Padding，允许我们内部的胶片能够拉满宽度触碰边缘
    local inner_ticket = FrameContainer:new{ 
        radius = 25, 
        bordersize = 1, 
        padding_top = db_padding, 
        padding_right = 0, 
        padding_bottom = db_padding, 
        padding_left = 0, 
        background = Blitbuffer.COLOR_WHITE, 
        VerticalGroup:new(content_children) 
    }
    
    local ticket_size = inner_ticket:getSize()
    local shadow_width_offset = Screen:scaleBySize(10) -- 控制阴影最终在右侧和下方露出的厚度
    local shadow_shrink_offset = Screen:scaleBySize(20) -- 控制阴影起始点的回缩量（模拟光照的倾斜感）
    
    local shadow_rect_w = math.max(1, math.floor(ticket_size.w + shadow_width_offset - shadow_shrink_offset))
    local shadow_rect_h = math.max(1, math.floor(ticket_size.h + shadow_width_offset - shadow_shrink_offset))

    -- 给 CenterContainer 塞入一个不可见(宽为0)的占位组件，防止 KOReader UI 崩溃
    local shadow_rect = FrameContainer:new{
        background = Blitbuffer.COLOR_GRAY_B,
        bordersize = 0,
        radius = 25,
        padding = 0,
        margin = 0,
        CenterContainer:new{ 
            dimen = Geom:new{ w = shadow_rect_w, h = shadow_rect_h },
            HorizontalSpan:new{ width = 0 } 
        }
    }
    
    local shadow_layer = FrameContainer:new{
        bordersize = 0, 
        padding_top = shadow_shrink_offset, 
        -- 阴影层的左侧需要加上与卡片左侧相同的空白，以保持阴影与卡片的相对位置不变
        padding_left = shadow_shrink_offset + shadow_width_offset, 
        padding_right = 0, 
        padding_bottom = 0,
        shadow_rect
    }
    
    local ticket_layer = FrameContainer:new{
        bordersize = 0, 
        padding_top = 0, 
        -- 给卡片左侧加上和右侧阴影相等的透明空白，用来平衡配重，使得整体视效严格居中
        padding_left = shadow_width_offset, 
        padding_right = shadow_width_offset, 
        padding_bottom = shadow_width_offset,
        inner_ticket
    }
    
    local overlap = OverlapGroup:new{
        -- 总宽度需要乘 2 倍的 offset，把左侧配重的宽度也算进去
        dimen = Geom:new{ w = math.floor(ticket_size.w + shadow_width_offset * 2), h = math.floor(ticket_size.h + shadow_width_offset) },
        shadow_layer,
        ticket_layer
    }

    return CenterContainer:new{ dimen = Screen:getSize(), overlap }
end

-- [UI 弹窗组件] 快捷呼出查看的“阅读小票”弹窗界面
local quicklookbox = InputContainer:extend{ modal = true, name = "quick_look_box", covers_fullscreen = true }  

function quicklookbox:init()
    local receipt_widget = buildReceipt(self.ui, self.state, function()
        UIManager:close(self)
    end)
    if receipt_widget then self[1] = receipt_widget
    else self[1] = CenterContainer:new{ dimen = Screen:getSize(), TextWidget:new{ text = _("无法生成阅读小票"), face = Font:getFace("cfont", 20) } } end
    if Device:hasKeys() then self.key_events.AnyKeyPressed = { { Device.input.group.Any } } end
    if Device:isTouchDevice() then
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } }
        self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } }
        self.ges_events.MultiSwipe = { GestureRange:new{ ges = "multiswipe", range = function() return self.dimen end } }
    end
end

function quicklookbox:onTap() self:onClose() end
function quicklookbox:onSwipe(arg, ges_ev) self:onClose() end
function quicklookbox:onClose() 
    UIManager:close(self)
    UIManager:setDirty(nil, "full") 
    return true 
end
quicklookbox.onAnyKeyPressed = quicklookbox.onClose
quicklookbox.onMultiSwipe = quicklookbox.onClose

-- 在 KOReader 的分发器中注册该动作，以便在菜单或手势中调用
Dispatcher:registerAction("quicklookbox_action", { category="none", event="QuickLook", title=_("阅读小票"), reader=true })

function ReaderUI:onQuickLook()
    local ui = self
    UIManager:nextTick(function()
        if not ui then return end
        local widget = quicklookbox:new{ ui = ui, document = ui.document, state = ui.view and ui.view.state }
        UIManager:show(widget)
    end)
end

local Screensaver = require("ui/screensaver")
local orig_screensaver_show = Screensaver.show

-- [核心挂钩] 拦截系统默认的屏保显示逻辑，将阅读小票作为屏保注入
Screensaver.show = function(self)
    if self.screensaver_type ~= "book_receipt" then return orig_screensaver_show(self) end
    local ui = self.ui or ReaderUI.instance
    if not hasActiveDocument(ui) then showFallbackScreensaver(self, orig_screensaver_show); return end
    if self.screensaver_widget then UIManager:close(self.screensaver_widget); self.screensaver_widget = nil end
    Device.screen_saver_mode = true
    local rotation_mode = Screen:getRotationMode()
    Device.orig_rotation_mode = rotation_mode
    if bit.band(rotation_mode, 1) == 1 then Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT) else Device.orig_rotation_mode = nil end
    local state = ui and ui.view and ui.view.state
    local receipt_widget = buildReceipt(ui, state, function()
        if self.close then self:close()
        else
            if self.screensaver_widget then UIManager:close(self.screensaver_widget); self.screensaver_widget = nil end
            if Device.screen_saver_mode then
                Device.screen_saver_mode = false
                if Device.orig_rotation_mode then Screen:setRotationMode(Device.orig_rotation_mode); Device.orig_rotation_mode = nil end
            end
        end
        UIManager:setDirty(nil, "full")
    end)
    if receipt_widget then
        local background_color, background_widget = getReceiptBackground(ui)
        local widget_to_show = receipt_widget
        if background_widget then widget_to_show = OverlapGroup:new{ dimen = Screen:getSize(), background_widget, receipt_widget } end
        self.screensaver_widget = ScreenSaverWidget:new{ widget = widget_to_show, background = background_color, covers_fullscreen = true }
        self.screensaver_widget.modal = true
        self.screensaver_widget.dithered = true
        UIManager:show(self.screensaver_widget, "full")
    else
        logger.warn("Book receipt: failed to build widget, falling back to default screensaver")
        showFallbackScreensaver(self, orig_screensaver_show)
    end
end

-- [菜单挂载] 通过拦截 dofile 解析菜单的机制，把我们的阅读小票选项塞进原生的“屏保”设置菜单中
local orig_dofile = dofile
_G.dofile = function(filepath)
    local result = orig_dofile(filepath)
    if filepath and filepath:match("screensaver_menu%.lua$") then
        if result and result[1] and result[1].sub_item_table then
            local wallpaper_submenu = result[1].sub_item_table
            local function genMenuItem(text, setting, value, enabled_func, separator)
                return {
                    text = text, enabled_func = enabled_func,
                    checked_func = function() return G_reader_settings:readSetting(setting) == value end,
                    callback = function() G_reader_settings:saveSetting(setting, value) end,
                    radio = true, separator = separator,
                }
            end
            local function isBookReceiptEnabled() return G_reader_settings:readSetting("screensaver_type") == "book_receipt" end
            table.insert(wallpaper_submenu, 6, genMenuItem(_("在屏保上显示阅读小票"), "screensaver_type", "book_receipt"))
            local background_menu = {
                text = _("背景"),
                sub_item_table = {
                    genMenuItem(_("白色填充"), BOOK_RECEIPT_BG_SETTING, "white"),
                    genMenuItem(_("透明"), BOOK_RECEIPT_BG_SETTING, "transparent"),
                    genMenuItem(_("黑色填充"), BOOK_RECEIPT_BG_SETTING, "black"),
                    genMenuItem(_("随机图片"), BOOK_RECEIPT_BG_SETTING, "random_image"),
                    genMenuItem(_("书籍封面"), BOOK_RECEIPT_BG_SETTING, "book_cover"),
                    {
                        text = _("背景图片布局"),
                        enabled_func = function() local value = G_reader_settings:readSetting(BOOK_RECEIPT_BG_SETTING); return value == "random_image" or value == "book_cover" end,
                        sub_item_table = {
                            genMenuItem(_("适应屏幕"), BOOK_RECEIPT_BG_IMAGE_MODE_SETTING, "fit"),
                            genMenuItem(_("拉伸至全屏"), BOOK_RECEIPT_BG_IMAGE_MODE_SETTING, "stretch"),
                            genMenuItem(_("居中不缩放"), BOOK_RECEIPT_BG_IMAGE_MODE_SETTING, "center"),
                        },
                    },
                },
            }
            local function isContentMode(value) local current = G_reader_settings:readSetting(BOOK_RECEIPT_CONTENT_MODE_SETTING) or CONTENT_MODE_BOOK_RECEIPT; return current == value end
            local content_menu = {
                text = _("内容"),
                sub_item_table = {
                    { text = _("阅读小票 (默认)"), checked_func = function() return isContentMode(CONTENT_MODE_BOOK_RECEIPT) end, callback = function() G_reader_settings:saveSetting(BOOK_RECEIPT_CONTENT_MODE_SETTING, CONTENT_MODE_BOOK_RECEIPT) end, radio = true },
                    { text = _("高亮笔记 + 进度"), checked_func = function() return isContentMode(CONTENT_MODE_HIGHLIGHT_PROGRESS) end, callback = function() G_reader_settings:saveSetting(BOOK_RECEIPT_CONTENT_MODE_SETTING, CONTENT_MODE_HIGHLIGHT_PROGRESS) end, radio = true },
                    { text = _("随机"), checked_func = function() return isContentMode(CONTENT_MODE_RANDOM) end, callback = function() G_reader_settings:saveSetting(BOOK_RECEIPT_CONTENT_MODE_SETTING, CONTENT_MODE_RANDOM) end, radio = true },
                    { text = _("封面缩放比例"), keep_menu_open = true, callback = function(touchmenu_instance)
                            local current_value = G_reader_settings:readSetting(BOOK_RECEIPT_COVER_SCALE_SETTING) or 1
                            local input_dialog; input_dialog = InputDialog:new{
                                title = _("封面缩放 (默认: 1.0)\n设为 0 以隐藏封面"), input = tostring(current_value), input_type = "number",
                                buttons = { { { text = _("取消"), id = "close", callback = function() UIManager:close(input_dialog) end }, { text = _("设置"), is_enter_default = true, callback = function() local input_text = input_dialog:getInputText(); input_text = input_text:gsub(",", "."); local new_value = tonumber(input_text); if new_value and new_value >= 0 then G_reader_settings:saveSetting(BOOK_RECEIPT_COVER_SCALE_SETTING, new_value); UIManager:close(input_dialog) end end } } },
                            }
                            UIManager:show(input_dialog); input_dialog:onShowKeyboard()
                        end,
                    },
                    { text = _("自定义休眠文字"), keep_menu_open = true, callback = function(touchmenu_instance)
                            local current_text = G_reader_settings:readSetting(BOOK_RECEIPT_SLEEP_TEXT_SETTING) or "休眠中"
                            local input_dialog; input_dialog = InputDialog:new{
                                title = _("设置休眠状态显示的文字"), input = current_text,
                                buttons = { { { text = _("取消"), id = "close", callback = function() UIManager:close(input_dialog) end }, { text = _("保存"), is_enter_default = true, callback = function() local new_text = input_dialog:getInputText(); if not new_text or new_text == "" then G_reader_settings:delSetting(BOOK_RECEIPT_SLEEP_TEXT_SETTING) else G_reader_settings:saveSetting(BOOK_RECEIPT_SLEEP_TEXT_SETTING, new_text) end; UIManager:close(input_dialog) end } } },
                            }
                            UIManager:show(input_dialog); input_dialog:onShowKeyboard()
                        end,
                    },
                },
            }
            table.insert(wallpaper_submenu, 7, { text = _("阅读小票设置"), enabled_func = isBookReceiptEnabled, sub_item_table = { background_menu, content_menu } })
        end
    end
    return result
end