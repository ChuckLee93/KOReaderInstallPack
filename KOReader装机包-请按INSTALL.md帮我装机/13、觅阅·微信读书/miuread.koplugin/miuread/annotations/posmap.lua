--[[--
章节 HTML ↔ 纯文本位置映射（上传/定位用）

官方靠 ChapterIndex.posPair + txt2html/html2txt。
本模块在「坐标 HTML」（normalizeMarkup 后、划线/脚注注入前）上建简化映射：
  - 跳过标签字符
  - 不展开实体（与 Runes.extractText / 当前下载注入假设自洽）

索引约定（与 annotations 全包一致）：
  Lua 1-index 半开；runes[1] ↔ 官方 dataPos 0
  text_to_html[i] = 第 i 个可见字符对应的 HTML rune 下标

@module miuread.annotations.posmap
--]]--

local util = require("util")
local Range = require("miuread.annotations.range")
local Runes = require("miuread.annotations.runes")

local PosMap = {}

--- 从坐标 HTML 构建映射。
-- @string html coord_html（建议已 normalizeMarkup；本函数会剥 BOM）
-- @treturn table map
function PosMap.build(html)
    html = Runes.stripLeadingBOM(html or "")
    local runes = Runes.toRunes(html)
    local text_runes = {}
    local text_to_html = {}
    local html_to_text = {}

    local in_tag = false
    for i = 1, #runes do
        local r = runes[i]
        if r == "<" then
            in_tag = true
        elseif r == ">" then
            in_tag = false
        elseif not in_tag then
            local t = #text_runes + 1
            text_runes[t] = r
            text_to_html[t] = i
            html_to_text[i] = t
        end
    end

    local text = table.concat(text_runes)
    -- 归一化视图（空白不敏感定位用）：norm_text 删掉空白与想法星号，
    -- norm_map[i] = norm 流第 i 个字符在原 text_runes 中的下标。
    -- 星号是注入的 wr-star 产物，coord/选区里不应算字符；剥离后
    -- 选区（可能带 * 与换行）与 norm 流对齐。
    local norm_runes = {}
    local norm_map = {}         -- norm 字符序号 → 原 text_runes 下标
    local norm_byte_map = {}    -- norm 字节偏移 → norm 字符序号
    local norm_bytes = 1
    for i = 1, #text_runes do
        local r = text_runes[i]
        if not r:match("%s") and r ~= "*" then
            norm_runes[#norm_runes + 1] = r
            norm_map[#norm_runes] = i
            norm_byte_map[norm_bytes] = #norm_runes
            norm_bytes = norm_bytes + #r
        end
    end

    return {
        html = html,
        runes = runes,
        text_runes = text_runes,
        text = text,
        norm_text = table.concat(norm_runes),
        norm_map = norm_map,
        norm_byte_map = norm_byte_map,
        text_to_html = text_to_html,
        html_to_text = html_to_text,
    }
end

--- HTML 半开区间 → 文本半开区间（落在标签上的端点会收拢到相邻文本）。
function PosMap.htmlToText(map, html_start, html_end_pos)
    if not map or not Range.isValid(html_start, html_end_pos) then
        return nil
    end

    local text_start
    for i = html_start, html_end_pos - 1 do
        local t = map.html_to_text[i]
        if t then
            text_start = t
            break
        end
    end
    if not text_start then
        return nil
    end

    local text_end
    for i = html_end_pos - 1, html_start, -1 do
        local t = map.html_to_text[i]
        if t then
            text_end = t + 1
            break
        end
    end
    if not text_end or text_end <= text_start then
        return nil
    end
    return text_start, text_end
end

--- 文本半开区间 → HTML 半开区间。
function PosMap.textToHtml(map, text_start, text_end_pos)
    if not map or not Range.isValid(text_start, text_end_pos) then
        return nil
    end
    if text_end_pos - 1 > #map.text_runes then
        return nil
    end

    local html_start = map.text_to_html[text_start]
    local last = map.text_to_html[text_end_pos - 1]
    if not html_start or not last then
        return nil
    end
    return html_start, last + 1
end

--- 空白不敏感匹配：在去空白视图（norm_text/norm_map）上查找。
-- 解决 CREngine selected_text 的换行/空白与正文文本流（\r\n、多空格）
-- 不一致导致的 not_found。命中位置经 norm_map 映射回原 text_runes 下标。
-- @treturn table rune 下标列表（1-index）
local function findAllNorm(norm_text, norm_byte_map, norm_map, needle)
    local hits = {}
    if needle == nil or needle == "" or norm_text == nil or norm_text == "" then
        return hits
    end
    local stripped = needle:gsub("%s", ""):gsub("%*", "")
    if stripped == "" or #stripped > #norm_text then
        return hits
    end
    local from = 1
    while true do
        local i = norm_text:find(stripped, from, true)
        if not i then
            break
        end
        -- norm 字节位置 → norm 字符序号 → 原 rune 下标
        local idx = norm_byte_map[i]
        local rune_i = idx and norm_map[idx]
        if rune_i then
            hits[#hits + 1] = rune_i
        end
        from = i + 1
    end
    return hits
end

--- 删除所有空白字符（用于空白不敏感比较）。
local function stripWS(s)
    return (s:gsub("%s", ""))
end

--- 从命中 rune 起点解析出文本半开区间 [text_start, text_end_pos)。
-- 空白不敏感：needle 去空白后逐 rune 消费，允许中间夹空白 rune；
-- 返回区间去空白后必须等于 needle 去空白。
-- @tparam table map PosMap.build 结果
-- @int rune_i 命中起点（text_runes 下标）
-- @string mark_text
-- @treturn[1] int text_start
-- @treturn[1] int text_end_pos
-- @treturn[2] nil
local function resolveHitToSpan(map, rune_i, mark_text)
    local text_start = rune_i
    local needle_runes = Runes.toRunes(mark_text)
    local nclean = {}
    for i = 1, #needle_runes do
        local r = needle_runes[i]
        if not r:match("%s") and r ~= "*" then
            nclean[#nclean + 1] = r
        end
    end
    local consumed = 0
    local pos = text_start
    local last_consumed = text_start
    while consumed < #nclean and pos <= #map.text_runes do
        local r = map.text_runes[pos]
        if not r:match("%s") and r ~= "*" then
            if r == nclean[consumed + 1] then
                consumed = consumed + 1
                last_consumed = pos
            else
                return nil
            end
        end
        pos = pos + 1
    end
    if consumed ~= #nclean then
        return nil
    end
    -- 半开区间必须停在最后一个实际消费字符之后。
    -- 不再吞掉选区末尾之后的段间换行/缩进空白；否则段尾“开球。”这类
    -- 选区会被扩大到下一段之前，生成过长的服务端 range。
    local text_end_pos = last_consumed + 1
    local got = table.concat(map.text_runes, "", text_start, text_end_pos - 1)
    if stripWS(got):gsub("%*", "") ~= stripWS(mark_text):gsub("%*", "") then
        return nil
    end
    return text_start, text_end_pos
end

--- 命中消歧：hits 为原 text_runes 下标；context 用真实候选 span 两侧文本比较。
-- 旧实现用“去空白后的 needle 长度”估算 context_after 起点；当选区内部
-- 存在换行、多个空格或 wr-star 时，后文可能从选区内部开始。这里先对每个
-- candidate 调 resolveHitToSpan，得到真实 end_pos 后再比较上下文。
local function pickHit(hits, map, needle, context_before, context_after)
    if #hits == 0 then
        return nil
    end
    if #hits == 1 then
        return hits[1]
    end

    context_before = context_before or ""
    context_after = context_after or ""
    if context_before == "" and context_after == "" then
        return nil, "ambiguous"
    end

    local runes = map.text_runes
    local expect_b = context_before:gsub("%s", ""):gsub("%*", "")
    local expect_a = context_after:gsub("%s", ""):gsub("%*", "")
    local before_need = #Runes.toRunes(expect_b)
    local after_need = #Runes.toRunes(expect_a)
    local scored = {}

    for _, rune_i in ipairs(hits) do
        local _, text_end_pos = resolveHitToSpan(map, rune_i, needle)
        if text_end_pos then
            local before = {}
            local seen = 0
            local k = rune_i - 1
            while k >= 1 and seen < before_need do
                local r = runes[k]
                if not r:match("%s") and r ~= "*" then
                    table.insert(before, 1, r)
                    seen = seen + 1
                end
                k = k - 1
            end

            local after = {}
            seen = 0
            k = text_end_pos
            while k <= #runes and seen < after_need do
                local r = runes[k]
                if not r:match("%s") and r ~= "*" then
                    after[#after + 1] = r
                    seen = seen + 1
                end
                k = k + 1
            end

            local ok = true
            if expect_b ~= "" and table.concat(before) ~= expect_b then ok = false end
            if ok and expect_a ~= "" and table.concat(after) ~= expect_a then ok = false end
            if ok then scored[#scored + 1] = rune_i end
        end
    end

    if #scored == 1 then
        return scored[1]
    end
    return nil, "ambiguous"
end

--- 用 markText（+ 可选前后文）在坐标 HTML 上定位，返回上传可用的 range。
-- @tparam table map PosMap.build 结果
-- @string mark_text
-- @tparam[opt] table opts `{ context_before=, context_after=, page_review=false }`
-- @treturn[1] string range_str
-- @treturn[1] int html_start
-- @treturn[1] int html_end_pos
-- @treturn[2] nil, string err
function PosMap.locate(map, mark_text, opts)
    opts = opts or {}
    if not map or type(mark_text) ~= "string" then
        return nil, "invalid"
    end
    mark_text = util.trim(mark_text)
    if mark_text == "" then
        return nil, "empty"
    end

    -- 统一归一化匹配：norm 流（去空白+去 star）定位，命中映射回原 rune 下标
    local hits = findAllNorm(map.norm_text, map.norm_byte_map, map.norm_map, mark_text)
    local rune_i, err = pickHit(hits, map, mark_text, opts.context_before, opts.context_after)
    if not rune_i then
        return nil, err or "not_found"
    end

    local text_start, text_end_pos = resolveHitToSpan(map, rune_i, mark_text)
    if not text_start then
        return nil, "bad_align"
    end

    local html_start, html_end_pos = PosMap.textToHtml(map, text_start, text_end_pos)
    if not html_start then
        return nil, "map_fail"
    end

    local range_str = Range.encode(html_start, html_end_pos, opts.page_review == true)
    if not range_str then
        return nil, "encode_fail"
    end
    return range_str, html_start, html_end_pos
end


--- 便捷：直接对 HTML 定位（内部 build）。
function PosMap.locateInHtml(html, mark_text, opts)
    return PosMap.locate(PosMap.build(html), mark_text, opts)
end

-- ============================================================
-- 注入桥：coord_html（注入前）↔ 注入后 HTML（含 wr-star）
--
-- 注入对文本流的唯一修改是插入 `*`（想法星标）：
--   coord 文本流 = 注入后文本流 去掉所有 star 字符
-- 其余注入（wr-underline / wr-thought-link / wr-native）都是纯标签
-- 操作，不改变文本流。因此用 star 位置数组即可双向映射。
--
-- 约定（与 PosMap 全包一致）：位置均为 1-index 半开区间端点。
--   injectedToCoord(p) = p - (#stars < p)
--   coordToInjected(c) = c + (#stars < 目标位置)，不动点 + star 吸附
-- ============================================================

--- stars 升序；返回 stars 中 < p 的数量（二分）。
local function countStarsBefore(stars, p)
    local lo, hi = 1, #stars
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if stars[mid] < p then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return lo - 1
end

--- p 是否是 star 位置（二分）。
local function isStarAt(stars, p)
    local lo, hi = 1, #stars
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if stars[mid] == p then
            return true
        elseif stars[mid] < p then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return false
end

--- 构建注入桥。
--
-- 两种签名：
--   buildBridge(coord_html, injected_html, stars)   —— 有完整注入后 HTML
--   buildBridge(coord_html, stars)                  —— 无注入后 HTML，合成注入文本流
--
-- 合成依据：注入对文本流的唯一修改是插入 `*`（其余为纯标签操作），
-- 因此 injected 文本流 = coord 文本流 + 在 stars 位置插入 "*"。
-- locateInjected 对 injected map 只使用 text/text_runes（文本流），
-- 不依赖其 html↔text 映射，故合成流与原注入流定位等价。
--
-- @string coord_html  注入前（normalizeMarkup 后）
-- @string|table injected_or_stars 注入后 HTML，或 stars 表（合成模式）
-- @tparam[opt] table stars_opt 注入后文本流中 star 的 1-index 字符位置（升序）
-- @treturn table|nil bridge `{ coord=map, injected=map, stars=stars }`
function PosMap.buildBridge(coord_html, injected_or_stars, stars_opt)
    if type(coord_html) ~= "string" then
        return nil
    end
    local stars
    local injected
    if type(injected_or_stars) == "table" then
        -- 合成模式：只有 coord_html + stars
        stars = injected_or_stars or {}
        injected = PosMap.synthesizeInjected(coord_html, stars)
    else
        if type(injected_or_stars) ~= "string" then
            return nil
        end
        stars = stars_opt or {}
        injected = PosMap.build(injected_or_stars)
    end
    local prev = 0
    for i = 1, #stars do
        local s = stars[i]
        if type(s) ~= "number" or s <= prev then
            return nil
        end
        prev = s
    end
    if not injected then
        return nil
    end
    return {
        coord = PosMap.build(coord_html),
        injected = injected,
        stars = stars,
    }
end

--- 合成注入侧 map：coord 文本流 + 在 stars 位置插入 "*"。
-- 与原注入流逐字符等价（注入只对文本流插入星号）。
-- @string coord_html 注入前 HTML
-- @tparam table stars 注入后文本流中 star 的 1-index 字符位置（升序）
-- @treturn table|nil 合成 map（text/text_runes 可用，html 映射为空）
function PosMap.synthesizeInjected(coord_html, stars)
    local coord_map = PosMap.build(coord_html)
    local coord_runes = coord_map.text_runes
    stars = stars or {}
    local star_i = 1
    local out = {}
    local out_len = 0
    for i = 1, #coord_runes do
        while star_i <= #stars and stars[star_i] == out_len + 1 do
            out[#out + 1] = "*"
            out_len = out_len + 1
            star_i = star_i + 1
        end
        out[#out + 1] = coord_runes[i]
        out_len = out_len + 1
    end
    while star_i <= #stars and stars[star_i] == out_len + 1 do
        out[#out + 1] = "*"
        out_len = out_len + 1
        star_i = star_i + 1
    end
    local out_text = table.concat(out)
    local norm_runes = {}
    local norm_map = {}
    local norm_byte_map = {}
    local norm_bytes = 1
    for i = 1, #out do
        local r = out[i]
        if not r:match("%s") and r ~= "*" then
            norm_runes[#norm_runes + 1] = r
            norm_map[#norm_runes] = i
            norm_byte_map[norm_bytes] = #norm_runes
            norm_bytes = norm_bytes + #r
        end
    end
    return {
        text_runes = out,
        text = out_text,
        norm_text = table.concat(norm_runes),
        norm_map = norm_map,
        norm_byte_map = norm_byte_map,
        text_to_html = {},
        html_to_text = {},
    }
end

--- 注入后文本位置 → coord 文本位置（1-index，star 位置映射到后一字符）。
function PosMap.injectedToCoord(bridge, p)
    return p - countStarsBefore(bridge.stars, p)
end

--- coord 文本位置 → 注入后文本位置。
-- 不动点：p = c + countStarsBefore(stars, p)；若 p 落在 star 上则 +1。
function PosMap.coordToInjected(bridge, c)
    local p = c
    while true do
        local np = c + countStarsBefore(bridge.stars, p)
        if np == p then
            break
        end
        p = np
    end
    if isStarAt(bridge.stars, p) then
        p = p + 1
    end
    return p
end

--- 注入后半开区间 → coord 半开区间。
function PosMap.injectedToCoordText(bridge, is, ie)
    return PosMap.injectedToCoord(bridge, is), PosMap.injectedToCoord(bridge, ie)
end

--- coord 半开区间 → 注入后半开区间。
function PosMap.coordToInjectedText(bridge, cs, ce)
    return PosMap.coordToInjected(bridge, cs), PosMap.coordToInjected(bridge, ce)
end

--- 在注入后文本流中定位 mark_text（可能含想法星号），返回 coord range。
-- 与 locate 的差别：文本流含注入的 `*`，选区若带上星号也能命中；
-- 命中后经 star 桥映射回 coord 坐标系，Range.encode 以 coord 为准。
-- @tparam table bridge PosMap.buildBridge 结果
-- @string mark_text 用户选区文本（可能含 `*`）
-- @tparam[opt] table opts `{ context_before=, context_after=, page_review=false }`
-- @treturn[1] string range_str
-- @treturn[1] int coord_html_start
-- @treturn[1] int coord_html_end_pos
-- @treturn[2] nil, string err
function PosMap.locateInjected(bridge, mark_text, opts)
    opts = opts or {}
    if not bridge or type(mark_text) ~= "string" then
        return nil, "invalid"
    end
    mark_text = util.trim(mark_text)
    if mark_text == "" then
        return nil, "empty"
    end

    local injected = bridge.injected
    local hits = findAllNorm(injected.norm_text, injected.norm_byte_map, injected.norm_map, mark_text)
    local rune_i, err = pickHit(hits, injected, mark_text, opts.context_before, opts.context_after)
    if not rune_i then
        return nil, err or "not_found"
    end

    local is, ie = resolveHitToSpan(injected, rune_i, mark_text)
    if not is then
        return nil, "bad_align"
    end

    -- 星号桥：注入后区间 → coord 区间 → coord HTML range
    local cs, ce = PosMap.injectedToCoordText(bridge, is, ie)
    if not Range.isValid(cs, ce) or ce - 1 > #bridge.coord.text_runes then
        return nil, "bridge_fail"
    end

    local html_start, html_end_pos = PosMap.textToHtml(bridge.coord, cs, ce)
    if not html_start then
        return nil, "map_fail"
    end
    local range_str = Range.encode(html_start, html_end_pos, opts.page_review == true)
    if not range_str then
        return nil, "encode_fail"
    end
    return range_str, html_start, html_end_pos
end

--- 便捷：coord_html + injected_html + stars 直接定位。
function PosMap.locateInjectedInHtml(coord_html, injected_html, stars, mark_text, opts)
    return PosMap.locateInjected(
        PosMap.buildBridge(coord_html, injected_html, stars), mark_text, opts
    )
end

--- range → 文本半开区间（先 parse，再映射到可见字符）。
function PosMap.rangeToTextSpan(map, range_str)
    local html_start, html_end_pos = Range.parse(range_str)
    if not Range.isValid(html_start, html_end_pos) then
        return nil
    end
    return PosMap.htmlToText(map, html_start, html_end_pos)
end


-- Build the exact text stream shown after MiuRead converts image footnote
-- markers into [N]. Unlike the old annotation fallback, this preserves a
-- one-to-one positional relationship: only an actual footnote <img> tag may
-- create a removable [N] token.
local function isImageFootnoteTag(raw)
    local lower = tostring(raw or ""):lower()
    if not lower:match("^<%s*img[%s>/]") then return false end
    return lower:find("qqreader-footnote", 1, true) ~= nil
        or lower:find("footnote-icon", 1, true) ~= nil
        or lower:find("footnote-ref", 1, true) ~= nil
        or lower:find("note-ref", 1, true) ~= nil
end

local function textMapFromRunes(runes)
    local norm_runes = {}
    local norm_map = {}
    local norm_byte_map = {}
    local norm_bytes = 1
    for i = 1, #runes do
        local r = runes[i]
        if not r:match("%s") and r ~= "*" then
            norm_runes[#norm_runes + 1] = r
            norm_map[#norm_runes] = i
            norm_byte_map[norm_bytes] = #norm_runes
            norm_bytes = norm_bytes + #r
        end
    end
    return {
        text_runes = runes,
        text = table.concat(runes),
        norm_text = table.concat(norm_runes),
        norm_map = norm_map,
        norm_byte_map = norm_byte_map,
        text_to_html = {},
        html_to_text = {},
    }
end

--- Build a display bridge for image footnotes.
-- The returned display stream is coord text plus [1], [2]... inserted exactly
-- where qqreader/footnote image tags occur. `display_to_coord[i]` is nil for
-- those synthetic digits and points to the original coord text rune otherwise.
function PosMap.buildFootnoteDisplayBridge(coord_html)
    if type(coord_html) ~= "string" or coord_html == "" then return nil end
    local coord = PosMap.build(coord_html)
    local html_runes = coord.runes or {}
    local display_runes, display_to_coord = {}, {}
    local coord_text_i, footnote_i = 0, 0
    local i = 1
    while i <= #html_runes do
        local r = html_runes[i]
        if r == "<" then
            local j = i
            while j <= #html_runes and html_runes[j] ~= ">" do j = j + 1 end
            if j > #html_runes then break end
            local raw = table.concat(html_runes, "", i, j)
            if isImageFootnoteTag(raw) then
                footnote_i = footnote_i + 1
                local token_runes = Runes.toRunes("[" .. tostring(footnote_i) .. "]")
                for _, token in ipairs(token_runes) do
                    display_runes[#display_runes + 1] = token
                    -- Synthetic token: deliberately no coord mapping.
                    display_to_coord[#display_runes] = false
                end
            end
            i = j + 1
        else
            coord_text_i = coord_text_i + 1
            display_runes[#display_runes + 1] = r
            display_to_coord[#display_runes] = coord_text_i
            i = i + 1
        end
    end
    if footnote_i == 0 then return nil end
    return {
        coord = coord,
        display = textMapFromRunes(display_runes),
        display_to_coord = display_to_coord,
        footnotes = footnote_i,
    }
end

--- Locate KOReader text in the exact footnote-display stream and return a range
-- in the original coord HTML. Synthetic [N] runes are never converted into
-- source coordinates, so genuine prose such as a literal "[6]" remains data.
function PosMap.locateFootnoteDisplay(bridge, mark_text, opts)
    opts = opts or {}
    if not bridge or type(mark_text) ~= "string" then return nil, "invalid" end
    mark_text = util.trim(mark_text)
    if mark_text == "" then return nil, "empty" end

    local display = bridge.display
    local hits = findAllNorm(display.norm_text, display.norm_byte_map, display.norm_map, mark_text)
    local rune_i, err = pickHit(hits, display, mark_text, opts.context_before, opts.context_after)
    if not rune_i then return nil, err or "not_found" end
    local ds, de = resolveHitToSpan(display, rune_i, mark_text)
    if not ds then return nil, "bad_align" end

    local cs, last
    for pos = ds, de - 1 do
        local mapped = bridge.display_to_coord[pos]
        if type(mapped) == "number" then
            cs = cs or mapped
            last = mapped
        end
    end
    if not cs or not last or last < cs then return nil, "synthetic_only" end
    local ce = last + 1
    if not Range.isValid(cs, ce) or ce - 1 > #bridge.coord.text_runes then
        return nil, "bridge_fail"
    end
    local html_start, html_end_pos = PosMap.textToHtml(bridge.coord, cs, ce)
    if not html_start then return nil, "map_fail" end
    local range_str = Range.encode(html_start, html_end_pos, opts.page_review == true)
    if not range_str then return nil, "encode_fail" end
    return range_str, html_start, html_end_pos, {
        display_start=ds, display_end_pos=de,
        display_text=table.concat(display.text_runes, "", ds, de - 1),
        source_text=table.concat(bridge.coord.text_runes, "", cs, ce - 1),
        footnotes=bridge.footnotes,
    }
end

return PosMap
