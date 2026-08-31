-- settings-preset-sleepscreen.lua
-- 装机预设：锁屏休眠屏接管（screensaver_* 键），配合 §6-D2「锁屏壁纸插件」使用。
-- 用法：WorkBuddy 读取此文件，把下列键块合并进目标设备的 settings.reader.lua
--       （同名键整块替换，没有则追加；其余键保持目标设备原值不动）。
-- 注意：此文件本身不会被上传到设备，仅作为合并的数据源。
return {
    ["screensaver_type"] = "customisable_ss",
    ["screensaver_delay"] = "disable",
    ["screensaver_extra_flash_count"] = 0,
    ["screensaver_extra_flash_delay"] = 1000,
    ["screensaver_hide_fallback_msg"] = false,
    ["screensaver_img_background"] = "none",
    ["screensaver_message_alpha"] = 100,
    ["screensaver_message_container"] = "box",
    ["screensaver_message_vertical_position"] = 50,
    ["screensaver_msg_background"] = "none",
    ["screensaver_rotate_auto_for_best_fit"] = false,
    ["screensaver_show_message"] = false,
    ["screensaver_stretch_images"] = true,
}
