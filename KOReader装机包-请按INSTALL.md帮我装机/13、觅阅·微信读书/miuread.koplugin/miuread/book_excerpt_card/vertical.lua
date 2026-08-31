--[[--
竖排标题（墨白/静影/锦书页眉）
标题按字数分列,中文竖排正立、英文/数字 90° 横躺、竖排引号替换。

@module koplugin.miuread.book_excerpt_card.vertical
--]]--

local Config = require("miuread.book_excerpt_card.config")
local Fonts = require("miuread.book_excerpt_card.fonts")
local Text = require("miuread.book_excerpt_card.text")
local Assets = require("miuread.book_excerpt_card.assets")
local Runes = require("miuread.book_excerpt_card.runes")
local RenderText = require("ui/rendertext")
local util = require("util")

local ds = Config.ds
local safeGetFace = Fonts.safeGetFace
local dateToChinese = Text.dateToChinese
local drawLineImage = Assets.drawLineImage

--- 标题分列规则:按标题字数返回每列字数，-1 = 剩余全部。
-- 真实截图(6 字标题)确认竖排标题为单列;
-- 分列仅用于更长标题(-1 = 剩余全部)。
local function breakLineRule(template_id, n)
    if n <= 9 then return { -1 } end -- 短标题一律单列(真实截图行为)
    if template_id == "inkwhite" then
        return { 5, -1 }
    elseif template_id == "stillness" then
        return { 3, 3, -1 }
    else -- ornate
        return { 3, 3, -1 }
    end
end

--- 按分列规则把标题切成多列（超长/无规则时整串单列）。
local function splitTitleColumns(title, rule_arr)
    local runes = Runes.toRunes(title)
    local n = #runes
    if n == 0 then return { "" } end
    if #rule_arr == 0 then return { title } end
    local cols = {}
    local pos = 1
    for _, cnt in ipairs(rule_arr) do
        local len = (cnt == -1) and (n - pos + 1) or cnt
        if len > 0 and pos <= n then
            cols[#cols + 1] = table.concat(runes, "", pos, pos + len - 1)
            pos = pos + len
        end
    end
    if #cols == 0 then cols[1] = title end
    return cols
end

--- 是否英文/数字（竖排时需 90° 横躺）。
local function isLatinChar(ch)
    return ch:match("^[A-Za-z0-9]$") ~= nil
end

-- 竖排标点集合:这些标点竖排时旋转 90°。
-- ". _ : | , ? … % ! < > 《 》 [ ] 【 】 { } 『 』 ( ) （ ） - – —"
local VERTICAL_ROTATE_PUNCT = "._:|,?\226\128\166%!<>\227\128\138\227\128\139[]\227\128\144\227\128\145{}\227\128\140\227\128\141()\239\188\136\239\188\137-\226\128\147\226\128\148"

--- 竖排需 90° 旋转的字符:西文/数字 或 竖排标点集合。
local function isVerticalRotateChar(ch)
    if isLatinChar(ch) then return true end
    return VERTICAL_ROTATE_PUNCT:find(ch, 1, true) ~= nil
end

--- 竖排引号替换:横排引号 → 竖排引号字形。
local function verticalQuote(ch)
    if ch == "\xE2\x80\x9C" then return "\xEF\xB9\x83"      -- “ → ﹃
    elseif ch == "\xE2\x80\x9D" then return "\xEF\xB9\x84"  -- ” → ﹄
    elseif ch == "\xE2\x80\x98" then return "\xEF\xB9\x81"  -- ‘ → ﹁
    elseif ch == "\xE2\x80\x99" then return "\xEF\xB9\x82"  -- ’ → ﹂
    else return ch end
end

--- 竖排单字符 90° 旋转(拉丁字母/竖排标点用,支持多字节 UTF-8)。
--- 直接用字形 glyph.bb(灰度 alpha) rotatedCopy(270) → colorblitFromRGB32 染色,
--- 与正文 glyph 染色路径完全一致,保证颜色统一(避免临时 BB 渲染导致浅色)。
--- 字符从行盒顶部(cur)开始,顶部对齐所有列首字符;步进 = 旋转后高度(rh)。
local function drawRotatedCharVert(bb, cx, cur, face, ch, fg_color, char_h)
    local charcode = ch:byte()
    local glyph = RenderText:getGlyph(face, charcode, false)
    if not glyph or not glyph.bb then return char_h end
    local rbb = glyph.bb:rotatedCopy(270)
    local rw, rh = rbb:getWidth(), rbb:getHeight()
    bb:colorblitFromRGB32(rbb, cx - math.floor(rw / 2),
        cur, 0, 0, rw, rh, fg_color)
    rbb:free()
    return math.max(rh, 1)
end

--- 竖排列宽（max：中文取字宽，旋转字符取字形高度）。
local function measureVerticalColumn(face, col_text, char_h)
    local max_w = 0
    for _, ch in ipairs(Runes.toRunes(col_text)) do
        local ch_q = verticalQuote(ch)
        if isVerticalRotateChar(ch_q) then
            local glyph = RenderText:getGlyph(face, ch_q:byte(), false)
            if glyph and glyph.bb then
                max_w = math.max(max_w, glyph.bb:getHeight())
            end
        else
            local w = RenderText:sizeUtf8Text(0, nil, face, ch_q, false, false).x
            max_w = math.max(max_w, w)
        end
    end
    return max_w
end

--- 渲染单列竖排文本，返回列高。
-- @param step 字符垂直步进(墨白标题=行高 35;其余=字形高度紧凑排列)
local function renderVerticalColumn(bb, cx, cy, face, col_text, char_h, fg_color, step)
    local fh, ascender = face.ftsize:getHeightAndAscender()
    local cur = cy
    local runes = Runes.toRunes(col_text)
    local i = 1
    while i <= #runes do
        local ch_q = verticalQuote(runes[i])
        if isLatinChar(ch_q) then
            -- 拉丁字符逐字符 90° 横躺,按字形实际高度紧凑排列(非固定行盒)
            cur = cur + drawRotatedCharVert(bb, cx, cur, face, ch_q, fg_color, char_h)
            i = i + 1
        elseif isVerticalRotateChar(ch_q) then
            -- 竖排标点(含方括号 [] 等):单字符 90° 旋转
            cur = cur + drawRotatedCharVert(bb, cx, cur, face, ch_q, fg_color, char_h)
            i = i + 1
        else
            -- 中文竖排:步进 = 列配置 step(墨白标题行高 35 / 其余字形高)
            local w = RenderText:sizeUtf8Text(0, nil, face, ch_q, false, false).x
            RenderText:renderUtf8Text(bb, cx - math.floor(w / 2),
                cur + math.floor(ascender), face, ch_q, false, false, fg_color)
            cur = cur + (step or math.floor(fh))
            i = i + 1
        end
    end
    return cur - cy
end

--- 构建竖排列（标题分列 + 作者 + 日期），共享给高度计算与渲染。
local function buildVerticalColumns(parts, template, font_name)
    local title_size = template.vertical_title_size or 30
    local title_line_h = ds(template.vertical_title_line_h or 35)
    local author_size = template.vertical_author_size or 13
    local author_line_h = ds(template.vertical_author_line_h or 16)
    local author_face = safeGetFace(font_name, author_size, template.font)

    local function clipRunes(s, maxn)
        local runes = Runes.toRunes(s)
        if #runes <= maxn then return s end
        return table.concat(runes, "", 1, maxn)
    end
    -- 标题最多 18 字 / 作者最多 12 词
    -- 注意:作者限制按「词」计(逐词分列),不能整段截断
    -- (整段截断会把 "[韩]sing N song" 切成 "[韩]sing N so",末词被砍)
    local title = clipRunes(parts[1] or "", 18)
    local author = parts[2] or ""
    -- 墨白: parts[3]=动作列(「摘录于」), parts[4]=日期;其他模板: parts[3]=日期
    local action, date
    if template.id == "inkwhite" then
        action = (parts[3] or ""):gsub("^%s+", ""):gsub("%s+$", "")
        date = parts[4] and dateToChinese(parts[4]) or ""
    else
        date = parts[3] and dateToChinese(parts[3]) or ""
    end

    -- 静影:中文 26/40，无中文 32/40
    if template.id == "stillness" and not title:find("[\228-\233]") then
        title_size = 32
        title_line_h = ds(40)
    end
    local title_face = safeGetFace(font_name, title_size, template.font)
    -- 每字符垂直步进:字形实际高度(紧凑排列)
    local function stepOf(face)
        local fh = face and face.ftsize and face.ftsize:getHeightAndAscender() or 0
        return math.max(1, math.floor(fh))
    end

    local cols = {}
    if title ~= "" then
        -- 墨白标题字符步进 = 行高 35(非字形高度);
        -- 其余模板保持字形高度(紧凑)
        local title_step = (template.id == "inkwhite") and title_line_h or stepOf(title_face)
        for _, col in ipairs(splitTitleColumns(title, breakLineRule(template.id, #Runes.toRunes(title)))) do
            cols[#cols + 1] = { text = col, face = title_face, char_h = title_line_h, step = title_step }
        end
    end
    if author ~= "" then
        -- 英文/数字按词分列,中文连续
        for _, word in ipairs(util.splitToArray(author, " ")) do
            if word ~= "" then
                cols[#cols + 1] = { text = word, face = author_face, char_h = author_line_h, step = stepOf(author_face) }
            end
        end
    end
    if action and action ~= "" then
        cols[#cols + 1] = { text = action, face = author_face, char_h = author_line_h, step = stepOf(author_face) }
    end
    if date ~= "" then
        cols[#cols + 1] = { text = date, face = author_face, char_h = author_line_h, step = stepOf(author_face) }
    end
    return cols
end

--- 竖排标题总高：列高 + 竖线上下留白；墨白竖线固定高 226。
local function verticalTitleHeight(parts, template, font_name)
    local cols = buildVerticalColumns(parts, template, font_name)
    local max_h = 0
    for _, c in ipairs(cols) do
        max_h = math.max(max_h, #Runes.toRunes(c.text) * (c.step or c.char_h))
    end
    local vline_pad = ds(template.vertical_vline_pad or 24)
    local box = max_h + 2 * vline_pad
    if template.vertical_box_h then
        -- 墨白:竖线固定 226,标题可高于竖线;
        -- 页眉总高 = max(标题高, 226) + 容器下留白(36)
        box = math.max(max_h, ds(template.vertical_box_h))
            + ds(template.vertical_header_gap or 36)
    end
    return box
end

--- 渲染竖排标题（标题分列 + 作者 + 日期 多列横排）+ 左右竖线。
-- 返回竖排内容总高。
-- @param deco_color 装饰竖线色(墨白=纯主题色)
-- @param vline_color 墨白右侧装饰列竖线色(icon_line_left 图片透明度低,≈主题色 15%)
local function renderVerticalTitle(bb, x, y, content_w, font_name, parts, fg_color, dim_color, template, deco_color, vline_color)
    local cols = buildVerticalColumns(parts, template, font_name)
    local text_h = 0
    for _, c in ipairs(cols) do
        text_h = math.max(text_h, #Runes.toRunes(c.text) * (c.step or c.char_h))
    end
    local vline_pad = ds(template.vertical_vline_pad or 24)
    local box_h = text_h + 2 * vline_pad
    if template.vertical_box_h then
        -- 墨白竖线固定高 226(不随标题伸缩);
        -- 标题在其中垂直居中(标题高于 226 时顶部对齐)
        local vline_h = ds(template.vertical_box_h)
        vline_pad = math.max(0, math.floor((vline_h - text_h) / 2))
        box_h = math.max(text_h, vline_h)
    end

    local col_gap = ds(template.id == "inkwhite" and 12 or 10)
    local widths = {}
    for idx, c in ipairs(cols) do
        local w = measureVerticalColumn(c.face, c.text, c.char_h)
        widths[idx] = w
    end

    local vline_w = ds(3)
    -- 竖线固定高 226(不随标题长度伸缩)
    local vline_len = template.vertical_box_h
        and ds(template.vertical_box_h) or box_h
    deco_color = deco_color or dim_color
    vline_color = vline_color or deco_color

    if template.id == "inkwhite" then
        -- 墨白:左侧大标题(书名 32/35)+ 小字作者,
        -- 右侧装饰列 = 竖线 + 「摘录于」动作 + 竖线 + 中文日期 + 竖线
        -- (昵称留空,动作列直接显示「摘录于」;竖线 3x226, 中间线间距 8/9)
        local cx = x
        local deco_n = 2 -- 最后两列 = 动作 + 日期(右侧装饰列)
        local main_n = #cols - deco_n
        for idx = 1, main_n do
            renderVerticalColumn(bb, cx + math.floor(widths[idx] / 2), y + vline_pad,
                cols[idx].face, cols[idx].text, cols[idx].char_h, fg_color, cols[idx].step)
            cx = cx + widths[idx] + col_gap
        end
        -- 右侧装饰列:贴内容右缘,从右往左排:竖线(8) → 日期 → 竖线(9/8) → 动作 → 竖线
        if main_n >= 1 then
            local a, d = cols[main_n + 1], cols[main_n + 2]
            local aw, dw = widths[main_n + 1], widths[main_n + 2]
            local line_gap = ds(8)
            local right_edge = x + content_w
            local x3 = right_edge - line_gap - vline_w                       -- 最右竖线
            -- 边缘竖线为 icon_line_left/right 图片(alpha≈0.2 半透明,带渐变纹理)
            if template.id ~= "inkwhite"
                or not drawLineImage(bb, x3, y, "icon_line_right", vline_w, vline_len, fg_color) then
                bb:paintRectRGB32(x3, y, vline_w, vline_len, vline_color)
            end
            local xd = x3 - line_gap - vline_w - dw                            -- 日期列
            renderVerticalColumn(bb, xd + math.floor(dw / 2), y + vline_pad,
                d.face, d.text, d.char_h, dim_color, d.step)
            local x2 = xd - line_gap - vline_w                                -- 中间竖线
            if template.id ~= "inkwhite"
                or not drawLineImage(bb, x2, y, "icon_line_middle", vline_w, vline_len, fg_color) then
                bb:paintRectRGB32(x2, y, vline_w, vline_len, vline_color)
            end
            local xa = x2 - line_gap - vline_w - aw                            -- 动作列
            renderVerticalColumn(bb, xa + math.floor(aw / 2), y + vline_pad,
                a.face, a.text, a.char_h, dim_color, a.step)
            if template.id ~= "inkwhite"
                or not drawLineImage(bb, xa - line_gap - vline_w, y, "icon_line_left", vline_w, vline_len, fg_color) then
                bb:paintRectRGB32(xa - line_gap - vline_w, y, vline_w, vline_len, vline_color) -- 最左竖线
            end
        end
    else
        -- 静影/锦书:标题左对齐 + 作者小字竖列于右侧(顶端对齐),无竖线
        local cx = x
        for idx, c in ipairs(cols) do
            renderVerticalColumn(bb, cx + math.floor(widths[idx] / 2), y + vline_pad,
                c.face, c.text, c.char_h, fg_color, c.step)
            cx = cx + widths[idx] + col_gap
        end
    end
    return box_h
end

return {
    verticalTitleHeight = verticalTitleHeight,
    renderVerticalTitle = renderVerticalTitle,
}
