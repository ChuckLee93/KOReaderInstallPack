-- module_new_books.lua — Simple UI
-- Module: New Books (recently added to library, sorted by file date).
-- Scans the home directory recursively for book files and displays
-- the most recently added ones with cover thumbnails.  Unread books
-- are labelled "New"; started books show their read percentage.

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local Screen          = Device.screen
local lfs             = require("libs/libkoreader-lfs")
local Size            = require("ui/size")
local _ = require("sui_i18n").translate

local logger = require("logger")
local _SH = nil
local function getSH()
    if not _SH then
        local ok, m = pcall(require, "desktop_modules/module_books_shared")
        if ok and m then _SH = m
        else logger.warn("simpleui: module_new_books: cannot load module_books_shared: " .. tostring(m)) end
    end
    return _SH
end

local Config       = require("sui_config")
local UI           = require("sui_core")
local SUISettings  = require("sui_store")
local SUIStyle     = require("sui_style")
local PAD          = UI.PAD
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

local _BASE_NB_LABEL_FS = SUIStyle.FS_DETAIL  -- 15: label text

-- ---------------------------------------------------------------------------
-- Module metadata
-- ---------------------------------------------------------------------------

local M = {}

M.id          = "new_books"
M.name        = _("New Books")
M.label       = _("New Books")
M.enabled_key = "new_books_enabled"
M.default_on  = false  -- opt-in; users enable via Arrange Modules
M.has_covers  = true   -- activates e-ink dithering and cover poll

local _cached_new_fps = nil
local _cached_new_fps_time = 0

function M.reset() 
    _SH = nil 
    _cached_new_fps = nil
    _cached_new_fps_time = 0
end

function M.invalidateCache()
    _cached_new_fps = nil
    _cached_new_fps_time = 0
end

-- ---------------------------------------------------------------------------
-- File scanning
-- ---------------------------------------------------------------------------

local _BOOK_EXTS = {
    epub = true, mobi = true, azw3 = true, azw = true, kfx = true,
    pdf = true, djvu = true, fb2 = true, cbz = true, cbr = true,
    doc = true, docx = true, rtf = true, txt = true,
}

--- Recursively scan `dir` for book files, collecting path + mtime.
local function collectBooks(dir, files, depth, state)
    if depth > 5 or state.count > 5000 then return end
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then return end
    for f in iter, dir_obj do
        state.count = state.count + 1
        if state.count > 5000 then break end
        if f ~= "." and f ~= ".." and not f:match("^%.") then
            local path = dir .. "/" .. f
            local attr = lfs.attributes(path)
            if attr then
                if attr.mode == "file" then
                    local ext = f:match("%.([^%.]+)$")
                    if ext and _BOOK_EXTS[ext:lower()] then
                        files[#files + 1] = { path = path, mtime = attr.modification }
                    end
                elseif attr.mode == "directory" then
                    collectBooks(path, files, depth + 1, state)
                end
            end
        end
    end
end

--- Return up to `limit` file paths from home_dir, newest first by mtime.
local function scanNewBooks(limit)
    limit = limit or 5
    local home = G_reader_settings:readSetting("home_dir")
    if not home or home == "" then
        home = Device.home_dir
    end
    if not home then return {} end

    local files = {}
    collectBooks(home, files, 1, { count = 0 })
    table.sort(files, function(a, b) return a.mtime > b.mtime end)

    local result = {}
    for i = 1, math.min(limit, #files) do
        result[i] = files[i].path
    end
    return result
end

-- ---------------------------------------------------------------------------
-- build / getHeight
-- ---------------------------------------------------------------------------

function M.build(w, ctx)
    Config.applyLabelToggle(M, _("New Books"))
    -- Cache the scan result for the lifetime of this render cycle.
    local new_fps = ctx._new_books_fps
    if not new_fps then
        local now = os.time()
        if _cached_new_fps and (now - _cached_new_fps_time < 300) then
            new_fps = _cached_new_fps
        else
            -- Fetch extra entries to compensate for books that will be excluded
            -- (current book, and books that are 100% read / marked complete).
            new_fps = scanNewBooks(15)
            _cached_new_fps = new_fps
            _cached_new_fps_time = now
        end
        -- Exclude the currently open book, matching the behaviour of the
        -- Recent Books module which also skips it.
        -- Also exclude books that are 100% read or marked complete,
        -- matching the filter applied by prefetchBooks() in module_books_shared.
        local DS_mod = nil
        pcall(function() DS_mod = require("docsettings") end)
        local filtered = {}
        for _, fp in ipairs(new_fps) do
            if fp ~= ctx.current_fp then
                local pct = 0
                local is_complete = false
                -- Try prefetched data first (no IO).
                local pre = ctx.prefetched and ctx.prefetched[fp]
                if pre and pre ~= false then
                    pct = pre.percent or 0
                    local summary = pre.summary
                    is_complete = type(summary) == "table" and summary.status == "complete"
                elseif DS_mod then
                    -- Fall back to reading DocSettings directly (same as prefetchBooks).
                    local ok, ds = pcall(DS_mod.open, DS_mod, fp)
                    if ok and ds then
                        pct = ds:readSetting("percent_finished") or 0
                        local summary = ds:readSetting("summary")
                        is_complete = type(summary) == "table" and summary.status == "complete"
                        pcall(function() ds:close() end)
                    end
                end
                if pct < 1.0 and not is_complete then
                    filtered[#filtered + 1] = fp
                end
            end
        end
        new_fps = filtered
        if #new_fps > 5 then
            local trimmed = {}
            for i = 1, 5 do trimmed[i] = new_fps[i] end
            new_fps = trimmed
        end
        ctx._new_books_fps = new_fps
    end
    if #new_fps == 0 then return nil end

    local SH          = getSH()
    local scale       = Config.getModuleScale("new_books", ctx.pfx)
    local thumb_scale = Config.getThumbScale("new_books", ctx.pfx)
    local lbl_scale   = Config.getItemLabelScale("new_books", ctx.pfx)
    local D           = SH.getDims(scale, thumb_scale)
    local label_fs    = math.max(8, math.floor(_BASE_NB_LABEL_FS * scale * lbl_scale))

    local ok_ss, SUIStyle  = pcall(require, "sui_style")
    local _theme_fg        = ok_ss and SUIStyle and SUIStyle.getThemeColor("fg")
    local _theme_secondary = ok_ss and SUIStyle and SUIStyle.getThemeColor("text_secondary")
    local CLR_TEXT_SUB_EFF = _theme_secondary or _theme_fg or CLR_TEXT_SUB

    local cols    = math.min(#new_fps, 5)
    local cw      = D.RECENT_W
    local ch      = D.RECENT_H
    -- Space-between across 5 fixed slots, same lateral padding as other modules.
    local inner_w = w - PAD * 2
    local gap     = math.floor((inner_w - 5 * cw) / 4)
    local face    = Font:getFace(SUIStyle.FACE_REGULAR, label_fs)

    local row = HorizontalGroup:new{ align = "top" }
    local cover_slots = {}
    for i = 1, cols do
        local fp    = new_fps[i]
        local bd    = SH.getBookData(fp, ctx.prefetched and ctx.prefetched[fp])
        local cover = SH.getBookCover(fp, cw, ch) or SH.coverPlaceholder(bd.title, bd.authors, cw, ch)

        -- "New" for unread books, read percentage otherwise.
        local label_text
        if (bd.percent or 0) < 0.01 then
            label_text = _("New")
        else
            label_text = string.format(_("%d%% Read"), math.floor((bd.percent or 0) * 100 + 0.5))
        end

        local cell = VerticalGroup:new{
            align = "center",
            cover,
            SH.vspan(D.RB_GAP1, ctx.vspan_pool),
            UI.progressBar(cw, bd.percent, D.RB_BAR_H),
            SH.vspan(D.RB_GAP2, ctx.vspan_pool),
            UI.makeColoredText{
                text      = label_text,
                face      = face,
                bold      = true,
                fgcolor   = CLR_TEXT_SUB_EFF,
                width     = cw,
                height    = D.RB_LABEL_H,
                alignment = "center",
            },
        }

        -- cover is at cell[1]
        cover_slots[#cover_slots+1] = { container = cell, idx = 1, fp = fp, w = cw, h = ch, align = nil, stretch = 0 }

        local tappable = InputContainer:new{
            dimen    = Geom:new{ w = cw, h = D.RECENT_CELL_H },
            [1]      = cell,
            _fp      = fp,
            _open_fn = ctx.open_fn,
        }
        tappable.ges_events = {
            TapBook = {
                GestureRange:new{
                    ges   = "tap",
                    range = function() return tappable.dimen end,
                },
            },
        }
        function tappable:onTapBook()
            if self._open_fn then self._open_fn(self._fp) end
            return true
        end

        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = tappable
    end

    local show_frame = SUISettings:isTrue(ctx.pfx .. "new_books_show_frame")
    local solid_bg   = SUISettings:isTrue(ctx.pfx .. "new_books_solid_bg")
    local has_box    = show_frame or solid_bg
    local border_sz  = show_frame and SUIStyle.BORDER_SZ or 0
    local radius     = has_box and math.floor(Screen:scaleBySize(12) * scale) or 0
    local border_color = Blitbuffer.gray(0.72)
    if ok_ss and SUIStyle then
        border_color = SUIStyle.getThemeColor("separator") or border_color
    end
    local bg_color = nil
    if solid_bg then
        bg_color = (ok_ss and SUIStyle and SUIStyle.getThemeColor("bg")) or Blitbuffer.COLOR_WHITE
    end

    local result = FrameContainer:new{
        bordersize = border_sz,
        radius     = radius,
        color      = border_color,
        background = bg_color,
        padding = PAD, padding_top = has_box and PAD or 0, padding_bottom = has_box and PAD or 0,
        row,
    }
    result._cover_slots = cover_slots
    return result
end

function M.updateCovers(widget, _ctx)
    if not widget or not widget._cover_slots then return true end
    local SH = getSH()
    if not SH then return true end
    local all_done = true
    for _, slot in ipairs(widget._cover_slots) do
        local new_cover = SH.getBookCover(slot.fp, slot.w, slot.h, slot.align, slot.stretch)
        if new_cover then
            slot.container[slot.idx] = new_cover
        elseif not Config.isCoverMissing(slot.fp) then
            all_done = false
        end
    end
    return all_done
end

function M.getHeight(_ctx)
    local SH = getSH()
    local D  = SH.getDims(Config.getModuleScale("new_books", _ctx and _ctx.pfx),
                           Config.getThumbScale("new_books", _ctx and _ctx.pfx))
    local h = D.RECENT_CELL_H
    if SUISettings:isTrue(_ctx and _ctx.pfx .. "new_books_show_frame") or SUISettings:isTrue(_ctx and _ctx.pfx .. "new_books_solid_bg") then
        h = h + PAD * 2
    end
    return require("sui_config").getScaledLabelH() + h
end

-- ---------------------------------------------------------------------------
-- Settings menu items (Scale, Text Size, Cover Size)
-- ---------------------------------------------------------------------------

local function _makeScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return require("sui_config").getModuleScalePct("new_books", pfx) end,
        set          = function(v) require("sui_config").setModuleScale(v, "new_books", pfx) end,
        refresh      = ctx_menu.refresh,
    })
end

local function _makeThumbScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func = function() return _lc("Cover size") end,
        separator = true,
        title     = _lc("Cover size"),
        info      = _lc("Scale for the cover thumbnails only.\nText and progress bar follow the module scale.\n100% is the default size."),
        get       = function() return require("sui_config").getThumbScalePct("new_books", pfx) end,
        set       = function(v) require("sui_config").setThumbScale(v, "new_books", pfx) end,
        refresh   = ctx_menu.refresh,
    })
end

function M.getMenuItems(ctx_menu)
    local _lc = ctx_menu._
    local label_item = Config.makeScaleItem({
        text_func = function() return _lc("Text Size") end,
        title     = _lc("Text Size"),
        info      = _lc("Scale for the label text.\n100% is the default size."),
        get       = function() return Config.getItemLabelScalePct("new_books", ctx_menu.pfx) end,
        set       = function(v) Config.setItemLabelScale(v, "new_books", ctx_menu.pfx) end,
        refresh   = ctx_menu.refresh,
    })
    local frame_item = {
        text           = _lc("Frame"),
        checked_func   = function() return SUISettings:isTrue(ctx_menu.pfx .. "new_books_show_frame") end,
        keep_menu_open = true,
        callback       = function()
            SUISettings:saveSetting(ctx_menu.pfx .. "new_books_show_frame", not SUISettings:isTrue(ctx_menu.pfx .. "new_books_show_frame"))
            ctx_menu.refresh()
        end,
    }
    local solid_bg_item = {
        text           = _lc("Solid Background"),
        checked_func   = function() return SUISettings:isTrue(ctx_menu.pfx .. "new_books_solid_bg") end,
        keep_menu_open = true,
        callback       = function()
            SUISettings:saveSetting(ctx_menu.pfx .. "new_books_solid_bg", not SUISettings:isTrue(ctx_menu.pfx .. "new_books_solid_bg"))
            ctx_menu.refresh()
        end,
    }
    return {
        _makeScaleItem(ctx_menu),
        label_item,
        _makeThumbScaleItem(ctx_menu),
        Config.makeLabelToggleItem("new_books", _("New Books"), ctx_menu.refresh, _lc),
        frame_item,
        solid_bg_item,
    }
end

return M
