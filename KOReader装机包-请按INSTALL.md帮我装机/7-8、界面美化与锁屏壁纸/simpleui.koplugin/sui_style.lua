-- sui_style.lua — SimpleUI  ▸  Style  ▸  Icons  ▸  System Icons
--
-- Manages custom icon overrides for:
--   • KOReader FM + Reader touch-menu tabs (appbar.filebrowser / settings /
--     tools / search / menu / navigation / typeset), plus the SimpleUI-
--     injected Quick Settings tab (see sui_quicksettings_bar.lua)
--   • FM titlebar home button  (KO built-in "home" icon)
--   • SimpleUI menu button     (ko_menu  — the right titlebar button)
--   • SimpleUI search button   (ko_search — injected search button)
--   • SimpleUI injected menu   (sub_menu  — injected menu in widgets)
--
-- How it works
-- ────────────
-- Icons are stored as full SVG/PNG paths in SUISettings under the key
-- "simpleui_sysicon_<slot_id>".  nil means "use the default".
--
-- For tab-bar icons: we patch FileManagerMenu.onShowMenu and
-- ReaderMenu.onShowMenu so that every time either menu is (re)opened the
-- tab icons are replaced with the user's choices before the TouchMenu
-- widget is built. Matching happens on `tab.id` — the field KOReader's
-- MenuSorter stamps onto every tab entry (menu_items key) — NOT `tab.key`,
-- which native tabs never have. The patches are installed by
-- installTabIconPatch()/installReaderTabIconPatch() and removed on teardown.
--
-- For titlebar / search / back icons: sui_titlebar.apply() calls
-- SUIStyle.getIcon(slot_id) when it assigns image.file to each button, and
-- sui_titlebar.lua is modified to call the overrides.  This file therefore
-- also exposes helper methods
-- that sui_titlebar.lua invokes after building each button so the icons can be
-- swapped without duplicating the button-construction logic.
--
-- Public API
-- ──────────
--   SUIStyle.SLOTS            — ordered list of slot descriptors
--   SUIStyle.getIcon(id)      — stored path or nil
--   SUIStyle.setIcon(id, path)— save (nil = reset to default)
--   SUIStyle.resetAll()       — clear every override
--   SUIStyle.applyTabIcons(fm_or_ui_or_table) — push overrides into a live
--                                          FM/Reader tab_item_table
--   SUIStyle.installTabIconPatch(plugin)       — persistent FM-menu patch
--   SUIStyle.removeTabIconPatch()              — undo persistent patch
--   SUIStyle.installReaderTabIconPatch(plugin) — persistent Reader-menu patch
--   SUIStyle.removeReaderTabIconPatch()        — undo persistent patch
--   SUIStyle.refreshLiveTabBars()        — reapply + repaint any open
--                                          FM/Reader tab bar right now
--                                          (also syncs the shared Quick
--                                          Settings panel-tab icon)
--   SUIStyle.makeMenuItems(plugin)       — returns sub_item_table for the menu
--   SUIStyle.applyIconToBtn(id, btn)     — overwrite image.file on a live button
--                                          (called by sui_titlebar.lua)
--   SUIStyle.applyPaginationIcons(widget) — apply pg_icons overrides to a live
--                                          Menu/FileChooser widget's chevron btns
--   SUIStyle.applyCollBackIcon(widget)   — apply coll_back override to the
--                                          page_return_arrow of a collections widget
--   SUIStyle.performResetAllSystemIcons(plugin) — applies reset and triggers update routines
--   SUIStyle.sui_build_system_icons(plugin, ctx_menu, ctx) — native RowPage renderer
--
-- Theme Colors API
-- ──────────────
--   SUIStyle.getThemeColor(role)         — Blitbuffer color for "bg"|"fg", or nil
--   SUIStyle.setThemeColor(role, hex)    — save "#RRGGBB" or nil to reset
--   SUIStyle.resetTheme()               — clear all theme color overrides
--   SUIStyle.makeThemeMenuItems()        — returns sub_item_table for Style ▸ Theme Colors

local SUISettings = require("sui_store")
local logger      = require("logger")
local _           = require("sui_i18n").translate
local Blitbuffer  = require("ffi/blitbuffer")
local Device      = require("device")
local Screen      = Device.screen

-- ---------------------------------------------------------------------------
-- Slot catalogue
-- ---------------------------------------------------------------------------
-- Each slot describes one configurable icon position.
--   id          key suffix for SUISettings ("simpleui_sysicon_<id>")
--   label       display name shown in the picker menu
--   group       "sui_titlebar" | "bm_icons"
--   default_ko  KOReader built-in name (used only as documentation / preview)
-- ---------------------------------------------------------------------------

local M = {}

M.SLOTS = {
    -- ── SimpleUI titlebar buttons ────────────────────────────────────────
    {
        id        = "sui_menu",
        label     = function() return _("Menu Button") end,
        group     = "sui_titlebar",
        default_ko = "appbar.menu",
    },
    {
        id        = "sui_search",
        label     = function() return _("Search Button") end,
        group     = "sui_titlebar",
        default_ko = "appbar.search",
    },
    {
        id        = "sui_back",
        label     = function() return _("Back Button") end,
        group     = "sui_titlebar",
        default_ko = "chevron.left",   -- matches the ICON_UP used at runtime
    },
    -- ── Browse Meta titlebar icons ───────────────────────────────────────
    -- These override the four icons used by the Browse button in the FM
    -- titlebar (normal/author/series/tags mode).
    {
        id        = "sui_browse_normal",
        label     = function() return _("Browse Button (default)") end,
        group     = "sui_browse_icons",
        default_ko = "icons/default.svg",
    },
    {
        id        = "sui_browse_author",
        label     = function() return _("Browse Button (author)") end,
        group     = "sui_browse_icons",
        default_ko = "icons/author.svg",
    },
    {
        id        = "sui_browse_series",
        label     = function() return _("Browse Button (series)") end,
        group     = "sui_browse_icons",
        default_ko = "icons/series.svg",
    },
    {
        id        = "sui_browse_tags",
        label     = function() return _("Browse Button (tags)") end,
        group     = "sui_browse_icons",
        default_ko = "icons/tags.svg",
    },
    -- ── Native pagination bar chevrons ───────────────────────────────────
    -- Override the four chevron Buttons in KOReader's native pagination row
    -- (page_info_{left,right,first,last}_chev).  Applied after every
    -- Menu:init / FileChooser:init via M.applyPaginationIcons().
    {
        id        = "sui_pager_prev",
        label     = function() return _("Pagination: Previous Page") end,
        group     = "sui_pager_icons",
        default_ko = "chevron.left",
    },
    {
        id        = "sui_pager_next",
        label     = function() return _("Pagination: Next Page") end,
        group     = "sui_pager_icons",
        default_ko = "chevron.right",
    },
    {
        id        = "sui_pager_first",
        label     = function() return _("Pagination: First Page") end,
        group     = "sui_pager_icons",
        default_ko = "chevron.first",
    },
    {
        id        = "sui_pager_last",
        label     = function() return _("Pagination: Last Page") end,
        group     = "sui_pager_icons",
        default_ko = "chevron.last",
    },
    -- ── Navpager arrows (bottom bar) ─────────────────────────────────────
    {
        id        = "sui_navpager_prev",
        label     = function() return _("Navpager: Previous") end,
        group     = "sui_navpager_icons",
        default_ko = "chevron.left",
    },
    {
        id        = "sui_navpager_next",
        label     = function() return _("Navpager: Next") end,
        group     = "sui_navpager_icons",
        default_ko = "chevron.right",
    },
    -- ── Collections back button ──────────────────────────────────────────
    -- Overrides the page_return_arrow ("appbar.back") in Collections /
    -- coll_list widgets.  Applied after Menu:init via M.applyCollBackIcon().
    {
        id        = "sui_coll_back",
        label     = function() return _("Collections: Back Button") end,
        group     = "sui_coll_icons",
        default_ko = "appbar.back",
    },
    -- ── Quick Actions Defaults ───────────────────────────────────────────
    {
        id        = "sui_qa_folder",
        label     = function() return _("Default: Folder") end,
        group     = "sui_qa_defaults",
        default_ko = "icons/custom.svg",
    },
    {
        id        = "sui_qa_plugin",
        label     = function() return _("Default: Plugin") end,
        group     = "sui_qa_defaults",
        default_ko = "icons/plugin.svg",
    },
    {
        id        = "sui_qa_system",
        label     = function() return _("Default: System") end,
        group     = "sui_qa_defaults",
        default_ko = "appbar.settings",
    },
    {
        id        = "sui_qa_group",
        label     = function() return _("Default: Group") end,
        group     = "sui_qa_defaults",
        default_ko = "icons/group.svg",
    },
    -- ── Folder Covers ────────────────────────────────────────────────────
    {
        id        = "sui_fc_empty",
        label     = function() return _("Folder Covers: Empty Folder") end,
        group     = "sui_fc_icons",
        default_ko = "icons/custom.svg",
    },
    -- ── Touch menu tab bar ───────────────────────────────────────────────
    -- Overrides the icons shown on the native KOReader touch-menu tabs
    -- (FileManager + Reader), plus the SimpleUI-injected Quick Settings tab.
    -- `tab_id` matches the `.id` field KOReader's MenuSorter stamps onto
    -- each tab entry (menu_items key), NOT `tab.key` (that field doesn't
    -- exist on native tabs). Applied live by M.applyTabIcons().
    {
        id         = "sui_tab_main",
        label      = function() return _("Tab: Menu") end,
        group      = "sui_tabbar_icons",
        tab_id     = "main",
        default_ko = "appbar.menu",
    },
    {
        id         = "sui_tab_setting",
        label      = function() return _("Tab: Settings") end,
        group      = "sui_tabbar_icons",
        tab_id     = "setting",
        default_ko = "appbar.settings",
    },
    {
        id         = "sui_tab_tools",
        label      = function() return _("Tab: Tools") end,
        group      = "sui_tabbar_icons",
        tab_id     = "tools",
        default_ko = "appbar.tools",
    },
    {
        id         = "sui_tab_search",
        label      = function() return _("Tab: Search") end,
        group      = "sui_tabbar_icons",
        tab_id     = "search",
        default_ko = "appbar.search",
    },
    {
        id         = "sui_tab_fm_settings",
        label      = function() return _("Tab: File Browser Settings") end,
        group      = "sui_tabbar_icons",
        tab_id     = "filemanager_settings",
        default_ko = "appbar.filebrowser",
    },
    {
        id         = "sui_tab_navigation",
        label      = function() return _("Tab: Reader Navigation") end,
        group      = "sui_tabbar_icons",
        tab_id     = "navigation",
        default_ko = "appbar.navigation",
    },
    {
        id         = "sui_tab_typeset",
        label      = function() return _("Tab: Reader Typeset") end,
        group      = "sui_tabbar_icons",
        tab_id     = "typeset",
        default_ko = "appbar.typeset",
    },
    {
        id         = "sui_tab_filebrowser",
        label      = function() return _("Tab: Back to File Browser") end,
        group      = "sui_tabbar_icons",
        tab_id     = "filebrowser",
        default_ko = "appbar.filebrowser",
    },
    {
        id         = "sui_tab_qs_panel",
        label      = function() return _("Tab: SimpleUI Quick Settings") end,
        group      = "sui_tabbar_icons",
        tab_id     = "_sui_qs_panel",
        default_ko = "simpleui_settings",
    },
}

-- Quick lookup by id.
local _SLOT_BY_ID = {}
for _, s in ipairs(M.SLOTS) do _SLOT_BY_ID[s.id] = s end

-- ---------------------------------------------------------------------------
-- Settings helpers
-- ---------------------------------------------------------------------------

local function _key(id) return "simpleui_sysicon_" .. id end

--- Returns the stored icon path for `id`, or nil if using the default.
function M.getIcon(id)
    local v = SUISettings:get(_key(id))
    return (type(v) == "string" and v ~= "") and v or nil
end

--- Saves `path` as the icon for `id`.  Pass nil to reset to default.
function M.setIcon(id, path)
    if type(path) == "string" and path ~= "" then
        SUISettings:set(_key(id), path)
    else
        SUISettings:del(_key(id))
    end
end

-- ---------------------------------------------------------------------------
-- Icon path guard
-- ---------------------------------------------------------------------------
-- SUPPORTED_ICON_EXTS: formats that imagewidget.lua can actually load.
-- SVG requires librsvg (available on most KOReader builds).
-- PNG is always safe (liblodepng is always present).
-- JPG/JPEG are supported but not recommended for icons (no transparency).
local _SUPPORTED_ICON_EXTS = { png = true, svg = true, jpg = true, jpeg = true }

--- Validates `path` as a loadable icon file.
--- Returns `path` when valid, `fallback` otherwise.
--- Also clears the stored setting for `slot_id` (when given) so a bad path
--- is not retried on the next startup.
---
--- @param path      string|any   candidate icon path
--- @param fallback  string|nil   path to return when `path` is invalid (nil = no icon)
--- @param slot_id   string|nil   SUISettings key suffix; when given, a bad path
---                               is deleted from settings so it is not retried.
--- @return string|nil
function M.safeIconPath(path, fallback, slot_id)
    -- Type check — nil/non-string means "no override", not an error.
    if type(path) ~= "string" or path == "" then
        return fallback
    end

    local Config = require("sui_config")
    if Config.isNerdIcon(path) then
        return path
    end

    -- Extension check — fast, no I/O.
    local ext = path:match("%.([^.]+)$")
    if not ext or not _SUPPORTED_ICON_EXTS[ext:lower()] then
        logger.warn("simpleui/style: unsupported icon format '" .. tostring(ext)
                    .. "' in path: " .. path)
        if slot_id then M.setIcon(slot_id, nil) end
        return fallback
    end

    -- Existence check — requires lfs; skip gracefully when unavailable.
    -- Note: _reqLFS() is defined later in this file (Lua forward-reference
    -- limitation), so we inline the pcall here instead of calling it.
    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if lfs_ok and lfs then
        if lfs.attributes(path, "mode") ~= "file" then
            logger.warn("simpleui/style: icon file not found: " .. path)
            if slot_id then M.setIcon(slot_id, nil) end
            return fallback
        end
    else
        -- lfs unavailable: trust the extension check, warn once.
        logger.warn("simpleui/style: lfs unavailable, skipping existence check for: " .. path)
    end

    return path
end

--- Clears every system icon override.
function M.resetAll()
    for _, s in ipairs(M.SLOTS) do
        if s.group ~= "sui_qa_defaults" then
            SUISettings:del(_key(s.id))
        end
    end
end

--- Clears every system icon override and triggers all runtime updates.
function M.performResetAllSystemIcons(plugin)
    M.resetAll()
    
    local fm = package.loaded["apps/filemanager/filemanager"] and package.loaded["apps/filemanager/filemanager"].instance
    local ok_tb, TB = pcall(require, "sui_titlebar")
    if ok_tb and TB then
        local UIManager = require("ui/uimanager")
        pcall(TB.reapplyAll, fm, UIManager._window_stack)
        if TB.refreshBrowseIcons and fm then TB.refreshBrowseIcons(fm) end
    end
    
    local UIManager = require("ui/uimanager")
    if fm and fm.file_chooser then pcall(M.applyPaginationIcons, fm.file_chooser) end
    if UIManager then
        for _, entry in ipairs(UIManager._window_stack or {}) do
            local w = entry.widget
            if w and w.page_info_left_chev then pcall(M.applyPaginationIcons, w) end
            if w and (w.name == "collections" or w.name == "coll_list") then pcall(M.applyCollBackIcon, w) end
        end
    end
    
    local ok_qa, QA2 = pcall(require, "sui_quickactions")
    if ok_qa and QA2 and QA2.invalidateCustomQACache then QA2.invalidateCustomQACache() end
    local ok_fc, FC = pcall(require, "sui_foldercovers")
    if ok_fc and FC and FC.invalidateCache then FC.invalidateCache() end
    pcall(M.refreshLiveTabBars)
    
    if fm and fm.file_chooser then
        fm._navbar_suppress_path_change = true
        fm.file_chooser:refreshPath()
        fm._navbar_suppress_path_change = nil
    end
    if plugin then plugin:_rebuildAllNavbars() end
    local HS = package.loaded["sui_homescreen"]
    if HS and HS._instance then HS._instance:_refreshImmediate(false) end
end

-- ---------------------------------------------------------------------------
-- Apply helpers — called by sui_titlebar.lua
-- ---------------------------------------------------------------------------

--- Replaces image.file on a live button widget with the stored override for
--- `id`.  Does nothing when no override is set or the button has no image.
--- Returns true when an override was applied.
function M.applyIconToBtn(id, btn)
    local raw = M.getIcon(id)
    if not raw then return false end
    if not btn then return false end
    local path = M.safeIconPath(raw, nil, id)
    if not path then return false end
    
    local Config = require("sui_config")
    local is_nerd = Config.isNerdIcon(path)
    
    -- IconButton stores self.image at self.horizontal_group[2] — that slot is
    -- what HorizontalGroup actually paints. Setting btn[w_key] alone updates
    -- the table field but leaves the render-tree slot pointing at the old widget.
    -- This helper keeps both in sync, and also recalculates btn.dimen so that
    -- IconButton:update() / initGesListener() use the right size.
    local function _syncIconButtonSlot(w_key, new_w)
        btn[w_key] = new_w
        -- Sync the render-tree slot (horizontal_group[2]) so IconButton paints
        -- the new widget and not the old one.
        local hg = btn.horizontal_group
        if hg and hg[2] and type(hg[2]) == "table"
                and hg[2].paintTo and hg[2] ~= new_w then
            hg[2] = new_w
        end
        -- Button render tree: btn.label_container[1] = btn.label_widget
        -- Pagination chevrons are Button:new{icon=…}, NOT IconButton, so their
        -- render slot is label_container[1]. Patch it so the new widget is
        -- actually painted instead of the old one.
        local lc = btn.label_container
        if lc and lc[1] and type(lc[1]) == "table"
                and lc[1].paintTo and lc[1] ~= new_w then
            lc[1] = new_w
        end
        -- widgetInvert (called by IconButton:onTapIconButton for the flash_ui
        -- highlight) uses `widget.dimen.w/h` when no explicit w/h are passed.
        -- TextWidget only populates self.dimen lazily inside paintTo, so we
        -- must force-compute the size now and store a Geom on the widget.
        -- We use the button slot dimensions (w_width × w_height) rather than
        -- the text's natural size, because that is what widgetInvert needs to
        -- know in order to invert the correct screen area.
        local w_width  = btn.width  or new_w.width  or 0
        local w_height = btn.height or new_w.height or 0
        -- Ensure the internal TextWidget size is computed (populates _length/_height).
        pcall(new_w.getSize, new_w)
        -- Give the widget a concrete dimen so widgetInvert never sees nil.
        local Geom = require("ui/geometry")
        new_w.dimen = Geom:new{ x = 0, y = 0, w = w_width, h = w_height }
        -- Keep btn.dimen consistent (padding-aware).
        if btn.dimen then
            btn.dimen.w = w_width  + (btn.padding_left  or 0) + (btn.padding_right  or 0)
            btn.dimen.h = w_height + (btn.padding_top   or 0) + (btn.padding_bottom or 0)
        end
    end

    local function applyToWidget(w_key)
        local w = btn[w_key]
        if not w then return end

        if is_nerd then
            local nerd_char = Config.nerdIconChar(path)
            local Font = require("ui/font")
            local TextWidget = require("ui/widget/textwidget")

            pcall(w.free, w)

            local w_width  = btn.width  or w.width
            local w_height = btn.height or w.height
            local font_size = math.floor(math.min(w_width, w_height) * 0.65)

            local new_w = TextWidget:new{
                text    = nerd_char,
                face    = Font:getFace(M.FACE_ICONS, font_size),
                fgcolor = btn.icon_color or require("ffi/blitbuffer").COLOR_BLACK,
                padding = 0,
            }
            new_w.width  = w_width
            new_w.height = w_height
            new_w.is_sui_wrapper = true

            local orig_paintTo = new_w.paintTo
            new_w.paintTo = function(self_w, bb, x, y)
                local sz = self_w:getSize()
                local ox = x + math.floor((w_width - sz.w) / 2)
                local oy = y + math.floor((w_height - sz.h) / 2)
                orig_paintTo(self_w, bb, ox, oy)
            end

            -- Sync btn[w_key] AND horizontal_group[2] so the render tree is consistent.
            _syncIconButtonSlot(w_key, new_w)

            local bb_mod = package.loaded["sui_bottombar"]
            if bb_mod and bb_mod.patchDimmedIcon then
                bb_mod.patchDimmedIcon(btn)
            end
        else
            if w.is_sui_wrapper then
                pcall(w.free, w)
                local IconWidget = require("ui/widget/iconwidget")
                local new_w = IconWidget:new{
                    file   = path,
                    width  = btn.width,
                    height = btn.height,
                }
                -- Sync btn[w_key] AND horizontal_group[2].
                _syncIconButtonSlot(w_key, new_w)

                local bb_mod = package.loaded["sui_bottombar"]
                if bb_mod and bb_mod.patchDimmedIcon then
                    bb_mod.patchDimmedIcon(btn)
                end
            else
                -- Mutate the existing widget in-place: object identity at
                -- horizontal_group[2] is preserved, no slot sync needed.
                w.icon = nil
                w.file = path
                pcall(w.free, w)
                pcall(w.init, w)
            end
        end
    end

    if btn.image then
        applyToWidget("image")
        return true
    elseif btn.label_widget then
        applyToWidget("label_widget")
        return true
    end

    return false
end

-- ---------------------------------------------------------------------------
-- Native Button icon replacement helper
-- ---------------------------------------------------------------------------
-- KOReader has two icon-button widget types with different internal structures:
--
--   • IconButton  → self.image is an IconWidget created in IconButton:init().
--                   We can swap the icon by setting .icon=nil / .file=path on
--                   that ImageWidget and calling :free() + :init().
--
--   • Button{icon=…} → self.label_widget is an IconWidget created inside
--                   Button:init() when self.text is nil.  There is NO self.image
--                   on a plain Button.  The label_widget must be patched the
--                   same way (nil the .icon, set .file) so IconWidget:init()
--                   skips the symbol-lookup branch and loads the file directly.
--                   Setting btn.icon to a file path and re-calling btn:init()
--                   does NOT work: Button:init() creates a fresh IconWidget with
--                   icon=<path> and IconWidget:init() treats that value as a
--                   symbolic name, fails the directory scan, and falls back to
--                   ICON_NOT_FOUND (the warning triangle).
--
-- Strategy:
--   1. If btn.image exists  → it's an IconButton  → patch btn.image directly.
--   2. If btn.label_widget exists → it's a Button → patch btn.label_widget.
--   Both cases: set .icon = nil, .file = path, then :free() + :init().
-- ---------------------------------------------------------------------------

-- Restores a native button's image widget to a default icon/file, intelligently
-- tearing down any SUI wrapper (like Nerd Fonts) that might be in its place.
function M.restoreDefaultIcon(btn, default_icon, default_file)
    if not btn then return end

    -- Same render-tree sync as applyIconToBtn: when we replace btn[w_key] we
    -- must also update horizontal_group[2], the slot IconButton actually paints.
    local function _syncIconButtonSlot(w_key, new_w)
        btn[w_key] = new_w
        -- Sync the render-tree slot (horizontal_group[2]) so IconButton paints
        -- the new widget and not the old one.
        local hg = btn.horizontal_group
        if hg and hg[2] and type(hg[2]) == "table"
                and hg[2].paintTo and hg[2] ~= new_w then
            hg[2] = new_w
        end
        -- widgetInvert (called by IconButton:onTapIconButton for the flash_ui
        -- highlight) uses `widget.dimen.w/h` when no explicit w/h are passed.
        -- TextWidget only populates self.dimen lazily inside paintTo, so we
        -- must force-compute the size now and store a Geom on the widget.
        -- We use the button slot dimensions (w_width × w_height) rather than
        -- the text's natural size, because that is what widgetInvert needs to
        -- know in order to invert the correct screen area.
        local w_width  = btn.width  or new_w.width  or 0
        local w_height = btn.height or new_w.height or 0
        -- Ensure the internal TextWidget size is computed (populates _length/_height).
        pcall(new_w.getSize, new_w)
        -- Give the widget a concrete dimen so widgetInvert never sees nil.
        local Geom = require("ui/geometry")
        new_w.dimen = Geom:new{ x = 0, y = 0, w = w_width, h = w_height }
        -- Keep btn.dimen consistent (padding-aware).
        if btn.dimen then
            btn.dimen.w = w_width  + (btn.padding_left  or 0) + (btn.padding_right  or 0)
            btn.dimen.h = w_height + (btn.padding_top   or 0) + (btn.padding_bottom or 0)
        end
    end

    local function applyToWidget(w_key)
        local w = btn[w_key]
        if not w then return end
        if w.is_sui_wrapper then
            pcall(w.free, w)
            local IconWidget = require("ui/widget/iconwidget")
            local new_w = IconWidget:new{
                icon   = default_icon,
                file   = default_file,
                width  = btn.width,
                height = btn.height,
            }
            _syncIconButtonSlot(w_key, new_w)
        else
            -- Mutate in-place: object identity at horizontal_group[2] is
            -- preserved so no slot sync is needed.
            w.icon = default_icon
            if default_icon and default_icon ~= "" then
                w.file = nil
            else
                w.file = default_file
            end
            pcall(w.free, w)
            pcall(w.init, w)
        end
    end

    if btn.image then applyToWidget("image")
    elseif btn.label_widget then applyToWidget("label_widget")
    end
end

-- Alias for internal compatibility
local function _applyNativeBtn(id, btn)
    return M.applyIconToBtn(id, btn)
end

-- ---------------------------------------------------------------------------
-- Pagination chevron icon application  (pg_icons group)
-- ---------------------------------------------------------------------------

-- Slot-id → button field name on the widget.
local _PG_CHEV_FIELDS = {
    sui_pager_prev  = "page_info_left_chev",
    sui_pager_next  = "page_info_right_chev",
    sui_pager_first = "page_info_first_chev",
    sui_pager_last  = "page_info_last_chev",
}

--- Applies stored pg_icons overrides to the pagination buttons of `widget`.
--- `widget` may be a FileChooser or any Menu instance (Collections, History…).
--- Returns true when at least one override was applied.
function M.applyPaginationIcons(widget)
    if not widget then return false end
    local applied = false
    for id, field in pairs(_PG_CHEV_FIELDS) do
        local btn = widget[field]
        if btn then
            applied = _applyNativeBtn(id, btn) or applied
        end
    end
    return applied
end

-- ---------------------------------------------------------------------------
-- Collections back-button icon application  (coll_icons group)
-- ---------------------------------------------------------------------------

--- Applies the stored coll_back override to the page_return_arrow of `widget`.
--- `widget` should be a collections or coll_list Menu instance.
--- Returns true when an override was applied.
function M.applyCollBackIcon(widget)
    if not widget then return false end
    local btn = widget.page_return_arrow
    if not btn then return false end
    return _applyNativeBtn("sui_coll_back", btn)
end

-- ---------------------------------------------------------------------------
-- FM tab icon application
-- ---------------------------------------------------------------------------

-- Build a tab_id → slot_id map for fast lookup.
-- NOTE: KOReader's MenuSorter stamps `.id = order_id` onto every top-level
-- tab entry (see ui/menusorter.lua:sort()); native tabs never have a
-- `.key` field. The SimpleUI-injected Quick Settings tab is given an
-- explicit `.id = "_sui_qs_panel"` in sui_quicksettings_bar.lua so it can
-- be matched the same way.
local _TAB_ID_TO_SLOT = {}
for _, s in ipairs(M.SLOTS) do
    if s.tab_id then _TAB_ID_TO_SLOT[s.tab_id] = s.id end
end

-- ---------------------------------------------------------------------------
-- Tab-icon name registration
-- ---------------------------------------------------------------------------
-- CRITICAL CONSTRAINT: unlike every other icon slot in this file (which
-- SimpleUI renders itself via ImageWidget/IconWidget with `.file = path`,
-- so any absolute/relative path works), tab-bar icons are rendered by
-- KOReader's OWN native widgets: TouchMenu → TouchMenuBar → IconButton →
-- IconWidget. IconButton unconditionally does
-- `IconWidget:new{ icon = self.icon }`, and IconWidget:init() ALWAYS treats
-- a non-file, non-image `.icon` as a bare NAME to search for under
-- ICONS_DIRS + {".svg",".png"} (see ui/widget/iconwidget.lua) — it never
-- accepts a literal file path. Assigning a full custom path straight into
-- `tab.icon` (as an earlier version of this code did) therefore always
-- resolves to icon-not-found.
--
-- The fix — and the same trick sui_quicksettings_bar.lua already uses to
-- make "simpleui_settings" resolve — is to REGISTER the custom icon under
-- a stable bare name:
--   1. Copy the file to DataStorage/icons/<name>.<ext> (disk-based lookup;
--      ICONS_DIRS always searches the user icons dir first, so this alone
--      is enough, and survives restarts).
--   2. Also poke IconWidget's runtime ICONS_PATH cache so the change is
--      visible immediately, without waiting for a fresh process.
-- Only .svg/.png are supported here because those are the only two
-- extensions IconWidget's by-name search ever tries.
local _TAB_ICON_NAME_CACHE = {} -- slot_id -> { src = last-registered source path, name = registered name }

--- Registers `path` under a stable per-slot icon name so KOReader's native
--- tab-bar widgets (which only resolve `.icon` by name) can find it.
--- Returns the registered name, or nil if `path` can't be registered
--- (unsupported extension, nerd-font glyph ref, or I/O failure) — callers
--- should fall back to the slot's native default in that case.
function M.registerTabIconName(slot_id, path)
    if type(path) ~= "string" or path == "" then return nil end

    local ok_cfg, Config = pcall(require, "sui_config")
    if ok_cfg and Config.isNerdIcon and Config.isNerdIcon(path) then
        -- Nerd-font glyph references aren't files; nothing to register.
        return nil
    end

    local ext = path:match("%.([^.]+)$")
    ext = ext and ext:lower()
    if ext ~= "svg" and ext ~= "png" then
        -- IconWidget's by-name search only ever tries .svg/.png — jpg/jpeg
        -- (allowed for every other icon slot) can never be found this way.
        logger.warn("simpleui/style: tab icons must be .svg or .png (got: "
                    .. tostring(ext) .. ") — falling back to default for " .. slot_id)
        return nil
    end

    local name = "simpleui_" .. slot_id
    local cached = _TAB_ICON_NAME_CACHE[slot_id]
    if cached and cached.src == path and cached.name == name then
        return name -- already registered for this exact source
    end

    local ok_ds, DataStorage = pcall(require, "datastorage")
    local ok_lfs, lfs        = pcall(require, "libs/libkoreader-lfs")
    local ok_fu, ffiutil     = pcall(require, "ffi/util")
    if not (ok_ds and ok_lfs and ok_fu) then return nil end

    local user_dir = DataStorage:getDataDir() .. "/icons"
    if lfs.attributes(user_dir, "mode") ~= "directory" then
        pcall(lfs.mkdir, user_dir)
    end
    local dst = user_dir .. "/" .. name .. "." .. ext

    -- Always (re)copy — the user may have picked a different source file
    -- for the same slot since the last time this ran.
    local copy_ok = pcall(ffiutil.copyFile, path, dst)
    if not copy_ok or lfs.attributes(dst, "mode") ~= "file" then
        logger.warn("simpleui/style: failed to register tab icon for " .. slot_id)
        return nil
    end

    -- Keep IconWidget's runtime name-cache in sync so the change applies
    -- immediately, without a restart (same approach as
    -- sui_quicksettings_bar.lua's icon-registration Layer 2).
    pcall(function()
        local iw = require("ui/widget/iconwidget")
        local iw_init = iw._simpleui_orig_init_for_scan or rawget(iw, "init")
        if type(iw_init) ~= "function" then return end
        for i = 1, 64 do
            local uname, uval = debug.getupvalue(iw_init, i)
            if uname == nil then break end
            if uname == "ICONS_PATH" and type(uval) == "table" then
                uval[name] = dst
                break
            end
        end
    end)

    _TAB_ICON_NAME_CACHE[slot_id] = { src = path, name = name }
    return name
end

--- Iterates the live tab_item_table of a FileManager or ReaderMenu instance
--- and resyncs every recognized tab's icon: the user's registered override
--- when one exists, or the slot's native default otherwise. Also accepts a
--- raw tab_item_table. Always resyncing (rather than only touching tabs
--- with an override) also fixes resets: a tab that previously had a custom
--- icon correctly reverts to its native icon once the override is cleared.
function M.applyTabIcons(fm_or_table)
    local tab_table
    if type(fm_or_table) == "table" then
        -- Could be a FM instance, a ReaderUI instance, or a raw table.
        if fm_or_table.file_manager_menu
           and fm_or_table.file_manager_menu.tab_item_table then
            tab_table = fm_or_table.file_manager_menu.tab_item_table
        elseif fm_or_table.menu
           and fm_or_table.menu.tab_item_table then
            -- ReaderUI instance (ReaderMenu is registered as ui.menu).
            tab_table = fm_or_table.menu.tab_item_table
        elseif fm_or_table.tab_item_table then
            -- FileManagerMenu or ReaderMenu instance passed directly.
            tab_table = fm_or_table.tab_item_table
        elseif fm_or_table[1] and fm_or_table[1].icon ~= nil then
            -- raw tab_item_table passed directly
            tab_table = fm_or_table
        end
    end
    if not tab_table then return end

    for _, tab in ipairs(tab_table) do
        local slot_id = tab.id and _TAB_ID_TO_SLOT[tab.id]
        if slot_id then
            local slot = _SLOT_BY_ID[slot_id]
            local raw  = M.getIcon(slot_id)
            if raw then
                local name = M.registerTabIconName(slot_id, raw)
                tab.icon = name or (slot and slot.default_ko) or tab.icon
            elseif slot and slot.default_ko then
                tab.icon = slot.default_ko
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Persistent tab-bar icon patches (FileManagerMenu + ReaderMenu)
-- ---------------------------------------------------------------------------
-- Both patches hook `onShowMenu` rather than `setUpdateItemTable`.
--
-- Why onShowMenu: FileManagerMenu/ReaderMenu:onShowMenu only calls
-- setUpdateItemTable() when `self.tab_item_table == nil` (build-once, cache
-- forever per instance). Patching onShowMenu instead of setUpdateItemTable
-- guarantees our override runs on *every* menu opening, and — critically —
-- runs it by forcing the table to be built (via a dynamic `fmm_self:
-- setUpdateItemTable()` call, which resolves to whatever version is
-- currently installed, including sui_quicksettings_bar's own tab-injection
-- wrap) *before* delegating to the untouched native onShowMenu that
-- actually constructs the TouchMenu widget. This sidesteps any ordering
-- dependency between this patch and sui_quicksettings_bar's own patches:
-- by the time TouchMenu:new{} runs, every tab (native + injected) already
-- has its final icon.
--
-- The SimpleUI-injected Quick Settings tab (_sui_qs_panel) is additionally
-- kept in sync directly by QSBar.refreshPanelTabIcon() (see
-- sui_quicksettings_bar.lua), since that tab is a single shared table
-- object reused by reference in both FM and Reader — mutating its `.icon`
-- field once is sufficient and avoids relying on injection-vs-override
-- ordering altogether. applyTabIcons() below still matches it too, as a
-- harmless no-op confirmation once it's present in a given tab_item_table.

local _fm_patch_installed     = false
local _reader_patch_installed = false

function M.installTabIconPatch(plugin)
    if _fm_patch_installed then return end
    local FMMenu = package.loaded["apps/filemanager/filemanagermenu"]
    if not FMMenu then
        local ok, m = pcall(require, "apps/filemanager/filemanagermenu")
        FMMenu = ok and m or nil
    end
    if not FMMenu then return end
    if FMMenu._simpleui_sysicon_patched then return end

    local orig = FMMenu.onShowMenu
    FMMenu._simpleui_sysicon_orig    = orig
    FMMenu._simpleui_sysicon_patched = true
    if plugin then plugin._sysicon_fmmenu_patched = true end

    FMMenu.onShowMenu = function(fmm_self, ...)
        if fmm_self.tab_item_table == nil then
            fmm_self:setUpdateItemTable()
        end
        if fmm_self.tab_item_table then
            M.applyTabIcons(fmm_self.tab_item_table)
        end
        return orig(fmm_self, ...)
    end

    _fm_patch_installed = true
    logger.dbg("simpleui/style: FM tab icon patch installed")
end

function M.removeTabIconPatch()
    if not _fm_patch_installed then return end
    local FMMenu = package.loaded["apps/filemanager/filemanagermenu"]
    if FMMenu and FMMenu._simpleui_sysicon_patched then
        FMMenu.onShowMenu                = FMMenu._simpleui_sysicon_orig
        FMMenu._simpleui_sysicon_orig    = nil
        FMMenu._simpleui_sysicon_patched = nil
    end
    _fm_patch_installed = false
    logger.dbg("simpleui/style: FM tab icon patch removed")
end

function M.installReaderTabIconPatch(plugin)
    if _reader_patch_installed then return end
    local ok, RMenu = pcall(require, "apps/reader/modules/readermenu")
    if not ok or not RMenu then return end
    if RMenu._simpleui_sysicon_patched then return end

    local orig = RMenu.onShowMenu
    RMenu._simpleui_sysicon_orig    = orig
    RMenu._simpleui_sysicon_patched = true
    if plugin then plugin._sysicon_rdmenu_patched = true end

    RMenu.onShowMenu = function(rm_self, ...)
        if rm_self.tab_item_table == nil then
            rm_self:setUpdateItemTable()
        end
        if rm_self.tab_item_table then
            M.applyTabIcons(rm_self.tab_item_table)
        end
        return orig(rm_self, ...)
    end

    _reader_patch_installed = true
    logger.dbg("simpleui/style: Reader tab icon patch installed")
end

function M.removeReaderTabIconPatch()
    if not _reader_patch_installed then return end
    local RMenu = package.loaded["apps/reader/modules/readermenu"]
    if RMenu and RMenu._simpleui_sysicon_patched then
        RMenu.onShowMenu                = RMenu._simpleui_sysicon_orig
        RMenu._simpleui_sysicon_orig    = nil
        RMenu._simpleui_sysicon_patched = nil
    end
    _reader_patch_installed = false
    logger.dbg("simpleui/style: Reader tab icon patch removed")
end

-- ---------------------------------------------------------------------------
-- Live tab-bar icon refresh
-- ---------------------------------------------------------------------------
-- Pushes current overrides into any live FM/Reader tab bar and asks it to
-- redraw. Covers the (rare) case where the icon picker is used while a
-- touch menu with tabs is already on the window stack.

function M.refreshLiveTabBars()
    -- Keep the shared Quick Settings panel tab's icon in sync regardless
    -- of whether the quicksettings-bar feature itself is currently enabled.
    local ok_qs, QSBar = pcall(require, "sui_quicksettings_bar")
    if ok_qs and QSBar and QSBar.refreshPanelTabIcon then
        pcall(QSBar.refreshPanelTabIcon)
    end

    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if not ok_ui then return end

    local fm = package.loaded["apps/filemanager/filemanager"]
    fm = fm and fm.instance
    if fm and fm.file_manager_menu and fm.file_manager_menu.tab_item_table then
        M.applyTabIcons(fm.file_manager_menu.tab_item_table)
    end

    for _, entry in ipairs(UIManager._window_stack or {}) do
        local w = entry.widget
        if w and w.tab_item_table then
            M.applyTabIcons(w.tab_item_table)
            UIManager:setDirty(w, "ui")
        end
    end
end

-- ---------------------------------------------------------------------------
-- Menu builder
-- ---------------------------------------------------------------------------

--- Returns the sub_item_table for Style ▸ Icons ▸ System Icons.
function M.makeMenuItems(plugin)
    local QA = require("sui_quickactions")

    -- Helper: get the current FM instance (may be nil).
    local function _fm()
        local FM = package.loaded["apps/filemanager/filemanager"]
        return FM and FM.instance
    end

    -- Helper: reapply titlebar icons to the live FM and all injected widgets.
local function _reapplyTitlebar()
        local ok_tb, TB = pcall(require, "sui_titlebar")
        if not ok_tb or not TB then return end
        local fm = _fm()
        local ok_ui, UIManager = pcall(require, "ui/uimanager")
        pcall(TB.reapplyAll, fm, ok_ui and UIManager._window_stack or nil)
    end

    -- Helper: reapply pagination icons on all live fullscreen menus and FM.
    local function _reapplyPaginationIcons()
        local ok_ui, UIManager = pcall(require, "ui/uimanager")
        if not ok_ui then return end

        -- Collect every widget that has pagination buttons and apply icons now.
        -- We must apply before nextTick so the widgets hold the new icon data
        -- when the deferred setDirty fires.
        local dirty_widgets = {}

        local fm = _fm()
        if fm and fm.file_chooser then
            if M.applyPaginationIcons(fm.file_chooser) then
                dirty_widgets[#dirty_widgets + 1] = fm.file_chooser
            end
        end

        -- Apply to any fullscreen menu currently on the stack (History, etc.).
        for _, entry in ipairs(UIManager._window_stack or {}) do
            local w = entry.widget
            if w and w.page_info_left_chev then
                if M.applyPaginationIcons(w) then
                    dirty_widgets[#dirty_widgets + 1] = w
                end
            end
        end

        if #dirty_widgets == 0 then return end

        -- Defer setDirty to the next tick so it runs *after* UIManager:close()
        -- has already finished its own _refresh() for the icon-picker dialog.
        -- Without this, the picker's close-repaint races with ours and the
        -- pagination bar may not reflect the new icon on screen.
        -- This is the same pattern used by sui_titlebar for deferred repaints.
        UIManager:nextTick(function()
            for _, w in ipairs(dirty_widgets) do
                UIManager:setDirty(w, "ui")
            end
        end)
    end

    -- Helper: reapply collections back icon on live collections widgets.
    local function _reapplyCollBackIcon()
        local ok_ui, UIManager = pcall(require, "ui/uimanager")
        if not ok_ui then return end
        for _, entry in ipairs(UIManager._window_stack or {}) do
            local w = entry.widget
            if w and (w.name == "collections" or w.name == "coll_list") then
                M.applyCollBackIcon(w)
            end
        end
    end

    -- Helper: after a change, reapply everything that is affected.
    local function _refresh(group)
        if group == "sui_titlebar" then
            _reapplyTitlebar()
        elseif group == "pg_icons" or group == "sui_pager_icons" then
            _reapplyPaginationIcons()
        elseif group == "coll_icons" then
            _reapplyCollBackIcon()
        elseif group == "sui_navpager_icons" then
            if plugin then plugin:_rebuildAllNavbars() end
        elseif group == "sui_qa_defaults" then
            local ok_qa, QA = pcall(require, "sui_quickactions")
            if ok_qa and QA.invalidateCustomQACache then QA.invalidateCustomQACache() end
            if plugin then plugin:_rebuildAllNavbars() end
            local ok_hs, HS = pcall(require, "sui_homescreen")
            if ok_hs and HS and HS._instance then HS._instance:_refreshImmediate(false) end
        elseif group == "sui_fc_icons" then
            local ok_fc, FC = pcall(require, "sui_foldercovers")
            if ok_fc and FC and FC.invalidateCache then FC.invalidateCache() end
            local fm = _fm()
            if fm and fm.file_chooser then
                fm._navbar_suppress_path_change = true
                fm.file_chooser:refreshPath()
                fm._navbar_suppress_path_change = nil
            end
        elseif group == "sui_tabbar_icons" then
            M.refreshLiveTabBars()
        end
    end

    -- ── Section heading helper ───────────────────────────────────────────
    local function _sep(label)
        return { text = label, is_title = true }
    end

    -- ── One row per slot ─────────────────────────────────────────────────
    local function _makeRow(slot)
        return {
            text_func = function()
                local path = M.getIcon(slot.id)
                local label = type(slot.label) == "function" and slot.label() or slot.label
                if path then
                    return label .. "  \u{270E}"
                end
                return label
            end,
            keep_menu_open = true,
            callback = function()
                QA.showIconPicker(
                    M.getIcon(slot.id),
                    function(new_path)
                        -- Guard: validate format/existence before persisting.
                        -- nil = "reset to default", always valid.
                        if new_path == nil then
                            M.setIcon(slot.id, nil)
                            _refresh(slot.group)
                            return
                        end
                        local safe = M.safeIconPath(new_path, nil)
                        if safe then
                            M.setIcon(slot.id, safe)
                            _refresh(slot.group)
                        else
                            local _InfoMessage = require("ui/widget/infomessage")
                            UIManager:show(_InfoMessage:new{
                                text    = _("Unsupported icon format.\nPlease use a PNG or SVG file."),
                                timeout = 3,
                            })
                        end
                    end,
                    type(slot.label) == "function" and slot.label() or slot.label,
                    plugin,
                    "_sysicon_picker_" .. slot.id,
                    true
                )
            end,
        }
    end

    -- ── Group the slots ───────────────────────────────────────────────────
    local items = {}

    -- Reset all item at the top.
    items[#items + 1] = {
        text           = _("Reset All System Icons"),
        keep_menu_open = true,
        callback       = function()
            M.performResetAllSystemIcons(plugin)
        end,
        separator      = true,
    }

    -- ── sui_titlebar group ────────────────────────────────────────────────
    for _, slot in ipairs(M.SLOTS) do
        if slot.group == "sui_titlebar" then
            items[#items + 1] = _makeRow(slot)
        end
    end

    -- ── bm_icons group ───────────────────────────────────────────────────
    for _, slot in ipairs(M.SLOTS) do
        if slot.group == "sui_browse_icons" then
            local row = _makeRow(slot)
            -- After changing a browse icon, refresh the live browse button.
            local orig_cb = row.callback
            row.callback = function()
                orig_cb()
                local ok_tb, TB = pcall(require, "sui_titlebar")
                if ok_tb and TB and TB.refreshBrowseIcons then
                    TB.refreshBrowseIcons(_fm())
                end
            end
            items[#items + 1] = row
        end
    end

    -- ── pg_icons group (pagination chevrons) ─────────────────────────────
    for _, slot in ipairs(M.SLOTS) do
        if slot.group == "sui_pager_icons" then
            items[#items + 1] = _makeRow(slot)
        end
    end

    -- ── sui_navpager_icons group (Navpager) ──────────────────────────────
    for _, slot in ipairs(M.SLOTS) do
        if slot.group == "sui_navpager_icons" then
            items[#items + 1] = _makeRow(slot)
        end
    end

    -- ── sui_fc_icons group ───────────────────────────────────────────────
    for _, slot in ipairs(M.SLOTS) do
        if slot.group == "sui_fc_icons" then
            items[#items + 1] = _makeRow(slot)
        end
    end

    -- ── sui_tabbar_icons group (touch menu tabs) ─────────────────────────
    for _, slot in ipairs(M.SLOTS) do
        if slot.group == "sui_tabbar_icons" then
            items[#items + 1] = _makeRow(slot)
        end
    end

    return items
end

function M.sui_build_system_icons(plugin, ctx_menu, ctx)
    local Device = require("device")
    local Screen = Device.screen
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local ImageWidget = require("ui/widget/imagewidget")
    local TextWidget = require("ui/widget/textwidget")
    local IconWidget = require("ui/widget/iconwidget")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    
    local btn_size = Screen:scaleBySize(36)
    local icon_size = math.floor(btn_size * 0.7)
    local border_sz = Screen:scaleBySize(1)
    
    local function makeIconPreview(icon_path, ko_native, fallback_label)
        local icon_widget
        local Config = require("sui_config")
        local is_nerd = icon_path and Config.isNerdIcon(icon_path)
        
        if is_nerd then
            local nerd_char = Config.nerdIconChar(icon_path)
            if nerd_char then
                icon_widget = TextWidget:new{
                    text    = nerd_char,
                    face    = Font:getFace(M.FACE_ICONS, math.floor(icon_size * 0.8)),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    padding = 0,
                }
            end
        elseif icon_path and M.safeIconPath then
            local safe_path = M.safeIconPath(icon_path, nil)
            if safe_path then
                local iw = ImageWidget:new{
                    file    = safe_path,
                    width   = icon_size,
                    height  = icon_size,
                    is_icon = true,
                    alpha   = true,
                }
                if pcall(function() iw:_render() end) then
                    icon_widget = iw
                else
                    iw:free()
                end
            end
        end
        
        if not icon_widget and ko_native then
            icon_widget = IconWidget:new{
                icon    = ko_native,
                width   = icon_size,
                height  = icon_size,
            }
        end

        if not icon_widget then
            icon_widget = TextWidget:new{
                text    = fallback_label and fallback_label:sub(1, 1):upper() or "?",
                face    = Font:getFace("cfont", math.floor(icon_size * 0.7)),
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
        end
        
        return FrameContainer:new{
            dimen      = Geom:new{ w = btn_size, h = btn_size },
            radius     = Screen:scaleBySize(8),
            bordersize = border_sz,
            background = Blitbuffer.COLOR_WHITE,
            color      = Blitbuffer.gray(0.75),
            padding    = 0,
            [1]        = CenterContainer:new{
                dimen = Geom:new{ w = btn_size - border_sz * 2, h = btn_size - border_sz * 2 },
                [1]   = icon_widget,
            }
        }
    end

    local function get_rows()
        local rows = {}
        local function addGroup(group_id, group_name)
            local added_title = false
            for _idx, slot in ipairs(M.SLOTS) do
                if slot.group == group_id then
                    if not added_title then
                        rows[#rows + 1] = {
                            text = group_name:upper(),
                            is_divider = true,
                            sui_build = function(ctx)
                                return require("sui_window").SectionLabel{ text = group_name:upper(), inner_w = ctx.inner_w }
                            end
                        }
                        added_title = true
                    end
                    
                    local path = M.getIcon(slot.id)
                    local label = type(slot.label) == "function" and slot.label() or slot.label
                    
                    local effective_path = path
                    local ko_native = nil
                    if not effective_path then
                        if slot.default_ko and slot.default_ko:match("%.svg$") then
                            local _plugin_dir = (debug.getinfo(1, "S").source:match("^@(.+/)[^/]+$") or "./")
                            local lfs = require("libs/libkoreader-lfs")
                            if lfs.attributes(_plugin_dir .. "/" .. slot.default_ko, "mode") == "file" then
                                effective_path = _plugin_dir .. "/" .. slot.default_ko
                            else
                                ko_native = slot.default_ko
                            end
                        elseif slot.default_ko then
                            ko_native = slot.default_ko
                        end
                    end
                    
                    rows[#rows + 1] = {
                        text = label .. (path and "  \u{270E}" or ""),
                        show_chevron = true,
                        right_widget = makeIconPreview(effective_path, ko_native, label),
                        on_hold = function() end,
                        on_tap = function()
                            local QA = require("sui_quickactions")
                            QA.showIconPicker(path, function(new_path)
                                local function _guardedSetIcon(ipath, on_valid)
                                    if ipath == nil then on_valid(nil); return end
                                    local safe = M.safeIconPath(ipath, nil)
                                    if not safe then
                                        ctx_menu.UIManager:show(ctx_menu.InfoMessage:new{ text = _("Unsupported icon format.\nPlease use a PNG or SVG file."), timeout = 3 })
                                        return
                                    end
                                    if slot.group == "sui_tabbar_icons" then
                                        local ext = safe:match("%.([^.]+)$")
                                        ext = ext and ext:lower()
                                        if ext ~= "svg" and ext ~= "png" then
                                            ctx_menu.UIManager:show(ctx_menu.InfoMessage:new{ text = _("Tab bar icons must be PNG or SVG."), timeout = 3 })
                                            return
                                        end
                                    end
                                    on_valid(safe)
                                end
                                _guardedSetIcon(new_path, function(safe_path)
                                    M.setIcon(slot.id, safe_path)
                                    QA.invalidateCustomQACache()
                                    plugin:_rebuildAllNavbars()
                                    if slot.group == "sui_tabbar_icons" then
                                        pcall(M.refreshLiveTabBars)
                                    end
                                    local HS = package.loaded["sui_homescreen"]
                                    if HS and HS._instance then HS._instance:_refreshImmediate(false) end
                                    -- Reapply titlebar icons and dirty the root widget so the
                                    -- titlebar repaints in the same paint cycle as the bottombar.
                                    -- Using setDirty on plugin.ui (the FM root) mirrors what
                                    -- _rebuildAllNavbars does — no tick scheduling needed because
                                    -- the SUIWindow is a child of this widget and is composited
                                    -- together with it by the UIManager.
                                    local ok_tb, TB = pcall(require, "sui_titlebar")
                                    if ok_tb and TB then
                                        local ok_ui, UIManager = pcall(require, "ui/uimanager")
                                        pcall(TB.reapplyAll, plugin.ui,
                                              ok_ui and UIManager._window_stack or nil)
                                        if ok_ui and UIManager and plugin.ui then
                                            UIManager:setDirty(plugin.ui, "ui")
                                        end
                                    end
                                    ctx.repaint()
                                end)
                            end, label, plugin, "_sysicon_picker_" .. slot.id, slot.group ~= "sui_tabbar_icons")
                        end
                    }
                end
            end
        end

        addGroup("sui_titlebar", _("Title Bar"))
        addGroup("sui_browse_icons", _("Browse Icons"))
        addGroup("sui_pager_icons", _("Pagination Bar"))
        addGroup("sui_navpager_icons", _("Navpager"))
        addGroup("sui_fc_icons", _("Folder Covers"))
        addGroup("sui_tabbar_icons", _("Tab Bar"))
        return rows
    end
    
    ctx_menu.show_row_page({
        title = _("System Icons"),
        items_func = get_rows,
        footer_text = _("Reset All"),
        footer_icon = "update",
        footer_action = function(ctx2)
            local ConfirmBox = require("ui/widget/confirmbox")
            ctx_menu.UIManager:show(ConfirmBox:new{
                text = _("Reset all system icons to default?"),
                ok_text = _("Reset"),
                cancel_text = _("Cancel"),
                ok_callback = function()
                    M.performResetAllSystemIcons(plugin)
                    ctx2.repaint()
                end,
            })
        end,
    })
end

-- ---------------------------------------------------------------------------
-- SUI Typographic Scale
-- ---------------------------------------------------------------------------
-- Five semantic font-size levels used across all SimpleUI modules.
-- Change values only here — every module derives its sizes from these.
--
--  FS_TITLE    (22)  — primary title, placeholder, cover heading, dir label
--  FS_SUBTITLE (20)  — subtitle, author name, large numeric value
--  FS_BODY     (18)  — standard row text, quote body, section label
--  FS_DETAIL   (15)  — metadata, percentages, collection labels, stats label
--  FS_CAPTION  (12)  — minimum readable label, pagination xs, goal sub-label
--
--  Badge overlays (module_collections, sui_foldercovers) are calculated
--  proportionally to their container size and intentionally bypass this scale.
--
--  Modules that have their own user-controlled scale factor (topbar, bottombar)
--  multiply that factor on top, e.g.:
--      math.floor(SUIStyle.FS_TITLE * _getTopbarScale())
--
--  The Style ▸ Global Text Size setting (Config.getFontScalePct()) is NOT
--  applied here. It patches ui/font.lua's Font:getFace() directly (see
--  sui_patches.lua patchFontGetFace), so it scales every KOReader UI text
--  size — native menus/dialogs AND SimpleUI's own FS_* widgets alike —
--  from a single choke point. Baking it into FS_* here too would double
--  the scale for every SimpleUI-drawn string.
--
--  _FS_SCALE is reserved for a possible future *SimpleUI-only* density
--  knob, layered independently on top of the global Font:getFace scale.

local _FS_SCALE = 1.0

local function _fs(base)
    return math.max(8, math.floor(base * _FS_SCALE))
end

M.FS_TITLE    = _fs(22)
M.FS_SUBTITLE = _fs(20)
M.FS_BODY     = _fs(18)
M.FS_DETAIL   = _fs(15)
M.FS_CAPTION  = _fs(12)

-- Global border thickness for all frames and elements
M.BORDER_SZ   = math.max(1, Screen:scaleBySize(1))

-- Thinner border and specific color for library badges and book covers
M.BADGE_BORDER_SZ  = require("ui/size").border.thin
M.BADGE_BORDER_CLR = Blitbuffer.COLOR_GRAY

-- ---------------------------------------------------------------------------
-- SUI Font Face Aliases
-- ---------------------------------------------------------------------------
-- Semantic font-face tokens used across all SimpleUI modules.
-- These are KOReader fontmap alias names passed to Font:getFace().
-- They select the font *file*; the size always comes from FS_* above.
-- Change values only here — every module derives its font faces from these.
--
--  FACE_REGULAR  — NotoSans-Regular: prose, labels, metadata, all general UI text.
--
--  FACE_BOLD     — NotoSans-Bold: emphasis, titles that need weight.
--                  Use sparingly; most titles use FACE_REGULAR + bold=true.
--
--  FACE_MONO     — DroidSansMono: counters, numeric badges, file counts,
--                  any value where fixed-width spacing matters.
--  FACE_ICONS    — nerdfonts/symbols.ttf: glyph / icon codepoints (U+E000…).
--
-- NOTE: When the UI Font picker (_applyFont) rewrites Font.fontmap, it updates
-- the KO slot names directly (e.g. "cfont", "tfont"). Because FACE_REGULAR and
-- FACE_BOLD point to those same slots, all SUI widgets automatically inherit
-- the user's chosen font with no extra work.

M.FACE_REGULAR = "cfont"
M.FACE_BOLD    = "tfont"
M.FACE_MONO    = "infont"
M.FACE_ICONS   = "symbols"

-- ---------------------------------------------------------------------------
-- SUI Icon Glyphs (Nerd Fonts / Material Symbols codepoints)
-- ---------------------------------------------------------------------------
-- Centraliza todos os glyphs usados na UI para eliminar Unicode espalhado.
-- Uso: text = SUIStyle.icon("chevron")  →  "\u{E8CC}"
-- Nunca usar os codepoints diretamente no código — usar sempre SUIStyle.icon().
--
-- Categorias:
--   Navegação  — chevron, back, more
--   Ações      — check, uncheck, delete, edit, add, drag
--   Estado     — goal, stats

M.ICON = {
    -- Navegação
    chevron  = "\u{F105}",   -- nf-fa-angle_right
    back     = "\u{E5C4}",   -- arrow_back
    more     = "\u{E8D7}",   -- more_horiz / três pontos (botão "…" do card)

    -- Ações
    check    = "\u{E832}",   -- check_box (checked)
    uncheck  = "\u{E82F}",   -- check_box_outline_blank
    delete   = "\u{F014}",   -- trash / delete (NerdFonts)
    edit     = "\u{F040}",   -- pencil / edit (NerdFonts)
    add      = "\u{E145}",   -- add / plus
    drag     = "\u{E25D}",   -- drag_handle
    arrow_up   = "\u{E75C}", -- arrow up (NerdFonts)
    arrow_down = "\u{E744}", -- arrow down (NerdFonts)
    move_page  = "\u{F0EC}", -- exchange / move
    update     = "\u{E769}", -- update / sync

    -- Estado / Conteúdo
    goal     = "\u{E153}",   -- flag (objetivos de leitura)
    stats    = "\u{E24B}",   -- bar_chart
    clock    = "\u{E385}",
    page     = "\u{F40E}",
    book     = "\u{F401}",
    calendar = "\u{F490}",
    trophy   = "\u{EC3B}",
    highlights = "\u{EE6B}",
    notes    = "\u{EAEC}",
    arrow_right = "\u{F178}",
}

--- Devolve o glyph do ícone com o nome `name`, ou "" se não existir.
--- Uso: TextWidget:new{ text = SUIStyle.icon("chevron"), face = ... }
---
--- @param name string  chave de M.ICON
--- @return string
function M.icon(name)
    return M.ICON[name] or ""
end

-- ---------------------------------------------------------------------------
-- UI Font face picker
-- ---------------------------------------------------------------------------
-- Allows the user to replace KOReader's built-in UI font with any font
-- installed on the system.
--
-- Settings keys (all via SUISettings):
--   simpleui_ui_font_name     string   — selected font family name
--   simpleui_ui_font_enabled  bool     — true = custom font active
--
-- The font path is resolved at apply-time via cre.getFontFaceFilenameAndFaceIndex
-- so the setting stores the human-readable family name, not a raw file path.
--
-- Public API:
--   M.applyUIFont()          — restore saved font (called from main.lua init)
--   M.makeFontMenuItems()    — returns sub_item_table for Style ▸ UI Font
-- ---------------------------------------------------------------------------

-- Settings keys
local _FONT_KEY_NAME    = "simpleui_ui_font_name"
local _FONT_KEY_ENABLED = "simpleui_ui_font_enabled"
local _FONT_DEFAULT     = "Noto Sans"

-- Module-level lazy caches — populated once by _initFonts().
local _font_list     = nil   -- ordered list of font family names (strings)
local _fonts         = nil   -- map: family name → { regular=path, bold=path }
local _replaced      = nil   -- map: Font.fontmap slot → "regular"|"bold"

-- ── Lazy module accessors ────────────────────────────────────────────────

local function _reqFont()
    local ok, m = pcall(require, "ui/font"); return ok and m or nil
end
local function _reqFontList()
    local ok, m = pcall(require, "fontlist"); return ok and m or nil
end
local function _reqCRE()
    -- Primary path: via CreDocument:engineInit() which loads and returns the
    -- cre C module.  This works in both the reader and the file manager.
    local ok, m = pcall(function()
        return require("document/credocument"):engineInit()
    end)
    if ok and m then return m end
    -- Fallback: the cre library may already be loaded as a standalone module
    -- (happens in some KOReader builds where it is pre-required).
    local ok2, m2 = pcall(require, "libs/libkoreader-cre")
    return ok2 and m2 or nil
end
local function _reqUIManager()
    local ok, m = pcall(require, "ui/uimanager"); return ok and m or nil
end
local function _reqLFS()
    local ok, m = pcall(require, "libs/libkoreader-lfs"); return ok and m or nil
end
local function _reqDataStorage()
    local ok, m = pcall(require, "datastorage"); return ok and m or nil
end

-- ── Path helpers ─────────────────────────────────────────────────────────

-- Heuristic: try "Font-Regular.ext" → "Font-Bold.ext",
-- then "Font.ext" → "Font-Bold.ext".
local function _boldPath(path_regular)
    if not path_regular then return nil end
    local p, n = path_regular:gsub("%-Regular%.", "-Bold.", 1)
    if n > 0 then return p end
    p, n = path_regular:gsub("(%.)([^.]+)$", "-Bold.%2", 1)
    return n > 0 and p or nil
end

-- ── Font list initialisation ──────────────────────────────────────────────

-- Builds _font_list, _fonts, _replaced.
local function _initFonts()
    local Font     = _reqFont()
    local FontList = _reqFontList()
    local cre      = _reqCRE()
    local lfs      = _reqLFS()
    if not (Font and FontList and cre) then
        _font_list = {}; _fonts = {}; _replaced = {}
        logger.warn("simpleui/style: font modules unavailable, font picker disabled")
        return
    end

    _font_list = {}
    _fonts     = {}
    _replaced  = {}

    -- Build the set of paths that will be accepted as valid font sources.
    local path_set = {}
    for _, p in ipairs(FontList.fontlist) do 
        -- Verify the file still exists on disk, as FontList caches paths across restarts.
        if not lfs or lfs.attributes(p, "mode") == "file" then
            path_set[p] = true 
        end
    end

    -- Walk CRE's font face list and keep only those whose file is in path_set.
    for _, name in ipairs(cre.getFontFaces()) do
        local path_regular = cre.getFontFaceFilenameAndFaceIndex(name)
        if path_regular and path_set[path_regular] then
            local path_bold  = _boldPath(path_regular)
            local bold_ok    = path_set[path_bold]
            table.insert(_font_list, name)
            if bold_ok then
                _fonts[name] = { regular = path_regular, bold = path_bold }
            else
                _fonts[name] = { regular = path_regular, bold = path_regular }
            end
        end
    end

    -- Record which Font.fontmap slots map to the two built-in Noto variants
    -- so we know exactly which entries to overwrite on apply.
    local type_font = {
        ["NotoSans-Regular.ttf"] = "regular",
        ["NotoSans-Bold.ttf"]    = "bold",
    }
    for slot, font_file in pairs(Font.fontmap) do
        local typ = type_font[font_file]
        if typ then _replaced[slot] = typ end
    end

    logger.dbg("simpleui/style: font list built,", #_font_list, "faces")
end

-- Ensures the cache is valid for the current setting value.
-- Wrapped in pcall internally so any unexpected error leaves the caches in a
-- safe (empty) state instead of propagating to the caller.
local function _ensureFonts()
    if _font_list ~= nil then return end
    local ok, err = pcall(_initFonts)
    if not ok then
        logger.warn("simpleui/style: _initFonts error:", err)
        _font_list    = _font_list    or {}
        _fonts        = _fonts        or {}
        _replaced     = _replaced     or {}
    end
end

-- ── Apply ────────────────────────────────────────────────────────────────

-- Refreshes the class-level font face defaults on KOReader's TitleBar widget.
--
-- TitleBar (ui/widget/titlebar.lua) evaluates Font:getFace("smalltfont") etc.
-- at require()-time as default field values in the OverlapGroup:extend{} table.
-- After _applyFont() updates Font.fontmap, those frozen face objects still point
-- to the old NotoSans paths, so every new TitleBar instance inherits the wrong
-- font regardless of the fontmap change.
--
-- Fix: after updating fontmap, call Font:getFace() again for each frozen slot
-- to get a face object bound to the new path, and overwrite the class default.
-- Safe to call even if titlebar.lua was never required (pcall + check).
local function _refreshTitleBarFaces()
    local ok_tb, TitleBar = pcall(require, "ui/widget/titlebar")
    if not ok_tb or not TitleBar then return end
    local Font = _reqFont()
    if not Font then return end
    -- These are the four slots frozen as class-level defaults in TitleBar.
    -- Re-fetching them forces Font to resolve the new fontmap path and cache
    -- a face under the new hash, then we replace the class default.
    local slots = {
        { field = "title_face_fullscreen",     face = "smalltfont"     },
        { field = "title_face_not_fullscreen", face = "x_smalltfont"   },
        { field = "subtitle_face",             face = "xx_smallinfofont"},
        { field = "info_text_face",            face = "x_smallinfofont" },
    }
    for _, s in ipairs(slots) do
        local ok_f, face = pcall(Font.getFace, Font, s.face)
        if ok_f and face then
            TitleBar[s.field] = face
        end
    end
end

-- Writes the chosen font paths into Font.fontmap.
local function _applyFont(name)
    local Font = _reqFont()
    if not Font then return end
    _ensureFonts()
    if not SUISettings:isTrue(_FONT_KEY_ENABLED) then return end
    if not (_fonts and _fonts[name]) then return end
    for slot, typ in pairs(_replaced) do
        Font.fontmap[slot] = _fonts[name][typ]
    end
    logger.dbg("simpleui/style: UI font applied →", name)
    -- Refresh TitleBar class defaults so new instances use the updated font.
    _refreshTitleBarFaces()
end

--- Restore the saved font preference.  Called from main.lua at plugin init.
function M.applyUIFont()
    _ensureFonts()
    if SUISettings:isTrue(_FONT_KEY_ENABLED) then
        local name = SUISettings:get(_FONT_KEY_NAME) or _FONT_DEFAULT
        if _fonts and _fonts[name] then
            _applyFont(name)
        else
            logger.warn("simpleui/style: active UI font not found on disk, disabling custom font:", name)
            SUISettings:set(_FONT_KEY_ENABLED, false)
        end
    end
end

-- ── Menu builder ─────────────────────────────────────────────────────────

--- Returns the sub_item_table for Style ▸ UI Font.
--- Never throws: any internal error is caught and surfaced as a disabled
--- "unavailable" entry so the menu always opens.
function M.makeFontMenuItems()
    local ok_ef, err_ef = pcall(_ensureFonts)
    if not ok_ef then
        logger.warn("simpleui/style: makeFontMenuItems – _ensureFonts error:", err_ef)
        _font_list = _font_list or {}
        _fonts     = _fonts     or {}
        _replaced  = _replaced  or {}
    end
    local Font      = _reqFont()
    local UIManager = _reqUIManager()

    local function _isEnabled()
        return SUISettings:isTrue(_FONT_KEY_ENABLED)
    end
    local function _currentName()
        return SUISettings:get(_FONT_KEY_NAME) or _FONT_DEFAULT
    end

    local items = {}

    -- ── Toggle: enable custom font ────────────────────────────────────────
    items[#items + 1] = {
        text         = _("Enable custom UI font"),
        checked_func = _isEnabled,
        callback     = function()
            local new_val = not _isEnabled()
            SUISettings:set(_FONT_KEY_ENABLED, new_val)
            if new_val then _applyFont(_currentName()) end
            if UIManager then
                UIManager:askForRestart(_("Restart to fully apply the UI font change."))
            end
        end,
    }

    -- ── One entry per available font face ────────────────────────────────
    if #_font_list == 0 then
        items[#items + 1] = {
            text    = _("No fonts found."),
            enabled_func = function() return false end,
            callback     = function() end,
        }
    else
        for _k, name in ipairs(_font_list) do
            local _name = name   -- upvalue capture
            items[#items + 1] = {
                text_func = function()
                    local label = _name
                    if _fonts[_name] and _fonts[_name].regular == _fonts[_name].bold then
                        label = label .. "  (no bold)"
                    end
                    if _isEnabled() and _name == _currentName() then
                        label = "\u{2713}  " .. label
                    end
                    return label
                end,
                -- Hide this entry in SUIWindow until the custom-font toggle is on.
                sui_hidden = function() return not _isEnabled() end,
                -- Render the menu entry in that font face when supported.
                font_func = Font and function(size)
                    local fd = _fonts[_name]
                    if not fd then return nil end
                    return Font:getFace(fd.regular, size)
                end or nil,
                -- Grey-out the currently selected entry.
                enabled_func = function()
                    return not (_isEnabled() and _name == _currentName())
                end,
                keep_menu_open = true,
                callback = function()
                    SUISettings:set(_FONT_KEY_NAME, _name)
                    SUISettings:set(_FONT_KEY_ENABLED, true)
                    _applyFont(_name)
                    if UIManager then
                        UIManager:askForRestart(_("Restart to fully apply the UI font change."))
                    end
                end,
            }
        end
    end

    return items
end

-- ===========================================================================
-- Theme Colors
-- ===========================================================================
-- Granular per-role colour overrides for every SimpleUI surface.
-- All keys use the "simpleui_style_" prefix so that homescreen presets
-- capture them automatically (HS_PREFIXES in sui_presets.lua covers it).
--
-- Color storage
-- ─────────────
-- Hex strings (#RRGGBB) are stored in settings.  At read-time they are
-- converted to Blitbuffer colors via Blitbuffer.colorFromString(), which
-- preserves the full RGB value.  On a greyscale e-ink panel the hardware
-- renders the perceived luminance — the user can therefore enter any HTML
-- color and it will look "right" without us forcing a luma conversion.
--
-- Role catalogue
-- ──────────────
-- "bg"              Homescreen background (also fallback for bars when their
--                   own role is unset).
-- "fg"              Homescreen primary text (also fallback for bar text).
-- "bottombar_bg"    Bottom navigation bar background.
-- "bottombar_fg"    Bottom navigation bar icon / label text.
-- "statusbar_bg"    Top status bar background.
-- "statusbar_fg"    Top status bar text (clock, battery, …).
-- "text_secondary"  Secondary / dim text — inactive nav items, sub-labels,
--                   mid-tone homescreen captions.
-- "separator"       Thin divider line between bars and content.
-- "accent"          Active / highlighted element (active nav item, pager
--                   arrows, etc.).
--
-- Fallback chain (getThemeColor)
-- ───────────────────────────────
-- bottombar_bg  → bg  → nil (caller uses its own default)
-- bottombar_fg  → fg  → nil
-- statusbar_bg  → bg  → nil
-- statusbar_fg  → fg  → nil
-- text_secondary → nil  (callers have their own grey default)
-- separator      → nil
-- accent         → nil

-- Settings keys — all under simpleui_style_ so presets pick them up.
local _ROLE_KEYS = {
    bg              = "simpleui_style_theme_bg",
    fg              = "simpleui_style_theme_fg",
    bottombar_bg    = "simpleui_style_theme_bottombar_bg",
    bottombar_fg    = "simpleui_style_theme_bottombar_fg",
    statusbar_bg    = "simpleui_style_theme_statusbar_bg",
    statusbar_fg    = "simpleui_style_theme_statusbar_fg",
    text_secondary  = "simpleui_style_theme_text_secondary",
    separator       = "simpleui_style_theme_separator",
    accent          = "simpleui_style_theme_accent",
    progress_bg     = "simpleui_style_theme_progress_bg",
    progress_fg     = "simpleui_style_theme_progress_fg",
}

-- Fallback chain: if role has no value, try these roles in order.
local _FALLBACKS = {
    bottombar_bg = { "bg" },
    bottombar_fg = { "fg" },
    statusbar_bg = { "bg" },
    statusbar_fg = { "fg" },
    progress_fg  = { "accent", "fg" },
}

-- In-memory cache: role → Blitbuffer color OR false ("tested, not set").
-- false avoids a store lookup on every paintTo().
-- Invalidated by setThemeColor() / resetTheme().
local _color_cache = {}

--- Converts "#RRGGBB" or "RRGGBB" to a full-colour Blitbuffer color.
--- Uses colorFromString when available (KOReader ≥ 2022), falls back to
--- a manual ColorRGB32 construction so older builds still work.
--- Returns nil on any parse error.
local function _hexToColor(hex)
    if type(hex) ~= "string" then return nil end
    local s = hex:match("^#?(%x%x%x%x%x%x)$")
    if not s then return nil end
    -- Prefer the built-in parser — it handles device colour depth correctly.
    if Blitbuffer.colorFromString then
        local normalized = "#" .. s:upper()
        local ok, c = pcall(Blitbuffer.colorFromString, normalized)
        if ok and c then return c end
    end
    -- Fallback: construct via ColorRGB32.
    local r = tonumber(s:sub(1, 2), 16)
    local g = tonumber(s:sub(3, 4), 16)
    local b = tonumber(s:sub(5, 6), 16)
    local ok2, c2 = pcall(Blitbuffer.ColorRGB32, r, g, b, 0)
    return ok2 and c2 or nil
end

local function _invalidateColorCache()
    _color_cache = {}
end

--- Returns the Blitbuffer color for `role`, respecting the fallback chain,
--- or nil when no custom color is set anywhere in the chain.
---
--- NOTE on cache safety: Blitbuffer cdata colors have an __eq metamethod that
--- crashes LuaJIT when either operand is non-color.  We use type() checks and
--- the boolean sentinel (false) instead of equality comparisons.
function M.getThemeColor(role)
    -- 1. Check cache for this role.
    local cached = _color_cache[role]
    local ct = type(cached)
    if ct == "boolean" then
        -- sentinel false → already resolved to nil for this role
        return nil
    elseif ct ~= "nil" then
        return cached   -- valid color object
    end

    -- 2. Try the role's own key.
    local key = _ROLE_KEYS[role]
    if key then
        local c = _hexToColor(SUISettings:get(key))
        if c then
            _color_cache[role] = c
            return c
        end
    end

    -- 3. Walk fallback chain.
    local fallbacks = _FALLBACKS[role]
    if fallbacks then
        for _, fb_role in ipairs(fallbacks) do
            local fb_key = _ROLE_KEYS[fb_role]
            if fb_key then
                local c = _hexToColor(SUISettings:get(fb_key))
                if c then
                    _color_cache[role] = c
                    return c
                end
            end
        end
    end

    -- 4. Nothing found — cache the sentinel so we skip the store next time.
    _color_cache[role] = false
    return nil
end

--- Saves `hex` ("#RRGGBB" / "RRGGBB") for `role`.
--- [DISABLED — theme color write/UI not ready for release]
--[==[
--- Saves `hex` ("#RRGGBB" / "RRGGBB") for `role`.
--- Pass nil or "" to reset the role to its default.
--- Invalidates the full in-memory cache (roles may depend on each other via
--- the fallback chain, so we can't invalidate selectively).
function M.setThemeColor(role, hex)
    local key = _ROLE_KEYS[role]
    if not key then return end
    if type(hex) == "string" and hex:match("^#?%x%x%x%x%x%x$") then
        SUISettings:set(key, hex:upper():gsub("^([^#])", "#%1"))
    else
        SUISettings:del(key)
    end
    _invalidateColorCache()
    logger.dbg("simpleui/style/theme: setThemeColor", role, "→", hex or "(reset)")
end

--- Clears every theme color override and invalidates the cache.
function M.resetTheme()
    for _, key in pairs(_ROLE_KEYS) do
        SUISettings:del(key)
    end
    _invalidateColorCache()
    logger.dbg("simpleui/style/theme: resetTheme")
end

-- ---------------------------------------------------------------------------
-- Preset palettes — shown as quick-fill shortcuts in the menu.
-- Each preset is a flat table of role → hex.
-- ---------------------------------------------------------------------------
local _PRESETS = {
    {
        label = _("Warm Paper"),
        colors = {
            bg             = "#F5F0E8",
            fg             = "#1A1008",
            bottombar_bg   = "#EDE8DF",
            bottombar_fg   = "#1A1008",
            statusbar_bg   = "#EDE8DF",
            statusbar_fg   = "#1A1008",
            text_secondary = "#6B5B45",
            separator      = "#C8C0B0",
            accent         = "#8B5E3C",
        },
    },
    {
        label = _("Dark Slate"),
        colors = {
            bg             = "#1C1C1E",
            fg             = "#E5E5EA",
            bottombar_bg   = "#2C2C2E",
            bottombar_fg   = "#E5E5EA",
            statusbar_bg   = "#2C2C2E",
            statusbar_fg   = "#E5E5EA",
            text_secondary = "#8E8E93",
            separator      = "#3A3A3C",
            accent         = "#0A84FF",
        },
    },
    {
        label = _("Cool Mist"),
        colors = {
            bg             = "#EEF2F7",
            fg             = "#1C2B3A",
            bottombar_bg   = "#E4EAF2",
            bottombar_fg   = "#1C2B3A",
            statusbar_bg   = "#E4EAF2",
            statusbar_fg   = "#1C2B3A",
            text_secondary = "#5A7080",
            separator      = "#C0CDD8",
            accent         = "#2D6A9F",
        },
    },
    {
        label = _("Sepia Classic"),
        colors = {
            bg             = "#FAEBD7",
            fg             = "#3B2A1A",
            bottombar_bg   = "#F0DFC0",
            bottombar_fg   = "#3B2A1A",
            statusbar_bg   = "#F0DFC0",
            statusbar_fg   = "#3B2A1A",
            text_secondary = "#7A5C40",
            separator      = "#D4B896",
            accent         = "#9B5B2A",
        },
    },
}

-- ---------------------------------------------------------------------------
-- Menu builder
-- ---------------------------------------------------------------------------

--- Returns the sub_item_table for Style ▸ Theme Colors.
--- Uses InputDialog (hex entry) — no external color picker widget required.
function M.makeThemeMenuItems()
    -- Ordered role definitions for the menu rows.
    -- Grouped by COLOR TYPE (not by UI location) so the user can find all
    -- "background" or "text" settings in one place regardless of which bar
    -- they belong to.  Section titles are kept to one per group; the old
    -- per-location titles (Homescreen / Bottom Bar / Status Bar / Details)
    -- have been removed as they were redundant with the label text itself.
    local _ROLES = {
        { role = "bg",             label = _("Home Screen — Background") },
        { role = "bottombar_bg",   label = _("Bottom Bar — Background") },
        { role = "statusbar_bg",   label = _("Status Bar — Background") },
        { role = "fg",             label = _("Home Screen — Text") },
        { role = "bottombar_fg",   label = _("Bottom Bar — Text and Icons") },
        { role = "statusbar_fg",   label = _("Status Bar — Text") },
        { role = "text_secondary", label = _("Secondary / Dim Text") },
        { role = "separator",      label = _("Separator Line") },
        { role = "accent",         label = _("Accent / Active Color") },
    }

    -- Shared helpers ------------------------------------------------------------
    local function _openInputDialog(role, label_str)
        local ok_id, InputDialog = pcall(require, "ui/widget/inputdialog")
        local ok_ui, UIManager   = pcall(require, "ui/uimanager")
        local ok_hs, HS          = pcall(require, "sui_homescreen")
        if not (ok_id and ok_ui) then return end

        local key     = _ROLE_KEYS[role]
        local current = (key and SUISettings:get(key)) or ""
        local dlg
        dlg = InputDialog:new{
            title       = label_str,
            input       = current,
            input_hint  = _("e.g. #F5F0E8  or #1C1C1E  (empty = reset)"),
            description = _("Enter a hex color (#RRGGBB). On greyscale e-ink the perceived brightness is used."),
            buttons     = {{
                {
                    text     = _("Cancel"),
                    callback = function() UIManager:close(dlg) end,
                },
                {
                    text             = _("Apply"),
                    is_enter_default = true,
                    callback         = function()
                        local v = dlg:getInputText():gsub("%s", "")
                        M.setThemeColor(role, v ~= "" and v or nil)
                        UIManager:close(dlg)
                        if ok_hs and HS and HS.rebuildLayout then
                            HS.rebuildLayout()
                        end
                    end,
                },
            }},
        }
        UIManager:show(dlg)
    end

    local function _makeRow(role_def)
        local role      = role_def.role
        local label_str = role_def.label
        return {
            text_func = function()
                local key = _ROLE_KEYS[role]
                local hex = key and SUISettings:get(key)
                -- Show the stored hex + edit pencil when a custom value is set.
                -- When using a fallback we show a subtle "(fallback)" note.
                if hex and hex ~= "" then
                    return label_str .. "  [" .. hex .. "]  \u{270E}"
                end
                -- Visual hint when this role inherits from a fallback.
                local fb = _FALLBACKS[role]
                if fb then
                    local fb_key = _ROLE_KEYS[fb[1]]
                    if fb_key and SUISettings:get(fb_key) then
                        return label_str .. "  \u{21B3}"   -- ↳ (inherits)
                    end
                end
                return label_str
            end,
            keep_menu_open = true,
            callback = function()
                _openInputDialog(role, label_str)
            end,
        }
    end

    -- ── Build item list ───────────────────────────────────────────────────
    local items = {}

    -- Quick-fill preset submenu at the top.
    items[#items + 1] = {
        text = _("Apply Palette…"),
        sub_item_table_func = function()
            local preset_items = {}
            for _, preset in ipairs(_PRESETS) do
                local _preset = preset
                preset_items[#preset_items + 1] = {
                    text           = _preset.label,
                    keep_menu_open = true,
                    callback       = function()
                        for role, hex in pairs(_preset.colors) do
                            M.setThemeColor(role, hex)
                        end
                        local ok_ui, UIManager = pcall(require, "ui/uimanager")
                        local ok_hs, HS        = pcall(require, "sui_homescreen")
                        if ok_ui and UIManager then UIManager:setDirty("all", "ui") end
                        if ok_hs and HS and HS.rebuildLayout then HS.rebuildLayout() end
                    end,
                }
            end
            return preset_items
        end,
    }

    -- Individual role rows — no section titles.
    for _, role_def in ipairs(_ROLES) do
        items[#items + 1] = _makeRow(role_def)
    end

    -- Reset all at the bottom.
    items[#items + 1] = {
        text     = _("Reset All Theme Colors"),
        callback = function()
            local ok_ui, UIManager = pcall(require, "ui/uimanager")
            local ok_hs, HS        = pcall(require, "sui_homescreen")
            M.resetTheme()
            if ok_ui and UIManager then UIManager:setDirty("all", "ui") end
            if ok_hs and HS and HS.rebuildLayout then HS.rebuildLayout() end
        end,
    }

--]==]
-- Disabled stubs so callers don't error:
function M.setThemeColor(role, hex) end  -- stub: disabled
function M.resetTheme() end              -- stub: disabled
function M.makeThemeMenuItems() return {} end  -- stub: disabled

-- ---------------------------------------------------------------------------
-- Icon Packs
-- ---------------------------------------------------------------------------

local function _isIconFile(fname)
    return fname:match("%.[Ss][Vv][Gg]$") ~= nil
        or fname:match("%.[Pp][Nn][Gg]$") ~= nil
end

local _ACTION_SET = {
    library=true, homescreen=true, collections=true, history=true, continue=true,
    favorites=true, bookmark_browser=true, wifi_toggle=true, wifi_toggle_off=true, frontlight=true,
    night_mode=true,
    stats_calendar=true, power=true, browse_authors=true, browse_series=true, browse_tags=true,
    settings=true,
}

-- Maps icon-pack filename identifiers to internal action ids when they differ.
-- "sui_action_library.svg" is the public icon name for the "home" (Library) action.
local _ICON_ID_ALIAS = { library = "home", settings = "sui_settings" }

local function _filenameToKey(fname)
    local stem = fname:match("^(.+)%.[^%.]+$") or fname
    for _, s in ipairs(M.SLOTS) do
        if s.id == stem then return "simpleui_sysicon_" .. stem, "sysicon" end
    end
    local action_id = stem:match("^sui_action_(.+)$")
    if action_id and _ACTION_SET[action_id] then
        local internal_id = _ICON_ID_ALIAS[action_id] or action_id
        return "simpleui_action_" .. internal_id .. "_icon", "action"
    end
    return nil, nil
end

function M.getPacksDir()
    local ok, DS = pcall(require, "datastorage")
    if not ok or not DS then return nil end
    local lfs = require("libs/libkoreader-lfs")
    local dir = DS:getSettingsDir() .. "/simpleui/sui_icons/packs"
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    return dir
end

local function _loadManifest(pack_dir)
    local lfs = require("libs/libkoreader-lfs")
    local path = pack_dir .. "/pack.lua"
    if lfs.attributes(path, "mode") ~= "file" then return {} end
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then return data end
    logger.warn("sui_style: invalid pack.lua in", pack_dir)
    return {}
end

function M.listPacks()
    local dir = M.getPacksDir()
    if not dir then return {} end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dir, "mode") ~= "directory" then return {} end

    local packs = {}
    for fname in lfs.dir(dir) do
        if fname ~= "." and fname ~= ".." then
            local full = dir .. "/" .. fname
            local attr = lfs.attributes(full)
            if attr then
                if attr.mode == "directory" then
                    local has_icon = false
                    for f2 in lfs.dir(full) do
                        if _isIconFile(f2) then has_icon = true; break end
                    end
                    if has_icon then
                        local manifest = _loadManifest(full)
                        packs[#packs + 1] = {
                            name   = (type(manifest.name) == "string" and manifest.name ~= "") and manifest.name or fname,
                            path   = full,
                            is_zip = false,
                        }
                    end
                end
            end
        end
    end
    table.sort(packs, function(a, b) return a.name:lower() < b.name:lower() end)
    return packs
end

local function _applyFromDir(pack_dir)
    local lfs = require("libs/libkoreader-lfs")
    local manifest  = _loadManifest(pack_dir)
    local file_map  = (type(manifest.map) == "table") and manifest.map or {}
    local result    = { applied = 0, skipped = 0, errors = 0 }
    local done_keys = {}

    for slot_id, rel_fname in pairs(file_map) do
        local settings_key = _filenameToKey(slot_id)
        if settings_key then
            local full_path    = pack_dir .. "/" .. rel_fname
            if lfs.attributes(full_path, "mode") == "file" then
                SUISettings:set(settings_key, full_path)
                done_keys[settings_key] = true
                result.applied = result.applied + 1
            else
                result.errors = result.errors + 1
            end
        else
            result.errors = result.errors + 1
        end
    end

    pcall(function()
        for fname in lfs.dir(pack_dir) do
            if fname ~= "." and fname ~= ".." and _isIconFile(fname) then
                local settings_key = _filenameToKey(fname)
                if settings_key then
                    if not done_keys[settings_key] then
                        local full_path = pack_dir .. "/" .. fname
                        if lfs.attributes(full_path, "mode") == "file" then
                            SUISettings:set(settings_key, full_path)
                            done_keys[settings_key] = true
                            result.applied = result.applied + 1
                        else
                            result.errors = result.errors + 1
                        end
                    end
                else
                    result.skipped = result.skipped + 1
                end
            end
        end
    end)
    return result
end

function M.installZip(zip_path)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(zip_path, "mode") ~= "file" then return nil, _("File not found: ") .. tostring(zip_path) end
    local ok_arc, Archiver = pcall(require, "ffi/archiver")
    if not ok_arc or not Archiver then return nil, _("ffi/archiver not available in this KOReader version") end
    local packs_dir = M.getPacksDir()
    if not packs_dir then return nil, _("Could not determine packs folder") end
    local arc = Archiver.Reader:new()
    if not arc:open(zip_path) then return nil, _("Could not open zip (invalid format or corrupted)") end
    local root_prefix = nil
    for entry in arc:iterate() do
        if entry.mode == "file" then
            local first_seg = entry.path:match("^([^/]+)/")
            if first_seg then
                if root_prefix == nil then root_prefix = first_seg
                elseif root_prefix ~= first_seg then root_prefix = false; break end
            else
                root_prefix = false; break
            end
        end
    end
    local zip_stem  = zip_path:match("([^/\\]+)%.[Zz][Ii][Pp]$") or "pack"
    local pack_name = (root_prefix and root_prefix ~= "") and root_prefix or zip_stem
    local dest_dir  = packs_dir .. "/" .. pack_name
    if lfs.attributes(dest_dir, "mode") ~= "directory" then lfs.mkdir(dest_dir) end
    local n_extracted = 0
    for entry in arc:iterate() do
        if entry.mode == "file" then
            local rel = entry.path
            if root_prefix and root_prefix ~= "" then
                local stripped = rel:match("^" .. root_prefix .. "/(.+)$")
                if stripped then rel = stripped else goto continue_entry end
            end
            if not rel:match("/") and rel ~= "" then
                if _isIconFile(rel) or rel == "pack.lua" then
                    arc:extractToPath(entry.path, dest_dir .. "/" .. rel)
                    n_extracted = n_extracted + 1
                end
            end
        end
        ::continue_entry::
    end
    return pack_name, dest_dir
end

function M.applyPack(pack_path)
    local lfs = require("libs/libkoreader-lfs")
    if not pack_path then return nil, _("pack_path not provided") end
    local attr = lfs.attributes(pack_path)
    if not attr then return nil, _("Path does not exist: ") .. tostring(pack_path) end
    local pack_dir
    if attr.mode == "directory" then
        pack_dir = pack_path
    elseif attr.mode == "file" and pack_path:lower():match("%.zip$") then
        local _name, dest_or_err = M.installZip(pack_path)
        if not _name then return nil, _("Error extracting zip: ") .. tostring(dest_or_err) end
        pack_dir = dest_or_err
    else
        return nil, _("Unsupported format (use a folder or a .zip file)")
    end
    if lfs.attributes(pack_dir, "mode") ~= "directory" then return nil, _("Pack folder not accessible: ") .. tostring(pack_dir) end
    return _applyFromDir(pack_dir)
end

return M
