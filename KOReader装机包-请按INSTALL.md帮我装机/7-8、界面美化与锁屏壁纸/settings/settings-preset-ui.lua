-- settings-preset-ui.lua
-- 装机预设：simpleUI 界面美化（字体 + 主页卡片样式），配合 §6-D1「美化界面包」使用。
-- 用法：WorkBuddy 读取此文件，把下列键块合并进目标设备的 settings.reader.lua
--       （同名键整块替换，没有则追加；其余键保持目标设备原值不动）。
-- 注意：此文件本身不会被上传到设备，仅作为合并的数据源。
return {
    ["ui_font_name"] = "HYKongShanKai",
    ["cre_font"] = "TsangerXuanSan01JF",
    ["start_with"] = "homescreen_simpleui",
    ["font_menu_sort_by_recently_selected"] = true,
    ["visual_overhaul_cover"] = {
        ["ar_den"] = 3,
        ["ar_num"] = 2,
        ["border_width"] = 1.5,
        ["card_gap"] = 3,
        ["corner_radius"] = 0,
        ["dogear_size"] = 0,
        ["file_count_size"] = 15,
        ["fill"] = false,
        ["folder_font_size"] = 25,
        ["hide_title_meta"] = true,
        ["meta_font_size"] = 8,
        ["new_badge_days"] = 9000,
        ["new_badge_inset_x"] = -25,
        ["new_badge_inset_y"] = -8,
        ["new_badge_size"] = 75,
        ["pages_badge_size"] = 10,
        ["pages_border_w"] = 2,
        ["pages_corner"] = 10,
        ["pages_enabled"] = false,
        ["pages_font_size"] = 0.5,
        ["pct_badge_size"] = 55,
        ["pct_move_x"] = 3,
        ["pct_move_y"] = -1,
        ["pct_text_size"] = 0.3,
        ["stretch_limit"] = 50,
        ["title_font_size"] = 10,
        ["title_max_lines"] = 1,
        ["title_padding"] = 3,
        ["top_margin"] = 0,
    },
}
