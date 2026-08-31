-- sui_presets.lua — SimpleUI Presets
--
-- This module contains two independent preset systems with the same
-- architecture: snapshot → storage in a single key → restore.
--
-- ══════════════════════════════════════════════════════════════════════════
-- 1. HOMESCREEN PRESETS  (SUIPresets)
-- ══════════════════════════════════════════════════════════════════════════
-- Saves and restores complete snapshots of the homescreen configuration.
-- Covers: modules, order, quick actions per slot, wallpaper, transparent bars.
-- Does NOT include: topbar/bottombar, the preset storage key itself.
-- Storage: "simpleui_hs_presets" → { [name] = {k=v, ...}, ... }
--
-- API:
--   SUIPresets.save(name)       SUIPresets.apply(name)    SUIPresets.delete(name)
--   SUIPresets.listNames()      SUIPresets.exists(name)   SUIPresets.rename(old,new)
--   SUIPresets.getAll()
--
-- ══════════════════════════════════════════════════════════════════════════
-- 2. ICON PRESETS  (SUIIconPresets)
-- ══════════════════════════════════════════════════════════════════════════
-- Saves and restores snapshots of all icon customizations:
--   • System icon overrides      simpleui_sysicon_*
--   • Default action icon overr. simpleui_action_*_icon
--   • Custom QA icon fields      simpleui_qa_<id>.icon  (only the icon field)
-- Does NOT include: labels, paths/collections of CQAs, the storage key itself.
-- Storage: "simpleui_icon_presets" → { [name] = {_scalar={}, _cqa={}}, ... }
--
-- API:
--   SUIIconPresets.save(name)           SUIIconPresets.apply(name, QA_module)
--   SUIIconPresets.delete(name)         SUIIconPresets.listNames()
--   SUIIconPresets.exists(name)         SUIIconPresets.rename(old, new)
--   SUIIconPresets.getAll()

local SUISettings = require("sui_store")
local logger      = require("logger")
local _           = require("sui_i18n").translate

-- ============================================================================
-- § 1  HOMESCREEN PRESETS
-- ============================================================================

local HS_PRESET_KEY = "simpleui_hs_presets"

local HS_PREFIXES = {
    "simpleui_hs_",
    "simpleui_style_",
}

local HS_EXACT = {
    ["simpleui_layout"]                 = true,
    ["simpleui_statusbar_transparent"]  = true,
    ["simpleui_navbar_transparent"]     = true,
    ["simpleui_wallpaper_show_in_fm"]   = true,  -- "show wallpaper in file manager" toggle
    ["simpleui_coll_list"]           = true,
    ["simpleui_coll_badge_position"] = true,
    ["simpleui_coll_badge_color"]    = true,
    ["simpleui_coll_badge_hidden"]   = true,
    ["simpleui_reading_goals_show_annual"]  = true,
    ["simpleui_reading_goals_show_monthly"] = true,
    ["simpleui_reading_goals_show_daily"]   = true,
    ["simpleui_reading_goals_layout"]       = true,
    ["simpleui_qa_row_instances"]           = true,
    ["simpleui_spacer_row_instances"]       = true,
}

local function _hsMatchesKey(key)
    if HS_EXACT[key] then return true end
    for _i, pfx in ipairs(HS_PREFIXES) do
        if key:sub(1, #pfx) == pfx then
            if key == HS_PRESET_KEY then return false end
            if key == HS_PRESET_KEY or key == "simpleui_hs_active_preset" then return false end
            return true
        end
    end
    return false
end

local function _getDirs()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds or not DataStorage then return nil, nil end
    local base = DataStorage:getSettingsDir() .. "/simpleui/sui_presets"
    local exp_dir = base .. "/sui_presets_export"
    local imp_dir = base .. "/sui_presets_import"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs then
        if lfs.attributes(base, "mode") ~= "directory" then lfs.mkdir(base) end
        if lfs.attributes(exp_dir, "mode") ~= "directory" then lfs.mkdir(exp_dir) end
        if lfs.attributes(imp_dir, "mode") ~= "directory" then lfs.mkdir(imp_dir) end
    end
    return exp_dir, imp_dir
end

local function _getExportDir()
    local exp, _ = _getDirs()
    return exp
end

local function _getImportDir()
    local _, imp = _getDirs()
    return imp
end

local function _listImportFiles(suffix)
    local dir = _getImportDir()
    local files = {}
    if not dir then return files end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return files end
    local pattern = suffix and (suffix:gsub("%.", "%%.") .. "$") or "%.lua$"
    if lfs.attributes(dir, "mode") == "directory" then
        for fname in lfs.dir(dir) do
            if fname ~= "." and fname ~= ".." and fname:lower():match(pattern:lower()) then
                files[#files + 1] = {
                    name = fname,
                    path = dir .. "/" .. fname
                }
            end
        end
        table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)
    end
    return files
end

local function _countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local SUIPresets = {}

local BUILTIN_PRESETS = {
    {
        id = "builtin_at_a_glance",
        name = _("At a Glance"),
        desc = _("Clock") .. ", " .. _("Currently Reading") .. ", " .. _("Recent Books"),
        layout = { pages = { { id = 1, modules = { "clock", "currently", "recent" } } } },
        settings = {
            simpleui_hs_clock_scale = 100,
            simpleui_hide_label_clock = false,
            simpleui_hs_currently_show_title = true,
            simpleui_hs_currently_show_author = true,
            simpleui_hs_currently_show_progress = true,
            simpleui_hs_currently_show_percent = true,
            simpleui_hs_currently_show_book_days = false,
            simpleui_hs_currently_show_book_time = false,
            simpleui_hs_currently_show_book_remaining = false,
            simpleui_hs_currently_bar_style = "with_pct",
            simpleui_hs_currently_stats_style = "default",
            simpleui_hs_currently_elem_order = { "title", "author", "progress", "percent" },
            simpleui_hs_currently_scale = 100,
            simpleui_hs_currently_thumb_scale = 100,
            simpleui_hs_currently_item_label_scale = 100,
            simpleui_hs_currently_show_frame = false,
            simpleui_hs_currently_solid_bg = false,
            simpleui_hide_label_currently = false,
            simpleui_hs_recent_show_progress = true,
            simpleui_hs_recent_show_text = true,
            simpleui_hs_recent_show_overlay = false,
            simpleui_hs_recent_scale = 100,
            simpleui_hs_recent_thumb_scale = 100,
            simpleui_hs_recent_item_label_scale = 100,
            simpleui_hs_recent_show_frame = false,
            simpleui_hs_recent_solid_bg = false,
            simpleui_hide_label_recent = false,
        }
    },
    {
        id = "builtin_mindful_reading",
        name = _("Mindful Reading"),
        desc = _("Quote of the Day") .. ", " .. _("Currently Reading") .. ", " .. _("Recent Books"),
        layout = { pages = { { id = 1, modules = { "quote", "currently", "recent" } } } },
        settings = {
            simpleui_hs_quote_source = "quotes",
            simpleui_hs_quote_align = "center",
            simpleui_hs_currently_show_title = true,
            simpleui_hs_currently_show_author = true,
            simpleui_hs_currently_show_progress = false,
            simpleui_hs_currently_show_percent = false,
            simpleui_hs_currently_show_book_days = true,
            simpleui_hs_currently_show_book_time = true,
            simpleui_hs_currently_show_book_remaining = false,
            simpleui_hs_currently_bar_style = "simple",
            simpleui_hs_currently_stats_style = "compact",
            simpleui_hs_currently_elem_order = { "title", "author", "book_days", "book_time" },
            simpleui_hs_currently_scale = 100,
            simpleui_hs_currently_thumb_scale = 100,
            simpleui_hs_currently_item_label_scale = 100,
            simpleui_hs_currently_show_frame = false,
            simpleui_hs_currently_solid_bg = false,
            simpleui_hide_label_currently = false,
            simpleui_hs_recent_show_progress = false,
            simpleui_hs_recent_show_text = false,
            simpleui_hs_recent_show_overlay = false,
            simpleui_hs_recent_scale = 100,
            simpleui_hs_recent_thumb_scale = 100,
            simpleui_hs_recent_item_label_scale = 100,
            simpleui_hs_recent_show_frame = false,
            simpleui_hs_recent_solid_bg = false,
            simpleui_hide_label_recent = false,
        }
    },
    {
        id = "builtin_momentum",
        name = _("Momentum"),
        desc = _("Cover Deck") .. ", " .. _("Reading Goals") .. ", " .. _("Reading Stats"),
        layout = { pages = { { id = 1, modules = { "coverdeck", "reading_goals", "reading_stats" } } } },
        settings = {
            simpleui_hs_coverdeck_source = "recent",
            simpleui_hs_coverdeck_title_pos = "above",
            simpleui_hs_coverdeck_main_order = { "title", "author", "covers", "progress", "stats" },
            simpleui_hs_coverdeck_show_title = false,
            simpleui_hs_coverdeck_show_author = false,
            simpleui_hs_coverdeck_show_progress = true,
            simpleui_hs_coverdeck_show_percent = true,
            simpleui_hs_coverdeck_show_book_days = true,
            simpleui_hs_coverdeck_show_book_time = false,
            simpleui_hs_coverdeck_show_book_remaining = false,
            simpleui_hs_coverdeck_stats_order = { "percent", "book_days" },
            simpleui_hs_coverdeck_scale = 100,
            simpleui_hs_coverdeck_thumb_scale = 100,
            simpleui_hs_coverdeck_item_label_scale = 100,
            simpleui_hide_label_coverdeck = false,
        }
    },
    {
        id = "builtin_library_view",
        name = _("Library View"),
        desc = _("Cover Deck") .. ", " .. _("Recent Books"),
        layout = { pages = { { id = 1, modules = { "coverdeck", "recent" } } } },
        settings = {
            simpleui_hs_coverdeck_source = "tbr",
            simpleui_hs_coverdeck_title_pos = "below",
            simpleui_hs_coverdeck_main_order = { "covers", "title", "author", "progress", "stats" },
            simpleui_hs_coverdeck_show_title = true,
            simpleui_hs_coverdeck_show_author = false,
            simpleui_hs_coverdeck_show_progress = false,
            simpleui_hs_coverdeck_show_percent = false,
            simpleui_hs_coverdeck_show_book_days = false,
            simpleui_hs_coverdeck_show_book_time = false,
            simpleui_hs_coverdeck_show_book_remaining = false,
            simpleui_hs_coverdeck_stats_order = {},
            simpleui_hs_coverdeck_scale = 100,
            simpleui_hs_coverdeck_thumb_scale = 100,
            simpleui_hs_coverdeck_item_label_scale = 100,
            simpleui_hide_label_coverdeck = false,
            simpleui_hs_recent_show_progress = true,
            simpleui_hs_recent_show_text = true,
            simpleui_hs_recent_show_overlay = false,
            simpleui_hs_recent_scale = 100,
            simpleui_hs_recent_thumb_scale = 100,
            simpleui_hs_recent_item_label_scale = 100,
            simpleui_hs_recent_show_frame = false,
            simpleui_hs_recent_solid_bg = false,
            simpleui_hide_label_recent = false,
        }
    }
}

local function isBuiltinName(name)
    for _, bp in ipairs(BUILTIN_PRESETS) do
        if bp.name == name then return true end
    end
    return false
end

function SUIPresets.getAll()
    local v = SUISettings:get(HS_PRESET_KEY)
    return type(v) == "table" and v or {}
end

function SUIPresets.save(name)
    if type(name) ~= "string" or name == "" then
        logger.warn("simpleui/presets: save() called with invalid name")
        return false
    end
    local snapshot = {}
    for k, v in SUISettings:iterateKeys() do
        if _hsMatchesKey(k) then
            if type(v) == "table" then
                local copy = {}
                for ki, vi in pairs(v) do copy[ki] = vi end
                snapshot[k] = copy
            else
                snapshot[k] = v
            end
        end
    end
    local presets = SUIPresets.getAll()
    presets[name] = snapshot
    SUISettings:set(HS_PRESET_KEY, presets)
    logger.dbg("simpleui/presets: saved preset '", name, "' with", _countKeys(snapshot), "keys")
    return true
end

function SUIPresets.apply(name)
    if type(name) ~= "string" or name == "" then return false end
    local presets  = SUIPresets.getAll()
    local snapshot = presets[name]
    if type(snapshot) ~= "table" then
        logger.warn("simpleui/presets: apply() — preset '", name, "' not found")
        return false
    end
    local to_delete = {}
    for k in SUISettings:iterateKeys() do
        if _hsMatchesKey(k) then to_delete[#to_delete + 1] = k end
    end
    for _i, k in ipairs(to_delete) do SUISettings:del(k) end
    for k, v in pairs(snapshot) do SUISettings:set(k, v) end
    logger.dbg("simpleui/presets: applied preset '", name, "'")
    return true
end

function SUIPresets.applyBuiltin(id)
    local bp = nil
    for _, b in ipairs(BUILTIN_PRESETS) do
        if b.id == id then bp = b; break end
    end
    if not bp then return false end

    SUISettings:set("simpleui_layout", bp.layout)

    local active_set = {}
    for _, page in ipairs(bp.layout.pages) do
        for _, mod_id in ipairs(page.modules) do
            active_set[mod_id] = true
        end
    end

    local Registry = require("desktop_modules/moduleregistry")
    local flat_order = {}
    for _, page in ipairs(bp.layout.pages) do
        for _, mod_id in ipairs(page.modules) do table.insert(flat_order, mod_id) end
    end
    for _, mod in ipairs(Registry.list()) do
        if not active_set[mod.id] then table.insert(flat_order, mod.id) end
        local is_active = (active_set[mod.id] == true)
        if type(mod.setEnabled) == "function" then mod.setEnabled("simpleui_hs_", is_active)
        elseif mod.enabled_key then SUISettings:set("simpleui_hs_" .. mod.enabled_key, is_active) end
    end
    SUISettings:set("simpleui_hs_module_order", flat_order)

    if bp.settings then
        for k, v in pairs(bp.settings) do
            SUISettings:set(k, v)
        end
    end
    SUISettings:flush()
    return true
end

function SUIPresets.delete(name)
    if type(name) ~= "string" or name == "" then return end
    local presets = SUIPresets.getAll()
    if presets[name] then
        presets[name] = nil
        SUISettings:set(HS_PRESET_KEY, presets)
        logger.dbg("simpleui/presets: deleted preset '", name, "'")
    end
end

function SUIPresets.rename(old_name, new_name)
    if type(old_name) ~= "string" or old_name == "" then return false end
    if type(new_name) ~= "string" or new_name == "" then return false end
    if old_name == new_name then return true end
    local presets = SUIPresets.getAll()
    if not presets[old_name] then return false end
    presets[new_name] = presets[old_name]
    presets[old_name] = nil
    SUISettings:set(HS_PRESET_KEY, presets)
    return true
end

function SUIPresets.exists(name)
    if type(name) ~= "string" or name == "" then return false end
    return SUIPresets.getAll()[name] ~= nil
end

function SUIPresets.listNames()
    local names = {}
    for name in pairs(SUIPresets.getAll()) do names[#names + 1] = name end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

function SUIPresets.export(name)
    local dir = _getExportDir()
    if not dir then return nil, _("No export directory") end
    local preset = SUIPresets.getAll()[name]
    if not preset then return nil, _("Preset not found") end

    local filename = name:gsub("[^%w_.-]", "_") .. "_sui_hs.lua"
    local filepath = dir .. "/" .. filename

    local ok, LuaSettings = pcall(require, "luasettings")
    if not ok or not LuaSettings then return nil, _("LuaSettings module unavailable") end

    local f = LuaSettings:open(filepath)
    f:saveSetting("type", "simpleui_homescreen_preset")
    f:saveSetting("name", name)
    f:saveSetting("data", preset)
    f:flush()
    return filepath
end

function SUIPresets.import(filepath)
    local ok, LuaSettings = pcall(require, "luasettings")
    if not ok or not LuaSettings then return nil, _("LuaSettings module unavailable") end

    local f = LuaSettings:open(filepath)
    local typ = f:readSetting("type")
    if typ ~= "simpleui_homescreen_preset" then
        return nil, _("Invalid preset file")
    end
    local name = f:readSetting("name") or "Imported Preset"
    local data = f:readSetting("data")
    if type(data) ~= "table" then return nil, _("Invalid data") end

    local presets = SUIPresets.getAll()
    local final_name = name
    local i = 1
    while presets[final_name] do
        final_name = name .. " (" .. i .. ")"
        i = i + 1
    end
    presets[final_name] = data
    SUISettings:set(HS_PRESET_KEY, presets)
    return final_name
end

function SUIPresets.getBuiltinPresets()
    return BUILTIN_PRESETS
end

-- ============================================================================
-- § 2  ICON PRESETS
-- ============================================================================

local ICON_PRESET_KEY  = "simpleui_icon_presets"
local ICON_PREFIXES    = { "simpleui_sysicon_", "simpleui_action_" }
local CQA_PREFIX       = "simpleui_qa_"
local CQA_LIST_KEY     = "simpleui_qa_list"

local function _isScalarIconKey(key)
    if key == ICON_PRESET_KEY then return false end
    for _i, pfx in ipairs(ICON_PREFIXES) do
        if key:sub(1, #pfx) == pfx then return true end
    end
    return false
end

local function _isCQAKey(key)
    return key ~= ICON_PRESET_KEY
        and key ~= CQA_LIST_KEY
        and key:sub(1, #CQA_PREFIX) == CQA_PREFIX
end

local SUIIconPresets = {}

function SUIIconPresets.getAll()
    local v = SUISettings:get(ICON_PRESET_KEY)
    return type(v) == "table" and v or {}
end

--- Saves the current state of all icons as a preset with the given name.
function SUIIconPresets.save(name)
    if type(name) ~= "string" or name == "" then
        logger.warn("simpleui/icon_presets: save() invalid name")
        return false
    end
    local snapshot = { _scalar = {}, _cqa = {} }

    -- Scalar keys: sysicon overrides + default action icon overrides.
    for k, v in SUISettings:iterateKeys() do
        if _isScalarIconKey(k) then snapshot._scalar[k] = v end
    end

    -- .icon field of each CQA (without touching other fields).
    local cqa_list = SUISettings:get(CQA_LIST_KEY) or {}
    for _i, qa_id in ipairs(cqa_list) do
        local cfg = SUISettings:get(CQA_PREFIX .. qa_id)
        if type(cfg) == "table" and cfg.icon ~= nil then
            snapshot._cqa[qa_id] = cfg.icon
        end
    end

    local presets = SUIIconPresets.getAll()
    presets[name] = snapshot
    SUISettings:set(ICON_PRESET_KEY, presets)
    logger.dbg("simpleui/icon_presets: saved '", name, "'")
    return true
end

--- Applies an icon preset.
--- QA: sui_quickactions module (to invalidate the cache after changing CQAs).
function SUIIconPresets.apply(name, QA)
    if type(name) ~= "string" or name == "" then return false end
    local snapshot = SUIIconPresets.getAll()[name]
    if type(snapshot) ~= "table" then
        logger.warn("simpleui/icon_presets: apply() — '", name, "' not found")
        return false
    end

    -- 1. Clear all current scalar icon keys.
    local to_delete = {}
    for k in SUISettings:iterateKeys() do
        if _isScalarIconKey(k) then to_delete[#to_delete + 1] = k end
    end
    for _i, k in ipairs(to_delete) do SUISettings:del(k) end

    -- 2. Restore scalar keys.
    for k, v in pairs(snapshot._scalar or {}) do SUISettings:set(k, v) end

    -- 3. Apply .icon to each existing CQA; CQAs missing from snapshot → reset.
    local cqa_list = SUISettings:get(CQA_LIST_KEY) or {}
    local cqa_icons = snapshot._cqa or {}
    for _i, qa_id in ipairs(cqa_list) do
        local cfg = SUISettings:get(CQA_PREFIX .. qa_id)
        if type(cfg) == "table" then
            cfg.icon = cqa_icons[qa_id]  -- nil = reset para default
            SUISettings:set(CQA_PREFIX .. qa_id, cfg)
        end
    end

    -- 4. Invalidate QA cache.
    if QA and QA.invalidateCustomQACache then QA.invalidateCustomQACache() end

    logger.dbg("simpleui/icon_presets: applied '", name, "'")
    return true
end

function SUIIconPresets.delete(name)
    if type(name) ~= "string" or name == "" then return end
    local presets = SUIIconPresets.getAll()
    if presets[name] then
        presets[name] = nil
        SUISettings:set(ICON_PRESET_KEY, presets)
        logger.dbg("simpleui/icon_presets: deleted '", name, "'")
    end
end

function SUIIconPresets.rename(old_name, new_name)
    if type(old_name) ~= "string" or old_name == "" then return false end
    if type(new_name) ~= "string" or new_name == "" then return false end
    if old_name == new_name then return true end
    local presets = SUIIconPresets.getAll()
    if not presets[old_name] then return false end
    presets[new_name] = presets[old_name]
    presets[old_name] = nil
    SUISettings:set(ICON_PRESET_KEY, presets)
    return true
end

function SUIIconPresets.exists(name)
    if type(name) ~= "string" or name == "" then return false end
    return SUIIconPresets.getAll()[name] ~= nil
end

function SUIIconPresets.listNames()
    local names = {}
    for n in pairs(SUIIconPresets.getAll()) do names[#names + 1] = n end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

function SUIIconPresets.export(name)
    local dir = _getExportDir()
    if not dir then return nil, _("No export directory") end
    local preset = SUIIconPresets.getAll()[name]
    if not preset then return nil, _("Preset not found") end

    local filename = name:gsub("[^%w_.-]", "_") .. "_sui_icn.lua"
    local filepath = dir .. "/" .. filename

    local ok, LuaSettings = pcall(require, "luasettings")
    if not ok or not LuaSettings then return nil, _("LuaSettings module unavailable") end

    local f = LuaSettings:open(filepath)
    f:saveSetting("type", "simpleui_icon_preset")
    f:saveSetting("name", name)
    f:saveSetting("data", preset)
    f:flush()
    return filepath
end

function SUIIconPresets.import(filepath)
    local ok, LuaSettings = pcall(require, "luasettings")
    if not ok or not LuaSettings then return nil, _("LuaSettings module unavailable") end

    local f = LuaSettings:open(filepath)
    local typ = f:readSetting("type")
    if typ ~= "simpleui_icon_preset" then
        return nil, _("Invalid preset file")
    end
    local name = f:readSetting("name") or "Imported Icon Preset"
    local data = f:readSetting("data")
    if type(data) ~= "table" then return nil, _("Invalid data") end

    local presets = SUIIconPresets.getAll()
    local final_name = name
    local i = 1
    while presets[final_name] do
        final_name = name .. " (" .. i .. ")"
        i = i + 1
    end
    presets[final_name] = data
    SUISettings:set(ICON_PRESET_KEY, presets)
    return final_name
end

SUIPresets.getExportDir = _getExportDir
SUIPresets.getImportDir = _getImportDir
SUIPresets.listImportFiles = function() return _listImportFiles("_sui_hs.lua") end

-- ============================================================================
-- § 1b  HOMESCREEN PRESETS — KOReader menu item list
-- ============================================================================
-- Returns the canonical list of KOReader menu items for the Homescreen Presets
-- sub-menu.  Both sui_menu.lua (native KOReader menu) and sui_layout_editor.lua
-- (SUIWindow via C.MenuTable) call this function so the two surfaces are always
-- identical and never drift apart.
--
-- opts (all optional):
--   on_apply  function()  — called after a preset is successfully applied
--                           (sui_menu passes _applyFullLayoutRefresh;
--                            sui_layout_editor passes ctx.repaint)
--   on_save   function()  — called after save / update / rename / delete
--                           (useful for a SUIWindow to repaint its list)
--
-- Usage from a SUIWindow screen builder:
--
--   local SUIPresets = require("sui_presets")
--   local function buildPresets(ctx)
--       return C.MenuTable{
--           inner_w    = ctx.inner_w,
--           items      = SUIPresets.makeMenuItems{
--                            on_apply = function() ctx.repaint() end,
--                            on_save  = function() ctx.repaint() end,
--                        },
--           repaint    = function() ctx.repaint() end,
--           push_stack = function(_, params)
--               table.insert(st.settings_stack, params)
--               ctx.repaint()
--           end,
--           on_close   = function() ctx.pop() end,
--       }
--   end
--
function SUIPresets.makeMenuItems(opts)
    opts = opts or {}
    local on_apply       = opts.on_apply       or function() end
    local on_save        = opts.on_save        or function() end
    local lock_overlay   = opts.lock_overlay   or function() end
    local unlock_overlay = opts.unlock_overlay or function() end

    local UIManager   = require("ui/uimanager")
    local function InfoMessage()  return require("ui/widget/infomessage")  end
    local function ConfirmBox()   return require("ui/widget/confirmbox")   end
    local function InputDialog()  return require("ui/widget/inputdialog")  end
    local T = require("ffi/util").template

    -- Helpers: wrap UIManager:show/close with overlay lock so that the
    -- SUIWindow onTapOutside doesn't fire while a dialog is visible.
    local function showDialog(d)
        lock_overlay()
        UIManager:show(d)
    end
    local function closeDialog(d)
        UIManager:close(d)
        unlock_overlay()
    end

    local items = {}
    local names = SUIPresets.listNames()

    -- ── Select Preset ─────────────────────────────────────────────────
    local select_items = {}
    
    for _, bp in ipairs(BUILTIN_PRESETS) do
        local _bp = bp
        select_items[#select_items + 1] = {
            text_func    = function() return _bp.name .. "\n" .. _bp.desc end,
            radio        = true,
            checked_func = function() return SUISettings:get("simpleui_hs_active_preset") == _bp.id end,
            callback = function()
                SUIPresets.applyBuiltin(_bp.id)
                SUISettings:set("simpleui_hs_active_preset", _bp.id)
                UIManager:nextTick(on_apply)
            end,
        }
    end

    if #BUILTIN_PRESETS > 0 and #names > 0 then
        select_items[#select_items].separator = true
    end

    for _i, name in ipairs(names) do
        local _name = name
        select_items[#select_items + 1] = {
            text_func    = function() return _name end,
            radio        = true,
            checked_func = function()
                return SUISettings:get("simpleui_hs_active_preset") == _name
            end,
            callback = function()
                if SUIPresets.apply(_name) then
                    SUISettings:set("simpleui_hs_active_preset", _name)
                    UIManager:nextTick(on_apply)
                else
                    showDialog(InfoMessage():new{
                        text    = string.format(_("Preset \"%s\" not found."), _name),
                        timeout = 2,
                    })
                end
            end,
        }
    end

    items[#items + 1] = {
        text           = _("Select Preset"),
        enabled        = #names > 0 or #BUILTIN_PRESETS > 0,
        dim            = #names == 0 and #BUILTIN_PRESETS == 0,
        sub_item_table = select_items,
        separator      = true,
        sui_build      = opts.lock_overlay and function(ctx, _item)
            local SUIWindow = require("sui_window")
            return SUIWindow.ListRow{
                title        = _("Select Preset"),
                inner_w      = ctx.inner_w,
                show_chevron = true,
                on_tap       = function()
                    ctx.push("nested_menu", {
                        title = _("Select Preset"),
                        items_func = function()
                            return {
                                {
                                    text = "Items List",
                                    sui_build = function(ctx2)
                                        local SUIWindow2 = require("sui_window")
                                        local rows = {}
                                        
                                        local current_names = SUIPresets.listNames()

                                        for _, bp in ipairs(BUILTIN_PRESETS) do
                                            rows[#rows + 1] = SUIWindow2.ListRow{
                                                title    = bp.name,
                                                subtitle = bp.desc,
                                                inner_w  = ctx2.inner_w,
                                                radio    = true,
                                                checked  = (SUISettings:get("simpleui_hs_active_preset") == bp.id),
                                                on_tap   = function()
                                                    SUIPresets.applyBuiltin(bp.id)
                                                    SUISettings:set("simpleui_hs_active_preset", bp.id)
                                                    ctx2.repaint()
                                                    UIManager:nextTick(on_apply)
                                                end,
                                            }
                                        end
            
                                        if #BUILTIN_PRESETS > 0 and #current_names > 0 then
                                            rows[#rows].separator = true
                                            if SUIWindow2.SectionLabel then
                                                rows[#rows + 1] = SUIWindow2.SectionLabel{
                                                    text    = _("My Presets"):upper(),
                                                    inner_w = ctx2.inner_w,
                                                }
                                            else
                                                rows[#rows + 1] = SUIWindow2.ListRow{
                                                    title   = _("My Presets"):upper(),
                                                    inner_w = ctx2.inner_w,
                                                    enabled = false,
                                                }
                                            end
                                        end
                                        
                                        for _, name in ipairs(current_names) do
                                            local _name = name
                                            rows[#rows + 1] = SUIWindow2.ListRow{
                                                title   = _name,
                                                inner_w = ctx2.inner_w,
                                                radio   = true,
                                                checked = (SUISettings:get("simpleui_hs_active_preset") == _name),
                                                on_tap  = function()
                                                    if SUIPresets.apply(_name) then
                                                        SUISettings:set("simpleui_hs_active_preset", _name)
                                                        ctx2.repaint()
                                                        UIManager:nextTick(on_apply)
                                                    else
                                                        showDialog(InfoMessage():new{ text = string.format(_("Preset \"%s\" not found."), _name), timeout = 2 })
                                                    end
                                                end,
                                            }
                                        end
                                        return rows
                                    end
                                }
                            }
                        end
                    })
                end
            }
        end or nil,
    }

    -- ── Save as new preset ────────────────────────────────────────────
    items[#items + 1] = {
        text            = _("Save as new preset"),
        keep_menu_open  = true,
        callback = function()
            local dialog
            dialog = InputDialog():new{
                title      = _("Save preset"),
                input      = "",
                input_hint = _("Preset name"),
                buttons    = {{
                    {
                        text     = _("Cancel"),
                        id       = "close",
                        callback = function() closeDialog(dialog) end,
                    },
                    {
                        text             = _("Save"),
                        is_enter_default = true,
                        callback         = function()
                            local name = dialog:getInputText()
                            name = name and name:match("^%s*(.-)%s*$") or ""
                            if name == "" then
                                showDialog(InfoMessage():new{
                                    text    = _("Please enter a name for the preset."),
                                    timeout = 2,
                                })
                                return
                            end
                            if isBuiltinName(name) then
                                showDialog(InfoMessage():new{
                                    text    = _("This name is reserved by a built-in preset."),
                                    timeout = 2,
                                })
                                return
                            end
                            local function doSave()
                                SUIPresets.save(name)
                                SUISettings:set("simpleui_hs_active_preset", name)
                                closeDialog(dialog)
                                showDialog(InfoMessage():new{
                                    text    = string.format(_("Preset \"%s\" saved."), name),
                                    timeout = 2,
                                })
                                UIManager:nextTick(on_save)
                            end
                            if SUIPresets.exists(name) then
                                showDialog(ConfirmBox():new{
                                    text        = string.format(
                                        _("A preset named \"%s\" already exists.\nOverwrite it?"), name),
                                    ok_text     = _("Overwrite"),
                                    cancel_text = _("Cancel"),
                                    ok_callback = doSave,
                                    cancel_callback = function() unlock_overlay() end,
                                })
                            else
                                doSave()
                            end
                        end,
                    },
                }},
            }
            showDialog(dialog)
        end,
    }

    -- ── Manage presets ────────────────────────────────────────────────
    if #names > 0 then
        items[#items + 1] = {
            text = _("Manage presets"),
            sub_item_table_func = function()
                local sub = {}
                for _i, name in ipairs(SUIPresets.listNames()) do
                    local _name = name
                    sub[#sub + 1] = {
                        text = _name,
                        sub_item_table = {
                            { text = _("Update with current settings"), callback = function()
                                showDialog(ConfirmBox():new{
                                    text = string.format(_("Overwrite preset \"%s\" with the current homescreen settings?"), _name),
                                    ok_text     = _("Overwrite"),
                                    cancel_text = _("Cancel"),
                                    ok_callback = function()
                                        unlock_overlay()
                                        SUIPresets.save(_name)
                                        SUISettings:set("simpleui_hs_active_preset", _name)
                                        showDialog(InfoMessage():new{ text = string.format(_("Preset \"%s\" updated."), _name), timeout = 2 })
                                        UIManager:nextTick(on_save)
                                    end,
                                    cancel_callback = function() unlock_overlay() end,
                                })
                            end },
                            { text = _("Rename"), callback = function()
                                local d
                                d = InputDialog():new{
                                    title = string.format(_("Rename \"%s\""), _name),
                                    input = _name,
                                    buttons = {{
                                        { text = _("Cancel"), id = "close", callback = function() closeDialog(d) end },
                                        { text = _("Rename"), is_enter_default = true, callback = function()
                                            local new_name = d:getInputText()
                                            new_name = new_name and new_name:match("^%s*(.-)%s*$") or ""
                                            if new_name == "" or new_name == _name then closeDialog(d); return end
                                            if isBuiltinName(new_name) then
                                                showDialog(InfoMessage():new{ text = _("This name is reserved by a built-in preset."), timeout = 2 })
                                                return
                                            end
                                            if SUIPresets.exists(new_name) then
                                                showDialog(InfoMessage():new{ text = string.format(_("A preset named \"%s\" already exists."), new_name), timeout = 2 })
                                                return
                                            end
                                            SUIPresets.rename(_name, new_name)
                                            local active = SUISettings:get("simpleui_hs_active_preset")
                                            if active == _name then SUISettings:set("simpleui_hs_active_preset", new_name) end
                                            closeDialog(d)
                                            UIManager:nextTick(on_save)
                                        end },
                                    }},
                                }
                                showDialog(d)
                                d:onShowKeyboard()
                            end },
                            { text = _("Delete"), callback = function()
                                showDialog(ConfirmBox():new{
                                    text        = string.format(_("Delete preset \"%s\"?"), _name),
                                    ok_text     = _("Delete"),
                                    cancel_text = _("Cancel"),
                                    ok_callback = function()
                                        unlock_overlay()
                                        SUIPresets.delete(_name)
                                        local active = SUISettings:get("simpleui_hs_active_preset")
                                        if active == _name then SUISettings:del("simpleui_hs_active_preset") end
                                        UIManager:nextTick(on_save)
                                    end,
                                    cancel_callback = function() unlock_overlay() end,
                                })
                            end },
                        }
                    }
                end
                return sub
            end,
            sui_build = opts.lock_overlay and function(ctx, _item)
                local SUIWindow = require("sui_window")
                return SUIWindow.ListRow{
                    title        = _("Manage presets"),
                    inner_w      = ctx.inner_w,
                    show_chevron = true,
                    on_tap       = function()
                        ctx.push("nested_menu", {
                            title = _("Manage presets"),
                            items_func = function()
                                return {
                                    {
                                        text = "Items List",
                                        sui_build = function(ctx2)
                                            local SUIWindow2 = require("sui_window")
                                            local rows = {}
                                            for _k, _name in ipairs(SUIPresets.listNames()) do
                                                rows[#rows + 1] = SUIWindow2.ListRow{
                                                    title     = _name,
                                                    inner_w   = ctx2.inner_w,
                                                    on_delete = function()
                                                        showDialog(ConfirmBox():new{
                                                            text        = string.format(_("Delete preset \"%s\"?"), _name),
                                                            ok_text     = _("Delete"),
                                                            cancel_text = _("Cancel"),
                                                            ok_callback = function()
                                                                unlock_overlay()
                                                                SUIPresets.delete(_name)
                                                                local active = SUISettings:get("simpleui_hs_active_preset")
                                                                if active == _name then SUISettings:del("simpleui_hs_active_preset") end
                                                                ctx2.repaint()
                                                                UIManager:nextTick(on_save)
                                                            end,
                                                            cancel_callback = function() unlock_overlay() end,
                                                        })
                                                    end,
                                                    on_edit = function()
                                                        local d
                                                        d = InputDialog():new{
                                                            title = string.format(_("Rename \"%s\""), _name),
                                                            input = _name,
                                                            buttons = {{
                                                                { text = _("Cancel"), id = "close", callback = function() closeDialog(d) end },
                                                                { text = _("Rename"), is_enter_default = true, callback = function()
                                                                    local new_name = d:getInputText()
                                                                    new_name = new_name and new_name:match("^%s*(.-)%s*$") or ""
                                                                    if new_name == "" or new_name == _name then closeDialog(d); return end
                                                            if isBuiltinName(new_name) then
                                                                UIManager:show(InfoMessage():new{ text = _("This name is reserved by a built-in preset."), timeout = 2 })
                                                                return
                                                            end
                                                                    if SUIPresets.exists(new_name) then
                                                                        showDialog(InfoMessage():new{ text = string.format(_("A preset named \"%s\" already exists."), new_name), timeout = 2 })
                                                                        return
                                                                    end
                                                                    SUIPresets.rename(_name, new_name)
                                                                    local active = SUISettings:get("simpleui_hs_active_preset")
                                                                    if active == _name then SUISettings:set("simpleui_hs_active_preset", new_name) end
                                                                    closeDialog(d)
                                                                    ctx2.repaint()
                                                                    UIManager:nextTick(on_save)
                                                                end }
                                                            }}
                                                        }
                                                        showDialog(d)
                                                        d:onShowKeyboard()
                                                    end,
                                                    on_update = function()
                                                        showDialog(ConfirmBox():new{
                                                            text = string.format(_("Overwrite preset \"%s\" with the current homescreen settings?"), _name),
                                                            ok_text     = _("Overwrite"),
                                                            cancel_text = _("Cancel"),
                                                            ok_callback = function()
                                                                unlock_overlay()
                                                                SUIPresets.save(_name)
                                                                SUISettings:set("simpleui_hs_active_preset", _name)
                                                                showDialog(InfoMessage():new{ text = string.format(_("Preset \"%s\" updated."), _name), timeout = 2 })
                                                                ctx2.repaint()
                                                                UIManager:nextTick(on_save)
                                                            end,
                                                            cancel_callback = function() unlock_overlay() end,
                                                        })
                                                    end,
                                                }
                                            end
                                            if #rows == 0 then
                                                rows[#rows + 1] = SUIWindow2.ListRow{ title = _("No presets found."), inner_w = ctx2.inner_w }
                                            end
                                            return rows
                                        end
                                    }
                                }
                            end
                        })
                    end
                }
            end or nil,
        }
    end

    -- ── Import ────────────────────────────────────────────────────────
    items[#items + 1] = {
        text = _("Import preset"),
        sub_item_table_func = function()
            local sub   = {}
            local files = SUIPresets.listImportFiles()

            if #files == 0 then
                sub[#sub + 1] = {
                    text    = T(_("No preset files found.\nPlace .lua files in:\n%1"),
                                SUIPresets.getImportDir() or ""),
                    enabled = false,
                }
            else
                for _i, f in ipairs(files) do
                    local _f = f
                    sub[#sub + 1] = {
                        text            = _f.name,
                        keep_menu_open  = true,
                        callback = function()
                            local imported_name, err = SUIPresets.import(_f.path)
                            if imported_name then
                                showDialog(InfoMessage():new{
                                    text    = string.format(_("Preset \"%s\" imported."), imported_name),
                                    timeout = 3,
                                })
                                UIManager:nextTick(on_save)
                            else
                                showDialog(InfoMessage():new{
                                    text    = _("Error importing preset: ") .. tostring(err),
                                    timeout = 4,
                                })
                            end
                        end,
                    }
                end
            end
            return sub
        end,
        separator = true,
    }

    -- ── Export ────────────────────────────────────────────────────────
    if #names > 0 then
        items[#items + 1] = {
            text = _("Export preset"),
            sub_item_table_func = function()
                local sub = {}
                for _i, name in ipairs(SUIPresets.listNames()) do
                    local _name = name
                    sub[#sub + 1] = {
                        text     = _name,
                        callback = function()
                            local filepath, err = SUIPresets.export(_name)
                            if filepath then
                                UIManager:show(InfoMessage():new{
                                    text    = string.format(_("Preset exported to:\n%s"), filepath),
                                    timeout = 4,
                                })
                            else
                                UIManager:show(InfoMessage():new{
                                    text    = _("Error exporting preset: ") .. tostring(err),
                                    timeout = 4,
                                })
                            end
                        end,
                    }
                end
                return sub
            end,
        }
    end

    return items
end

SUIIconPresets.getExportDir = _getExportDir
SUIIconPresets.getImportDir = _getImportDir
SUIIconPresets.listImportFiles = function() return _listImportFiles("_sui_icn.lua") end

-- ============================================================================
-- Exports
-- ============================================================================

return {
    -- Homescreen presets (compatibility with existing code that does
    -- local P = require("sui_presets") and calls P.save / P.apply / etc.)
    save      = SUIPresets.save,
    apply     = SUIPresets.apply,
    delete    = SUIPresets.delete,
    listNames = SUIPresets.listNames,
    exists    = SUIPresets.exists,
    rename    = SUIPresets.rename,
    getAll    = SUIPresets.getAll,
    export    = SUIPresets.export,
    import    = SUIPresets.import,
    getExportDir    = _getExportDir,
    getImportDir    = _getImportDir,
    listImportFiles = SUIPresets.listImportFiles,
    getBuiltinPresets = SUIPresets.getBuiltinPresets,
        applyBuiltin = SUIPresets.applyBuiltin,

    -- Homescreen preset menu items (shared between sui_menu and sui_layout_editor)
    makeMenuItems = SUIPresets.makeMenuItems,
    icons = SUIIconPresets,
}
