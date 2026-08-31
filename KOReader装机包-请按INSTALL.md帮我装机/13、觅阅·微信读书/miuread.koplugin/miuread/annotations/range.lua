--[[--
服务端 range 字符串语义：0-index **闭区间** [rangeStart, rangeEnd]
  "A-B" → start=A, end=B-1, pageReview=false
  "A"   → start=A, end=A,   pageReview=true
  切分按 '-'，取 **首段** 与 **末段**（不是“第二段”；"1-2-3" 末段为 3）

保存编码：
  max >= min → 字符串 "min-(max+1)"   （半开写回）
  否则       → 字符串 "min"           （页评）

本模块对外统一用 **Lua 1-index 半开** [start, end_pos)：
  "A-B" → start=A+1, end_pos=B+1, page_review=false
  "A"   → start=A+1, end_pos=A+2, page_review=true

循环约定：
  for i = start, end_pos - 1 do ... end
  runes[1] ↔ 服务端偏移 0

@module miuread.annotations.range
--]]--

local util = require("util")

local Range = {}

--- 按 '-' 切分，保留尾部空段（"A-" → {"A",""}）。
-- 复用 KOReader util.splitToArray；其 gsplit 不产出尾部空段，这里补上。
local function splitHyphen(s)
    local parts = util.splitToArray(s, "-", true)
    if #s > 0 and s:sub(-1) == "-" then
        parts[#parts + 1] = ""
    end
    return parts
end

--- 解析服务端 range 字符串 → Lua 1-index 半开区间。
-- @string range_str
-- @treturn[1] int start
-- @treturn[1] int end_pos
-- @treturn[1] bool page_review
-- @treturn[2] nil
function Range.parse(range_str)
    if type(range_str) ~= "string" or range_str == "" then
        return nil
    end

    local parts = splitHyphen(range_str)
    if #parts == 0 then
        return nil
    end

    local start0 = tonumber(parts[1])
    if not start0 then
        -- 解析失败 → rangeStart = -1（无效）
        return nil
    end

    if #parts == 1 then
        -- 页评锚点：闭区间 [A, A] → Lua [A+1, A+2)
        return start0 + 1, start0 + 2, true
    end

    -- 取 **最后一段** 作为右端半开值，再减 1 得闭区间终点
    local end_wire = tonumber(parts[#parts])
    if not end_wire then
        return nil
    end

    local end_closed = end_wire - 1
    -- 有效性：start != -1 && end != -1 && start <= end
    if start0 > end_closed then
        return nil
    end

    -- 闭区间 [start0, end_closed] → Lua 半开 [start0+1, end_closed+2)
    -- end_closed+2 = end_wire+1
    return start0 + 1, end_wire + 1, false
end

--- 闭区间视图（0-index closed）。
-- @treturn[1] int range_start
-- @treturn[1] int range_end
-- @treturn[1] bool page_review
function Range.toOfficialClosed(start, end_pos, page_review)
    if type(start) ~= "number" or type(end_pos) ~= "number" then
        return nil
    end
    if start < 1 or end_pos <= start then
        return nil
    end
    local a = start - 1
    if page_review then
        return a, a, true
    end
    -- Lua [A+1, B+1) ↔ 服务端闭区间 [A, B-1]
    return a, end_pos - 2, false
end

--- 编码回服务端 range 字符串。
function Range.encode(start, end_pos, page_review)
    if type(start) ~= "number" or type(end_pos) ~= "number" then
        return nil
    end
    if start < 1 or end_pos <= start then
        return nil
    end
    local a = start - 1
    if page_review then
        return tostring(a)
    end
    -- 半开右端 = 服务端字符串里的 B
    return a .. "-" .. (end_pos - 1)
end

--- 有效性校验（对已解析的 Lua 半开区间）。
function Range.isValid(start, end_pos)
    return type(start) == "number"
        and type(end_pos) == "number"
        and start >= 1
        and end_pos > start
end

--- 闭区间连通判断（是否相交或端点相接）。
-- 参数为 0-index 闭区间。
function Range.isConnectClosed(start1, end1, start2, end2)
    return start1 <= end2 and end1 >= start2
end

--- 半开区间版本的 connect/overlap（含共享端点的闭区间 connect）。
-- Lua 半开：start1 < end2 and end1 > start2
function Range.isConnect(start1, end_pos1, start2, end_pos2)
    return start1 < end_pos2 and end_pos1 > start2
end

--- 排序比较：先有效性，再 start，再 end。
function Range.compare(a, b)
    local av = Range.isValid(a.start, a.end_pos)
    local bv = Range.isValid(b.start, b.end_pos)
    if av ~= bv then
        return av -- 有效的排前面：返回 true 表示 a < b
    end
    if not av then
        return false
    end
    if a.start == b.start then
        return a.end_pos < b.end_pos
    end
    return a.start < b.start
end

return Range
