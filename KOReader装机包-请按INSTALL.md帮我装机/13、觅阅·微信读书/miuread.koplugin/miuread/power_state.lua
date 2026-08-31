local U = require("miuread.util")

local M = {}

local KEY = "__MIUREAD_POWER_STATE_V1"
local VALID = {
    NORMAL = true,
    DOWNLOAD_LOCKED = true,
    PSEUDO_LOCKED = true,
    SCREEN_SAVER_HOLD = true,
    BACKGROUND_LOCKED = true,
    REAL_SUSPEND = true,
    RESUMING = true,
}

local function shared()
    local value = rawget(_G, KEY)
    if type(value) ~= "table" then
        value = {
            state = "NORMAL",
            previous = "NORMAL",
            generation = 0,
            changed_at = os.time(),
            reason = "init",
        }
        rawset(_G, KEY, value)
    end
    if not VALID[tostring(value.state or "")] then value.state = "NORMAL" end
    value.generation = tonumber(value.generation or 0) or 0
    return value
end

function M.snapshot()
    return U.copy(shared())
end

function M.state()
    return tostring(shared().state or "NORMAL")
end

function M.generation()
    return tonumber(shared().generation or 0) or 0
end

function M.is_normal()
    return M.state() == "NORMAL"
end

function M.matches(generation, state)
    local value = shared()
    if generation ~= nil and tonumber(generation) ~= tonumber(value.generation) then return false end
    if state ~= nil and tostring(state) ~= tostring(value.state) then return false end
    return true
end

function M.transition(state, reason, meta)
    state = tostring(state or "NORMAL")
    if not VALID[state] then state = "NORMAL" end
    local value = shared()
    local previous = tostring(value.state or "NORMAL")
    reason=tostring(reason or "transition")
    -- FileManager and ReaderUI may both receive the same lifecycle event. They
    -- must share one power generation rather than manufacturing two transitions
    -- for a single physical suspend/resume.
    local duplicate=(previous==state and tostring(value.reason or "")==reason
        and (reason=="onSuspend" or reason=="onResume"))
    value.previous = duplicate and tostring(value.previous or previous) or previous
    value.state = state
    if not duplicate then
        value.generation = (tonumber(value.generation or 0) or 0) + 1
        value.changed_at = os.time()
    end
    value.reason = reason
    value.download_active = type(meta) == "table" and meta.download_active == true or false
    value.download_continue = type(meta) == "table" and meta.download_continue == true or false
    value.sync_continue = type(meta) == "table" and meta.sync_continue == true or false
    value.slept = type(meta) == "table" and tonumber(meta.slept) or nil
    value.short_wake = type(meta) == "table" and meta.short_wake == true or false
    return U.copy(value)
end

return M
