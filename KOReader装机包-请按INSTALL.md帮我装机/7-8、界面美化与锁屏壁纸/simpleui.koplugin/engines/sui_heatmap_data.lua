-- sui_heatmap_data.lua — Simple UI
-- Reading-heatmap data layer: two SQL aggregates over page_stat (daily
-- seconds, and weekday x hour-of-day seconds) plus the day arithmetic
-- needed to slice that data into "N-week blocks" for paging back through
-- history. No widgets here — this file only knows about numbers and
-- timestamps; engines/sui_heatmap_widgets.lua turns them into pixels.
--
-- Both queries group by id_book/page/day(/hour) before summing duration,
-- so a page re-read across multiple sessions on the same day (or same
-- hour, for the weekday/hour breakdown) is only counted once — matches
-- how module_stats_provider.lua already treats page_stat elsewhere in
-- this plugin.

local Config = require("infra/sui_config")

local HD = {}

local DAY = 86400

-- ---------------------------------------------------------------------------
-- DB access
-- ---------------------------------------------------------------------------
-- Runs `sql`, calling row_fn(row) for every returned row. Uses shared_conn
-- when given (the homescreen's own ctx.db_conn — no new connection opened);
-- otherwise opens and closes a short-lived one via Config.openStatsDB(),
-- same as the standalone stats windows in screens/sui_stats_windows.lua.
-- Returns true/false plus the pcall error (for Config.isFatalDbError) on
-- failure.
local function runQuery(shared_conn, sql, row_fn)
    local function exec(conn)
        local stmt = conn:prepare(sql)
        for row in stmt:rows() do row_fn(row) end
        stmt:close()
    end
    if shared_conn then
        local ok, err = pcall(exec, shared_conn)
        return ok, err
    end
    local conn = Config.openStatsDB()
    if not conn then return false, "no_db" end
    local ok, err = pcall(exec, conn)
    pcall(conn.close, conn)
    return ok, err
end

-- ---------------------------------------------------------------------------
-- Cache — per exact [start,end] range, rebuilt at most once per day
-- ---------------------------------------------------------------------------
local _cache = { daily = {}, weekday_hour = {}, earliest = nil }

function HD.invalidate()
    _cache.daily         = {}
    _cache.weekday_hour  = {}
    _cache.earliest      = nil
end

-- ---------------------------------------------------------------------------
-- Range arithmetic
-- ---------------------------------------------------------------------------
-- Inclusive [start_t, end_t] (both at noon, clear of DST edge cases) for the
-- block of `weeks` weeks that is `blocks_back` blocks before the current
-- one: block 0 ends today and starts (weeks*7 - 1) days earlier; block 1
-- covers the same span immediately before block 0, and so on. Relies on
-- os.time's normalisation of out-of-range day values, the same trick used
-- for month arithmetic elsewhere in this codebase's date handling.
function HD.getWeekBlockRange(weeks, blocks_back)
    weeks       = weeks or 12
    blocks_back = blocks_back or 0
    local today = os.date("*t")
    local end_t = os.time({
        year = today.year, month = today.month,
        day  = today.day - (weeks * 7) * blocks_back,
        hour = 12,
    })
    local start_t = os.time({
        year = today.year, month = today.month,
        day  = today.day - (weeks * 7) * (blocks_back + 1) + 1,
        hour = 12,
    })
    return start_t, end_t
end

-- How many blocks back from the current one (0) still reach into a period
-- with recorded reading (earliest_t, from HD.getEarliestStartTime). Small
-- loop rather than closed-form maths, to stay in lockstep with
-- HD.getWeekBlockRange's own definition of a block boundary.
function HD.maxBlocksBack(weeks, earliest_t)
    if not earliest_t or earliest_t <= 0 then return 0 end
    local blocks_back = 0
    while blocks_back < 500 do
        local _, block_end = HD.getWeekBlockRange(weeks, blocks_back + 1)
        if block_end < earliest_t then break end
        blocks_back = blocks_back + 1
    end
    return blocks_back
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------
-- Returns { ["YYYY-MM-DD"] = seconds_read } for every day with any reading
-- in the inclusive [start_t, end_t] range.
function HD.getDailyReadingData(start_t, end_t, shared_conn)
    local start_str = os.date("%Y-%m-%d", start_t)
    local end_str   = os.date("%Y-%m-%d", end_t)
    local today     = os.date("%Y-%m-%d")
    local cache_key = start_str .. ".." .. end_str

    local hit = _cache.daily[cache_key]
    if hit and hit.day == today then return hit.data end

    local sql = string.format([[
        SELECT day, SUM(dur) AS duration
        FROM (
            SELECT id_book, page,
                   date(start_time, 'unixepoch', 'localtime') AS day,
                   SUM(duration) AS dur
            FROM page_stat
            WHERE date(start_time, 'unixepoch', 'localtime') BETWEEN '%s' AND '%s'
            GROUP BY id_book, page, day
        )
        GROUP BY day
    ]], start_str, end_str)

    local data = {}
    local ok, err = runQuery(shared_conn, sql, function(row)
        data[row[1]] = tonumber(row[2]) or 0
    end)
    if not ok then
        return {}, Config.isFatalDbError(err)
    end

    _cache.daily[cache_key] = { day = today, data = data }
    return data, false
end

-- Returns { [1..7] = { [0..23] = seconds_read } }, 1 = Monday, for the
-- inclusive [start_t, end_t] range.
function HD.getWeekdayHourReadingData(start_t, end_t, shared_conn)
    local start_str = os.date("%Y-%m-%d", start_t)
    local end_str   = os.date("%Y-%m-%d", end_t)
    local today     = os.date("%Y-%m-%d")
    local cache_key = start_str .. ".." .. end_str

    local hit = _cache.weekday_hour[cache_key]
    if hit and hit.day == today then return hit.data end

    local sql = string.format([[
        SELECT dow, hour, SUM(dur) AS duration
        FROM (
            SELECT id_book, page,
                   strftime('%%w', start_time, 'unixepoch', 'localtime') AS dow,
                   CAST(strftime('%%H', start_time, 'unixepoch', 'localtime') AS INTEGER) AS hour,
                   date(start_time, 'unixepoch', 'localtime') AS day,
                   SUM(duration) AS dur
            FROM page_stat
            WHERE date(start_time, 'unixepoch', 'localtime') BETWEEN '%s' AND '%s'
            GROUP BY id_book, page, day, dow, hour
        )
        GROUP BY dow, hour
    ]], start_str, end_str)

    local data = {}
    for wd = 1, 7 do
        data[wd] = {}
        for h = 0, 23 do data[wd][h] = 0 end
    end

    local ok, err = runQuery(shared_conn, sql, function(row)
        local dow_sun0 = tonumber(row[1]) or 0   -- 0=Sun..6=Sat
        local wd       = ((dow_sun0 + 6) % 7) + 1  -- 1=Mon..7=Sun
        local hour     = tonumber(row[2]) or 0
        data[wd][hour] = tonumber(row[3]) or 0
    end)
    if not ok then
        return data, Config.isFatalDbError(err)
    end

    _cache.weekday_hour[cache_key] = { day = today, data = data }
    return data, false
end

-- Cheap "did anything change" probe (single MAX(start_time) read) for
-- callers that want to skip a re-query when nothing new was read.
function HD.getMaxStartTime(shared_conn)
    local max_t = 0
    runQuery(shared_conn, "SELECT MAX(start_time) FROM page_stat", function(row)
        max_t = tonumber(row[1]) or 0
    end)
    return max_t
end

-- Epoch seconds of the very first page_stat row, or 0 if none. Cached
-- indefinitely (until HD.invalidate()) since it only moves forward and is
-- cheap enough not to bother with the daily TTL the other two caches use.
function HD.getEarliestStartTime(shared_conn)
    if _cache.earliest ~= nil then return _cache.earliest end
    local t = 0
    runQuery(shared_conn, "SELECT MIN(start_time) FROM page_stat", function(row)
        t = tonumber(row[1]) or 0
    end)
    _cache.earliest = t
    return t
end

return HD
