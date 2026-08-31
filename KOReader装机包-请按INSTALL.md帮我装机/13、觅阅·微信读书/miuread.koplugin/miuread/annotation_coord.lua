--[[--
MiuRead 批注坐标统一入口。

这里故意把“坐标 HTML 的来源”与 PosMap/Range 分开：
- 章节解码完成后的完整 XHTML（仅去 UTF-8 BOM）就是 coord_html。
- 不裁剪 body，不折叠空白，不改写实体/资源 URL，避免改变服务端字符坐标。
- 2026-08 真机诊断已用微信读书现有 range 对齐：完整 raw XHTML 与服务端坐标一致；
  body-inner 会丢失 head/body 前缀并造成整体前移。
--]]--

local PosMap = require("miuread.annotations.posmap")
local Range = require("miuread.annotations.range")
local Runes = require("miuread.annotations.runes")

local Coord = {}

--- 章节解码结果 -> 服务端坐标 HTML。
-- 关键约束：保留完整 XHTML，只剥离 UTF-8 BOM。
-- 不能使用 Codec.body()，否则每章都会丢失长度不固定的 XML/head/body 前缀。
function Coord.fromDownloadedXhtml(xhtml)
    return Runes.stripLeadingBOM(tostring(xhtml or ""))
end

function Coord.build(coord_html)
    return PosMap.build(Coord.fromDownloadedXhtml(coord_html))
end

local function slice(runes, first, last)
    if first > last then return "" end
    return table.concat(runes, "", first, last)
end

--- 服务端 range -> coord 文本区间与原始文本。
-- 返回的 html/text 坐标全部使用 Lua 1-index 半开区间。
function Coord.resolveRangeOnMap(map, range_str)
    if type(map) ~= "table" then return nil, "invalid_map" end
    local html_start, html_end_pos, point = Range.parse(tostring(range_str or ""))
    if not html_start then return nil, "invalid_range" end
    if html_end_pos - 1 > #(map.runes or {}) then return nil, "range_out_of_bounds" end

    local text_start, text_end_pos = PosMap.htmlToText(map, html_start, html_end_pos)
    if not text_start then return nil, "range_has_no_text" end

    return {
        map = map,
        html_start = html_start,
        html_end_pos = html_end_pos,
        text_start = text_start,
        text_end_pos = text_end_pos,
        text = slice(map.text_runes, text_start, text_end_pos - 1),
        point = point == true,
    }
end

function Coord.resolveRange(coord_html, range_str)
    return Coord.resolveRangeOnMap(Coord.build(coord_html), range_str)
end

--- 从已知区间生成短前后文，用于重复文本 round-trip 消歧。
function Coord.contextForSpan(map, text_start, text_end_pos, width)
    if not map or not text_start or not text_end_pos then return "", "" end
    width = math.max(0, math.floor(tonumber(width) or 24))
    local before_start = math.max(1, text_start - width)
    local after_end = math.min(#map.text_runes, text_end_pos + width - 1)
    return slice(map.text_runes, before_start, text_start - 1),
        slice(map.text_runes, text_end_pos, after_end)
end

--- 真实服务端 range -> text -> range 闭环检查。
-- `ok=false` 仅作为诊断，不会改变现有云端批注显示；上传路径可把它作为硬门槛。
function Coord.roundTrip(coord_html, range_str)
    local resolved, err = Coord.resolveRange(coord_html, range_str)
    if not resolved then return {ok=false, error=err} end

    if resolved.point then
        local encoded = Range.encode(resolved.html_start, resolved.html_end_pos, true)
        return {
            ok = encoded == tostring(range_str or ""),
            range = encoded,
            text = resolved.text,
            point = true,
        }
    end

    local before, after = Coord.contextForSpan(
        resolved.map, resolved.text_start, resolved.text_end_pos, 24)
    local encoded, hs, he = PosMap.locate(resolved.map, resolved.text, {
        context_before = before,
        context_after = after,
    })
    return {
        ok = encoded ~= nil and encoded == tostring(range_str or ""),
        range = encoded,
        html_start = hs,
        html_end_pos = he,
        text = resolved.text,
        error = encoded and nil or "roundtrip_locate_failed",
        point = false,
    }
end

return Coord
