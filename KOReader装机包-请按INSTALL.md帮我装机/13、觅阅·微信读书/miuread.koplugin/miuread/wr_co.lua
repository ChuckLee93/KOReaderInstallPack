--[[--
WeRead Web Reader native chapterOffset (`co`) coordinate helper.

Archived Web Reader parser code assigns `data-wr-co` from the character
position in the complete decoded chapter XHTML. JavaScript string offsets are
UTF-16 code-unit offsets, while KOReader's PosMap exposes Lua 1-index rune
boundaries. This module converts between those two coordinate conventions.

The caller should pass the same complete raw XHTML map used by annotation
coordinates (UTF-8 BOM removed, no body cropping or whitespace normalization).
--]]--

local PosMap = require("miuread.annotations.posmap")

local M = {}

local function utf16_units(rune)
    if type(rune) ~= "string" or rune == "" then return 0 end
    local first = string.byte(rune, 1)
    -- Valid UTF-8 supplementary scalar values are four bytes and occupy two
    -- UTF-16 code units. WTF-8 surrogate code units are three bytes and must
    -- remain one unit, matching JavaScript's string indexing semantics.
    if first and first >= 0xF0 and first <= 0xF4 and #rune >= 4 then
        return 2
    end
    return 1
end

function M.fromMap(map, html_boundary)
    if type(map) ~= "table" or type(map.runes) ~= "table" then
        return nil, "wr_co_map_missing"
    end
    local runes = map.runes
    local boundary = tonumber(html_boundary)
    if boundary == nil then return nil, "wr_co_boundary_missing" end
    boundary = math.floor(boundary)
    if boundary < 1 or boundary > #runes + 1 then
        return nil, "wr_co_boundary_out_of_bounds"
    end

    local units = 0
    for i = 1, boundary - 1 do
        units = units + utf16_units(runes[i])
    end

    return {
        co = units,
        basis = "raw_xhtml_utf16",
        rune_boundary = boundary,
        codepoints_before = boundary - 1,
        utf16_extra = units - (boundary - 1),
    }
end

function M.fromSource(coord_html, html_boundary)
    local ok, map = pcall(PosMap.build, tostring(coord_html or ""))
    if not ok or type(map) ~= "table" then
        return nil, "wr_co_map_build_failed:" .. tostring(map)
    end
    return M.fromMap(map, html_boundary)
end

function M.toMap(map, co)
    if type(map) ~= "table" or type(map.runes) ~= "table" then
        return nil, "wr_co_map_missing"
    end
    local target = tonumber(co)
    if target == nil then return nil, "wr_co_missing" end
    target = math.floor(target)
    if target < 0 then return nil, "wr_co_negative" end

    local runes = map.runes
    local units = 0
    if target == 0 then
        return {
            co = 0, basis = "raw_xhtml_utf16", rune_boundary = 1,
            codepoints_before = 0, utf16_extra = 0, exact = true,
        }
    end

    for i = 1, #runes do
        if units == target then
            return {
                co = target, basis = "raw_xhtml_utf16", rune_boundary = i,
                codepoints_before = i - 1, utf16_extra = units - (i - 1), exact = true,
            }
        end
        local width = utf16_units(runes[i])
        if units + width > target then
            return {
                co = target, basis = "raw_xhtml_utf16", rune_boundary = i,
                codepoints_before = i - 1, utf16_extra = units - (i - 1),
                exact = false, snapped = "inside_utf16_scalar", resolved_co = units,
            }
        end
        units = units + width
    end

    if units == target then
        return {
            co = target, basis = "raw_xhtml_utf16", rune_boundary = #runes + 1,
            codepoints_before = #runes, utf16_extra = units - #runes, exact = true,
        }
    end
    return nil, "wr_co_out_of_bounds"
end

function M.toSource(coord_html, co)
    local ok, map = pcall(PosMap.build, tostring(coord_html or ""))
    if not ok or type(map) ~= "table" then
        return nil, "wr_co_map_build_failed:" .. tostring(map)
    end
    local resolved, err = M.toMap(map, co)
    if not resolved then return nil, err end
    resolved.map = map
    return resolved
end

return M
