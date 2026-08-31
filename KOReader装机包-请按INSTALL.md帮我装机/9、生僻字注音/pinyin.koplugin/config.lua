--[[--
pinyin.koplugin 配置文件
Copyright (C) 2026 zhouwt — 以 GPL-3.0 协议发布 (见 LICENSE)

修改本文件后, 重启 KOReader 才会生效。
两项高级开关默认均为关闭 (false)。

  enable_debug_log
    是否在阅读菜单中显示「调试日志 (写 KOReader 日志)」项。
    开启后, 翻页 / 重绘时每个盒子的取字、拼音数据、等级过滤结果
    都会写入 KOReader 日志 (crash.log)。

  show_diagnostics
    是否在阅读菜单中显示「查看诊断信息」项。
    开启后, 可在阅读菜单里直接查看本页注音统计与判读,
    无需去翻 crash.log。
--]]--

local config = {
    enable_debug_log = false,
    show_diagnostics = false,
    _pinyin = true,  -- 标记: 避免 require("config") 误加载其它同名模块
}

return config
