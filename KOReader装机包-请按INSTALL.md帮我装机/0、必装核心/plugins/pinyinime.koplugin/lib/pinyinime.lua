local util = require("util")
local logger = require("logger")

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local plugin_root = source:match("^(.*)/lib/pinyinime%.lua$")
local SentenceDecoder = dofile(plugin_root .. "/lib/sentence_decoder.lua")
local InputSchemes = dofile(plugin_root .. "/lib/input_schemes.lua")
local default_syllables

local function isSingleUtf8Character(text)
    if type(text) ~= "string" or text == "" then
        return false
    end
    local first = text:byte(1)
    local length = first < 0x80 and 1
        or first >= 0xC2 and first < 0xE0 and 2
        or first >= 0xE0 and first < 0xF0 and 3
        or first >= 0xF0 and first <= 0xF4 and 4 or 0
    if length == 0 or #text ~= length then
        return false
    end
    for index = 2, length do
        local byte = text:byte(index)
        if not byte or byte < 0x80 or byte > 0xBF then
            return false
        end
    end
    return true
end

local function getDefaultSyllables()
    if not default_syllables then
        default_syllables = dofile(plugin_root .. "/data/pinyin_syllables.lua")
    end
    return default_syllables
end

local PinyinIME = {
    page_size = 5,
    max_candidates = 50,
    max_exact_candidates = 24,
    max_short_lexicon_candidates = 8,
    max_short_lexicon_cache = 16,
    min_short_lexicon_head_score = 2304,
    min_short_lexicon_head_margin = 512,
    max_abbreviation_candidates = 10,
    max_prefix_codes = 24,
    max_segmentations = 6,
    max_segment_candidates = 8,
    max_code_length = 64,
    max_correction_states = 32,
    max_correction_codes = 3,
    max_context_keys = 512,
    max_context_candidates = 3,
    max_prediction_candidates = 5,
    max_prediction_context_length = 12,
    max_lexicon_segmentations = 2,
    min_alternate_sentence_code_length = 12,
    max_segmentation_cache = 32,
    max_legacy_sentence_cache = 32,
    max_static_candidate_cache = 128,
    max_static_candidate_admission = 256,
    max_shuangpin_decode_cache = 64,
    max_candidate_seen_entries = 512,
    default_context_candidates = {
        ["第\0zhang"] = "章",
    },
}

local function listFromValue(value)
    if type(value) == "table" then
        return value
    elseif type(value) == "string" then
        return { value }
    end
    return {}
end

local function clearTable(values)
    for key in pairs(values) do
        values[key] = nil
    end
    return values
end

local function makeSyllableSet(syllables)
    if type(syllables) == "table" then
        local set = {}
        for key, value in pairs(syllables) do
            if type(key) == "number" then
                set[value] = true
            elseif value then
                set[key] = true
            end
        end
        return set
    end
    local set = {}
    for _, syllable in ipairs(getDefaultSyllables()) do
        set[syllable] = true
    end
    return set
end

function PinyinIME.makeSyllableSet(syllables)
    return makeSyllableSet(syllables)
end

local function lowerBound(values, target)
    local first, last = 1, #values + 1
    while first < last do
        local middle = math.floor((first + last) / 2)
        if values[middle] < target then
            first = middle + 1
        else
            last = middle
        end
    end
    return first
end

function PinyinIME:new(options)
    local instance = options or {}
    setmetatable(instance, self)
    self.__index = self
    instance:init()
    return instance
end

function PinyinIME:init()
    self.code_map = self.code_map or {}
    self.abbreviation_map = self.abbreviation_map or {}
    self.overlay_exact = self.overlay_exact or {}
    self.overlay_abbr = self.overlay_abbr or {}
    self.correction_full = self.correction_full or {}
    self.correction_shuangpin = self.correction_shuangpin or {}
    self.abbreviation_overlay_merged = self.abbreviation_overlay_merged == true
    self.user_frequency = self.user_frequency or {}
    self.personalization_enabled = self.personalization_enabled ~= false
    self.prediction_enabled = self.prediction_enabled ~= false
    self.input_scheme = InputSchemes.normalize(self.input_scheme)
    if self.shuangpin_decoder and InputSchemes.isShuangpin(self.input_scheme) then
        self.shuangpin_data_file = self.shuangpin_data_file
            or InputSchemes.get(self.input_scheme).data_file
    end
    self.syllables = self.syllable_set or makeSyllableSet(self.syllables)
    self.max_syllable_length = 0
    for syllable in pairs(self.syllables) do
        self.max_syllable_length = math.max(self.max_syllable_length, #syllable)
    end
    if not self.sorted_codes then
        self.sorted_codes = {}
        for code in pairs(self.code_map) do
            self.sorted_codes[#self.sorted_codes + 1] = code
        end
        table.sort(self.sorted_codes)
    end
    self.raw_code = ""
    self.lookup_code = ""
    self.display_code = ""
    self.commit_code = ""
    self.learning_code = ""
    self.decode_status = "idle"
    self.code = "" -- Internal compatibility alias for lookup_code.
    -- Candidate refreshes happen on every composition key. Reuse their
    -- bounded working tables so a paragraph-sized burst does not leave one
    -- discarded candidate/metadata set per key waiting for the next GC pass.
    self._candidate_buffer = {}
    self._candidate_kind_buffer = {}
    self._candidate_learning_code_buffer = {}
    self._candidate_seen = {}
    self._candidate_seen_count = 0
    self._candidate_seen_generation = 0
    self._prediction_seen = {}
    self.candidates = self._candidate_buffer
    self.candidate_kinds = self._candidate_kind_buffer
    self.candidate_learning_codes = self._candidate_learning_code_buffer
    self.candidate_mode = "idle"
    self.selected_index = 0
    -- nil keeps the engine usable without a candidate bar (tests, legacy
    -- callers). Once a bar reports its layout, only actually rendered slots
    -- may be submitted by number keys.
    self.visible_candidate_slots = nil
    self.fallback_candidate = false
    self.correction_candidate = false
    self.lexicon_exact_expanded = false
    self.prediction_context_text = ""
    self.short_lexicon_cache = {}
    self.short_lexicon_cache_order = {}
    self.segmentation_cache = {}
    self.segmentation_cache_order = {}
    self.legacy_sentence_cache = {}
    self.legacy_sentence_cache_order = {}
    self.static_candidate_cache = {}
    self.static_candidate_cache_slots = {}
    self.static_candidate_cache_next = 1
    self.static_candidate_admission = {}
    self.static_candidate_admission_slots = {}
    self.static_candidate_admission_next = 1
    self.static_candidate_cache_enabled = self.lexicon_provider
        and type(self.lexicon_provider.getCapabilities) == "function" or false
    self.shuangpin_decode_cache = {}
    self.shuangpin_decode_cache_slots = {}
    self.shuangpin_decode_cache_next = 1
    self.timing_stats = {}
    -- A caller may hand a bounded session store to a replacement engine.  The
    -- runtime deliberately does not persist this table in user settings.
    self.context_records = type(self.context_frequency) == "table"
        and self.context_frequency or {}
    self.context_sequence = 0
    self.context_key_count = 0
    self._default_context_sources = {}
    for key in pairs(self.default_context_candidates) do
        local boundary = type(key) == "string" and key:find("\0", 1, true)
        if boundary and boundary > 1 then
            self._default_context_sources[key:sub(1, boundary - 1)] = true
        end
    end
    for _, candidates in pairs(self.context_records) do
        self.context_key_count = self.context_key_count + 1
        if type(candidates) == "table" then
            for _, item in pairs(candidates) do
                if type(item) == "table" and type(item.last_used) == "number" then
                    self.context_sequence = math.max(self.context_sequence, item.last_used)
                end
            end
        end
    end
    while self.context_key_count > self.max_context_keys do
        self:_trimContext()
    end
    self.previous_context_candidate = nil
    self.association_context_candidate = nil
    self.sentence_decoder = SentenceDecoder:new{
        provider = self.lexicon_provider,
        on_timing = self.on_timing,
        timing_clock = self.timing_clock,
        lookup_base = function(code)
            return self:_sentenceTokenCandidates(code)
        end,
        on_lexicon_error = function(reason)
            if self.on_lexicon_error then
                self.on_lexicon_error(reason)
            end
        end,
    }
end

function PinyinIME:_nextCandidateSeenGeneration()
    if self._candidate_seen_count >= self.max_candidate_seen_entries then
        clearTable(self._candidate_seen)
        self._candidate_seen_count = 0
    end
    self._candidate_seen_generation = self._candidate_seen_generation + 1
    return self._candidate_seen, self._candidate_seen_generation
end

function PinyinIME:_resetCandidateStorage()
    self.candidates = clearTable(self._candidate_buffer)
    self.candidate_kinds = clearTable(self._candidate_kind_buffer)
    self.candidate_learning_codes = clearTable(
        self._candidate_learning_code_buffer)
    return self.candidates
end

function PinyinIME:invalidateCandidateCaches()
    self.static_candidate_cache = {}
    self.static_candidate_cache_slots = {}
    self.static_candidate_cache_next = 1
    self.static_candidate_admission = {}
    self.static_candidate_admission_slots = {}
    self.static_candidate_admission_next = 1
    self.legacy_sentence_cache = {}
    self.legacy_sentence_cache_order = {}
end

function PinyinIME:_storeStaticCandidates(
        key, candidates, learning_code, current_state)
    if not key or self.static_candidate_cache[key] then
        return
    end
    -- Admit only a repeated composition. This keeps search-like one-off text
    -- from copying up to fifty candidates into a cache it will never reuse,
    -- while normal backspace/re-entry and recurring phrases become hot on the
    -- second encounter. Fixed rings avoid O(n) FIFO shifts on the key path.
    if not self.static_candidate_admission[key] then
        local slot = self.static_candidate_admission_next
        local evicted = self.static_candidate_admission_slots[slot]
        if evicted then
            self.static_candidate_admission[evicted] = nil
        end
        self.static_candidate_admission_slots[slot] = key
        self.static_candidate_admission[key] = true
        self.static_candidate_admission_next = slot
            % self.max_static_candidate_admission + 1
        return
    end
    local stored = {
        candidates = {}, kinds = {}, learning_codes = {},
        rankable = not current_state,
        selected_index = current_state and self.selected_index or 1,
        fallback_candidate = current_state and self.fallback_candidate or false,
        correction_candidate = current_state and self.correction_candidate or false,
    }
    for index, candidate in ipairs(candidates) do
        stored.candidates[index] = candidate
        stored.kinds[index] = current_state
            and self.candidate_kinds[index] or "normal"
        stored.learning_codes[index] = current_state
            and self.candidate_learning_codes[index] or learning_code
    end
    local slot = self.static_candidate_cache_next
    local evicted = self.static_candidate_cache_slots[slot]
    if evicted then
        self.static_candidate_cache[evicted] = nil
    end
    self.static_candidate_cache_slots[slot] = key
    self.static_candidate_cache[key] = stored
    self.static_candidate_cache_next = slot % self.max_static_candidate_cache + 1
end

function PinyinIME:_recordTiming(name, started)
    if not started then
        return
    end
    local elapsed = (self.timing_clock or os.clock)() - started
    local item = self.timing_stats[name]
    if not item then
        item = { count = 0, total = 0, maximum = 0 }
        self.timing_stats[name] = item
    end
    item.count = item.count + 1
    item.total = item.total + elapsed
    item.maximum = math.max(item.maximum, elapsed)
    if self.on_timing then
        pcall(self.on_timing, name, elapsed)
    end
end

function PinyinIME:getTimingStats(reset)
    local result = {}
    for name, item in pairs(self.timing_stats) do
        result[name] = {
            count = item.count,
            total_ms = item.total * 1000,
            maximum_ms = item.maximum * 1000,
        }
    end
    if reset then
        self.timing_stats = {}
    end
    return result
end

-- Replace the optional read-only lexicon without committing the current
-- composition. Existing candidates are refreshed against the new provider.
function PinyinIME:setLexiconProvider(provider)
    if self.lexicon_provider == provider then
        return false
    end
    self.lexicon_provider = provider
    self.static_candidate_cache_enabled = provider
        and type(provider.getCapabilities) == "function" or false
    self.short_lexicon_cache = {}
    self.short_lexicon_cache_order = {}
    self:invalidateCandidateCaches()
    self.sentence_decoder:setProvider(provider)
    if self:isComposing() then
        self:_refreshCandidates()
    else
        self:_dismissPrediction()
    end
    return true
end

function PinyinIME:getSentenceDecoderStats()
    return self.sentence_decoder:getStats()
end

function PinyinIME:isComposing()
    return self.raw_code ~= ""
end

function PinyinIME:_isShuangpin()
    return InputSchemes.isShuangpin(self.input_scheme)
end

function PinyinIME:_normalizedCode()
    if self.lookup_code:find("'", 1, true) then
        return self.lookup_code:gsub("'", "")
    end
    return self.lookup_code
end

function PinyinIME:_decodeShuangpin(raw_code)
    local cached = self.shuangpin_decode_cache[raw_code]
    if cached then
        return cached
    end
    local decoded = self.shuangpin_decoder:decode(raw_code)
    local slot = self.shuangpin_decode_cache_next
    local evicted = self.shuangpin_decode_cache_slots[slot]
    if evicted then
        self.shuangpin_decode_cache[evicted] = nil
    end
    self.shuangpin_decode_cache_slots[slot] = raw_code
    self.shuangpin_decode_cache[raw_code] = decoded
    self.shuangpin_decode_cache_next = slot % self.max_shuangpin_decode_cache + 1
    return decoded
end

function PinyinIME:_syncComposition()
    if self:_isShuangpin() then
        local decoded = self:_decodeShuangpin(self.raw_code)
        self.decode_status = decoded.status
        self.lookup_code = decoded.lookup_code
        -- Keep the decoded spelling internal to candidate lookup. The preedit
        -- and raw fallback expose the actual double-pinyin key sequence.
        self.display_code = self.raw_code
        self.commit_code = self.raw_code:find("'", 1, true)
            and self.raw_code:gsub("'", "") or self.raw_code
    else
        -- Full pinyin is already canonical. Avoid constructing a decoded
        -- result object for every ordinary key.
        self.decode_status = self.raw_code == "" and "idle" or "valid"
        self.lookup_code = self.raw_code
        self.display_code = self.raw_code
        self.commit_code = self.raw_code
    end
    self.learning_code = self.lookup_code:find("'", 1, true)
        and self.lookup_code:gsub("'", "") or self.lookup_code
    self.code = self.lookup_code
end

function PinyinIME:_notify()
    if self._defer_notify then
        self._notify_pending = true
        return
    end
    if self.on_update then
        local ok, err = xpcall(function()
            local started = self.on_timing
                and (self.timing_clock or os.clock)() or nil
            local state = self:getState()
            self:_recordTiming("state_build", started)
            self.on_update(state)
        end, debug.traceback)
        if not ok then
            self:_reportError(err, self.inputbox and self.inputbox.keyboard)
        end
    end
end

function PinyinIME:_reportError(reason, keyboard)
    if self.on_error then
        local ok, callback_err = xpcall(function()
            self.on_error(reason, keyboard)
        end, debug.traceback)
        if ok then
            return true
        end
        logger.err("Chinese pinyin error callback failed:", callback_err)
    else
        logger.err("Chinese pinyin runtime error:", reason)
    end
    return false
end

function PinyinIME:_beginUpdate()
    self._defer_notify = true
end

function PinyinIME:_endUpdate()
    self._defer_notify = nil
    if self._notify_pending then
        self._notify_pending = nil
        self:_notify()
    end
end

function PinyinIME:getState()
    local page = 1
    if self.selected_index > 0 then
        page = math.floor((self.selected_index - 1) / self.page_size) + 1
    end
    local first_index = (page - 1) * self.page_size + 1
    local page_candidates = {}
    local page_candidate_kinds = {}
    for index = first_index, math.min(first_index + self.page_size - 1, #self.candidates) do
        page_candidates[#page_candidates + 1] = self.candidates[index]
        page_candidate_kinds[#page_candidate_kinds + 1] = self.candidate_kinds[index] or "normal"
    end
    return {
        code = self.display_code,
        raw_code = self.raw_code,
        lookup_code = self.lookup_code,
        display_code = self.display_code,
        learning_code = self.learning_code,
        input_scheme = self.input_scheme,
        decode_status = self.decode_status,
        candidates = page_candidates,
        candidate_kinds = page_candidate_kinds,
        fallback_candidate = self.fallback_candidate,
        correction_candidate = self.correction_candidate,
        candidate_mode = self.candidate_mode,
        candidate_count = #self.candidates,
        selected_index = self.selected_index,
        selected_slot = self.selected_index > 0 and self.selected_index - first_index + 1 or 0,
        page = page,
        page_count = math.max(1, math.ceil(#self.candidates / self.page_size)),
        has_previous_page = page > 1,
        has_next_page = first_index + self.page_size <= #self.candidates,
    }
end

function PinyinIME:getAllCandidateMetadata()
    local metadata = {}
    for index = 1, #self.candidates do
        metadata[index] = {
            kind = self.candidate_kinds[index] or "normal",
            learning_code = self.candidate_learning_codes[index],
        }
    end
    return metadata
end

function PinyinIME:getAllCandidates()
    local candidates = {}
    for index, candidate in ipairs(self.candidates) do
        candidates[index] = candidate
    end
    return candidates
end

function PinyinIME:setVisibleCandidateSlots(slots)
    if slots == nil then
        self.visible_candidate_slots = nil
        return
    end
    local visible = {}
    for _, slot in ipairs(slots) do
        if type(slot) == "number" and slot == math.floor(slot)
                and slot >= 1 and slot <= self.page_size then
            visible[slot] = true
        end
    end
    self.visible_candidate_slots = visible
end

function PinyinIME:isCandidateSlotVisible(slot)
    return self.visible_candidate_slots == nil
        or self.visible_candidate_slots[slot] == true
end

function PinyinIME:_setFallbackCandidate()
    self.fallback_candidate = false
    self.correction_candidate = false
    self:_resetCandidateStorage()
    self.selected_index = 0
    if self.commit_code ~= "" then
        self.candidates[1] = self.commit_code
        self.candidate_kinds[1] = "fallback"
        self.selected_index = 1
        self.fallback_candidate = true
    end
end

function PinyinIME:_learningRecord(code, candidate)
    local candidates = self.user_frequency[code]
    local record = candidates and candidates[candidate]
    if type(record) == "number" then
        return record, 0
    elseif type(record) == "table" then
        return tonumber(record.count) or 0, tonumber(record.last_used) or 0
    end
    return 0, 0
end

function PinyinIME:_learningScore(code, candidate)
    local count, last_used = self:_learningRecord(code, candidate)
    if count < 2 then
        return 0
    end
    local sequence = self.get_learning_sequence and self.get_learning_sequence() or 0
    local age = math.max(0, sequence - last_used)
    local recency = age <= 8 and 8 or age <= 32 and 4 or 0
    return math.min(count, 32) * 8 + recency
end

function PinyinIME:_hasCode(code)
    return self.code_map[code] ~= nil or self.overlay_exact[code] ~= nil
end

-- Keep the established top two candidates stable, then expose up to four
-- overlay phrases before the long tail of the base dictionary. The overlay is
-- generated in final display order, so no per-keystroke sorting is needed.
function PinyinIME:_forEachExactCandidate(code, frequency_code, callback)
    -- pinyin_data.lua is generated in final display order. Iterating it
    -- directly avoids rebuilding and sorting identity wrappers for every
    -- prefix of every composition key.
    local base = listFromValue(self.code_map[code])
    local overlay = listFromValue(self.overlay_exact[code])
    local function visit(candidate)
        return candidate == nil or callback(candidate) ~= false
    end
    for index = 1, math.min(2, #base) do
        if not visit(base[index]) then
            return
        end
    end
    for index = 1, math.min(4, #overlay) do
        if not visit(overlay[index]) then
            return
        end
    end
    for index = 3, #base do
        if not visit(base[index]) then
            return
        end
    end
end

function PinyinIME:_applyPersonalRanking(candidates, code)
    -- The common path has no learned candidates for the current composition.
    -- Preserve the existing list by reference and avoid allocating/sorting one
    -- wrapper table per candidate on every keystroke.
    if not self.personalization_enabled or not self.user_frequency[code] then
        return candidates
    end
    -- A learned first choice is already in its final position. Detect the
    -- general already-promoted prefix before allocating ranking wrappers;
    -- repeated ordinary selections therefore remain allocation-free.
    local promoted_count, previous_score = 0, math.huge
    local already_ranked = true
    for index, candidate in ipairs(candidates) do
        local score = self:_learningScore(code, candidate)
        if score > 0 then
            promoted_count = promoted_count + 1
            if index ~= promoted_count or score > previous_score then
                already_ranked = false
            end
            previous_score = score
        elseif index <= promoted_count then
            already_ranked = false
        end
    end
    if promoted_count == 0 or already_ranked then
        return candidates
    end
    local promoted, remaining = {}, {}
    for index, candidate in ipairs(candidates) do
        local score = self:_learningScore(code, candidate)
        local item = { text = candidate, index = index, score = score }
        if score > 0 then
            promoted[#promoted + 1] = item
        else
            remaining[#remaining + 1] = item
        end
    end
    table.sort(promoted, function(left, right)
        if left.score == right.score and left.index == right.index then
            return left.text < right.text
        elseif left.score == right.score then
            return left.index < right.index
        end
        return left.score > right.score
    end)
    local ranked = {}
    for _, item in ipairs(promoted) do
        ranked[#ranked + 1] = item.text
    end
    for _, item in ipairs(remaining) do
        ranked[#ranked + 1] = item.text
    end
    return ranked
end

function PinyinIME:_contextKey(code)
    if not self.previous_context_candidate or not code or code == "" then
        return nil
    end
    local han = {}
    for _, char in ipairs(util.splitToChars(self.previous_context_candidate)) do
        if util.isCJKChar(char) then
            han[#han + 1] = char
            if #han > 4 then
                table.remove(han, 1)
            end
        end
    end
    if #han == 0 then
        return nil
    end
    return table.concat(han) .. "\0" .. code
end

function PinyinIME:_contextRankingMayApply()
    local previous = self.previous_context_candidate
    if not previous then
        return false
    end
    if next(self.context_records) == nil then
        local may_have_default = false
        for source in pairs(self._default_context_sources) do
            local first = #previous - #source + 1
            if first >= 1 and previous:find(source, first, true) == first then
                may_have_default = true
                break
            end
        end
        if not may_have_default then
            return false
        end
    end
    return true
end

function PinyinIME:_contextRankingKey(code, may_apply)
    if may_apply ~= true and not self:_contextRankingMayApply() then
        return nil
    end
    local key = self:_contextKey(code)
    if not key then
        return nil
    end
    if self.default_context_candidates[key]
            or (self.personalization_enabled and self.context_records[key]) then
        return key
    end
    return nil
end

function PinyinIME:_applyContextRanking(candidates, code)
    local key = self:_contextRankingKey(code)
    if not key then return candidates end
    local record = self.personalization_enabled and key
        and self.context_records[key] or nil
    local fixed = key and self.default_context_candidates[key]
    if fixed then
        for index = 2, math.min(self.page_size, #candidates) do
            if candidates[index] == fixed then
                table.remove(candidates, index)
                table.insert(candidates, 1, fixed)
                break
            end
        end
    end
    if not record then
        return candidates
    end
    local best_index, best
    for index = 1, math.min(self.page_size, #candidates) do
        local item = record[candidates[index]]
        if item and item.count >= 2 and (not best or item.count > best.count
                or item.count == best.count and item.last_used > best.last_used) then
            best_index, best = index, item
        end
    end
    if best_index and best_index > 1 then
        local selected = table.remove(candidates, best_index)
        table.insert(candidates, 1, selected)
    end
    return candidates
end

function PinyinIME:_trimContext()
    if self.context_key_count <= self.max_context_keys then
        return
    end
    local oldest_key, oldest_sequence
    for key, candidates in pairs(self.context_records) do
        local last_used = 0
        for _, item in pairs(candidates) do
            last_used = math.max(last_used, item.last_used or 0)
        end
        if not oldest_sequence or last_used < oldest_sequence then
            oldest_key, oldest_sequence = key, last_used
        end
    end
    if oldest_key then
        self.context_records[oldest_key] = nil
        self.context_key_count = self.context_key_count - 1
    end
end

function PinyinIME:_rememberContext(code, candidate, selected_non_default)
    local key = self:_contextKey(code)
    if self.personalization_enabled and key and selected_non_default
            and self.on_context_commit then
        self.on_context_commit(key, candidate)
    elseif self.personalization_enabled and key and selected_non_default then
        self.context_sequence = self.context_sequence + 1
        local record = self.context_records[key]
        if not record then
            record = {}
            self.context_records[key] = record
            self.context_key_count = self.context_key_count + 1
        end
        local item = record[candidate]
        if not item then
            local count = 0
            for _ in pairs(record) do
                count = count + 1
            end
            if count >= self.max_context_candidates then
                local oldest_candidate, oldest_sequence
                for text, value in pairs(record) do
                    if not oldest_sequence or value.last_used < oldest_sequence then
                        oldest_candidate, oldest_sequence = text, value.last_used
                    end
                end
                record[oldest_candidate] = nil
            end
            item = { count = 0, last_used = 0 }
            record[candidate] = item
        end
        item.count = item.count + 1
        item.last_used = self.context_sequence
        self:_trimContext()
    end
    self.previous_context_candidate = candidate
end

function PinyinIME:resetContext()
    self.previous_context_candidate = nil
    self.association_context_candidate = nil
    self.prediction_context_text = ""
    if self.candidate_mode == "prediction" then
        self:_clear()
    end
end

function PinyinIME:_refreshVisiblePrediction()
    if self.candidate_mode ~= "prediction" then
        return false
    end
    local context_text = self.prediction_context_text
    local last_committed_text = self.association_context_candidate
        or self.previous_context_candidate
    self:_dismissPrediction(false)
    if self.prediction_enabled
            and self:_showPredictions(context_text, last_committed_text) then
        return true
    end
    self:_notify()
    return true
end

function PinyinIME:setPersonalizationEnabled(enabled)
    enabled = enabled ~= false
    if self.personalization_enabled == enabled then
        return false
    end
    local had_prediction = self.candidate_mode == "prediction"
    self.personalization_enabled = enabled
    if self:isComposing() then
        self:_refreshCandidates()
    elseif had_prediction then
        self:_refreshVisiblePrediction()
    end
    return true
end

function PinyinIME:setPredictionEnabled(enabled)
    enabled = enabled ~= false
    if self.prediction_enabled == enabled then
        return false
    end
    self.prediction_enabled = enabled
    if not enabled then
        self:_dismissPrediction()
    end
    return true
end

function PinyinIME:hasSessionPersonalization()
    return next(self.context_records) ~= nil
end

function PinyinIME:clearPersonalization()
    local had_data = next(self.context_records) ~= nil
    for key in pairs(self.context_records) do
        self.context_records[key] = nil
    end
    self.context_sequence = 0
    self.context_key_count = 0
    if self:isComposing() then
        self:_refreshCandidates()
    elseif self.candidate_mode == "prediction" then
        self:_refreshVisiblePrediction()
    end
    return had_data
end

-- Append one explicitly committed fragment to the prediction context while
-- retaining only the most recent bounded Han suffix. A non-Han fragment is a
-- context boundary rather than a reason to repeat stale predictions.
function PinyinIME:_appendPredictionContext(text)
    local han = {}
    for _, char in ipairs(util.splitToChars(self.prediction_context_text or "")) do
        if util.isCJKChar(char) then
            han[#han + 1] = char
        end
    end
    local added = false
    for _, char in ipairs(util.splitToChars(text or "")) do
        if not util.isCJKChar(char) then
            self.prediction_context_text = ""
            self.association_context_candidate = nil
            return ""
        end
        han[#han + 1] = char
        added = true
    end
    if not added then
        self.prediction_context_text = ""
        return ""
    end
    local first = math.max(1, #han - self.max_prediction_context_length + 1)
    self.prediction_context_text = table.concat(han, "", first)
    return self.prediction_context_text
end

-- Static prediction data is keyed by a bounded Han-only context. In addition
-- to the accumulated frame, preserve the last explicitly committed token as a
-- trusted boundary. This lets exact-only lexical relations survive preceding
-- text without making arbitrary suffix fallback less conservative.
function PinyinIME:_predictionContextKeys(text, last_committed_text)
    local han = {}
    for _, char in ipairs(util.splitToChars(text or "")) do
        if util.isCJKChar(char) then
            han[#han + 1] = char
            if #han > self.max_prediction_context_length then
                table.remove(han, 1)
            end
        end
    end
    if #han == 0 then
        return {}
    end

    local keys, seen = {}, {}
    local function add(key, kind)
        if key ~= "" and not seen[key] then
            seen[key] = true
            keys[#keys + 1] = { text = key, kind = kind }
        end
    end

    add(table.concat(han), "exact")

    local trusted = {}
    local trusted_valid = last_committed_text ~= nil
        and last_committed_text ~= ""
    for _, char in ipairs(util.splitToChars(last_committed_text or "")) do
        if not util.isCJKChar(char) then
            trusted_valid = false
            break
        end
        trusted[#trusted + 1] = char
    end
    if trusted_valid and #trusted > 0 then
        local first = math.max(1,
            #trusted - self.max_prediction_context_length + 1)
        add(table.concat(trusted, "", first), "trusted_token")
    end

    for _, length in ipairs({ 4, 3, 2 }) do
        if #han >= length then
            add(table.concat(han, "", #han - length + 1), "suffix")
        end
    end
    return keys
end

function PinyinIME:_notifyAssociation(previous_text, current_text)
    if not self.personalization_enabled or not self.prediction_enabled
            or not self.on_association_commit
            or not previous_text or previous_text == ""
            or not current_text or current_text == "" then
        return
    end
    local ok, err = pcall(self.on_association_commit, previous_text, current_text)
    if not ok then
        -- Association learning is optional. A broken persistence callback must
        -- never disable ordinary input or lose the text the user selected.
        logger.warn("Chinese pinyin association callback failed:", err)
    end
end

function PinyinIME:_dismissPrediction(notify)
    if self.candidate_mode ~= "prediction" then
        return false
    end
    self:_resetCandidateStorage()
    self.selected_index = 0
    self.fallback_candidate = false
    self.correction_candidate = false
    self.candidate_mode = "idle"
    if notify ~= false then
        self:_notify()
    end
    return true
end

function PinyinIME:_showPredictions(context_text, last_committed_text)
    if not self.prediction_enabled or not self.prediction_lookup then
        return false
    end
    local context_keys = self:_predictionContextKeys(
        context_text, last_committed_text)
    if #context_keys == 0 then
        return false
    end
    local ok, rows = pcall(self.prediction_lookup,
        context_keys, self.max_prediction_candidates)
    if not ok then
        -- Prediction is an optional enhancement and is deliberately isolated
        -- from the core composition/error circuit breaker.
        logger.warn("Chinese pinyin prediction lookup failed:", rows)
        return false
    end
    if type(rows) ~= "table" then
        return false
    end

    local candidates = self:_resetCandidateStorage()
    local seen = clearTable(self._prediction_seen)
    for _, row in ipairs(rows) do
        local text = type(row) == "table" and row.text or row
        if type(text) == "string" and text ~= "" and not seen[text] then
            seen[text] = true
            candidates[#candidates + 1] = text
            if #candidates >= self.max_prediction_candidates then
                break
            end
        end
    end
    if #candidates == 0 then
        return false
    end

    for index = 1, #candidates do
        self.candidate_kinds[index] = "prediction"
    end
    self.selected_index = 0
    self.fallback_candidate = false
    self.correction_candidate = false
    self.candidate_mode = "prediction"
    self:_notify()
    return true
end

function PinyinIME:_sentenceTokenCandidates(code)
    local result, seen = {}, {}
    local function add(candidate)
        if candidate and not seen[candidate] then
            seen[candidate] = true
            result[#result + 1] = candidate
        end
    end
    local base = listFromValue(self.code_map[code])
    for index = 1, math.min(2, #base) do
        add(base[index])
    end
    -- One overlay candidate per token keeps sentence beam growth bounded.
    local overlay = listFromValue(self.overlay_exact[code])
    add(overlay[1])
    return result
end

function PinyinIME:_segmentPart(part)
    -- Keep only the first bounded set of longest-syllable-first paths for each
    -- byte position.  The previous depth-first search re-explored the same
    -- suffix exponentially when an ambiguous input had no complete parse.
    local memo = {}
    local function solve(position)
        if position > #part then
            return { {} }
        elseif memo[position] then
            return memo[position]
        end

        local results = {}
        local final = math.min(#part, position + self.max_syllable_length - 1)
        for last = final, position, -1 do
            local syllable = part:sub(position, last)
            if self.syllables[syllable] and self:_hasCode(syllable) then
                for _, suffix in ipairs(solve(last + 1)) do
                    local path = { syllable }
                    for _, value in ipairs(suffix) do
                        path[#path + 1] = value
                    end
                    results[#results + 1] = path
                    if #results >= self.max_segmentations then
                        break
                    end
                end
                if #results >= self.max_segmentations then
                    break
                end
            end
        end
        memo[position] = results
        return results
    end
    return solve(1)
end

function PinyinIME:_segmentationsUncached()
    local part_results = {}
    for part in self.code:gmatch("[^']+") do
        local results = self:_segmentPart(part)
        if #results == 0 then
            return {}
        end
        part_results[#part_results + 1] = results
    end
    if #part_results == 0 then
        return {}
    end

    local combined = { {} }
    for _, results in ipairs(part_results) do
        local next_combined = {}
        for _, prefix in ipairs(combined) do
            for _, suffix in ipairs(results) do
                local item = {}
                for _, syllable in ipairs(prefix) do
                    item[#item + 1] = syllable
                end
                for _, syllable in ipairs(suffix) do
                    item[#item + 1] = syllable
                end
                next_combined[#next_combined + 1] = item
                if #next_combined >= self.max_segmentations then
                    break
                end
            end
            if #next_combined >= self.max_segmentations then
                break
            end
        end
        combined = next_combined
    end
    return combined
end


function PinyinIME:_segmentations()
    local key = self.code
    local cached = self.segmentation_cache[key]
    if cached then
        return cached
    end
    local started = self.on_timing and (self.timing_clock or os.clock)() or nil
    local result = self:_segmentationsUncached()
    self:_recordTiming("segmentation", started)
    self.segmentation_cache[key] = result
    self.segmentation_cache_order[#self.segmentation_cache_order + 1] = key
    if #self.segmentation_cache_order > self.max_segmentation_cache then
        local evicted = table.remove(self.segmentation_cache_order, 1)
        self.segmentation_cache[evicted] = nil
    end
    return result
end

function PinyinIME:_phraseTokenizations(segments)
    local tokenizations = {}
    local path = {}
    local allow_merging = not self.code:find("'", 1, true)

    local function walk(position)
        if #tokenizations >= self.max_segmentations then
            return
        elseif position > #segments then
            local result = {}
            for index, token in ipairs(path) do
                result[index] = token
            end
            tokenizations[#tokenizations + 1] = result
            return
        end

        -- Compatibility mode retains the original explicit-boundary behavior.
        -- Full Wanxiang mode bypasses this tokenizer and treats apostrophes as
        -- syllable boundaries rather than barriers between phrase spans.
        local last_position = allow_merging and #segments or position
        local code = ""
        for last = position, last_position do
            code = code .. segments[last]
        end
        for last = last_position, position, -1 do
            if self:_hasCode(code) then
                path[#path + 1] = { code = code, syllable_count = last - position + 1 }
                walk(last + 1)
                path[#path] = nil
            end
            code = code:sub(1, #code - #segments[last])
        end
    end

    walk(1)
    return tokenizations
end

function PinyinIME:_legacySentenceCandidates(segments)
    if #segments < 2 then
        return {}
    end
    local cache_key = table.concat(segments, "'")
    local cached = self.legacy_sentence_cache[cache_key]
    if cached then
        return cached
    end
    local function store(results)
        self.legacy_sentence_cache[cache_key] = results
        self.legacy_sentence_cache_order[
            #self.legacy_sentence_cache_order + 1] = cache_key
        if #self.legacy_sentence_cache_order > self.max_legacy_sentence_cache then
            local evicted = table.remove(self.legacy_sentence_cache_order, 1)
            self.legacy_sentence_cache[evicted] = nil
        end
        return results
    end
    local results = {}
    for _, tokens in ipairs(self:_phraseTokenizations(segments)) do
        local beams = { { text = "", score = 0 } }
        for _, token in ipairs(tokens) do
            local token_candidates = self:_sentenceTokenCandidates(token.code)
            local next_beams = {}
            for _, beam in ipairs(beams) do
                local accepted = 0
                for index, candidate in ipairs(token_candidates) do
                    -- Some map entries contain unrelated long words. Keep a
                    -- phrase proportional to the number of syllables it covers.
                    if #util.splitToChars(candidate) <= token.syllable_count * 2 then
                        next_beams[#next_beams + 1] = {
                            text = beam.text .. candidate,
                            score = beam.score + index - 1,
                        }
                        accepted = accepted + 1
                        if accepted >= 3 then
                            break
                        end
                    end
                end
            end
            table.sort(next_beams, function(left, right)
                if left.score == right.score then
                    return left.text < right.text
                end
                return left.score < right.score
            end)
            beams = {}
            for index = 1, math.min(#next_beams, self.max_segment_candidates) do
                beams[index] = next_beams[index]
            end
            if #beams == 0 then
                break
            end
        end
        for _, beam in ipairs(beams) do
            results[#results + 1] = beam
            if #results >= self.max_segment_candidates then
                return store(results)
            end
        end
    end
    return store(results)
end

function PinyinIME:_sentenceCandidates(segments, use_lexicon)
    -- Existing tables are faster and already strong for one-to-three syllable
    -- words. Activate the SQLite word graph at sentence length, avoiding
    -- database work on every short prefix while the user is still composing.
    if #segments >= 4 and use_lexicon ~= false and self.lexicon_provider then
        return self.sentence_decoder:decode(segments)
    end
    return self:_legacySentenceCandidates(segments)
end

local function sentenceBeamOrder(left, right)
    if (left.cost or 0) ~= (right.cost or 0) then
        return (left.cost or 0) < (right.cost or 0)
    elseif (left.token_count or 0) ~= (right.token_count or 0) then
        return (left.token_count or 0) < (right.token_count or 0)
    elseif (left.lexical_score or 0) ~= (right.lexical_score or 0) then
        return (left.lexical_score or 0) > (right.lexical_score or 0)
    end
    return left.text < right.text
end

-- Exact full-code lookup is intentionally wider than the sentence graph. The
-- graph keeps four alternatives per span for bounded latency, while a user
-- paging a complete phrase may inspect up to 24 Wanxiang candidates.
function PinyinIME:_forEachLexiconExactCandidate(callback, segmentations, query_limit)
    local provider = self.lexicon_provider
    if not provider then
        return
    end
    local queried = {}
    for _, segments in ipairs(segmentations or self:_segmentations()) do
        if #segments >= 2 then
            local canonical_code = table.concat(segments, "'")
            if not queried[canonical_code] then
                queried[canonical_code] = true
                query_limit = math.min(query_limit or self.max_exact_candidates,
                    self.max_exact_candidates)
                local ok, rows = pcall(provider.lookup, provider,
                    canonical_code, query_limit)
                if not ok then
                    if self.on_lexicon_error then
                        self.on_lexicon_error(rows)
                    end
                    return
                end
                rows = type(rows) == "table" and rows or {}
                for index = 1, math.min(#rows, query_limit) do
                    local row = rows[index]
                    local text = type(row) == "table" and row.text or row
                    if type(text) == "string" and text ~= ""
                            and callback(text) == false then
                        return
                    end
                end
            end
        end
    end
end

function PinyinIME:_firstExactCandidate(code)
    local candidate
    self:_forEachExactCandidate(code, code, function(value)
        candidate = value
        return false
    end)
    return candidate
end

function PinyinIME:_acceptCorrectionCode(matches, code)
    if code and code ~= self.learning_code and self:_hasCode(code) then
        matches[code] = true
    end
end

local function forEachCorrectionAlias(aliases, callback)
    if type(aliases) == "string" then
        for canonical in aliases:gmatch("[^,]+") do
            if callback(canonical) == false then
                return false
            end
        end
    elseif type(aliases) == "table" then
        for _, canonical in ipairs(aliases) do
            if callback(canonical) == false then
                return false
            end
        end
    end
    return true
end

function PinyinIME:_fullCorrectionCodes()
    local raw = self.raw_code
    if raw == "" then
        return {}
    end
    local matches, explored = {}, 0
    local parts, offsets = {}, {}
    local normalized_offset = 0
    for part in raw:gmatch("[^']+") do
        parts[#parts + 1] = part
        offsets[#offsets + 1] = normalized_offset
        normalized_offset = normalized_offset + #part
    end
    local normalized = raw:gsub("'", "")
    for part_index, part in ipairs(parts) do
        for length = math.min(7, #part), 1, -1 do
            for position = 1, #part - length + 1 do
                local typo = part:sub(position, position + length - 1)
                local aliases = self.correction_full[typo]
                if aliases then
                    local keep_going = forEachCorrectionAlias(aliases, function(canonical)
                        explored = explored + 1
                        local start_index = offsets[part_index] + position
                        local code = normalized:sub(1, start_index - 1) .. canonical
                            .. normalized:sub(start_index + length)
                        self:_acceptCorrectionCode(matches, code)
                        if explored >= self.max_correction_states then
                            return false
                        end
                    end)
                    if not keep_going then
                        return matches
                    end
                end
            end
        end
    end
    return matches
end

function PinyinIME:_shuangpinCorrectionCodes()
    local raw = self.raw_code
    if raw == "" or raw:find("'", 1, true) or #raw % 2 ~= 0
            or self.decode_status == "pending" then
        return {}
    end
    local matches, explored = {}, 0
    for position = 1, #raw, 2 do
        local typo = raw:sub(position, position + 1)
        local keep_going = forEachCorrectionAlias(
            self.correction_shuangpin[typo], function(canonical_pair)
                explored = explored + 1
                local corrected_raw = raw:sub(1, position - 1) .. canonical_pair
                    .. raw:sub(position + 2)
                local decoded = self.shuangpin_decoder:decode(corrected_raw)
                if decoded.status == "valid" then
                    self:_acceptCorrectionCode(matches, decoded.lookup_code:gsub("'", ""))
                end
                if explored >= self.max_correction_states then
                    return false
                end
            end)
        if not keep_going then
            return matches
        end
    end
    return matches
end

function PinyinIME:_setCorrectionCandidate(matches)
    matches = matches or (self:_isShuangpin()
        and self:_shuangpinCorrectionCodes() or self:_fullCorrectionCodes())
    local codes = {}
    for code in pairs(matches) do
        codes[#codes + 1] = code
        if #codes > 1 then
            return false
        end
    end
    if #codes ~= 1 then
        return false
    end
    local code = codes[1]
    local candidate = self:_firstExactCandidate(code)
    if not candidate then
        return false
    end
    self:_resetCandidateStorage()
    self.candidates[1], self.candidates[2] = candidate, self.commit_code
    self.candidate_kinds[1], self.candidate_kinds[2] = "correction", "fallback"
    self.candidate_learning_codes[1] = code
    self.selected_index = 1
    self.fallback_candidate = false
    self.correction_candidate = true
    return true
end

function PinyinIME:_refreshCandidatesUnmeasured()
    self.candidate_mode = "composing"
    self.fallback_candidate = false
    self.correction_candidate = false
    local static_cache_key = self.static_candidate_cache_enabled and (
        self.lexicon_exact_expanded and "\1" .. self.raw_code or self.raw_code
    ) or nil
    local static_entry = static_cache_key
        and self.static_candidate_cache[static_cache_key] or nil
    if static_entry then
        local has_personal_ranking = static_entry.rankable
            and self.personalization_enabled
            and self.user_frequency[self.learning_code] ~= nil
        local context_may_apply = static_entry.rankable
            and self:_contextRankingMayApply()
        local has_context_ranking = context_may_apply
            and self:_contextRankingKey(self.learning_code, true) ~= nil
        if not has_personal_ranking and not has_context_ranking then
            self.candidates = static_entry.candidates
            self.candidate_kinds = static_entry.kinds
            self.candidate_learning_codes = static_entry.learning_codes
            self.selected_index = static_entry.selected_index
            self.fallback_candidate = static_entry.fallback_candidate
            self.correction_candidate = static_entry.correction_candidate
            self:_notify()
            return
        end
        local candidates = self:_resetCandidateStorage()
        for index, candidate in ipairs(static_entry.candidates) do
            candidates[index] = candidate
        end
        candidates = self:_applyPersonalRanking(candidates, self.learning_code)
        candidates = self:_applyContextRanking(candidates, self.learning_code)
        self.candidates = candidates
        for index = 1, #candidates do
            self.candidate_kinds[index] = "normal"
            self.candidate_learning_codes[index] = self.learning_code
        end
        self.selected_index = 1
        self:_notify()
        return
    end
    local candidates = self:_resetCandidateStorage()
    if self:_isShuangpin() and self.decode_status == "pending" then
        self:_setFallbackCandidate()
        self:_storeStaticCandidates(
            static_cache_key, self.candidates, self.learning_code, true)
        self:_notify()
        return
    elseif self:_isShuangpin() and self.decode_status == "invalid" then
        if not self:_setCorrectionCandidate() then
            self:_setFallbackCandidate()
        end
        self:_storeStaticCandidates(
            static_cache_key, self.candidates, self.learning_code, true)
        self:_notify()
        return
    end
    local normalized_code = self:_normalizedCode()
    local seen, seen_generation = self:_nextCandidateSeenGeneration()
    local segmentations = self:_segmentations()
    -- Prefer the longest-syllable-first primary parse when the compact code is
    -- an established exact word. A three-syllable word such as nian'ye'fan
    -- also has the artificial ni'an'ye'fan parse; that alternate must not bury
    -- the exact word behind character beams. When no exact word exists, a
    -- sentence-length alternate (xian... -> xi'an...) remains eligible.
    local primary = segmentations[1]
    local alternate = segmentations[2]
    local is_long_sentence = primary and (#primary >= 4
        or (alternate and #alternate >= 4
            and #normalized_code >= self.min_alternate_sentence_code_length
            and not self:_hasCode(normalized_code)))
        or false
    local function add(candidate)
        if candidate and candidate ~= "" and seen[candidate] ~= seen_generation
                and #candidates < self.max_candidates then
            if seen[candidate] == nil then
                self._candidate_seen_count = self._candidate_seen_count + 1
            end
            seen[candidate] = seen_generation
            candidates[#candidates + 1] = candidate
            return true
        end
        return false
    end

    local function addExactCandidates(limit)
        local added = 0
        limit = math.min(limit or self.max_exact_candidates,
            self.max_candidates)
        self:_forEachExactCandidate(normalized_code, self.learning_code, function(candidate)
            if add(candidate) then
                added = added + 1
            end
            return added < limit
        end)
    end
    local function addExactPhraseCandidates()
        local added = 0
        self:_forEachExactCandidate(normalized_code, self.learning_code, function(candidate)
            if #util.splitToChars(candidate) > 1 and add(candidate) then
                added = added + 1
            end
            return added < self.max_exact_candidates
        end)
    end
    local function addShortBaseHead(segments)
        local head, head_seen = {}, {}
        local function keep(candidate)
            if candidate and not head_seen[candidate] then
                head_seen[candidate] = true
                head[#head + 1] = candidate
            end
            return #head < 2
        end
        self:_forEachExactCandidate(normalized_code, self.learning_code, keep)
        if #head < 2 then
            for _, beam in ipairs(self:_legacySentenceCandidates(segments)) do
                if not keep(beam.text) then
                    break
                end
            end
        end
        for _, candidate in ipairs(head) do
            add(candidate)
        end
    end
    local function shortLexiconRows(segments)
        local code = table.concat(segments, "'")
        local cached = self.short_lexicon_cache[code]
        if cached then return cached end
        local lookup = self.lexicon_provider.lookupHead
            or self.lexicon_provider.lookup
        local timing_started = self.on_timing
            and (self.timing_clock or os.clock)() or nil
        local ok, rows = pcall(lookup, self.lexicon_provider, code,
            self.max_short_lexicon_candidates)
        -- `code_head` is deliberately sparse. A negative optional-layer hit
        -- must continue through the complete phrase table, and corruption of
        -- the head table must never remove ordinary candidates.
        if ok and #rows == 0 and self.lexicon_provider.lookupHead
                and self.lexicon_provider.lookup then
            ok, rows = pcall(self.lexicon_provider.lookup,
                self.lexicon_provider, code, self.max_short_lexicon_candidates)
        end
        self:_recordTiming("sqlite_short_lookup", timing_started)
        if not ok then
            if self.on_lexicon_error then self.on_lexicon_error(rows) end
            return {}
        end
        rows = type(rows) == "table" and rows or {}
        self.short_lexicon_cache[code] = rows
        self.short_lexicon_cache_order[#self.short_lexicon_cache_order + 1] = code
        if #self.short_lexicon_cache_order > self.max_short_lexicon_cache then
            local evicted = table.remove(self.short_lexicon_cache_order, 1)
            self.short_lexicon_cache[evicted] = nil
        end
        return rows
    end
    local function addHighConfidenceShortLexicon(segments, rows)
        if not self.lexicon_provider or #segments < 2 or #segments > 3 then
            return
        end
        local first = type(rows) == "table" and rows[1] or nil
        local second = type(rows) == "table" and rows[2] or nil
        local first_score = type(first) == "table" and tonumber(first.score) or 0
        local second_score = type(second) == "table"
            and (tonumber(second.score) or first_score) or first_score
        if type(first) == "table" and type(second) == "table"
                and tonumber(first.rank) == 1
                and (tonumber(first.source_penalty) or 0) == 0
                and first_score >= self.min_short_lexicon_head_score
                and first_score - second_score >= self.min_short_lexicon_head_margin
                and #util.splitToChars(first.text) == #segments then
            add(first.text)
        end
    end
    local function addLexiconExactCandidates(limit, selected_segmentations,
            prefetched_rows)
        if not limit then
            return
        end
        local added = 0
        if prefetched_rows then
            for index = 1, math.min(#prefetched_rows, limit) do
                local row = prefetched_rows[index]
                local candidate = type(row) == "table" and row.text or row
                if add(candidate) then added = added + 1 end
                if added >= limit then return end
            end
            return
        end
        self:_forEachLexiconExactCandidate(function(candidate)
            if add(candidate) then
                added = added + 1
            end
            return added < limit
        end, selected_segmentations or segmentations, limit)
    end
    local function addAbbreviationCandidates()
        if self:_isShuangpin() or #normalized_code < 2
                or self.lookup_code:find("'", 1, true) then
            return
        end
        local base = listFromValue(self.abbreviation_map[normalized_code])
        if self.abbreviation_overlay_merged then
            local remaining = math.max(0, self.max_abbreviation_candidates - #candidates)
            local added = 0
            for _, candidate in ipairs(base) do
                if add(candidate) then
                    added = added + 1
                    if added >= remaining then
                        break
                    end
                end
            end
            return
        end
        local overlay = listFromValue(self.overlay_abbr[normalized_code])
        local remaining = math.max(0, self.max_abbreviation_candidates - #candidates)
        local added = 0
        local function append(candidate)
            if added < remaining and add(candidate) then
                added = added + 1
            end
        end
        for index = 1, math.min(3, #base) do
            append(base[index])
        end
        for index = 1, math.min(2, #overlay) do
            append(overlay[index])
        end
        local base_index, overlay_index = 4, 3
        while added < remaining
                and (base_index <= #base or overlay_index <= #overlay) do
            append(base[base_index])
            base_index = base_index + 1
            append(overlay[overlay_index])
            overlay_index = overlay_index + 1
        end
    end
    local mixed_correction_matches
    local function addMixedCandidates()
        if self:_isShuangpin() or #normalized_code < 3 or #segmentations > 0
                or self.lookup_code:find("'", 1, true)
                or self.abbreviation_map[normalized_code]
                or self.overlay_abbr[normalized_code]
                or not self.lexicon_provider
                or type(self.lexicon_provider.lookupMixed) ~= "function" then
            return false
        end
        local timing_started = self.on_timing
            and (self.timing_clock or os.clock)() or nil
        local ok, rows = pcall(
            self.lexicon_provider.lookupMixed, self.lexicon_provider,
            normalized_code, self.max_exact_candidates)
        self:_recordTiming("sqlite_mixed_lookup", timing_started)
        if not ok then
            if self.on_lexicon_error then self.on_lexicon_error(rows) end
            return false
        end
        rows = type(rows) == "table" and rows or {}
        if #rows == 0 then
            return false
        end
        mixed_correction_matches = self:_fullCorrectionCodes()
        local correction_count = 0
        for _ in pairs(mixed_correction_matches) do
            correction_count = correction_count + 1
            if correction_count > 1 then
                break
            end
        end
        if correction_count == 1 then
            -- A mixed index hit must not replace the established unique-typo
            -- route. Resume the legacy prefix/correction/fallback order.
            return false
        end
        local added = 0
        for _, row in ipairs(rows) do
            local candidate = type(row) == "table" and row.text or row
            if add(candidate) then added = added + 1 end
        end
        return added > 0
    end
    local function addSentenceCandidates()
        local merged, alternates = {}, {}
        local explicit_boundary = self.raw_code:find("'", 1, true) ~= nil
        local alternate = is_long_sentence and not explicit_boundary
            and segmentations[2] or nil
        local alternate_code = alternate and table.concat(alternate, "'") or nil
        local primary = segmentations[1]

        -- Short inputs without a sentence-length alternate need neither score
        -- wrappers nor a sort: legacy beams are already in stable candidate
        -- order. This keeps explicit boundaries and common words on the same
        -- allocation-light path as the compatibility engine.
        if primary and #primary < 4 and not alternate then
            for _, segments in ipairs(segmentations) do
                for _, beam in ipairs(self:_legacySentenceCandidates(segments)) do
                    add(beam.text)
                end
            end
            return
        end

        if primary then
            if #primary >= 4 and self.lexicon_provider then
                local extras = alternate_code and { alternate_code } or nil
                for _, beam in ipairs(self.sentence_decoder:decode(
                        primary, extras)) do
                    merged[#merged + 1] = beam
                end
            else
                if alternate and #alternate >= 4 and self.lexicon_provider then
                    self.sentence_decoder:prefetchExact(alternate)
                end
                for _, beam in ipairs(self:_legacySentenceCandidates(primary)) do
                    merged[#merged + 1] = {
                        text = beam.text,
                        cost = 1024 + (beam.score or 0) * 32,
                        token_count = #primary,
                        lexical_score = 0,
                    }
                end
            end
        end

        if alternate and self.lexicon_provider then
            for _, beam in ipairs(self.sentence_decoder:exactCandidates(alternate)) do
                alternates[#alternates + 1] = {
                    text = beam.text,
                    cost = beam.cost + 16,
                    token_count = 1,
                    lexical_score = beam.lexical_score or 0,
                }
            end
        end
        for _, beam in ipairs(alternates) do
            merged[#merged + 1] = beam
        end
        table.sort(merged, sentenceBeamOrder)
        for _, beam in ipairs(merged) do
            add(beam.text)
        end

        -- Further parses remain the lightweight compatibility fallback. Only
        -- two segmentations may touch SQLite.
        for segmentation_index = 2, #segmentations do
            if segmentation_index > self.max_lexicon_segmentations
                    or explicit_boundary then
                for _, beam in ipairs(self:_legacySentenceCandidates(
                        segmentations[segmentation_index])) do
                    add(beam.text)
                end
            end
        end
    end
    -- An apostrophe is an explicit syllable boundary, so respect it before the
    -- unseparated dictionary spelling (xi'an should prefer 西安 over 先).
    local mixed_hit = addMixedCandidates()
    if mixed_hit then
        -- The precompiled result is already ranked and complete. In
        -- particular, do not reinterpret the mixed key as a prefix.
    elseif self.lexicon_provider and is_long_sentence then
        -- For a sentence-length composition, prefer the whole-code dictionary
        -- and bounded word graph over legacy exact/abbreviation fragments.
        if self.lexicon_exact_expanded then
            addLexiconExactCandidates(self.max_exact_candidates)
        end
        addSentenceCandidates()
        addExactPhraseCandidates()
        addExactCandidates()
        addAbbreviationCandidates()
    elseif self.lookup_code:find("'", 1, true) then
        local short = segmentations[1]
        addExactPhraseCandidates()
        if self.lexicon_provider and not self:_hasCode(normalized_code)
                and short and #short >= 2 and #short <= 3 then
            addLexiconExactCandidates(self.lexicon_exact_expanded
                and self.max_exact_candidates or self.max_short_lexicon_candidates,
                { short })
        elseif self.lexicon_exact_expanded then
            addLexiconExactCandidates(self.max_exact_candidates)
        end
        addSentenceCandidates()
        addExactCandidates()
    else
        local short = segmentations[1]
        if self.lexicon_provider and not self.lexicon_exact_expanded
                and not self:_hasCode(normalized_code)
                and short and #short >= 2 and #short <= 3 then
            -- Preserve the established in-memory leaders, then put complete
            -- Wanxiang words missing from the compact dictionary on the first
            -- page before the recomposed tail. Established exact words stay
            -- entirely on the faster in-memory path.
            local short_rows = shortLexiconRows(short)
            addHighConfidenceShortLexicon(short, short_rows)
            addShortBaseHead(short)
            addLexiconExactCandidates(self.max_short_lexicon_candidates,
                { short }, short_rows)
            addExactCandidates()
        elseif self.lexicon_exact_expanded and short
                and #short >= 2 and #short <= 3 then
            -- Once the user explicitly expands a short composition, expose
            -- the wider exact lexicon before recomposed character beams. The
            -- initial page remains conservative; this also preserves the old
            -- expanded order for ambiguous three-syllable names.
            addLexiconExactCandidates(self.max_exact_candidates)
            addExactCandidates()
        else
            -- A single syllable can map to more than 24 Han characters. Keep
            -- the initial page unchanged, but let explicit expansion reach
            -- the rest of the existing base table so those characters remain
            -- inputtable without a frequency or dictionary exception.
            addExactCandidates(self.lexicon_exact_expanded and short
                and #short == 1 and self.max_candidates or nil)
            if self.lexicon_exact_expanded then
                addLexiconExactCandidates(self.max_exact_candidates)
            end
        end
        addAbbreviationCandidates()
        addSentenceCandidates()
    end

    if not mixed_hit then
        local prefix_index = lowerBound(self.sorted_codes, normalized_code)
        local matched_codes = 0
        for index = prefix_index, #self.sorted_codes do
            local code = self.sorted_codes[index]
            if code:sub(1, #normalized_code) ~= normalized_code then
                break
            elseif code ~= normalized_code then
                matched_codes = matched_codes + 1
                local values = listFromValue(self.code_map[code])
                for candidate_index = 1, math.min(2, #values) do
                    add(values[candidate_index])
                end
                if matched_codes >= self.max_prefix_codes
                        or #candidates >= self.max_candidates then
                    break
                end
            end
        end
    end

    if #candidates == 0 then
        if not self:_setCorrectionCandidate(mixed_correction_matches) then
            self:_setFallbackCandidate()
        end
        self:_storeStaticCandidates(
            static_cache_key, self.candidates, self.learning_code, true)
    else
        self:_storeStaticCandidates(
            static_cache_key, candidates, self.learning_code)
        candidates = self:_applyPersonalRanking(candidates, self.learning_code)
        candidates = self:_applyContextRanking(candidates, self.learning_code)
        self.candidates = candidates
        for index = 1, #candidates do
            self.candidate_kinds[index] = "normal"
            self.candidate_learning_codes[index] = self.learning_code
        end
        self.selected_index = 1
    end
    self:_notify()
end


function PinyinIME:_refreshCandidates()
    if not self.on_timing then
        return self:_refreshCandidatesUnmeasured()
    end
    local started = (self.timing_clock or os.clock)()
    local result = self:_refreshCandidatesUnmeasured()
    self:_recordTiming("candidate_refresh", started)
    return result
end

function PinyinIME:_clear()
    self.raw_code = ""
    self.lookup_code = ""
    self.display_code = ""
    self.commit_code = ""
    self.learning_code = ""
    self.decode_status = "idle"
    self.code = ""
    self:_resetCandidateStorage()
    self.candidate_mode = "idle"
    self.selected_index = 0
    self.fallback_candidate = false
    self.correction_candidate = false
    self.lexicon_exact_expanded = false
    self:_notify()
end

function PinyinIME:cancel()
    local had_composition = self:isComposing()
    local had_prediction = self.candidate_mode == "prediction"
    self:resetContext()
    if had_composition then
        self:_clear()
        return true
    end
    return had_prediction
end

function PinyinIME:_finish(text, kind, learning_code, committed_index)
    kind = kind or "fallback"
    learning_code = learning_code or self.learning_code
    local previous_text = self.association_context_candidate
    local should_predict = false
    local prediction_context
    if (kind == "normal" or kind == "correction") and text and text ~= "" then
        if self.personalization_enabled and self.on_commit then
            self.on_commit(learning_code, text, kind)
        end
        self:_rememberContext(learning_code, text, (committed_index or 1) > 1)
        self:_notifyAssociation(previous_text, text)
        self.association_context_candidate = text
        prediction_context = self:_appendPredictionContext(text)
        should_predict = true
    elseif kind == "prediction" and text and text ~= "" then
        self:_notifyAssociation(previous_text, text)
        self.previous_context_candidate = text
        self.association_context_candidate = text
        prediction_context = self:_appendPredictionContext(text)
        should_predict = true
    elseif kind == "fallback" then
        self:resetContext()
    end
    self:_clear()
    -- Prediction advances only after an explicit selection. Each user action
    -- therefore performs at most one bounded lookup; no automatic chain runs.
    if should_predict then
        self:_showPredictions(prediction_context, text)
    end
    return text or ""
end

function PinyinIME:commitCandidate(index)
    index = index or self.selected_index
    local candidate = self.candidates[index]
    if not candidate then
        return ""
    end
    local kind = self.candidate_kinds[index] or "normal"
    return self:_finish(candidate, kind, self.candidate_learning_codes[index], index)
end

function PinyinIME:commitCandidateOnPage(slot)
    local state = self:getState()
    local index = (state.page - 1) * self.page_size + slot
    return self:commitCandidate(index)
end

function PinyinIME:flush()
    if not self:isComposing() then
        self:_dismissPrediction()
        return ""
    elseif self.selected_index > 0 then
        return self:commitCandidate(self.selected_index)
    end
    return self:_finish(self.commit_code, "fallback")
end

function PinyinIME:commitRaw()
    if not self:isComposing() then
        return ""
    end
    return self:_finish(self.commit_code, "fallback")
end

function PinyinIME:backspace()
    if not self:isComposing() then
        self:resetContext()
        return false
    end
    self.raw_code = self.raw_code:sub(1, -2)
    self:_syncComposition()
    if self.raw_code == "" then
        self:_clear()
    else
        self:_refreshCandidates()
    end
    return true
end

function PinyinIME:_bestSyllablePath(part)
    local memo = {}
    local function solve(position)
        if position > #part then
            return {}
        elseif memo[position] ~= nil then
            return memo[position] or nil
        end
        local best
        local final = math.min(#part, position + self.max_syllable_length - 1)
        for last = final, position, -1 do
            local syllable = part:sub(position, last)
            if self.syllables[syllable] then
                local suffix = solve(last + 1)
                if suffix then
                    local path = { syllable }
                    for _, value in ipairs(suffix) do
                        path[#path + 1] = value
                    end
                    if not best or #path < #best then
                        best = path
                    end
                end
            end
        end
        memo[position] = best or false
        return best
    end
    return solve(1)
end

function PinyinIME:_deleteFullPinyinUnit()
    local raw = self.raw_code
    if raw:sub(-1) == "'" then
        return raw:sub(1, -2)
    end
    local boundary = raw:match("^.*()'")
    local prefix = boundary and raw:sub(1, boundary) or ""
    local part = boundary and raw:sub(boundary + 1) or raw
    local path = self:_bestSyllablePath(part)
    local keep
    if path and #path > 0 then
        keep = #part - #path[#path]
    else
        local legal_prefix = 0
        for last = #part - 1, 1, -1 do
            if self:_bestSyllablePath(part:sub(1, last)) then
                legal_prefix = last
                break
            end
        end
        keep = legal_prefix
    end
    if keep <= 0 then
        return prefix ~= "" and prefix:sub(1, -2) or ""
    end
    return prefix .. part:sub(1, keep)
end

function PinyinIME:_deleteShuangpinUnit()
    local raw = self.raw_code
    local quoted_start = raw:match("()'[^']*'$")
    if quoted_start then
        return raw:sub(1, quoted_start - 1)
    end
    local unmatched = raw:match("()'[^']*$")
    if unmatched then
        return raw:sub(1, unmatched - 1)
    end
    local delete_count = #raw % 2 == 1 and 1 or 2
    return raw:sub(1, math.max(0, #raw - delete_count))
end

function PinyinIME:deleteLastUnit()
    if not self:isComposing() then
        self:resetContext()
        return false
    end
    self.raw_code = self:_isShuangpin()
        and self:_deleteShuangpinUnit() or self:_deleteFullPinyinUnit()
    self.lexicon_exact_expanded = false
    self:_syncComposition()
    if self.raw_code == "" then
        self:_clear()
    else
        self:_refreshCandidates()
    end
    return true
end

function PinyinIME:moveSelection(delta)
    if #self.candidates == 0 then
        return false
    end
    self.selected_index = math.max(1, math.min(#self.candidates, self.selected_index + delta))
    self:_notify()
    return true
end

function PinyinIME:previousPage()
    if #self.candidates == 0 then
        return false
    end
    local state = self:getState()
    if not state.has_previous_page then
        return false
    end
    self.selected_index = math.max(1, self.selected_index - self.page_size)
    self:_notify()
    return true
end

function PinyinIME:expandLexiconCandidates()
    if self.lexicon_exact_expanded or not self:isComposing() then
        return false
    end
    self.lexicon_exact_expanded = true
    self:_refreshCandidates()
    return true
end

function PinyinIME:nextPage()
    if #self.candidates == 0 then
        return false
    end
    self:expandLexiconCandidates()
    local state = self:getState()
    if not state.has_next_page then
        return false
    end
    self.selected_index = math.min(#self.candidates, self.selected_index + self.page_size)
    self:_notify()
    return true
end

function PinyinIME:processCharacter(char)
    -- A normal composition key does not emit text. Keep that hot path free of
    -- a short-lived table: long typing sessions otherwise create one output
    -- table per key even though almost all of them remain empty.
    local output = ""
    local lower = char:lower()
    local is_letter = lower:match("^[a-z]$") ~= nil
    local is_scheme_semicolon = char == ";"
        and InputSchemes.isAllowedCharacter(self.input_scheme, char)
        and self.shuangpin_decoder
        and self.shuangpin_decoder:canAppendFinal(self.raw_code, char)
    if is_letter or is_scheme_semicolon then
        -- Starting the next composition hides zero-input predictions but
        -- retains the committed contexts for ranking and the next lookup.
        self:_dismissPrediction(false)
        if #self.raw_code >= self.max_code_length then
            output = self:flush()
        end
        self.raw_code = self.raw_code .. lower
        self.lexicon_exact_expanded = false
        self:_syncComposition()
        self:_refreshCandidates()
    elseif char == "'" and (self:isComposing() or self:_isShuangpin()) then
        self:_dismissPrediction(false)
        if self:_isShuangpin() or self.raw_code:sub(-1) ~= "'" then
            self.raw_code = self.raw_code .. char
            self.lexicon_exact_expanded = false
            self:_syncComposition()
            self:_refreshCandidates()
        end
    elseif char:match("^[1-9]$") and self:isComposing() then
        local slot = tonumber(char)
        if self:isCandidateSlotVisible(slot) then
            output = self:commitCandidateOnPage(slot)
        end
    elseif char == " " and self:isComposing() then
        output = self:flush()
    elseif char == "\n" and self:isComposing() then
        output = self:commitRaw()
    else
        self:_dismissPrediction()
        output = self:flush() .. char
        -- Any literal committed outside composition is an explicit prediction
        -- and association boundary. Preserve the older composition hint for
        -- digit/space patterns such as 第 2 章, but never expose it as a trusted
        -- token to next-text prediction or association learning.
        self.prediction_context_text = ""
        self.association_context_candidate = nil
        if char:match("[。！？%.%!%?；;]") or char == "\n" then
            self.previous_context_candidate = nil
        end
    end
    return output
end

function PinyinIME:processText(text)
    if isSingleUtf8Character(text) then
        return self:processCharacter(text)
    end
    local output = {}
    for _, char in ipairs(util.splitToChars(text)) do
        output[#output + 1] = self:processCharacter(char)
    end
    return table.concat(output)
end

function PinyinIME:getInputScheme()
    return self.input_scheme
end

function PinyinIME:getInputSchemeLabel()
    return self:_isShuangpin() and "双拼" or "全拼"
end

function PinyinIME:getInputSchemeAccessibilityLabel()
    return "空格，当前拼音方案为" .. self:getInputSchemeLabel()
        .. "，长按选择拼音方案"
end

function PinyinIME:_insertCommittedText(text)
    if not self.inputbox or not text or text == "" then
        return text or ""
    end
    self.inputbox.preedit_text = nil
    self.inputbox._preedit_start_idx = nil
    self.inputbox._preedit_end_idx = nil
    self.inputbox._preedit_cursor_idx = nil
    self.inputbox.addChars:raw_method_call(text)
    return ""
end

function PinyinIME:setInputScheme(scheme, finish_composition, resources)
    scheme = InputSchemes.normalize(scheme)
    if scheme == self.input_scheme then
        return "", false
    end

    local target_decoder
    local target_corrections = {}
    local target_data_file
    if InputSchemes.isShuangpin(scheme) then
        local prepared, prepare_err = xpcall(function()
            if not resources and self.on_prepare_scheme then
                resources = self.on_prepare_scheme(scheme)
            end
            target_decoder = resources and resources.decoder or self.shuangpin_decoder
            if not target_decoder then
                error("double-pinyin decoder is unavailable for " .. scheme)
            end
            target_data_file = InputSchemes.get(scheme).data_file
            if not resources and self.shuangpin_data_file
                    and self.shuangpin_data_file ~= target_data_file then
                error("double-pinyin resources do not match " .. scheme)
            end
            target_corrections = resources and resources.corrections
                or self.correction_shuangpin or {}
        end, debug.traceback)
        if not prepared then
            logger.warn("Chinese pinyin scheme preparation failed:", prepare_err)
            return "", false
        end
    end

    local committed = ""
    self:_beginUpdate()
    local ok, err = xpcall(function()
        if self:isComposing() then
            if finish_composition then
                committed = self:_insertCommittedText(self:flush())
            else
                self:cancel()
            end
        end
        if InputSchemes.isShuangpin(scheme) then
            self.shuangpin_decoder = target_decoder
            self.correction_shuangpin = target_corrections
            self.shuangpin_data_file = target_data_file
        else
            self.shuangpin_decoder = nil
            self.correction_shuangpin = {}
            self.shuangpin_data_file = nil
        end
        self.input_scheme = scheme
        self:invalidateCandidateCaches()
        self.shuangpin_decode_cache = {}
        self.shuangpin_decode_cache_slots = {}
        self.shuangpin_decode_cache_next = 1
        self:resetContext()
        self:_syncComposition()
        self:_notify()
    end, debug.traceback)
    self:_endUpdate()
    if not ok then
        self:_reportError(err, self.inputbox and self.inputbox.keyboard)
        return "", false
    end
    if self.on_scheme_changed then
        local changed_ok, changed_err = xpcall(function()
            self.on_scheme_changed(self, scheme)
        end, debug.traceback)
        if not changed_ok then
            self:_reportError(changed_err, self.inputbox and self.inputbox.keyboard)
            return committed, false
        end
    end
    return committed, true
end

function PinyinIME:toggleInputScheme()
    if self.on_toggle_scheme then
        return self.on_toggle_scheme(self)
    end
    local scheme = self.input_scheme == "full" and "flypy" or "full"
    return self:setInputScheme(scheme, true)
end

function PinyinIME:attach(inputbox, on_update)
    self.inputbox = inputbox
    self.on_update = function(state)
        if inputbox.setPreeditText then
            inputbox:setPreeditText(state.code)
        end
        if on_update then
            on_update(state)
        end
    end
    local wrappers = {}

    local function clearDisplayedPreedit()
        if inputbox.preedit_text then
            inputbox.preedit_text = nil
            inputbox._preedit_start_idx = nil
            inputbox._preedit_end_idx = nil
            inputbox._preedit_cursor_idx = nil
        end
    end
    local function insertRaw(text)
        if text and text ~= "" then
            clearDisplayedPreedit()
            inputbox.addChars:raw_method_call(text)
        end
    end
    local function batch(callback)
        self:_beginUpdate()
        local ok, result = xpcall(callback, debug.traceback)
        self:_endUpdate()
        if not ok then
            self:_reportError(result, inputbox.keyboard)
            return nil, false
        end
        return result, true
    end
    local function wrappedAddChars(_, text)
        -- Virtual/physical keyboard events are single characters. Multi-char
        -- additions come from paste/programmatic insertion and are already
        -- committed text, so they must not be reinterpreted as pinyin.
        local timing_started = self.on_timing
            and (self.timing_clock or os.clock)() or nil
        local raw_before = self.raw_code
        local _, ok = batch(function()
            if not isSingleUtf8Character(text) then
                local committed = self:flush()
                -- Paste/programmatic insertion is an opaque context boundary:
                -- commit any preedit, but do not leave predictions generated
                -- for the text that now precedes the pasted payload.
                self:resetContext()
                insertRaw(committed .. text)
            else
                insertRaw(self:processText(text))
            end
        end)
        -- If processing failed before accepting this event, preserve it once.
        -- If raw_code changed, session fallback will commit the accepted input.
        if not ok and self.raw_code == raw_before and text and text ~= "" then
            clearDisplayedPreedit()
            pcall(inputbox.addChars.raw_method_call, inputbox.addChars, text)
        end
        self:_recordTiming("input_adapter", timing_started)
    end
    local function wrappedDelChar()
        local was_composing = self:isComposing()
        local ok, err = xpcall(function()
            if not self:backspace() then
                inputbox.delChar:raw_method_call()
            end
        end, debug.traceback)
        if not ok then
            if was_composing then
                pcall(inputbox.delChar.raw_method_call, inputbox.delChar)
            end
            self:_reportError("delete input failed: " .. tostring(err), inputbox.keyboard)
        end
    end
    local function wrappedDelWord(_, left_to_cursor)
        local was_composing = self:isComposing()
        local ok, err = xpcall(function()
            if self.candidate_mode == "prediction" then
                self:resetContext()
                inputbox.delWord:raw_method_call(left_to_cursor)
            elseif not self:cancel() then
                inputbox.delWord:raw_method_call(left_to_cursor)
            end
        end, debug.traceback)
        if not ok then
            if was_composing then
                pcall(inputbox.delWord.raw_method_call, inputbox.delWord, left_to_cursor)
            end
            self:_reportError("delete word failed: " .. tostring(err), inputbox.keyboard)
        end
    end
    local function wrappedDelToStartOfLine()
        local was_composing = self:isComposing()
        local ok, err = xpcall(function()
            if self.candidate_mode == "prediction" then
                self:resetContext()
                inputbox.delToStartOfLine:raw_method_call()
            elseif not self:cancel() then
                inputbox.delToStartOfLine:raw_method_call()
            end
        end, debug.traceback)
        if not ok then
            if was_composing then
                pcall(inputbox.delToStartOfLine.raw_method_call,
                    inputbox.delToStartOfLine)
            end
            self:_reportError("delete line failed: " .. tostring(err), inputbox.keyboard)
        end
    end
    local function wrappedLeftChar()
        local was_composing = self:isComposing()
        local ok, err = xpcall(function()
            if not self:isComposing() then
                self:resetContext()
                inputbox.leftChar:raw_method_call()
            elseif self.selected_index == 0 then
                insertRaw(self:flush())
                self:resetContext()
                inputbox.leftChar:raw_method_call()
            else
                self:moveSelection(-1)
            end
        end, debug.traceback)
        if not ok then
            if was_composing then
                pcall(inputbox.leftChar.raw_method_call, inputbox.leftChar)
            end
            self:_reportError("left navigation failed: " .. tostring(err), inputbox.keyboard)
        end
    end
    local function wrappedRightChar()
        local was_composing = self:isComposing()
        local ok, err = xpcall(function()
            if not self:isComposing() then
                self:resetContext()
                inputbox.rightChar:raw_method_call()
            elseif self.selected_index == 0 then
                insertRaw(self:flush())
                self:resetContext()
                inputbox.rightChar:raw_method_call()
            else
                self:moveSelection(1)
            end
        end, debug.traceback)
        if not ok then
            if was_composing then
                pcall(inputbox.rightChar.raw_method_call, inputbox.rightChar)
            end
            self:_reportError("right navigation failed: " .. tostring(err), inputbox.keyboard)
        end
    end
    local function wrappedUpLine()
        local was_composing = self:isComposing()
        local ok, err = xpcall(function()
            if not self:isComposing() then
                self:resetContext()
                inputbox.upLine:raw_method_call()
            elseif self.selected_index == 0 then
                insertRaw(self:flush())
                self:resetContext()
                inputbox.upLine:raw_method_call()
            else
                self:previousPage()
            end
        end, debug.traceback)
        if not ok then
            if was_composing then
                pcall(inputbox.upLine.raw_method_call, inputbox.upLine)
            end
            self:_reportError("up navigation failed: " .. tostring(err), inputbox.keyboard)
        end
    end
    local function wrappedDownLine()
        local was_composing = self:isComposing()
        local ok, err = xpcall(function()
            if not self:isComposing() then
                self:resetContext()
                inputbox.downLine:raw_method_call()
            elseif self.selected_index == 0 then
                insertRaw(self:flush())
                self:resetContext()
                inputbox.downLine:raw_method_call()
            else
                self:nextPage()
            end
        end, debug.traceback)
        if not ok then
            if was_composing then
                pcall(inputbox.downLine.raw_method_call, inputbox.downLine)
            end
            self:_reportError("down navigation failed: " .. tostring(err), inputbox.keyboard)
        end
    end
    local function commitComposition()
        batch(function()
            insertRaw(self:flush())
        end)
    end
    local function cancelComposition()
        self:cancel()
    end
    local function finishAndResetContext()
        batch(function()
            insertRaw(self:flush())
            self:resetContext()
        end)
    end

    wrappers[#wrappers + 1] = util.wrapMethod(inputbox, "addChars", wrappedAddChars, nil)
    wrappers[#wrappers + 1] = util.wrapMethod(inputbox, "delChar", wrappedDelChar, nil)
    wrappers[#wrappers + 1] = util.wrapMethod(inputbox, "delWord", wrappedDelWord, nil)
    wrappers[#wrappers + 1] = util.wrapMethod(inputbox, "delToStartOfLine", wrappedDelToStartOfLine, nil)
    wrappers[#wrappers + 1] = util.wrapMethod(inputbox, "leftChar", wrappedLeftChar, nil)
    wrappers[#wrappers + 1] = util.wrapMethod(inputbox, "rightChar", wrappedRightChar, nil)
    wrappers[#wrappers + 1] = util.wrapMethod(inputbox, "upLine", wrappedUpLine, nil)
    wrappers[#wrappers + 1] = util.wrapMethod(inputbox, "downLine", wrappedDownLine, nil)
    wrappers[#wrappers + 1] = util.wrapMethod(inputbox, "clear", nil, cancelComposition)
    wrappers[#wrappers + 1] = util.wrapMethod(inputbox, "goToStartOfLine", nil, finishAndResetContext)
    wrappers[#wrappers + 1] = util.wrapMethod(inputbox, "goToEndOfLine", nil, finishAndResetContext)
    wrappers[#wrappers + 1] = util.wrapMethod(inputbox, "scrollUp", nil, finishAndResetContext)
    wrappers[#wrappers + 1] = util.wrapMethod(inputbox, "scrollDown", nil, finishAndResetContext)
    wrappers[#wrappers + 1] = util.wrapMethod(inputbox, "unfocus", nil, finishAndResetContext)
    wrappers[#wrappers + 1] = util.wrapMethod(inputbox, "onCloseKeyboard", nil, finishAndResetContext)
    wrappers[#wrappers + 1] = util.wrapMethod(inputbox, "onTapTextBox", nil, finishAndResetContext)
    wrappers[#wrappers + 1] = util.wrapMethod(inputbox, "onHoldTextBox", nil, finishAndResetContext)
    wrappers[#wrappers + 1] = util.wrapMethod(inputbox, "onSwipeTextBox", nil, finishAndResetContext)
    wrappers[#wrappers + 1] = util.wrapMethod(inputbox, "onSwitchingKeyboardLayout", nil, finishAndResetContext)

    self:_notify()
    return function(mode)
        pcall(function()
            if mode == "raw" then
                batch(function()
                    insertRaw(self:commitRaw())
                end)
            elseif mode == "cancel" then
                self:cancel()
            else
                commitComposition()
            end
        end)
        for _, wrapper in ipairs(wrappers) do
            pcall(wrapper.revert, wrapper)
        end
        self:resetContext()
        self.inputbox = nil
        self.on_update = nil
    end
end

function PinyinIME:insertCandidate(index)
    local raw_fallback = self.candidate_mode == "prediction"
        and self.candidates[index] or self.commit_code
    self:_beginUpdate()
    local ok, err = xpcall(function()
        local text = self:commitCandidate(index)
        if text ~= "" and self.inputbox then
            if self.inputbox.preedit_text then
                self.inputbox.preedit_text = nil
                self.inputbox._preedit_start_idx = nil
                self.inputbox._preedit_end_idx = nil
                self.inputbox._preedit_cursor_idx = nil
            end
            self.inputbox.addChars:raw_method_call(text)
        end
    end, debug.traceback)
    self:_endUpdate()
    if not ok then
        if raw_fallback ~= "" and self.inputbox and not self:isComposing() then
            pcall(self.inputbox.addChars.raw_method_call,
                self.inputbox.addChars, raw_fallback)
        end
        self:_reportError(err, self.inputbox and self.inputbox.keyboard)
        return false
    end
    return true
end

function PinyinIME:insertCandidateOnPage(slot)
    local state = self:getState()
    local index = (state.page - 1) * self.page_size + slot
    return self:insertCandidate(index)
end

return PinyinIME
