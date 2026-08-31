--[[ 视觉大修：拉伸的圆角封面、文件夹封面、系列徽章、
     百分比徽章、页码徽章、书角图标、虚拟系列文件夹。
     合并：2--covers.lua、2-cover-overlays.lua、2-automatic-book-series.lua ]]
--

local ok, err = pcall(function()

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FileChooser = require("ui/widget/filechooser")
local IconWidget = require("ui/widget/iconwidget")
local userpatch = require("userpatch")
local util = require("util")

local _ = require("gettext")
local Screen = Device.screen
local logger = require("logger")

-- 持久化配置（懒加载，不在顶层调用 G_reader_settings）
local VO_KEY = "visual_overhaul_cover"


local vo_defaults = {
    fill              = false,
    ar_num            = 2,
    ar_den            = 3,
    stretch_limit     = 50,
    corner_radius     = 12,
    dogear_size       = 0,     -- 0=自动（封面短边/7），正数=固定px
    border_width      = 1.2,
    new_badge_days    = 9000,
    top_margin        = 25,
    -- 文件夹
    folder_font_size  = 25,
    file_count_size   = 15,
    -- 页码徽章
    pages_badge_size  = 10,
    pages_font_size   = 0.5,
    pages_border_w    = 2,
    pages_corner      = 10,
    pages_enabled     = true,
    -- 百分比徽章
    pct_text_size     = 0.30,
    pct_move_x        = 3,
    pct_move_y        = -1,
    pct_badge_size    = 55,    -- 百分比徽章大小（宽），高度按原始55:30比例自动换算
    -- 标题栏
    title_font_size   = 15,
    meta_font_size    = 12,
    title_max_lines   = 3,
    title_padding     = 3,
    card_gap          = 10,
    hide_title_meta   = false,  -- 新增：隐藏书籍标题和作者
    -- 其他
    new_badge_size    = 75,    -- NEW图标大小（宽），高度按原始比例自动换算
    new_badge_inset_x = -25,
    new_badge_inset_y = -8,
}
local vo_cfg = nil
local function vo_getCfg()
    if not vo_cfg then
        local saved = G_reader_settings:readSetting(VO_KEY) or {}
        vo_cfg = {}
        -- 合并默认值和保存的值
        for k, v in pairs(vo_defaults) do
            if saved[k] ~= nil then
                vo_cfg[k] = saved[k]
            else
                vo_cfg[k] = v
            end
        end
    end
    return vo_cfg
end


local function vo_saveCfg()
    if vo_cfg then
        G_reader_settings:saveSetting(VO_KEY, vo_cfg)
        logger.info("[视觉大修] 配置已保存")
    end
end

--========================== [[封面显示设置]] ======================================
local aspect_ratio = 3 / 4
local stretch_limit = 50
local fill = false
local file_count_size = 15
local folder_font_size = 25
local folder_border = 1.2
local folder_name = true
--======================================================================================

--========================== [[页码徽章设置]] ================================
local pages_cfg = {
    font_size = 0.5,
    text_color = Blitbuffer.COLOR_WHITE,
    border_thickness = 2,
    border_corner_radius = 10,
    border_color = Blitbuffer.COLOR_DARK_GRAY,
    background_color = Blitbuffer.COLOR_GRAY_3,
    move_from_border = 8,
}

--========================== [[百分比徽章设置]] ==============================
local percent_cfg = {
    text_size = 0.30,
    move_on_x = 3,
    move_on_y = -1,
    badge_w = 55,
    badge_h = 30,
    bump_up = 0,
}

--========================== [[标题栏设置]] ==================================
local title_cfg = {
    font_size = 15,
    meta_font_size = 12,
    max_lines = 3,
    padding = 3,
    text_color = Blitbuffer.COLOR_BLACK,
    meta_color = Blitbuffer.COLOR_DARK_GRAY,
    card_gap = 10,
}

--========================== [[焦点边框设置]] =================================
local focus_cfg = {
    border_width = 12,
    color = Blitbuffer.COLOR_BLACK,
}

--========================== [[布局调整设置]] ==================================
local layout_cfg = {
    top_margin = 25,
}
--=======================================================================================

local FolderCover = {
    name = ".cover",
    exts = { ".jpg", ".jpeg", ".png", ".webp", ".gif" },
}

local Folder = {
    face = {
        border_size = 1,
        alpha = 0.75,
        nb_items_font_size = file_count_size,
        nb_items_margin = Screen:scaleBySize(8),
        dir_max_font_size = folder_font_size,
    },
}

--========================== [[新书徽章设置]] ================================
local new_badge_cfg = {
    max_age_days = 9000,
    badge_w = 75,
    badge_h = 48,
    inset_x = -25,
    inset_y = -8,
}

-- 新增：隐藏标题标志
local hide_title_meta = false
-- 标题栏高度（upvalue，可通过 recompute_title_layout() 重算）
local title_line_h, title_strip_h, card_gap_px

local function vo_syncToLocals()
    -- 把持久化配置同步到各局部变量（在此处定义确保所有变量已存在）
    local c = vo_getCfg()
    percent_cfg.text_size          = c.pct_text_size
    percent_cfg.move_on_x          = c.pct_move_x
    percent_cfg.move_on_y          = c.pct_move_y
    percent_cfg.badge_w            = c.pct_badge_size
    percent_cfg.badge_h            = math.floor(c.pct_badge_size * 30 / 55)
    title_cfg.font_size            = c.title_font_size
    title_cfg.meta_font_size       = c.meta_font_size
    title_cfg.max_lines            = c.title_max_lines
    title_cfg.padding              = c.title_padding
    title_cfg.card_gap             = c.card_gap
    layout_cfg.top_margin          = c.top_margin
    new_badge_cfg.max_age_days     = c.new_badge_days
    new_badge_cfg.inset_x          = c.new_badge_inset_x
    new_badge_cfg.inset_y          = c.new_badge_inset_y
    Folder.face.nb_items_font_size = c.file_count_size
    -- 新增：同步隐藏标题标志
    hide_title_meta = c.hide_title_meta or false
end

local function recompute_title_layout()
    if hide_title_meta then
        title_line_h = 0
        title_strip_h = 0
        card_gap_px = 0
    else
        local Font = require("ui/font")
        local TextWidget = require("ui/widget/textwidget")
        local face = Font:getFace("cfont", title_cfg.font_size)
        local s = TextWidget:new{ text = "Ag", face = face }
        title_line_h = s:getSize().h
        s:free()
        title_strip_h = title_line_h * title_cfg.max_lines + Screen:scaleBySize(title_cfg.padding)
        card_gap_px = Screen:scaleBySize(title_cfg.card_gap)
    end
end

-- ============================================================================
-- 自定义图标目录设置
-- ============================================================================
do
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")

    local icons_dirs = userpatch.getUpValue(IconWidget.init, "ICONS_DIRS")
    local icons_path = userpatch.getUpValue(IconWidget.init, "ICONS_PATH")

    if icons_dirs then
        local data_dir = DataStorage:getFullDataDir()
        if not data_dir then
            data_dir = DataStorage:getDataDir()
        end
        local variant_subdir = Device:hasColorScreen() and "icons-colours" or "icons-bw"
        local variant_dir = data_dir .. "/icons/" .. variant_subdir
        local all_dir     = data_dir .. "/icons/all"

        local all_mode = lfs.attributes(all_dir, "mode")
        if all_mode == "directory" then
            table.insert(icons_dirs, 1, all_dir)
        end

        local variant_mode = lfs.attributes(variant_dir, "mode")
        if variant_mode == "directory" then
            table.insert(icons_dirs, 1, variant_dir)
        end

        -- 清空缓存的图标路径，使新目录生效
        if icons_path then
            for k in pairs(icons_path) do
                icons_path[k] = nil
            end
        end
    end
end

-- 圆角半径（像素），可调整大小
local function getCornerRadius()
    return Screen:scaleBySize((vo_cfg or vo_defaults).corner_radius)
end

local function clipRoundedRect(bb, x, y, w, h, r, color)
    if r <= 0 then return end
    if 2 * r > w then r = math.floor(w / 2) end
    if 2 * r > h then r = math.floor(h / 2) end
    local r2 = r * r
    local function clipCorner(cx, cy, start_x, end_x, start_y, end_y)
        for px = start_x, end_x do
            for py = start_y, end_y do
                local dx = px - cx
                local dy = py - cy
                if dx * dx + dy * dy > r2 then
                    bb:setPixelClamped(px, py, color)
                end
            end
        end
    end
    clipCorner(x + r - 1, y + r - 1, x, x + r - 1, y, y + r - 1)
    clipCorner(x + w - r, y + r - 1, x + w - r, x + w - 1, y, y + r - 1)
    clipCorner(x + r - 1, y + h - r, x, x + r - 1, y + h - r, y + h - 1)
    clipCorner(x + w - r, y + h - r, x + w - r, x + w - 1, y + h - r, y + h - 1)
end

local function strokeRoundedRect(bb, x, y, w, h, r, color, thickness)
    thickness = thickness or 1
    if r <= 0 then
        bb:paintBorder(x, y, w, h, thickness, color, 0, false)
        return
    end
    if 2 * r > w then r = math.floor(w / 2) end
    if 2 * r > h then r = math.floor(h / 2) end
    bb:paintRect(x + r, y, w - 2 * r, thickness, color)
    bb:paintRect(x + r, y + h - thickness, w - 2 * r, thickness, color)
    bb:paintRect(x, y + r, thickness, h - 2 * r, color)
    bb:paintRect(x + w - thickness, y + r, thickness, h - 2 * r, color)
    local r2 = r * r
    local function drawCorner(cx, cy, start_x, end_x, start_y, end_y)
        for px = start_x, end_x do
            for py = start_y, end_y do
                local dx = px - cx
                local dy = py - cy
                local dist2 = dx * dx + dy * dy
                if dist2 >= (r - thickness) ^ 2 and dist2 <= r2 then
                    bb:setPixelClamped(px, py, color)
                end
            end
        end
    end
    drawCorner(x + r - 1, y + r - 1, x, x + r - 1, y, y + r - 1)
    drawCorner(x + w - r, y + r - 1, x + w - r, x + w - 1, y, y + r - 1)
    drawCorner(x + r - 1, y + h - r, x, x + r - 1, y + h - r, y + h - 1)
    drawCorner(x + w - r, y + h - r, x + w - r, x + w - 1, y + h - r, y + h - 1)
end

local function findCover(dir_path)
    local path = dir_path .. "/" .. FolderCover.name
    for _, ext in ipairs(FolderCover.exts) do
        local fname = path .. ext
        if util.fileExists(fname) then return fname end
    end
end

local function capitalize(sentence)
    local words = {}
    for word in sentence:gmatch("%S+") do
        table.insert(words, word:sub(1, 1):upper() .. word:sub(2):lower())
    end
    return table.concat(words, " ")
end

local function getMenuItem(menu, ...)
    local function findItem(sub_items, texts)
        local find = {}
        for _, text in ipairs(type(texts) == "table" and texts or { texts }) do
            find[text] = true
        end
        for _, item in ipairs(sub_items) do
            local text = item.text or (item.text_func and item.text_func())
            if text and find[text] then return item end
        end
    end

    local sub_items, item
    for _, texts in ipairs { ... } do
        sub_items = (item or menu).sub_item_table
        if not sub_items then return end
        item = findItem(sub_items, texts)
        if not item then return end
    end
    return item
end

local function toKey(...)
    local keys = {}
    for _, key in pairs { ... } do
        if type(key) == "table" then
            table.insert(keys, "table")
            for k, v in pairs(key) do
                table.insert(keys, tostring(k))
                table.insert(keys, tostring(v))
            end
        else
            table.insert(keys, tostring(key))
        end
    end
    return table.concat(keys, "")
end

local function paintCorners(bb, x, y, w, h)
    local cover_border = Screen:scaleBySize((vo_cfg or vo_defaults).border_width)
    local cr = getCornerRadius()
    clipRoundedRect(bb, x, y, w, h, cr, Blitbuffer.COLOR_WHITE)
    strokeRoundedRect(bb, x, y, w, h, cr, Blitbuffer.COLOR_BLACK, cover_border)
end

local function paintTopCorners(bb, x, y, w, h)
    local bgcolor = Blitbuffer.COLOR_WHITE
    local r = getCornerRadius()
    if r <= 0 then return end
    if 2 * r > w then r = math.floor(w / 2) end
    if 2 * r > h then r = math.floor(h / 2) end
    local r2 = r * r
    local function clipCornerTop(cx, cy, start_x, end_x, start_y, end_y)
        for px = start_x, end_x do
            for py = start_y, end_y do
                local dx = px - cx
                local dy = py - cy
                if dx * dx + dy * dy > r2 then
                    bb:setPixelClamped(px, py, bgcolor)
                end
            end
        end
    end
    clipCornerTop(x + r - 1, y + r - 1, x, x + r - 1, y, y + r - 1)
    clipCornerTop(x + w - r, y + r - 1, x + w - r, x + w - 1, y, y + r - 1)
end

local function getAspectRatioAdjustedDimensions(width, height, border_size)
    local available_w = width - 2 * border_size
    local available_h = height - 2 * border_size
    local _cfg = vo_cfg or vo_defaults
    local ratio = _cfg.fill and (available_w / available_h) or (_cfg.ar_num / _cfg.ar_den)

    local frame_w, frame_h
    if available_w / available_h > ratio then
        frame_h = available_h
        frame_w = available_h * ratio
    else
        frame_w = available_w
        frame_h = available_w / ratio
    end

    return { w = frame_w + 2 * border_size, h = frame_h + 2 * border_size }
end

local orig_FileChooser_getListItem = FileChooser.getListItem
local CACHE_MAX = 2000
local cached_list = {}
local cached_list_count = 0
local function vo_clearCache()
    cached_list = {}
    cached_list_count = 0
end
function FileChooser:getListItem(dirpath, f, fullpath, attributes, collate)
    local key = toKey(dirpath, f, fullpath, attributes, collate, self.show_filter.status)
    if not cached_list[key] then
        if cached_list_count >= CACHE_MAX then
            cached_list = {}
            cached_list_count = 0
        end
        cached_list[key] = orig_FileChooser_getListItem(self, dirpath, f, fullpath, attributes, collate)
        cached_list_count = cached_list_count + 1
    end
    return cached_list[key]
end

-- 用于浏览器向上导航的图标常量
local Icon = {
    home = "home",
    up = BD.mirroredUILayout() and "back.top.rtl" or "back.top",
}

-- 用于在刷新时持久化虚拟文件夹状态

if not IconWidget.patched_new_status_icons then
    IconWidget.patched_new_status_icons = true

    local originalIconWidgetNew = IconWidget.new

    function IconWidget:new(o)
        local corner_icons = {
            "dogear.reading",
            "dogear.abandoned",
            "dogear.abandoned.rtl",
            "dogear.complete",
            "dogear.complete.rtl",
            "star.white",
        }

        for _, icon_name in ipairs(corner_icons) do
            if o.icon == icon_name then
                o.alpha = true
                break
            end
        end

        return originalIconWidgetNew(self, o)
    end
end

-- ============================================================================
-- 回调作用域
-- ============================================================================

local function patchVisualOverhaul(plugin)
    local AlphaContainer = require("ui/widget/container/alphacontainer")
    local BookInfoManager = require("bookinfomanager")
    local BottomContainer = require("ui/widget/container/bottomcontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local ImageWidget = require("ui/widget/imagewidget")
    local OverlapGroup = require("ui/widget/overlapgroup")
    local RightContainer = require("ui/widget/container/rightcontainer")
    local Size = require("ui/size")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local TextWidget = require("ui/widget/textwidget")
    local TitleBar = require("ui/widget/titlebar")
    local TopContainer = require("ui/widget/container/topcontainer")
    local lfs = require("libs/libkoreader-lfs")
    local VerticalSpan = require("ui/widget/verticalspan")
    local MosaicMenu = require("mosaicmenu")
    local MosaicMenuItem = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
    if not MosaicMenuItem or MosaicMenuItem.patched_visual_overhaul then return end
    MosaicMenuItem.patched_visual_overhaul = true

    -- 从持久化配置同步到各局部变量（此时所有变量已定义）
    vo_syncToLocals()
    recompute_title_layout()

    -- 拉伸图片控件 + debug.setupvalue
    local max_img_w, max_img_h

    if not MosaicMenuItem.patched_aspect_ratio then
        MosaicMenuItem.patched_aspect_ratio = true

        local local_ImageWidget
        local n = 1
        while true do
            local name, value = debug.getupvalue(MosaicMenuItem.update, n)
            if not name then break end
            if name == "ImageWidget" then
                local_ImageWidget = value
                break
            end
            n = n + 1
        end

        if not local_ImageWidget then
            logger.warn("在 MosaicMenuItem.update 闭包中找不到 ImageWidget")
        else
            local StretchingImageWidget = local_ImageWidget:extend({})
            StretchingImageWidget.init = function(self)
                if local_ImageWidget.init then local_ImageWidget.init(self) end
                if not max_img_w and not max_img_h then return end

                self.scale_factor = nil
                self.stretch_limit_percentage = (vo_cfg or vo_defaults).stretch_limit

                local _cfg = vo_cfg or vo_defaults
                local ratio = _cfg.fill and (max_img_w / max_img_h) or (_cfg.ar_num / _cfg.ar_den)
                if max_img_w / max_img_h > ratio then
                    self.height = max_img_h
                    self.width = max_img_h * ratio
                else
                    self.width = max_img_w
                    self.height = max_img_w / ratio
                end
            end

            debug.setupvalue(MosaicMenuItem.update, n, StretchingImageWidget)
        end
    end

    -- 设置定义
    local function BooleanSetting(text, name, default)
        local s = { text = text }
        s.get = function()
            local setting = BookInfoManager:getSetting(name)
            if default then return not setting end
            return setting
        end
        s.toggle = function() return BookInfoManager:toggleSetting(name) end
        return s
    end

    local settings = {
        name_centered = BooleanSetting(_("文件夹名称居中"), "folder_name_centered", true),
        show_folder_name = BooleanSetting(_("显示文件夹名称"), "folder_name_show", folder_name),
    }


    -- 在覆盖前捕获原始函数
    local orig_init = MosaicMenuItem.init
    local orig_paintTo = MosaicMenuItem.paintTo
    local orig_free = MosaicMenuItem.free
    local orig_update = MosaicMenuItem.update

    -- 进度条的书角标记大小（在包装paintTo前提取）
    local corner_mark_size = userpatch.getUpValue(orig_paintTo, "corner_mark_size")
        or Screen:scaleBySize(24)

    local function I(v)
        return math.floor(v + 0.5)
    end

    -- MosaicMenuItem.init -- 一次覆盖
    function MosaicMenuItem:init()
        -- [封面] 捕获 max_img_w/max_img_h
        if self.width and self.height then
            local border_size = Size.border.thin
            if hide_title_meta then
                max_img_w = self.width - 2 * border_size
                max_img_h = self.height - 2 * border_size
            else
                max_img_w = self.width - 2 * border_size
                max_img_h = self.height - 2 * border_size - title_strip_h - card_gap_px
            end
        end
        if orig_init then orig_init(self) end
    end

    -- MosaicMenuItem.update -- 一次覆盖
    function MosaicMenuItem:update(...)
        orig_update(self, ...)

        -- [页码] 从侧边数据捕获页数（使用BookList缓存，无新I/O）
        self.pages = nil
        if self.filepath and not self.is_directory and not self.file_deleted then
            local book_info = self.menu.getBookInfo(self.filepath)
            if book_info and book_info.pages then
                self.pages = book_info.pages
            end
        end

        -- [新书] 标记最近添加、未读的书籍
        self._is_new = false
        if self.filepath and not self.is_directory and not self.file_deleted
            and not self.percent_finished and not self.been_opened then
            local attr = lfs.attributes(self.filepath)
            if attr and attr.modification then
                local age_days = (os.time() - attr.modification) / 86400
                if age_days <= new_badge_cfg.max_age_days then
                    self._is_new = true
                end
            end
        end

        -- [标题] 缩小CenterContainer使封面位于顶部；存储标题/元信息供paintTo使用
        if self._has_cover_image and not self.is_directory and not self.file_deleted then
            local existing = self._underline_container[1]  -- CenterContainer{FrameContainer{image}}
            if existing and existing.dimen then
                local cover_area_h
                if hide_title_meta then
                    cover_area_h = self.height
                else
                    cover_area_h = self.height - title_strip_h - card_gap_px
                end
                existing.dimen.h = cover_area_h
                self._cover_frame = existing[1]
                if self._cover_frame then
                    self._cover_frame.bordersize = 0
                end
            end

            local bookinfo = BookInfoManager:getBookInfo(self.filepath, false)
            local has_meta = bookinfo and not bookinfo.ignore_meta
            local title_text = (has_meta and bookinfo.title) or self.text
            
            -- 只在未隐藏标题时创建标题控件
            if not hide_title_meta and title_text then
                -- 构建第二行：系列（#N）或作者
                local meta_line
                if has_meta then
                    if bookinfo.series then
                        meta_line = bookinfo.series
                        if bookinfo.series_index then
                            meta_line = meta_line .. " #" .. bookinfo.series_index
                        end
                    elseif bookinfo.authors then
                        meta_line = bookinfo.authors
                    end
                end

                local strip_content_h = title_strip_h - Screen:scaleBySize(title_cfg.padding)
                local title_max_h = meta_line and (title_line_h * 2) or strip_content_h
                local meta_max_h = meta_line and (strip_content_h - title_max_h) or 0

                if self._title_widget then
                    self._title_widget:free(true)
                end
                self._title_widget = TextBoxWidget:new{
                    text = BD.auto(title_text),
                    face = Font:getFace("cfont", title_cfg.font_size),
                    width = self.width - Screen:scaleBySize(8),
                    alignment = "center",
                    fgcolor = title_cfg.text_color,
                    height = title_max_h,
                    height_adjust = true,
                    height_overflow_show_ellipsis = true,
                }

                if self._meta_widget then
                    self._meta_widget:free(true)
                    self._meta_widget = nil
                end
                if meta_line and meta_max_h > 0 then
                    self._meta_widget = TextBoxWidget:new{
                        text = BD.auto(meta_line),
                        face = Font:getFace("cfont", title_cfg.meta_font_size),
                        width = self.width - Screen:scaleBySize(8),
                        alignment = "center",
                        fgcolor = title_cfg.meta_color,
                        height = meta_max_h,
                        height_adjust = true,
                        height_overflow_show_ellipsis = true,
                    }
                end
            else
                -- 清空标题控件
                if self._title_widget then
                    self._title_widget:free(true)
                    self._title_widget = nil
                end
                if self._meta_widget then
                    self._meta_widget:free(true)
                    self._meta_widget = nil
                end
            end
        end

        -- [封面] 文件夹封面逻辑
         if not self.menu.no_refresh_covers and self.do_cover_image then
            if not (self.entry.is_file or self.entry.file) and self.mandatory then
                local dir_path = self.entry and self.entry.path
                if dir_path then
                    self._foldercover_processed = true

                    local cover_file = findCover(dir_path)
                    if cover_file then
                        local success, w, h = pcall(function()
                            local tmp_img = ImageWidget:new { file = cover_file, scale_factor = 1 }
                            tmp_img:_render()
                            local orig_w = tmp_img:getOriginalWidth()
                            local orig_h = tmp_img:getOriginalHeight()
                            tmp_img:free()
                            return orig_w, orig_h
                        end)
                        if success then
                            self:_setFolderCover { file = cover_file, w = w, h = h }
                            return
                        end
                    end

                    self.menu._dummy = true
                    local entries = self.menu:genItemTableFromPath(dir_path)
                    self.menu._dummy = false
                    if entries then
                        for _, entry in ipairs(entries) do
                            if entry.is_file or entry.file then
                                local bookinfo = BookInfoManager:getBookInfo(entry.path, true)
                                if bookinfo and bookinfo.cover_bb and bookinfo.has_cover and bookinfo.cover_fetched
                                   and not bookinfo.ignore_cover and not BookInfoManager.isCachedCoverInvalid(bookinfo, self.menu.cover_specs) then
                                    self:_setFolderCover { data = bookinfo.cover_bb, w = bookinfo.cover_w, h = bookinfo.cover_h }
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end


        -- 缩小没有文件夹封面的目录项（go-up项、无封面文件夹）
        -- 使它们与使用cover_h的文件夹卡片垂直对齐
        -- 控件树：FrameContainer{ OverlapGroup{ CenterContainer, BottomContainer } }
        if self.is_directory and not self._folder_frame_dimen then
            local existing = self._underline_container and self._underline_container[1]
            if existing then
                local cover_h
                if hide_title_meta then
                    cover_h = self.height
                else
                    cover_h = self.height - title_strip_h - card_gap_px
                end
                local margin = existing.margin or 0
                local padding = existing.padding or 0
                local bs = existing.bordersize or 0
                local inner_h = cover_h - (margin + padding + bs) * 2

                existing.height = cover_h
                if existing.dimen then existing.dimen.h = cover_h end

                local overlap = existing[1]  -- OverlapGroup
                if overlap and overlap.dimen then
                    overlap.dimen.h = inner_h
                    for _, child in ipairs(overlap) do
                        if child.dimen then child.dimen.h = inner_h end
                    end
                end
            end
        end
    end

    function MosaicMenuItem:_setFolderCover(img)
    local border_size = 0
    local cover_h
    if hide_title_meta then
        cover_h = self.height
    else
        cover_h = self.height - title_strip_h - card_gap_px
    end
    
    local frame_dimen = getAspectRatioAdjustedDimensions(self.width, cover_h, border_size)
    local cover_width = frame_dimen.w
    local cover_height = frame_dimen.h
    local dir_path = self.entry and self.entry.path
    
    -- 创建画布
    local final_bb = Blitbuffer.new(cover_width, cover_height)
    final_bb:fill(Blitbuffer.COLOR_WHITE)
    
    -- 收集前3本有封面的书（使用第一份代码的遍历方式）
    local book_covers = {}
    local BookInfoManager = require("bookinfomanager")
    
    if dir_path then
        -- 使用 genItemTableFromPath，和第一份代码完全一样
        self.menu._dummy = true
        local entries = self.menu:genItemTableFromPath(dir_path)
        self.menu._dummy = false
        
        if entries then
            for _, entry in ipairs(entries) do
                if #book_covers >= 3 then break end
                
                if entry.is_file or entry.file then
                    local bookinfo = BookInfoManager:getBookInfo(entry.path, true)
                    if bookinfo and bookinfo.cover_bb and bookinfo.has_cover then
                        table.insert(book_covers, {
                            data = bookinfo.cover_bb,
                            w = bookinfo.cover_w,
                            h = bookinfo.cover_h
                        })
                    end
                end
            end
        end
    end
    
    -- 如果没有获取到书籍，使用传入的img作为备选
    if #book_covers == 0 and img and (img.file or img.data) then
        table.insert(book_covers, img)
    end
    
    -- 绘制层叠的书籍封面
    if #book_covers > 0 then
        local book_width = cover_width * 0.8
        local book_height = book_width * (cover_height / cover_width)
        local base_x = math.floor((cover_width - book_width) / 2)
        local base_y = math.floor((cover_height - book_height) / 2)
        
        -- 层叠偏移量（根据书籍数量动态调整）
        local offsets
        local book_count = #book_covers
        
        if book_count == 1 then
            offsets = { { x = 0, y = 6 } }
        elseif book_count == 2 then
            offsets = { { x = 8, y = 0 }, { x = -8, y = 12 } }
        else  -- 3本
            offsets = { { x = 12, y = 0 }, { x = 0, y = 6 }, { x = -12, y = 12 } }
        end
        
        -- 从最底层开始绘制（先绘制第3本，再第2本，最后第1本）
        for i = book_count, 1, -1 do
            local book = book_covers[i]
            local offset_idx = book_count - i + 1
            local offset = offsets[offset_idx] or { x = 0, y = 6 }
            
            local _sl = (vo_cfg or vo_defaults).stretch_limit
            local book_cover = book.file and
                ImageWidget:new { file = book.file, width = book_width, height = book_height, stretch_limit_percentage = _sl } or
                ImageWidget:new { image = book.data, width = book_width, height = book_height, stretch_limit_percentage = _sl }
            
            local book_x = base_x + offset.x
            local book_y = base_y + offset.y
            book_cover:paintTo(final_bb, book_x, book_y)
        end
    end
    
    -- 绘制文件夹图标（底部）
    local DataStorage = require("datastorage")
    local icons_dir = DataStorage:getDataDir() .. "/icons/"
    local folder_icon_width = cover_width
    local folder_icon_height = folder_icon_width * 0.65
    local folder_x = 0
    local folder_y = cover_height - folder_icon_height
    
    local folder_icon = ImageWidget:new({
        file = icons_dir .. "folder.png",
        width = folder_icon_width,
        height = folder_icon_height,
        alpha = true,
    })
    folder_icon:paintTo(final_bb, folder_x, folder_y)
    
    -- 创建最终封面
    local final_image = ImageWidget:new{
        image = final_bb,
        width = cover_width,
        height = cover_height,
    }
    
    local image_widget = FrameContainer:new {
        padding = 0, bordersize = border_size, final_image, overlap_align = "center",
    }
    
    local image_size = final_image:getSize()
    
    -- 计算文件数量
    local item_count = 0
    if self.mandatory then
        for n in self.mandatory:gmatch("(%d+)") do
            item_count = item_count + tonumber(n)
        end
    end
    
    -- 文件夹标题
    if self._folder_title_widget then
        self._folder_title_widget:free(true)
        self._folder_title_widget = nil
    end
    if self._folder_meta_widget then
        self._folder_meta_widget:free(true)
        self._folder_meta_widget = nil
    end
    
    if not hide_title_meta and settings.show_folder_name.get() then
        local text = self.text
        if text:match("/$") then text = text:sub(1, -2) end
        text = BD.directory(capitalize(text))
        
        local strip_content_h = title_strip_h - Screen:scaleBySize(title_cfg.padding)
        local title_max_h = (item_count > 0) and (title_line_h * 2) or strip_content_h
        local meta_max_h = (item_count > 0) and (strip_content_h - title_max_h) or 0
        
        self._folder_title_widget = TextBoxWidget:new{
            text = text,
            face = Font:getFace("cfont", title_cfg.font_size),
            width = self.width - Screen:scaleBySize(8),
            alignment = "center",
            bold = true,
            fgcolor = title_cfg.text_color,
            height = title_max_h,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
        }
        
        if item_count > 0 and meta_max_h > 0 then
            local meta_text = tostring(item_count) .. " " .. (item_count == 1 and _("本书") or _("本书"))
            self._folder_meta_widget = TextBoxWidget:new{
                text = meta_text,
                face = Font:getFace("cfont", title_cfg.meta_font_size),
                width = self.width - Screen:scaleBySize(8),
                alignment = "center",
                fgcolor = title_cfg.meta_color,
                height = meta_max_h,
                height_adjust = true,
                height_overflow_show_ellipsis = true,
            }
        end
    end
    
    -- 文件数量徽章
    local nbitems_widget
    if item_count > 0 then
        local nbitems = TextWidget:new {
            text = tostring(item_count),
            face = Font:getFace("cfont", Folder.face.nb_items_font_size),
            bold = true, padding = 0
        }
        
        local nb_size = math.max(nbitems:getSize().w, nbitems:getSize().h)
        nbitems_widget = BottomContainer:new {
            dimen = frame_dimen,
            RightContainer:new {
                dimen = {
                    w = frame_dimen.w - Folder.face.nb_items_margin,
                    h = nb_size + Folder.face.nb_items_margin * 2,
                },
                FrameContainer:new {
                    padding = 2, bordersize = Folder.face.border_size,
                    radius = math.ceil(nb_size), background = Blitbuffer.COLOR_GRAY_E,
                    CenterContainer:new { dimen = { w = nb_size, h = nb_size }, nbitems },
                },
            },
            overlap_align = "center",
        }
    else
        nbitems_widget = VerticalSpan:new { width = 0 }
    end
    
    self._folder_frame_dimen = frame_dimen
    self._folder_image_size = image_size
    
    local widget = CenterContainer:new {
        dimen = { w = self.width, h = cover_h },
        CenterContainer:new {
            dimen = { w = self.width, h = cover_h },
            OverlapGroup:new {
                dimen = frame_dimen,
                image_widget,
                nbitems_widget,
            },
        },
    }
    
    if self._underline_container[1] then
        self._underline_container[1]:free()
    end
    self._underline_container[1] = widget
end

    function MosaicMenuItem:_getTextBox(dimen)
        local text = self.text
        if text:match("/$") then text = text:sub(1, -2) end
        text = BD.directory(capitalize(text))

        local available_height = dimen.h
        local dir_font_size = Folder.face.dir_max_font_size
        local directory

        while true do
            if directory then directory:free(true) end
            directory = TextBoxWidget:new {
                text = text,
                face = Font:getFace("cfont", dir_font_size),
                width = dimen.w,
                alignment = "center",
                bold = true,
            }
            if directory:getSize().h <= available_height then break end
            dir_font_size = dir_font_size - 1
            if dir_font_size < 10 then
                directory:free()
                directory.height = available_height
                directory.height_adjust = true
                directory.height_overflow_show_ellipsis = true
                directory:init()
                break
            end
        end
        return directory
    end

    -- MosaicMenuItem.paintTo -- 一次覆盖
    function MosaicMenuItem:paintTo(bb, x, y)
        local top_margin_px = Screen:scaleBySize(layout_cfg.top_margin)
        orig_paintTo(self, bb, x, y + top_margin_px)

        -- [封面] 文件夹路径
        if self._folder_frame_dimen and self._folder_image_size then
            if not (self.entry.is_file or self.entry.file) then
                local frame_dimen = self._folder_frame_dimen
                local image_size = self._folder_image_size
                local cover_h
                if hide_title_meta then
                    cover_h = self.height
                else
                    cover_h = self.height - title_strip_h - card_gap_px
                end
                local fx = x + math.floor((self.width - frame_dimen.w) / 2)
                local fy = y + top_margin_px + math.floor((cover_h - frame_dimen.h) / 2)
                local image_x = fx + math.floor((frame_dimen.w - image_size.w) / 2)
                local image_y = fy + math.floor((frame_dimen.h - image_size.h) / 2)


                 -- 从封面下方到单元格底部填充白色
                local fill_top = fy + frame_dimen.h
                local fill_h = self.height - (fill_top - y)
                if fill_h > 0 then
                    bb:paintRect(image_x, fill_top, image_size.w, fill_h, Blitbuffer.COLOR_WHITE)
                end

                -- 文件夹圆角
                paintCorners(bb, image_x, image_y, image_size.w, image_size.h)
                self._cover_tap_zone = { x = image_x, y = image_y, w = image_size.w, h = image_size.h }

                -- 封面下方显示文件夹标题（仅在未隐藏时显示）
                if not hide_title_meta and self._folder_title_widget then
                    local strip_top = y + top_margin_px + self.height - title_strip_h
                    local tw = self._folder_title_widget:getSize().w
                    local title_x = x + math.floor((self.width - tw) / 2)
                    self._folder_title_widget:paintTo(bb, title_x, strip_top)

                    if self._folder_meta_widget then
                        local mw = self._folder_meta_widget:getSize().w
                        local meta_x = x + math.floor((self.width - mw) / 2)
                        local meta_y = strip_top + self._folder_title_widget:getSize().h
                        self._folder_meta_widget:paintTo(bb, meta_x, meta_y)
                    end
                end
                if self._focused then
                    local bw = Screen:scaleBySize((vo_cfg or vo_defaults).border_width)
                    bb:paintRect(x, y + self.height - bw, self.width, bw, focus_cfg.color)
                end
                return
            end
        end

        -- [封面] 书籍路径
        if self.is_directory or self.file_deleted then return end
        local target = self._cover_frame or (self[1] and self[1][1] and self[1][1][1])
        if not target or not target.dimen then return end

        local cover_area_h
        if hide_title_meta then
            cover_area_h = self.height
        else
            cover_area_h = self._title_widget and (self.height - title_strip_h - card_gap_px) or self.height
        end
        -- 用与 StretchingImageWidget 相同的宽高比逻辑重新计算封面尺寸，
        -- 避免 target.dimen 与实际渲染尺寸在不同格子比例下出现偏差（如 4x2+3:4）
        local frame_dimen = getAspectRatioAdjustedDimensions(self.width, cover_area_h, 0)
        local fw, fh = frame_dimen.w, frame_dimen.h
        local fx = x + math.floor((self.width - fw) / 2)
        local fy = y + top_margin_px + math.floor((cover_area_h - fh) / 2)

        -- [卡片] 从封面下方到单元格底部填充白色（间隙+文字区域）
        if not hide_title_meta and self._title_widget then
            local fill_top = y + top_margin_px + cover_area_h
            local fill_h = self.height - cover_area_h
            bb:paintRect(fx, fill_top, fw, fill_h, Blitbuffer.COLOR_WHITE)
        end

        -- 裁全部四角圆角
        paintCorners(bb, fx, fy, fw, fh)
        self._cover_tap_zone = { x = fx, y = fy, w = fw, h = fh }

        -- [覆盖层] 状态图标（书角位于右下角）
        local pf = self.percent_finished
        local effective_status = self.status
        if pf and pf >= 0.97 and effective_status ~= "complete" and effective_status ~= "abandoned" then
            effective_status = "complete"
        end

        local _show_dogear = effective_status == "complete"
            or effective_status == "abandoned"
            or (
                self.percent_finished
                and (
                    (self.do_hint_opened and self.been_opened)
                    or self.menu.name == "history"
                    or self.menu.name == "collections"
                )
            )
        if _show_dogear then
            local _dogear_cfg = vo_getCfg().dogear_size or 0
            local icon_corner_mark_size = (_dogear_cfg > 0)
                and Screen:scaleBySize(_dogear_cfg)
                or math.floor(math.min(fw, fh) / 7)

            local icon_ix, icon_iy

            local icon_inset_x = Screen:scaleBySize(0)
            if BD.mirroredUILayout() then
                icon_ix = math.floor((self.width - fw) / 2) + icon_inset_x
            else
                icon_ix = self.width - math.ceil((self.width - fw) / 2) - icon_corner_mark_size - icon_inset_x
            end
            local corner_inset = Screen:scaleBySize(0)
            icon_iy = cover_area_h - math.ceil((cover_area_h - fh) / 2) - icon_corner_mark_size - corner_inset

            local mark

            if effective_status == "abandoned" then
                mark = IconWidget:new({
                    icon = BD.mirroredUILayout() and "dogear.abandoned.rtl" or "dogear.abandoned",
                    width = icon_corner_mark_size,
                    height = icon_corner_mark_size,
                    alpha = true,
                })
            elseif effective_status == "complete" then
                mark = IconWidget:new({
                    icon = BD.mirroredUILayout() and "dogear.complete.rtl" or "dogear.complete",
                    width = icon_corner_mark_size,
                    height = icon_corner_mark_size,
                    alpha = true,
                })
            else
                mark = IconWidget:new({
                    icon = "dogear.reading",
                    rotation_angle = BD.mirroredUILayout() and 270 or 0,
                    width = icon_corner_mark_size,
                    height = icon_corner_mark_size,
                    alpha = true,
                })
            end

            if mark then
                mark:paintTo(bb, x + icon_ix, y + top_margin_px + icon_iy)
            end
        end

        -- [覆盖层] 页码徽章（左下角，未完成的书籍）
        local _show_pages = not self.is_directory and not self.file_deleted
            and self.status ~= "complete"
        if _show_pages then
            -- 来源1：侧边数据页数（适用于所有已打开的书；在update中设置）
            local page_count = self.pages
            -- 来源2：BookInfoManager数据库（适用于未读的PDF/DjVu，对EPUB返回nil）
            if not page_count and self.filepath then
                local bookinfo = BookInfoManager:getBookInfo(self.filepath, false)
                if bookinfo and bookinfo.pages then
                    page_count = bookinfo.pages
                end
            end

            local _pcfg = vo_getCfg()
            if page_count and _pcfg.pages_enabled then
                local pages_badge_size = Screen:scaleBySize(_pcfg.pages_badge_size or 10)
                local page_text = page_count .. " 页"
                local pfont_size = math.floor(pages_badge_size * _pcfg.pages_font_size)

                local pages_text = TextWidget:new({
                    text = page_text,
                    face = Font:getFace("cfont", pfont_size),
                    alignment = "left",
                    fgcolor = pages_cfg.text_color,
                    bold = true,
                    padding = 2,
                })

                local pages_badge = FrameContainer:new({
                    linesize = Screen:scaleBySize(2),
                    radius = Screen:scaleBySize(_pcfg.pages_corner),  -- 使用保存的圆角值
                    color = pages_cfg.border_color,
                    bordersize = _pcfg.pages_border_w,  -- 使用保存的边框值
                    background = pages_cfg.background_color,
                    padding = Screen:scaleBySize(2),
                    margin = 0,
                    pages_text,
                })

                local cover_left = x + math.floor((self.width - fw) / 2)
                local cover_bottom = y + top_margin_px + cover_area_h - math.floor((cover_area_h - fh) / 2)
                local badge_w, badge_h = pages_badge:getSize().w, pages_badge:getSize().h

                local pos_x_badge = cover_left + Screen:scaleBySize(4)
                local pos_y_badge = cover_bottom - badge_h - Screen:scaleBySize(8)

                pages_badge:paintTo(bb, pos_x_badge, pos_y_badge)
            end
        end

        -- [覆盖层] 百分比徽章（右上角，进行中的书籍）
        if not self.is_directory and self.status ~= "complete" and self.percent_finished then
            if
                (self.do_hint_opened and self.been_opened)
                or self.menu.name == "history"
                or self.menu.name == "collections"
            then
                local pct_corner_mark_size = Screen:scaleBySize(20)
                local percent_text = string.format("%d%%", math.floor(self.percent_finished * 100))
                local pct_font_size = math.floor(pct_corner_mark_size * percent_cfg.text_size)
                local percent_widget = TextWidget:new({
                    text = percent_text,
                    font_size = pct_font_size,
                    face = Font:getFace("cfont", pct_font_size),
                    alignment = "center",
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    bold = true,
                    max_width = pct_corner_mark_size,
                    truncate_with_ellipsis = true,
                })

                local PBADGE_W = Screen:scaleBySize(percent_cfg.badge_w)
                local PBADGE_H = math.floor(PBADGE_W * 30 / 55)
                local PINSET_X = Screen:scaleBySize(percent_cfg.move_on_x)
                local PINSET_Y = Screen:scaleBySize(percent_cfg.move_on_y)
                local TEXT_PAD = Screen:scaleBySize(6)

                local pfx = x + math.floor((self.width - fw) / 2)
                local pfy = y + top_margin_px + math.floor((cover_area_h - fh) / 2)
                local pfw = fw

                local percent_badge_icon = IconWidget:new({ icon = "percent.badge", alpha = true })
                percent_badge_icon.width = PBADGE_W
                percent_badge_icon.height = PBADGE_H

                local bx = pfx + pfw - PBADGE_W - PINSET_X
                local by = pfy + PINSET_Y
                bx, by = math.floor(bx), math.floor(by)

                percent_badge_icon:paintTo(bb, bx, by)
                percent_widget.alignment = "center"
                percent_widget.truncate_with_ellipsis = false
                percent_widget.max_width = PBADGE_W - 2 * TEXT_PAD

                local ts = percent_widget:getSize()
                local tx = bx + math.floor((PBADGE_W - ts.w) / 2)
                local ty = by + math.floor((PBADGE_H - ts.h) / 2)
                percent_widget:paintTo(bb, math.floor(tx), math.floor(ty))
            end
        end

        -- [覆盖层] 新书徽章（左上角，最近添加的未读书籍）
        if self._is_new then
            local NBADGE_W = Screen:scaleBySize((vo_cfg or vo_defaults).new_badge_size or 75)
            local NBADGE_H = math.floor(NBADGE_W * 48 / 75)  -- 保持原始 75:48 比例

            local new_badge_icon = IconWidget:new({ icon = "new", alpha = true })
            new_badge_icon.width = NBADGE_W
            new_badge_icon.height = NBADGE_H

            local cover_left = x + math.floor((self.width - fw) / 2)
            local cover_top = y + top_margin_px + math.floor((cover_area_h - fh) / 2)
            local ninset_x = Screen:scaleBySize(new_badge_cfg.inset_x)
            local ninset_y = Screen:scaleBySize(new_badge_cfg.inset_y)

            new_badge_icon:paintTo(bb, cover_left + ninset_x, cover_top + ninset_y)
        end

        -- [标题] 在封面下方绘制标题和元文本（仅在未隐藏时）
        if not hide_title_meta and self._title_widget and target and target.dimen then
            local strip_top = y + top_margin_px + self.height - title_strip_h
            local tw = self._title_widget:getSize().w
            local th = self._title_widget:getSize().h
            local title_x = x + math.floor((self.width - tw) / 2)
            self._title_widget:paintTo(bb, title_x, strip_top)

            if self._meta_widget then
                local mw = self._meta_widget:getSize().w
                local meta_x = x + math.floor((self.width - mw) / 2)
                local meta_y = strip_top + th
                self._meta_widget:paintTo(bb, meta_x, meta_y)
            end
        end

        if self._focused then
            local bw = Screen:scaleBySize((vo_cfg or vo_defaults).border_width)
            bb:paintRect(x, y + self.height - bw, self.width, bw, focus_cfg.color)
        end

    end

    -- 限制点击区域：只有封面图片范围内的点击才生效
    local orig_onTapSelect  = MosaicMenuItem.onTapSelect
    local orig_onHoldSelect = MosaicMenuItem.onHoldSelect

    local function _in_cover_zone(self, ges)
        local z = self._cover_tap_zone
        if not z then return true end  -- 无封面（返回上级等）不限制
        local px, py = ges.pos.x, ges.pos.y
        return px >= z.x and px <= z.x + z.w and py >= z.y and py <= z.y + z.h
    end

    function MosaicMenuItem:onTapSelect(arg, ges)
        if not _in_cover_zone(self, ges) then return true end
        if orig_onTapSelect then return orig_onTapSelect(self, arg, ges) end
    end

    function MosaicMenuItem:onHoldSelect(arg, ges)
        if not _in_cover_zone(self, ges) then return true end
        if orig_onHoldSelect then return orig_onHoldSelect(self, arg, ges) end
    end

    function MosaicMenuItem:onFocus()
        self._focused = true
        self._underline_container.color = Blitbuffer.COLOR_WHITE
        return true
    end

    function MosaicMenuItem:onUnfocus()
        self._focused = false
        self._underline_container.color = Blitbuffer.COLOR_WHITE
        return true
    end

    -- MosaicMenuItem.free
    if orig_free then
        function MosaicMenuItem:free()
            self._cover_frame = nil

            if self._title_widget then
                self._title_widget:free(true)
                self._title_widget = nil
            end

            if self._meta_widget then
                self._meta_widget:free(true)
                self._meta_widget = nil
            end

            if self._folder_title_widget then
                self._folder_title_widget:free(true)
                self._folder_title_widget = nil
            end
            if self._folder_meta_widget then
                self._folder_meta_widget:free(true)
                self._folder_meta_widget = nil
            end

            orig_free(self)
        end
    end

    -- plugin.addToMainMenu -- 一次覆盖
    local orig_addToMainMenu = plugin.addToMainMenu
    function plugin:addToMainMenu(menu_items)
        orig_addToMainMenu(self, menu_items)

        -- [封面] 将文件夹名称设置注入到马赛克子菜单中
        if menu_items.filebrowser_settings then
            local item = getMenuItem(menu_items.filebrowser_settings, _("马赛克和详细列表设置"))
            if item then
                item.sub_item_table[#item.sub_item_table].separator = true
                for i, setting in pairs(settings) do
                    if not getMenuItem(menu_items.filebrowser_settings, _("马赛克和详细列表设置"), setting.text) then
                        table.insert(item.sub_item_table, {
                            text = setting.text,
                            checked_func = function() return setting.get() end,
                            callback = function()
                                setting.toggle()
                                self.ui.file_chooser:updateItems()
                            end,
                        })
                    end
                end
            end

            -- 封面视觉设置
            local cover_visual_added = false
            for _, sub_item in ipairs(menu_items.filebrowser_settings.sub_item_table) do
                if sub_item._cover_visual_item then
                    cover_visual_added = true
                    break
                end
            end
            if not cover_visual_added then
                local ui = self.ui
                table.insert(menu_items.filebrowser_settings.sub_item_table, {
                    text = _("封面视觉设置"),
                    _cover_visual_item = true,
                    sub_item_table = {

                        -- ══ 封面显示设置 ══
                        {
                            text = "封面显示设置",
                            sub_item_table = {
                                {
                                    text_func = function()
                                        local cfg = vo_getCfg()
                                        local labels = { ["2/3"] = "2:3  标准书籍", ["3/4"] = "3:4  Kindle" }
                                        return "文件夹封面宽高比：" .. (labels[cfg.ar_num .. "/" .. cfg.ar_den] or (cfg.ar_num .. ":" .. cfg.ar_den))
                                    end,
                                    sub_item_table = {
                                        {
                                            text = "2:3  标准书籍",
                                            checked_func = function() local c = vo_getCfg(); return c.ar_num == 2 and c.ar_den == 3 end,
                                            callback = function()
                                                local cfg = vo_getCfg(); cfg.ar_num = 2; cfg.ar_den = 3; 
                                                vo_saveCfg()
                                                vo_clearCache(); if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                            end,
                                        },
                                        {
                                            text = "3:4  Kindle",
                                            checked_func = function() local c = vo_getCfg(); return c.ar_num == 3 and c.ar_den == 4 end,
                                            callback = function()
                                                local cfg = vo_getCfg(); cfg.ar_num = 3; cfg.ar_den = 4; 
                                                vo_saveCfg()
                                                vo_clearCache(); if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                            end,
                                        },
                                    },
                                },
                                {
                                    text_func = function() return "文件数量字体：" .. vo_getCfg().file_count_size end,
                                    keep_menu_open = true,
                                    callback = function(touchmenu_instance)
                                        local cfg = vo_getCfg()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local UIManager = require("ui/uimanager")
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = "文件数量徽章字体大小（8~30）",
                                            input = tostring(cfg.file_count_size),
                                            hint = "默认15",
                                            buttons = {{
                                                { text = "取消", id = "close", callback = function() UIManager:close(dlg) end },
                                                { text = "确定", is_enter_default = true, callback = function()
                                                    local v = tonumber(dlg:getInputText())
                                                    UIManager:close(dlg)
                                                    if v then
                                                        cfg.file_count_size = math.max(8, math.min(30, math.floor(v)))
                                                        Folder.face.nb_items_font_size = cfg.file_count_size
                                                        vo_saveCfg()
                                                        vo_clearCache()
                                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end
                                                end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                                {
                                    text_func = function() return "封面边框粗细：" .. vo_getCfg().border_width end,
                                    keep_menu_open = true,
                                    callback = function(touchmenu_instance)
                                        local cfg = vo_getCfg()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local UIManager = require("ui/uimanager")
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = "封面边框粗细（0~5）",
                                            input = tostring(cfg.border_width),
                                            hint = "0=无边框，1=默认，5=粗边框",
                                            buttons = {{
                                                { text = "取消", id = "close", callback = function() UIManager:close(dlg) end },
                                                { text = "确定", is_enter_default = true, callback = function()
                                                    local v = tonumber(dlg:getInputText())
                                                    UIManager:close(dlg)
                                                    if v then
                                                        cfg.border_width = math.max(0, math.min(5, v))
                                                        vo_saveCfg()
                                                        vo_clearCache()
                                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end
                                                end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                                {
                                    text_func = function() return "封面圆角：" .. vo_getCfg().corner_radius .. "px" end,
                                    keep_menu_open = true,
                                    callback = function(touchmenu_instance)
                                        local cfg = vo_getCfg()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local UIManager = require("ui/uimanager")
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = "封面圆角半径（0~30px）",
                                            input = tostring(cfg.corner_radius),
                                            hint = "0=直角，12=默认，30=大圆角",
                                            buttons = {{
                                                { text = "取消", id = "close", callback = function() UIManager:close(dlg) end },
                                                { text = "确定", is_enter_default = true, callback = function()
                                                    local v = tonumber(dlg:getInputText())
                                                    UIManager:close(dlg)
                                                    if v then
                                                        cfg.corner_radius = math.max(0, math.min(30, math.floor(v)))
                                                        vo_saveCfg()
                                                        vo_clearCache()
                                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end
                                                end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                                {
                                    text_func = function()
                                        local v = vo_getCfg().dogear_size or 0
                                        return "阅读状态图标大小：" .. (v == 0 and "自动" or (v .. "px"))
                                    end,
                                    keep_menu_open = true,
                                    callback = function(touchmenu_instance)
                                        local cfg = vo_getCfg()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local UIManager = require("ui/uimanager")
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = "阅读状态图标大小（0=自动，10~60px）",
                                            input = tostring(cfg.dogear_size or 0),
                                            hint = "0=跟随封面大小自动计算",
                                            buttons = {{
                                                { text = "取消", id = "close", callback = function() UIManager:close(dlg) end },
                                                { text = "确定", is_enter_default = true, callback = function()
                                                    local v = tonumber(dlg:getInputText())
                                                    UIManager:close(dlg)
                                                    if v then
                                                        cfg.dogear_size = math.max(0, math.min(60, math.floor(v)))
                                                        vo_saveCfg()
                                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end
                                                end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                                {
                                    text_func = function() return "书架与状态栏间距：" .. vo_getCfg().top_margin .. "px" end,
                                    keep_menu_open = true,
                                    callback = function(touchmenu_instance)
                                        local cfg = vo_getCfg()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local UIManager = require("ui/uimanager")
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = "书架与状态栏间距（0~100px）",
                                            input = tostring(cfg.top_margin),
                                            hint = "书架整体下移，避开状态栏，默认25px",
                                            buttons = {{
                                                { text = "取消", id = "close", callback = function() UIManager:close(dlg) end },
                                                { text = "确定", is_enter_default = true, callback = function()
                                                    local v = tonumber(dlg:getInputText())
                                                    UIManager:close(dlg)
                                                    if v then
                                                        cfg.top_margin = math.max(0, math.min(100, math.floor(v)))
                                                        layout_cfg.top_margin = cfg.top_margin
                                                        vo_saveCfg()
                                                        vo_clearCache()
                                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end
                                                end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                            },
                        },

                        -- ══ 标题栏设置 ══
                        {
                            text = "标题栏设置",
                            sub_item_table = {
                                {
                                    text = "隐藏书籍标题和作者",
                                    checked_func = function() return vo_getCfg().hide_title_meta end,
                                    callback = function()
                                        local cfg = vo_getCfg()
                                        cfg.hide_title_meta = not cfg.hide_title_meta
                                        hide_title_meta = cfg.hide_title_meta
                                        recompute_title_layout()
                                        vo_saveCfg()
                                        vo_clearCache()
                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                    end,
                                },
                                {
                                    text_func = function() return "标题字体大小：" .. vo_getCfg().title_font_size end,
                                    keep_menu_open = true,
                                    callback = function(touchmenu_instance)
                                        local cfg = vo_getCfg()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local UIManager = require("ui/uimanager")
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = "标题字体大小（10~30）",
                                            input = tostring(cfg.title_font_size),
                                            hint = "书籍标题和文件夹名称，默认15",
                                            buttons = {{
                                                { text = "取消", id = "close", callback = function() UIManager:close(dlg) end },
                                                { text = "确定", is_enter_default = true, callback = function()
                                                    local v = tonumber(dlg:getInputText())
                                                    UIManager:close(dlg)
                                                    if v then
                                                        cfg.title_font_size = math.max(10, math.min(30, math.floor(v)))
                                                        title_cfg.font_size = cfg.title_font_size
                                                        recompute_title_layout()
                                                        vo_saveCfg()
                                                        vo_clearCache()
                                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end
                                                end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                                {
                                    text_func = function() return "作者字体大小：" .. vo_getCfg().meta_font_size end,
                                    keep_menu_open = true,
                                    callback = function(touchmenu_instance)
                                        local cfg = vo_getCfg()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local UIManager = require("ui/uimanager")
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = "作者字体大小（8~28）",
                                            input = tostring(cfg.meta_font_size),
                                            hint = "作者/系列信息，默认12",
                                            buttons = {{
                                                { text = "取消", id = "close", callback = function() UIManager:close(dlg) end },
                                                { text = "确定", is_enter_default = true, callback = function()
                                                    local v = tonumber(dlg:getInputText())
                                                    UIManager:close(dlg)
                                                    if v then
                                                        cfg.meta_font_size = math.max(8, math.min(28, math.floor(v)))
                                                        title_cfg.meta_font_size = cfg.meta_font_size
                                                        vo_saveCfg()
                                                        vo_clearCache()
                                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end
                                                end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                                {
                                    text_func = function() return "标题行数：" .. vo_getCfg().title_max_lines  end,
                                    keep_menu_open = true,
                                    callback = function(touchmenu_instance)
                                        local cfg = vo_getCfg()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local UIManager = require("ui/uimanager")
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = "标题最大行数（1~5）",
                                            input = tostring(cfg.title_max_lines),
                                            hint = "默认3",
                                            buttons = {{
                                                { text = "取消", id = "close", callback = function() UIManager:close(dlg) end },
                                                { text = "确定", is_enter_default = true, callback = function()
                                                    local v = tonumber(dlg:getInputText())
                                                    UIManager:close(dlg)
                                                    if v then
                                                        cfg.title_max_lines = math.max(1, math.min(5, math.floor(v)))
                                                        title_cfg.max_lines = cfg.title_max_lines
                                                        recompute_title_layout()
                                                        vo_saveCfg()
                                                        vo_clearCache()
                                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end
                                                end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                                {
                                    text_func = function() return "标题内边距：" .. vo_getCfg().title_padding .. "px" end,
                                    keep_menu_open = true,
                                    callback = function(touchmenu_instance)
                                        local cfg = vo_getCfg()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local UIManager = require("ui/uimanager")
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = "标题区域内边距（0~20px）",
                                            input = tostring(cfg.title_padding),
                                            hint = "默认3px",
                                            buttons = {{
                                                { text = "取消", id = "close", callback = function() UIManager:close(dlg) end },
                                                { text = "确定", is_enter_default = true, callback = function()
                                                    local v = tonumber(dlg:getInputText())
                                                    UIManager:close(dlg)
                                                    if v then
                                                        cfg.title_padding = math.max(0, math.min(20, math.floor(v)))
                                                        title_cfg.padding = cfg.title_padding
                                                        recompute_title_layout()
                                                        vo_saveCfg()
                                                        vo_clearCache()
                                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end
                                                end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                                {
                                    text_func = function() return "封面与标题间距：" .. vo_getCfg().card_gap .. "px" end,
                                    keep_menu_open = true,
                                    callback = function(touchmenu_instance)
                                        local cfg = vo_getCfg()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local UIManager = require("ui/uimanager")
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = "封面与标题区域间距（0~30px）",
                                            input = tostring(cfg.card_gap),
                                            hint = "默认10px",
                                            buttons = {{
                                                { text = "取消", id = "close", callback = function() UIManager:close(dlg) end },
                                                { text = "确定", is_enter_default = true, callback = function()
                                                    local v = tonumber(dlg:getInputText())
                                                    UIManager:close(dlg)
                                                    if v then
                                                        cfg.card_gap = math.max(0, math.min(30, math.floor(v)))
                                                        title_cfg.card_gap = cfg.card_gap
                                                        recompute_title_layout()
                                                        vo_saveCfg()
                                                        vo_clearCache()
                                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end
                                                end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                            },
                        },

                        -- ══ 页码徽章设置 ══
                        {
                            text = "页码徽章设置",
                            sub_item_table = {
                                {
                                    text = "启用页码徽章",
                                    checked_func = function() return vo_getCfg().pages_enabled end,
                                    callback = function()
                                        local cfg = vo_getCfg()
                                        cfg.pages_enabled = not cfg.pages_enabled
                                        vo_saveCfg()
                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                    end,
                                },
                                {
                                    text_func = function() return "徽章大小：" .. vo_getCfg().pages_badge_size end,
                                    keep_menu_open = true,
                                    callback = function(touchmenu_instance)
                                        local cfg = vo_getCfg()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local UIManager = require("ui/uimanager")
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = "页码徽章大小（5~30）",
                                            input = tostring(cfg.pages_badge_size),
                                            hint = "控制徽章整体尺寸，默认10",
                                            buttons = {{
                                                { text = "取消", id = "close", callback = function() UIManager:close(dlg) end },
                                                { text = "确定", is_enter_default = true, callback = function()
                                                    local v = tonumber(dlg:getInputText())
                                                    UIManager:close(dlg)
                                                    if v then
                                                        cfg.pages_badge_size = math.max(5, math.min(30, math.floor(v)))
                                                        vo_saveCfg()
                                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end
                                                end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                                {
                                    text_func = function() return "文字大小：" .. vo_getCfg().pages_font_size end,
                                    keep_menu_open = true,
                                    callback = function(touchmenu_instance)
                                        local cfg = vo_getCfg()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local UIManager = require("ui/uimanager")
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = "页码文字大小比例（0.1~1.0）",
                                            input = tostring(cfg.pages_font_size),
                                            hint = "0.3=小，0.5=默认，0.8=大",
                                            buttons = {{
                                                { text = "取消", id = "close", callback = function() UIManager:close(dlg) end },
                                                { text = "确定", is_enter_default = true, callback = function()
                                                    local v = tonumber(dlg:getInputText())
                                                    UIManager:close(dlg)
                                                    if v then
                                                        cfg.pages_font_size = math.max(0.1, math.min(1.0, v))
                                                        vo_saveCfg()
                                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end
                                                end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                                {
                                    text_func = function() return "边框粗细：" .. vo_getCfg().pages_border_w end,
                                    keep_menu_open = true,
                                    callback = function(touchmenu_instance)
                                        local cfg = vo_getCfg()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local UIManager = require("ui/uimanager")
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = "页码徽章边框粗细（0~5）",
                                            input = tostring(cfg.pages_border_w),
                                            hint = "0=无边框，2=默认，5=粗边框",
                                            buttons = {{
                                                { text = "取消", id = "close", callback = function() UIManager:close(dlg) end },
                                                { text = "确定", is_enter_default = true, callback = function()
                                                    local v = tonumber(dlg:getInputText())
                                                    UIManager:close(dlg)
                                                    if v then
                                                        cfg.pages_border_w = math.max(0, math.min(5, math.floor(v)))
                                                        vo_saveCfg()
                                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end
                                                end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                                {
                                    text_func = function() return "边框圆角：" .. vo_getCfg().pages_corner end,
                                    keep_menu_open = true,
                                    callback = function(touchmenu_instance)
                                        local cfg = vo_getCfg()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local UIManager = require("ui/uimanager")
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = "页码徽章边框圆角（0~20）",
                                            input = tostring(cfg.pages_corner),
                                            hint = "0=直角，10=默认，20=大圆角",
                                            buttons = {{
                                                { text = "取消", id = "close", callback = function() UIManager:close(dlg) end },
                                                { text = "确定", is_enter_default = true, callback = function()
                                                    local v = tonumber(dlg:getInputText())
                                                    UIManager:close(dlg)
                                                    if v then
                                                        cfg.pages_corner = math.max(0, math.min(20, math.floor(v)))
                                                        vo_saveCfg()
                                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end
                                                end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                            },
                        },

                        -- ══ 百分比徽章设置 ══
                        {
                            text = "百分比徽章设置",
                            sub_item_table = {
                                {
                                    text_func = function() return "文字大小：" .. vo_getCfg().pct_text_size end,
                                    keep_menu_open = true,
                                    callback = function(touchmenu_instance)
                                        local cfg = vo_getCfg()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local UIManager = require("ui/uimanager")
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = "百分比文字大小比例（0.1~1.0）",
                                            input = tostring(cfg.pct_text_size),
                                            hint = "0.25=很小，0.30=默认，0.5=中等",
                                            buttons = {{
                                                { text = "取消", id = "close", callback = function() UIManager:close(dlg) end },
                                                { text = "确定", is_enter_default = true, callback = function()
                                                    local v = tonumber(dlg:getInputText())
                                                    UIManager:close(dlg)
                                                    if v then
                                                        cfg.pct_text_size = math.max(0.1, math.min(1.0, v))
                                                        percent_cfg.text_size = cfg.pct_text_size
                                                        vo_saveCfg()
                                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end
                                                end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                                {
                                    text_func = function() return "水平偏移：" .. vo_getCfg().pct_move_x end,
                                    keep_menu_open = true,
                                    callback = function(touchmenu_instance)
                                        local cfg = vo_getCfg()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local UIManager = require("ui/uimanager")
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = "百分比徽章水平偏移（-20~20）",
                                            input = tostring(cfg.pct_move_x),
                                            hint = "正数向右，负数向左，默认3",
                                            buttons = {{
                                                { text = "取消", id = "close", callback = function() UIManager:close(dlg) end },
                                                { text = "确定", is_enter_default = true, callback = function()
                                                    local v = tonumber(dlg:getInputText())
                                                    UIManager:close(dlg)
                                                    if v then
                                                        cfg.pct_move_x = math.max(-20, math.min(20, math.floor(v)))
                                                        percent_cfg.move_on_x = cfg.pct_move_x
                                                        vo_saveCfg()
                                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end
                                                end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                                {
                                    text_func = function() return "垂直偏移：" .. vo_getCfg().pct_move_y end,
                                    keep_menu_open = true,
                                    callback = function(touchmenu_instance)
                                        local cfg = vo_getCfg()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local UIManager = require("ui/uimanager")
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = "百分比徽章垂直偏移（-20~20）",
                                            input = tostring(cfg.pct_move_y),
                                            hint = "正数向下，负数向上，默认-1",
                                            buttons = {{
                                                { text = "取消", id = "close", callback = function() UIManager:close(dlg) end },
                                                { text = "确定", is_enter_default = true, callback = function()
                                                    local v = tonumber(dlg:getInputText())
                                                    UIManager:close(dlg)
                                                    if v then
                                                        cfg.pct_move_y = math.max(-20, math.min(20, math.floor(v)))
                                                        percent_cfg.move_on_y = cfg.pct_move_y
                                                        vo_saveCfg()
                                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end
                                                end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                                {
                                    text_func = function() return "徽章大小：" .. vo_getCfg().pct_badge_size .. "px" end,
                                    keep_menu_open = true,
                                    callback = function(touchmenu_instance)
                                        local cfg = vo_getCfg()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local UIManager = require("ui/uimanager")
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = "百分比徽章大小（20~100px）",
                                            input = tostring(cfg.pct_badge_size),
                                            hint = "默认55px，高度按比例自动换算",
                                            buttons = {{
                                                { text = "取消", id = "close", callback = function() UIManager:close(dlg) end },
                                                { text = "确定", is_enter_default = true, callback = function()
                                                    local v = tonumber(dlg:getInputText())
                                                    UIManager:close(dlg)
                                                    if v then
                                                        cfg.pct_badge_size = math.max(20, math.min(100, math.floor(v)))
                                                        percent_cfg.badge_w = cfg.pct_badge_size
                                                        percent_cfg.badge_h = math.floor(cfg.pct_badge_size * 30 / 55)
                                                        vo_saveCfg()
                                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end
                                                end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                            },
                        },

                        -- ══ 其他设置 ══
                        {
                            text = "其他设置",
                            sub_item_table = {
                                {
                                    text_func = function()
                                        local d = vo_getCfg().new_badge_days
                                        return "新书标记天数：" .. (d >= 9999 and "不限" or (d .. "天"))
                                    end,
                                    keep_menu_open = true,
                                    callback = function(touchmenu_instance)
                                        local cfg = vo_getCfg()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local UIManager = require("ui/uimanager")
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = "新书标记天数（0=关闭，9999=不限）",
                                            input = tostring(cfg.new_badge_days),
                                            hint = "文件在此天数内添加则显示NEW徽章",
                                            buttons = {{
                                                { text = "取消", id = "close", callback = function() UIManager:close(dlg) end },
                                                { text = "确定", is_enter_default = true, callback = function()
                                                    local v = tonumber(dlg:getInputText())
                                                    UIManager:close(dlg)
                                                    if v then
                                                        cfg.new_badge_days = math.max(0, math.floor(v))
                                                        new_badge_cfg.max_age_days = cfg.new_badge_days
                                                        vo_saveCfg()
                                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end
                                                end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                                {
                                    text_func = function() return "NEW图标大小：" .. vo_getCfg().new_badge_size .. "px" end,
                                    keep_menu_open = true,
                                    callback = function(touchmenu_instance)
                                        local cfg = vo_getCfg()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local UIManager = require("ui/uimanager")
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = "NEW图标大小（20~150px）",
                                            input = tostring(cfg.new_badge_size),
                                            hint = "默认75px，高度按比例自动换算",
                                            buttons = {{
                                                { text = "取消", id = "close", callback = function() UIManager:close(dlg) end },
                                                { text = "确定", is_enter_default = true, callback = function()
                                                    local v = tonumber(dlg:getInputText())
                                                    UIManager:close(dlg)
                                                    if v then
                                                        cfg.new_badge_size = math.max(20, math.min(150, math.floor(v)))
                                                        vo_saveCfg()
                                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end
                                                end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                                {
                                    text_func = function() return "NEW图标水平偏移：" .. vo_getCfg().new_badge_inset_x end,
                                    keep_menu_open = true,
                                    callback = function(touchmenu_instance)
                                        local cfg = vo_getCfg()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local UIManager = require("ui/uimanager")
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = "NEW图标水平偏移（-50~50）",
                                            input = tostring(cfg.new_badge_inset_x),
                                            hint = "负数向左超出封面，默认-25",
                                            buttons = {{
                                                { text = "取消", id = "close", callback = function() UIManager:close(dlg) end },
                                                { text = "确定", is_enter_default = true, callback = function()
                                                    local v = tonumber(dlg:getInputText())
                                                    UIManager:close(dlg)
                                                    if v then
                                                        cfg.new_badge_inset_x = math.max(-50, math.min(50, math.floor(v)))
                                                        new_badge_cfg.inset_x = cfg.new_badge_inset_x
                                                        vo_saveCfg()
                                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end
                                                end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                                {
                                    text_func = function() return "NEW图标垂直偏移：" .. vo_getCfg().new_badge_inset_y end,
                                    keep_menu_open = true,
                                    callback = function(touchmenu_instance)
                                        local cfg = vo_getCfg()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local UIManager = require("ui/uimanager")
                                        local dlg
                                        dlg = InputDialog:new{
                                            title = "NEW图标垂直偏移（-50~50）",
                                            input = tostring(cfg.new_badge_inset_y),
                                            hint = "负数向上超出封面，默认-8",
                                            buttons = {{
                                                { text = "取消", id = "close", callback = function() UIManager:close(dlg) end },
                                                { text = "确定", is_enter_default = true, callback = function()
                                                    local v = tonumber(dlg:getInputText())
                                                    UIManager:close(dlg)
                                                    if v then
                                                        cfg.new_badge_inset_y = math.max(-50, math.min(50, math.floor(v)))
                                                        new_badge_cfg.inset_y = cfg.new_badge_inset_y
                                                        vo_saveCfg()
                                                        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                                    end
                                                end },
                                            }},
                                        }
                                        UIManager:show(dlg)
                                        dlg:onShowKeyboard()
                                    end,
                                },
                            },
                        },

                    },
                })
            end
        end
    end
end

userpatch.registerPatchPluginFunc("coverbrowser", patchVisualOverhaul)

end)
if not ok then
    local logger = require("logger")
    logger.warn("补丁失败: 2--视觉大修:", tostring(err))
end