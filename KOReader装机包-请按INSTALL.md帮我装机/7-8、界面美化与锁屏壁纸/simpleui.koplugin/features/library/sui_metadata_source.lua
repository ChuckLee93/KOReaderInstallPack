-- sui_metadata_source.lua — Simple UI
-- Fast, cacheable access to book metadata for library browsing/filtering.
--
-- Two data sources are combined:
--   1. CoverBrowser's bookinfo_cache.sqlite3 (via BookInfoManager) — the
--      primary source, populated as the user opens/scans books.
--   2. Calibre's metadata.calibre (when present under base_dir) — used to
--      backfill books the bookinfo DB doesn't know about yet, or to fill
--      gaps in existing rows. bookinfo values always win on conflict.
--
-- Every query is scoped to a FilterState trail (see sui_filter_state) and
-- can be "recursive" (the whole subtree under base_dir — used by the full
-- author/series/tags browse mode) or not (only direct children of base_dir
-- — used by inline series-grouping inside a normal folder listing). This
-- is the one function both features share instead of each re-implementing
-- their own book-matching logic.
--
-- Results are cached per (base_dir, recursive, serialized trail). Call
-- MetadataSource.clearCache(base_dir) when the library changes (book
-- added/removed/re-scanned) for that subtree.
--
-- Public API
-- ----------
--   MetadataSource.getMatchingFiles(bim, base_dir, filter_state, options)
--       -> { {fullpath, filename, title=, authors=, series=, series_index=,
--             keywords=}, ... }  sorted by directory, filename
--   MetadataSource.getFacetValues(bim, base_dir, dimension, filter_state, options)
--       -> { {value, count, _first=row}, ... } sorted for display
--   MetadataSource.getRepresentativeFile(bim, base_dir, filter_state, options)
--       -> fullpath | nil  (first matching file once sorted for `active_dimension`)
--   MetadataSource.sortFiles(files, active_dimension)  -- mutates in place
--   MetadataSource.clearCache(base_dir)  -- base_dir == nil clears everything
--
-- options (all optional):
--   recursive        -- default true; false = direct children of base_dir only
--   active_dimension  -- passed to sortFiles when getMatchingFiles is asked to sort

local logger      = require("logger")
local ffiUtil     = require("ffi/util")
local FilterState = require("features/library/sui_filter_state")

local MetadataSource = {}

-- ---------------------------------------------------------------------------
-- Caches
-- ---------------------------------------------------------------------------

local _matching_files_cache = {} -- [cache_key] = rows
local _facet_values_cache   = {} -- [cache_key .. "\31" .. dimension] = { {value, count, _first=row}, ... }
local _calibre_index_cache  = {} -- [base_dir]   = index table | false

local function normalizeBaseDir(dir)
    while #dir > 1 and dir:sub(-1) == "/" do dir = dir:sub(1, -2) end
    return dir
end

local function serializeTrail(filter_state, recursive)
    local parts = { recursive and "r" or "d" }
    for _, entry in ipairs(filter_state and filter_state.trail or {}) do
        parts[#parts + 1] = entry.dimension
        parts[#parts + 1] = (entry.value == false) and "\0" or tostring(entry.value)
    end
    return table.concat(parts, "\31")
end

local function cacheKey(base_dir, filter_state, recursive)
    return normalizeBaseDir(base_dir) .. "\30" .. serializeTrail(filter_state, recursive)
end

-- Clears every cache entry whose base_dir is `base_dir` or a subdirectory
-- of it (so invalidating a parent also invalidates narrower queries below
-- it). base_dir == nil clears everything.
function MetadataSource.clearCache(base_dir)
    if not base_dir then
        for k in pairs(_matching_files_cache) do _matching_files_cache[k] = nil end
        for k in pairs(_facet_values_cache)   do _facet_values_cache[k]   = nil end
        for k in pairs(_calibre_index_cache)  do _calibre_index_cache[k]  = nil end
        return
    end
    local prefix = normalizeBaseDir(base_dir)
    for k in pairs(_matching_files_cache) do
        local key_base = k:match("^(.-)\30")
        if key_base == prefix or (key_base and key_base:sub(1, #prefix + 1) == prefix .. "/") then
            _matching_files_cache[k] = nil
        end
    end
    -- _facet_values_cache keys are a matching_files_cache key with
    -- "\31" .. dimension appended, so the same base-dir prefix match applies.
    for k in pairs(_facet_values_cache) do
        local key_base = k:match("^(.-)\30")
        if key_base == prefix or (key_base and key_base:sub(1, #prefix + 1) == prefix .. "/") then
            _facet_values_cache[k] = nil
        end
    end
    _calibre_index_cache[prefix] = nil
end

-- ---------------------------------------------------------------------------
-- Calibre metadata.calibre backfill
-- ---------------------------------------------------------------------------

-- Loads metadata.calibre reachable from `dir` and returns a lookup table
-- keyed by the book's absolute path: { [fullpath] = {title, authors,
-- series, series_index, keywords}, ... }. Returns false when none exists.
-- Cached for the session (per base_dir actually queried).
local function loadCalibreIndex(dir)
    local cached = _calibre_index_cache[dir]
    if cached ~= nil then return cached end

    local ok_cm, CalibreMetadata = pcall(require, "metadata")
    if not ok_cm or not CalibreMetadata or type(CalibreMetadata.loadBookList) ~= "function" then
        _calibre_index_cache[dir] = false
        return false
    end

    local cm = setmetatable({}, { __index = CalibreMetadata })
    cm.drive = {}
    cm.books = {}

    local ok_init, result = pcall(function() return cm:init(dir, true) end)
    if not ok_init or not result then
        cm:clean()
        _calibre_index_cache[dir] = false
        return false
    end

    local index = {}
    for _, book in ipairs(cm.books) do
        local lpath = book.lpath
        if lpath and type(lpath) == "string" then
            local fullpath = dir .. "/" .. lpath

            local authors_str
            if type(book.authors) == "table" and #book.authors > 0 then
                authors_str = table.concat(book.authors, "\n")
            end
            local keywords_str
            if type(book.tags) == "table" and #book.tags > 0 then
                keywords_str = table.concat(book.tags, "\n")
            end
            local series = (type(book.series) == "string") and book.series or nil
            local series_index = (type(book.series_index) == "number") and book.series_index or nil
            local title = (type(book.title) == "string") and book.title or nil

            index[fullpath] = {
                title = title, authors = authors_str, series = series,
                series_index = series_index, keywords = keywords_str,
            }
        end
    end
    cm:clean()

    if next(index) then
        _calibre_index_cache[dir] = index
        return index
    end
    _calibre_index_cache[dir] = false
    return false
end

local function dirOf(fullpath)
    return fullpath:match("^(.*)/[^/]+$")
end

-- ---------------------------------------------------------------------------
-- SQL query
-- ---------------------------------------------------------------------------

local _SQL_BASE_RECURSIVE = "SELECT directory, filename, title, authors, series, series_index, keywords"
                         .. " FROM bookinfo WHERE directory GLOB ?"
local _SQL_BASE_DIRECT    = "SELECT directory, filename, title, authors, series, series_index, keywords"
                         .. " FROM bookinfo WHERE directory = ?"

local function trailMatchesRow(trail, row)
    for _, entry in ipairs(trail) do
        local definition = FilterState.DIMENSIONS[entry.dimension]
        local field_value = row[definition.column]
        if entry.value == false then
            if field_value ~= nil then return false end
        elseif definition.multi_value then
            if not field_value then return false end
            if not ("\n" .. field_value .. "\n"):find("\n" .. entry.value .. "\n", 1, true) then
                return false
            end
        else
            if field_value ~= entry.value then return false end
        end
    end
    return true
end

local function fetchMatchingFiles(bim, base_dir, filter_state, recursive)
    base_dir = normalizeBaseDir(base_dir)
    local vars = {}
    local sql

    if recursive then
        sql = _SQL_BASE_RECURSIVE
        vars[1] = base_dir .. "/*"
    else
        sql = _SQL_BASE_DIRECT
        -- The `directory` column always stores a trailing slash (fullpath is
        -- built as directory..filename with no separator) — must match that.
        vars[1] = base_dir .. "/"
    end

    for _, entry in ipairs(filter_state and filter_state.trail or {}) do
        local definition = FilterState.DIMENSIONS[entry.dimension]
        local col = definition.column
        if entry.value == false then
            sql = sql .. " AND " .. col .. " IS NULL"
        elseif definition.multi_value then
            sql = sql .. " AND '\n'||" .. col .. "||'\n' GLOB ?"
            vars[#vars + 1] = "*\n" .. entry.value .. "\n*"
        else
            sql = sql .. " AND " .. col .. "=?"
            vars[#vars + 1] = entry.value
        end
    end
    sql = sql .. " ORDER BY directory ASC, filename ASC"

    local results = {}
    local stmt
    local ok, err = pcall(function()
        bim:openDbConnection()
        stmt = bim.db_conn:prepare(sql)
        stmt:bind(table.unpack(vars))
        while true do
            local row = stmt:step()
            if not row then break end
            results[#results + 1] = {
                row[1] .. row[2], row[2],
                title = row[3], authors = row[4], series = row[5],
                series_index = tonumber(row[6]), keywords = row[7],
            }
        end
    end)
    if stmt then pcall(function() stmt:finalize() end) end
    if not ok then
        logger.warn("sui_metadata_source: SQL error:", tostring(err))
        return {}
    end

    -- Calibre backfill. For non-recursive queries this only ever finds
    -- something when base_dir itself is a Calibre library root, which is
    -- rare for a plain subfolder — an acceptable, harmless no-op the rest
    -- of the time.
    local cal_index = loadCalibreIndex(base_dir)
    if cal_index then
        for _, row in ipairs(results) do
            local cal = cal_index[row[1]]
            if cal then
                row.authors      = row.authors      or cal.authors
                row.series       = row.series       or cal.series
                row.series_index = row.series_index or cal.series_index
                row.title        = row.title        or cal.title
                row.keywords     = row.keywords     or cal.keywords
            end
        end

        local seen = {}
        for _, row in ipairs(results) do seen[row[1]] = true end

        for fullpath, cal in pairs(cal_index) do
            local in_scope = recursive
                or dirOf(fullpath) == base_dir
            if in_scope and not seen[fullpath] and trailMatchesRow(filter_state and filter_state.trail or {}, cal) then
                local fname = fullpath:match("([^/]+)$")
                if fname then
                    results[#results + 1] = {
                        fullpath, fname,
                        title = cal.title, authors = cal.authors, series = cal.series,
                        series_index = cal.series_index, keywords = cal.keywords,
                    }
                end
            end
        end
    end

    return results
end

local function copyArray(array)
    local copy = {}
    for i, value in ipairs(array) do copy[i] = value end
    return copy
end

-- Returns a COPY of the (internally cached) matching-files array. Callers
-- are free to sort or otherwise mutate the array they receive — the cache
-- itself is never touched here, so a caller sorting by one active_dimension
-- can never corrupt the result another caller expects in a different order.
function MetadataSource.getMatchingFiles(bim, base_dir, filter_state, options)
    if not bim or not base_dir then return {} end
    options = options or {}
    local recursive = options.recursive
    if recursive == nil then recursive = true end

    local key = cacheKey(base_dir, filter_state, recursive)
    local cached = _matching_files_cache[key]
    if not cached then
        cached = fetchMatchingFiles(bim, base_dir, filter_state, recursive)
        _matching_files_cache[key] = cached
    end
    return copyArray(cached)
end

-- ---------------------------------------------------------------------------
-- Facet values (grouping + counts)
-- ---------------------------------------------------------------------------

-- The grouping pass + strcoll sort below is the expensive part of this
-- function (O(#matching files) to group, O(n log n) strcoll comparisons to
-- sort) — cheap for a single call, but this function is called on every
-- author/series/tags tab switch, so without memoization it re-pays that
-- cost every time even when getMatchingFiles itself is a cache hit. Cached
-- under the same key scheme as _matching_files_cache, with the dimension
-- appended, and invalidated by the same MetadataSource.clearCache(base_dir).
local function computeFacetValues(files, definition)
    local grouped, first = {}, {}

    for _, row in ipairs(files) do
        local raw = row[definition.column]
        if definition.multi_value and raw and raw:find("\n", 1, true) then
            for token in raw:gmatch("[^\n]+") do
                if token ~= "" then
                    if not grouped[token] then grouped[token] = 0; first[token] = row end
                    grouped[token] = grouped[token] + 1
                end
            end
        else
            local key = raw or false
            if not grouped[key] then grouped[key] = 0; first[key] = row end
            grouped[key] = grouped[key] + 1
        end
    end

    local out = {}
    for value, count in pairs(grouped) do
        out[#out + 1] = { value, count, _first = first[value] }
    end

    table.sort(out, function(a, b)
        local av, bv = a[1], b[1]
        if av == bv then return false end
        if not av or av == false or av == "" then return false end
        if not bv or bv == false or bv == "" then return true end
        return ffiUtil.strcoll(av, bv)
    end)

    return out
end

function MetadataSource.getFacetValues(bim, base_dir, dimension, filter_state, options)
    if not FilterState.isDimension(dimension) then return {} end
    options = options or {}
    local recursive = options.recursive
    if recursive == nil then recursive = true end

    local key = cacheKey(base_dir, filter_state, recursive) .. "\31" .. dimension
    local cached = _facet_values_cache[key]
    if not cached then
        local files = MetadataSource.getMatchingFiles(bim, base_dir, filter_state, options)
        cached = computeFacetValues(files, FilterState.DIMENSIONS[dimension])
        _facet_values_cache[key] = cached
    end
    -- Return a shallow copy: cheap (copies {value,count,_first} refs, not
    -- rows), and keeps callers free to sort/mutate what they receive
    -- without corrupting the cache — same contract as getMatchingFiles.
    return copyArray(cached)
end

-- ---------------------------------------------------------------------------
-- Sorting
-- ---------------------------------------------------------------------------

local function strcollSafe(a, b)
    if a == b then return false end
    if not a or a == false then return false end
    if not b or b == false then return true end
    return ffiUtil.strcoll(a, b)
end

-- Sort by: series name (author dimension only), series_index, title, filename.
function MetadataSource.sortFiles(files, active_dimension)
    local is_author = (active_dimension == "author")
    table.sort(files, function(a, b)
        if is_author then
            local as, bs = a.series, b.series
            if as ~= bs then return strcollSafe(as, bs) end
        end
        local ai, bi = a.series_index, b.series_index
        if ai ~= bi then
            if not ai then return false end
            if not bi then return true end
            return ai < bi
        end
        local at = a.title or a[2]
        local bt = b.title or b[2]
        if at ~= bt then return strcollSafe(at, bt) end
        return strcollSafe(a[2], b[2])
    end)
end

-- ---------------------------------------------------------------------------
-- Representative file (for cover thumbnails)
-- ---------------------------------------------------------------------------

function MetadataSource.getRepresentativeFile(bim, base_dir, filter_state, options)
    local files = MetadataSource.getMatchingFiles(bim, base_dir, filter_state, options)
    if #files == 0 then return nil end
    MetadataSource.sortFiles(files, options and options.active_dimension)
    return files[1][1]
end

return MetadataSource
