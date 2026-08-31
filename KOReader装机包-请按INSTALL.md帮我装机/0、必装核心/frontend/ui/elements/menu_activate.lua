local _ = require("gettext")

local VALID = { tap = true, swipe = true, swipe_tap = true }

local function current(key)
    local value = G_reader_settings:readSetting(key)
    if VALID[value] then
        return value
    end
    value = G_reader_settings:readSetting("activate_menu")
    if VALID[value] then
        return value
    end
    return "swipe_tap"
end

local function options_for(key, title, help)
    local choices = {
        { text = "通过单击", value = "tap" },
        { text = "通过滑动", value = "swipe" },
        { text = "单击和滑动", value = "swipe_tap" },
    }
    local sub_items = {}
    for _, choice in ipairs(choices) do
        table.insert(sub_items, {
            text = choice.text,
            checked_func = function()
                return current(key) == choice.value
            end,
            callback = function(touchmenu_instance)
                G_reader_settings:saveSetting(key, choice.value)
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end,
        })
    end
    return {
        text = title,
        help_text = help,
        sub_item_table = sub_items,
    }
end

return {
    text = _("Activate menu"),
    sub_item_table = {
        options_for(
            "activate_menu_top",
            "书内顶部菜单",
            "在书内从屏幕顶部区域唤醒顶部菜单的方式"
        ),
        options_for(
            "activate_menu_bottom",
            "书内底部菜单",
            "在书内从屏幕底部区域唤醒底部菜单的方式"
        ),
        {
            text = _("Auto-show bottom menu"),
            checked_func = function()
                return G_reader_settings:nilOrTrue("show_bottom_menu")
            end,
            callback = function()
                G_reader_settings:flipNilOrTrue("show_bottom_menu")
            end,
            separator = true,
        },
    },
}
