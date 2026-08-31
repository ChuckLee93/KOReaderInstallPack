-- sui_cover_finder.lua — Simple UI
-- On-disk discovery of "what cover should represent this folder": either an
-- explicit `.cover.*` file, or a collage of the folder's book covers (this
-- one recurses into subfolders when "recursive cover" is enabled).
--
-- This is deliberately separate from sui_metadata_source: it answers "what
-- image files/cached cover blitbuffers exist under this real directory",
-- not "which books match this filter trail". A plain folder without any
-- bookinfo DB entries yet (freshly copied, never opened) still works here.
--
-- Public API
-- ----------
--   CoverFinder.findDotCover(dir_path) -> filepath | nil
--   CoverFinder.entriesWithNoFilter(menu, dir_path) -> entries | nil
--   CoverFinder.collectCovers(menu, dir_path, max_count, BookInfoManager) -> { {data,w,h}, ... }
--   CoverFinder.findCoverRecursive(menu, dir_path, depth, max_depth, BookInfoManager) -> {data,w,h} | nil
--   CoverFinder.clearCache()  -- call from M.invalidateCache()

local lfs = require("libs/libkoreader-lfs")

local CoverFinder = {}

-- Two-generation LRU cache pattern used throughout this module:
--   generation A is the active table; B is the previous one.
--   On overflow: B = A, A = {}, counter reset. Effective capacity ~2×MAX.
local _DIR_CACHE_MAX    = 300
local _cover_file_cache = {}
local _cfc_b            = {}
local _cfc_cnt          = 0

local function cfcGet(key) return _cover_file_cache[key] or _cfc_b[key] end
local function cfcSet(key, v)
    if _cfc_cnt >= _DIR_CACHE_MAX then
        _cfc_b            = _cover_file_cache
        _cover_file_cache = {}
        _cfc_cnt          = 0
    end
    _cover_file_cache[key] = v
    _cfc_cnt = _cfc_cnt + 1
end

function CoverFinder.clearCache()
    _cover_file_cache, _cfc_b, _cfc_cnt = {}, {}, 0
end

local _COVER_EXTS = { ".jpg", ".jpeg", ".png", ".webp", ".gif" }

-- Returns the path to a .cover.* file in dir_path, or nil.
function CoverFinder.findDotCover(dir_path)
    local cached = cfcGet(dir_path)
    if cached ~= nil then return cached or nil end
    local base = dir_path .. "/.cover"
    for i = 1, #_COVER_EXTS do
        local fname = base .. _COVER_EXTS[i]
        if lfs.attributes(fname, "mode") == "file" then
            cfcSet(dir_path, fname)
            return fname
        end
    end
    cfcSet(dir_path, false)
    return nil
end

-- Runs FileChooser:genItemTableFromPath with the status filter suppressed,
-- so books hidden by "show only new/reading" can still supply cover art.
-- Deliberately mutates the FileChooser *class* attribute (not the instance)
-- for the duration of the call — genItemTableFromPath reads it off the
-- class, and this runs synchronously with nothing else able to observe the
-- momentary change (Lua has no concurrency here).
local FileChooser   = require("ui/widget/filechooser")
local _EMPTY_FILTER = {}
function CoverFinder.entriesWithNoFilter(menu, dir_path)
    local saved = FileChooser.show_filter
    FileChooser.show_filter = _EMPTY_FILTER
    menu._dummy = true
    local entries = menu:genItemTableFromPath(dir_path)
    menu._dummy = false
    FileChooser.show_filter = saved
    return entries
end

-- Collect up to `needed` cached covers from dir_path recursively (files
-- first, then subdirs). Returns an array that may be shorter than needed.
local function collectCoversRecursive(menu, dir_path, depth, max_depth, needed, BookInfoManager)
    if depth > max_depth or needed <= 0 then return {} end
    local entries = CoverFinder.entriesWithNoFilter(menu, dir_path)
    if not entries then return {} end
    local covers  = {}
    local subdirs = {}
    for _, entry in ipairs(entries) do
        if entry.is_file or entry.file then
            local bi = BookInfoManager:getBookInfo(entry.path, true)
            if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                    and not bi.ignore_cover
                    and not BookInfoManager.isCachedCoverInvalid(bi, menu.cover_specs)
            then
                covers[#covers + 1] = { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h }
                if #covers >= needed then return covers end
            end
        elseif not entry.is_go_up then
            subdirs[#subdirs + 1] = entry
        end
    end
    for _, entry in ipairs(subdirs) do
        if #covers >= needed then break end
        local sub = collectCoversRecursive(
            menu, entry.path, depth + 1, max_depth, needed - #covers, BookInfoManager)
        for _, c in ipairs(sub) do
            covers[#covers + 1] = c
            if #covers >= needed then break end
        end
    end
    return covers
end
CoverFinder._collectCoversRecursive = collectCoversRecursive -- exposed for style resolution (quad vs single)

-- Find exactly one cover recursively (used on the bookless-folder path).
function CoverFinder.findCoverRecursive(menu, dir_path, depth, max_depth, BookInfoManager)
    local found = collectCoversRecursive(menu, dir_path, depth, max_depth, 1, BookInfoManager)
    return found[1]
end

-- Collect up to `max_count` covers from dir_path, including subfolders when
-- `recursive_enabled` is true (kept as an explicit arg — this module has no
-- opinion on where that setting lives; sui_foldercovers passes it in).
function CoverFinder.collectCovers(menu, dir_path, max_count, BookInfoManager, recursive_enabled)
    local covers  = {}
    local entries = CoverFinder.entriesWithNoFilter(menu, dir_path)
    if not entries then return covers end
    for _, entry in ipairs(entries) do
        if entry.is_file or entry.file then
            if #covers >= max_count then break end
            local bi = BookInfoManager:getBookInfo(entry.path, true)
            if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                    and not bi.ignore_cover
            then
                covers[#covers + 1] = { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h }
            end
        end
    end
    if #covers < max_count and recursive_enabled then
        for _, entry in ipairs(entries) do
            if not (entry.is_file or entry.file) and not entry.is_go_up then
                if #covers >= max_count then break end
                local sub = collectCoversRecursive(
                    menu, entry.path, 1, 3, max_count - #covers, BookInfoManager)
                for _, c in ipairs(sub) do
                    covers[#covers + 1] = c
                    if #covers >= max_count then break end
                end
            end
        end
    end
    return covers
end

return CoverFinder
