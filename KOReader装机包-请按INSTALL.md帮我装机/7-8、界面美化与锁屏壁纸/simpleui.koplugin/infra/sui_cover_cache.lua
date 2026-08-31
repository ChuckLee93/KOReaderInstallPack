-- sui_cover_cache.lua — Simple UI
-- Single-layer LRU of stretched cover bitmaps, keyed by filepath ONLY
-- ("canonical-dim" caching). One entry per book, sized to the LARGEST
-- render dims requested across every consumer in this session.
--
-- This is one of two cover caches in the plugin. The other is the
-- reference cover cache in infra/sui_config.lua (backing
-- Config.getCroppedCoverBB), which crops fresh on every call instead of
-- stretching. Together they replaced an older three-layer design (exact-
-- size cache, uncropped reference cache, separate canonical-3:2 crop
-- cache) that predates this split.
--
-- THIS cache is for every consumer that renders a book at a fixed 3:2
-- aspect and STRETCHES to fit (no crop): Recent, TBR, New Books, Library,
-- Currently, CoverDeck's centre slot, Collections' Single style. It is NOT
-- used by anything that needs an actual crop: Collections' Quad style
-- (~1:1 quadrants, crop-to-fill) and CoverDeck's near/far "peek" slots
-- (deliberately non-3:2 slivers cropped left/right-aligned) both go
-- through the reference cache instead — cropping is a framing decision
-- that depends on target shape, so it can't share a filepath-only entry
-- with this stretch-only group. See infra/sui_config.lua's
-- Config.getCroppedCoverBB for that path.
--
-- Why filepath-only works here (and wouldn't for a crop consumer): every
-- consumer of THIS cache targets the exact same 3:2 aspect ratio. Stretching
-- a book's cover once, to the LARGEST 3:2 box requested so far, and letting
-- every smaller consumer downscale that same 3:2 bitmap at paint time (via
-- ImageWidget's own width/height, no scale_factor) is an EXACT uniform
-- downscale — not an approximation — because source and target share the
-- same aspect. A (filepath, w, h) key, which an exact-size cache needs,
-- produces a separate resident copy per distinct (module, scale) pair for
-- the same book; this collapses all of them into one.
--
-- Put policy: prefer-larger. On put, if an existing entry has at least as
-- many pixels as the incoming bb, the incoming bb is unused (caller must
-- treat it as never cached — free it if they owned it) and the existing
-- entry is kept. If the incoming bb is larger, it replaces the entry. This
-- means the FIRST consumer built in a session seeds the cache at its size;
-- a later, larger consumer (e.g. CoverDeck's hero after Recent's small
-- thumbnail) upgrades it; smaller consumers thereafter read the larger
-- bitmap and downscale. Stable regardless of build order.
--
-- Get returns whatever bb is cached, at ANY dimensions — the caller is
-- responsible for comparing it against its own target slot:
--   * cached >= target in both axes → use it, let ImageWidget downscale
--     at paint time (the safe direction on every device this plugin
--     targets, Kindle included).
--   * cached < target in either axis → treat as a miss: decode+stretch a
--     fresh bb at the target size (which will then upgrade the cache via
--     put's prefer-larger rule). NEVER hand a too-small cached bb to
--     ImageWidget expecting it to upscale — that is the corruption-prone
--     path this module deliberately never takes. See the "Upscale safety"
--     note below.
--
-- Lifetime: the cache holds a strong reference to each cached bb. Callers
-- pass it to ImageWidget with image_disposable = false. When the cache
-- drops an entry (eviction or prefer-larger replace) it only nils its own
-- reference — it does NOT call bb:free(). Other live widgets may still
-- hold that bb (e.g. a Recent thumbnail whose shared entry just got
-- upgraded to CoverDeck-hero dimensions by a later put); an explicit free
-- here would yank the C memory out from under those widgets' next partial
-- repaint. Blitbuffer sets up an ffi.gc finalizer at allocation time (see
-- ffi/blitbuffer.lua's setAllocated(1)), so the underlying C memory is
-- reclaimed automatically once every Lua reference is gone. Slight
-- memory-reclaim latency, never a use-after-free.
--
-- clear() follows the same rule — it drops references, it doesn't free.
--
-- Upscale safety: this cache never performs, and never asks ImageWidget to
-- perform, an upscale of a bb that's smaller than the requested slot.
-- SimpleUI's own cover-scaling code (infra/sui_config.lua's
-- _scaleBBToSlot) already documents blitbuffer corruption ("TV static" on
-- repaint) tied to exactly this class of mistake — ownership confusion
-- around scale/free on a buffer that's reused across calls. The contract
-- this module expects from its caller is: only ever call get() to decide
-- whether a fresh decode+stretch is needed; only ever call put() with a bb
-- that was just produced by a stretch to AT LEAST the caller's own target
-- size. Never construct an ImageWidget from a get() result that is smaller
-- than the target slot.

local logger = require("logger")

-- Per-cover cache logging is verbose (one line per PUT/EVICT) and, because
-- Lua evaluates the string.format() argument before logger.dbg can discard
-- it at the info level, the format cost is paid on every cover even with
-- debug logging off. Gate it behind a constant so production pays nothing;
-- flip to true when diagnosing cache churn.
local _PERF_LOG = false

-- Resident byte size of a cached cover bb. `stride` is the bytes-per-row of
-- the underlying C allocation, so `stride * h` is the true RAM footprint
-- INCLUDING any row padding — and it scales correctly with both cover
-- dimensions and bit depth (1 byte/px on grayscale e-ink vs 4 bytes/px
-- RGB32 on a colour panel) without the cache needing to know the device
-- type. This is why the cache is bounded by BYTES, not entry count: "40
-- covers" is a few MiB of small grayscale thumbnails or tens of MiB of
-- large colour hero covers — same count, very different RAM.
local function _bbBytes(bb)
    if not bb then return 0 end
    local ok, n = pcall(function()
        local h = (bb.getHeight and bb:getHeight()) or tonumber(bb.h) or 0
        local stride = tonumber(bb.stride)
        if stride and h > 0 then return stride * h end
        local w   = (bb.getWidth and bb:getWidth()) or 0
        local bpp = (bb.getBpp and bb:getBpp()) or 8
        return w * h * math.ceil(bpp / 8)
    end)
    return (ok and n) or 0
end

local SUICoverCache = {
    -- Bounded by RAM, in BYTES — see _bbBytes above. ~20 MiB default:
    -- replaces the old exact-size cache (8 MiB) + the per-book duplication
    -- a separate canonical-crop cache (4 MiB) existed to work around, at
    -- roughly the same combined footprint, but without holding
    -- near-duplicate entries for the same book at nearly the same size
    -- across two separate tables.
    --
    -- _capacity is a non-user-facing entry-COUNT backstop, kept only to
    -- bound the O(n) _order scans in get/put and guard against a
    -- pathological many-tiny-covers case. Set high enough that the byte
    -- budget always binds first for normal budgets.
    _capacity    = 512,
    _byte_budget = 20 * 1024 * 1024,
    _bytes       = 0,   -- running sum of resident entry bytes (see _sizes)
    _cache       = {},  -- filepath -> bb
    _order       = {},  -- list of filepaths, oldest at front, MRU at back
    _sizes       = {},  -- filepath -> bytes, so evict/replace adjust _bytes O(1)
    _hits        = 0,   -- perf: cache hits this session
    _puts        = 0,   -- perf: cache misses (fresh stretch) this session
    _evictions   = 0,   -- perf: evictions this session
}

-- setCapacity(n) — adjust the entry-COUNT backstop. Not user-facing: the
-- RAM bound is _byte_budget. Retained for completeness/tuning; raising it
-- lets more covers stay resident (until the byte budget binds), lowering
-- it evicts down immediately.
function SUICoverCache:setCapacity(n)
    n = tonumber(n)
    if not n then return end
    n = math.floor(n)
    if n < 1 then n = 1 end
    if n == self._capacity then return end
    self._capacity = n
    self:_evictIfNeeded()
end

-- setByteBudget(bytes) — hard cap on total resident cover bytes. Evicts
-- immediately if the new budget is smaller than current usage.
function SUICoverCache:setByteBudget(bytes)
    bytes = tonumber(bytes)
    if not bytes then return end
    bytes = math.floor(bytes)
    if bytes < 1 then return end
    if bytes == self._byte_budget then return end
    self._byte_budget = bytes
    self:_evictIfNeeded()
end

function SUICoverCache:_removeKey(key)
    for i, k in ipairs(self._order) do
        if k == key then
            table.remove(self._order, i)
            return
        end
    end
end

function SUICoverCache:_evictIfNeeded()
    -- Evict oldest until BOTH bounds hold: entry count <= capacity AND
    -- resident bytes <= byte budget. Keep at least the most-recently
    -- inserted entry (#order > 1 guard) so a single oversized cover can't
    -- evict itself right after being cached.
    while #self._order > 1
          and (#self._order > self._capacity or self._bytes > self._byte_budget) do
        local key = table.remove(self._order, 1)
        -- Drop the cache's reference only. Don't call bb:free() — see the
        -- lifetime note at the top of this file; ImageWidgets that still
        -- hold this bb would render garbage pixels on their next paint.
        self._cache[key] = nil
        self._bytes = self._bytes - (self._sizes[key] or 0)
        if self._bytes < 0 then self._bytes = 0 end
        self._sizes[key] = nil
        self._evictions = self._evictions + 1
        if _PERF_LOG then logger.dbg(string.format(
            "[simpleui perf] SUICoverCache: EVICT fp=%s size=%d/%d bytes=%d/%d",
            key, #self._order, self._capacity, self._bytes, self._byte_budget)) end
    end
end

-- get(filepath) — returns the cached bb (at whatever dimensions it was last
-- put at) or nil. On hit, the entry is promoted to MRU. Caller MUST compare
-- the returned bb's dimensions against its own target slot — see the
-- "Upscale safety" note at the top of this file.
function SUICoverCache:get(filepath)
    if not filepath or filepath == "" then return nil end
    local bb = self._cache[filepath]
    if not bb then return nil end
    self._hits = self._hits + 1
    self:_removeKey(filepath)
    self._order[#self._order + 1] = filepath
    return bb
end

-- has(filepath) — boolean probe. Doesn't touch MRU order or counters. Lets
-- a caller skip a slow BookInfoManager decode when the cover is already
-- resident (the cache-first check should still call get() to actually use
-- the bb — this is only for "is it worth trying the fast path at all").
function SUICoverCache:has(filepath)
    if not filepath or filepath == "" then return false end
    return self._cache[filepath] ~= nil
end

-- put(filepath, bb) — insert or upgrade. Returns the bb now serving as the
-- cache entry for filepath, which is NOT always the bb the caller passed
-- in. Prefer-larger semantics:
--   * No existing entry: cache the new bb. Returns new bb.
--   * Existing entry with >= pixel count: keep existing, return the
--     existing bb. The caller's bb is unused — the caller MUST treat the
--     passed-in bb as if it were never put (don't hand it to an
--     ImageWidget expecting cache ownership; free() it if the caller
--     owned it and has no other use for it).
--   * Existing entry with < pixel count: install new as the cache entry.
--     The existing bb is no longer in the cache but is NOT freed — other
--     widgets may still hold references and need to paint with it before
--     LuaJIT's FFI finalizer reclaims it. Returns new bb.
--
-- Callers should use the return value to decide what to paint with; this
-- avoids a redundant get() round-trip and makes the discard case explicit
-- at the call site.
function SUICoverCache:put(filepath, bb)
    if not filepath or filepath == "" then return bb end
    if not bb then return bb end
    local existing = self._cache[filepath]
    if existing == bb then
        return bb  -- identity put (no-op)
    end
    if existing then
        local ex_px  = (existing.getWidth and existing:getWidth() or 0)
                     * (existing.getHeight and existing:getHeight() or 0)
        local new_px = (bb.getWidth      and bb:getWidth()      or 0)
                     * (bb.getHeight     and bb:getHeight()     or 0)
        if ex_px >= new_px then
            -- Keep existing; touch MRU. Do NOT free the caller's bb — they
            -- may have another use for it. Returning existing tells the
            -- caller "use this instead".
            self:_removeKey(filepath)
            self._order[#self._order + 1] = filepath
            return existing
        end
        -- New is larger; replace the cache reference. Do NOT free existing
        -- — other live widgets may still hold it (see lifetime note at the
        -- top of this file). Drop the old entry's byte accounting; the new
        -- size is added below.
        self:_removeKey(filepath)
        self._bytes = self._bytes - (self._sizes[filepath] or 0)
        if self._bytes < 0 then self._bytes = 0 end
        self._sizes[filepath] = nil
    end
    self._cache[filepath] = bb
    self._order[#self._order + 1] = filepath
    local nbytes = _bbBytes(bb)
    self._sizes[filepath] = nbytes
    self._bytes = self._bytes + nbytes
    self._puts = self._puts + 1
    if _PERF_LOG then logger.dbg(string.format(
        "[simpleui perf] SUICoverCache: PUT fp=%s %dx%d size=%d/%d bytes=%d/%d hits=%d puts=%d",
        filepath,
        (bb.getWidth and bb:getWidth() or 0),
        (bb.getHeight and bb:getHeight() or 0),
        #self._order, self._capacity, self._bytes, self._byte_budget,
        self._hits, self._puts)) end
    self:_evictIfNeeded()
    return bb
end

-- drop(filepath) — surgical eviction for a single book. For callers that
-- know that book's source cover changed out of band (manual cover
-- override, metadata refresh) and the next render must re-decode rather
-- than serve a stale stretched bb. Same lifetime contract as put/clear:
-- drops the reference, doesn't bb:free().
function SUICoverCache:drop(filepath)
    if not filepath or filepath == "" then return end
    if self._cache[filepath] == nil then return end
    self._bytes = self._bytes - (self._sizes[filepath] or 0)
    if self._bytes < 0 then self._bytes = 0 end
    self._cache[filepath] = nil
    self._sizes[filepath] = nil
    self:_removeKey(filepath)
end

-- clear() — drop every cached reference. Same lifetime contract as put: we
-- do NOT explicitly free; live widgets may still be holding bbs. LuaJIT
-- reclaims once every reference is gone.
function SUICoverCache:clear()
    if _PERF_LOG then logger.dbg(string.format(
        "[simpleui perf] SUICoverCache: clear hits=%d puts=%d evictions=%d",
        self._hits, self._puts, self._evictions)) end
    self._cache     = {}
    self._order     = {}
    self._sizes     = {}
    self._bytes     = 0
    self._hits      = 0
    self._puts      = 0
    self._evictions = 0
end

return SUICoverCache
