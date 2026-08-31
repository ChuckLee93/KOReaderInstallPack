-- settings-preset-pinyin.lua
-- 装机预设：由装机包生成，来自蓝本设备的实际设置（已剔除隐私/临时数据）。
-- 用法：WorkBuddy 读取此文件，把下列键块合并进目标设备的 settings.reader.lua
--       （同名键整块替换，没有则追加；其余键保持目标设备原值不动）。
-- 注意：此文件本身不会被上传到设备，仅作为合并的数据源。
return {
    ["pinyin_enabled"] = true,
    ["pinyin_arrow_select"] = true,
    ["pinyin_font"] = "cfont",
    ["pinyin_font_size"] = 15,
    ["pinyin_level"] = 2,
}
