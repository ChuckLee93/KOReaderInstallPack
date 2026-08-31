-- ./settings/customisablesleepscreen_presets.lua
-- 必须保持 "Default"：若为内置 preset 名（如 "Kobo"），插件启动时会用 preset 值
-- 整体覆盖 settings/customisablesleepscreen.lua 里的自定义键，导致二选一参数失效。
return {
    ["customisable_ss_last_loaded_preset"] = "Default",
    ["customisable_ss_presets_cycle_index"] = 0,
}
