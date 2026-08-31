--[[--
Rune 切字辅助（书摘卡片渲染用）。

卡片排版（kinsoku 避头尾 / justify 分配 / 竖排分列计数）只用到 toRunes，
本文件仅保留该函数，避免依赖批注系统的 HTML 坐标系 / BOM / 注入逻辑。

@module koplugin.miuread.book_excerpt_card.runes
--]]--

local util = require("util")

local Runes = {}

--- UTF-8 → 码点数组（不是 grapheme cluster）。
-- 委托 `util.splitToChars`（含 WTF-8 surrogate 处理）；nil/空串返回 {}。
function Runes.toRunes(str)
    if type(str) ~= "string" or str == "" then
        return {}
    end
    return util.splitToChars(str)
end

return Runes
