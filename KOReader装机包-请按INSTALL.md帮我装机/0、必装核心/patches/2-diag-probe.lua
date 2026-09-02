-- 诊断探针 (Diag Probe) v1.0 —— KeZi 原创，随装机包分发
-- 用途：把设备状态汇总写到 koreader/diag_report.txt，供 AI 助手在用户求助时
--       通过 FilebrowserPlus API（GET /api/raw/mnt/us/koreader/diag_report.txt）
--       或 USB 拷贝远程读取、快速排障。
-- 报告内容：机型 / KOReader 版本 / 电量 / 内存 / 屏保状态 / 插件 / 补丁 / 词典 /
--           手势与设置键名（仅键名不含值）/ crash.log 末 80 行。
-- 刷新时机：KOReader 启动 1 秒后首写，之后每 30 分钟自动刷新；进程退出即停。
-- 隐私：只读不写任何配置，不含账号/密钥；报告只保存在本机 koreader 目录内。

local logger = require("logger")
pcall(function()
    if _G.__diag_probe_started then return end
    _G.__diag_probe_started = true

    local ok_lfs, lfs = pcall(require, "libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    local Device = require("device")
    local UIManager = require("ui/uimanager")

    local base = (ok_lfs and lfs.currentdir()) or "/mnt/us/koreader"
    local report_path = base .. "/diag_report.txt"

    -- 取文件末 n 行（超大文件只读末 256KB，避免老设备整读大日志）
    local function file_tail(path, n)
        local f = io.open(path, "r")
        if not f then return "(无此文件)" end
        local size = f:seek("end")
        if size and size > 262144 then
            f:seek("set", size - 262144)
            f:read("*l") -- 丢弃被截断的半行
        else
            f:seek("set")
        end
        local tail, count = {}, 0
        for line in f:lines() do
            count = count + 1
            if #tail >= n then table.remove(tail, 1) end
            tail[#tail + 1] = line
        end
        f:close()
        if count == 0 then return "(空文件)" end
        return table.concat(tail, "\n")
    end

    local function file_last_line(path)
        local f = io.open(path, "r")
        if not f then return "(无此文件)" end
        local last
        for line in f:lines() do last = line end
        f:close()
        return last or "(空)"
    end

    local function list_dir(path)
        local items = {}
        local ok = pcall(function()
            for name in lfs.dir(path) do
                if name ~= "." and name ~= ".." then items[#items + 1] = name end
            end
        end)
        if not ok then return "(无法读取)" end
        if #items == 0 then return "(空)" end
        table.sort(items)
        return table.concat(items, ", ")
    end

    local function read_meminfo()
        local f = io.open("/proc/meminfo", "r")
        if not f then return "(不可读)" end
        local total, avail
        for line in f:lines() do
            local v = line:match("^MemTotal:%s+(%d+) kB")
            if v then total = math.floor(v / 1024) .. "MB" end
            v = line:match("^MemAvailable:%s+(%d+) kB")
            if v then avail = math.floor(v / 1024) .. "MB" end
            if total and avail then break end
        end
        f:close()
        if not total then return "(无 MemTotal)" end
        return total .. " / 可用 " .. (avail or "?")
    end

    -- settings.reader.lua 顶层键名（仅键名，不含值）
    local function settings_keys(path)
        local f = io.open(path, "r")
        if not f then return nil end
        local keys = {}
        for line in f:lines() do
            local k = line:match('^    %["(.-)"%] =')
            if k then keys[#keys + 1] = k end
        end
        f:close()
        return keys
    end

    local function write_report()
        local ok, err = pcall(function()
            local lines = {}
            local add = function(s) lines[#lines + 1] = s end

            add("════════ KOReader 诊断探针报告 ════════")
            add("生成时间: " .. os.date("%Y-%m-%d %H:%M:%S"))
            add("生成方式: 探针补丁 2-diag-probe.lua（启动后 + 每 30 分钟自动刷新）")
            add("机型: " .. tostring(Device.model))
            add("KOReader 版本: " .. file_last_line(base .. "/version.log"))

            local pp = Device:getPowerDevice()
            local cap, chg = "?", "?"
            pcall(function() cap = pp:getCapacity() end)
            pcall(function() chg = pp:isCharging() end)
            add("电量: " .. tostring(cap) .. "%（" .. (chg == true and "充电中" or "电池") .. "）")
            add("内存: " .. read_meminfo()
                .. string.format(" | Lua 堆 %.1fMB", collectgarbage("count") / 1024))

            local ssm = Device.screen_saver_mode
            if type(ssm) == "function" then
                local okss, v = pcall(ssm)
                ssm = okss and v or "?"
            end
            add("屏保状态: " .. tostring(ssm))

            add("插件(plugins/): " .. list_dir(base .. "/plugins"))
            add("补丁(patches/): " .. list_dir(base .. "/patches"))
            add("词典(data/dict/): " .. list_dir(base .. "/data/dict"))

            local gattr = ok_lfs and lfs.attributes(base .. "/settings/gestures.lua")
            add("手势配置: settings/gestures.lua "
                .. (gattr and gattr.size and (gattr.size .. " 字节") or "缺失"))

            local keys = settings_keys(base .. "/settings.reader.lua")
            if keys then
                add("设置键(共 " .. #keys .. " 个): " .. table.concat(keys, ", "))
            else
                add("设置键: settings.reader.lua 缺失")
            end

            add("")
            add("── crash.log 末 80 行 ──")
            add(file_tail(base .. "/crash.log", 80))

            local f = io.open(report_path, "w")
            if not f then return end
            f:write(table.concat(lines, "\n") .. "\n")
            f:close()
        end)
        if not ok then logger.warn("[DiagProbe] write report failed:", err) end
    end

    local function tick()
        write_report()
        UIManager:scheduleIn(1800, tick)
    end
    UIManager:scheduleIn(1, tick)
    logger.info("[DiagProbe] started, report path: " .. report_path)
end)
