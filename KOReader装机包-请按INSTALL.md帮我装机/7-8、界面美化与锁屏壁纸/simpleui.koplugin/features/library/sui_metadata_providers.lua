-- sui_metadata_providers.lua — Simple UI
--
-- Supplies bibliographic metadata for CBZ chapter archives whose real
-- title/author/series live in an embedded ComicInfo.xml rather than in
-- the engine's native document properties.
--
-- BookInfoManager is the single cache Library, covers and series grouping
-- read from. This module patches it once so that:
--   1. extractBookInfo / extractInBackground skip files that already have a
--      usable cached row (avoids mass re-extract when a folder gains one file)
--   2. extractBookInfo redirects recognized CBZs to the companion document
--      provider when available, then merges ComicInfo.xml into the row
--   3. getBookInfo fills incomplete CBZ rows from ComicInfo.xml in-place and
--      keeps a small text snapshot so the UI can still show title/author while
--      a row is temporarily missing (in-progress extraction)
--
-- ComicInfo.xml is read from the ZIP in pure Lua (store and deflate), so
-- metadata does not depend on an external binary.
--
-- Public API: Providers.install()  -- idempotent

local logger = require("logger")

local Providers = {}

-- ---------------------------------------------------------------------------
-- Paths
-- ---------------------------------------------------------------------------

local ok_android, android = pcall(require, "android")
local is_android = ok_android and android ~= nil

local function normalizePath(path)
    if type(path) ~= "string" or path == "" then return nil end
    if is_android then
        path = path:gsub("^/sdcard/", "/storage/emulated/0/")
    end
    return path:gsub("/+$", "")
end

local function pathIsUnder(path, directory)
    path = normalizePath(path)
    directory = normalizePath(directory)
    if not (path and directory) then return false end
    if path == directory then return true end
    local prefix = directory
    if prefix:sub(-1) ~= "/" then prefix = prefix .. "/" end
    return path:sub(1, #prefix) == prefix
end

local function getDataDir()
    local DataStorage = require("datastorage")
    return DataStorage:getFullDataDir() or DataStorage:getDataDir()
end

local function absoluteDataPath(path)
    if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/" then
        return path
    end
    return getDataDir() .. "/" .. path:gsub("^%./", "")
end

local function isCbz(path)
    return type(path) == "string" and path:lower():sub(-4) == ".cbz"
end

-- ---------------------------------------------------------------------------
-- Bounded path → value cache (evicts everything when full)
-- ---------------------------------------------------------------------------

local CACHE_MAX = 128

local function newCache()
    return { map = {}, n = 0 }
end

local function cacheGet(c, key)
    return c.map[key]
end

local function cacheSet(c, key, value)
    if c.map[key] == nil then
        if c.n >= CACHE_MAX then
            c.map = {}
            c.n = 0
        end
        c.n = c.n + 1
    end
    c.map[key] = value
end

-- ---------------------------------------------------------------------------
-- ZIP helpers
-- ---------------------------------------------------------------------------

local function u16(data, i)
    return (data:byte(i) or 0) + (data:byte(i + 1) or 0) * 256
end

local function u32(data, i)
    return (data:byte(i) or 0)
        + (data:byte(i + 1) or 0) * 256
        + (data:byte(i + 2) or 0) * 65536
        + (data:byte(i + 3) or 0) * 16777216
end

-- Raw DEFLATE (ZIP method 8). windowBits = -15 = no zlib/gzip wrapper.
local _inflate_fn -- false = unavailable, nil = not tried, function = ready

local function rawInflate(compressed, uncompressed_size)
    if type(compressed) ~= "string" or compressed == "" then return nil end
    if _inflate_fn == false then return nil end

    if _inflate_fn == nil then
        local ok_ffi, ffi = pcall(require, "ffi")
        if not ok_ffi then
            _inflate_fn = false
            return nil
        end
        pcall(function()
            ffi.cdef[[
                typedef struct z_stream_s {
                    const unsigned char *next_in;
                    unsigned int avail_in;
                    unsigned long total_in;
                    unsigned char *next_out;
                    unsigned int avail_out;
                    unsigned long total_out;
                    const char *msg;
                    void *state;
                    void *zalloc;
                    void *zfree;
                    void *opaque;
                    int data_type;
                    unsigned long adler;
                    unsigned long reserved;
                } z_stream;
                int inflateInit2_(z_stream *strm, int windowBits,
                                  const char *version, int stream_size);
                int inflate(z_stream *strm, int flush);
                int inflateEnd(z_stream *strm);
            ]]
        end)
        local libz
        pcall(function()
            libz = ffi.loadlib and ffi.loadlib("z", 1) or ffi.load("z")
        end)
        if not (libz and libz.inflateInit2_) then
            _inflate_fn = false
            return nil
        end
        _inflate_fn = function(data, out_len)
            out_len = math.max(out_len or (#data * 4), 256)
            local stream = ffi.new("z_stream")
            if libz.inflateInit2_(stream, -15, "1.2.0", ffi.sizeof(stream)) ~= 0 then
                return nil
            end
            local out = ffi.new("unsigned char[?]", out_len)
            stream.next_in = ffi.cast("const unsigned char *", data)
            stream.avail_in = #data
            stream.next_out = out
            stream.avail_out = out_len
            local res = libz.inflate(stream, 4) -- Z_FINISH
            libz.inflateEnd(stream)
            if res ~= 1 and res ~= 0 then return nil end
            local produced = tonumber(stream.total_out) or 0
            if produced <= 0 then return nil end
            return ffi.string(out, produced)
        end
    end

    return _inflate_fn(compressed, uncompressed_size)
end

-- Find EOCD offset inside a tail buffer, or nil.
local function findEocd(tail)
    for pos = #tail - 21, 1, -1 do
        if tail:sub(pos, pos + 3) == "PK\005\006" then
            return pos
        end
    end
end

-- Read one named entry (store or deflate). entry_names is a list of
-- acceptable names (first match wins, case-insensitive).
local function readZipEntry(path, entry_names)
    if type(path) ~= "string" then return nil end
    if type(entry_names) == "string" then entry_names = { entry_names } end
    if type(entry_names) ~= "table" or #entry_names == 0 then return nil end

    local want = {}
    for _, name in ipairs(entry_names) do
        want[name:lower()] = true
    end

    local file = io.open(path, "rb")
    if not file then return nil end

    local function fail()
        file:close()
        return nil
    end

    local size = file:seek("end")
    if not size or size < 22 then return fail() end

    local tail_len = math.min(size, 65535 + 22)
    file:seek("set", size - tail_len)
    local tail = file:read(tail_len)
    if not tail then return fail() end

    local eocd = findEocd(tail)
    if not eocd then return fail() end

    local cd_size   = u32(tail, eocd + 12)
    local cd_offset = u32(tail, eocd + 16)
    if cd_size == 0 or cd_offset + cd_size > size then return fail() end

    file:seek("set", cd_offset)
    local cd = file:read(cd_size)
    if not cd or #cd < cd_size then return fail() end

    local local_offset, comp_method, comp_size, uncomp_size
    local i = 1
    while i + 46 <= #cd + 1 do
        if cd:sub(i, i + 3) ~= "PK\001\002" then break end
        local name_len    = u16(cd, i + 28)
        local extra_len   = u16(cd, i + 30)
        local comment_len = u16(cd, i + 32)
        local name = cd:sub(i + 46, i + 45 + name_len)
        if want[name:lower()] then
            local_offset = u32(cd, i + 42)
            comp_method  = u16(cd, i + 10)
            comp_size    = u32(cd, i + 20)
            uncomp_size  = u32(cd, i + 24)
            break
        end
        i = i + 46 + name_len + extra_len + comment_len
    end
    if not local_offset then return fail() end

    file:seek("set", local_offset)
    local lfh = file:read(30)
    if not lfh or #lfh < 30 or lfh:sub(1, 4) ~= "PK\003\004" then
        return fail()
    end
    local l_name_len  = u16(lfh, 27)
    local l_extra_len = u16(lfh, 29)
    -- Prefer central-directory sizes (local header may be zeroed with data descriptors).
    file:seek("set", local_offset + 30 + l_name_len + l_extra_len)
    local payload = file:read(comp_size)
    file:close()

    if not payload or #payload < comp_size then return nil end
    if comp_method == 0 then return payload end
    if comp_method == 8 then return rawInflate(payload, uncomp_size) end
    return nil
end

-- True when the archive contains any of the named entries (no decompress).
local function zipHasEntry(path, entry_names)
    if type(path) ~= "string" then return false end
    if type(entry_names) == "string" then entry_names = { entry_names } end
    if type(entry_names) ~= "table" then return false end

    local want = {}
    for _, name in ipairs(entry_names) do
        want[name:lower()] = true
    end

    local file = io.open(path, "rb")
    if not file then return false end

    local size = file:seek("end")
    if not size or size < 22 then
        file:close()
        return false
    end

    local tail_len = math.min(size, 65535 + 22)
    file:seek("set", size - tail_len)
    local tail = file:read(tail_len)
    if not tail then
        file:close()
        return false
    end

    local eocd = findEocd(tail)
    if not eocd then
        file:close()
        return false
    end

    local cd_size   = u32(tail, eocd + 12)
    local cd_offset = u32(tail, eocd + 16)
    if cd_size == 0 or cd_offset + cd_size > size then
        file:close()
        return false
    end

    file:seek("set", cd_offset)
    local cd = file:read(cd_size)
    file:close()
    if not cd then return false end

    local i = 1
    while i + 46 <= #cd + 1 do
        if cd:sub(i, i + 3) ~= "PK\001\002" then break end
        local name_len    = u16(cd, i + 28)
        local extra_len   = u16(cd, i + 30)
        local comment_len = u16(cd, i + 32)
        local name = cd:sub(i + 46, i + 45 + name_len)
        if want[name:lower()] then return true end
        i = i + 46 + name_len + extra_len + comment_len
    end
    return false
end

local function readZipComment(path)
    local file = io.open(path, "rb")
    if not file then return nil end

    local size = file:seek("end")
    if not size or size <= 0 then
        file:close()
        return nil
    end

    local read_size = math.min(size, 65535 + 22)
    file:seek("set", size - read_size)
    local data = file:read(read_size)
    file:close()
    if not data then return nil end

    local eocd = findEocd(data)
    if not eocd then return nil end
    local comment_len = u16(data, eocd + 20)
    if eocd + 21 + comment_len == #data and comment_len > 0 then
        return data:sub(eocd + 22, eocd + 21 + comment_len)
    end
end

-- ---------------------------------------------------------------------------
-- ComicInfo.xml
-- ---------------------------------------------------------------------------

local COMICINFO_NAMES = { "ComicInfo.xml", "comicinfo.xml" }

local function xmlText(xml, tag)
    local value = xml:match("<" .. tag .. "%s*[^>]*>(.-)</" .. tag .. "%s*>")
    if not value then return nil end
    value = value:gsub("<.->", "")
    value = value
        :gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&")
        :gsub("&quot;", '"'):gsub("&apos;", "'")
        :gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then return nil end
    return value
end

local function parseComicInfoXml(xml)
    if type(xml) ~= "string" or xml == "" then return nil end

    local title   = xmlText(xml, "Title")
    local series  = xmlText(xml, "Series")
    local number  = xmlText(xml, "Number")
    local summary = xmlText(xml, "Summary")
    local language = xmlText(xml, "LanguageISO")
    local genre   = xmlText(xml, "Genre")

    local authors = {}
    local function addAuthor(v)
        if not v or v == "" then return end
        for _, existing in ipairs(authors) do
            if existing == v then return end
        end
        authors[#authors + 1] = v
    end
    addAuthor(xmlText(xml, "Writer"))
    addAuthor(xmlText(xml, "Penciller"))
    addAuthor(xmlText(xml, "Inker"))
    addAuthor(xmlText(xml, "Translator"))

    local info = {}
    if title then
        info.title = title
    elseif series then
        info.title = series
    end
    if series then info.series = series end
    if number then info.series_index = tonumber(number) or number end
    if language then info.language = language end
    if genre then info.keywords = genre end
    if summary then
        info.description = summary
        info.notes = summary
    end
    if #authors > 0 then
        local joined = table.concat(authors, " & ")
        info.authors = joined
        info.author = joined
    end

    if not next(info) then return nil end
    return info
end

local comicinfo_cache = newCache()

local function fileIdentity(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not (ok and lfs) then return 0, 0 end
    return lfs.attributes(path, "size") or 0,
           lfs.attributes(path, "modification") or 0
end

-- Returns a props table or nil. Results are cached per path+mtime+size.
local function readComicInfoProps(path)
    if not isCbz(path) then return nil end

    local size, mtime = fileIdentity(path)
    local cached = cacheGet(comicinfo_cache, path)
    if cached and cached.size == size and cached.mtime == mtime then
        return cached.props or nil
    end

    local xml = readZipEntry(path, COMICINFO_NAMES)
    local props = xml and parseComicInfoXml(xml) or nil
    cacheSet(comicinfo_cache, path, {
        size = size,
        mtime = mtime,
        props = props or false,
    })
    return props
end

-- Columns BookInfoManager actually stores.
local BOOKINFO_KEYS = {
    "title", "authors", "series", "series_index",
    "language", "keywords", "description",
}

local function bookinfoPatchFromComic(comic)
    if type(comic) ~= "table" then return nil end
    local patch = {}
    for _, key in ipairs(BOOKINFO_KEYS) do
        local value = comic[key]
        if value ~= nil and value ~= "" then
            patch[key] = value
        end
    end
    return next(patch) and patch or nil
end

-- Merge ComicInfo fields into an existing bookinfo row.
local function enrichBookInfoFromComic(bim, filepath)
    if not isCbz(filepath) then return false end
    if type(bim) ~= "table" or type(bim.setBookInfoProperties) ~= "function" then
        return false
    end
    local patch = bookinfoPatchFromComic(readComicInfoProps(filepath))
    if not patch then return false end
    return pcall(bim.setBookInfoProperties, bim, filepath, patch)
end

-- ---------------------------------------------------------------------------
-- Chapter-archive recognition
-- ---------------------------------------------------------------------------

local origin_cache = newCache()

local function hasOriginComment(path)
    local cached = cacheGet(origin_cache, path)
    if cached ~= nil then return cached end

    local comment = readZipComment(path)
    local has = type(comment) == "string"
        and comment:find('"chapter_id"', 1, true) ~= nil
        and comment:find('"manga_id"', 1, true) ~= nil
        and comment:find('"source_id"', 1, true) ~= nil
    cacheSet(origin_cache, path, has)
    return has
end

local storage_path_loaded = false
local storage_path_cache

local function getChapterStoragePath()
    if storage_path_loaded then return storage_path_cache end
    storage_path_loaded = true

    local home = getDataDir() .. "/rakuyomi"
    local storage = home .. "/downloads"
    local content = require("util").readFromFile(home .. "/settings.json", "rb")
    if content then
        local ok_json, rapidjson = pcall(require, "rapidjson")
        if ok_json then
            local ok_decode, settings = pcall(rapidjson.decode, content)
            if ok_decode and type(settings) == "table"
                    and type(settings.storage_path) == "string"
                    and settings.storage_path ~= "" then
                storage = absoluteDataPath(settings.storage_path)
            end
        end
    end
    storage_path_cache = normalizePath(storage)
    return storage_path_cache
end

-- Cheap entry-presence probe (no decompress / parse).
local comicinfo_presence_cache = newCache()

local function hasComicInfoEntry(path)
    local size, mtime = fileIdentity(path)
    local cached = cacheGet(comicinfo_presence_cache, path)
    if cached and cached.size == size and cached.mtime == mtime then
        return cached.has
    end
    local has = zipHasEntry(path, COMICINFO_NAMES)
    cacheSet(comicinfo_presence_cache, path, {
        size = size, mtime = mtime, has = has,
    })
    return has
end

local function isChapterArchive(path)
    if not isCbz(path) then return false end
    local storage = getChapterStoragePath()
    if pathIsUnder(path, storage) or hasOriginComment(path) then
        return true
    end
    return hasComicInfoEntry(path)
end

-- ---------------------------------------------------------------------------
-- Companion document provider (optional)
-- ---------------------------------------------------------------------------

local function getChapterArchiveProvider(path)
    if not isChapterArchive(path) then return nil end

    local ok, CbzDocument = pcall(require, "extensions/CbzDocument")
    if not (ok and type(CbzDocument) == "table") then return nil end

    if not CbzDocument._simpleui_comicinfo_patched then
        CbzDocument._simpleui_comicinfo_patched = true
        local orig = CbzDocument.getDocumentProps
        function CbzDocument:getDocumentProps(...)
            local props = orig(self, ...)
            if type(props) ~= "table" then props = {} end

            local comic = readComicInfoProps(self.file)
            if comic then
                for key, value in pairs(comic) do
                    if value ~= nil and value ~= ""
                            and (props[key] == nil or props[key] == "") then
                        props[key] = value
                    end
                end
            end
            if (not props.authors or props.authors == "") and props.author then
                props.authors = props.author
            end
            if (not props.description or props.description == "") and props.notes then
                props.description = props.notes
            end
            return props
        end
    end

    return CbzDocument
end

local SOURCES = { getChapterArchiveProvider }

local function resolveProvider(path)
    for _, getProvider in ipairs(SOURCES) do
        local provider = getProvider(path)
        if provider then return provider end
    end
end

-- ---------------------------------------------------------------------------
-- BookInfoManager patch
-- ---------------------------------------------------------------------------

-- Text-only snapshot of a complete row. Used when getBookInfo returns nil
-- during an in-progress re-extract so the UI can keep showing title/author.
local display_cache = newCache()

local function snapshotMeta(bi)
    if type(bi) ~= "table" then return nil end
    local has_text = (bi.title and bi.title ~= "")
        or (bi.authors and bi.authors ~= "")
        or (bi.series and bi.series ~= "")
    if not has_text then return nil end
    return {
        title        = bi.title,
        authors      = bi.authors,
        series       = bi.series,
        series_index = bi.series_index,
        description  = bi.description,
        language     = bi.language,
        keywords     = bi.keywords,
        pages        = bi.pages,
    }
end

local function syntheticFromSnapshot(snap)
    return {
        title         = snap.title,
        authors       = snap.authors,
        series        = snap.series,
        series_index  = snap.series_index,
        description   = snap.description,
        language      = snap.language,
        keywords      = snap.keywords,
        pages         = snap.pages,
        has_meta      = "Y",
        -- No cover payload: force callers to keep polling until the real row
        -- is written back, without inventing a cover bitmap.
        cover_fetched = false,
        has_cover     = false,
    }
end

function Providers.install()
    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    local ok_registry, DocumentRegistry = pcall(require, "document/documentregistry")
    if not (ok_bim and ok_registry)
            or type(BookInfoManager) ~= "table"
            or type(BookInfoManager.extractBookInfo) ~= "function"
            or type(DocumentRegistry) ~= "table"
            or type(DocumentRegistry.getProvider) ~= "function" then
        return false
    end
    if BookInfoManager._simpleui_metadata_providers_patched then
        return true
    end

    local orig_getBookInfo = BookInfoManager.getBookInfo
    local orig_extractBookInfo = BookInfoManager.extractBookInfo
    local orig_extractInBackground = BookInfoManager.extractInBackground

    -- True when the cached row is good enough that a full extract would only
    -- wipe and rewrite the same data (the mass-reset problem on folder refresh).
    local function canSkipExtract(bim, filepath, cover_specs)
        if type(orig_getBookInfo) ~= "function" then return false end
        local ok, bi = pcall(orig_getBookInfo, bim, filepath, false)
        if not ok or not bi or not bi.cover_fetched then return false end
        if bi.has_cover and cover_specs
                and type(bim.isCachedCoverInvalid) == "function"
                and bim.isCachedCoverInvalid(bi, cover_specs) then
            return false
        end
        -- Cover state is fine. Fill any missing text from ComicInfo without
        -- opening the document engine.
        if isCbz(filepath) then
            local need_meta = (not bi.title or bi.title == "")
                or (not bi.authors or bi.authors == "")
                or (not bi.series or bi.series == "")
            if need_meta then
                enrichBookInfoFromComic(bim, filepath)
            end
        end
        return true
    end

    function BookInfoManager:extractBookInfo(filepath, cover_specs, ...)
        if canSkipExtract(self, filepath, cover_specs) then
            return true
        end

        local provider = resolveProvider(filepath)
        local result

        if provider then
            local orig_getProvider = DocumentRegistry.getProvider
            DocumentRegistry.getProvider = function(registry, file, ...)
                if file == filepath then return provider end
                return orig_getProvider(registry, file, ...)
            end
            local ok, extract_result = pcall(
                orig_extractBookInfo, self, filepath, cover_specs, ...)
            DocumentRegistry.getProvider = orig_getProvider
            if not ok then
                logger.warn("simpleui: metadata extraction failed:", tostring(extract_result))
                error(extract_result, 0)
            end
            result = extract_result
        else
            result = orig_extractBookInfo(self, filepath, cover_specs, ...)
        end

        enrichBookInfoFromComic(self, filepath)
        return result
    end

    -- Drop already-complete files before launching a background batch so a
    -- single new chapter does not re-queue (and wipe) the rest of the folder.
    if type(orig_extractInBackground) == "function" then
        function BookInfoManager:extractInBackground(files)
            if type(files) ~= "table" or #files == 0 then
                return orig_extractInBackground(self, files)
            end
            local filtered = {}
            for _, entry in ipairs(files) do
                local fp = type(entry) == "table" and entry.filepath or entry
                local specs = type(entry) == "table" and entry.cover_specs or nil
                if not canSkipExtract(self, fp, specs) then
                    filtered[#filtered + 1] = entry
                end
            end
            if #filtered == 0 then return true end
            return orig_extractInBackground(self, filtered)
        end
    end

    if type(orig_getBookInfo) == "function" then
        local healed = newCache()
        function BookInfoManager:getBookInfo(filepath, ...)
            local bookinfo = orig_getBookInfo(self, filepath, ...)

            if bookinfo then
                local snap = snapshotMeta(bookinfo)
                if snap then cacheSet(display_cache, filepath, snap) end

                if isCbz(filepath) and not cacheGet(healed, filepath) then
                    local incomplete = (not bookinfo.title or bookinfo.title == "")
                        or (not bookinfo.authors or bookinfo.authors == "")
                        or (not bookinfo.series or bookinfo.series == "")
                    if incomplete then
                        cacheSet(healed, filepath, true)
                        if enrichBookInfoFromComic(self, filepath) then
                            bookinfo = orig_getBookInfo(self, filepath, ...)
                            if bookinfo then
                                local snap2 = snapshotMeta(bookinfo)
                                if snap2 then cacheSet(display_cache, filepath, snap2) end
                            end
                        end
                    end
                end
                return bookinfo
            end

            -- Row missing (never extracted, or temporarily replaced while
            -- in_progress). Serve last known text metadata when available.
            local snap = cacheGet(display_cache, filepath)
            if snap then
                return syntheticFromSnapshot(snap)
            end
            return nil
        end
    end

    BookInfoManager._simpleui_metadata_providers_patched = true
    return true
end

return Providers
