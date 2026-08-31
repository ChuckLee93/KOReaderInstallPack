local Config = require("miuread.config")
local RuntimePressure = require("miuread.runtime_pressure")
local logger = require("logger")

local PerformanceMode = {}
PerformanceMode.__index = PerformanceMode

local RUNTIME_KEY = "__MIUREAD_PERFORMANCE_RUNTIME"
local runtime = rawget(_G, RUNTIME_KEY)
if type(runtime) ~= "table" then
    runtime = {samples = {}, enabled = false}
    rawset(_G, RUNTIME_KEY, runtime)
end

local function normalize_state(preferences)
    preferences.performance_mode = type(preferences.performance_mode) == "table"
        and preferences.performance_mode or {}
    local state = preferences.performance_mode
    if state.enabled == nil then state.enabled = false end
    if state.auto_detect == nil then state.auto_detect = true end
    state.last_prompt_at = tonumber(state.last_prompt_at or 0) or 0
    state.reminders_disabled = state.reminders_disabled == true
    return state
end

local function performance_rule(kind)
    kind = tostring(kind or "default")
    local rules = type(Config.PERFORMANCE_RULES) == "table" and Config.PERFORMANCE_RULES or {}
    local fallback = type(rules.default) == "table" and rules.default or {}
    local specific = type(rules[kind]) == "table" and rules[kind] or {}

    local slow_ms = tonumber(specific.slow_ms)
        or tonumber(fallback.slow_ms)
        or tonumber(Config.PERFORMANCE_SLOW_MS)
        or 1200
    local extreme_ms = tonumber(specific.extreme_ms)
        or tonumber(fallback.extreme_ms)
        or tonumber(Config.PERFORMANCE_EXTREME_MS)
        or 2500
    local repeat_count = tonumber(specific.repeat_count)
        or tonumber(fallback.repeat_count)
        or tonumber(Config.PERFORMANCE_REPEAT_COUNT)
        or 2

    return {
        slow_ms = math.max(100, slow_ms),
        extreme_ms = math.max(math.max(100, slow_ms), extreme_ms),
        repeat_count = math.max(2, math.floor(repeat_count + .5)),
        single_extreme = specific.single_extreme == true
            or (specific.single_extreme == nil and fallback.single_extreme == true),
    }
end

function PerformanceMode:new(store)
    local object = setmetatable({store = store}, self)
    object:_sync_runtime_flag()
    return object
end

function PerformanceMode:_preferences()
    local preferences = self.store:preferences()
    return preferences, normalize_state(preferences)
end

function PerformanceMode:_save(preferences)
    self.store:save_preferences(preferences)
    return true
end

function PerformanceMode:_sync_runtime_flag()
    local _, state = self:_preferences()
    runtime.enabled = state.enabled == true
    local effective = RuntimePressure.sync_flag(runtime.enabled)
    return effective
end

function PerformanceMode:status()
    local _, state = self:_preferences()
    runtime.enabled = state.enabled == true
    local pressure = RuntimePressure.status()
    return {
        enabled = runtime.enabled,
        effective = runtime.enabled or pressure.active==true,
        temporary = runtime.enabled~=true and pressure.active==true,
        temporary_reason = pressure.reason,
        temporary_until = tonumber(pressure.until_at) or 0,
        auto_detect = state.auto_detect ~= false,
        reminders_disabled = state.reminders_disabled == true,
        last_prompt_at = tonumber(state.last_prompt_at or 0) or 0,
    }
end

function PerformanceMode:enabled()
    return runtime.enabled == true
end

function PerformanceMode:effective_enabled()
    local effective=runtime.enabled==true or RuntimePressure.active()
    RuntimePressure.sync_flag(runtime.enabled==true)
    return effective
end

function PerformanceMode:activate_temporary(reason,seconds)
    RuntimePressure.activate(reason,seconds)
    RuntimePressure.sync_flag(runtime.enabled==true)
    return true
end

function PerformanceMode:set_enabled(enabled)
    local preferences, state = self:_preferences()
    state.enabled = enabled == true
    preferences.performance_mode = state
    self:_save(preferences)
    if not state.enabled and RuntimePressure.active() then
        -- An explicit user switch back to standard mode should win over an
        -- automatic temporary protection window. Future measured pressure can
        -- still activate another temporary window.
        RuntimePressure.clear("manual standard mode",false)
    end
    self:_sync_runtime_flag()
    runtime.samples = {}
    logger.info("[MiuRead][PerformanceMode]", state.enabled and "enabled" or "disabled")
    return true
end

function PerformanceMode:set_auto_detect(enabled)
    local preferences, state = self:_preferences()
    state.auto_detect = enabled ~= false
    if state.auto_detect then state.reminders_disabled = false end
    preferences.performance_mode = state
    self:_save(preferences)
    logger.info("[MiuRead][PerformanceMode] auto detect", tostring(state.auto_detect))
    return true
end

function PerformanceMode:disable_reminders()
    local preferences, state = self:_preferences()
    state.auto_detect = false
    state.reminders_disabled = true
    preferences.performance_mode = state
    self:_save(preferences)
    runtime.samples = {}
    logger.info("[MiuRead][PerformanceMode] reminders disabled")
    return true
end

function PerformanceMode:record(kind, elapsed_ms)
    local status = self:status()
    if status.enabled or not status.auto_detect or status.reminders_disabled then return nil end

    kind = tostring(kind or "interaction")
    local elapsed = math.max(0, tonumber(elapsed_ms) or 0)
    local rule = performance_rule(kind)
    if elapsed < rule.slow_ms then return nil end

    local now = os.time()
    local window = math.max(60, tonumber(Config.PERFORMANCE_WINDOW_SECONDS) or 600)
    local cooldown = math.max(3600, tonumber(Config.PERFORMANCE_PROMPT_COOLDOWN) or 7 * 24 * 60 * 60)

    local samples = runtime.samples or {}
    local retained = {}
    local same_kind_count = 0
    for _, sample in ipairs(samples) do
        if now - (tonumber(sample.at) or 0) <= window then
            retained[#retained + 1] = sample
            if tostring(sample.kind or "") == kind then same_kind_count = same_kind_count + 1 end
        end
    end
    retained[#retained + 1] = {at = now, kind = kind, elapsed_ms = elapsed}
    same_kind_count = same_kind_count + 1
    runtime.samples = retained

    local extreme = elapsed >= rule.extreme_ms
    local triggered = same_kind_count >= rule.repeat_count
        or (extreme and rule.single_extreme)
    if not triggered then return nil end
    -- Runtime protection is immediate and independent from the user-facing
    -- prompt cooldown. A user who already dismissed the prompt still benefits
    -- from a temporary smaller background workload when lag returns.
    self:activate_temporary("lag:"..kind,tonumber(Config.PERFORMANCE_AUTO_PROTECT_SECONDS) or 20*60)
    if status.last_prompt_at > 0 and now - status.last_prompt_at < cooldown then return nil end

    local preferences, state = self:_preferences()
    state.last_prompt_at = now
    preferences.performance_mode = state
    self:_save(preferences)
    runtime.samples = {}

    logger.warn("[MiuRead][PerformanceMode] sustained lag detected",
        "kind=", kind,
        "elapsed_ms=", tostring(math.floor(elapsed + .5)),
        "count=", tostring(same_kind_count),
        "slow_ms=", tostring(rule.slow_ms),
        "extreme_ms=", tostring(rule.extreme_ms),
        "extreme=", tostring(extreme),
        "temporary_protection=true")
    return {
        kind = kind,
        elapsed_ms = elapsed,
        extreme = extreme,
        count = same_kind_count,
        slow_ms = rule.slow_ms,
        extreme_ms = rule.extreme_ms,
    }
end

PerformanceMode.FLAG_PATH = Config.LIGHTWEIGHT_MODE_FLAG or "/tmp/miuread-lightweight-mode.flag"

return PerformanceMode
