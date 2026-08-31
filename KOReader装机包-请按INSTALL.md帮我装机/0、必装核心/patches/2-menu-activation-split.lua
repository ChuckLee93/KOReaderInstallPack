-- 顶部菜单 / 底部菜单分别设置激活方式（书内）
-- 新增设置键: activate_menu_top / activate_menu_bottom，取值 tap / swipe / swipe_tap
-- 未单独设置时回落到旧键 activate_menu（兼容迁移，当前已有值会被继承）
-- 配套的设置界面在 frontend/ui/elements/menu_activate.lua（已重写为两个子菜单）
local ok, err = pcall(function()
    local Event = require("ui/event")
    local ReaderMenu = require("apps/reader/modules/readermenu")
    local ReaderConfig = require("apps/reader/modules/readerconfig")

    if ReaderMenu._menu_activation_split_applied then
        return
    end
    ReaderMenu._menu_activation_split_applied = true
    ReaderConfig._menu_activation_split_applied = true

    local VALID = { tap = true, swipe = true, swipe_tap = true }

    local function activation_for(key)
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

    -- 顶部菜单（ReaderMenu，屏幕顶部区域：下拉 south / 单击）
    function ReaderMenu:onTapShowMenu(ges)
        if activation_for("activate_menu_top") ~= "swipe" then
            if G_reader_settings:nilOrTrue("show_bottom_menu") then
                self.ui:handleEvent(Event:new("ShowConfigMenu"))
            end
            self:onShowMenu(self:_getTabIndexFromLocation(ges))
            return true
        end
    end

    function ReaderMenu:onSwipeShowMenu(ges)
        if activation_for("activate_menu_top") ~= "tap" and ges.direction == "south" then
            if G_reader_settings:nilOrTrue("show_bottom_menu") then
                self.ui:handleEvent(Event:new("ShowConfigMenu"))
            end
            self:onShowMenu(self:_getTabIndexFromLocation(ges))
            self.ui:handleEvent(Event:new("HandledAsSwipe"))
            return true
        end
    end

    -- 底部菜单（ReaderConfig，屏幕底部区域：上拉 north / 单击）
    function ReaderConfig:onTapShowConfigMenu()
        if activation_for("activate_menu_bottom") ~= "swipe" then
            self:onShowConfigMenu()
            return true
        end
    end

    function ReaderConfig:onSwipeShowConfigMenu(ges)
        if activation_for("activate_menu_bottom") ~= "tap" and ges.direction == "north" then
            self:onShowConfigMenu()
            return true
        end
    end
end)

if not ok then
    require("logger").warn("[MenuActivationSplit] patch failed:", err)
end
