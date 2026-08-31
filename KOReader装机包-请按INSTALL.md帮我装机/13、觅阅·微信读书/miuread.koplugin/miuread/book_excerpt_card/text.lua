--[[--
文本处理：手动换行（kinsoku 避头尾 + justify 分配）/ 日期格式化。

@module koplugin.miuread.book_excerpt_card.text
--]]--

local Runes = require("miuread.book_excerpt_card.runes")
local RenderText = require("ui/rendertext")
local util = require("util")

-- ---------------------------------------------------------------------------
-- 文本排版（RenderText 手动换行，RGB32 上彩色渲染）
-- ---------------------------------------------------------------------------

--- 按段落换行：先按 \n 分段（每段 trim、空段跳过），
-- 段内再用 getSubTextByWidth 循环切行（UTF-8 安全）。
-- 返回 lines（字符串数组）与 line_is_end（对应行是否为段落末行，供 justify 末行左对齐）。
-- 中文避头尾：行首不放收尾标点，行尾不放开引号。
local KINSOKU_NO_START = {
    ["，"]=true, ["。"]=true, ["、"]=true, ["；"]=true, ["："]=true,
    ["！"]=true, ["？"]=true, ["」"]=true, ["』"]=true, ["》"]=true,
    ["】"]=true, ["）"]=true, ["…"]=true, ["—"]=true,
    [","]=true, ["."]=true, [";"]=true, [":"]=true, ["!"]=true, ["?"]=true,
    [")"]=true, ["]"]=true, ["}"]=true,
    ["\xE2\x80\x9D"]=true, -- ”
    ["\xE2\x80\x99"]=true, -- ’
}
local KINSOKU_NO_END = {
    ["「"]=true, ["『"]=true, ["《"]=true, ["【"]=true, ["（"]=true,
    ["("]=true, ["["]=true, ["{"]=true,
    ["\xE2\x80\x9C"]=true, -- “
    ["\xE2\x80\x98"]=true, -- ‘
}

local function applyKinsoku(line, rest)
    local line_r = Runes.toRunes(line)
    local rest_r = Runes.toRunes(rest)
    while #rest_r > 0 and KINSOKU_NO_START[rest_r[1]] do
        line_r[#line_r + 1] = table.remove(rest_r, 1)
    end
    while #line_r > 1 and KINSOKU_NO_END[line_r[#line_r]] do
        table.insert(rest_r, 1, line_r[#line_r])
        line_r[#line_r] = nil
    end
    if #line_r == 0 then
        return line, rest
    end
    return table.concat(line_r), table.concat(rest_r)
end

local function wrapText(text, face, width, kerning, bold)
    local lines = {}
    local line_is_end = {}
    local function push_para(para)
        para = para:gsub("^%s+", ""):gsub("%s+$", "")
        if para == "" then return end
        local rest = para
        local plines = {}
        while rest ~= "" do
            local line = RenderText:getSubTextByWidth(rest, face, width, kerning, bold)
            if line == "" then
                -- 单字符也放不下（罕见）：强制取一个字符，避免死循环
                local chars = util.splitToChars(rest)
                local ch = chars[1] or rest
                plines[#plines + 1] = ch
                rest = rest:sub(#ch + 1)
            else
                local leftover = rest:sub(#line + 1)
                line, leftover = applyKinsoku(line, leftover)
                plines[#plines + 1] = line
                rest = leftover
            end
        end
        for i, ln in ipairs(plines) do
            lines[#lines + 1] = ln
            line_is_end[#lines] = (i == #plines)
        end
    end
    for para in text:gmatch("[^\n]*") do
        push_para(para)
    end
    return lines, line_is_end
end

--- 计算 justify 的 char_pads：把 extra 像素均匀分配到字符间隙（前 rem 个间隙各多 1）。
-- char_pads[i] 表示第 i 个字符之后追加的像素；末字符位无后续字符，无需填写。
local function justifyCharPads(line, extra)
    local n = #Runes.toRunes(line)
    if n <= 1 or extra <= 0 then return nil end
    local pads = {}
    local gaps = n - 1
    local base = math.floor(extra / gaps)
    local rem = extra - base * gaps
    for i = 1, gaps do
        pads[i] = base + ((i <= rem) and 1 or 0)
    end
    return pads
end

--- 渲染多行文本，返回结束后的 baseline。
-- @param align "left" | "center" | "right" | "justify"
-- @param justify_flags[opt] 数组：line 是否为段落末行（末行左对齐不拉伸）
-- @param para_gap[opt] 段落后额外间距
local function renderLines(bb, x_start, baseline, face, lines, line_height_px,
                          fgcolor, width, align, justify_flags, para_gap, bold)
    para_gap = para_gap or 0
    for i, line in ipairs(lines) do
        local line_w = RenderText:sizeUtf8Text(0, width, face, line, false, bold).x
        if align == "justify" then
            local pads = nil
            local is_end = justify_flags and justify_flags[i]
            if not is_end then
                pads = justifyCharPads(line, width - line_w)
            end
            RenderText:renderUtf8Text(bb, x_start, baseline, face, line, false, bold, fgcolor, width, pads)
        else
            local x = x_start
            if align == "center" then
                x = x_start + math.floor((width - line_w) / 2)
            elseif align == "right" then
                x = x_start + math.max(0, width - line_w)
            end
            RenderText:renderUtf8Text(bb, x, baseline, face, line, false, bold, fgcolor, width)
        end
        baseline = baseline + line_height_px
        if para_gap > 0 and justify_flags and justify_flags[i] then
            baseline = baseline + para_gap
        end
    end
    return baseline
end

--- 测量多行文本高度（wrap 后；含段距）。
local function wrapHeight(lines, line_height_px, line_is_end, para_gap)
    local h = #lines * line_height_px
    if para_gap and para_gap > 0 and line_is_end then
        for i = 1, #lines do
            if line_is_end[i] then
                h = h + para_gap
            end
        end
    end
    return h
end

-- ---------------------------------------------------------------------------
-- 日期 / 中文数字
-- ---------------------------------------------------------------------------

-- 汉字数字:年份逐位、月日按 十/廿 规则
local CN_NUM = { "〇", "一", "二", "三", "四", "五", "六", "七", "八", "九" }
local function cnYear(n)
    return tostring(n):gsub("%d", function(d) return CN_NUM[tonumber(d) + 1] end)
end
local function cnNum(n)
    if n < 10 then return CN_NUM[n + 1] end
    local t, u = math.floor(n / 10), n % 10
    if n < 20 then return "十" .. (u > 0 and CN_NUM[u + 1] or "") end
    return CN_NUM[t + 1] .. "十" .. (u > 0 and CN_NUM[u + 1] or "")
end
--- "2026/8/13" → "二〇二六年·八月·十三日"
local function dateToChinese(date_str, sep)
    sep = sep or "·"
    local y, m, d = tostring(date_str or ""):match("(%d+)/(%d+)/(%d+)")
    if not y then return date_str or "" end
    return cnYear(tonumber(y)) .. "年" .. sep .. cnNum(tonumber(m)) .. "月" .. sep
        .. cnNum(tonumber(d)) .. "日"
end

--- 任意常见日期输入 → "YYYY/M/D"（年 4 位、月日不补零、斜杠分隔，如 "2026/8/13"）。
-- 接受 "2026-08-13" / "2026/8/13" / "2026年8月13日" / "2026.8.13" / 时间戳。
local function formatDateSlash(date_str)
    if type(date_str) ~= "string" then
        local t = os.date("*t", date_str or os.time())
        return string.format("%d/%d/%d", t.year, t.month, t.day)
    end
    local y, m, d = tostring(date_str):match("(%d+)[%/%-.%s](%d+)[%/%-.%s](%d+)")
    if y then
        return string.format("%d/%d/%d", tonumber(y), tonumber(m), tonumber(d))
    end
    local t = os.date("*t", tonumber(date_str) or os.time())
    return string.format("%d/%d/%d", t.year, t.month, t.day)
end

return {
    wrapText = wrapText,
    justifyCharPads = justifyCharPads,
    renderLines = renderLines,
    wrapHeight = wrapHeight,
    dateToChinese = dateToChinese,
    formatDateSlash = formatDateSlash,
}
