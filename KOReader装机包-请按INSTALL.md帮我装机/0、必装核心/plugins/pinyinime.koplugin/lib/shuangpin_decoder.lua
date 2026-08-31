local ShuangpinDecoder = {}

local EXCEPTION_SYLLABLES = {
    m = true,
    n = true,
    ng = true,
    hng = true,
}

local ADJACENT = {
    q = "wa", w = "qase", e = "wsdr", r = "edft", t = "rfgy",
    y = "tghu", u = "yhji", i = "ujko", o = "iklp", p = "ol",
    a = "qwsz", s = "awedxz", d = "serfcx", f = "drtgvc",
    g = "ftyhbv", h = "gyujnb", j = "huikmn", k = "jiolm",
    l = "kop", z = "asx", x = "zsdc", c = "xdfv",
    v = "cfgb", b = "vghn", n = "bhjm", m = "njk",
}

local function displaySyllable(syllable)
    if syllable:match("^[nl]v") then
        return syllable:sub(1, 1) .. "ü" .. syllable:sub(3)
    elseif syllable:match("^[nl]ue") then
        return syllable:sub(1, 1) .. "üe" .. syllable:sub(4)
    end
    return syllable
end

local function appendPart(parts, value)
    if value and value ~= "" then
        parts[#parts + 1] = value
    end
end

local function joinWithBoundary(parts)
    return table.concat(parts, "'")
end

function ShuangpinDecoder:new(options)
    local instance = options or {}
    setmetatable(instance, self)
    self.__index = self
    instance.code_map = instance.code_map or {}
    return instance
end

function ShuangpinDecoder:decode(raw_code)
    raw_code = raw_code or ""
    if raw_code == "" then
        return {
            status = "idle",
            lookup_code = "",
            display_code = "",
            commit_code = "",
        }
    end

    local lookup_parts, display_parts, commit_parts = {}, {}, {}
    local position = 1
    while position <= #raw_code do
        local first = raw_code:sub(position, position)
        if first == "'" then
            local closing = raw_code:find("'", position + 1, true)
            if not closing then
                local literal = raw_code:sub(position + 1)
                appendPart(display_parts, literal .. "·")
                appendPart(commit_parts, literal)
                return {
                    status = "pending",
                    lookup_code = joinWithBoundary(lookup_parts),
                    display_code = joinWithBoundary(display_parts),
                    commit_code = joinWithBoundary(commit_parts),
                }
            end

            local literal = raw_code:sub(position + 1, closing - 1)
            if not EXCEPTION_SYLLABLES[literal] then
                appendPart(display_parts, raw_code:sub(position))
                appendPart(commit_parts, raw_code:sub(position):gsub("'", ""))
                return {
                    status = "invalid",
                    lookup_code = joinWithBoundary(lookup_parts),
                    display_code = joinWithBoundary(display_parts),
                    commit_code = joinWithBoundary(commit_parts),
                }
            end
            appendPart(lookup_parts, literal)
            appendPart(display_parts, literal)
            appendPart(commit_parts, literal)
            position = closing + 1
        elseif position == #raw_code then
            appendPart(display_parts, first .. "·")
            appendPart(commit_parts, first)
            return {
                status = "pending",
                lookup_code = joinWithBoundary(lookup_parts),
                display_code = joinWithBoundary(display_parts),
                commit_code = joinWithBoundary(commit_parts),
            }
        else
            local code = raw_code:sub(position, position + 1)
            local syllable = self.code_map[code]
            if not syllable then
                local remainder = raw_code:sub(position)
                appendPart(display_parts, remainder)
                appendPart(commit_parts, remainder:gsub("'", ""))
                return {
                    status = "invalid",
                    lookup_code = joinWithBoundary(lookup_parts),
                    display_code = joinWithBoundary(display_parts),
                    commit_code = joinWithBoundary(commit_parts),
                }
            end
            appendPart(lookup_parts, syllable)
            appendPart(display_parts, displaySyllable(syllable))
            appendPart(commit_parts, displaySyllable(syllable))
            position = position + 2
        end
    end

    return {
        status = "valid",
        lookup_code = joinWithBoundary(lookup_parts),
        display_code = joinWithBoundary(display_parts),
        commit_code = joinWithBoundary(commit_parts),
    }
end

function ShuangpinDecoder:canAppendFinal(raw_code, character)
    if character ~= ";" or raw_code == "" then
        return false
    end
    return self:decode(raw_code .. character).status == "valid"
end

function ShuangpinDecoder.buildCorrections(code_map, maximum_targets, canonical_map)
    maximum_targets = maximum_targets or 3
    local aliases = {}
    local canonical_codes = {}
    if canonical_map then
        for _, canonical in pairs(canonical_map) do
            canonical_codes[canonical] = true
        end
    else
        canonical_codes = code_map or {}
    end
    for canonical in pairs(canonical_codes) do
        for position = 1, #canonical do
            local character = canonical:sub(position, position)
            for replacement in (ADJACENT[character] or ""):gmatch(".") do
                local typo = canonical:sub(1, position - 1) .. replacement
                    .. canonical:sub(position + 1)
                if typo ~= canonical then
                    local target = aliases[typo]
                    if not target then
                        target = {}
                        aliases[typo] = target
                    end
                    target[canonical] = true
                end
            end
        end
    end

    local result = {}
    for typo, targets in pairs(aliases) do
        local values = {}
        for canonical in pairs(targets) do
            values[#values + 1] = canonical
        end
        table.sort(values)
        while #values > maximum_targets do
            values[#values] = nil
        end
        result[typo] = table.concat(values, ",")
    end
    return result
end

return ShuangpinDecoder
