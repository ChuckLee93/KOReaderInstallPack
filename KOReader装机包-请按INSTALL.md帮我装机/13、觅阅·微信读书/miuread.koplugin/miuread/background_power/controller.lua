-- Compatibility facade for the background-power subsystem.
-- Kindle uses the SCREEN_SAVER_HOLD backend. Kobo keeps the previously
-- validated pseudo-lock implementation unchanged and isolated.
local Device = require("device")
local Kindle
local Kobo

local M = {}

local function flag(name)
    local fn = Device and Device[name]
    if type(fn) ~= "function" then return false end
    local ok, yes = pcall(fn, Device)
    return ok and yes == true
end

local function platform()
    local kindle, kobo = flag("isKindle"), flag("isKobo")
    if kindle == kobo then return "other" end
    return kindle and "kindle" or "kobo"
end

local function backend()
    local p = platform()
    if p == "kindle" then
        if not Kindle then Kindle = require("miuread.background_power.kindle") end
        return Kindle, p
    end
    if p == "kobo" then
        if not Kobo then Kobo = require("miuread.background_power.kobo_legacy") end
        return Kobo, p
    end
    return nil, p
end

function M.device_platform() return platform() end
function M.platform()
    local b, p = backend()
    if b and type(b.platform) == "function" then return b.platform() end
    return p
end
function M.background_supported()
    local _, p = backend()
    return p == "kindle" or p == "kobo", p
end
function M.active()
    local b = backend()
    return b and type(b.active) == "function" and b.active() == true or false
end
function M.system_active()
    local b = backend()
    return b and type(b.system_active) == "function" and b.system_active() == true or false
end
function M.commit_pending()
    local b = backend()
    if b and type(b.commit_pending) == "function" then return b.commit_pending() == true end
    local snap = M.snapshot()
    return snap.commit_pending == true
end
function M.snapshot()
    local b, p = backend()
    if b and type(b.snapshot) == "function" then return b.snapshot() end
    return { active = false, platform = p, system_active = false, commit_pending = false }
end
function M.mark_user_sleep(origin)
    local b = backend()
    return b and type(b.mark_user_sleep) == "function" and b.mark_user_sleep(origin) or false
end
function M.consume_user_sleep_origin()
    local b = backend()
    return b and type(b.consume_user_sleep_origin) == "function" and b.consume_user_sleep_origin() or nil
end
function M.begin(reason)
    local b = backend()
    if not b or type(b.begin) ~= "function" then return false, "unsupported_platform" end
    return b.begin(reason)
end
function M.after_suspend()
    local b = backend()
    return b and type(b.after_suspend) == "function" and b.after_suspend() or false
end
function M.on_resume_event()
    local b = backend()
    return b and type(b.on_resume_event) == "function" and b.on_resume_event() or "normal"
end
function M.on_suspend_while_active()
    local b = backend()
    return b and type(b.on_suspend_while_active) == "function" and b.on_suspend_while_active() or "none"
end
function M.set_task_active(name, value)
    local b, p = backend()
    if p == "kindle" and b and type(b.set_task) == "function" then
        return b.set_task(name, value)
    end
    -- Kobo's legacy implementation only needs the download marker. Reader
    -- finalizer continues using its existing lease on Kobo, preserving behavior.
    if p == "kobo" and name == "download" and b and type(b.set_download_active) == "function" then
        return b.set_download_active(value)
    end
    return true
end
function M.set_download_active(value)
    return M.set_task_active("download", value)
end
function M.download_active()
    local b, p = backend()
    if p == "kindle" and b and type(b.task_active) == "function" then return b.task_active("download") end
    return b and type(b.download_active) == "function" and b.download_active() == true or false
end
function M.background_task_done(reason)
    local b = backend()
    return b and type(b.background_task_done) == "function" and b.background_task_done(reason) or false
end
function M.force_clear(reason)
    local b = backend()
    return b and type(b.force_clear) == "function" and b.force_clear(reason) or false
end

return M
