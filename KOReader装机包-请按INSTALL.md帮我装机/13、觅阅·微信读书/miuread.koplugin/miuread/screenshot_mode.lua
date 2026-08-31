local UIManager = require("ui/uimanager")
local logger = require("logger")
local ActionSheet = require("miuread.action_sheet")

local ScreenshotMode = {}
local generation = 0
local armed = false

local function native_screenshoter(host)
    local ui = host and host.ui or nil
    if ui and ui.screenshot and type(ui.screenshot.onScreenshot) == "function" then
        return ui.screenshot
    end
    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_reader and ReaderUI and ReaderUI.instance and ReaderUI.instance.screenshot
        and type(ReaderUI.instance.screenshot.onScreenshot) == "function" then
        return ReaderUI.instance.screenshot
    end
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FileManager and FileManager.instance and FileManager.instance.screenshot
        and type(FileManager.instance.screenshot.onScreenshot) == "function" then
        return FileManager.instance.screenshot
    end
    return nil
end

local function capture(host, token)
    if not armed or token ~= generation then return false end
    armed = false
    local screenshoter = native_screenshoter(host)
    if not screenshoter then
        if host and host.info then host:info("当前 KOReader 暂时无法截图") end
        return false
    end
    local ok, err = pcall(screenshoter.onScreenshot, screenshoter)
    if not ok then
        logger.warn("[MiuRead][Screenshot] native KOReader screenshot failed", tostring(err))
        if host and host.info then host:info("截图失败：\n" .. tostring(err or "KOReader 截图不可用")) end
        return false
    end
    return true
end

local function arm(host, seconds)
    generation = generation + 1
    local token = generation
    armed = true
    seconds = math.max(2, tonumber(seconds) or 8)
    if host and host.toast then
        host:toast(tostring(seconds) .. " 秒后截图，可继续操作页面", 2.2)
    end
    UIManager:scheduleIn(seconds, function() capture(host, token) end)
    return true
end

function ScreenshotMode.start(host, anchor)
    local actions = {
        {icon = "5", label = "5 秒后截图", detail = "截图由 KOReader 保存", callback = function() arm(host, 5) end},
        {icon = "10", label = "10 秒后截图", detail = "适合进入菜单或翻页", callback = function() arm(host, 10) end},
        {icon = "15", label = "15 秒后截图", detail = "留出更多操作时间", callback = function() arm(host, 15) end},
    }
    if armed then
        actions[#actions + 1] = {icon = "×", label = "取消待截图任务", detail = "当前计时将停止", danger = true, callback = function()
            ScreenshotMode.cancel()
            if host and host.toast then host:toast("已取消截图", 1.3) end
        end}
    end
    ActionSheet.show{
        anchor = anchor,
        preferred_direction = "below",
        title = "延时截图",
        subtitle = "觅阅只负责倒计时，截图与保存由 KOReader 完成",
        show_close = false,
        actions = actions,
    }
    return true
end

function ScreenshotMode.cancel()
    generation = generation + 1
    armed = false
end

function ScreenshotMode.isArmed()
    return armed == true
end

return ScreenshotMode
