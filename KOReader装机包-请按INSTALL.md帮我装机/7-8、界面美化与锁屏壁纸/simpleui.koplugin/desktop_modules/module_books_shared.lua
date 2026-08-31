-- module_books_shared.lua — Simple UI
-- Helpers shared by the Currently Reading and Recent Books modules:
-- cover loading, book data, progress bar, prefetch, formatTimeLeft.
-- Not a module — no id or build(). Pure shared utilities.

local BD             = require("ui/bidi")
local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local lfs             = require("libs/libkoreader-lfs")
local util            = require("util")
local Config          = require("sui_config")
local SUIStyle        = require("sui_style")

local math_floor = math.floor
local math_max   = math.max
local math_min   = math.min

-- Returns the KOBO_VIRTUAL:// path for a real kepub filepath when the
-- kobo.koplugin is active, or the original filepath otherwise.
-- This ensures that covers and sidecars are looked up via the virtual path
-- (which the kobo.koplugin's BookInfoManager patch understands), and that
-- openBook always passes a virtual path to DocumentRegistry so DRM
-- decryption is triggered correctly.
local function _koboVirtualPath(fp)
    local ok, PluginLoader = pcall(require, "pluginloader")
    if not ok or not PluginLoader then return fp end
    local kobo = PluginLoader:getPluginInstance("kobo_plugin")
    if not kobo or not kobo.virtual_library then return fp end
    local vl = kobo.virtual_library
    if vl:isVirtualPath(fp) then return fp end
    if not next(vl.virtual_to_real) then
        pcall(function() vl:buildPathMappings() end)
    end
    return vl:getVirtualPath(fp) or fp
end

local SH = {}

-- ---------------------------------------------------------------------------
-- applyCustomProps — overlay custom_metadata.lua overrides onto doc_props.
--
-- KOReader stores user-edited title/author in a *separate* file called
-- custom_metadata.lua (next to the main metadata.*.lua sidecar).  The
-- structure inside it is:
--   custom_props = { title = "...", authors = "..." }   <- user overrides
--   doc_props    = { title = "...", authors = "..." }   <- original copy
--
-- DS.open() only reads the main sidecar, so ds:readSetting("doc_props")
-- always returns the original (unedited) values.  We must open
-- custom_metadata.lua separately and let its custom_props win.
--
-- This mirrors what BookInfo.extendProps() does in KOReader core, which is
-- why History and the library show the correct custom values while SimpleUI
-- homescreen modules (Currently Reading, Recent) showed the originals.
-- ---------------------------------------------------------------------------
local _DS_for_custom = nil
local function _getDS()
    if not _DS_for_custom then
        local ok, ds = pcall(require, "docsettings")
        if ok then _DS_for_custom = ds end
    end
    return _DS_for_custom
end

local function applyCustomProps(fp, title, authors)
    local DS = _getDS()
    if not DS then return title, authors end
    -- findCustomMetadataFile is an instance method (:), so pass DS as self + fp as arg.
    local ok, custom_file = pcall(DS.findCustomMetadataFile, DS, fp)
    if not ok or not custom_file then return title, authors end
    -- openSettingsFile is a STATIC function (.), not an instance method.
    -- Correct call: DS.openSettingsFile(custom_file) — do NOT pass DS as first arg.
    local ok2, cs = pcall(DS.openSettingsFile, custom_file)
    if not ok2 or not cs then return title, authors end
    local custom_props = cs:readSetting("custom_props") or {}
    return custom_props.title   or title,
           custom_props.authors or authors
end

-- ---------------------------------------------------------------------------
-- Base dimensions — computed once at load time from device DPI.
-- These are the 100%-scale reference values; never modify them at runtime.
-- ---------------------------------------------------------------------------
local _BASE_COVER_W  = Screen:scaleBySize(122)
local _BASE_COVER_H  = math_floor(Screen:scaleBySize(122) * 3 / 2)
local _BASE_RECENT_W = Screen:scaleBySize(75)
local _BASE_RECENT_H = Screen:scaleBySize(112)
local _BASE_RB_GAP1    = Screen:scaleBySize(4)
local _BASE_RB_BAR_H   = Screen:scaleBySize(5)
local _BASE_RB_GAP2    = Screen:scaleBySize(3)
local _BASE_RB_LABEL_H = Screen:scaleBySize(14)

-- Flat aliases kept for any call-site that reads SH.COVER_W etc. directly
-- without going through getDims(). These always reflect 100% scale and are
-- present only for backward-compat — new code should use getDims().
SH.COVER_W       = _BASE_COVER_W
SH.COVER_H       = _BASE_COVER_H
SH.RECENT_W      = _BASE_RECENT_W
SH.RECENT_H      = _BASE_RECENT_H
SH.RB_GAP1       = _BASE_RB_GAP1
SH.RB_BAR_H      = _BASE_RB_BAR_H
SH.RB_GAP2       = _BASE_RB_GAP2
SH.RECENT_CELL_H = _BASE_RECENT_H + _BASE_RB_GAP1 + _BASE_RB_BAR_H
                   + _BASE_RB_GAP2 + _BASE_RB_LABEL_H

-- ---------------------------------------------------------------------------
-- getDims(scale) — returns a table of scaled dimensions for one render pass.
-- Called at the top of build() / getHeight() in module_currently and
-- module_recent.  Keeps all math in one place; modules stay declarative.
--
-- scale: float from Config.getModuleScale() — e.g. 0.75, 1.0, 1.25.
-- Returns a plain table (no metatable overhead); keys mirror SH flat names.
-- ---------------------------------------------------------------------------
-- getDims(scale, thumb_scale)
-- scale:       overall module scale (affects everything)
-- thumb_scale: independent cover/thumbnail scale multiplier (affects cover dims only).
--              Text, progress bar and gaps follow only `scale`.
--              Pass nil or 1.0 to apply no thumb adjustment.
function SH.getDims(scale, thumb_scale)
    scale       = scale       or 1.0
    thumb_scale = thumb_scale or 1.0
    -- Combined scale applied to cover dimensions only.
    local cs = scale * thumb_scale
    if scale == 1.0 and thumb_scale == 1.0 then
        -- Fast path: return the pre-computed base values without any math.
        return {
            COVER_W       = _BASE_COVER_W,
            COVER_H       = _BASE_COVER_H,
            RECENT_W      = _BASE_RECENT_W,
            RECENT_H      = _BASE_RECENT_H,
            RB_GAP1       = _BASE_RB_GAP1,
            RB_BAR_H      = _BASE_RB_BAR_H,
            RB_GAP2       = _BASE_RB_GAP2,
            RB_LABEL_H    = _BASE_RB_LABEL_H,
            RECENT_CELL_H = SH.RECENT_CELL_H,
        }
    end
    -- Text/bar/gap dims scale with `scale` only — unaffected by thumb_scale.
    local g1  = math_max(1, math_floor(_BASE_RB_GAP1    * scale))
    local bh  = math_max(1, math_floor(_BASE_RB_BAR_H   * scale))
    local g2  = math_max(1, math_floor(_BASE_RB_GAP2    * scale))
    local lh  = math_max(1, math_floor(_BASE_RB_LABEL_H * scale))
    -- Cover dims scale with the combined scale (scale × thumb_scale).
    local rh  = math_floor(_BASE_RECENT_H * cs)
    -- RECENT_CELL_H = cover height + bar + gaps + label — each part scaled independently.
    return {
        COVER_W       = math_floor(_BASE_COVER_W  * cs),
        COVER_H       = math_floor(_BASE_COVER_H  * cs),
        RECENT_W      = math_floor(_BASE_RECENT_W * cs),
        RECENT_H      = rh,
        RB_GAP1       = g1,
        RB_BAR_H      = bh,
        RB_GAP2       = g2,
        RB_LABEL_H    = lh,
        RECENT_CELL_H = rh + g1 + bh + g2 + lh,
    }
end

local _CLR_COVER_BORDER = Blitbuffer.COLOR_BLACK
local _CLR_COVER_BG     = Blitbuffer.gray(0.88)

-- ---------------------------------------------------------------------------
-- vspan pool helper
-- ---------------------------------------------------------------------------
function SH.vspan(px, pool)
    if pool then
        if not pool[px] then pool[px] = VerticalSpan:new{ width = px } end
        return pool[px]
    end
    return VerticalSpan:new{ width = px }
end

-- ---------------------------------------------------------------------------
-- pctStr — canonical percentage formatter for book-progress values.
--
-- Uses string.format("%.0f", …) which delegates rounding to the C runtime
-- (round-half-away-from-zero on all platforms KOReader targets).  This is
-- correct for progress values such as 0.995 → "100%", 0.994 → "99%".
--
-- Always use this instead of math.floor(pct * 100) to avoid truncation bugs
-- (e.g. 0.569 stored as 0.5689999… truncates to 56 instead of rounding to 57).
-- ---------------------------------------------------------------------------
function SH.pctStr(pct)
    return string.format("%.0f%%", (pct or 0) * 100)
end

-- ---------------------------------------------------------------------------
-- coverPlaceholder
-- ---------------------------------------------------------------------------
-- Renders a FakeCover-style placeholder (mirroring KOReader's coverbrowser
-- mosaicmenu.lua FakeCover widget) for books that have no cover image.
-- Displays title and authors as text with decreasing font sizes until they
-- fit, at the 2:3 proportions used by the homescreen modules.
--
-- title   : book title string (or nil — filename used as fallback by callers)
-- authors : book authors string (or nil)
-- w, h    : exact pixel dimensions of the cell (should be ~2:3 ratio)
function SH.coverPlaceholder(title, authors, w, h)
    -- Backwards-compat: old call sites used (title, w, h) with 3 args.
    -- Detect by checking whether `authors` is a number (the old w slot).
    if type(authors) == "number" then
        h = w; w = authors; authors = nil
    end
    w = tonumber(w) or 100
    h = tonumber(h) or 150

    local border = SUIStyle.BADGE_BORDER_SZ
    -- Inner dimensions (FakeCover uses width/height = outer - 2*bordersize,
    -- since margin=0 and padding=0)
    local width  = w - 2 * border
    local height = h - 2 * border
    -- FakeCover uses 7/8 of width for text to leave lateral breathing room
    local text_width = math_floor(7 / 8 * width)

    -- BD-wrap title (mirrors FakeCover logic)
    local bd_wrap_title_as_filename = false
    if not title then
        title = authors  -- no title: treat authors string as title fallback
        authors = nil
        bd_wrap_title_as_filename = true
    end
    if title then
        -- filename-style cleanup when no authors
        if not authors then
            bd_wrap_title_as_filename = true
            title = title:gsub(" %- ", "\n")
            title = title:gsub("|", "\n")
            title = title:gsub("_", " ")
            title = title:gsub("%.", ".\u{200B}")
            title = title:gsub("%.\u{200B}(%w%w?%w?%w?%w?)$", "\u{200B}.%1")
        end
        title = bd_wrap_title_as_filename and BD.filename(title) or BD.auto(title)
    end
    if authors then
        if authors:find("\n") then
            local parts = util.splitToArray(authors, "\n")
            for i = 1, #parts do parts[i] = BD.auto(parts[i]) end
            if #parts > 3 then
                parts = { parts[1], parts[2], parts[3] .. " et al." }
            end
            authors = table.concat(parts, "\n")
        else
            authors = BD.auto(authors)
        end
    end

    -- The modules use a 2:3 cover proportion which is narrower than the
    -- mosaic grid cells FakeCover was designed for. Start with a slightly
    -- reduced font size so text fits comfortably without many loop iterations.
    local initial_sizedec = Screen:scaleBySize(4)
    local sizedec_step    = Screen:scaleBySize(2)
    local authors_font_max, authors_font_min = SUIStyle.FS_SUBTITLE, 6   -- 20 / 6
    local title_font_max,   title_font_min   = SUIStyle.FS_TITLE + 2, 10 -- 24 / 10 (slightly above FS_TITLE for cover prominence)
    local top_pad    = Size.padding.default
    local bottom_pad = Size.padding.default

    local authors_wg, title_wg
    local inter_pad = 0
    local sizedec   = initial_sizedec
    local loop2     = false

    while true do
        if authors_wg then authors_wg:free(true); authors_wg = nil end
        if title_wg   then title_wg:free(true);   title_wg   = nil end

        local texts_height = 0
        if authors then
            authors_wg = TextBoxWidget:new{
                text      = authors,
                face      = Font:getFace(SUIStyle.FACE_REGULAR, math_max(authors_font_max - sizedec, authors_font_min)),
                width     = text_width,
                alignment = "center",
                bgcolor   = nil,
                alpha     = true,
            }
            texts_height = texts_height + authors_wg:getSize().h
        end
        if title then
            title_wg = TextBoxWidget:new{
                text      = title,
                face      = Font:getFace(SUIStyle.FACE_REGULAR, math_max(title_font_max - sizedec, title_font_min)),
                width     = text_width,
                alignment = "center",
                bgcolor   = nil,
                alpha     = true,
            }
            texts_height = texts_height + title_wg:getSize().h
        end

        local free_height = height - texts_height
        if authors then free_height = free_height - top_pad    end
        inter_pad = math_floor(free_height / 2)

        local textboxes_ok = not (authors_wg and authors_wg.has_split_inside_word)
                          and not (title_wg   and title_wg.has_split_inside_word)

        if textboxes_ok and free_height > 0.2 * height then break end

        sizedec = sizedec + sizedec_step
        if sizedec > 20 + initial_sizedec then
            if not loop2 then
                loop2  = true
                sizedec = initial_sizedec
                if G_reader_settings:nilOrTrue("use_xtext") then
                    if title   then title   = title:gsub("_",   "_\u{200B}"):gsub("%.", ".\u{200B}") end
                    if authors then authors = authors:gsub("_", "_\u{200B}"):gsub("%.", ".\u{200B}") end
                else
                    if title   then title   = title:gsub("-",   " "):gsub("_", " ") end
                    if authors then authors = authors:gsub("-",  " "):gsub("_", " ") end
                end
            else
                break
            end
        end
    end

    local vgroup = VerticalGroup:new{}
    if authors then
        table.insert(vgroup, VerticalSpan:new{ width = top_pad })
        table.insert(vgroup, authors_wg)
    end
    table.insert(vgroup, VerticalSpan:new{ width = inter_pad })
    if title then
        table.insert(vgroup, title_wg)
    end
    table.insert(vgroup, VerticalSpan:new{ width = inter_pad })

    return FrameContainer:new{
        width      = w,
        height     = h,
        bordersize = border,
        margin     = 0,
        padding    = 0,
        color      = _CLR_COVER_BORDER,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = width, h = height },
            vgroup,
        },
    }
end

-- ---------------------------------------------------------------------------
-- getBookCover
-- ---------------------------------------------------------------------------
function SH.getBookCover(filepath, w, h, align, stretch_limit)
    -- Reserve 1px on each side for the border: request a bb that is 2px smaller.
    local inner_w = math_max(1, w - 2)
    local inner_h = math_max(1, h - 2)
    local bb = Config.getCoverBB(filepath, inner_w, inner_h, align, stretch_limit)
    if not bb then return nil end
    local ok, img = pcall(function()
        return require("ui/widget/imagewidget"):new{
            image            = bb,
            image_disposable = false,  -- bb is owned by the cover cache; must not be freed here
            width            = inner_w,
            height           = inner_h,
            -- bb is already scaled to exactly inner_w×inner_h by getCoverBB.
            scale_factor     = 1,
        }
    end)
    if not (ok and img) then return nil end
    -- padding=0 + bordersize=1: the FrameContainer outer size is inner_w+2 × inner_h+2 = w×h.
    return FrameContainer:new{
        bordersize = SUIStyle.BADGE_BORDER_SZ, color = _CLR_COVER_BORDER,
        padding    = 0, margin = 0,
        dimen      = Geom:new{ w = w, h = h },
        img,
    }
end

-- ---------------------------------------------------------------------------
-- formatTimeLeft
-- ---------------------------------------------------------------------------
function SH.formatTimeLeft(pct, pages, avg_time)
    if not avg_time or avg_time <= 0 or not pct or pct < 0 or not pages then return nil end
    local remaining = math_floor(pages * (1.0 - pct))
    if remaining <= 0 then return nil end
    local secs = math_floor(remaining * avg_time)
    if secs <= 0 then return nil end
    local h = math_floor(secs / 3600)
    local m = math_floor((secs % 3600) / 60)
    if h > 0 and m > 0 then return string.format("%dh %dm", h, m)
    elseif h > 0        then return string.format("%dh", h)
    else                     return string.format("%dm", m) end
end

-- ---------------------------------------------------------------------------
-- getBookData
-- ---------------------------------------------------------------------------
local _DocSettings = nil
local function getDocSettings()
    if not _DocSettings then
        local ok, ds = pcall(require, "docsettings")
        if ok then _DocSettings = ds end
    end
    return _DocSettings
end

-- BookInfoManager — same lazy-loader pattern as getDocSettings(). Used as a
-- fallback title/author source for files whose doc_props are still empty
-- (e.g. books added to the TBR collection that have never been opened in
-- ReaderUI, so KOReader never extracted their EPUB/PDF metadata into the
-- sidecar). BookInfoManager indexes metadata independently of doc_props —
-- this mirrors the pattern already used in sui_browsemeta.lua's title
-- resolution (bim:getBookInfo(fp, false)).
local _BookInfoManager = nil
local function getBookInfoManager()
    if not _BookInfoManager then
        local ok, bim = pcall(require, "bookinfomanager")
        if ok then _BookInfoManager = bim end
    end
    return _BookInfoManager
end

-- ---------------------------------------------------------------------------
-- Sidecar metadata cache — invalidated by mtime, lives for the process lifetime.
--
-- Each entry: { sidecar_path, mtime, preferred_loc, data={...} }
-- where data holds all keys extracted by prefetchBooks + summary for countMarkedRead.
--
-- Cost per cache hit: 1 lfs.attributes("modification") instead of ~15 syscalls
-- + 1 dofile. Cache miss falls through to the normal DS.open path.
-- ---------------------------------------------------------------------------
local _sidecar_cache = {}

-- Returns the preferred_location string used as part of cache validation.
-- Reading G_reader_settings is a table lookup — no IO.
local function _prefLoc()
    return G_reader_settings:readSetting("document_metadata_folder", "doc")
end

-- Returns cached data table for fp, or nil on miss / stale entry.
local function _cacheGet(fp)
    local e = _sidecar_cache[fp]
    if not e then return nil end
    -- Invalidate if the user changed metadata location between sessions.
    if e.preferred_loc ~= _prefLoc() then
        _sidecar_cache[fp] = nil
        return nil
    end
    -- 1 syscall: stat the sidecar file we recorded on last DS.open.
    local mtime = lfs.attributes(e.sidecar_path, "modification")
    if mtime ~= e.mtime then
        _sidecar_cache[fp] = nil
        return nil
    end
    -- Also invalidate when custom_metadata.lua has changed (user edited title/author).
    -- custom_mtime is nil when no custom_metadata.lua existed at cache-fill time;
    -- a new non-nil mtime means the file was just created → invalidate.
    if e.custom_mtime ~= lfs.attributes(e.custom_path or "", "modification") then
        _sidecar_cache[fp] = nil
        return nil
    end
    return e.data
end

-- Stores a cache entry after a successful DS.open.
-- source_candidate is ds.source_candidate (the winning sidecar path chosen by DS.open).
local function _cachePut(fp, source_candidate, data)
    if not source_candidate then return end
    local mtime = lfs.attributes(source_candidate, "modification")
    if not mtime then return end
    -- Also record the custom_metadata.lua path and mtime so _cacheGet can
    -- detect when the user edits title/author via "Book information".
    local DS_c = _getDS()
    local custom_path, custom_mtime
    if DS_c then
        local ok, cp = pcall(DS_c.findCustomMetadataFile, DS_c, fp)
        if ok and cp then
            custom_path  = cp
            custom_mtime = lfs.attributes(cp, "modification")
        end
    end
    _sidecar_cache[fp] = {
        sidecar_path  = source_candidate,
        mtime         = mtime,
        preferred_loc = _prefLoc(),
        custom_path   = custom_path,
        custom_mtime  = custom_mtime,
        data          = data,
    }
end

-- Expose the sidecar cache accessors as part of the module API so that
-- module_stats_provider can share the same cache in countMarkedReadBoth
-- without creating a circular dependency or reaching into internals.
-- These are considered semi-internal (prefix _) but are stable across versions.
SH._cacheGet = _cacheGet
SH._cacheGetRaw = function(fp)
    local e = _sidecar_cache[fp]
    return e and e.data
end
SH._cachePut = _cachePut


-- or flush everything (fp == nil).
function SH.invalidateSidecarCache(fp)
    if fp then
        _sidecar_cache[fp] = nil
    else
        _sidecar_cache = {}
    end
end

function SH.getBookData(filepath, prefetched)
    local meta = {}
    local percent, pages, md5, stat_pages, stat_total_time = 0, nil, nil, nil, nil

    if prefetched then
        -- Fast path: use data already extracted by prefetchBooks.
        percent         = prefetched.percent or 0
        pages           = prefetched.doc_pages
        md5             = prefetched.partial_md5_checksum
        stat_pages      = prefetched.stat_pages
        stat_total_time = prefetched.stat_total_time
        meta.title      = prefetched.title
        meta.authors    = prefetched.authors
    elseif prefetched ~= false then
        -- prefetched==nil means prefetchBooks was not called (e.g. direct call).
        -- prefetched==false means prefetchBooks tried but DS.open failed — skip
        -- the lfs.attributes syscall and DS.open retry; fall through with defaults.
        local DS = getDocSettings()
        if DS and lfs.attributes(filepath, "mode") == "file" then
            local ok2, ds = pcall(DS.open, DS, filepath)
            if ok2 and ds then
                percent         = ds:readSetting("percent_finished") or 0
                pages           = ds:readSetting("doc_pages")
                md5             = ds:readSetting("partial_md5_checksum")
                local rp        = ds:readSetting("doc_props") or {}
                local rs        = ds:readSetting("stats") or {}
                meta.title, meta.authors = applyCustomProps(filepath, rp.title, rp.authors)
                stat_pages      = rs.pages
                stat_total_time = rs.total_time_in_sec
            end
        end
    end

    if not meta.title or meta.title == "" then
        -- doc_props was empty — most likely this file was never opened in
        -- ReaderUI (e.g. a TBR entry), so KOReader never wrote real title/
        -- author metadata into the sidecar. Try BookInfoManager before
        -- falling back to the raw filename.
        local BIM = getBookInfoManager()
        if BIM then
            local ok3, bi = pcall(BIM.getBookInfo, BIM, filepath, false)
            if ok3 and bi and bi.title and bi.title ~= "" then
                meta.title   = bi.title
                meta.authors = meta.authors and meta.authors ~= "" and meta.authors or bi.authors
            end
        end
    end

    if not meta.title or meta.title == "" then
        meta.title = filepath:match("([^/]+)%.[^%.]+$") or "?"
    end

    local avg_time
    -- Source 1: live ReaderUI session — most accurate when a book is open.
    pcall(function()
        local ReaderUI = package.loaded["apps/reader/readerui"]
        if ReaderUI and ReaderUI.instance then
            local stats = ReaderUI.instance.statistics
            if stats and stats.avg_time and stats.avg_time > 0 then
                -- Only use if this is the same book currently being read.
                local rui_fp = ReaderUI.instance.document
                    and ReaderUI.instance.document.file
                if rui_fp == filepath then
                    avg_time = stats.avg_time
                end
            end
        end
    end)
    -- Source 2: doc settings stats (written by Statistics plugin on close).
    -- The capped avg_time from the stats DB is computed by fetchBookStats()
    -- in module_currently and passed back via bstats — callers that need
    -- the DB-backed value should use that instead of querying here again.
    if not avg_time and stat_pages and stat_pages > 0
            and stat_total_time and stat_total_time > 0 then
        avg_time = stat_total_time / stat_pages
    end

    return {
        percent  = percent,
        title    = meta.title,
        authors  = meta.authors or "",
        pages    = pages,
        avg_time = avg_time,
    }
end

-- ---------------------------------------------------------------------------
-- prefetchBooks — reads history, pre-extracts book metadata.
-- Called once per Homescreen render; result cached per open instance.
-- ---------------------------------------------------------------------------
-- NOTE: _cover_extraction_pending was removed from SH.
-- Use Config.cover_extraction_pending (the single source of truth) instead.

-- ---------------------------------------------------------------------------
-- Stale-data cache — mirrors module_stats_provider.lua's _cache/getStale()
-- pattern. Holds the last successful SH.prefetchBooks() result so callers
-- on the hot reader-return path (onCloseDocument, HomescreenWidget:onShow)
-- can render currently/coverdeck/recent with last-known-good data via
-- SH.getStaleBooks() — a plain table reference, zero ReadHistory walk, zero
-- lfs.attributes, zero sidecar cache lookups, zero new work of any kind.
-- The authoritative SH.prefetchBooks() call on the deferred ~50ms tick (see
-- _refresh() in sui_homescreen.lua) always still runs and overwrites this
-- cache with fresh data; getStaleBooks() is purely a synchronous-path
-- optimisation, never a substitute for it.
--
-- Unlike SP._cache (single shared state for the whole-app stats), this is
-- naturally per-(show_currently,show_recent,max_recent) call shape — but in
-- practice the homescreen always calls prefetchBooks with the same
-- (show_c, show_r, 15) triple, so a single last-result slot is sufficient,
-- exactly like SP's single _cache slot.
--
-- ── Cross-process-restart persistence ──────────────────────────────────────
-- _last_books_state is a plain Lua local: it lives only as long as this
-- module stays required, i.e. for the lifetime of the current KOReader
-- process. On a genuine cold start (KOReader just launched, this module's
-- first ever require in this run) it starts nil — exactly like SP._cache,
-- which also starts nil and makes reading_stats show zeros for one frame
-- on the very first onShow(). To avoid that one-time "zeros/placeholder"
-- flash on every fresh KOReader launch (not just on reader-return within an
-- already-running session, which the in-memory cache already covers for
-- free), the last state is ALSO mirrored to disk via sui_store, with two
-- deliberate performance constraints:
--
--   1. WRITE COST: _persistStaleBooks() below calls the underlying
--      LuaSettings:saveSetting() directly (bypassing SUISettings:set()/
--      :saveSetting(), which call :flush() on every write — see
--      sui_store.lua's comment on SUISettings:set()). saveSetting() alone
--      only mutates the in-memory settings table; zero disk I/O. This is
--      called every time prefetchBooks() succeeds, so the in-memory disk
--      mirror is always fresh, but at zero extra I/O cost over what was
--      already happening (none).
--   2. FLUSH COST: the actual fsync-to-disk (:flush()) is intentionally
--      NEVER triggered from this module. It piggy-backs on
--      SimpleUIPlugin:onSuspend() in main.lua, which already calls
--      SUISettings:flush() for the same reason every other plugin setting
--      gets persisted — device suspend is infrequent (not on the hot
--      reader-return path) and KOReader has idle time before sleeping.
--      Worst case if the device loses power before ever suspending: the
--      on-disk copy is simply absent or one session behind, and
--      getStaleBooks() falls back to nil exactly as SP.getStale() does —
--      callers render the same "no data yet" placeholder reading_stats
--      shows in that case, never a correctness issue, only a missed
--      optimisation for that one run.
--
-- Net effect: reading the persisted copy back costs one disk read,
-- performed AT MOST ONCE per process lifetime (lazy, on the first
-- getStaleBooks() call when the in-memory cache is still nil) — small,
-- bounded, and off the hot path entirely after that single read.
-- ---------------------------------------------------------------------------
local _last_books_state       = nil
local _disk_books_load_tried  = false  -- guards the single lazy disk read

local _STALE_BOOKS_SETTING_KEY = "simpleui_stale_books_v1"

-- Lazily resolve sui_store without a hard require at module load time, to
-- avoid any chance of a circular dependency between module_books_shared and
-- sui_store (sui_store has no reverse dependency today, but this keeps the
-- coupling defensive and consistent with the rest of this file's lazy-require
-- style, e.g. getDocSettings()).
local _SUIStore = nil
local function _getSUIStore()
    if not _SUIStore then
        local ok, m = pcall(require, "sui_store")
        if ok then _SUIStore = m end
    end
    return _SUIStore
end

-- Writes _last_books_state into the in-memory settings table only — see the
-- WRITE COST note above. Safe to call unconditionally after every
-- prefetchBooks() success; never performs disk I/O itself.
local function _persistStaleBooks(state)
    local SUIStore = _getSUIStore()
    if not SUIStore or not SUIStore.setNoFlush then return end
    -- prefetched_data values are plain strings/numbers/booleans only
    -- (percent, title, authors, doc_pages, partial_md5_checksum, stat_pages,
    -- stat_total_time, summary — see SH.getBookData()'s shape), so the whole
    -- table is safely serialisable by LuaSettings without any special-casing.
    pcall(SUIStore.setNoFlush, SUIStore, _STALE_BOOKS_SETTING_KEY, state)
end

-- Reads the on-disk mirror back exactly once per process lifetime. Returns
-- nil silently on any failure (missing key, corrupt entry, sui_store
-- unavailable) — callers already treat nil as "no stale data available" and
-- fall back accordingly, so this never needs to raise.
local function _loadStaleBooksFromDisk()
    _disk_books_load_tried = true
    local SUIStore = _getSUIStore()
    if not SUIStore then return nil end
    local ok, v = pcall(SUIStore.readSetting, SUIStore, _STALE_BOOKS_SETTING_KEY)
    if not ok or type(v) ~= "table" then return nil end
    return v
end

function SH.prefetchBooks(show_currently, show_recent, max_recent)
    max_recent = max_recent or 5
    local state = { current_fp = nil, recent_fps = {}, prefetched_data = {} }
    if not show_currently and not show_recent then return state end

    local ReadHistory = package.loaded["readhistory"] or require("readhistory")
    if not ReadHistory then return state end
    if not ReadHistory.hist or #ReadHistory.hist == 0 then
        pcall(function() ReadHistory:reload() end)
    end

    local DS = getDocSettings()
    -- hist[1] is the most recently read book.
    -- • show_currently=true  → claim it as current_fp; never add to recent_fps.
    -- • show_currently=false → treat it like any other entry for recent_fps.
    -- Always start at index 1 so hist[1] is never silently dropped.
    for i = 1, #(ReadHistory.hist or {}) do
        local entry = ReadHistory.hist[i]
        local fp = entry and entry.file
        if fp and lfs.attributes(fp, "mode") == "file" then
            -- Normalise to KOBO_VIRTUAL:// if this is a real kepub path saved
            -- by the kobo.koplugin into ReadHistory. Using the virtual path as
            -- the key ensures cover extraction and sidecar lookups go through
            -- the kobo.koplugin's BookInfoManager patch, and that openBook
            -- passes the correct path to DocumentRegistry for DRM decryption.
            fp = _koboVirtualPath(fp)
            if i == 1 and show_currently then
                -- Claim as currently-reading book.
                state.current_fp = fp
                if DS then
                    local cached = _cacheGet(fp)
                    if cached then
                        -- Re-apply custom props on the cache-hit path.
                        -- The cached title/authors may predate a metadata edit
                        -- or predate this fix. applyCustomProps is cheap (stat calls only).
                        local _ct, _ca = applyCustomProps(fp, cached.title, cached.authors)
                        if _ct ~= cached.title or _ca ~= cached.authors then
                            -- Clone only when values differ to avoid mutating the shared cache entry.
                            local patched = {}
                            for k, v in pairs(cached) do patched[k] = v end
                            patched.title   = _ct
                            patched.authors = _ca
                            state.prefetched_data[fp] = patched
                        else
                            state.prefetched_data[fp] = cached
                        end
                    else
                        local ok2, ds = pcall(DS.open, DS, fp)
                        if ok2 and ds then
                            local rp = ds:readSetting("doc_props") or {}
                            local rs = ds:readSetting("stats") or {}
                            local _t, _a = applyCustomProps(fp, rp.title, rp.authors)
                            local data = {
                                percent              = ds:readSetting("percent_finished") or 0,
                                title                = _t,
                                authors              = _a,
                                doc_pages            = ds:readSetting("doc_pages"),
                                partial_md5_checksum = ds:readSetting("partial_md5_checksum"),
                                stat_pages           = rs.pages,
                                stat_total_time      = rs.total_time_in_sec,
                                summary              = ds:readSetting("summary"),
                            }
                            _cachePut(fp, ds.source_candidate, data)
                            pcall(function() ds:close() end)
                            state.prefetched_data[fp] = data
                        else
                            -- Signal that DS.open was attempted but failed — getBookData
                            -- will skip the lfs.attributes syscall and DS.open retry.
                            state.prefetched_data[fp] = false
                        end
                    end
                end
            elseif show_recent and #state.recent_fps < max_recent then
                -- i==1 only reaches here when show_currently==false, so hist[1]
                -- is correctly included in recent rather than being skipped.
                local pct = 0
                local book_summary = nil
                if DS then
                    local cached = _cacheGet(fp)
                    if cached then
                        pct = cached.percent
                        book_summary = cached.summary
                        -- Re-apply custom props on the cache-hit path.
                        local _ct, _ca = applyCustomProps(fp, cached.title, cached.authors)
                        if _ct ~= cached.title or _ca ~= cached.authors then
                            local patched = {}
                            for k, v in pairs(cached) do patched[k] = v end
                            patched.title   = _ct
                            patched.authors = _ca
                            state.prefetched_data[fp] = patched
                        else
                            state.prefetched_data[fp] = cached
                        end
                    else
                        local ok2, ds = pcall(DS.open, DS, fp)
                        if ok2 and ds then
                            pct    = ds:readSetting("percent_finished") or 0
                            book_summary = ds:readSetting("summary")
                            local rp = ds:readSetting("doc_props") or {}
                            local rs = ds:readSetting("stats") or {}
                            local _t, _a = applyCustomProps(fp, rp.title, rp.authors)
                            local data = {
                                percent              = pct,
                                title                = _t,
                                authors              = _a,
                                doc_pages            = ds:readSetting("doc_pages"),
                                partial_md5_checksum = ds:readSetting("partial_md5_checksum"),
                                stat_pages           = rs.pages,
                                stat_total_time      = rs.total_time_in_sec,
                                summary              = book_summary,
                            }
                            _cachePut(fp, ds.source_candidate, data)
                            pcall(function() ds:close() end)
                            state.prefetched_data[fp] = data
                        else
                            state.prefetched_data[fp] = false
                        end
                    end
                end
                -- Always add to recent_fps regardless of read/complete status.
                -- Filtering by finished/complete is each module's responsibility:
                -- module_recent and module_coverdeck apply their own independent
                -- setting at render time using pct/summary from prefetched_data.
                state.recent_fps[#state.recent_fps + 1] = fp
            end
        end
        if not show_recent and state.current_fp then break end
        if state.current_fp and #state.recent_fps >= max_recent then break end
    end

    -- Only cache results that actually resolved something — an early-return
    -- empty state (e.g. both show_currently/show_recent false) would
    -- otherwise poison getStaleBooks() with an empty result on the next
    -- reader-return, even though a perfectly good previous result exists.
    if state.current_fp or #state.recent_fps > 0 then
        _last_books_state = state
        -- Mirror to the in-memory settings table (zero disk I/O — see the
        -- WRITE COST note above _persistStaleBooks). This keeps the on-disk
        -- copy fresh so the NEXT KOReader process launch can skip the
        -- zeros/placeholder flash on its very first onShow(), the same way
        -- SP._cache already avoids it for every reader-return WITHIN a
        -- single running process.
        _persistStaleBooks(state)
    end

    return state
end

-- ---------------------------------------------------------------------------
-- SH.getStaleBooks() — instant, zero-cost return of the last successful
-- SH.prefetchBooks() result. See the _last_books_state comment above the
-- cache declaration for the full rationale; this mirrors
-- module_stats_provider.lua's SP.getStale() exactly, with one addition:
-- a single lazy disk read on cold start (see _loadStaleBooksFromDisk above)
-- so a freshly launched KOReader process can also benefit from the previous
-- run's last-known books, not just reader-returns within the same run.
--
-- Returns nil only when (a) this is a genuinely fresh on-disk state too —
-- e.g. first launch ever after install, or the user cleared SimpleUI
-- settings — or (b) sui_store is unavailable for some reason. Callers must
-- fall back to an empty stub in that case, same as SP.getStale() callers
-- fall back to `{}`.
-- ---------------------------------------------------------------------------
function SH.getStaleBooks()
    if not _last_books_state and not _disk_books_load_tried then
        -- Lazy, at-most-once-per-process disk read. Deliberately NOT done
        -- eagerly at module load time: most processes' first relevant call
        -- to getStaleBooks() happens from HomescreenWidget:onShow() on the
        -- very first homescreen paint, which is exactly the latency-
        -- sensitive moment this whole mechanism exists to protect — so the
        -- read only happens if and when it's actually needed, not on every
        -- KOReader startup regardless of whether the homescreen is ever
        -- shown the books modules are even enabled.
        _last_books_state = _loadStaleBooksFromDisk()
    end
    return _last_books_state
end


-- ---------------------------------------------------------------------------
-- Sidecar helpers
-- ---------------------------------------------------------------------------


return SH