local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local plugin_root = source:match("^(.*)/lib/settings%.lua$")
local InputSchemes = dofile(plugin_root .. "/lib/input_schemes.lua")
local util = require("util")

local LearningWriter

local Settings = {}

local MAX_CODES = 5000
local MAX_CANDIDATES_PER_CODE = 20
local MAX_CODE_LENGTH = 64
local MAX_CANDIDATE_LENGTH = 64
local MAX_FREQUENCY = 1000
local MAX_SEQUENCE = 2147483647
local LEARNING_FLUSH_DELAY = 2
local MAX_ASSOCIATION_CONTEXTS = 512
local MAX_ASSOCIATIONS_PER_CONTEXT = 3
local MAX_PROVISIONAL_ASSOCIATIONS_PER_CONTEXT = 1
local MAX_ASSOCIATION_TEXT_LENGTH = 12
local MAX_ASSOCIATION_FREQUENCY = 100
local MIN_ASSOCIATION_FREQUENCY = 2
-- Association time is measured in successful adjacent commits, so it remains
-- deterministic when the wall clock is wrong or unavailable on an e-reader.
-- One point expires per interval; a twice-seen transition therefore becomes
-- inactive after a long run of unrelated input and must be reinforced before
-- it can displace static data again.
local ASSOCIATION_DECAY_INTERVAL = 256

local function enabledByDefault(value)
    if type(value) == "boolean" then
        return value
    end
    return true
end

local function validFrequency(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge and value >= 1
end

local function validCandidate(candidate)
    if type(candidate) ~= "string" or candidate == "" then
        return false
    end
    return #util.splitToChars(candidate) <= MAX_CANDIDATE_LENGTH
end

local function normalizeRecord(value)
    if validFrequency(value) then
        return { count = math.min(math.floor(value), MAX_FREQUENCY), last_used = 0 }, true
    elseif type(value) ~= "table" or not validFrequency(value.count) then
        return nil, true
    end
    local count = math.min(math.floor(value.count), MAX_FREQUENCY)
    local last_used = tonumber(value.last_used) or 0
    if last_used ~= last_used or last_used == math.huge or last_used == -math.huge then
        last_used = 0
    end
    last_used = math.max(0, math.min(math.floor(last_used), MAX_SEQUENCE))
    local changed = count ~= value.count or last_used ~= value.last_used
    return { count = count, last_used = last_used }, changed
end

local function candidateRows(candidates)
    local rows = {}
    for candidate, record in pairs(candidates) do
        rows[#rows + 1] = {
            candidate = candidate,
            count = record.count,
            last_used = record.last_used,
        }
    end
    table.sort(rows, function(left, right)
        if left.count == right.count and left.last_used == right.last_used then
            return left.candidate < right.candidate
        elseif left.count == right.count then
            return left.last_used > right.last_used
        end
        return left.count > right.count
    end)
    return rows
end

local function associationEffectiveCount(record, sequence)
    local age = math.max(0, sequence - record.last_used)
    return math.max(0, record.count - math.floor(age / ASSOCIATION_DECAY_INTERVAL))
end

local function associationCandidateRows(candidates, sequence)
    local rows = {}
    for candidate, record in pairs(candidates) do
        rows[#rows + 1] = {
            candidate = candidate,
            count = record.count,
            effective_count = associationEffectiveCount(record, sequence),
            last_used = record.last_used,
        }
    end
    table.sort(rows, function(left, right)
        if left.effective_count ~= right.effective_count then
            return left.effective_count > right.effective_count
        elseif left.last_used ~= right.last_used then
            return left.last_used > right.last_used
        elseif left.count ~= right.count then
            return left.count > right.count
        end
        return left.candidate < right.candidate
    end)
    return rows
end

-- Keep three established transitions plus one one-shot provisional. The
-- provisional is intentionally excluded from lookup by the frequency
-- threshold, but survives long enough for a second consecutive observation
-- to promote it. A protected promotion is retained before ranking the old
-- established rows, preventing a fresh count=2 transition from being starved
-- by three older count=2 transitions.
local function trimAssociationCandidates(candidates, sequence, protected_candidate)
    local rows = associationCandidateRows(candidates, sequence)
    local keep = {}
    local established_count = 0
    local protected = protected_candidate and candidates[protected_candidate]
    if protected and protected.count >= MIN_ASSOCIATION_FREQUENCY then
        keep[protected_candidate] = true
        established_count = 1
    end
    for _, row in ipairs(rows) do
        if row.count >= MIN_ASSOCIATION_FREQUENCY
                and not keep[row.candidate]
                and established_count < MAX_ASSOCIATIONS_PER_CONTEXT then
            keep[row.candidate] = true
            established_count = established_count + 1
        end
    end

    local provisional_count = 0
    for _, row in ipairs(rows) do
        if row.count < MIN_ASSOCIATION_FREQUENCY
                and provisional_count < MAX_PROVISIONAL_ASSOCIATIONS_PER_CONTEXT then
            keep[row.candidate] = true
            provisional_count = provisional_count + 1
        end
    end

    local changed = false
    for candidate in pairs(candidates) do
        if not keep[candidate] then
            candidates[candidate] = nil
            changed = true
        end
    end
    return changed
end

local function validAssociationText(value)
    if type(value) ~= "string" or value == "" then
        return false
    end
    local chars = util.splitToChars(value)
    if #chars > MAX_ASSOCIATION_TEXT_LENGTH then
        return false
    end
    for _, char in ipairs(chars) do
        if not util.isCJKChar(char) then
            return false
        end
    end
    return true
end

local function associationContextKeys(value)
    if type(value) ~= "string" or value == "" then
        return {}
    end
    local chars = util.splitToChars(value)
    for _, char in ipairs(chars) do
        if not util.isCJKChar(char) then
            return {}
        end
    end
    if #chars > MAX_ASSOCIATION_TEXT_LENGTH then
        local trimmed = {}
        for index = #chars - MAX_ASSOCIATION_TEXT_LENGTH + 1, #chars do
            trimmed[#trimmed + 1] = chars[index]
        end
        chars = trimmed
    end
    local keys, seen = {}, {}
    local function add(first)
        local key = table.concat(chars, "", first, #chars)
        if not seen[key] then
            seen[key] = true
            keys[#keys + 1] = key
        end
    end
    add(1)
    for _, length in ipairs({ 4, 3, 2 }) do
        if #chars > length then
            add(#chars - length + 1)
        end
    end
    return keys
end

local function associationContextRows(associations, sequence)
    local rows = {}
    for context, candidates in pairs(associations) do
        local total, last_used = 0, 0
        for _, record in pairs(candidates) do
            total = total + associationEffectiveCount(record, sequence)
            last_used = math.max(last_used, record.last_used)
        end
        rows[#rows + 1] = {
            context = context,
            frequency = total,
            last_used = last_used,
        }
    end
    table.sort(rows, function(left, right)
        if left.frequency == right.frequency and left.last_used == right.last_used then
            return left.context < right.context
        elseif left.frequency == right.frequency then
            return left.last_used > right.last_used
        end
        return left.frequency > right.frequency
    end)
    return rows
end

local function evictLowestAssociationContext(associations, sequence)
    local lowest_context, lowest_frequency, lowest_last_used
    for context, candidates in pairs(associations) do
        local total, last_used = 0, 0
        for _, record in pairs(candidates) do
            total = total + associationEffectiveCount(record, sequence)
            last_used = math.max(last_used, record.last_used)
        end
        if not lowest_frequency or total < lowest_frequency
                or total == lowest_frequency and last_used < lowest_last_used
                or total == lowest_frequency and last_used == lowest_last_used
                    and context > lowest_context then
            lowest_context = context
            lowest_frequency = total
            lowest_last_used = last_used
        end
    end
    if lowest_context then
        associations[lowest_context] = nil
    end
    return lowest_context
end

local function normalizeAssociations(stored, stored_sequence)
    if type(stored) ~= "table" then
        return {}, 0, true
    end
    local normalized, changed = {}, false
    local sequence = tonumber(stored_sequence) or 0
    if sequence ~= sequence or sequence == math.huge or sequence == -math.huge then
        sequence = 0
    end
    sequence = math.max(0, math.min(math.floor(sequence), MAX_SEQUENCE))
    if sequence ~= stored_sequence then
        changed = true
    end

    for context, candidates in pairs(stored) do
        if not validAssociationText(context) or type(candidates) ~= "table" then
            changed = true
        else
            local target = {}
            for candidate, value in pairs(candidates) do
                local record, record_changed = normalizeRecord(value)
                if validAssociationText(candidate) and record then
                    if record.count > MAX_ASSOCIATION_FREQUENCY then
                        record_changed = true
                    end
                    record.count = math.min(record.count, MAX_ASSOCIATION_FREQUENCY)
                    if record_changed or target[candidate] then
                        changed = true
                    end
                    local previous = target[candidate]
                    if previous then
                        previous.count = math.min(
                            previous.count + record.count, MAX_ASSOCIATION_FREQUENCY)
                        previous.last_used = math.max(previous.last_used, record.last_used)
                    else
                        target[candidate] = record
                    end
                    if record.last_used > sequence then
                        sequence = record.last_used
                        changed = true
                    end
                else
                    changed = true
                end
            end
            if next(target) then
                normalized[context] = target
            elseif next(candidates) then
                changed = true
            end
        end
    end

    -- Rank after the final sequence has been recovered from every record, so
    -- an old high raw count cannot crowd out a fresher candidate at load time.
    -- Persisted data may contain arbitrarily many provisional rows; repair it
    -- to the same three-established-plus-one-provisional runtime invariant.
    for _, candidates in pairs(normalized) do
        if trimAssociationCandidates(candidates, sequence) then
            changed = true
        end
    end

    local contexts = associationContextRows(normalized, sequence)
    if #contexts > MAX_ASSOCIATION_CONTEXTS then
        changed = true
        for index = MAX_ASSOCIATION_CONTEXTS + 1, #contexts do
            normalized[contexts[index].context] = nil
        end
    end
    return changed and normalized or stored, sequence, changed
end

local function normalizeLearning(user_frequency, stored_sequence)
    if type(user_frequency) ~= "table" then
        return {}, 0, true
    end
    local normalized = {}
    local changed = false
    local sequence = tonumber(stored_sequence) or 0
    if sequence ~= sequence or sequence == math.huge or sequence == -math.huge then
        sequence = 0
    end
    sequence = math.max(0, math.min(math.floor(sequence), MAX_SEQUENCE))
    if sequence ~= stored_sequence then
        changed = true
    end
    for code, candidates in pairs(user_frequency) do
        if type(code) ~= "string" or type(candidates) ~= "table" then
            changed = true
        else
            local normalized_code = code
            if #normalized_code < 1 or #normalized_code > MAX_CODE_LENGTH
                    or not normalized_code:match("^[a-z]+$") then
                changed = true
            else
                local target = normalized[normalized_code]
                if not target then
                    target = {}
                    normalized[normalized_code] = target
                else
                    changed = true
                end
                for candidate, value in pairs(candidates) do
                    local record, record_changed = normalizeRecord(value)
                    if validCandidate(candidate) and record then
                        if record_changed or target[candidate] then
                            changed = true
                        end
                        local previous = target[candidate]
                        if previous then
                            previous.count = math.min(previous.count + record.count, MAX_FREQUENCY)
                            previous.last_used = math.max(previous.last_used, record.last_used)
                        else
                            target[candidate] = record
                        end
                        if record.last_used > sequence then
                            sequence = record.last_used
                            changed = true
                        end
                    else
                        changed = true
                    end
                end
            end
        end
    end

    local code_rows = {}
    for code, candidates in pairs(normalized) do
        local rows = candidateRows(candidates)
        if #rows > MAX_CANDIDATES_PER_CODE then
            changed = true
            for index = MAX_CANDIDATES_PER_CODE + 1, #rows do
                candidates[rows[index].candidate] = nil
            end
        end
        if next(candidates) then
            local total, last_used = 0, 0
            for _, record in pairs(candidates) do
                total = total + record.count
                last_used = math.max(last_used, record.last_used)
            end
            code_rows[#code_rows + 1] = {
                code = code,
                frequency = total,
                last_used = last_used,
            }
        else
            normalized[code] = nil
            changed = true
        end
    end
    if #code_rows > MAX_CODES then
        changed = true
        table.sort(code_rows, function(left, right)
            if left.frequency == right.frequency and left.last_used == right.last_used then
                return left.code < right.code
            elseif left.frequency == right.frequency then
                return left.last_used > right.last_used
            end
            return left.frequency > right.frequency
        end)
        for index = MAX_CODES + 1, #code_rows do
            normalized[code_rows[index].code] = nil
        end
    end
    return changed and normalized or user_frequency, sequence, changed
end

function Settings:new()
    local settings_file = DataStorage:getSettingsDir() .. "/chinesepinyin.lua"
    local store = LuaSettings:open(settings_file)
    local user_frequency, learning_sequence, learning_changed = normalizeLearning(
        store:readSetting("user_frequency", {}),
        store:readSetting("learning_sequence", 0))
    local user_associations, association_sequence, associations_changed =
        normalizeAssociations(
            store:readSetting("user_associations", {}),
            store:readSetting("association_sequence", 0))
    local input_scheme = InputSchemes.normalize(store:readSetting("input_scheme", "full"))
    local last_shuangpin_scheme = InputSchemes.normalizeShuangpin(
        store:readSetting("last_shuangpin_scheme", "flypy"))
    local lexicon_mode = store:readSetting("lexicon_mode", "auto")
    if lexicon_mode ~= "compatibility" then
        lexicon_mode = "auto"
    end
    local personalization_enabled = enabledByDefault(
        store:readSetting("personalization_enabled", true))
    local prediction_enabled = enabledByDefault(
        store:readSetting("prediction_enabled", true))
    local instance = {
        settings_file = settings_file,
        store = store,
        user_frequency = user_frequency,
        learning_sequence = learning_sequence,
        user_associations = user_associations,
        association_sequence = association_sequence,
        association_context_count = #associationContextRows(
            user_associations, association_sequence),
        input_scheme = input_scheme,
        last_shuangpin_scheme = last_shuangpin_scheme,
        lexicon_mode = lexicon_mode,
        personalization_enabled = personalization_enabled,
        prediction_enabled = prediction_enabled,
        learning_dirty = false,
        learning_generation = 0,
        learning_flush_action = nil,
    }
    setmetatable(instance, self)
    self.__index = self
    if learning_changed or associations_changed then
        store:saveSetting("user_frequency", user_frequency)
            :saveSetting("learning_sequence", learning_sequence)
            :saveSetting("user_associations", user_associations)
            :saveSetting("association_sequence", association_sequence)
            :flush()
    end
    return instance
end

function Settings:_learningWriter()
    if self.learning_writer then
        return self.learning_writer
    end
    LearningWriter = LearningWriter
        or dofile(plugin_root .. "/lib/learning_writer.lua")
    local writer
    writer = LearningWriter:new{
        path = self.settings_file,
        data = self.store.data,
        on_settled = function(success, settled)
            if success and settled
                    and writer.persisted_generation >= self.learning_generation
                    and not self.learning_flush_action then
                self.learning_dirty = false
            end
        end,
    }
    self.learning_writer = writer
    return writer
end

function Settings:_syncLearningStore()
    self.store:saveSetting("user_frequency", self.user_frequency)
        :saveSetting("learning_sequence", self.learning_sequence)
        :saveSetting("user_associations", self.user_associations)
        :saveSetting("association_sequence", self.association_sequence)
end

function Settings:_drainLearningWriter()
    if self.learning_dirty
            or self.learning_writer and self.learning_writer:isInFlight() then
        return self:flush()
    end
    return false
end

function Settings:_scheduleLearningFlush()
    self.learning_dirty = true
    self.learning_generation = self.learning_generation + 1
    if self.learning_flush_action then
        return
    end
    self.learning_flush_action = function()
        self.learning_flush_action = nil
        local writer = self:_learningWriter()
        writer:markDirty(self.learning_generation)
        self:_syncLearningStore()
        writer:startAsync()
    end
    UIManager:scheduleIn(LEARNING_FLUSH_DELAY, self.learning_flush_action)
end

function Settings:flush()
    if self.learning_flush_action then
        UIManager:unschedule(self.learning_flush_action)
        self.learning_flush_action = nil
    end
    local had_pending = self.learning_dirty
        or self.learning_writer and self.learning_writer:isInFlight()
    if not had_pending then
        return false
    end
    local writer = self:_learningWriter()
    writer:markDirty(self.learning_generation)
    self:_syncLearningStore()
    local ok = writer:flushSync()
    if ok then
        self.learning_dirty = false
    end
    return ok == true
end

function Settings:learn(code, candidate)
    if type(code) ~= "string" or code == "" or #code > MAX_CODE_LENGTH
            or not code:match("^[a-z]+$") or not validCandidate(candidate) then
        return false
    end
    local candidates = self.user_frequency[code]
    local new_code = candidates == nil
    if not candidates then
        candidates = {}
        self.user_frequency[code] = candidates
    end
    if self.learning_sequence >= MAX_SEQUENCE then
        for _, learned_candidates in pairs(self.user_frequency) do
            for _, record in pairs(learned_candidates) do
                record.last_used = math.floor(record.last_used / 2)
            end
        end
        self.learning_sequence = math.floor(self.learning_sequence / 2)
    end
    self.learning_sequence = self.learning_sequence + 1
    local record = candidates[candidate]
    if not record then
        record = { count = 0, last_used = 0 }
        candidates[candidate] = record
    end
    record.count = math.min(record.count + 1, MAX_FREQUENCY)
    record.last_used = self.learning_sequence
    local rows = candidateRows(candidates)
    if #rows > MAX_CANDIDATES_PER_CODE then
        candidates[rows[#rows].candidate] = nil
    end
    if new_code then
        local code_count = 0
        for _ in pairs(self.user_frequency) do
            code_count = code_count + 1
        end
        if code_count > MAX_CODES then
            local lowest_code, lowest_frequency, lowest_last_used
            for learned_code, learned_candidates in pairs(self.user_frequency) do
                local total, last_used = 0, 0
                for _, learned_record in pairs(learned_candidates) do
                    total = total + learned_record.count
                    last_used = math.max(last_used, learned_record.last_used)
                end
                if not lowest_frequency or total < lowest_frequency
                        or total == lowest_frequency and last_used < lowest_last_used
                        or total == lowest_frequency and last_used == lowest_last_used
                            and learned_code > lowest_code then
                    lowest_code = learned_code
                    lowest_frequency = total
                    lowest_last_used = last_used
                end
            end
            self.user_frequency[lowest_code] = nil
        end
    end
    self:_scheduleLearningFlush()
    return true
end

function Settings:getLearningSequence()
    return self.learning_sequence
end

function Settings:learnAssociation(previous_text, next_text)
    local context_keys = associationContextKeys(previous_text)
    if #context_keys == 0 or not validAssociationText(next_text) then
        return false
    end
    if self.association_sequence >= MAX_SEQUENCE then
        for _, learned_candidates in pairs(self.user_associations) do
            for _, record in pairs(learned_candidates) do
                record.last_used = math.floor(record.last_used / 2)
            end
        end
        self.association_sequence = math.floor(self.association_sequence / 2)
    end
    self.association_sequence = self.association_sequence + 1

    for _, context in ipairs(context_keys) do
        local candidates = self.user_associations[context]
        local new_context = candidates == nil
        if not candidates then
            candidates = {}
            self.user_associations[context] = candidates
        end
        local record = candidates[next_text]
        local was_provisional = record ~= nil
            and record.count < MIN_ASSOCIATION_FREQUENCY
        if not record then
            record = { count = 0, last_used = 0 }
            candidates[next_text] = record
        end
        -- Materialize age before incrementing. Otherwise a record which once
        -- reached the cap could become fully trusted again after one very late
        -- observation even though it has been inactive for a long time.
        record.count = math.min(
            associationEffectiveCount(record, self.association_sequence) + 1,
            MAX_ASSOCIATION_FREQUENCY)
        record.last_used = self.association_sequence
        local promoted_candidate = was_provisional
            and record.count >= MIN_ASSOCIATION_FREQUENCY
            and next_text or nil
        trimAssociationCandidates(
            candidates, self.association_sequence, promoted_candidate)

        if new_context then
            self.association_context_count = self.association_context_count + 1
            if self.association_context_count > MAX_ASSOCIATION_CONTEXTS then
                evictLowestAssociationContext(
                    self.user_associations, self.association_sequence)
                self.association_context_count = self.association_context_count - 1
            end
        end
    end
    self:_scheduleLearningFlush()
    return true
end

-- Return every active caller-ordered context with ranking metadata. Runtime
-- fusion can therefore compare specificity before comparing source strength.
-- The legacy string-only waterfall below remains available to other callers.
function Settings:getAssociationCandidatesByContext(context_keys, limit)
    if type(context_keys) ~= "table" then
        return {}
    end
    limit = math.max(1, math.min(
        math.floor(tonumber(limit) or MAX_ASSOCIATIONS_PER_CONTEXT),
        MAX_ASSOCIATIONS_PER_CONTEXT))
    local groups = {}
    local seen_context = {}
    for context_index, context in ipairs(context_keys) do
        if validAssociationText(context) and not seen_context[context] then
            seen_context[context] = true
            local candidates = self.user_associations[context]
            if candidates then
                local ranked = associationCandidateRows(
                    candidates, self.association_sequence)
                local rows = {}
                for _, row in ipairs(ranked) do
                    if row.effective_count >= MIN_ASSOCIATION_FREQUENCY then
                        rows[#rows + 1] = {
                            text = row.candidate,
                            rank = #rows + 1,
                            count = row.count,
                            effective_count = row.effective_count,
                            last_used = row.last_used,
                        }
                        if #rows >= limit then
                            break
                        end
                    end
                end
                if #rows > 0 then
                    groups[#groups + 1] = {
                        context = context,
                        context_index = context_index,
                        candidates = rows,
                    }
                end
            end
        end
    end
    return groups
end

function Settings:getAssociationCandidates(context_keys, limit)
    local groups = self:getAssociationCandidatesByContext(context_keys, limit)
    local group = groups[1]
    if not group then
        return {}
    end
    local result = {}
    for _, row in ipairs(group.candidates) do
        result[#result + 1] = row.text
    end
    return result
end

function Settings:hasLearning()
    return next(self.user_frequency) ~= nil or next(self.user_associations) ~= nil
end

function Settings:clearLearning()
    if self.learning_flush_action then
        UIManager:unschedule(self.learning_flush_action)
        self.learning_flush_action = nil
    end
    for code in pairs(self.user_frequency) do
        self.user_frequency[code] = nil
    end
    for context in pairs(self.user_associations) do
        self.user_associations[context] = nil
    end
    self.learning_sequence = 0
    self.association_sequence = 0
    self.association_context_count = 0
    self.learning_dirty = true
    self.learning_generation = self.learning_generation + 1
    local writer = self:_learningWriter()
    writer:markDirty(self.learning_generation)
    self:_syncLearningStore()
    if writer:flushSync() then
        self.learning_dirty = false
    end
end

function Settings:getInputScheme()
    return self.input_scheme
end

function Settings:setInputScheme(scheme)
    scheme = InputSchemes.normalize(scheme)
    if self.input_scheme == scheme then
        return false
    end
    self:_drainLearningWriter()
    self.input_scheme = scheme
    if InputSchemes.isShuangpin(scheme) then
        self.last_shuangpin_scheme = scheme
    end
    self.store:saveSetting("input_scheme", scheme)
        :saveSetting("last_shuangpin_scheme", self.last_shuangpin_scheme)
        :flush()
    return true
end

function Settings:getLexiconMode()
    return self.lexicon_mode
end

function Settings:setLexiconMode(mode)
    mode = mode == "compatibility" and "compatibility" or "auto"
    if self.lexicon_mode == mode then
        return false
    end
    self:_drainLearningWriter()
    self.lexicon_mode = mode
    self.store:saveSetting("lexicon_mode", mode):flush()
    return true
end

function Settings:isPersonalizationEnabled()
    return self.personalization_enabled
end

function Settings:setPersonalizationEnabled(enabled)
    enabled = enabled ~= false
    if self.personalization_enabled == enabled then
        return false
    end
    self:_drainLearningWriter()
    self.personalization_enabled = enabled
    self.store:saveSetting("personalization_enabled", enabled):flush()
    return true
end

function Settings:isPredictionEnabled()
    return self.prediction_enabled
end

function Settings:setPredictionEnabled(enabled)
    enabled = enabled ~= false
    if self.prediction_enabled == enabled then
        return false
    end
    self:_drainLearningWriter()
    self.prediction_enabled = enabled
    self.store:saveSetting("prediction_enabled", enabled):flush()
    return true
end

function Settings:getLearningWriterStats()
    return self:_learningWriter():getStats()
end

return Settings
