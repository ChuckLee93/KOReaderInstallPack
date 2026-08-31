-- ITER-001V wrapper: reject irrelevant pinyin pairs before candidate parsing.

local source = debug.getinfo(1, "S").source
local path = source:sub(1, 1) == "@" and source:sub(2) or source
local directory = path:match("^(.*)/[^/]+$") or "."
local Base = dofile(directory .. "/sparse_bigram_reranker.lua")

local PairRoutedBigramReranker = {}

local function pointerU16(pointer, position)
    return pointer[position] + pointer[position + 1] * 256
end

local function textKey3(text, position)
    local first, second, third = text:byte(position, position + 2)
    if not third or first < 224 or first > 239
            or second < 128 or second > 191
            or third < 128 or third > 191 then return nil end
    return first * 65536 + second * 256 + third
end

local function pairKey(first_id, second_id)
    return first_id * 65536 + second_id
end

local function decorate(model)
    local pairs, pair_count = {}, 0
    for record_index = 0, model.bigram_count - 1 do
        local position = model.bigram_offset + record_index * 11
        local key = pairKey(
            pointerU16(model.pointer, position),
            pointerU16(model.pointer, position + 2))
        if not pairs[key] then
            pairs[key] = true
            pair_count = pair_count + 1
        end
    end
    model.relevant_pairs = pairs
    model.relevant_pair_count = pair_count

    local base_stats = model.getStats
    function model:getStats()
        local stats = base_stats(self)
        stats.relevant_pair_count = self.relevant_pair_count
        return stats
    end

    function model:_relevantPositions(syllables)
        local count, ids, positions = #syllables, {}, {}
        for index = 1, count do
            ids[index] = self.syllable_ids[syllables[index]] or false
        end
        for index = 1, count - 1 do
            local first_id, second_id = ids[index], ids[index + 1]
            if first_id and second_id
                    and self.relevant_pairs[pairKey(first_id, second_id)] then
                positions[#positions + 1] = index
            end
        end
        return ids, count, positions
    end

    function model:_scoreRelevant(ids, count, positions, candidate)
        if #candidate ~= count * 3 then return 0 end
        local score, seen_first, seen_second, seen_left, seen_right = 0, {}, {}, {}, {}
        local seen_count = 0
        for _, index in ipairs(positions) do
            local left = textKey3(candidate, (index - 1) * 3 + 1)
            local right = textKey3(candidate, index * 3 + 1)
            if not left or not right then return 0 end
            local duplicate = false
            for previous = 1, seen_count do
                if seen_first[previous] == ids[index]
                        and seen_second[previous] == ids[index + 1]
                        and seen_left[previous] == left
                        and seen_right[previous] == right then
                    duplicate = true
                    break
                end
            end
            if not duplicate then
                seen_count = seen_count + 1
                seen_first[seen_count], seen_second[seen_count] =
                    ids[index], ids[index + 1]
                seen_left[seen_count], seen_right[seen_count] = left, right
                score = score + self:_lookupBigram(
                    ids[index], ids[index + 1], left, right)
            end
        end
        return score
    end

    function model:winnerIndexSyllables(syllables, candidates, limit)
        limit = math.min(tonumber(limit) or 5, #candidates)
        if limit < 2 or type(syllables) ~= "table" or #syllables < 2 then
            return 1
        end
        local ids, count, positions = self:_relevantPositions(syllables)
        if #positions == 0 then return 1 end
        local best_index, best_score, baseline_score = 1
        for index = 1, limit do
            local score = self:_scoreRelevant(
                ids, count, positions, candidates[index])
                - self.prior * self.scale * (index - 1)
            if index == 1 then baseline_score = score end
            if best_score == nil or score > best_score then
                best_index, best_score = index, score
            end
        end
        if best_index == 1 or best_score - baseline_score < self.margin * self.scale
                or self:_changesProtectedCharacter(
                    candidates[1], candidates[best_index]) then
            return 1
        end
        return best_index
    end

    return model
end

function PairRoutedBigramReranker.fromBlob(data, options)
    local model, load_error = Base.fromBlob(data, options)
    if not model then return nil, load_error end
    local ok, result = pcall(decorate, model)
    if ok then return result end
    return nil, tostring(result)
end

function PairRoutedBigramReranker.load(model_path, options)
    local model, load_error = Base.load(model_path, options)
    if not model then return nil, load_error end
    local ok, result = pcall(decorate, model)
    if ok then return result end
    return nil, tostring(result)
end

PairRoutedBigramReranker.adler32 = Base.adler32

return PairRoutedBigramReranker
