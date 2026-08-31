-- ITER-002J representation-only S+B+T scorer. It is not production-integrated.

local bit = require("bit")
local ffi = require("ffi")
require("ffi/posix_h")

local band = bit.band
local C = ffi.C

local DenseSBTReranker = {}
local Model = {}
Model.__index = Model

local MAGIC_V1 = "PYSBTF1\0"
local MAGIC_V2 = "PYSBTF2\0"
local RANGE_MAGIC = "PYSBTR1\0"
local HEADER_SIZE = 84
local SYLLABLE_WIDTH = 7
local T_SLOT_SIZE = 8
local RANGE_TRAILER_SIZE = 28
local RANGE_SLOT_SIZE = 8
local MINIMUM_RAW_SCORE_SPAN = 288
local MAX_FILE_SIZE = 4 * 1024 * 1024
local EXPECTED_PROTECTED = { [30340] = true, [22320] = true, [24471] = true }

local function u16(pointer, position)
    return pointer[position] + pointer[position + 1] * 256
end

local function u32(pointer, position)
    return pointer[position] + pointer[position + 1] * 256
        + pointer[position + 2] * 65536
        + pointer[position + 3] * 16777216
end

local function signedByte(pointer, position)
    local value = pointer[position]
    return value >= 128 and value - 256 or value
end

local function trigramHash(first, second, third)
    return first * 73856093 + second * 19349663 + third * 83492791
end

local function adler32(pointer, first, last)
    local lower, upper = 1, 0
    for position = first, last - 1 do
        lower = lower + pointer[position]
        upper = upper + lower
        if (position - first + 1) % 5552 == 0 then
            lower = lower % 65521
            upper = upper % 65521
        end
    end
    lower = lower % 65521
    upper = upper % 65521
    return upper * 65536 + lower
end

local function readFile(path)
    if type(path) ~= "string" or path == "" then
        error("dense SBT path is required")
    end
    local fd = C.open(path, C.O_RDONLY)
    if fd < 0 then error("unable to open dense SBT artifact") end
    local size = tonumber(C.lseek(fd, 0, C.SEEK_END))
    if not size or size < HEADER_SIZE or size > MAX_FILE_SIZE
            or tonumber(C.lseek(fd, 0, C.SEEK_SET)) ~= 0 then
        C.close(fd)
        error("invalid dense SBT artifact size")
    end
    local raw = C.malloc(size)
    if raw == nil then
        C.close(fd)
        error("unable to allocate dense SBT buffer")
    end
    local pointer = ffi.cast("uint8_t*", raw)
    local consumed = 0
    while consumed < size do
        local count = tonumber(C.read(fd, pointer + consumed, size - consumed))
        if not count or count <= 0 then
            C.close(fd)
            C.free(raw)
            error("unable to read dense SBT artifact")
        end
        consumed = consumed + count
    end
    C.close(fd)
    return ffi.gc(pointer, C.free), size
end

local function validRange(offset, length, size)
    return offset >= HEADER_SIZE and length >= 0
        and offset <= size and length <= size - offset
end

local function loadModel(path, options)
    options = type(options) == "table" and options or {}
    local pointer, size = readFile(path)
    local magic = ffi.string(pointer, 8)
    local expected_version = magic == MAGIC_V1 and 1
        or magic == MAGIC_V2 and 2 or nil
    if not expected_version then error("invalid dense SBT magic") end
    local model = setmetatable({ pointer = pointer, external_bytes = size }, Model)
    model.version = u32(pointer, 8)
    local header_size = u32(pointer, 12)
    local declared_size = u32(pointer, 16)
    local expected_adler = u32(pointer, 20)
    model.syllable_count = u32(pointer, 24)
    model.character_count = u32(pointer, 28)
    model.pair_count = u32(pointer, 32)
    model.s_count = u32(pointer, 36)
    model.b_count = u32(pointer, 40)
    model.t_count = u32(pointer, 44)
    model.t_capacity = u32(pointer, 48)
    model.syllable_offset = u32(pointer, 52)
    model.character_map_offset = u32(pointer, 56)
    model.pair_matrix_offset = u32(pointer, 60)
    model.s_offset = u32(pointer, 64)
    model.b_offset = u32(pointer, 68)
    model.t_offset = u32(pointer, 72)
    model.protected_offset = u32(pointer, 76)
    model.protected_count = u32(pointer, 80)
    if model.version ~= expected_version or header_size ~= HEADER_SIZE
            or declared_size ~= size or model.syllable_count < 1
            or model.syllable_count >= 65535 or model.character_count < 1
            or model.character_count >= 65535 or model.pair_count < 1
            or model.pair_count >= 65535 or model.t_capacity < 1
            or band(model.t_capacity, model.t_capacity - 1) ~= 0
            or model.t_count > model.t_capacity
            or model.protected_count > 16 then
        error("invalid dense SBT header")
    end
    if options.expected_size and size ~= options.expected_size then
        error("dense SBT expected size mismatch")
    elseif options.expected_adler32
            and expected_adler ~= options.expected_adler32 then
        error("dense SBT expected checksum mismatch")
    end
    model.character_dimension = model.character_count + 1
    model.pair_dimension = model.pair_count + 1
    local syllable_bytes = model.syllable_count * SYLLABLE_WIDTH
    local pair_matrix_bytes = (model.syllable_count + 1)
        * model.character_dimension * 2
    local b_bytes = model.pair_dimension * model.pair_dimension
    local protected_end = model.protected_offset + model.protected_count * 4
    if not validRange(model.syllable_offset, syllable_bytes, size)
            or not validRange(model.character_map_offset, 65536 * 2, size)
            or not validRange(model.pair_matrix_offset, pair_matrix_bytes, size)
            or not validRange(model.s_offset, model.pair_dimension, size)
            or not validRange(model.b_offset, b_bytes, size)
            or not validRange(model.t_offset,
                model.t_capacity * T_SLOT_SIZE, size)
            or not validRange(model.protected_offset,
                model.protected_count * 4, size)
            or model.syllable_offset + syllable_bytes > model.character_map_offset
            or model.character_map_offset + 65536 * 2 > model.pair_matrix_offset
            or model.pair_matrix_offset + pair_matrix_bytes > model.s_offset
            or model.s_offset + model.pair_dimension > model.b_offset
            or model.b_offset + b_bytes > model.t_offset
            or model.t_offset + model.t_capacity * T_SLOT_SIZE
                > model.protected_offset
            or protected_end > size
            or model.version == 1 and protected_end ~= size then
        error("invalid dense SBT section bounds")
    end
    if model.version == 2 then
        if protected_end + RANGE_TRAILER_SIZE > size
                or ffi.string(pointer + protected_end, 8) ~= RANGE_MAGIC then
            error("invalid dense SBT range trailer")
        end
        model.s_range_offset = u32(pointer, protected_end + 8)
        model.b_range_offset = u32(pointer, protected_end + 12)
        model.t_range_offset = u32(pointer, protected_end + 16)
        model.t_range_count = u32(pointer, protected_end + 20)
        model.t_range_capacity = u32(pointer, protected_end + 24)
        local s_range_bytes = (model.syllable_count + 1) * 2
        local b_range_bytes = (model.syllable_count + 1)
            * (model.syllable_count + 1) * 2
        if model.t_range_capacity < 1
                or band(model.t_range_capacity,
                    model.t_range_capacity - 1) ~= 0
                or model.t_range_count > model.t_range_capacity
                or not validRange(model.s_range_offset, s_range_bytes, size)
                or not validRange(model.b_range_offset, b_range_bytes, size)
                or not validRange(model.t_range_offset,
                    model.t_range_capacity * RANGE_SLOT_SIZE, size)
                or protected_end + RANGE_TRAILER_SIZE > model.s_range_offset
                or model.s_range_offset + s_range_bytes > model.b_range_offset
                or model.b_range_offset + b_range_bytes > model.t_range_offset
                or model.t_range_offset
                    + model.t_range_capacity * RANGE_SLOT_SIZE ~= size then
            error("invalid dense SBT range section bounds")
        end
    end
    if adler32(pointer, HEADER_SIZE, size) ~= expected_adler then
        error("dense SBT payload checksum mismatch")
    end
    model.syllable_ids = {}
    for index = 0, model.syllable_count - 1 do
        local value = ffi.string(
            pointer + model.syllable_offset + index * SYLLABLE_WIDTH,
            SYLLABLE_WIDTH):match("^[^%z]*")
        if not value or value == "" or model.syllable_ids[value] then
            error("invalid dense SBT syllable table")
        end
        model.syllable_ids[value] = index + 1
    end
    local seen_characters = ffi.new("uint8_t[?]", model.character_count + 1)
    local observed_characters = 0
    for codepoint = 0, 65535 do
        local identifier = u16(pointer,
            model.character_map_offset + codepoint * 2)
        if identifier > model.character_count
                or identifier ~= 0 and seen_characters[identifier] ~= 0 then
            error("invalid dense SBT character identifier")
        elseif identifier ~= 0 then
            seen_characters[identifier] = 1
            observed_characters = observed_characters + 1
        end
    end
    if observed_characters ~= model.character_count then
        error("dense SBT character count mismatch")
    end
    local seen_pairs = ffi.new("uint8_t[?]", model.pair_count + 1)
    local observed_pairs = 0
    for syllable = 0, model.syllable_count do
        for character = 0, model.character_count do
            local identifier = u16(pointer, model.pair_matrix_offset
                + (syllable * model.character_dimension + character) * 2)
            if identifier > model.pair_count
                    or identifier ~= 0 and seen_pairs[identifier] ~= 0
                    or (syllable == 0 or character == 0) and identifier ~= 0 then
                error("invalid dense SBT pair identifier")
            elseif identifier ~= 0 then
                seen_pairs[identifier] = 1
                observed_pairs = observed_pairs + 1
            end
        end
    end
    if observed_pairs ~= model.pair_count then
        error("dense SBT pair count mismatch")
    end
    local observed_s = 0
    for identifier = 1, model.pair_count do
        if signedByte(pointer, model.s_offset + identifier) ~= 0 then
            observed_s = observed_s + 1
        end
    end
    if signedByte(pointer, model.s_offset) ~= 0 or observed_s ~= model.s_count then
        error("dense SBT unigram count mismatch")
    end
    local observed_b = 0
    for index = 0, model.pair_dimension * model.pair_dimension - 1 do
        local value = signedByte(pointer, model.b_offset + index)
        if value ~= 0 then
            if index < model.pair_dimension
                    or index % model.pair_dimension == 0 then
                error("invalid dense SBT bigram sentinel")
            end
            observed_b = observed_b + 1
        end
    end
    if observed_b ~= model.b_count then
        error("dense SBT bigram count mismatch")
    end
    model.protected = {}
    for index = 0, model.protected_count - 1 do
        local codepoint = u32(pointer, model.protected_offset + index * 4)
        if not EXPECTED_PROTECTED[codepoint] or model.protected[codepoint] then
            error("invalid dense SBT protected character")
        end
        model.protected[codepoint] = true
    end
    if model.protected_count ~= 3 then
        error("dense SBT protected character count mismatch")
    end
    local observed_trigrams = 0
    for slot = 0, model.t_capacity - 1 do
        local position = model.t_offset + slot * T_SLOT_SIZE
        local first = u16(pointer, position)
        if first ~= 0 then
            local second, third = u16(pointer, position + 2), u16(pointer, position + 4)
            if first > model.pair_count or second < 1
                    or second > model.pair_count or third < 1
                    or third > model.pair_count
                    or signedByte(pointer, position + 6) == 0
                    or pointer[position + 7] ~= 0 then
                error("invalid dense SBT trigram slot")
            end
            local home = band(trigramHash(first, second, third),
                model.t_capacity - 1)
            local probe = home
            while probe ~= slot do
                local previous = model.t_offset + probe * T_SLOT_SIZE
                local previous_first = u16(pointer, previous)
                if previous_first == 0 then
                    error("invalid dense SBT trigram probe chain")
                elseif previous_first == first
                        and u16(pointer, previous + 2) == second
                        and u16(pointer, previous + 4) == third then
                    error("duplicate dense SBT trigram key")
                end
                probe = band(probe + 1, model.t_capacity - 1)
                if probe == home then
                    error("invalid dense SBT saturated trigram table")
                end
            end
            observed_trigrams = observed_trigrams + 1
        end
    end
    if observed_trigrams ~= model.t_count then
        error("dense SBT trigram count mismatch")
    end
    if model.version == 2 then
        for identifier = 0, model.syllable_count do
            local position = model.s_range_offset + identifier * 2
            local lower = signedByte(pointer, position)
            local upper = signedByte(pointer, position + 1)
            if lower > 0 or upper < 0 or lower > upper
                    or identifier == 0 and (lower ~= 0 or upper ~= 0) then
                error("invalid dense SBT syllable range")
            end
        end
        local range_dimension = model.syllable_count + 1
        for index = 0, range_dimension * range_dimension - 1 do
            local position = model.b_range_offset + index * 2
            local lower = signedByte(pointer, position)
            local upper = signedByte(pointer, position + 1)
            if lower > 0 or upper < 0 or lower > upper
                    or (index < range_dimension
                        or index % range_dimension == 0)
                        and (lower ~= 0 or upper ~= 0) then
                error("invalid dense SBT bigram range")
            end
        end
        local observed_ranges = 0
        for slot = 0, model.t_range_capacity - 1 do
            local position = model.t_range_offset + slot * RANGE_SLOT_SIZE
            local first = u16(pointer, position)
            local second = u16(pointer, position + 2)
            local third = u16(pointer, position + 4)
            local lower = signedByte(pointer, position + 6)
            local upper = signedByte(pointer, position + 7)
            if first == 0 then
                if second ~= 0 or third ~= 0 or lower ~= 0 or upper ~= 0 then
                    error("invalid empty dense SBT trigram range")
                end
            else
                if first > model.syllable_count or second < 1
                        or second > model.syllable_count or third < 1
                        or third > model.syllable_count or lower > 0
                        or upper < 0 or lower > upper
                        or lower == 0 and upper == 0 then
                    error("invalid dense SBT trigram range")
                end
                local home = band(trigramHash(first, second, third),
                    model.t_range_capacity - 1)
                local probe = home
                while probe ~= slot do
                    local previous = model.t_range_offset
                        + probe * RANGE_SLOT_SIZE
                    local previous_first = u16(pointer, previous)
                    if previous_first == 0 then
                        error("invalid dense SBT trigram range probe chain")
                    elseif previous_first == first
                            and u16(pointer, previous + 2) == second
                            and u16(pointer, previous + 4) == third then
                        error("duplicate dense SBT trigram range key")
                    end
                    probe = band(probe + 1, model.t_range_capacity - 1)
                    if probe == home then
                        error("invalid saturated dense SBT trigram range table")
                    end
                end
                observed_ranges = observed_ranges + 1
            end
        end
        if observed_ranges ~= model.t_range_count then
            error("dense SBT trigram range count mismatch")
        end
    end
    model.ids, model.pairs = {}, {}
    return model
end

function Model:_trigramWeight(first, second, third)
    if first == 0 or second == 0 or third == 0 then return 0 end
    local slot = band(trigramHash(first, second, third), self.t_capacity - 1)
    while true do
        local position = self.t_offset + slot * T_SLOT_SIZE
        local observed_first = u16(self.pointer, position)
        if observed_first == 0 then return 0 end
        if observed_first == first
                and u16(self.pointer, position + 2) == second
                and u16(self.pointer, position + 4) == third then
            return signedByte(self.pointer, position + 6)
        end
        slot = band(slot + 1, self.t_capacity - 1)
    end
end

function Model:_prepareSyllables(canonical_pinyin)
    local count = 0
    for syllable in tostring(canonical_pinyin or ""):gmatch("[^']+") do
        count = count + 1
        self.ids[count] = self.syllable_ids[syllable] or 0
    end
    return count
end

function Model:_prepareSyllableList(syllables)
    if type(syllables) ~= "table" then return 0 end
    local count = #syllables
    for index = 1, count do
        self.ids[index] = self.syllable_ids[syllables[index]] or 0
    end
    return count
end

function Model:_trigramRange(first, second, third)
    if first == 0 or second == 0 or third == 0 then return 0, 0 end
    local slot = band(trigramHash(first, second, third),
        self.t_range_capacity - 1)
    while true do
        local position = self.t_range_offset + slot * RANGE_SLOT_SIZE
        local observed_first = u16(self.pointer, position)
        if observed_first == 0 then return 0, 0 end
        if observed_first == first
                and u16(self.pointer, position + 2) == second
                and u16(self.pointer, position + 4) == third then
            return signedByte(self.pointer, position + 6),
                signedByte(self.pointer, position + 7)
        end
        slot = band(slot + 1, self.t_range_capacity - 1)
    end
end

function Model:_rangeBoundPrepared(count)
    if self.version < 2 then return math.huge end
    local pointer, bound = self.pointer, 0
    for index = 1, count do
        local position = self.s_range_offset + self.ids[index] * 2
        bound = bound + signedByte(pointer, position + 1)
            - signedByte(pointer, position)
    end
    local dimension = self.syllable_count + 1
    for index = 1, count - 1 do
        local position = self.b_range_offset
            + (self.ids[index] * dimension + self.ids[index + 1]) * 2
        bound = bound + signedByte(pointer, position + 1)
            - signedByte(pointer, position)
    end
    for index = 1, count - 2 do
        local lower, upper = self:_trigramRange(
            self.ids[index], self.ids[index + 1], self.ids[index + 2])
        bound = bound + upper - lower
    end
    return bound
end

function Model:rangeBoundSyllables(syllables)
    if not self.pointer then return 0 end
    return self:_rangeBoundPrepared(self:_prepareSyllableList(syllables))
end

function Model:couldRerankSyllables(syllables)
    return self:rangeBoundSyllables(syllables) >= MINIMUM_RAW_SCORE_SPAN
end

local function codepoint3(text, position)
    local first, second, third = text:byte(position, position + 2)
    if not third or first < 224 or first > 239
            or second < 128 or second > 191
            or third < 128 or third > 191 then
        return nil
    end
    return (first - 224) * 4096 + (second - 128) * 64 + third - 128
end

function Model:_candidateScorePrepared(count, candidate)
    if not self.pointer or count == 0 or #candidate ~= count * 3 then return 0 end
    local pointer = self.pointer
    for index = 1, count do
        local codepoint = codepoint3(candidate, (index - 1) * 3 + 1)
        if not codepoint then return 0 end
        local character_id = u16(pointer,
            self.character_map_offset + codepoint * 2)
        local syllable_id = self.ids[index]
        self.pairs[index] = syllable_id ~= 0 and character_id ~= 0
            and u16(pointer, self.pair_matrix_offset
                + (syllable_id * self.character_dimension + character_id) * 2)
            or 0
    end
    local score = 0
    for index = 1, count do
        local pair = self.pairs[index]
        if pair ~= 0 then
            local duplicate = false
            for previous = 1, index - 1 do
                if self.pairs[previous] == pair then duplicate = true break end
            end
            if not duplicate then
                score = score + signedByte(pointer, self.s_offset + pair)
            end
        end
    end
    for index = 1, count - 1 do
        local first, second = self.pairs[index], self.pairs[index + 1]
        if first ~= 0 and second ~= 0 then
            local duplicate = false
            for previous = 1, index - 1 do
                if self.pairs[previous] == first
                        and self.pairs[previous + 1] == second then
                    duplicate = true break
                end
            end
            if not duplicate then
                score = score + signedByte(pointer, self.b_offset
                    + first * self.pair_dimension + second)
            end
        end
    end
    for index = 1, count - 2 do
        local first, second, third = self.pairs[index], self.pairs[index + 1],
            self.pairs[index + 2]
        if first ~= 0 and second ~= 0 and third ~= 0 then
            local duplicate = false
            for previous = 1, index - 1 do
                if self.pairs[previous] == first
                        and self.pairs[previous + 1] == second
                        and self.pairs[previous + 2] == third then
                    duplicate = true break
                end
            end
            if not duplicate then
                score = score + self:_trigramWeight(first, second, third)
            end
        end
    end
    return score
end

function Model:candidateScore(canonical_pinyin, candidate)
    return self:_candidateScorePrepared(
        self:_prepareSyllables(canonical_pinyin), tostring(candidate or ""))
end

function Model:winnerIndexSyllables(syllables, candidates, limit)
    if not self.pointer or type(candidates) ~= "table" or #candidates < 2 then
        return 1
    end
    local count = self:_prepareSyllableList(syllables)
    local maximum = math.min(#candidates, tonumber(limit) or 5)
    if count == 0 or maximum < 2 then return 1 end
    local baseline_score = self:_candidateScorePrepared(count, candidates[1])
    local winner, winner_score = 1, baseline_score
    for index = 2, maximum do
        local score = self:_candidateScorePrepared(count, candidates[index])
            - 128 * (index - 1)
        if score > winner_score then
            winner, winner_score = index, score
        end
    end
    if winner == 1 or winner_score - baseline_score < 160
            or self:_changesProtected(candidates[1], candidates[winner]) then
        return 1
    end
    return winner
end

function Model:_changesProtected(left, right)
    local count = math.max(#left, #right) / 3
    for index = 1, count do
        local position = (index - 1) * 3 + 1
        local left_code = codepoint3(left, position) or 0
        local right_code = codepoint3(right, position) or 0
        if left_code ~= right_code
                and (self.protected[left_code] or self.protected[right_code]) then
            return true
        end
    end
    return false
end

function Model:rerank(canonical_pinyin, candidates)
    if not self.pointer or type(candidates) ~= "table" or #candidates < 2 then
        return candidates
    end
    local count = self:_prepareSyllables(canonical_pinyin)
    local ranked = {}
    for index, candidate in ipairs(candidates) do
        ranked[index] = {
            candidate = candidate,
            index = index,
            score = self:_candidateScorePrepared(count, candidate)
                - 128 * (index - 1),
        }
    end
    table.sort(ranked, function(left, right)
        return left.score > right.score
            or left.score == right.score and left.index < right.index
    end)
    local winner = ranked[1]
    if winner.index == 1 then
        return candidates
    end
    local baseline_score
    for _, row in ipairs(ranked) do
        if row.index == 1 then baseline_score = row.score break end
    end
    if winner.score - baseline_score < 160
            or self:_changesProtected(candidates[1], winner.candidate) then
        return candidates
    end
    local result = { winner.candidate }
    for _, candidate in ipairs(candidates) do
        if candidate ~= winner.candidate then result[#result + 1] = candidate end
    end
    return result
end

function Model:getStats()
    return {
        external_bytes = self.external_bytes,
        syllables = self.syllable_count,
        characters = self.character_count,
        pairs = self.pair_count,
        s_features = self.s_count,
        b_features = self.b_count,
        t_features = self.t_count,
        capability_ranges = self.version >= 2,
        capability_trigram_ranges = self.t_range_count or 0,
    }
end

function Model:close()
    if self.pointer then
        local pointer = ffi.gc(self.pointer, nil)
        C.free(pointer)
        self.pointer = nil
    end
end

function DenseSBTReranker.load(path, options)
    local ok, model = pcall(loadModel, path, options)
    if ok then return model end
    return nil, tostring(model):gsub("[\r\n]+", " ")
end

return DenseSBTReranker
