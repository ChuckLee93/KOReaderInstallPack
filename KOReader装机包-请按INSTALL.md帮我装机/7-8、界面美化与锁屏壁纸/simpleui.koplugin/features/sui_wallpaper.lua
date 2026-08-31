-- features/sui_wallpaper.lua — SimpleUI wallpaper feature module.
--
-- Owns all state and logic for the "Wallpaper" settings sub-page: the cached
-- background ImageWidget (plus its associated pre-scaled Blitbuffer used for
-- stretch mode), every simpleui_style_wallpaper_* / simpleui_wallpaper_*
-- setting getter/setter, the on-disk wallpaper directory scan, the
-- transparent-status-bar / transparent-navigation-bar settings (they only
-- ever have a visible effect while a wallpaper is active, so they live here
-- next to the settings that gate them, as part of the same sub-page), and
-- the night-mode hook that invalidates the cache when night mode is toggled.
--
-- All settings live under the "simpleui_style_wallpaper_*" namespace (plus
-- the standalone "simpleui_wallpaper_show_in_fm" key) — unchanged from
-- before this module existed, since these are user-persisted keys.
--
-- Consumers:
--   * engines/sui_screen_engine.lua — paints the wallpaper behind the
--     Homescreen / Custom Screens body, and derives ctx.has_wallpaper for
--     content modules from styleGetBgWidget().
--   * infra/sui_patches.lua — paints the same wallpaper behind FM,
--     Collections, History and other fullscreen overlays when
--     "Show in FM" is enabled.
--   * modules/module_collections.lua, modules/module_currently.lua,
--     modules/module_quote.lua, engines/sui_book_grid.lua — these never
--     talk to this module directly; they just read ctx.has_wallpaper,
--     which the homescreen engine computes from this module.
--   * features/library/sui_foldercovers.lua — checks styleGetWallpaperShowInFM
--     / styleGetBgWidget directly to decide whether to mask its title strip.
--   * screens/sui_menu.lua — builds the "Wallpaper" TouchMenu / MenuTable
--     entries, consumed both from the native KOReader menu and from the
--     SUIWindow-based Settings window (screens/sui_settings_window.lua).
--
-- Any setter here that affects what is on screen frees the cached
-- ImageWidget/Blitbuffer and asks the homescreen engine to rebuild its
-- layout via screens/sui_homescreen's ScreenEngine.rebuildLayout() — using a
-- lazy require() inside the function body (never at file scope), the same
-- pattern already used by features/sui_style.lua for the same purpose. This
-- is required because engines/sui_screen_engine.lua requires this module
-- directly; requiring it back at file scope would create a load-order cycle.

local Device      = require("device")
local logger       = require("logger")
local SUISettings  = require("infra/sui_store")
local ImageWidget  = require("ui/widget/imagewidget")
local UIManager    = require("ui/uimanager")
local lfs          = require("libs/libkoreader-lfs")
local Screen       = Device.screen

local M = {}

-- ---------------------------------------------------------------------------
-- Cache state
-- ---------------------------------------------------------------------------
local _style_bg_cache     = nil   -- cached ImageWidget for the current wallpaper
local _style_bg_cache_w   = 0     -- screen width  at cache-creation time
local _style_bg_cache_h   = 0     -- screen height at cache-creation time
local _style_bg_cache_nm  = nil   -- Screen.night_mode value at cache-creation time

-- Stretch implementation note:
-- KOReader's ImageWidget has no native "fill ignoring aspect ratio" mode —
-- scale_factor=nil and scale_factor=0 both produce a proportional fit.
-- True stretch is achieved by decoding the source image into a Blitbuffer and
-- calling bb:scale(sw, sh), which scales X and Y independently.  The scaled
-- bitmap is kept in _style_bg_cache_bb and freed together with the widget.
local _style_bg_cache_bb = nil   -- pre-scaled Blitbuffer for stretch mode (or nil)

-- Lazy reference to ffi/pic (used only for auto-rotate dimension probe).
local _pic = nil
local function _getPic()
    if not _pic then
        local ok, m = pcall(require, "ffi/pic")
        if ok then _pic = m end
    end
    return _pic
end

-- Setting readers — centralised so _styleGetBgWidget stays readable.
local function _wpStretch()     return SUISettings:isTrue("simpleui_style_wallpaper_stretch")        end
local function _wpAutoRotate()  return SUISettings:nilOrTrue("simpleui_style_wallpaper_autorotate")  end
local function _wpInvertNight() return SUISettings:isTrue("simpleui_style_wallpaper_invert_night")   end
local function _wpOpacity()     return SUISettings:readSetting("simpleui_style_wallpaper_opacity", 0) end

-- Returns DataStorage/simpleui/sui_wallpapers/, creating it if needed.
local function _styleWallpapersDir()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local dir
    if ok_ds and DataStorage then
        dir = DataStorage:getSettingsDir() .. "/simpleui/sui_wallpapers"
    else
        local src = debug.getinfo(1, "S").source or ""
        dir = (src:match("^@(.+/)[^/]+/[^/]+$") or "./") .. "sui_wallpapers"
    end
    if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    return dir
end

-- Returns the cached bg ImageWidget, or nil when unset.
-- Cache is keyed on (path, screen w/h, night-mode state) — any change to those
-- values triggers a rebuild. Setting changes (stretch, rotate, invert) always
-- call _styleFreeBgCache() before asking the engine to rebuild its layout, so
-- the next _styleGetBgWidget() call always reflects the current options.
local function _styleGetBgWidget()
    if not SUISettings:isTrue("simpleui_style_wallpaper_enabled") then return nil end
    local path = SUISettings:readSetting("simpleui_style_wallpaper")
    if not path then return nil end

    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local nm     = Screen.night_mode and true or false

    if _style_bg_cache
       and _style_bg_cache_w  == sw
       and _style_bg_cache_h  == sh
       and _style_bg_cache_nm == nm
    then
        return _style_bg_cache
    end

    -- Dimensions or night-mode state changed — rebuild.
    if _style_bg_cache    then _style_bg_cache:free()    end
    if _style_bg_cache_bb then _style_bg_cache_bb:free() end
    _style_bg_cache    = nil
    _style_bg_cache_bb = nil

    -- original_in_nightmode: true  = image is never inverted by KOReader.
    --                         false = KOReader inverts the image in night mode.
    local orig_nm = not _wpInvertNight()

    -- Auto-rotate: probe image dimensions and pick a rotation_angle so the
    -- image orientation best matches the current screen orientation.
    local rotation_angle = 0
    local img_w, img_h   = nil, nil
    local raw_bb         = nil
    local pic = _getPic()
    if pic then
        local ok_d, doc = pcall(pic.openDocument, path)
        if ok_d and doc then
            img_w, img_h = doc.width, doc.height
            doc:close()
        end
    end
    if not img_w or not img_h then
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if ok_ri and RenderImage then
        local ok_bb, bb = pcall(RenderImage.renderImageFile, RenderImage, path, false, nil, nil)
        if ok_bb and bb then
            img_w = bb:getWidth()
            img_h = bb:getHeight()
            raw_bb = bb
            end
        end
    end

    if _wpAutoRotate() and img_w and img_h and img_w > 0 and img_h > 0 then
        local img_landscape    = img_w > img_h
        local screen_landscape = sw    > sh
        if img_landscape ~= screen_landscape then
            rotation_angle = G_reader_settings:isTrue("imageviewer_rotation_landscape_invert")
                and -90 or 90
        end
    end

    local widget_opts
    if _wpStretch() and img_w and img_h and img_w > 0 and img_h > 0
       and (img_w ~= sw or img_h ~= sh)
    then
        -- True stretch: decode the raw bitmap and scale it to exact screen
        -- dimensions, distorting aspect ratio when necessary.
        -- rotation_angle is applied manually so the dimension probe above
        -- already accounts for it; we bake it into the bitmap here.
        local eff_w, eff_h = sw, sh
        if rotation_angle ~= 0 then eff_w, eff_h = sh, sw end

        local ok_ri, RenderImage = pcall(require, "ui/renderimage")
        if ok_ri and RenderImage then
            local ok_bb = true
            if not raw_bb then
                -- Decode at native resolution (no max-bounds) so we get the raw
                -- pixel data, then scale to exact eff_w×eff_h in one step.
                -- Passing width/height to renderImageFile would do a proportional
                -- fit first, producing a bitmap smaller than eff_w×eff_h, and
                -- the subsequent :scale() call would then distort unevenly.
                ok_bb, raw_bb = pcall(RenderImage.renderImageFile, RenderImage, path, false, nil, nil)
            end
            if ok_bb and raw_bb then
                local ok_sc, scaled = pcall(function() return raw_bb:scale(eff_w, eff_h) end)
                raw_bb:free()
                raw_bb = nil
                if ok_sc and scaled then
                    _style_bg_cache_bb = scaled
                    widget_opts = {
                        image                 = scaled,
                        width                 = sw,
                        height                = sh,
                        scale_factor          = 1,  -- bitmap is already exact sw×sh
                        file_do_cache         = false,
                        alpha                 = true,
                        original_in_nightmode = orig_nm,
                        rotation_angle        = rotation_angle,
                    }
                end
            end
        end
    end

    if raw_bb then
        pcall(function() raw_bb:free() end)
        raw_bb = nil
    end

    -- Fallback (stretch decode failed, or stretch disabled, or dimensions match):
    -- proportional fit via ImageWidget's built-in scaling.
    if not widget_opts then
        widget_opts = {
            file                  = path,
            width                 = sw,
            height                = sh,
            scale_factor          = 0,    -- proportional fit (letterbox/pillarbox)
            file_do_cache         = false,
            alpha                 = true,
            original_in_nightmode = orig_nm,
            rotation_angle        = rotation_angle,
        }
    end

    local ok, w = pcall(ImageWidget.new, ImageWidget, widget_opts)
    if ok and w then
        _style_bg_cache    = w
        _style_bg_cache_w  = sw
        _style_bg_cache_h  = sh
        _style_bg_cache_nm = nm
        return w
    end
    -- Build failed — clean up any decoded bitmap.
    if _style_bg_cache_bb then _style_bg_cache_bb:free(); _style_bg_cache_bb = nil end
    _style_bg_cache_w  = 0
    _style_bg_cache_h  = 0
    _style_bg_cache_nm = nil
    logger.warn("sui_style: cannot load wallpaper: " .. tostring(path))
    return nil
end

-- Frees the cached bg widget and any associated decode buffer.
local function _styleFreeBgCache()
    if _style_bg_cache    then _style_bg_cache:free()    end
    if _style_bg_cache_bb then _style_bg_cache_bb:free() end
    _style_bg_cache    = nil
    _style_bg_cache_bb = nil
    _style_bg_cache_w  = 0
    _style_bg_cache_h  = 0
    _style_bg_cache_nm = nil
end

-- Lazily asks the homescreen engine to free the cache (redundant but
-- harmless — see ScreenEngine.rebuildLayout()) and rebuild its layout so a
-- wallpaper setting change is visible immediately. Lazy-required so this
-- module never creates a load-order cycle with the engine, which requires
-- this module directly — same pattern as features/sui_style.lua.
local function _notifyLayoutChanged()
    local ok, HS = pcall(require, "screens/sui_homescreen")
    if ok and HS and HS.rebuildLayout then
        HS.rebuildLayout()
    end
end

-- ---------------------------------------------------------------------------
-- Public API — wallpaper options (consumed by sui_menu.lua and friends)
-- ---------------------------------------------------------------------------

function M.styleGetWallpaper()
    return SUISettings:readSetting("simpleui_style_wallpaper")
end

function M.styleSetWallpaper(path)
    SUISettings:saveSetting("simpleui_style_wallpaper", path)
    if not path then
        SUISettings:saveSetting("simpleui_statusbar_transparent", false)
        SUISettings:saveSetting("simpleui_navbar_transparent", false)
        SUISettings:saveSetting("simpleui_wallpaper_show_in_fm", false)
    end
    _styleFreeBgCache()
    _notifyLayoutChanged()
end

function M.styleGetWallpapersDir()
    return _styleWallpapersDir()
end

-- Raster formats accepted for wallpapers. Exported (not local) so callers
-- offering a file browser over the wallpapers directory — e.g. the
-- "Browse…" entry in screens/sui_menu.lua's Select Wallpaper submenu — stay
-- in sync with this list instead of duplicating it.
M.SUPPORTED_WALLPAPER_EXTS = { jpg=true, jpeg=true, png=true, bmp=true, gif=true, webp=true }

function M.styleScanWallpapers()
    local dir     = _styleWallpapersDir()
    local items   = {}
    local exts    = M.SUPPORTED_WALLPAPER_EXTS
    if lfs.attributes(dir, "mode") == "directory" then
        for fname in lfs.dir(dir) do
            -- lfs.dir() always yields "." and ".." — skip them explicitly so
            -- they are never matched against the extension table (a bare "."
            -- has no extension, but guard unconditionally for clarity).
            if fname ~= "." and fname ~= ".." then
                local ext = fname:match("%.([^%.]+)$")
                if ext and exts[ext:lower()] then
                    items[#items + 1] = {
                        label = fname:match("^(.+)%.[^%.]+$") or fname,
                        path  = dir .. "/" .. fname,
                    }
                end
            end
        end
        table.sort(items, function(a, b) return a.label:lower() < b.label:lower() end)
    end
    return items
end

--- Returns the cached background ImageWidget (or nil).
--- Consumed by sui_patches.lua to paint the wallpaper into FM and fullscreen overlay surfaces.
function M.styleGetBgWidget()
    return _styleGetBgWidget()
end

--- Returns the stored wallpaper opacity (0 = fully opaque, 1-99 = fade toward white).
--- Consumed by sui_patches.lua paint helpers.
function M.styleGetWallpaperOpacityValue()
    return _wpOpacity()
end

--- Consumed by sui_patches.lua to decide whether to paint the wallpaper into
--- fullscreen overlays (Collections, History, etc.) and the FM.
function M.styleGetWallpaperShowInFM()
    if not M.styleGetWallpaperEnabled() or not M.styleGetWallpaper() then return false end
    return SUISettings:isTrue("simpleui_wallpaper_show_in_fm")
end
function M.styleSetWallpaperShowInFM(on)
    SUISettings:saveSetting("simpleui_wallpaper_show_in_fm", on and true or false)
end

function M.styleGetWallpaperEnabled()
    return SUISettings:isTrue("simpleui_style_wallpaper_enabled")
end
function M.styleSetWallpaperEnabled(on)
    local is_on = on ~= false and true or false
    SUISettings:saveSetting("simpleui_style_wallpaper_enabled", is_on)
    if not is_on then
        SUISettings:saveSetting("simpleui_statusbar_transparent", false)
        SUISettings:saveSetting("simpleui_navbar_transparent", false)
        SUISettings:saveSetting("simpleui_wallpaper_show_in_fm", false)
    end
    _styleFreeBgCache()
    _notifyLayoutChanged()
end

function M.styleGetWallpaperStretch()
    return _wpStretch()
end
function M.styleSetWallpaperStretch(on)
    SUISettings:saveSetting("simpleui_style_wallpaper_stretch", on ~= false and true or false)
    _styleFreeBgCache()
    _notifyLayoutChanged()
end

function M.styleGetWallpaperAutoRotate()
    return _wpAutoRotate()
end
function M.styleSetWallpaperAutoRotate(on)
    SUISettings:saveSetting("simpleui_style_wallpaper_autorotate", on ~= false and true or false)
    _styleFreeBgCache()
    _notifyLayoutChanged()
end

function M.styleGetWallpaperInvertNight()
    return _wpInvertNight()
end
function M.styleSetWallpaperInvertNight(on)
    SUISettings:saveSetting("simpleui_style_wallpaper_invert_night", on and true or false)
    _styleFreeBgCache()
    _notifyLayoutChanged()
end

function M.styleGetWallpaperOpacity()
    return _wpOpacity()
end
function M.styleSetWallpaperOpacity(val)
    SUISettings:saveSetting("simpleui_style_wallpaper_opacity", math.max(0, math.min(99, val or 0)))
    -- Opacity is applied at paint-time (not baked into the ImageWidget cache),
    -- but a setDirty alone is not sufficient when called from a SpinWidget
    -- callback — the homescreen instance may not be in the foreground repaint
    -- queue at that point.  Use the same rebuild path as every other
    -- wallpaper setter so the change is always visible immediately.
    _notifyLayoutChanged()
end

--- Frees the internal wallpaper widget cache.
--- Must be called after changing the simpleui_style_* keys directly
--- in SUISettings (e.g. after applying a preset), so that the next paint
--- rebuilds the ImageWidget with the new wallpaper.
--- Consumed by engines/sui_screen_engine.lua (rotation handling,
--- ScreenEngine.rebuildLayout()).
function M.freeCache()
    _styleFreeBgCache()
end

-- ---------------------------------------------------------------------------
-- Transparent bars — these only ever apply while a wallpaper is active (a
-- transparent bar with no wallpaper behind it would just show the plain
-- background), so they live here rather than in the homescreen engine, next
-- to the settings that gate them. They are part of the same "Wallpaper"
-- settings sub-page as every other option above.
--
-- Split into two independent settings (status bar / navigation bar).
-- Migration: if the old unified "simpleui_bars_transparent" key is present
-- we copy its value to both new keys once, then delete the legacy key so
-- it doesn't interfere on subsequent launches.
-- ---------------------------------------------------------------------------
do
    local legacy = "simpleui_bars_transparent"
    if SUISettings:get(legacy) ~= nil then
        local v = SUISettings:isTrue(legacy)
        SUISettings:saveSetting("simpleui_statusbar_transparent", v)
        SUISettings:saveSetting("simpleui_navbar_transparent",    v)
        SUISettings:del(legacy)
    end
end

function M.styleStatusbarTransparent()
    if not M.styleGetWallpaperEnabled() or not M.styleGetWallpaper() then return false end
    return SUISettings:isTrue("simpleui_statusbar_transparent")
end

function M.styleSetStatusbarTransparent(on)
    SUISettings:saveSetting("simpleui_statusbar_transparent", on and true or false)
    _styleFreeBgCache()
    _notifyLayoutChanged()
end

function M.styleNavbarTransparent()
    if not M.styleGetWallpaperEnabled() or not M.styleGetWallpaper() then return false end
    return SUISettings:isTrue("simpleui_navbar_transparent")
end

function M.styleSetNavbarTransparent(on)
    SUISettings:saveSetting("simpleui_navbar_transparent", on and true or false)
    _styleFreeBgCache()
    _notifyLayoutChanged()
end

-- ---------------------------------------------------------------------------
-- Night-mode hook — free the wallpaper cache whenever night mode is toggled
-- so the next _styleGetBgWidget() call rebuilds with the correct inversion
-- state (original_in_nightmode reflects the new setting).
-- ---------------------------------------------------------------------------
local _orig_UIManager_ToggleNightMode = UIManager.ToggleNightMode
function UIManager:ToggleNightMode()
    _orig_UIManager_ToggleNightMode(self)
    _styleFreeBgCache()
    _notifyLayoutChanged()
end

local _orig_UIManager_SetNightMode = UIManager.SetNightMode
if _orig_UIManager_SetNightMode then
    function UIManager:SetNightMode(nightmode)
        _orig_UIManager_SetNightMode(self, nightmode)
        _styleFreeBgCache()
        _notifyLayoutChanged()
    end
end

return M
