-- Read-only fixed-width int8 reranker used by ITER-001N.
-- The model stays as one shared Lua string; no feature hash table is expanded.

local CompactStaticReranker = {}
local ffi = require("ffi")
local bit = require("bit")
local band, bxor, tobit = bit.band, bit.bxor, bit.tobit

local MAGIC = "PYRERK1\0"
local VERSION = 1
local HEADER_SIZE = 66
local SYLLABLE_WIDTH = 7
local FAMILY_ORDER = { "s", "p", "b", "t", "c", "q" }
local FAMILY_SPECS = {
    s = { size = 6 }, p = { size = 7 }, b = { size = 11 },
    t = { size = 16 }, c = { size = 7 }, q = { size = 9 },
}

local function u16(data, position)
    local a, b = data:byte(position, position + 1)
    if not b then error("truncated uint16") end
    return a + b * 256
end

local function u32(data, position)
    local a, b, c, d = data:byte(position, position + 3)
    if not d then error("truncated uint32") end
    return a + b * 256 + c * 65536 + d * 16777216
end

local function signedByte(value)
    return value >= 128 and value - 256 or value
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
    first = first % 65521
    second = second % 65521
    return second * 65536 + first
end

local function splitUtf8(text)
    local result = {}
    for character in tostring(text or ""):gmatch(
            "[%z\1-\127\194-\244][\128-\191]*") do
        result[#result + 1] = character
    end
    return result
end

local function lastUtf8Character(text)
    return tostring(text or ""):match(
        "([%z\1-\127\194-\244][\128-\191]*)$")
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
    local first = math.floor(value / 65536)
    local second = math.floor(value / 256) % 256
    hash = hashByte(hash, first)
    hash = hashByte(hash, second)
    return hashByte(hash, value % 256)
end

local function hashRecord(pointer, position, length)
    local hash = FNV_OFFSET
    for offset = 0, length - 1 do
        hash = hashByte(hash, pointer[position + offset])
    end
    return hash
end

local function recordKeysEqual(pointer, left, right, length)
    for offset = 0, length - 1 do
        if pointer[left + offset] ~= pointer[right + offset] then return false end
    end
    return true
end

local Model = {}
Model.__index = Model

function Model:_syllableId(syllable)
    if type(syllable) ~= "string" or syllable == ""
            or #syllable > SYLLABLE_WIDTH then
        return nil
    end
    return self.syllable_ids[syllable]
end

function Model:_lookupS(syllable_id, character)
    local pointer, index = self.pointer, self.indexes.s
    local hash = hashKey3(hashU16(FNV_OFFSET, syllable_id), character)
    local slot = band(hash, index.mask)
    while true do
        local entry = index.slots[slot]
        if entry == 0 then return 0 end
        local position = self.s_offset + (tonumber(entry) - 1) * 6
        if pointerU16(pointer, position) == syllable_id
                and pointerKey3(pointer, position + 2) == character then
            return signedPointerByte(pointer, position + 5)
        end
        slot = band(slot + 1, index.mask)
    end
end

function Model:_lookupP(bucket, syllable_id, character)
    local pointer, index = self.pointer, self.indexes.p
    local hash = hashByte(FNV_OFFSET, bucket)
    hash = hashKey3(hashU16(hash, syllable_id), character)
    local slot = band(hash, index.mask)
    while true do
        local entry = index.slots[slot]
        if entry == 0 then return 0 end
        local position = self.p_offset + (tonumber(entry) - 1) * 7
        if pointer[position] == bucket
                and pointerU16(pointer, position + 1) == syllable_id
                and pointerKey3(pointer, position + 3) == character then
            return signedPointerByte(pointer, position + 6)
        end
        slot = band(slot + 1, index.mask)
    end
end

function Model:_lookupB(first_id, second_id, first_character, second_character)
    local pointer, index = self.pointer, self.indexes.b
    local hash = hashU16(FNV_OFFSET, first_id)
    hash = hashU16(hash, second_id)
    hash = hashKey3(hash, first_character)
    hash = hashKey3(hash, second_character)
    local slot = band(hash, index.mask)
    while true do
        local entry = index.slots[slot]
        if entry == 0 then return 0 end
        local position = self.b_offset + (tonumber(entry) - 1) * 11
        if pointerU16(pointer, position) == first_id
                and pointerU16(pointer, position + 2) == second_id
                and pointerKey3(pointer, position + 4) == first_character
                and pointerKey3(pointer, position + 7) == second_character then
            return signedPointerByte(pointer, position + 10)
        end
        slot = band(slot + 1, index.mask)
    end
end

function Model:_lookupT(first_id, second_id, third_id,
        first_character, second_character, third_character)
    local pointer, index = self.pointer, self.indexes.t
    local hash = hashU16(FNV_OFFSET, first_id)
    hash = hashU16(hash, second_id)
    hash = hashU16(hash, third_id)
    hash = hashKey3(hash, first_character)
    hash = hashKey3(hash, second_character)
    hash = hashKey3(hash, third_character)
    local slot = band(hash, index.mask)
    while true do
        local entry = index.slots[slot]
        if entry == 0 then return 0 end
        local position = self.t_offset + (tonumber(entry) - 1) * 16
        if pointerU16(pointer, position) == first_id
                and pointerU16(pointer, position + 2) == second_id
                and pointerU16(pointer, position + 4) == third_id
                and pointerKey3(pointer, position + 6) == first_character
                and pointerKey3(pointer, position + 9) == second_character
                and pointerKey3(pointer, position + 12) == third_character then
            return signedPointerByte(pointer, position + 15)
        end
        slot = band(slot + 1, index.mask)
    end
end

function Model:_lookupC(context_character, first_character)
    local pointer, index = self.pointer, self.indexes.c
    local hash = hashKey3(FNV_OFFSET, context_character)
    hash = hashKey3(hash, first_character)
    local slot = band(hash, index.mask)
    while true do
        local entry = index.slots[slot]
        if entry == 0 then return 0 end
        local position = self.c_offset + (tonumber(entry) - 1) * 7
        if pointerKey3(pointer, position) == context_character
                and pointerKey3(pointer, position + 3) == first_character then
            return signedPointerByte(pointer, position + 6)
        end
        slot = band(slot + 1, index.mask)
    end
end

function Model:_lookupQ(context_character, syllable_id, first_character)
    local pointer, index = self.pointer, self.indexes.q
    local hash = hashKey3(FNV_OFFSET, context_character)
    hash = hashU16(hash, syllable_id)
    hash = hashKey3(hash, first_character)
    local slot = band(hash, index.mask)
    while true do
        local entry = index.slots[slot]
        if entry == 0 then return 0 end
        local position = self.q_offset + (tonumber(entry) - 1) * 9
        if pointerKey3(pointer, position) == context_character
                and pointerU16(pointer, position + 3) == syllable_id
                and pointerKey3(pointer, position + 5) == first_character then
            return signedPointerByte(pointer, position + 8)
        end
        slot = band(slot + 1, index.mask)
    end
end

local function textKey3(text, position)
    local first, second, third = text:byte(position, position + 2)
    if not third or first < 224 or first > 239
            or second < 128 or second > 191
            or third < 128 or third > 191 then return nil end
    return first * 65536 + second * 256 + third
end

function Model:_prepareSyllables(canonical_pinyin)
    local count, ids = 0, {}
    for syllable in tostring(canonical_pinyin or ""):gmatch("[^']+") do
        count = count + 1
        ids[count] = self:_syllableId(syllable) or false
    end
    return ids, count
end

function Model:_candidateScorePrepared(ids, count, candidate, context_character, characters)
    if count == 0 or #candidate ~= count * 3 then return 0 end
    for index = 1, count do
        local character = textKey3(candidate, (index - 1) * 3 + 1)
        if not character then return 0 end
        characters[index] = character
    end

    local score = 0
    for index = 1, count do
        local syllable_id, character = ids[index], characters[index]
        if syllable_id then
            local duplicate = false
            for previous = 1, index - 1 do
                if ids[previous] == syllable_id
                        and characters[previous] == character then
                    duplicate = true
                    break
                end
            end
            if not duplicate then
                score = score + self:_lookupS(syllable_id, character)
            end
            local bucket = index == 1 and 0 or index == count and 2 or 1
            duplicate = false
            for previous = 1, index - 1 do
                local previous_bucket = previous == 1 and 0
                    or previous == count and 2 or 1
                if previous_bucket == bucket and ids[previous] == syllable_id
                        and characters[previous] == character then
                    duplicate = true
                    break
                end
            end
            if not duplicate then
                score = score + self:_lookupP(bucket, syllable_id, character)
            end
        end
    end
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
                score = score + self:_lookupB(
                    first_id, second_id, characters[index], characters[index + 1])
            end
        end
    end
    for index = 1, count - 2 do
        local first_id, second_id, third_id =
            ids[index], ids[index + 1], ids[index + 2]
        if first_id and second_id and third_id then
            local duplicate = false
            for previous = 1, index - 1 do
                if ids[previous] == first_id and ids[previous + 1] == second_id
                        and ids[previous + 2] == third_id
                        and characters[previous] == characters[index]
                        and characters[previous + 1] == characters[index + 1]
                        and characters[previous + 2] == characters[index + 2] then
                    duplicate = true
                    break
                end
            end
            if not duplicate then
                score = score + self:_lookupT(
                    first_id, second_id, third_id, characters[index],
                    characters[index + 1], characters[index + 2])
            end
        end
    end
    if context_character then
        score = score + self:_lookupC(context_character, characters[1])
        if ids[1] then
            score = score + self:_lookupQ(
                context_character, ids[1], characters[1])
        end
    end
    return score
end

function Model:candidateScore(canonical_pinyin, candidate, context)
    local ids, count = self:_prepareSyllables(canonical_pinyin)
    local context_text = lastUtf8Character(context)
    local context_character = context_text and #context_text == 3
        and textKey3(context_text, 1) or nil
    return self:_candidateScorePrepared(
        ids, count, tostring(candidate or ""), context_character, {})
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

function Model:winnerIndex(canonical_pinyin, candidates, context, limit)
    limit = math.min(tonumber(limit) or 5, #candidates)
    if limit < 2 then return 1 end
    local ids, count = self:_prepareSyllables(canonical_pinyin)
    -- Single-syllable examples never promoted in either frozen corpus. Keep
    -- their baseline order without touching the feature sections.
    if count < 2 then return 1 end
    local context_text = lastUtf8Character(context)
    local context_character = context_text and #context_text == 3
        and textKey3(context_text, 1) or nil
    local characters = {}
    local best_index, best_score, baseline_score = 1
    for index = 1, limit do
        local score = self:_candidateScorePrepared(
            ids, count, candidates[index], context_character, characters)
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
        local candidate = table.remove(result, winner)
        table.insert(result, 1, candidate)
    end
    return result
end

function Model:getStats()
    local counts, indexes = {}, {}
    for _, family in ipairs(FAMILY_ORDER) do
        counts[family] = self.families[family].count
        local index = self.indexes[family]
        indexes[family] = {
            capacity = index.capacity,
            bytes = index.capacity * 2,
            maximum_probe = index.maximum_probe,
            average_probe = index.total_probe / self.families[family].count,
        }
    end
    return {
        bytes = #self.data,
        syllables = self.syllable_count,
        counts = counts,
        indexes = indexes,
        index_bytes = self.index_bytes,
        prior = self.prior,
        margin = self.margin,
        scale = self.scale,
    }
end

local function buildIndexes(model)
    local pointer, total_bytes = model.pointer, 0
    for _, family in ipairs(FAMILY_ORDER) do
        local metadata = model.families[family]
        if metadata.count >= 65535 then
            error("compact reranker family exceeds uint16 index")
        end
        local capacity = 1
        while capacity * 0.66 < metadata.count do capacity = capacity * 2 end
        local slots = ffi.new("uint16_t[?]", capacity)
        local mask = capacity - 1
        local maximum_probe, total_probe = 0, 0
        local base = metadata.offset - 1
        local key_length = metadata.size - 1
        for record_index = 0, metadata.count - 1 do
            local position = base + record_index * metadata.size
            local slot = band(hashRecord(pointer, position, key_length), mask)
            local probe = 0
            while slots[slot] ~= 0 do
                local existing_index = tonumber(slots[slot]) - 1
                local existing_position = base + existing_index * metadata.size
                if recordKeysEqual(
                        pointer, position, existing_position, key_length) then
                    error("compact reranker duplicate indexed key: " .. family)
                end
                probe = probe + 1
                if probe >= capacity then
                    error("compact reranker index saturated: " .. family)
                end
                slot = band(slot + 1, mask)
            end
            slots[slot] = record_index + 1
            maximum_probe = math.max(maximum_probe, probe)
            total_probe = total_probe + probe
        end
        model.indexes[family] = {
            slots = slots,
            capacity = capacity,
            mask = mask,
            maximum_probe = maximum_probe,
            total_probe = total_probe,
        }
        total_bytes = total_bytes + capacity * 2
    end
    model.index_bytes = total_bytes
end

local function parse(data, options)
    options = options or {}
    if type(data) ~= "string" or #data < HEADER_SIZE then
        error("compact reranker is truncated")
    elseif data:sub(1, 8) ~= MAGIC then
        error("compact reranker magic mismatch")
    elseif u16(data, 9) ~= VERSION or u16(data, 11) ~= HEADER_SIZE then
        error("compact reranker version mismatch")
    elseif options.expected_size and #data ~= options.expected_size then
        error("compact reranker size mismatch")
    elseif options.expected_adler32 and adler32(data) ~= options.expected_adler32 then
        error("compact reranker checksum mismatch")
    end
    local model = setmetatable({
        data = data,
        pointer = ffi.cast("const uint8_t *", data),
        prior = data:byte(13),
        margin = data:byte(14),
        scale = data:byte(15),
        syllable_count = u16(data, 17),
        syllable_ids = {},
        families = {},
        indexes = {},
        protected = {},
    }, Model)
    local protected_count = data:byte(16)
    local expected_offset = HEADER_SIZE + model.syllable_count * SYLLABLE_WIDTH
        + protected_count * 3
    for index, family in ipairs(FAMILY_ORDER) do
        local count = u32(data, 19 + (index - 1) * 4)
        local offset = u32(data, 43 + (index - 1) * 4)
        if offset ~= expected_offset then
            error("compact reranker family offset mismatch: " .. family)
        end
        model.families[family] = {
            count = count,
            offset = offset + 1,
            size = FAMILY_SPECS[family].size,
        }
        model[family .. "_count"] = count
        model[family .. "_offset"] = offset
        expected_offset = expected_offset + count * FAMILY_SPECS[family].size
    end
    if expected_offset ~= #data then error("compact reranker length mismatch") end
    buildIndexes(model)
    for index = 0, model.syllable_count - 1 do
        local position = HEADER_SIZE + 1 + index * SYLLABLE_WIDTH
        local syllable = data:sub(position, position + SYLLABLE_WIDTH - 1)
            :gsub("%z+$", "")
        if syllable == "" or model.syllable_ids[syllable] ~= nil then
            error("compact reranker syllable dictionary mismatch")
        end
        model.syllable_ids[syllable] = index
    end
    local protected_offset = HEADER_SIZE + model.syllable_count * SYLLABLE_WIDTH + 1
    for index = 0, protected_count - 1 do
        local character = data:sub(
            protected_offset + index * 3, protected_offset + index * 3 + 2)
        model.protected[character] = true
    end
    return model
end

function CompactStaticReranker.fromBlob(data, options)
    local ok, result = pcall(parse, data, options)
    if ok then return result end
    return nil, tostring(result)
end

function CompactStaticReranker.load(path, options)
    local handle, open_error = io.open(path, "rb")
    if not handle then return nil, tostring(open_error) end
    local ok, data = pcall(handle.read, handle, "*a")
    pcall(handle.close, handle)
    if not ok then return nil, tostring(data) end
    return CompactStaticReranker.fromBlob(data, options)
end

CompactStaticReranker.adler32 = adler32

return CompactStaticReranker
