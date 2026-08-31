local SentenceDecoder = {
    max_span = 12,
    max_span_candidates = 4,
    beam_width = 8,
    max_results = 8,
    max_query_cache = 512,
    max_state_cache = 32,
    max_character_count_cache = 512,
}

local function utf8Length(text)
    local length = 0
    for _ in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        length = length + 1
    end
    return length
end

local function candidateOrder(left, right)
    if left.cost ~= right.cost then
        return left.cost < right.cost
    elseif left.token_count ~= right.token_count then
        return left.token_count < right.token_count
    elseif (left.lexical_score or 0) ~= (right.lexical_score or 0) then
        return (left.lexical_score or 0) > (right.lexical_score or 0)
    end
    return left.text < right.text
end

function SentenceDecoder:new(options)
    local instance = options or {}
    setmetatable(instance, self)
    self.__index = self
    instance.provider_cache = {}
    instance.provider_cache_count = 0
    instance.provider_cache_sequence = 0
    instance.state_cache = {}
    instance.state_cache_count = 0
    instance.state_cache_sequence = 0
    instance.character_count_cache = {}
    instance.character_count_cache_order = {}
    instance.stats = {}
    instance:_resetStats()
    return instance
end

function SentenceDecoder:_resetStats()
    self.stats = {
        provider_queries = 0,
        provider_cache_hits = 0,
        spans = 0,
        max_span_candidates = 0,
        max_beam = 0,
        completed = 0,
        decode_cache_hits = 0,
    }
end

function SentenceDecoder:getStats()
    local stats = {}
    for key, value in pairs(self.stats) do
        stats[key] = value
    end
    return stats
end

function SentenceDecoder:_timingStart()
    return self.on_timing and (self.timing_clock or os.clock)() or nil
end

function SentenceDecoder:_recordTiming(name, started)
    if started then
        pcall(self.on_timing, name,
            (self.timing_clock or os.clock)() - started)
    end
end

function SentenceDecoder:setProvider(provider)
    local changed = self.provider ~= provider
    self.provider = provider
    if changed then
        self.provider_cache = {}
        self.provider_cache_count = 0
        self.provider_cache_sequence = 0
        self.provider_error_reported = nil
        self.state_cache = {}
        self.state_cache_count = 0
        self.state_cache_sequence = 0
    end
    return changed
end

function SentenceDecoder:invalidate()
    self.provider_cache = {}
    self.provider_cache_count = 0
    self.provider_cache_sequence = 0
    self.provider_error_reported = nil
    self.state_cache = {}
    self.state_cache_count = 0
    self.state_cache_sequence = 0
end

function SentenceDecoder:_providerError(reason)
    if self.provider_error_reported then
        return
    end
    self.provider_error_reported = true
    if self.on_lexicon_error then
        self.on_lexicon_error(reason or "wanxiang lexicon unavailable")
    end
end

function SentenceDecoder:_providerAvailable()
    if not self.provider then
        return false
    end
    if not self.provider.isAvailable then
        return true
    end
    local ok, available = pcall(self.provider.isAvailable, self.provider)
    if ok and available then
        return true
    end
    local reason
    if self.provider.getStats then
        local stats_ok, provider_stats = pcall(self.provider.getStats, self.provider)
        reason = stats_ok and provider_stats and provider_stats.error
    end
    self:_providerError(reason)
    return false
end

function SentenceDecoder:_storeProviderRows(code, rows)
    rows = type(rows) == "table" and rows or {}
    local normalized = {}
    for index = 1, math.min(#rows, self.max_span_candidates) do
        local row = rows[index]
        local text = type(row) == "table" and row.text or row
        if type(text) == "string" and text ~= "" then
            normalized[#normalized + 1] = {
                text = text,
                rank = type(row) == "table" and (tonumber(row.rank) or index) or index,
                score = type(row) == "table" and (tonumber(row.score) or 0) or 0,
                source_penalty = type(row) == "table"
                    and (tonumber(row.source_penalty) or tonumber(row.penalty) or 0) or 0,
                character_count = type(row) == "table"
                    and tonumber(row.character_count) or nil,
            }
        end
    end
    self.provider_cache_sequence = self.provider_cache_sequence + 1
    local cached = self.provider_cache[code]
    self.provider_cache[code] = {
        rows = normalized,
        last_used = self.provider_cache_sequence,
    }
    if not cached then
        self.provider_cache_count = self.provider_cache_count + 1
    end
    if self.provider_cache_count > self.max_query_cache then
        local oldest_code, oldest_sequence
        for cached_code, item in pairs(self.provider_cache) do
            if not oldest_sequence or item.last_used < oldest_sequence then
                oldest_code, oldest_sequence = cached_code, item.last_used
            end
        end
        if oldest_code then
            self.provider_cache[oldest_code] = nil
            self.provider_cache_count = self.provider_cache_count - 1
        end
    end
    return normalized
end

function SentenceDecoder:_characterCount(text, supplied)
    if type(supplied) == "number" and supplied >= 1
            and supplied == math.floor(supplied) then
        return supplied
    end
    local cached = self.character_count_cache[text]
    if cached then
        return cached
    end
    local count = utf8Length(text)
    self.character_count_cache[text] = count
    self.character_count_cache_order[#self.character_count_cache_order + 1] = text
    if #self.character_count_cache_order > self.max_character_count_cache then
        local evicted = table.remove(self.character_count_cache_order, 1)
        self.character_count_cache[evicted] = nil
    end
    return count
end

function SentenceDecoder:_providerRows(code)
    local cached = self.provider_cache[code]
    if cached then
        self.stats.provider_cache_hits = self.stats.provider_cache_hits + 1
        self.provider_cache_sequence = self.provider_cache_sequence + 1
        cached.last_used = self.provider_cache_sequence
        return cached.rows
    end
    if not self:_providerAvailable() then
        return {}
    end
    self.stats.provider_queries = self.stats.provider_queries + 1
    local timing_started = self:_timingStart()
    local lookup = self.provider.lookupMain or self.provider.lookup
    local ok, rows = pcall(lookup, self.provider, code,
        self.max_span_candidates)
    self:_recordTiming("sqlite_phrase_query", timing_started)
    if not ok then
        self:_providerError(rows)
        return {}
    end
    if self.provider.isAvailable and not self:_providerAvailable() then
        return {}
    end
    return self:_storeProviderRows(code, rows)
end

function SentenceDecoder:_spanCandidates(segments, first, last)
    local syllable_count = last - first + 1
    local compact_parts, canonical_parts = {}, {}
    for index = first, last do
        compact_parts[#compact_parts + 1] = segments[index]
        canonical_parts[#canonical_parts + 1] = segments[index]
    end
    local compact_code = table.concat(compact_parts)
    local canonical_code = table.concat(canonical_parts, "'")
    local rows, by_text = {}, {}
    local function add(text, rank, source_penalty, lexical_score, supplied_count)
        local character_count = type(text) == "string"
            and self:_characterCount(text, supplied_count) or 0
        if type(text) ~= "string" or text == ""
                or character_count < syllable_count
                or character_count > syllable_count * 2 then
            return
        end
        local row = {
            text = text,
            rank = math.max(1, tonumber(rank) or 1),
            source_penalty = math.max(0, tonumber(source_penalty) or 0),
            lexical_score = math.max(0, tonumber(lexical_score) or 0),
            character_count = character_count,
            code = canonical_code,
        }
        row.cost = 256 + 32 * (row.rank - 1) + row.source_penalty
        local existing = by_text[text]
        if not existing then
            rows[#rows + 1] = row
            by_text[text] = row
        elseif row.cost < existing.cost
                or row.cost == existing.cost
                    and row.lexical_score > existing.lexical_score then
            existing.rank = row.rank
            existing.source_penalty = row.source_penalty
            existing.cost = row.cost
            existing.lexical_score = row.lexical_score
        end
    end

    local base = self.lookup_base and self.lookup_base(compact_code, syllable_count) or {}
    for index, candidate in ipairs(base or {}) do
        local text = type(candidate) == "table" and candidate.text or candidate
        local rank = type(candidate) == "table" and candidate.rank or index
        local penalty = type(candidate) == "table"
            and (candidate.source_penalty or candidate.penalty) or 0
        local score = type(candidate) == "table" and candidate.score or 0
        local character_count = type(candidate) == "table"
            and candidate.character_count or nil
        add(text, rank, penalty, score, character_count)
    end
    if syllable_count >= 2 then
        for _, row in ipairs(self:_providerRows(canonical_code)) do
            add(row.text, row.rank, row.source_penalty, row.score,
                row.character_count)
        end
    end
    table.sort(rows, function(left, right)
        if left.cost == right.cost
                and left.lexical_score ~= right.lexical_score then
            return left.lexical_score > right.lexical_score
        elseif left.cost == right.cost then
            return left.text < right.text
        end
        return left.cost < right.cost
    end)
    while #rows > self.max_span_candidates do
        rows[#rows] = nil
    end
    self.stats.max_span_candidates = math.max(self.stats.max_span_candidates, #rows)
    return rows
end

function SentenceDecoder:_prefetchCodes(codes)
    local lookup_many = self.provider
        and (self.provider.lookupMainMany or self.provider.lookupMany)
    if type(lookup_many) ~= "function"
            or not self:_providerAvailable() then
        return
    end
    local missing = {}
    for _, code in ipairs(codes) do
        if not self.provider_cache[code] then
            missing[#missing + 1] = code
        end
    end
    if #missing == 0 then
        return
    end
    self.stats.provider_queries = self.stats.provider_queries + 1
    local timing_started = self:_timingStart()
    local ok, result = pcall(lookup_many, self.provider, missing,
        self.max_span_candidates)
    self:_recordTiming("sqlite_phrase_query", timing_started)
    if not ok then
        self:_providerError(result)
    elseif self.provider.isAvailable and not self:_providerAvailable() then
        return
    else
        result = type(result) == "table" and result or {}
        for _, code in ipairs(missing) do
            self:_storeProviderRows(code, result[code])
        end
    end
end

function SentenceDecoder:_prefetchTailSpans(segments, first_regular, last, extra_codes)
    local codes, seen = {}, {}
    for first = first_regular, last - 1 do
        local parts = {}
        for index = first, last do
            parts[#parts + 1] = segments[index]
        end
        local code = table.concat(parts, "'")
        codes[#codes + 1] = code
        seen[code] = true
    end
    -- A second syllable segmentation is represented by its complete span.
    -- The regular tail contributes at most eleven codes, so one alternate
    -- exact code still fits the provider's fixed twelve-slot statement.
    for _, code in ipairs(extra_codes or {}) do
        if type(code) == "string" and code ~= "" and not seen[code]
                and #codes < 12 then
            codes[#codes + 1] = code
            seen[code] = true
        end
    end
    self:_prefetchCodes(codes)
end

function SentenceDecoder:_prefetchSmallGraph(segments, extra_codes)
    local codes, seen = {}, {}
    for first = 1, #segments - 1 do
        local parts = { segments[first] }
        for last = first + 1, #segments do
            parts[#parts + 1] = segments[last]
            local code = table.concat(parts, "'")
            codes[#codes + 1] = code
            seen[code] = true
        end
    end
    for _, code in ipairs(extra_codes or {}) do
        if type(code) == "string" and code ~= "" and not seen[code]
                and #codes < 12 then
            codes[#codes + 1] = code
            seen[code] = true
        end
    end
    if #codes <= 12 then
        self:_prefetchCodes(codes)
    end
end

function SentenceDecoder:_edges(segments)
    local edges = {}
    for first = 1, #segments do
        edges[first] = {}
        local regular_last = math.min(#segments, first + self.max_span - 1)
        for last = first, regular_last do
            local candidates = self:_spanCandidates(segments, first, last)
            if #candidates > 0 then
                edges[first][#edges[first] + 1] = {
                    next_position = last + 1,
                    candidates = candidates,
                }
                self.stats.spans = self.stats.spans + 1
            end
        end
    end
    -- Long exact phrases remain reachable without making every long substring
    -- eligible for a database query.
    if #segments > self.max_span then
        local candidates = self:_spanCandidates(segments, 1, #segments)
        if #candidates > 0 then
            edges[1][#edges[1] + 1] = {
                next_position = #segments + 1,
                candidates = candidates,
            }
            self.stats.spans = self.stats.spans + 1
        end
    end
    return edges
end

local function trimBeams(values, limit)
    table.sort(values, candidateOrder)
    local result, seen = {}, {}
    for _, value in ipairs(values) do
        if not seen[value.text] then
            seen[value.text] = true
            result[#result + 1] = value
            if #result >= limit then
                break
            end
        end
    end
    return result
end

local function stateKey(segments, count)
    local parts = {}
    for index = 1, count or #segments do
        parts[index] = segments[index]
    end
    return table.concat(parts, "'")
end

function SentenceDecoder:_touchState(state)
    self.state_cache_sequence = self.state_cache_sequence + 1
    state.last_used = self.state_cache_sequence
end

function SentenceDecoder:_storeState(key, state)
    if not self.state_cache[key] then
        self.state_cache_count = self.state_cache_count + 1
    end
    self.state_cache[key] = state
    self:_touchState(state)
    while self.state_cache_count > self.max_state_cache do
        local oldest_key, oldest_sequence
        for cached_key, cached in pairs(self.state_cache) do
            if cached_key ~= key and (not oldest_sequence
                    or cached.last_used < oldest_sequence) then
                oldest_key, oldest_sequence = cached_key, cached.last_used
            end
        end
        if not oldest_key then
            break
        end
        self.state_cache[oldest_key] = nil
        self.state_cache_count = self.state_cache_count - 1
    end
end

-- Build only the DP destination introduced by the final syllable. A prefix
-- state owns immutable, already-trimmed beams for earlier positions, so an
-- append changes at most 12 regular spans (plus one bounded long exact span).
function SentenceDecoder:_buildState(segments, extra_prefetch_codes)
    local count = #segments
    local key = stateKey(segments)
    local cached = self.state_cache[key]
    if cached then
        self:_touchState(cached)
        return cached, true
    end

    local parent
    if count == 1 then
        parent = { beams = { [1] = {
            {
                text = "", cost = 0, token_count = 0, lexical_score = 0,
            },
        } } }
    else
        local parent_segments = {}
        for index = 1, count - 1 do
            parent_segments[index] = segments[index]
        end
        parent = self:_buildState(parent_segments)
    end

    local beams = {}
    for position, values in pairs(parent.beams) do
        beams[position] = values
    end
    local destination = {}
    local first_regular = math.max(1, count - self.max_span + 1)
    self:_prefetchTailSpans(segments, first_regular, count,
        extra_prefetch_codes)
    local function extend(first, last)
        local candidates = self:_spanCandidates(segments, first, last)
        if #candidates == 0 then
            return
        end
        self.stats.spans = self.stats.spans + 1
        local source_beams = parent.beams[first] or {}
        self.stats.max_beam = math.max(self.stats.max_beam, #source_beams)
        for _, beam in ipairs(source_beams) do
            for _, candidate in ipairs(candidates) do
                destination[#destination + 1] = {
                    text = beam.text .. candidate.text,
                    cost = beam.cost + candidate.cost,
                    token_count = beam.token_count + 1,
                    lexical_score = (beam.lexical_score or 0)
                        + (candidate.lexical_score or 0),
                }
            end
        end
    end

    for first = first_regular, count do
        extend(first, count)
    end
    beams[count + 1] = trimBeams(destination, self.beam_width)
    self.stats.max_beam = math.max(self.stats.max_beam, #beams[count + 1])
    local state = {
        beams = beams,
        results = trimBeams(beams[count + 1], self.max_results),
    }
    self:_storeState(key, state)
    return state, false
end

function SentenceDecoder:_decodeUnmeasured(segments, extra_prefetch_codes)
    self:_resetStats()
    if type(segments) ~= "table" or #segments < 2 then
        return {}
    end
    local key = stateKey(segments)
    local parent_key = stateKey(segments, #segments - 1)
    if self.state_cache[key] and extra_prefetch_codes then
        self:_prefetchCodes(extra_prefetch_codes)
    elseif not self.state_cache[key] and not self.state_cache[parent_key] then
        -- When full decoding starts at four syllables, fetch the small initial
        -- graph in one statement; later appended syllables use one tail batch.
        self:_prefetchSmallGraph(segments, extra_prefetch_codes)
    end
    local state, cache_hit = self:_buildState(segments, extra_prefetch_codes)
    if cache_hit then
        self.stats.decode_cache_hits = 1
        self.stats.max_beam = #state.beams[#segments + 1]
    end
    local completed = state.results
    if #segments > self.max_span then
        -- A >12-syllable exact phrase is eligible only when it covers the
        -- whole current composition. Do not put it into the reusable regular
        -- prefix beam, where it could become an unbounded long substring.
        local exact = self:_spanCandidates(segments, 1, #segments)
        if #exact > 0 then
            self.stats.spans = self.stats.spans + 1
            local with_exact = {}
            for _, value in ipairs(completed) do
                with_exact[#with_exact + 1] = value
            end
            for _, candidate in ipairs(exact) do
                with_exact[#with_exact + 1] = {
                    text = candidate.text,
                    cost = candidate.cost,
                    token_count = 1,
                    lexical_score = candidate.lexical_score or 0,
                }
            end
            completed = trimBeams(with_exact, self.max_results)
        end
    end
    self.stats.completed = #completed
    -- Cached DP results are immutable after _storeState. Callers only iterate
    -- them, so return the cached view directly instead of copying up to eight
    -- rows on every key refresh/cache hit. The >12-syllable branch above has
    -- already produced its own temporary result table.
    return completed
end

function SentenceDecoder:decode(segments, extra_prefetch_codes)
    local timing_started = self:_timingStart()
    local result = self:_decodeUnmeasured(segments, extra_prefetch_codes)
    self:_recordTiming("beam_decode", timing_started)
    return result
end

-- Return the bounded candidates for one complete alternate segmentation. The
-- caller normally passes its code to decode() as an extra prefetch first, so
-- this remains a cache-only operation on the real provider and does not add a
-- second SQLite statement to the keystroke path.
function SentenceDecoder:exactCandidates(segments)
    if type(segments) ~= "table" or #segments < 2 then
        return {}
    end
    return self:_spanCandidates(segments, 1, #segments)
end

-- Used when the longest-first parse has fewer than four syllables but its
-- alternate is sentence length (for example xian... versus xi'an...).
function SentenceDecoder:prefetchExact(segments)
    if type(segments) ~= "table" or #segments < 2 then
        return
    end
    self:_prefetchCodes({ stateKey(segments) })
end

return SentenceDecoder
