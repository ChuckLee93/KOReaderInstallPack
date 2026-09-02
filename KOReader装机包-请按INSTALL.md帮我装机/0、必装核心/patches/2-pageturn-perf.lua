--[[
    2-pageturn-perf.lua

    [PageTurnPerf] diagnostic probe (same family as [ReloadDiag]):
    page-turn freezes are invisible in crash.log because nothing times them.
    This probe times the UI main-loop phases and logs any slow phase:

      - UIManager:handleInputEvent >= 300ms  (input dispatch: tap -> goto -> setDirty)
      - UIManager:_checkTasks      >= 300ms  (scheduled task callbacks, incl. miuread background)
      - UIManager:_repaint         >= 300ms  (render + swipe animation + e-ink refresh)
      - collectgarbage             >= 200ms  (explicit full GC, with caller traceback)

    Read-only instrumentation: wraps, logs, calls the original.
    No behavior change. Remove this file to uninstall.
--]]
pcall(function()
    local logger = require("logger")
    local ffiUtil = require("ffi/util")

    local function now_ms()
        local s, us = ffiUtil.gettime()
        return s * 1000 + math.floor(us / 1000 + 0.5)
    end

    local function fmt(ms)
        return string.format("%.0f", ms)
    end

    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if not ok_ui or type(UIManager) ~= "table" then
        logger.warn("[PageTurnPerf] failed:", "UIManager not loadable")
        return
    end
    if UIManager._pageturn_perf_applied then return end
    UIManager._pageturn_perf_applied = true

    local ok_dev, Device = pcall(require, "device")
    local function swipe_state()
        if ok_dev and Device and Device.screen then
            return tostring(Device.screen.swipe_animations)
        end
        return "unknown"
    end

    local orig_handleInputEvent = UIManager.handleInputEvent
    if type(orig_handleInputEvent) == "function" then
        function UIManager:handleInputEvent(...)
            local t0 = now_ms()
            local a, b = orig_handleInputEvent(self, ...)
            local ms = now_ms() - t0
            if ms >= 300 then
                pcall(function()
                    logger.warn("[PageTurnPerf] input dispatch slow ms=", fmt(ms),
                        "traceback:\n" .. debug.traceback())
                end)
            end
            return a, b
        end
    end

    local orig_checkTasks = UIManager._checkTasks
    if type(orig_checkTasks) == "function" then
        function UIManager:_checkTasks(...)
            local t0 = now_ms()
            local a, b = orig_checkTasks(self, ...)
            local ms = now_ms() - t0
            if ms >= 300 then
                pcall(function()
                    logger.warn("[PageTurnPerf] checkTasks slow ms=", fmt(ms),
                        "traceback:\n" .. debug.traceback())
                end)
            end
            return a, b
        end
    end

    local orig_repaint = UIManager._repaint
    if type(orig_repaint) == "function" then
        function UIManager:_repaint(...)
            local t0 = now_ms()
            orig_repaint(self, ...)
            local ms = now_ms() - t0
            if ms >= 300 then
                pcall(function()
                    logger.warn("[PageTurnPerf] repaint slow ms=", fmt(ms),
                        "swipe_animations=", swipe_state())
                end)
            end
        end
    end

    -- Explicit collectgarbage calls (automatic GC steps are not visible here).
    local orig_cg = collectgarbage
    if type(orig_cg) == "function" and not _G._pageturn_perf_cg then
        _G._pageturn_perf_cg = true
        _G.collectgarbage = function(opt, ...)
            local t0 = now_ms()
            local a, b = orig_cg(opt, ...)
            local ms = now_ms() - t0
            if ms >= 200 then
                pcall(function()
                    logger.warn("[PageTurnPerf] collectgarbage opt=", tostring(opt),
                        "ms=", fmt(ms), "caller:\n" .. debug.traceback())
                end)
            end
            return a, b
        end
    end

    logger.info("[PageTurnPerf] probe installed (handleInputEvent/_checkTasks/_repaint/collectgarbage timed)")
end)
