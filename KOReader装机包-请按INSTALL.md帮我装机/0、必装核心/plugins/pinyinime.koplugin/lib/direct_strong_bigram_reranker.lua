-- ITER-002N read-only direct-matrix strong-bigram reranker.
-- The asset and all ranking constants reproduce the frozen ITER-001V model.

local ffi = require("ffi")
require("ffi/posix_h")

local C = ffi.C

local DirectStrongBigramReranker = {}
local Model = {}
Model.__index = Model

local MAGIC = "PYDSB1\0\0"
local VERSION = 1
local HEADER_SIZE = 68
local SYLLABLE_WIDTH = 7
local MAX_FILE_SIZE = 2 * 1024 * 1024
local EXPECTED_SYLLABLES = 45
local EXPECTED_CHARACTERS = 95
local EXPECTED_ROUTES = 36
local EXPECTED_FEATURES = 85
local RANK_PRIOR = 8 * 16
local PROMOTION_MARGIN = 10 * 16
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

local function align4(value)
    return math.floor((value + 3) / 4) * 4
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

local function codepoint3(text, position)
    local first, second, third = text:byte(position, position + 2)
    if not third or first < 224 or first > 239
            or second < 128 or second > 191
            or third < 128 or third > 191 then
        return nil
    end
    return (first - 224) * 4096 + (second - 128) * 64 + third - 128
end

local function readFile(path)
    if type(path) ~= "string" or path == "" then
        error("direct strong-bigram path is required")
    end
    local fd = C.open(path, C.O_RDONLY)
    if fd < 0 then error("unable to open direct strong-bigram artifact") end
    local size = tonumber(C.lseek(fd, 0, C.SEEK_END))
    if not size or size < HEADER_SIZE or size > MAX_FILE_SIZE
            or tonumber(C.lseek(fd, 0, C.SEEK_SET)) ~= 0 then
        C.close(fd)
        error("invalid direct strong-bigram artifact size")
    end
    local raw = C.malloc(size)
    if raw == nil then
        C.close(fd)
        error("unable to allocate direct strong-bigram buffer")
    end
    local pointer = ffi.cast("uint8_t*", raw)
    local consumed = 0
    while consumed < size do
        local count = tonumber(C.read(fd, pointer + consumed, size - consumed))
        if not count or count <= 0 then
            C.close(fd)
            C.free(raw)
            error("unable to read direct strong-bigram artifact")
        end
        consumed = consumed + count
    end
    C.close(fd)
    return ffi.gc(pointer, C.free), size
end

local function validateZeroPadding(pointer, first, last)
    for position = first, last - 1 do
        if pointer[position] ~= 0 then
            error("invalid direct strong-bigram section padding")
        end
    end
end

local function loadModel(path, options)
    options = type(options) == "table" and options or {}
    local pointer, size = readFile(path)
    if ffi.string(pointer, 8) ~= MAGIC then
        error("invalid direct strong-bigram magic")
    end
    local version = u32(pointer, 8)
    local header_size = u32(pointer, 12)
    local declared_size = u32(pointer, 16)
    local declared_adler = u32(pointer, 20)
    local syllable_count = u32(pointer, 24)
    local character_count = u32(pointer, 28)
    local route_count = u32(pointer, 32)
    local feature_count = u32(pointer, 36)
    local syllable_offset = u32(pointer, 40)
    local character_map_offset = u32(pointer, 44)
    local route_matrix_offset = u32(pointer, 48)
    local weight_matrix_offset = u32(pointer, 52)
    local protected_offset = u32(pointer, 56)
    local protected_count = u32(pointer, 60)
    local reserved = u32(pointer, 64)
    if version ~= VERSION or header_size ~= HEADER_SIZE
            or declared_size ~= size or syllable_count ~= EXPECTED_SYLLABLES
            or character_count ~= EXPECTED_CHARACTERS
            or route_count ~= EXPECTED_ROUTES
            or feature_count ~= EXPECTED_FEATURES
            or protected_count ~= 3 or reserved ~= 0 then
        error("invalid direct strong-bigram header")
    end
    if options.expected_size and size ~= options.expected_size then
        error("direct strong-bigram expected size mismatch")
    elseif options.expected_adler32
            and declared_adler ~= options.expected_adler32 then
        error("direct strong-bigram expected checksum mismatch")
    end

    local syllable_end = syllable_offset + syllable_count * SYLLABLE_WIDTH
    local expected_character_map = align4(syllable_end)
    local character_map_end = character_map_offset + 65536 * 2
    local syllable_dimension = syllable_count + 1
    local route_matrix_end = route_matrix_offset
        + syllable_dimension * syllable_dimension
    local expected_weight_matrix = align4(route_matrix_end)
    local character_dimension = character_count + 1
    local weight_matrix_end = weight_matrix_offset
        + (route_count + 1) * character_dimension * character_dimension
    local expected_protected = align4(weight_matrix_end)
    local protected_end = protected_offset + protected_count * 4
    if syllable_offset ~= HEADER_SIZE
            or character_map_offset ~= expected_character_map
            or route_matrix_offset ~= character_map_end
            or weight_matrix_offset ~= expected_weight_matrix
            or protected_offset ~= expected_protected
            or protected_end ~= size then
        error("invalid direct strong-bigram section bounds")
    end
    validateZeroPadding(pointer, syllable_end, character_map_offset)
    validateZeroPadding(pointer, route_matrix_end, weight_matrix_offset)
    validateZeroPadding(pointer, weight_matrix_end, protected_offset)
    if adler32(pointer, HEADER_SIZE, size) ~= declared_adler then
        error("direct strong-bigram payload checksum mismatch")
    end

    local model = setmetatable({
        pointer = pointer,
        external_bytes = size,
        syllable_count = syllable_count,
        character_count = character_count,
        route_count = route_count,
        feature_count = feature_count,
        syllable_offset = syllable_offset,
        character_map_offset = character_map_offset,
        route_matrix_offset = route_matrix_offset,
        weight_matrix_offset = weight_matrix_offset,
        protected_offset = protected_offset,
        protected_count = protected_count,
        syllable_dimension = syllable_dimension,
        character_dimension = character_dimension,
        syllable_ids = {},
        protected = {},
        ids = {},
        positions = {},
        route_ids = {},
        seen_route = {},
        seen_left = {},
        seen_right = {},
    }, Model)

    for index = 0, syllable_count - 1 do
        local value = ffi.string(
            pointer + syllable_offset + index * SYLLABLE_WIDTH,
            SYLLABLE_WIDTH):match("^[^%z]*")
        if not value or value == "" or #value > SYLLABLE_WIDTH
                or not value:match("^[a-z]+$") or model.syllable_ids[value] then
            error("invalid direct strong-bigram syllable table")
        end
        model.syllable_ids[value] = index + 1
    end

    local seen_characters = ffi.new("uint8_t[?]", character_count + 1)
    local observed_characters = 0
    for codepoint = 0, 65535 do
        local identifier = u16(pointer, character_map_offset + codepoint * 2)
        if identifier > character_count
                or identifier ~= 0 and seen_characters[identifier] ~= 0 then
            error("invalid direct strong-bigram character identifier")
        elseif identifier ~= 0 then
            seen_characters[identifier] = 1
            observed_characters = observed_characters + 1
        end
    end
    if observed_characters ~= character_count then
        error("direct strong-bigram character count mismatch")
    end

    local seen_routes = ffi.new("uint8_t[?]", route_count + 1)
    local observed_routes = 0
    for first = 0, syllable_count do
        for second = 0, syllable_count do
            local identifier = pointer[route_matrix_offset
                + first * syllable_dimension + second]
            if identifier > route_count
                    or identifier ~= 0 and seen_routes[identifier] ~= 0
                    or (first == 0 or second == 0) and identifier ~= 0 then
                error("invalid direct strong-bigram route identifier")
            elseif identifier ~= 0 then
                seen_routes[identifier] = 1
                observed_routes = observed_routes + 1
            end
        end
    end
    if observed_routes ~= route_count then
        error("direct strong-bigram route count mismatch")
    end

    local observed_features = 0
    for route = 0, route_count do
        for left = 0, character_count do
            local row = weight_matrix_offset
                + (route * character_dimension + left) * character_dimension
            for right = 0, character_count do
                local weight = signedByte(pointer, row + right)
                if weight ~= 0 then
                    if route == 0 or left == 0 or right == 0 then
                        error("invalid direct strong-bigram weight sentinel")
                    end
                    observed_features = observed_features + 1
                end
            end
        end
    end
    if observed_features ~= feature_count then
        error("direct strong-bigram feature count mismatch")
    end

    for index = 0, protected_count - 1 do
        local codepoint = u32(pointer, protected_offset + index * 4)
        if not EXPECTED_PROTECTED[codepoint] or model.protected[codepoint] then
            error("invalid direct strong-bigram protected character")
        end
        model.protected[codepoint] = true
    end
    return model
end

function Model:_prepareRouteIds(count)
    local pointer = self.pointer
    local position_count = 0
    if not pointer then return 0 end
    for index = 1, count - 1 do
        local first, second = self.ids[index], self.ids[index + 1]
        local route = first ~= 0 and second ~= 0
            and pointer[self.route_matrix_offset
                + first * self.syllable_dimension + second] or 0
        if route ~= 0 then
            position_count = position_count + 1
            self.positions[position_count] = index
            self.route_ids[position_count] = route
        end
    end
    return position_count
end

function Model:_prepareRoutes(syllables)
    if not self.pointer or type(syllables) ~= "table" then return 0, 0 end
    local count = #syllables
    for index = 1, count do
        self.ids[index] = self.syllable_ids[syllables[index]] or 0
    end
    return count, self:_prepareRouteIds(count)
end

function Model:_scorePrepared(count, position_count, candidate)
    if not self.pointer or type(candidate) ~= "string" or count == 0
            or #candidate ~= count * 3 or position_count == 0 then
        return 0
    end
    local pointer = self.pointer
    local seen_count, score = 0, 0
    for route_index = 1, position_count do
        local index = self.positions[route_index]
        local left_code = codepoint3(candidate, (index - 1) * 3 + 1)
        local right_code = codepoint3(candidate, index * 3 + 1)
        if not left_code or not right_code then return 0 end
        local left = u16(pointer,
            self.character_map_offset + left_code * 2)
        local right = u16(pointer,
            self.character_map_offset + right_code * 2)
        if left ~= 0 and right ~= 0 then
            local route = self.route_ids[route_index]
            local duplicate = false
            for previous = 1, seen_count do
                if self.seen_route[previous] == route
                        and self.seen_left[previous] == left
                        and self.seen_right[previous] == right then
                    duplicate = true
                    break
                end
            end
            if not duplicate then
                seen_count = seen_count + 1
                self.seen_route[seen_count] = route
                self.seen_left[seen_count] = left
                self.seen_right[seen_count] = right
                local cell = (route * self.character_dimension + left)
                    * self.character_dimension + right
                score = score + signedByte(
                    pointer, self.weight_matrix_offset + cell)
            end
        end
    end
    return score
end

function Model:candidateScore(canonical_pinyin, candidate)
    if not self.pointer then return 0 end
    local count = 0
    for syllable in tostring(canonical_pinyin or ""):gmatch("[^']+") do
        count = count + 1
        self.ids[count] = self.syllable_ids[syllable] or 0
    end
    return self:_scorePrepared(
        count, self:_prepareRouteIds(count), tostring(candidate or ""))
end

function Model:_changesProtected(left, right)
    if type(left) ~= "string" or type(right) ~= "string" then return false end
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

function Model:_winnerPrepared(count, position_count, candidates, limit)
    local maximum = math.min(#candidates, tonumber(limit) or 5)
    if count < 2 or position_count == 0 or maximum < 2 then return 1 end
    local baseline_score = self:_scorePrepared(
        count, position_count, candidates[1])
    local winner, winner_score = 1, baseline_score
    for index = 2, maximum do
        local score = self:_scorePrepared(count, position_count, candidates[index])
            - RANK_PRIOR * (index - 1)
        if score > winner_score then
            winner, winner_score = index, score
        end
    end
    if winner == 1 or winner_score - baseline_score < PROMOTION_MARGIN
            or self:_changesProtected(candidates[1], candidates[winner]) then
        return 1
    end
    return winner
end

function Model:winnerIndexSyllables(syllables, candidates, limit)
    if not self.pointer or type(candidates) ~= "table" or #candidates < 2 then
        return 1
    end
    local count, position_count = self:_prepareRoutes(syllables)
    return self:_winnerPrepared(count, position_count, candidates, limit)
end

function Model:winnerIndex(canonical_pinyin, candidates, _, limit)
    if not self.pointer or type(candidates) ~= "table" or #candidates < 2 then
        return 1
    end
    local count = 0
    for syllable in tostring(canonical_pinyin or ""):gmatch("[^']+") do
        count = count + 1
        self.ids[count] = self.syllable_ids[syllable] or 0
    end
    return self:_winnerPrepared(
        count, self:_prepareRouteIds(count), candidates, limit)
end

function Model:rerankedOrder(canonical_pinyin, candidates, context, limit)
    local result = {}
    for index, candidate in ipairs(candidates or {}) do result[index] = candidate end
    local winner = self:winnerIndex(canonical_pinyin, result, context, limit)
    if winner > 1 then
        local selected = table.remove(result, winner)
        table.insert(result, 1, selected)
    end
    return result
end

function Model:getStats()
    return {
        external_bytes = self.external_bytes,
        syllables = self.syllable_count,
        characters = self.character_count,
        routes = self.route_count,
        features = self.feature_count,
        prior = RANK_PRIOR,
        margin = PROMOTION_MARGIN,
    }
end

function Model:close()
    if self.pointer then
        local pointer = ffi.gc(self.pointer, nil)
        C.free(pointer)
        self.pointer = nil
    end
end

function DirectStrongBigramReranker.load(path, options)
    local ok, model = pcall(loadModel, path, options)
    if ok then return model end
    return nil, tostring(model):gsub("[\r\n]+", " ")
end

return DirectStrongBigramReranker
