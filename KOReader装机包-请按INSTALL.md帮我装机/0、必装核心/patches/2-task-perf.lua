--[[
    2-task-perf.lua

    [TaskPerf] diagnostic probe (same family as [PageTurnPerf]):
    [PageTurnPerf] proved the freeze happens inside UIManager:_checkTasks
    (25438ms hang), but its traceback is cut at the pcall boundary and
    cannot tell WHICH scheduled task blocked the UI loop.

    This probe replaces UIManager._checkTasks with an exact copy of the
    original body, except each task.action() call is timed individually.
    Any action taking >= 300ms is logged with its own debug.getinfo
    source location (module + line), which names the culprit directly.

    Semantics preserved: same queue handling, same return values,
    unschedule/identity unaffected (queue still stores original actions).
    Read-only instrumentation. Remove this file to uninstall.
--]]
pcall(function()
    local logger = require("logger")
    local ffiUtil = require("ffi/util")
    local time = require("ui/time")

    local function now_ms()
        local s, us = ffiUtil.gettime()
        return s * 1000 + math.floor(us / 1000 + 0.5)
    end

    local function fmt(ms)
        return string.format("%.0f", ms)
    end

    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if not ok_ui or type(UIManager) ~= "table" then
        logger.warn("[TaskPerf] failed:", "UIManager not loadable")
        return
    end
    if UIManager._task_perf_applied then return end
    UIManager._task_perf_applied = true

    -- exact copy of frontend/ui/uimanager.lua _checkTasks, with per-action timing
    function UIManager:_checkTasks()
        self._now = time.now()
        local wait_until = nil

        self._task_queue_dirty = false
        while self._task_queue[1] do
            local task_time = self._task_queue[#self._task_queue].time
            if task_time <= self._now then
                local task = table.remove(self._task_queue)
                local action = task.action
                local t0 = now_ms()
                action(unpack(task.args, 1, task.args.n))
                local ms = now_ms() - t0
                if ms >= 300 then
                    pcall(function()
                        local info = debug.getinfo(action, "Sln")
                        local src, name
                        if info then
                            src = tostring(info.short_src) .. ":" .. tostring(info.linedefined)
                            name = info.name or "anonymous"
                        else
                            src, name = "?", "?"
                        end
                        logger.warn("[TaskPerf] task slow ms=", fmt(ms),
                            "name=", name, "src=", src)
                    end)
                end
            else
                wait_until = task_time
                break
            end
        end

        return wait_until, self._now
    end

    logger.info("[TaskPerf] probe installed (every scheduled task timed; slow ones report their source)")
end)
