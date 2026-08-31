--[[--
书摘卡片常量：画布尺寸 / 导出倍率 / 背景图名称 / 日历文案。

画布固定 375pt 设计稿宽(内容宽 = 375 - 2*模板水平内边距),
导出卡片统一 1125px 宽(= 375pt x @3x),
高度随内容自适应。固定画布宽度(不随设备屏幕宽度变化)保证卡片尺寸稳定。

@module koplugin.miuread.book_excerpt_card.config
--]]--

local DESIGN_WIDTH_PT = 375  -- 设计稿宽度(pt)
local RENDER_SCALE = 3       -- 导出倍率(@3x -> 1125px)
local function ds(n) return math.floor((n or 0) * RENDER_SCALE) end -- pt -> px

-- 背景图名称(bg_1..bg_10,静影主题专用;渲染只使用随插件打包的
-- assets/cards/stillness/bg_N.jpg,缺失时回退纯色,见 render.lua)
local BG_IMAGE_NAMES_CN = {
    "海景", "山岚", "暖阳", "青雾", "林深", "暮林", "粉黛", "晚霞", "余晖", "雾灰",
}

-- 英文月份（日历"今日卡片"模板）/ 中文星期（wday: 1=周日）
local MONTHS_EN = { "JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE",
                    "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER" }
local WEEKDAYS_CN = { "星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六" }

return {
    DESIGN_WIDTH_PT = DESIGN_WIDTH_PT,
    RENDER_SCALE = RENDER_SCALE,
    ds = ds,
    BG_IMAGE_NAMES_CN = BG_IMAGE_NAMES_CN,
    MONTHS_EN = MONTHS_EN,
    WEEKDAYS_CN = WEEKDAYS_CN,
}
