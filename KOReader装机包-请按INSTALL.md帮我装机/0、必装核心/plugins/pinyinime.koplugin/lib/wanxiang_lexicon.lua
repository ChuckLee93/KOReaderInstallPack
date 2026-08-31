local SQ3 = require("lua-ljsqlite3/init")

local WanxiangLexicon = {}

local APPLICATION_ID = 0x50494D45 -- "PIME"
local SCHEMA_VERSION = 5
local NORMALIZATION_VERSION = "1"
local REQUIRED_CAPABILITIES = {
    phrase = true,
    code_head = true,
    prediction = true,
    prediction_head = true,
    academic_supplement = true,
}
local DEFAULT_LIMIT = 4
local MAX_LIMIT = 24
local MAX_CACHE_ENTRIES = 512
local MAX_CODE_LENGTH = 256
local MAX_PREDICTION_KEYS = 5
local MAX_PREDICTION_LIMIT = 5
local MAX_PREDICTION_CACHE_ENTRIES = 128
local MAX_CONTEXT_LENGTH = 64
local MAX_HEAD_CODES = 12
local MAX_HEAD_CANDIDATES = 8
local MAX_HEAD_CACHE_ENTRIES = 512
local MAX_MIXED_CACHE_ENTRIES = 128
local MIXED_BLOOM_BYTES = 256 * 1024
local MIXED_BLOOM_BITS = MIXED_BLOOM_BYTES * 8

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local plugin_root = source:match("^(.*)/lib/wanxiang_lexicon%.lua$")
local default_path = plugin_root and (plugin_root .. "/data/wanxiang.sqlite3")

local MAX_BATCH_CODES = 12
local LOOKUP_SQL = [[
SELECT code, text, lexical_score, rank, source_mask, source_penalty,
       character_count
FROM phrase
WHERE code IN (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  AND rank <= ?
ORDER BY code, rank
]]
local SUPPLEMENT_LOOKUP_SQL = [[
SELECT code, text, lexical_score, rank, source_mask, source_penalty,
       character_count
FROM phrase_supplement
WHERE code IN (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  AND rank <= ?
ORDER BY code, rank
]]
local LICENSED_EXTENSION_LOOKUP_SQL = [[
SELECT code, text, lexical_score, rank, source_mask, source_penalty,
       character_count
FROM licensed_phrase_extension
WHERE code IN (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  AND rank <= ?
ORDER BY code, tier, rank
]]
local MIXED_LOOKUP_SQL = [[
SELECT h.rank, c.code, c.text, c.lexical_score, c.source_mask,
       c.source_penalty
FROM mixed_head h
JOIN mixed_candidate c ON c.candidate_id = h.candidate_id
WHERE h.mixed_key = ? AND h.rank <= ?
ORDER BY h.rank
]]
local PREDICTION_SQL = [[
SELECT context, next_text, rank, quality, source_mask, flags
FROM prediction
WHERE context IN (?, ?, ?, ?, ?)
  AND rank <= 5
ORDER BY context, rank
]]
local PREDICTION_FLAG_SAFE_BACKOFF = 32
local PREDICTION_FLAG_SENTENCE = 16
local CODE_HEAD_SQL = [[
SELECT code,
       candidate1, chars1, score1, source1, penalty1,
       candidate2, chars2, score2, source2, penalty2,
       candidate3, chars3, score3, source3, penalty3,
       candidate4, chars4, score4, source4, penalty4,
       candidate5, chars5, score5, source5, penalty5,
       candidate6, chars6, score6, source6, penalty6,
       candidate7, chars7, score7, source7, penalty7,
       candidate8, chars8, score8, source8, penalty8
FROM code_head
WHERE code IN (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
]]
local PREDICTION_HEAD_SQL = [[
SELECT context,
       candidate1, quality1, source1, flags1,
       candidate2, quality2, source2, flags2,
       candidate3, quality3, source3, flags3,
       candidate4, quality4, source4, flags4,
       candidate5, quality5, source5, flags5
FROM prediction_head
WHERE context IN (?, ?, ?, ?, ?)
]]

-- Semantic sentence tails are useful across longer contexts, but a directly
-- preceding negation or yes/no frame reverses their meaning. Keep this guard
-- deliberately small and local: the engine already supplies at most twelve
-- Han characters, and only suffix rows marked both SENTENCE and SAFE_BACKOFF
-- consult it. Fixed completions, character continuations, and exact matches
-- never enter this path.
local SEMANTIC_SUFFIX_LEFT_GUARDS = {
    "未", "没", "不", "否", "非", "无",
    "无法", "不能", "没有", "未能", "不再", "不曾",
}

local REQUIRED_METADATA = {
    normalization_version = NORMALIZATION_VERSION,
}

local function parseCapabilities(value)
    local capabilities = {}
    if type(value) == "string" then
        for capability in value:gmatch("[^,]+") do
            if capability:match("^[a-z][a-z0-9_]*$") then
                capabilities[capability] = true
            end
        end
    end
    return capabilities
end

local function copyCapabilities(capabilities)
    local result = {}
    for capability, enabled in pairs(capabilities or {}) do
        result[capability] = enabled == true
    end
    return result
end

local function oneLine(value)
    local message = tostring(value or "unknown SQLite error")
    return message:match("^[^\r\n]+") or message
end

local function normalizeLimit(limit)
    limit = tonumber(limit)
    if not limit or limit ~= limit or limit == math.huge or limit == -math.huge then
        return DEFAULT_LIMIT
    end
    return math.max(1, math.min(MAX_LIMIT, math.floor(limit)))
end

local function validCode(code)
    return type(code) == "string"
        and #code > 0
        and #code <= MAX_CODE_LENGTH
        and not code:find("[^a-z']")
        and code:sub(1, 1) ~= "'"
        and code:sub(-1) ~= "'"
        and not code:find("''", 1, true)
end

local function validMixedKey(key)
    return type(key) == "string" and #key > 1 and #key <= MAX_CODE_LENGTH
        and not key:find("[^a-z]")
end

local function validContext(context)
    return type(context) == "string"
        and #context > 0
        and #context <= MAX_CONTEXT_LENGTH
        and not context:find("[%z\1-\31\127]")
end

local function normalizePredictionLimit(limit)
    limit = tonumber(limit)
    if not limit or limit ~= limit or limit == math.huge or limit == -math.huge then
        return MAX_PREDICTION_LIMIT
    end
    return math.max(1, math.min(MAX_PREDICTION_LIMIT, math.floor(limit)))
end

local function copyTexts(rows, limit)
    local result = {}
    for index = 1, math.min(#rows, limit) do
        result[index] = rows[index].text
    end
    return result
end

local function copyPredictionRows(rows, context, limit)
    local result = {}
    for index = 1, math.min(#rows, limit) do
        local row = rows[index]
        result[index] = {
            text = row.text,
            rank = row.rank,
            quality = row.quality,
            source_mask = row.source_mask,
            flags = row.flags,
            context = context,
        }
    end
    return result
end

local function hasFlag(flags, flag)
    return math.floor(flags / flag) % 2 == 1
end

local function guardedSemanticSuffix(full_context, suffix_context)
    if full_context == suffix_context or #full_context <= #suffix_context
            or full_context:sub(-#suffix_context) ~= suffix_context then
        return false
    end
    local boundary = #full_context - #suffix_context
    for _, guard in ipairs(SEMANTIC_SUFFIX_LEFT_GUARDS) do
        local first = boundary - #guard + 1
        if first >= 1 and full_context:sub(first, boundary) == guard then
            return true
        end
    end
    return false
end

local function validInteger(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
        and value == math.floor(value)
end

local function copyRows(rows, limit)
    local result = {}
    local count = math.min(#rows, limit)
    for index = 1, count do
        local row = rows[index]
        result[index] = {
            text = row.text,
            score = row.score,
            rank = row.rank,
            source = row.source,
            source_penalty = row.source_penalty,
            character_count = row.character_count,
        }
    end
    return result
end

local function copyMixedRows(rows, limit)
    local result = {}
    for index = 1, math.min(#rows, limit) do
        local row = rows[index]
        result[index] = {
            text = row.text,
            code = row.code,
            score = row.score,
            rank = row.rank,
            source = row.source,
            source_penalty = row.source_penalty,
        }
    end
    return result
end

local function mixedBloomPositions(key)
    local first, second = 7, 13
    for index = 1, #key do
        local value = key:byte(index)
        first = (first * 131 + value) % MIXED_BLOOM_BITS
        second = (second * 137 + value) % MIXED_BLOOM_BITS
    end
    if second == 0 then second = 1 end
    return {
        first,
        (first + second + 17) % MIXED_BLOOM_BITS,
        (first + 2 * second + 68) % MIXED_BLOOM_BITS,
        (first + 3 * second + 153) % MIXED_BLOOM_BITS,
    }
end

function WanxiangLexicon:new(options)
    if type(options) == "string" then
        options = { path = options }
    end
    options = options or {}
    local instance = {
        path = options.path or default_path,
        supplement_path = options.supplement_path,
        mixed_bloom_path = options.mixed_bloom_path,
        on_error = options.on_error,
        _available = nil,
        _failed = false,
        _closed = false,
        _db = nil,
        _supplement_db = nil,
        _supplement_metadata = nil,
        _supplement_disabled = false,
        _lookup_stmt = nil,
        _supplement_stmt = nil,
        _licensed_extension_stmt = nil,
        _mixed_stmt = nil,
        _mixed_disabled = false,
        _mixed_bloom = nil,
        _prediction_stmt = nil,
        _prediction_disabled = false,
        _head_stmt = nil,
        _head_disabled = false,
        _prediction_head_stmt = nil,
        _prediction_head_disabled = false,
        _metadata = nil,
        _capabilities = {},
        _schema_version = nil,
        _cache = {},
        _cache_head = nil,
        _cache_tail = nil,
        _prediction_cache = {},
        _prediction_cache_head = nil,
        _prediction_cache_tail = nil,
        _head_cache = {},
        _head_cache_head = nil,
        _head_cache_tail = nil,
        _mixed_cache = {},
        _mixed_cache_head = nil,
        _mixed_cache_tail = nil,
        _stats = {
            lookups = 0,
            cache_hits = 0,
            cache_misses = 0,
            queries = 0,
            rows = 0,
            supplement_queries = 0,
            supplement_rows = 0,
            licensed_extension_queries = 0,
            licensed_extension_rows = 0,
            mixed_lookups = 0,
            mixed_bloom_negatives = 0,
            mixed_queries = 0,
            mixed_rows = 0,
            mixed_cache_hits = 0,
            mixed_cache_misses = 0,
            mixed_cache_entries = 0,
            main_only_lookups = 0,
            main_only_queries = 0,
            main_only_rows = 0,
            cache_entries = 0,
            prediction_lookups = 0,
            prediction_cache_hits = 0,
            prediction_cache_misses = 0,
            prediction_queries = 0,
            prediction_rows = 0,
            prediction_cache_entries = 0,
            head_lookups = 0,
            head_cache_hits = 0,
            head_cache_misses = 0,
            head_queries = 0,
            head_rows = 0,
            head_cache_entries = 0,
            prediction_head_queries = 0,
            prediction_head_rows = 0,
        },
    }
    setmetatable(instance, self)
    self.__index = self
    return instance
end

function WanxiangLexicon:_closeResources()
    if self._mixed_stmt then
        pcall(self._mixed_stmt.close, self._mixed_stmt)
        self._mixed_stmt = nil
    end
    if self._licensed_extension_stmt then
        pcall(self._licensed_extension_stmt.close, self._licensed_extension_stmt)
        self._licensed_extension_stmt = nil
    end
    if self._prediction_head_stmt then
        pcall(self._prediction_head_stmt.close, self._prediction_head_stmt)
        self._prediction_head_stmt = nil
    end
    if self._head_stmt then
        pcall(self._head_stmt.close, self._head_stmt)
        self._head_stmt = nil
    end
    if self._prediction_stmt then
        pcall(self._prediction_stmt.close, self._prediction_stmt)
        self._prediction_stmt = nil
    end
    if self._lookup_stmt then
        pcall(self._lookup_stmt.close, self._lookup_stmt)
        self._lookup_stmt = nil
    end
    if self._supplement_stmt then
        pcall(self._supplement_stmt.close, self._supplement_stmt)
        self._supplement_stmt = nil
    end
    if self._supplement_db then
        pcall(self._supplement_db.close, self._supplement_db)
        self._supplement_db = nil
    end
    if self._db then
        pcall(self._db.close, self._db)
        self._db = nil
    end
end

function WanxiangLexicon:_fail(reason)
    if self._failed then
        return false
    end
    self._failed = true
    self._available = false
    self._error = oneLine(reason)
    self:_closeResources()
    if type(self.on_error) == "function" then
        pcall(self.on_error, self._error)
    end
    return false
end

function WanxiangLexicon:_readMetadata(db)
    local stmt = db:prepare("SELECT key, value FROM metadata")
    local metadata = {}
    local ok, err = pcall(function()
        for row in stmt:rows() do
            if type(row[1]) ~= "string" or type(row[2]) ~= "string" then
                error("invalid metadata row")
            end
            metadata[row[1]] = row[2]
        end
    end)
    pcall(stmt.close, stmt)
    if not ok then
        error(err)
    end
    return metadata
end

function WanxiangLexicon:_validateMetadata(metadata, schema_version)
    for key, expected in pairs(REQUIRED_METADATA) do
        if metadata[key] ~= expected then
            error(string.format("unsupported %s: %s", key, tostring(metadata[key])))
        end
    end
    if metadata.schema_version ~= tostring(schema_version) then
        error(string.format("unsupported schema_version: %s", tostring(metadata.schema_version)))
    end
    if schema_version ~= SCHEMA_VERSION then
        error(string.format("unsupported schema_version: %s", tostring(schema_version)))
    end
    if type(metadata.wanxiang_commit) ~= "string"
            or not metadata.wanxiang_commit:match("^[0-9a-fA-F]+$")
            or #metadata.wanxiang_commit ~= 40 then
        error("missing or invalid wanxiang_commit metadata")
    end
    if type(metadata.builder_version) ~= "string" or metadata.builder_version == "" then
        error("missing builder_version metadata")
    end
    local capabilities = parseCapabilities(metadata.capabilities)
    for capability in pairs(REQUIRED_CAPABILITIES) do
        if not capabilities[capability] then
            error("missing required V5 capability: " .. capability)
        end
    end
    if capabilities.composition_context or capabilities.token_transition then
        error("unsupported V5 runtime capability")
    end
    return capabilities
end

function WanxiangLexicon:_ensureSupplementOpen()
    if self._supplement_stmt then
        return true
    elseif self._supplement_disabled or self._closed then
        return false
    end
    local supplement_path = self.supplement_path
    if supplement_path == nil then
        local directory = self.path:match("^(.*)/[^/]+$")
        supplement_path = directory and (directory .. "/academic_supplement.sqlite3")
    end
    if type(supplement_path) ~= "string" or supplement_path == "" then
        self._supplement_disabled = true
        return false
    end
    local file = io.open(supplement_path, "rb")
    if not file then
        self._supplement_disabled = true
        self._stats.supplement_error = "academic supplement is unavailable"
        return false
    end
    file:close()

    local ok, err = pcall(function()
        local db = SQ3.open(supplement_path, "ro")
        self._supplement_db = db
        db:exec([[
            PRAGMA query_only = ON;
            PRAGMA temp_store = MEMORY;
            PRAGMA cache_size = -1024;
        ]])
        local application_id = tonumber(db:rowexec("PRAGMA application_id"))
        local schema_version = tonumber(db:rowexec("PRAGMA user_version"))
        if application_id ~= APPLICATION_ID or schema_version ~= SCHEMA_VERSION then
            error("unsupported academic supplement database")
        end
        local metadata = self:_readMetadata(db)
        local main_metadata = self._supplement_metadata or {}
        if metadata.schema_version ~= tostring(SCHEMA_VERSION)
                or metadata.normalization_version ~= NORMALIZATION_VERSION
                or metadata.wanxiang_commit ~= main_metadata.wanxiang_commit
                or metadata.builder_version ~= "academic-supplement-v5" then
            error("academic supplement metadata mismatch")
        end
        self._supplement_stmt = db:prepare(SUPPLEMENT_LOOKUP_SQL)
        local extensions = parseCapabilities(metadata.supplement_capabilities)
        if extensions.licensed_phrase_extension then
            self._licensed_extension_stmt = db:prepare(
                LICENSED_EXTENSION_LOOKUP_SQL)
        end
        if extensions.mixed_head or extensions.mixed_candidate then
            if not extensions.mixed_head or not extensions.mixed_candidate then
                error("incomplete mixed-pinyin supplement capability")
            end
            self._mixed_stmt = db:prepare(MIXED_LOOKUP_SQL)
        else
            self._mixed_disabled = true
        end
        self._supplement_extension_metadata = metadata
    end)
    if not ok then
        self._supplement_stmt = nil
        self._licensed_extension_stmt = nil
        self._mixed_stmt = nil
        if self._supplement_db then
            pcall(self._supplement_db.close, self._supplement_db)
            self._supplement_db = nil
        end
        self._supplement_disabled = true
        self._stats.supplement_error = oneLine(err)
        return false
    end
    return true
end

function WanxiangLexicon:_ensureOpen()
    if self._available == true then
        return true
    elseif self._failed or self._closed then
        return false
    elseif type(self.path) ~= "string" or self.path == "" then
        return self:_fail("Wanxiang database path is unavailable")
    end

    local ok, err = pcall(function()
        self._db = SQ3.open(self.path, "ro")
        self._db:exec([[
            PRAGMA query_only = ON;
            PRAGMA temp_store = MEMORY;
            PRAGMA cache_size = -2048;
        ]])

        local application_id = tonumber(self._db:rowexec("PRAGMA application_id"))
        if application_id ~= APPLICATION_ID then
            error(string.format("unsupported application_id: %s", tostring(application_id)))
        end
        local schema_version = tonumber(self._db:rowexec("PRAGMA user_version"))
        if schema_version ~= SCHEMA_VERSION then
            error(string.format("unsupported user_version: %s", tostring(schema_version)))
        end

        local metadata = self:_readMetadata(self._db)
        local capabilities = self:_validateMetadata(metadata, schema_version)
        self._lookup_stmt = self._db:prepare(LOOKUP_SQL)
        self._supplement_metadata = metadata
        self._metadata = metadata
        self._capabilities = capabilities
        self._schema_version = schema_version
        -- Every declared core V5 capability is mandatory. A manifest/table
        -- mismatch rejects the database and lets the runtime use its Lua
        -- compatibility lexicon instead of running a partially described V5.
        self._prediction_stmt = self._db:prepare(PREDICTION_SQL)
        self._head_stmt = self._db:prepare(CODE_HEAD_SQL)
        self._prediction_head_stmt = self._db:prepare(PREDICTION_HEAD_SQL)
    end)
    if not ok then
        return self:_fail(err)
    end
    self._available = true
    return true
end

function WanxiangLexicon:_packedCacheUnlink(prefix, node)
    local head_key = "_" .. prefix .. "_cache_head"
    local tail_key = "_" .. prefix .. "_cache_tail"
    if node.previous then
        node.previous.next = node.next
    else
        self[head_key] = node.next
    end
    if node.next then
        node.next.previous = node.previous
    else
        self[tail_key] = node.previous
    end
    node.previous, node.next = nil, nil
end

function WanxiangLexicon:_packedCacheTouch(prefix, node)
    local head_key = "_" .. prefix .. "_cache_head"
    local tail_key = "_" .. prefix .. "_cache_tail"
    if self[head_key] == node then
        return
    end
    if node.previous or node.next or self[tail_key] == node then
        self:_packedCacheUnlink(prefix, node)
    end
    node.next = self[head_key]
    if self[head_key] then
        self[head_key].previous = node
    else
        self[tail_key] = node
    end
    self[head_key] = node
end

function WanxiangLexicon:_packedCacheStore(prefix, key, value, maximum, stat_key)
    local cache = self["_" .. prefix .. "_cache"]
    local node = cache[key]
    if not node then
        node = { key = key }
        cache[key] = node
        self._stats[stat_key] = self._stats[stat_key] + 1
    end
    node.value = value
    self:_packedCacheTouch(prefix, node)
    while self._stats[stat_key] > maximum do
        local tail_key = "_" .. prefix .. "_cache_tail"
        local evicted = self[tail_key]
        self:_packedCacheUnlink(prefix, evicted)
        cache[evicted.key] = nil
        self._stats[stat_key] = self._stats[stat_key] - 1
    end
    return node
end

function WanxiangLexicon:_disableHead(reason)
    self._head_disabled = true
    self._stats.head_error = oneLine(reason)
    if self._head_stmt then
        pcall(self._head_stmt.close, self._head_stmt)
        self._head_stmt = nil
    end
end

-- Return packed, pre-ranked rows for common ambiguous codes. Callers opt in to
-- this layer so cold sentence spans still use the existing single phrase
-- batch instead of paying an extra negative lookup.
function WanxiangLexicon:lookupHeads(canonical_codes, limit)
    local results, codes, seen = {}, {}, {}
    limit = math.min(MAX_HEAD_CANDIDATES, normalizeLimit(limit))
    if type(canonical_codes) ~= "table" then
        return results
    end
    for _, code in ipairs(canonical_codes) do
        if #codes >= MAX_HEAD_CODES then
            break
        elseif validCode(code) and not seen[code] then
            seen[code] = true
            codes[#codes + 1] = code
            self._stats.head_lookups = self._stats.head_lookups + 1
        end
    end
    if #codes == 0 or not self:_ensureOpen()
            or self._head_disabled or not self._head_stmt then
        return results
    end
    local missing = {}
    for _, code in ipairs(codes) do
        local cached = self._head_cache[code]
        if cached ~= nil then
            self._stats.head_cache_hits = self._stats.head_cache_hits + 1
            self:_packedCacheTouch("head", cached)
            results[code] = copyRows(cached.value, limit)
        else
            self._stats.head_cache_misses = self._stats.head_cache_misses + 1
            missing[#missing + 1] = code
        end
    end
    if #missing == 0 then
        return results
    end

    self._stats.head_queries = self._stats.head_queries + 1
    local grouped = {}
    for _, code in ipairs(missing) do
        grouped[code] = {}
    end
    local ok, err = pcall(function()
        local bindings = {}
        for index = 1, MAX_HEAD_CODES do
            bindings[index] = missing[index] or ""
        end
        local stmt = self._head_stmt
        stmt:reset():clearbind():bind(unpack(bindings))
        for _ = 1, #missing do
            local row = stmt:step()
            if not row then
                break
            end
            local code = row[1]
            if not grouped[code] then
                error("invalid code_head key")
            end
            local rows, seen_text = {}, {}
            for candidate_index = 1, MAX_HEAD_CANDIDATES do
                local first = 2 + (candidate_index - 1) * 5
                local text = row[first]
                local character_count = tonumber(row[first + 1])
                local score = tonumber(row[first + 2])
                local source = tonumber(row[first + 3])
                local source_penalty = tonumber(row[first + 4])
                if text ~= nil then
                    if type(text) ~= "string" or text == "" or seen_text[text]
                            or not validInteger(character_count) or character_count < 1
                            or not validInteger(score) or score < 0
                            or not validInteger(source) or source < 0
                            or not validInteger(source_penalty) or source_penalty < 0 then
                        error("invalid code_head candidate")
                    end
                    seen_text[text] = true
                    rows[#rows + 1] = {
                        text = text,
                        character_count = character_count,
                        score = score,
                        rank = candidate_index,
                        source = source,
                        source_penalty = source_penalty,
                    }
                elseif character_count ~= nil or score ~= nil or source ~= nil
                        or source_penalty ~= nil then
                    error("partial code_head candidate")
                end
            end
            grouped[code] = rows
            self._stats.head_rows = self._stats.head_rows + 1
        end
        stmt:reset():clearbind()
    end)
    if not ok then
        if self._head_stmt then
            pcall(function() self._head_stmt:reset():clearbind() end)
        end
        self:_disableHead(err)
        return results
    end
    for _, code in ipairs(missing) do
        local rows = grouped[code] or {}
        self:_packedCacheStore("head", code, rows,
            MAX_HEAD_CACHE_ENTRIES, "head_cache_entries")
        results[code] = copyRows(rows, limit)
    end
    return results
end

function WanxiangLexicon:lookupHead(canonical_code, limit)
    return self:lookupHeads({ canonical_code }, limit)[canonical_code] or {}
end

function WanxiangLexicon:_predictionUnlink(node)
    if node.previous then
        node.previous.next = node.next
    else
        self._prediction_cache_head = node.next
    end
    if node.next then
        node.next.previous = node.previous
    else
        self._prediction_cache_tail = node.previous
    end
    node.previous = nil
    node.next = nil
end

function WanxiangLexicon:_predictionTouch(node)
    if self._prediction_cache_head == node then
        return
    end
    if node.previous or node.next or self._prediction_cache_tail == node then
        self:_predictionUnlink(node)
    end
    node.next = self._prediction_cache_head
    if self._prediction_cache_head then
        self._prediction_cache_head.previous = node
    else
        self._prediction_cache_tail = node
    end
    self._prediction_cache_head = node
end

function WanxiangLexicon:_predictionStore(context, rows)
    local node = self._prediction_cache[context]
    if not node then
        node = { context = context }
        self._prediction_cache[context] = node
        self._stats.prediction_cache_entries = self._stats.prediction_cache_entries + 1
    end
    node.rows = rows
    self:_predictionTouch(node)

    while self._stats.prediction_cache_entries > MAX_PREDICTION_CACHE_ENTRIES do
        local evicted = self._prediction_cache_tail
        self:_predictionUnlink(evicted)
        self._prediction_cache[evicted.context] = nil
        self._stats.prediction_cache_entries = self._stats.prediction_cache_entries - 1
    end
end

function WanxiangLexicon:_disablePrediction(reason)
    self._prediction_disabled = true
    self._stats.prediction_error = oneLine(reason)
    if self._prediction_stmt then
        pcall(self._prediction_stmt.close, self._prediction_stmt)
        self._prediction_stmt = nil
    end
end

function WanxiangLexicon:_unlink(node)
    if node.previous then
        node.previous.next = node.next
    else
        self._cache_head = node.next
    end
    if node.next then
        node.next.previous = node.previous
    else
        self._cache_tail = node.previous
    end
    node.previous = nil
    node.next = nil
end

function WanxiangLexicon:_touch(node)
    if self._cache_head == node then
        return
    end
    if node.previous or node.next or self._cache_tail == node then
        self:_unlink(node)
    end
    node.next = self._cache_head
    if self._cache_head then
        self._cache_head.previous = node
    else
        self._cache_tail = node
    end
    self._cache_head = node
end

function WanxiangLexicon:_store(code, rows, loaded_limit)
    local node = self._cache[code]
    if not node then
        node = { code = code }
        self._cache[code] = node
        self._stats.cache_entries = self._stats.cache_entries + 1
    end
    node.rows = rows
    node.loaded_limit = loaded_limit
    node.complete = #rows < loaded_limit
    self:_touch(node)

    while self._stats.cache_entries > MAX_CACHE_ENTRIES do
        local evicted = self._cache_tail
        self:_unlink(evicted)
        self._cache[evicted.code] = nil
        self._stats.cache_entries = self._stats.cache_entries - 1
    end
end

function WanxiangLexicon:_queryMany(codes, limit, include_supplement)
    local grouped = {}
    for _, code in ipairs(codes) do
        grouped[code] = {}
    end
    local ok, err = pcall(function()
        local stmt = self._lookup_stmt
        local bindings = {}
        for index = 1, MAX_BATCH_CODES do
            bindings[index] = codes[index] or ""
        end
        bindings[MAX_BATCH_CODES + 1] = limit
        stmt:reset():clearbind():bind(unpack(bindings))
        for _ = 1, #codes * limit do
            local row = stmt:step()
            if not row then
                break
            end
            local code = row[1]
            local text = row[2]
            local score = tonumber(row[3])
            local rank = tonumber(row[4])
            local source_mask = tonumber(row[5])
            local source_penalty = tonumber(row[6])
            local character_count = tonumber(row[7])
            if not grouped[code] or type(text) ~= "string" or text == ""
                    or not validInteger(score)
                    or not validInteger(rank) or rank < 1
                    or not validInteger(source_mask) or source_mask < 0
                    or not validInteger(source_penalty) or source_penalty < 0
                    or not validInteger(character_count) or character_count < 1 then
                error("invalid phrase row for code " .. code)
            end
            grouped[code][#grouped[code] + 1] = {
                text = text,
                score = score,
                rank = rank,
                source = source_mask,
                source_penalty = source_penalty,
                character_count = character_count,
            }
        end
        stmt:reset():clearbind()

        local supplement_codes = {}
        for _, code in ipairs(codes) do
            if #grouped[code] < limit then
                supplement_codes[#supplement_codes + 1] = code
            end
        end
        if include_supplement ~= false and #supplement_codes > 0
                and self:_ensureSupplementOpen() then
            self._stats.supplement_queries = self._stats.supplement_queries + 1
            local supplement_bindings = {}
            for index = 1, MAX_BATCH_CODES do
                supplement_bindings[index] = supplement_codes[index] or ""
            end
            supplement_bindings[MAX_BATCH_CODES + 1] = limit
            local supplement_stmt = self._supplement_stmt
            supplement_stmt:reset():clearbind():bind(unpack(supplement_bindings))
            for _ = 1, #supplement_codes * limit do
                local row = supplement_stmt:step()
                if not row then
                    break
                end
                local code = row[1]
                local text = row[2]
                local score = tonumber(row[3])
                local rank = tonumber(row[4])
                local source_mask = tonumber(row[5])
                local source_penalty = tonumber(row[6])
                local character_count = tonumber(row[7])
                if not grouped[code] or type(text) ~= "string" or text == ""
                        or not validInteger(score)
                        or not validInteger(rank) or rank < 1
                        or not validInteger(source_mask) or source_mask < 0
                        or not validInteger(source_penalty) or source_penalty < 0
                        or not validInteger(character_count) or character_count < 1 then
                    error("invalid phrase_supplement row for code " .. code)
                end
                grouped[code][#grouped[code] + 1] = {
                    text = text,
                    score = score,
                    rank = rank,
                    source = source_mask,
                    source_penalty = source_penalty,
                    character_count = character_count,
                }
                self._stats.supplement_rows = self._stats.supplement_rows + 1
            end
            supplement_stmt:reset():clearbind()
        end

        local extension_codes = {}
        if include_supplement ~= false and self._licensed_extension_stmt then
            for _, code in ipairs(codes) do
                if #grouped[code] < limit then
                    extension_codes[#extension_codes + 1] = code
                end
            end
        end
        if #extension_codes > 0 then
            self._stats.licensed_extension_queries =
                self._stats.licensed_extension_queries + 1
            local extension_bindings = {}
            for index = 1, MAX_BATCH_CODES do
                extension_bindings[index] = extension_codes[index] or ""
            end
            extension_bindings[MAX_BATCH_CODES + 1] = limit
            local extension_stmt = self._licensed_extension_stmt
            extension_stmt:reset():clearbind():bind(unpack(extension_bindings))
            for _ = 1, #extension_codes * limit do
                local row = extension_stmt:step()
                if not row then break end
                local code = row[1]
                local text = row[2]
                local score = tonumber(row[3])
                local rank = tonumber(row[4])
                local source_mask = tonumber(row[5])
                local source_penalty = tonumber(row[6])
                local character_count = tonumber(row[7])
                if not grouped[code] or type(text) ~= "string" or text == ""
                        or not validInteger(score)
                        or not validInteger(rank) or rank < 1
                        or not validInteger(source_mask) or source_mask < 0
                        or not validInteger(source_penalty) or source_penalty < 0
                        or not validInteger(character_count) or character_count < 1 then
                    error("invalid licensed_phrase_extension row for code " .. code)
                end
                if #grouped[code] < limit then
                    grouped[code][#grouped[code] + 1] = {
                        text = text,
                        score = score,
                        rank = rank,
                        source = source_mask,
                        source_penalty = source_penalty,
                        character_count = character_count,
                    }
                    self._stats.licensed_extension_rows =
                        self._stats.licensed_extension_rows + 1
                end
            end
            extension_stmt:reset():clearbind()
        end
    end)
    if not ok then
        if self._lookup_stmt then
            pcall(function()
                self._lookup_stmt:reset():clearbind()
            end)
        end
        if self._supplement_stmt then
            pcall(function()
                self._supplement_stmt:reset():clearbind()
            end)
        end
        if self._licensed_extension_stmt then
            pcall(function()
                self._licensed_extension_stmt:reset():clearbind()
            end)
        end
        return nil, err
    end
    return grouped
end

function WanxiangLexicon:lookup(canonical_code, limit)
    self._stats.lookups = self._stats.lookups + 1
    if not validCode(canonical_code) then
        return {}
    end
    limit = normalizeLimit(limit)
    if not self:_ensureOpen() then
        return {}
    end

    local cached = self._cache[canonical_code]
    if cached and (cached.complete or cached.loaded_limit >= limit) then
        self._stats.cache_hits = self._stats.cache_hits + 1
        self:_touch(cached)
        return copyRows(cached.rows, limit)
    end

    self._stats.cache_misses = self._stats.cache_misses + 1
    self._stats.queries = self._stats.queries + 1
    local grouped, err = self:_queryMany({ canonical_code }, limit)
    if not grouped then
        self:_fail(err)
        return {}
    end
    local rows = grouped[canonical_code]
    self._stats.rows = self._stats.rows + #rows
    self:_store(canonical_code, rows, limit)
    return copyRows(rows, limit)
end

-- The supplement is recall-only. Sentence decoding uses this main-table view
-- so newly appended long-tail edges cannot demote an established whole-
-- sentence Top-1. SentenceDecoder owns the bounded cache for these rows.
function WanxiangLexicon:lookupMain(canonical_code, limit)
    self._stats.main_only_lookups = self._stats.main_only_lookups + 1
    if not validCode(canonical_code) then
        return {}
    end
    limit = normalizeLimit(limit)
    if not self:_ensureOpen() then
        return {}
    end
    self._stats.main_only_queries = self._stats.main_only_queries + 1
    local grouped, err = self:_queryMany({ canonical_code }, limit, false)
    if not grouped then
        self:_fail(err)
        return {}
    end
    local rows = grouped[canonical_code] or {}
    self._stats.main_only_rows = self._stats.main_only_rows + #rows
    return copyRows(rows, limit)
end

function WanxiangLexicon:lookupMainMany(canonical_codes, limit)
    local results, codes, seen = {}, {}, {}
    if type(canonical_codes) ~= "table" then
        return results
    end
    for _, code in ipairs(canonical_codes) do
        if #codes >= MAX_BATCH_CODES then
            break
        elseif validCode(code) and not seen[code] then
            seen[code] = true
            codes[#codes + 1] = code
            self._stats.main_only_lookups = self._stats.main_only_lookups + 1
        end
    end
    if #codes == 0 or not self:_ensureOpen() then
        return results
    end
    limit = normalizeLimit(limit)
    self._stats.main_only_queries = self._stats.main_only_queries + 1
    local grouped, err = self:_queryMany(codes, limit, false)
    if not grouped then
        self:_fail(err)
        return results
    end
    for _, code in ipairs(codes) do
        local rows = grouped[code] or {}
        self._stats.main_only_rows = self._stats.main_only_rows + #rows
        results[code] = copyRows(rows, limit)
    end
    return results
end

-- Query all suffix spans introduced by one new syllable with the same single
-- prepared statement used by lookup(). Positive and negative rows share the
-- provider's bounded LRU.
function WanxiangLexicon:lookupMany(canonical_codes, limit)
    limit = normalizeLimit(limit)
    local results, missing, seen = {}, {}, {}
    if type(canonical_codes) ~= "table" then
        return results
    end
    for _, code in ipairs(canonical_codes) do
        if #missing >= MAX_BATCH_CODES then
            break
        elseif validCode(code) and not seen[code] then
            seen[code] = true
            self._stats.lookups = self._stats.lookups + 1
            local cached = self._cache[code]
            if cached and (cached.complete or cached.loaded_limit >= limit) then
                self._stats.cache_hits = self._stats.cache_hits + 1
                self:_touch(cached)
                results[code] = copyRows(cached.rows, limit)
            else
                self._stats.cache_misses = self._stats.cache_misses + 1
                missing[#missing + 1] = code
            end
        end
    end
    if #missing == 0 or not self:_ensureOpen() then
        return results
    end
    self._stats.queries = self._stats.queries + 1
    local grouped, err = self:_queryMany(missing, limit)
    if not grouped then
        self:_fail(err)
        return results
    end
    for _, code in ipairs(missing) do
        local rows = grouped[code] or {}
        self._stats.rows = self._stats.rows + #rows
        self:_store(code, rows, limit)
        results[code] = copyRows(rows, limit)
    end
    return results
end

function WanxiangLexicon:_mixedBloomMayContain(key)
    if self._mixed_bloom == nil then
        local path = self.mixed_bloom_path
        if path == nil then
            local directory = self.path:match("^(.*)/[^/]+$")
            path = directory and (directory .. "/mixed_head.bloom")
        end
        local file = type(path) == "string" and io.open(path, "rb") or nil
        local payload = file and file:read("*a") or nil
        if file then file:close() end
        if type(payload) == "string" and #payload == MIXED_BLOOM_BYTES then
            self._mixed_bloom = payload
        else
            -- Missing or malformed optional filters must not create false
            -- negatives. The indexed SQLite lookup remains the safe fallback.
            self._mixed_bloom = false
            if payload ~= nil then
                self._stats.mixed_bloom_error = "mixed-pinyin Bloom size mismatch"
            end
        end
    end
    if self._mixed_bloom == false then
        return true
    end
    for _, position in ipairs(mixedBloomPositions(key)) do
        local byte = self._mixed_bloom:byte(math.floor(position / 8) + 1)
        local mask = 2 ^ (position % 8)
        if math.floor(byte / mask) % 2 == 0 then
            return false
        end
    end
    return true
end

-- Mixed full/initial spellings are precompiled offline. This lookup is called
-- only when standard full-pinyin segmentation has no result, so ordinary full
-- pinyin, abbreviations, double pinyin, and sentence decoding pay no query.
function WanxiangLexicon:lookupMixed(mixed_key, limit)
    self._stats.mixed_lookups = self._stats.mixed_lookups + 1
    if not validMixedKey(mixed_key) then
        return {}
    end
    limit = normalizeLimit(limit)
    local cached = self._mixed_cache[mixed_key]
    if cached and (cached.complete
            or (cached.loaded_limit or 0) >= limit) then
        self._stats.mixed_cache_hits = self._stats.mixed_cache_hits + 1
        self:_packedCacheTouch("mixed", cached)
        return copyMixedRows(cached.value, limit)
    end
    self._stats.mixed_cache_misses = self._stats.mixed_cache_misses + 1
    if not self:_ensureOpen() then
        return {}
    end
    if not self:_mixedBloomMayContain(mixed_key) then
        self._stats.mixed_bloom_negatives = self._stats.mixed_bloom_negatives + 1
        local node = self:_packedCacheStore(
            "mixed", mixed_key, {}, MAX_MIXED_CACHE_ENTRIES,
            "mixed_cache_entries")
        node.loaded_limit = 0
        node.complete = true
        return {}
    end
    if not self:_ensureSupplementOpen() or self._mixed_disabled
            or not self._mixed_stmt then
        return {}
    end
    self._stats.mixed_queries = self._stats.mixed_queries + 1
    local rows = {}
    local ok, err = pcall(function()
        local stmt = self._mixed_stmt
        stmt:reset():clearbind():bind(mixed_key, limit)
        for _ = 1, limit do
            local row = stmt:step()
            if not row then break end
            local rank = tonumber(row[1])
            local code = row[2]
            local text = row[3]
            local score = tonumber(row[4])
            local source_mask = tonumber(row[5])
            local source_penalty = tonumber(row[6])
            if not validInteger(rank) or rank < 1 or not validCode(code)
                    or type(text) ~= "string" or text == ""
                    or not validInteger(score)
                    or not validInteger(source_mask) or source_mask < 0
                    or not validInteger(source_penalty) or source_penalty < 0 then
                error("invalid mixed_head row for key " .. mixed_key)
            end
            rows[#rows + 1] = {
                rank = rank,
                code = code,
                text = text,
                score = score,
                source = source_mask,
                source_penalty = source_penalty,
            }
        end
        stmt:reset():clearbind()
    end)
    if not ok then
        if self._mixed_stmt then
            pcall(function() self._mixed_stmt:reset():clearbind() end)
        end
        self._mixed_disabled = true
        self._stats.mixed_error = oneLine(err)
        return {}
    end
    self._stats.mixed_rows = self._stats.mixed_rows + #rows
    local node = self:_packedCacheStore(
        "mixed", mixed_key, rows, MAX_MIXED_CACHE_ENTRIES,
        "mixed_cache_entries")
    node.loaded_limit = limit
    node.complete = #rows < limit
    return copyMixedRows(rows, limit)
end

-- Return structured next-text candidates for the first caller-ordered context
-- that has usable rows. Schema v3 permits broad use only for the exact first
-- key; a trusted explicitly committed token has the same permission. Suffix
-- fallback rows must be explicitly marked SAFE_BACKOFF. All five
-- uncached keys are still fetched by one prepared query and share a bounded
-- positive/negative LRU.
function WanxiangLexicon:predictDetailed(context_keys, limit)
    limit = normalizePredictionLimit(limit)
    if type(context_keys) ~= "table" then
        return { matched_context = nil, candidates = {} }
    end

    local contexts, seen = {}, {}
    for index, context in ipairs(context_keys) do
        local text = type(context) == "table" and context.text or context
        local kind = type(context) == "table" and context.kind
            or (index == 1 and "exact" or "suffix")
        if kind ~= "exact" and kind ~= "trusted_token" and kind ~= "suffix" then
            kind = index == 1 and "exact" or "suffix"
        end
        if #contexts >= MAX_PREDICTION_KEYS then
            break
        elseif validContext(text) and not seen[text] then
            seen[text] = true
            contexts[#contexts + 1] = { text = text, kind = kind }
        end
    end
    if #contexts == 0 then
        return { matched_context = nil, candidates = {} }
    end
    self._stats.prediction_lookups = self._stats.prediction_lookups + 1
    if not self:_ensureOpen() then
        return { matched_context = nil, candidates = {} }
    end
    local use_prediction_head = not self._prediction_head_disabled
        and self._prediction_head_stmt ~= nil
    if not use_prediction_head
            and (self._prediction_disabled or not self._prediction_stmt) then
        return { matched_context = nil, candidates = {} }
    end

    local missing = {}
    for _, context in ipairs(contexts) do
        local cached = self._prediction_cache[context.text]
        if cached then
            self._stats.prediction_cache_hits = self._stats.prediction_cache_hits + 1
            self:_predictionTouch(cached)
        else
            self._stats.prediction_cache_misses = self._stats.prediction_cache_misses + 1
            missing[#missing + 1] = context.text
        end
    end

    if #missing > 0 then
        self._stats.prediction_queries = self._stats.prediction_queries + 1
        local grouped = {}
        for _, context in ipairs(missing) do
            grouped[context] = {}
        end
        local ok, err = pcall(function()
            local bindings = {}
            for index = 1, MAX_PREDICTION_KEYS do
                bindings[index] = missing[index] or ""
            end
            local stmt = use_prediction_head
                and self._prediction_head_stmt or self._prediction_stmt
            stmt:reset():clearbind():bind(unpack(bindings))
            if use_prediction_head then
                self._stats.prediction_head_queries =
                    self._stats.prediction_head_queries + 1
            end
            local maximum_rows = use_prediction_head and #missing
                or #missing * MAX_PREDICTION_LIMIT
            for _ = 1, maximum_rows do
                local row = stmt:step()
                if not row then
                    break
                end
                local context = row[1]
                if not grouped[context] then
                    error("invalid prediction context")
                end
                local first_candidate = use_prediction_head and 1 or 0
                local last_candidate = use_prediction_head
                    and MAX_PREDICTION_LIMIT or 1
                for candidate_index = first_candidate, last_candidate do
                    local first = use_prediction_head
                        and 2 + (candidate_index - 1) * 4 or 2
                    local next_text = row[first]
                    local rank = use_prediction_head and candidate_index
                        or tonumber(row[3])
                    local quality, source_mask, flags
                    quality = tonumber(row[first + (use_prediction_head and 1 or 2)])
                    source_mask = tonumber(row[first + (use_prediction_head and 2 or 3)])
                    flags = tonumber(row[first + (use_prediction_head and 3 or 4)])
                    -- Packed heads keep absent candidate columns NULL so
                    -- corruption can be distinguished from a valid zero.
                    -- The row-oriented table defaults omitted scoring metadata
                    -- to zero for defensive compatibility with partial data.
                    if not use_prediction_head then
                        quality = quality or 0
                        source_mask = source_mask or 0
                        flags = flags or 0
                    end
                    if next_text ~= nil then
                        if type(next_text) ~= "string" or next_text == ""
                                or not validInteger(rank) or rank < 1
                                or rank > MAX_PREDICTION_LIMIT
                                or not validInteger(quality) or quality < 0
                                or quality > 1000
                                or not validInteger(source_mask) or source_mask < 0
                                or not validInteger(flags) or flags < 0 then
                            error("invalid prediction row")
                        end
                        local rows = grouped[context]
                        local duplicate = false
                        for _, candidate in ipairs(rows) do
                            if candidate.text == next_text then
                                duplicate = true
                                break
                            end
                        end
                        if not duplicate then
                            rows[#rows + 1] = {
                                text = next_text,
                                rank = rank,
                                quality = quality,
                                source_mask = source_mask,
                                flags = flags,
                            }
                            self._stats.prediction_rows =
                                self._stats.prediction_rows + 1
                        end
                    elseif use_prediction_head and (quality ~= nil
                            or source_mask ~= nil or flags ~= nil) then
                        error("partial prediction_head candidate")
                    end
                end
                if use_prediction_head then
                    self._stats.prediction_head_rows =
                        self._stats.prediction_head_rows + 1
                end
            end
            stmt:reset():clearbind()
        end)
        if not ok then
            if use_prediction_head and self._prediction_head_stmt then
                pcall(function()
                    self._prediction_head_stmt:reset():clearbind()
                end)
                self._prediction_head_disabled = true
                self._stats.prediction_head_error = oneLine(err)
                pcall(self._prediction_head_stmt.close, self._prediction_head_stmt)
                self._prediction_head_stmt = nil
                -- A malformed optional packed table must not suppress the
                -- ordinary prediction table for this keypress. Retry once
                -- after disabling only the v5 layer.
                return self:predictDetailed(contexts, limit)
            elseif self._prediction_stmt then
                pcall(function()
                    self._prediction_stmt:reset():clearbind()
                end)
                self:_disablePrediction(err)
            end
            return { matched_context = nil, candidates = {} }
        end
        for _, context in ipairs(missing) do
            self:_predictionStore(context, grouped[context])
        end
    end

    for _, context in ipairs(contexts) do
        local cached = self._prediction_cache[context.text]
        if cached and #cached.rows > 0 then
            local usable = {}
            local guarded_suffix
            for _, row in ipairs(cached.rows) do
                local safe_backoff = hasFlag(
                    row.flags, PREDICTION_FLAG_SAFE_BACKOFF)
                local is_suffix = context.kind == "suffix"
                local semantic_safe_suffix = is_suffix and safe_backoff
                    and hasFlag(row.flags, PREDICTION_FLAG_SENTENCE)
                if semantic_safe_suffix and guarded_suffix == nil then
                    guarded_suffix = guardedSemanticSuffix(
                        contexts[1].text, context.text)
                end
                local guarded_semantic = semantic_safe_suffix and guarded_suffix
                if not is_suffix or safe_backoff and not guarded_semantic then
                    usable[#usable + 1] = row
                end
            end
            if #usable > 0 then
                return {
                    matched_context = context.text,
                    candidates = copyPredictionRows(
                        usable, context.text, limit),
                }
            end
        end
    end
    return { matched_context = nil, candidates = {} }
end

function WanxiangLexicon:supportsTypedPredictionContexts()
    return true
end

function WanxiangLexicon:getCapabilities()
    if not self:_ensureOpen() then
        return {}
    end
    return copyCapabilities(self._capabilities)
end

function WanxiangLexicon:predict(context_keys, limit)
    local detailed = self:predictDetailed(context_keys, limit)
    return copyTexts(detailed.candidates, normalizePredictionLimit(limit))
end

function WanxiangLexicon:isAvailable()
    return self:_ensureOpen()
end

function WanxiangLexicon:getStats()
    local stats = {}
    for key, value in pairs(self._stats) do
        stats[key] = value
    end
    stats.available = self._available == true
    stats.initialized = self._available ~= nil
    stats.closed = self._closed
    stats.error = self._error
    stats.reason = self._error
    stats.capabilities = copyCapabilities(self._capabilities)
    if self._metadata then
        stats.metadata = {}
        for key, value in pairs(self._metadata) do
            stats.metadata[key] = value
        end
    end
    return stats
end

function WanxiangLexicon:close()
    if self._closed then
        return
    end
    self._closed = true
    self._available = false
    self:_closeResources()
    self._cache = {}
    self._cache_head = nil
    self._cache_tail = nil
    self._stats.cache_entries = 0
    self._prediction_cache = {}
    self._prediction_cache_head = nil
    self._prediction_cache_tail = nil
    self._stats.prediction_cache_entries = 0
    self._head_cache = {}
    self._head_cache_head = nil
    self._head_cache_tail = nil
    self._stats.head_cache_entries = 0
    self._mixed_cache = {}
    self._mixed_cache_head = nil
    self._mixed_cache_tail = nil
    self._mixed_bloom = nil
    self._stats.mixed_cache_entries = 0
end

return WanxiangLexicon
