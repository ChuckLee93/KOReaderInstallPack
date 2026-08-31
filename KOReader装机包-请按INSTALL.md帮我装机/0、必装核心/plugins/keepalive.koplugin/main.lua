local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local PluginShare = require("pluginshare")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

-- 修改版说明（自用 v4.4）：
-- v4.4 修复【勾选保活仍休眠】：
--   实测（crash.log 08/30 19:16）v4.3 三层防护在"未充电 + 主页状态"下全灭：
--   ① Layer 3（t1 重置循环）有启动顺序 bug——勾选菜单时 enable() 先执行，
--      PluginShare.keepalive=true 在其后，循环第一轮自检 keepalive=false 即
--      自杀退出，此后永不重启（日志 19:06:30 "started" 下一行立刻
--      "stopped: keepalive off" 即此 bug）；
--   ② 19:16:33 闲置挂起（t1 十分钟到期）发起后 7 秒睡死，期间
--      readyToSuspend 事件从未投递（主页状态无 reader 收尾流程，powerd
--      直接走 REAL_SUSPEND），Layer 1 聋；
--   ③ Layer 2 看门狗 5 秒一 tick，powerd 状态 screenSaver→suspended 直接
--      跳变，抓不到 readyToSuspend 窗口，Layer 2 聋。
--   结论：事件层/状态层/重置层全部不可靠，唯一被实证可靠的是
--   preventScreenSaver 系统标志（v2/v3 时代用户长期使用，闲置/按钮/合盖
--   挂起全部拦截成功）。v4.4 回退为该方案作为主防线：
--   勾选保活 = preventScreenSaver=1，电源键/合盖也无法休眠，须取消勾选
--   才能休眠（用户明确接受此代价）；取消勾选/未勾选时主动清零标志，
--   防止崩溃残留导致"取消勾选仍无法休眠"。
--   保留 v4 的：勾选状态 G_reader_settings 持久化、autosuspend 协同
--   （pause_auto_suspend）、Layer 1/2 作为兜底（prevent 标志万一失效时
--   仍有事件拦截+看门狗两道保险）。
-- 历史版本：
-- v4.3 三层防护（事件拦截/状态看门狗/充电 t1 重置）——见上，三路皆败。
-- v4.1/v4.2 readyToSuspend 拦截 + autosuspend 协同（作为 Layer 1 保留）。
-- v2/v3 preventScreenSaver 方案（拦截一切挂起含电源键）——v4.4 重新启用。

local menuItem = {
    text = _("Keep alive"),
    checked_func = function() return PluginShare.keepalive end,
}

local disable
local enable

local function persist(enabled)
    if G_reader_settings then
        G_reader_settings:saveSetting("keepalive", enabled)
        G_reader_settings:flush()
    end
end

--------------------------------------------------------------------
-- Kindle: 系统级保活标志 + 事件拦截兜底
--------------------------------------------------------------------
local SS_SOURCE_NAME = {
    [1] = "BUTTON_WAKEUP",
    [2] = "BUTTON_SUSPEND",
    [3] = "IDLE_TIMEOUT",
    [4] = "HALL_SUSPEND",
    [6] = "HALL_WAKEUP",
}

local last_ss_source -- 最近一次 IntoSS 的 source 数字
local last_ss_at     -- 记录时间（os.time()）

-- 用户主动发起的挂起来源：电源键(2)、合盖(4)。
local USER_INITIATED = { [2] = true, [4] = true }

-- [v4.4] 主防线：系统级保活标志。powerd 每次发起屏保/挂起前检查，
-- =1 时全部取消（v2/v3 时代实证有效，含闲置超时、电源键、合盖）。
local function setPrevent(on)
    local v = on and 1 or 0
    os.execute("lipc-set-prop -i com.lab126.powerd preventScreenSaver " .. v .. " >/dev/null 2>&1")
    logger.info("[KeepAlive] preventScreenSaver =", v)
end

-- 是否应拦截本次挂起（仅兜底层使用，主防线已拦截绝大多数场景）。
local function shouldBlockSuspend()
    local src = last_ss_source
    if src == nil then return false end -- 无记录：KOReader 内部路径，放行
    local age = last_ss_at and (os.time() - last_ss_at) or math.huge
    if age > 300 then return false end  -- 记录过期（>5 分钟）：不可信，放行
    if USER_INITIATED[src] then return false end -- 电源键/合盖：用户发起，放行
    return true -- source=3（闲置超时）等其余来源：拦截
end

local function lipcAbortSuspend()
    local ok = os.execute("lipc-set-prop -i com.lab126.powerd abortSuspend 1 >/dev/null 2>&1")
    return ok == true or ok == 0
end

--------------------------------------------------------------------
-- [兜底 Layer 2] powerd 状态看门狗（prevent 失效时的最后保险）
--------------------------------------------------------------------
local PowerD -- 在 init 中赋值（Device:getPowerDevice()）

local WATCHDOG_INTERVAL = 3  -- 秒
local watchdog_running = false

local function getPowerdState()
    if PowerD and type(PowerD.getPowerdState) == "function" then
        local ok, state = pcall(PowerD.getPowerdState, PowerD)
        if ok and state ~= nil then return tostring(state) end
    end
    local p = io.popen("lipc-get-property com.lab126.powerd state 2>/dev/null", "r")
    if not p then return nil end
    local state = p:read("*l")
    p:close()
    return state
end

local function watchdogTick()
    watchdog_running = false
    if not PluginShare.keepalive then
        logger.info("[KeepAlive] watchdog stopped: keepalive off")
        return
    end
    if not Device.screen_saver_mode then
        logger.info("[KeepAlive] watchdog stopped: out of screensaver")
        return
    end
    if not last_ss_source or USER_INITIATED[last_ss_source] then
        return
    end

    local state = getPowerdState()
    if state == "readyToSuspend" then
        logger.info("[KeepAlive] watchdog: powerd in readyToSuspend, aborting")
        if lipcAbortSuspend() then
            last_ss_at = os.time()
            logger.info("[KeepAlive] watchdog abort ok")
        else
            logger.warn("[KeepAlive] watchdog abortSuspend failed")
        end
    end

    -- 仍在屏保保活窗口内：继续下一轮。
    watchdog_running = true
    UIManager:scheduleIn(WATCHDOG_INTERVAL, watchdogTick)
end

local function startWatchdog()
    if watchdog_running then return end
    watchdog_running = true
    logger.info("[KeepAlive] watchdog started",
        "powerd=", tostring(getPowerdState() or "unknown"))
    UIManager:scheduleIn(WATCHDOG_INTERVAL, watchdogTick)
end

--------------------------------------------------------------------
-- Device 包装：兜底 Layer 1（事件拦截）+ Layer 2（看门狗触发）
--------------------------------------------------------------------
local function installSuspendGuards()
    if Device.__keepalive_v4_guard then return end
    if type(Device.intoScreenSaver) ~= "function"
        or type(Device.readyToSuspend) ~= "function" then
        return
    end
    Device.__keepalive_v4_guard = true

    -- 记录每次进入屏保的来源（电源键=2 / 闲置=3 / 合盖=4）。
    local orig_into = Device.intoScreenSaver
    Device.intoScreenSaver = function(self, source, ...)
        last_ss_source = tonumber(source)
        last_ss_at = os.time()
        if PluginShare.keepalive and last_ss_source
            and not USER_INITIATED[last_ss_source] then
            startWatchdog()
        end
        return orig_into(self, source, ...)
    end

    -- powerd 即将真正挂起前的最后决策点。
    local orig_ready = Device.readyToSuspend
    Device.readyToSuspend = function(self, delay, ...)
        if PluginShare.keepalive and shouldBlockSuspend() then
            local src = last_ss_source or -1
            logger.info("[KeepAlive] block idle suspend at readyToSuspend",
                "source=", tostring(SS_SOURCE_NAME[src] or src),
                "age=", tostring(last_ss_at and (os.time() - last_ss_at) or -1),
                "powerd=", tostring(getPowerdState() or "unknown"))
            if lipcAbortSuspend() then
                last_ss_at = os.time()
                return false
            end
            logger.warn("[KeepAlive] abortSuspend failed; letting suspend pass")
        end
        return orig_ready(self, delay, ...)
    end
    logger.info("[KeepAlive] v4.4 suspend guards installed (fallback layers)")
end

local function showConfirmBox(touchmenu_instance)
    UIManager:show(ConfirmBox:new{
        text = _("The system won't sleep while this message is showing.\n\nPress \"Stay alive\" if you prefer to keep the system on even after closing this notification. *This will drain the battery*.\n\nIf KOReader terminates before \"Close\" is pressed, please start and close the KeepAlive plugin again to ensure settings are reset."),
        cancel_text = _("Close"),
        cancel_callback = function()
            disable()
            PluginShare.keepalive = false
            persist(false)
            touchmenu_instance:updateItems()
        end,
        ok_text = _("Stay alive"),
        ok_callback = function()
            PluginShare.keepalive = true
            enable()
            persist(true)
            touchmenu_instance:updateItems()
        end,
    })
end

if Device:isCervantes() or Device:isKobo() then
    enable = function() PluginShare.pause_auto_suspend = true end
    disable = function() PluginShare.pause_auto_suspend = false end
elseif Device:isKindle() then
    -- [v4.4] 勾选 = preventScreenSaver=1（系统级，拦一切自动挂起，
    -- 电源键/合盖也被拦，须取消勾选才能休眠——用户接受的代价）。
    -- 取消勾选时主动清零，防崩溃残留。
    enable = function()
        setPrevent(true)
        PluginShare.pause_auto_suspend = true
    end
    disable = function()
        setPrevent(false)
        PluginShare.pause_auto_suspend = false
    end
elseif Device:isSDL() then
    local InfoMessage = require("ui/widget/infomessage")
    disable = function()
        UIManager:show(InfoMessage:new{
            text = _("This is a dummy implementation of 'disable' function.")
        })
    end
    enable = function()
        UIManager:show(InfoMessage:new{
            text = _("This is a dummy implementation of 'enable' function.")
        })
    end
else
    return { disabled = true, }
end

menuItem.callback = function(touchmenu_instance)
    enable()
    showConfirmBox(touchmenu_instance)
end

local KeepAlive = WidgetContainer:extend{
    name = "keepalive",
}

function KeepAlive:init()
    self.ui.menu:registerToMainMenu(self)
    -- 勾选状态恢复：以持久化设置为唯一事实源。
    if G_reader_settings and G_reader_settings:has("keepalive") then
        PluginShare.keepalive = G_reader_settings:isTrue("keepalive")
    else
        PluginShare.keepalive = false
    end
    if Device:isKindle() then
        PowerD = Device:getPowerDevice()
        -- [v4.4] 每次启动按勾选状态同步系统标志：
        -- 勾选 → =1 持续保活（防 KOReader 重启/powerd 重启丢标志）；
        -- 未勾选 → =0 主动清理（防 v2/v3 时代崩溃残留导致无法休眠）。
        setPrevent(PluginShare.keepalive and true or false)
        installSuspendGuards()
        -- [v4.2] 启动时同步：勾选保活 ⇒ 暂停 AutoSuspend 定时挂起。
        PluginShare.pause_auto_suspend = PluginShare.keepalive and true or false
        logger.info("[KeepAlive] v4.4 init",
            "checked=", tostring(PluginShare.keepalive),
            "powerd=", tostring(getPowerdState() or "unknown"))
    end
end

function KeepAlive:addToMainMenu(menu_items)
    menu_items.keep_alive = menuItem
end

return KeepAlive
