-- Specialized read-only ITER-001U bigram reranker.
-- Empty feature families are rejected instead of paying their lookup cost.

local SparseBigramReranker = {}
local ffi = require("ffi")
local bit = require("bit")
local band, bxor, tobit = bit.band, bit.bxor, bit.tobit

local MAGIC = "PYRERK1\0"
local VERSION = 1
local HEADER_SIZE = 66
local SYLLABLE_WIDTH = 7
local BIGRAM_RECORD_SIZE = 11

local function u16(data, position)
    local first, second = data:byte(position, position + 1)
    if not second then error("truncated uint16") end
    return first + second * 256
end

local function u32(data, position)
    local first, second, third, fourth = data:byte(position, position + 3)
    if not fourth then error("truncated uint32") end
    return first + second * 256 + third * 65536 + fourth * 16777216
end

local function adler32(data)
    local first, second = 1, 0
    for index = 1, #data do
        first = first + data:byte(index)
        second = second + first
        if index % 5552 == 0 then
            first = first % 65521
            second = second % 65521
        end
    end
    first, second = first % 65521, second % 65521
    return second * 65536 + first
end

local function pointerU16(pointer, position)
    return pointer[position] + pointer[position + 1] * 256
end

local function pointerKey3(pointer, position)
    return pointer[position] * 65536
        + pointer[position + 1] * 256 + pointer[position + 2]
end

local function signedPointerByte(pointer, position)
    local value = pointer[position]
    return value >= 128 and value - 256 or value
end

local function textKey3(text, position)
    local first, second, third = text:byte(position, position + 2)
    if not third or first < 224 or first > 239
            or second < 128 or second > 191
            or third < 128 or third > 191 then return nil end
    return first * 65536 + second * 256 + third
end

local function splitUtf8(text)
    local result = {}
    for character in tostring(text or ""):gmatch(
            "[%z\1-\127\194-\244][\128-\191]*") do
        result[#result + 1] = character
    end
    return result
end

local FNV_OFFSET = tobit(2166136261)
local FNV_PRIME = 16777619

local function hashByte(hash, value)
    return tobit(bxor(hash, value) * FNV_PRIME)
end

local function hashU16(hash, value)
    hash = hashByte(hash, value % 256)
    return hashByte(hash, math.floor(value / 256))
end

local function hashKey3(hash, value)
    hash = hashByte(hash, math.floor(value / 65536))
    hash = hashByte(hash, math.floor(value / 256) % 256)
    return hashByte(hash, value % 256)
end

local function hashRecord(pointer, position)
    local hash = FNV_OFFSET
    for offset = 0, BIGRAM_RECORD_SIZE - 2 do
        hash = hashByte(hash, pointer[position + offset])
    end
    return hash
end

local function recordsEqual(pointer, left, right)
    for offset = 0, BIGRAM_RECORD_SIZE - 2 do
        if pointer[left + offset] ~= pointer[right + offset] then return false end
    end
    return true
end

local Model = {}
Model.__index = Model

function Model:_syllableId(syllable)
    if type(syllable) ~= "string" or syllable == ""
            or #syllable > SYLLABLE_WIDTH then return nil end
    return self.syllable_ids[syllable]
end

function Model:_lookupBigram(first_id, second_id, first_character, second_character)
    local hash = hashU16(FNV_OFFSET, first_id)
    hash = hashU16(hash, second_id)
    hash = hashKey3(hash, first_character)
    hash = hashKey3(hash, second_character)
    local slot = band(hash, self.index_mask)
    while true do
        local entry = self.index_slots[slot]
        if entry == 0 then return 0 end
        local position = self.bigram_offset
            + (tonumber(entry) - 1) * BIGRAM_RECORD_SIZE
        if pointerU16(self.pointer, position) == first_id
                and pointerU16(self.pointer, position + 2) == second_id
                and pointerKey3(self.pointer, position + 4) == first_character
                and pointerKey3(self.pointer, position + 7) == second_character then
            return signedPointerByte(self.pointer, position + 10)
        end
        slot = band(slot + 1, self.index_mask)
    end
end

function Model:_prepareSyllables(canonical_pinyin)
    local count, ids = 0, {}
    for syllable in tostring(canonical_pinyin or ""):gmatch("[^']+") do
        count = count + 1
        ids[count] = self:_syllableId(syllable) or false
    end
    return ids, count
end

function Model:_candidateScorePrepared(ids, count, candidate, characters)
    if count == 0 or #candidate ~= count * 3 then return 0 end
    for index = 1, count do
        local character = textKey3(candidate, (index - 1) * 3 + 1)
        if not character then return 0 end
        characters[index] = character
    end
    local score = 0
    for index = 1, count - 1 do
        local first_id, second_id = ids[index], ids[index + 1]
        if first_id and second_id then
            local duplicate = false
            for previous = 1, index - 1 do
                if ids[previous] == first_id and ids[previous + 1] == second_id
                        and characters[previous] == characters[index]
                        and characters[previous + 1] == characters[index + 1] then
                    duplicate = true
                    break
                end
            end
            if not duplicate then
                score = score + self:_lookupBigram(
                    first_id, second_id, characters[index], characters[index + 1])
            end
        end
    end
    return score
end

function Model:candidateScore(canonical_pinyin, candidate)
    local ids, count = self:_prepareSyllables(canonical_pinyin)
    return self:_candidateScorePrepared(ids, count, tostring(candidate or ""), {})
end

function Model:_changesProtectedCharacter(baseline, proposed)
    local left, right = splitUtf8(baseline), splitUtf8(proposed)
    for index = 1, math.max(#left, #right) do
        if left[index] ~= right[index]
                and (self.protected[left[index]] or self.protected[right[index]]) then
            return true
        end
    end
    return false
end

function Model:winnerIndex(canonical_pinyin, candidates, _, limit)
    limit = math.min(tonumber(limit) or 5, #candidates)
    if limit < 2 then return 1 end
    local ids, count = self:_prepareSyllables(canonical_pinyin)
    if count < 2 then return 1 end
    local characters = {}
    local best_index, best_score, baseline_score = 1
    for index = 1, limit do
        local score = self:_candidateScorePrepared(
            ids, count, candidates[index], characters)
            - self.prior * self.scale * (index - 1)
        if index == 1 then baseline_score = score end
        if best_score == nil or score > best_score then
            best_index, best_score = index, score
        end
    end
    if best_index == 1 or best_score - baseline_score < self.margin * self.scale
            or self:_changesProtectedCharacter(candidates[1], candidates[best_index]) then
        return 1
    end
    return best_index
end

function Model:rerankedOrder(canonical_pinyin, candidates, context, limit)
    local result = {}
    for index, candidate in ipairs(candidates) do result[index] = candidate end
    local winner = self:winnerIndex(canonical_pinyin, result, context, limit)
    if winner > 1 then
        local selected = table.remove(result, winner)
        table.insert(result, 1, selected)
    end
    return result
end

function Model:getStats()
    return {
        bytes = #self.data,
        syllables = self.syllable_count,
        counts = { s = 0, p = 0, b = self.bigram_count, t = 0, c = 0, q = 0 },
        index_bytes = self.index_capacity * 2,
        index_capacity = self.index_capacity,
        maximum_probe = self.maximum_probe,
        average_probe = self.total_probe / self.bigram_count,
        prior = self.prior,
        margin = self.margin,
        scale = self.scale,
    }
end

local function parse(data, options)
    options = options or {}
    if type(data) ~= "string" or #data < HEADER_SIZE then
        error("sparse bigram reranker is truncated")
    elseif data:sub(1, 8) ~= MAGIC then
        error("sparse bigram reranker magic mismatch")
    elseif u16(data, 9) ~= VERSION or u16(data, 11) ~= HEADER_SIZE then
        error("sparse bigram reranker version mismatch")
    elseif options.expected_size and #data ~= options.expected_size then
        error("sparse bigram reranker size mismatch")
    elseif options.expected_adler32 and adler32(data) ~= options.expected_adler32 then
        error("sparse bigram reranker checksum mismatch")
    end
    local counts, offsets = {}, {}
    for index = 1, 6 do
        counts[index] = u32(data, 19 + (index - 1) * 4)
        offsets[index] = u32(data, 43 + (index - 1) * 4)
    end
    if counts[1] ~= 0 or counts[2] ~= 0 or counts[3] == 0
            or counts[4] ~= 0 or counts[5] ~= 0 or counts[6] ~= 0 then
        error("sparse bigram reranker contains a non-bigram family")
    end
    local syllable_count, protected_count = u16(data, 17), data:byte(16)
    local dictionary_end = HEADER_SIZE + syllable_count * SYLLABLE_WIDTH
    local bigram_offset = dictionary_end + protected_count * 3
    if offsets[1] ~= bigram_offset or offsets[2] ~= bigram_offset
            or offsets[3] ~= bigram_offset
            or offsets[4] ~= bigram_offset + counts[3] * BIGRAM_RECORD_SIZE
            or offsets[5] ~= offsets[4] or offsets[6] ~= offsets[4]
            or offsets[4] ~= #data then
        error("sparse bigram reranker family offsets mismatch")
    end
    if counts[3] >= 65535 then error("sparse bigram index exceeds uint16") end
    local model = setmetatable({
        data = data,
        pointer = ffi.cast("const uint8_t *", data),
        syllable_count = syllable_count,
        syllable_ids = {},
        bigram_count = counts[3],
        bigram_offset = bigram_offset,
        prior = data:byte(13),
        margin = data:byte(14),
        scale = data:byte(15),
        protected = {},
    }, Model)
    for index = 0, syllable_count - 1 do
        local position = HEADER_SIZE + 1 + index * SYLLABLE_WIDTH
        local syllable = data:sub(position, position + SYLLABLE_WIDTH - 1)
            :gsub("%z+$", "")
        if syllable == "" or model.syllable_ids[syllable] ~= nil then
            error("sparse bigram syllable dictionary mismatch")
        end
        model.syllable_ids[syllable] = index
    end
    local protected_offset = dictionary_end + 1
    for index = 0, protected_count - 1 do
        local character = data:sub(
            protected_offset + index * 3, protected_offset + index * 3 + 2)
        model.protected[character] = true
    end
    local capacity = 1
    while capacity * 0.66 < model.bigram_count do capacity = capacity * 2 end
    local slots, mask = ffi.new("uint16_t[?]", capacity), capacity - 1
    local maximum_probe, total_probe = 0, 0
    for record_index = 0, model.bigram_count - 1 do
        local position = bigram_offset + record_index * BIGRAM_RECORD_SIZE
        local slot, probe = band(hashRecord(model.pointer, position), mask), 0
        while slots[slot] ~= 0 do
            local existing = bigram_offset
                + (tonumber(slots[slot]) - 1) * BIGRAM_RECORD_SIZE
            if recordsEqual(model.pointer, position, existing) then
                error("sparse bigram duplicate indexed key")
            end
            probe = probe + 1
            if probe >= capacity then error("sparse bigram index saturated") end
            slot = band(slot + 1, mask)
        end
        slots[slot] = record_index + 1
        maximum_probe = math.max(maximum_probe, probe)
        total_probe = total_probe + probe
    end
    model.index_slots, model.index_capacity, model.index_mask = slots, capacity, mask
    model.maximum_probe, model.total_probe = maximum_probe, total_probe
    return model
end

function SparseBigramReranker.fromBlob(data, options)
    local ok, result = pcall(parse, data, options)
    if ok then return result end
    return nil, tostring(result)
end

function SparseBigramReranker.load(path, options)
    local handle, open_error = io.open(path, "rb")
    if not handle then return nil, tostring(open_error) end
    local ok, data = pcall(handle.read, handle, "*a")
    pcall(handle.close, handle)
    if not ok then return nil, tostring(data) end
    return SparseBigramReranker.fromBlob(data, options)
end

SparseBigramReranker.adler32 = adler32

return SparseBigramReranker
