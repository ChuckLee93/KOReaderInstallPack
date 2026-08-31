--[[--
章节 HTML 坐标系基础

服务端 range = 章节 HTML 字符串上的字符索引。
切字复用 KOReader `util.splitToChars`（含 WTF-8 surrogate 处理）。
BMP 内文字（常见 CJK）与 UTF-16 code unit 对齐；非 BMP 理论上可能差 1。

BOM：章节 HTML 读入时通常不含 BOM。注入前剥 BOM，避免整章右偏 1。

Lua 数组 1-index：runes[1] ↔ 服务端偏移 0。

@module miuread.annotations.runes
--]]--

local util = require("util")

local Runes = {}

function Runes.stripLeadingBOM(s)
    if type(s) ~= "string" then
        return s
    end
    -- UTF-8 BOM: EF BB BF
    if s:sub(1, 3) == "\xef\xbb\xbf" then
        return s:sub(4)
    end
    return s
end

--- UTF-8 → 码点数组（不是 grapheme cluster）。
-- 委托 `util.splitToChars`；nil/空串返回 {}。
function Runes.toRunes(str)
    if type(str) ~= "string" or str == "" then
        return {}
    end
    return util.splitToChars(str)
end

--- rune 索引 → 原始字符串字节位置（1-based）。
-- 供等长替换（如原生 underline class 改写）在 rune 数组与字节串之间换算。
-- @tparam table runes Runes.toRunes 产物
-- @tparam int k 1-based rune 索引，允许 k == #runes + 1（串尾）
-- @treturn int 字节偏移
function Runes.byteAt(runes, k)
    if type(runes) ~= "table" then
        return 1
    end
    if k < 1 then
        k = 1
    end
    local byte = 1
    local n = #runes
    if k > n + 1 then
        k = n + 1
    end
    for i = 1, k - 1 do
        byte = byte + #runes[i]
    end
    return byte
end

--- 从 Lua 半开切片提取纯文本（跳过 HTML 标签字符）。
-- 输入仍是 HTML runes，只能跳过标签，不还原实体。
function Runes.extractText(runes, start, end_pos)
    local parts = {}
    local in_tag = false
    for i = start, end_pos - 1 do
        local r = runes[i]
        if r == "<" then
            in_tag = true
        elseif r == ">" then
            in_tag = false
        elseif not in_tag then
            parts[#parts + 1] = r
        end
    end
    return table.concat(parts)
end

return Runes
