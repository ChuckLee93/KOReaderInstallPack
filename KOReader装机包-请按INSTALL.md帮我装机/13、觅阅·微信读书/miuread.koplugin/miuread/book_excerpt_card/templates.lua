--[[--
书摘卡片模板 / 配色 / 背景图定义（纯数据，排版参数见 init.lua 模块文档）。

@module koplugin.miuread.book_excerpt_card.templates
--]]--

local Config = require("miuread.book_excerpt_card.config")

-- ---------------------------------------------------------------------------
-- 模板定义（各模板排版参数）
-- ---------------------------------------------------------------------------

local TEMPLATES = {
    {
        id = "classic",
        name = "经典",
        font = "cfont",
        content_size = 18,
        header_size = 16,
        header_line_height = 22,
        subheader_size = 12,
        subheader_line_height = 18,
        footer_size = 12,
        footer_text_ratio = 0.8,
        padding = 32,
        align = "justify",
        header_align = "left",
        header_divider = false,
        footer_divider = true,
        footer_hairline = true,
        content_line_height = 36,
        para_gap = 10,
        content_max_lines = 16,
        header_pad_top = 40,
        header_pad_bottom = 34,
        footer_pad_top = 40,
        -- 经典页脚:上边距 40 + 容器高 80(带二维码 112),
        -- 微信读书在其中垂直居中,容器底 = 卡底(无额外留白)
        footer_content_h = 80,
        footer_qr_extra = 32, -- 经典带二维码时容器 80→112
        footer_pad_bottom = 0,
        qr_size = 64,
        classic_header = true,
        subheader_prefix = "摘录于 ", -- 页眉第二行 = 动作文案 + " " + 日期
        source_after_content = true,
        source_slash = true,
        source_show_book = true,
        source_author_line = true,
        source_line_height = 20,
        source_margin_top = 4,
    },
    {
        id = "inkwhite",
        name = "墨白",
        font = "ffont",
        content_size = 18,
        header_size = 18,
        footer_size = 12,
        footer_text_ratio = 0.8,
        padding = 32,
        align = "justify",
        header_align = "center",
        header_divider = false,
        footer_divider = true,
        footer_sep_317 = true,
        footer_bold_line = true,
        content_line_height = 34,
        para_gap = 10,
        content_max_lines = 14,
        vertical_title = true,
        vertical_title_size = 32,
        vertical_title_line_h = 35,
        vertical_author_size = 13,
        vertical_author_line_h = 16,
        vertical_box_h = 226,
        vertical_vline_pad = 24,
        subheader_prefix = "摘录于 ", -- 右侧装饰列动作列文案
        header_pad_top = 46,
        header_top_bar_h = 10,
        header_after_top_bar = 28,
        header_bottom_bar_h = 0,
        footer_pad_top = 36,
        footer_pad_bottom = 46,
        -- 墨白页脚:上分隔线与下粗线之间是 content 盒(高 80,
        -- 带二维码 96),微信读书在其中垂直居中
        footer_content_h = 80,
        qr_size = 56,
        source_after_content = true,
        source_slash = true,
        source_line_height = 20,
        source_margin_top = 3,
    },
    {
        id = "notebook",
        name = "手札",
        font = "cfont",
        content_size = 17,
        header_size = 17,
        header_line_height = 24,
        subheader_size = 12,
        subheader_line_height = 17,
        footer_size = 12,
        footer_text_ratio = 0.7,
        footer_text_white = true, -- 手札页脚微信读书 = 白 70% 透明度
        padding = 20,
        align = "justify",
        header_align = "left",
        header_divider = false,
        footer_divider = true,
        footer_hairline = true,
        content_line_height = 34,
        para_gap = 8,
        content_max_lines = 14,
        header_pad_top = 24,
        footer_pad_top = 40,
        -- 手札页脚容器底 = 卡片内框底(无额外留白):
        -- 微信读书距底部边框与距上分隔线均为 ~43px,对称
        footer_pad_bottom = 0,
        inner_panel = true,
        inner_pad_h = 16,
        inner_pad_v = 44,
        qr_size = 56,
        notebook_header = true, -- 手札页眉高 102:只显示「摘录于 日期」,垂直居中
        content_pad_top = 24, -- 手札页眉→正文留白 24
        subheader_prefix = "摘录于 ",
        footer_qrcode_line = true, -- 手札:微信读书与二维码间 1px 竖分隔线
        footer_height = 102, -- 手札页脚容器高 102,微信读书垂直居中
        source_after_content = true,
        source_slash = true,
        source_two_lines = true,
        source_author_line = true,
        source_line_height = 22,
        source_margin_top = 4,
    },
    {
        id = "stillness",
        name = "静影",
        font = "cfont",
        content_size = 18,
        header_size = 16,
        footer_size = 12,
        padding = 36,
        align = "justify",
        header_align = "center",
        header_divider = false,
        footer_divider = true,
        footer_hairline = true,
        footer_line_color = "ADB4BE", -- 静影页脚分隔线固定色
        divider_ratio = 0.22,
        content_line_height = 36,
        para_gap = 10,
        content_max_lines = 12,
        vertical_title = true,
        vertical_title_size = 26,
        vertical_title_line_h = 40,
        vertical_author_size = 13,
        vertical_author_line_h = 16,
        header_pad_top = 76,
        content_pad_top = 32,
        footer_pad_top = 40,
        footer_pad_bottom = 48,
        footer_two_lines = true,
        footer_date_prefix = "摘录于 ", -- 页脚第一行 = 昵称 · 摘录于 日期
        footer_date_color = "212832",
        footer_date_pad_top = 36, -- 页脚容器高 112 内两行垂直居中:(112-39)/2
        qr_size = 64,
        vertical_box_h = 200,
        source_after_content = true,
        source_slash = true,
        source_line_height = 24,
        source_margin_top = 4,
    },
    {
        id = "ornate",
        name = "锦书",
        font = "cfont",
        content_size = 18,
        header_size = 16,
        footer_size = 12,
        padding = 36,
        align = "justify",
        header_align = "center",
        header_divider = false,
        footer_divider = true,
        footer_hairline = true,
        header_deco = true,
        content_line_height = 36,
        para_gap = 10,
        content_max_lines = 14,
        vertical_title = true,
        vertical_title_size = 30,
        vertical_title_line_h = 34,
        vertical_author_size = 13,
        vertical_author_line_h = 16,
        header_pad_top = 76, -- 锦书页眉上留白 76
        header_pad_bottom = 40, -- 页眉下留白 40
        content_pad_top = 24,
        footer_pad_top = 40,
        -- 锦书页脚:上边距 40 + 容器高 112 固定
        -- (两行[摘录于日期+微信读书]垂直居中),容器底 = 卡底
        footer_height = 112,
        footer_pad_bottom = 0,
        footer_two_lines = true,
        footer_date_prefix = "摘录于 ",
        -- 页脚容器 112 内两行垂直居中;插件渲染以基线为基准,
        -- 上边距取 40(≈(112-39)/2 + 字形上移量)
        footer_date_pad_top = 40, -- 页脚容器 112 内两行垂直居中
        qr_size = 64,
        source_after_content = true,
        source_slash = true,
        source_line_height = 24,
        source_margin_top = 2,
    },
    {
        id = "calendar",
        name = "日历",
        font = "ffont",
        content_size = 17,
        header_size = 100,
        footer_size = 12,
        footer_text_ratio = 0.5,
        padding = 32,
        align = "justify",
        header_align = "center",
        header_divider = true,
        footer_divider = false,
        content_line_height = 32,
        para_gap = 13,
        header_pad_top = 28,
        content_pad_top = 30,
        footer_pad_top = 32,
        footer_pad_bottom = 48,
        content_max_lines = 12,
        calendar = true,
        footer_align = "center",
        show_book_info = true,
        qr_size = 46,
        center_if_short = true,
        book_title_size = 14,
        book_title_line_height = 19,
        book_author_size = 14,
        book_author_line_height = 19,
        book_info_gap = 7,
    },
}

-- 10 套配色。color_1 由原生铺底,插件用米色纸近似。
-- color_5..8 是双色渐变，bg2 为第二色（垂直渐变）。
local COLORS = {
    { name = "米纸", bg = "F4E1B9", bg2 = "F1EFE5", fg = "271300", dark = false }, -- color_1 近似
    { name = "墨黑", bg = "1B1C1F", fg = "F4E1B9", dark = true },  -- color_2
    { name = "墨蓝", bg = "233073", fg = "CCEDFF", dark = true },  -- color_3
    { name = "灰蓝", bg = "6A85B6", fg = "FFFFFF", dark = true },  -- color_4
    { name = "浅蓝", bg = "E3EEFF", bg2 = "F5EBED", fg = "2D1F16", dark = false }, -- color_5
    { name = "浅粉", bg = "F3E5E8", bg2 = "F3F1E5", fg = "270007", dark = false }, -- color_6
    { name = "浅黄", bg = "F3F1E5", bg2 = "E5F3E9", fg = "271E00", dark = false }, -- color_7
    { name = "浅绿", bg = "E5F3E9", bg2 = "E5ECF3", fg = "002706", dark = false }, -- color_8
    { name = "暖白", bg = "FFFCF7", fg = "2D1F16", dark = false }, -- color_9
    { name = "白",   bg = "FAFAFA", fg = "2D1F16", dark = false }, -- color_10
}

-- 背景图列表（静影主题专用；渲染只使用打包资产，见 assets.lua）
local BACKGROUND_IMAGES = {}
for i, cn in ipairs(Config.BG_IMAGE_NAMES_CN) do
    BACKGROUND_IMAGES[i] = {
        id = "bg_" .. i,
        name = cn,
    }
end

return {
    TEMPLATES = TEMPLATES,
    COLORS = COLORS,
    BACKGROUND_IMAGES = BACKGROUND_IMAGES,
}
