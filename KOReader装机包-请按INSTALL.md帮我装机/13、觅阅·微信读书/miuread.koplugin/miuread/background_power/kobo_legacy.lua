local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local SuspendWorkLease = require("miuread.suspend_work_lease")

local ok_pluginshare, PluginShare = pcall(require, "pluginshare")
if not ok_pluginshare then PluginShare = nil end

local M = {}

local KEY = "__MIUREAD_PSEUDO_LOCK_V1"

local function state()
    local value = rawget(_G, KEY)
    if type(value) ~= "table" then
        value = {
            active = false,
            phase = "OFF",
            phase_changed_at = os.time(),
            phase_reason = "init",
            user_exit_started_at = 0,
            platform = "other",
            system_active = false,
            internal_resume_pending = false,
            exit_requested = false,
            user_exit_pending = false,
            commit_pending = false,
            commit_started_at = 0,
            commit_generation = 0,
            commit_suspend_seen = false,
            commit_native_returned = false,
            entered_at = 0,
            generation = 0,
            wake_attempts = 0,
            download_active = false,
            autosuspend_pause_previous = nil,
            autosuspend_pause_owned = false,
            last_power_kind = nil,
            last_power_source = nil,
            last_power_source_name = nil,
            last_power_event_at = 0,
            last_power_self_injected = false,
            injected_expected_kind = nil,
            injected_reason = nil,
            injected_until = 0,
            injected_ticket = 0,
            last_power_injected_ticket = nil,
            pending_user_sleep_origin = nil,
            pending_user_sleep_at = 0,
        }
        rawset(_G, KEY, value)
    end
    value.phase = tostring(value.phase or (value.active and "LOCKED" or "OFF"))
    value.phase_changed_at = tonumber(value.phase_changed_at or 0) or 0
    value.phase_reason = tostring(value.phase_reason or "legacy")
    value.user_exit_started_at = tonumber(value.user_exit_started_at or 0) or 0
    return value
end

local PHASE_OFF = "OFF"
local PHASE_ENTERING = "ENTERING"
local PHASE_LOCKED = "LOCKED"
local PHASE_EXITING = "EXITING"
local PHASE_COMMITTING = "COMMITTING"

local function set_phase(s, next_phase, reason)
    s = s or state()
    local previous = tostring(s.phase or (s.active and PHASE_LOCKED or PHASE_OFF))
    next_phase = tostring(next_phase or PHASE_OFF)
    s.phase = next_phase
    s.phase_changed_at = os.time()
    s.phase_reason = tostring(reason or "unknown")
    s.active = next_phase ~= PHASE_OFF
    s.exit_requested = next_phase == PHASE_EXITING
    s.user_exit_pending = next_phase == PHASE_EXITING
    s.commit_pending = next_phase == PHASE_COMMITTING
    if next_phase == PHASE_OFF then
        s.internal_resume_pending = false
        s.system_active = false
        s.user_exit_started_at = 0
    elseif next_phase == PHASE_ENTERING then
        s.internal_resume_pending = true
    elseif next_phase == PHASE_LOCKED then
        s.internal_resume_pending = false
    end
    if previous ~= next_phase then
        logger.info("[MiuRead][PseudoLock][Phase]",
            "from=", previous, "to=", next_phase,
            "reason=", s.phase_reason,
            "generation=", tostring(s.generation or 0))
    end
    return next_phase
end

local KINDLE_POWER_SOURCES = {
    [1] = "BUTTON_WAKEUP",
    [2] = "BUTTON_SUSPEND",
    [4] = "HALL_SUSPEND",
    [6] = "HALL_WAKEUP",
}

local function power_source_name(source, kind)
    local numeric = tonumber(source)
    if numeric and KINDLE_POWER_SOURCES[numeric] then return KINDLE_POWER_SOURCES[numeric] end
    return string.format("UNKNOWN_%s(%s)", tostring(kind or "POWER"):upper(), tostring(source or "nil"))
end

local function pause_kindle_autosuspend()
    local s = state()
    if s.autosuspend_pause_owned or not PluginShare then return false end
    s.autosuspend_pause_previous = PluginShare.pause_auto_suspend
    PluginShare.pause_auto_suspend = true
    s.autosuspend_pause_owned = true
    logger.info("[MiuRead][PseudoLock] Kindle AutoSuspend paused",
        "previous=", tostring(s.autosuspend_pause_previous))
    return true
end

local function restore_kindle_autosuspend(reason)
    local s = state()
    if not s.autosuspend_pause_owned or not PluginShare then return false end
    PluginShare.pause_auto_suspend = s.autosuspend_pause_previous
    logger.info("[MiuRead][PseudoLock] Kindle AutoSuspend restored",
        "value=", tostring(s.autosuspend_pause_previous),
        "reason=", tostring(reason or "unknown"))
    s.autosuspend_pause_previous = nil
    s.autosuspend_pause_owned = false
    return true
end

local function recent_power_event(kind, max_age)
    local s = state()
    local age = os.time() - (tonumber(s.last_power_event_at) or 0)
    if age < 0 then age = 999 end
    if kind and s.last_power_kind ~= kind then return nil end
    if age > (tonumber(max_age) or 3) then return nil end
    return {
        kind = s.last_power_kind,
        source = tonumber(s.last_power_source),
        name = tostring(s.last_power_source_name or "unknown"),
        self_injected = s.last_power_self_injected == true,
        age = age,
    }
end

local function record_kindle_power_event(kind, source)
    local s = state()
    local now = os.time()
    local numeric = tonumber(source)
    local self_injected = false
    local injected_ticket = nil

    -- A MiuRead powerButton write may authenticate exactly one matching raw
    -- edge. The ticket is consumed immediately; later BUTTON/HALL events are
    -- never covered by the same injection window.
    local expected_raw_source = kind == "wake" and 1 or (kind == "suspend" and 2 or nil)
    if s.injected_expected_kind == kind and numeric == expected_raw_source
        and now <= (tonumber(s.injected_until) or 0) then
        self_injected = true
        injected_ticket = tonumber(s.injected_ticket) or 0
        s.injected_expected_kind = nil
        s.injected_until = 0
    end

    s.last_power_kind = tostring(kind or "unknown")
    s.last_power_source = numeric
    s.last_power_source_name = power_source_name(numeric, kind)
    s.last_power_event_at = now
    s.last_power_self_injected = self_injected
    s.last_power_injected_ticket = injected_ticket

    local classification = "UNKNOWN"
    if numeric == 6 then
        classification = "USER_COVER"
    elseif (numeric == 1 or numeric == 2) and self_injected then
        classification = "SELF_INJECTED"
    elseif numeric == 1 or numeric == 2 then
        classification = "USER_BUTTON"
    elseif numeric == 4 then
        classification = "COVER_CLOSE"
    end

    logger.info("[MiuRead][PseudoLock][RawPower]",
        "kind=", tostring(kind or "unknown"),
        "source=", tostring(s.last_power_source_name),
        "classification=", classification,
        "self_injected=", tostring(self_injected),
        "ticket=", tostring(injected_ticket or "-"),
        "active=", tostring(s.active == true),
        "system_active=", tostring(s.system_active == true),
        "generation=", tostring(s.generation or 0),
        "injected_reason=", tostring(s.injected_reason or "none"))
    if self_injected then s.injected_reason = nil end
    return self_injected
end

local function device_flag(name)
    local fn = Device and Device[name]
    if type(fn) ~= "function" then return false end
    local ok, yes = pcall(fn, Device)
    return ok and yes == true
end

local function platform_name()
    local kindle = device_flag("isKindle")
    local kobo = device_flag("isKobo")
    -- Special suspend handling is intentionally fail-closed. If a future port
    -- reports an ambiguous identity, treat it as a generic device rather than
    -- risking Kindle/Kobo power operations on the wrong platform.
    if kindle == kobo then return "other" end
    return kindle and "kindle" or "kobo"
end

local function set_frontlight_hw_off()
    local powerd = Device and Device.powerd
    if not powerd then return false end
    -- Do not alter KOReader's logical brightness setting. A normal Resume will
    -- restore the previously requested level; only the panel LEDs are darkened
    -- while the pseudo lock screen is active.
    if type(powerd.turnOffFrontlightHW) == "function" then
        local ok = pcall(powerd.turnOffFrontlightHW, powerd)
        return ok
    end
    return false
end

local function inhibit_non_power_input()
    local s = state()
    if s.phase == PHASE_EXITING or s.exit_requested or s.user_exit_pending then
        logger.info("[MiuRead][PseudoLock] input inhibit skipped during user exit",
            "generation=", tostring(s.generation or 0))
        return false
    end
    if Device and Device.input and type(Device.input.inhibitInput) == "function" then
        local ok = pcall(Device.input.inhibitInput, Device.input, true)
        return ok == true
    end
    return false
end

local function restore_user_input()
    if Device and Device.input and type(Device.input.inhibitInput) == "function" then
        local ok = pcall(Device.input.inhibitInput, Device.input, false)
        return ok == true
    end
    return false
end

local function kindle_power_button(reason)
    local s = state()
    local why = tostring(reason or "unknown")
    if why == "download_complete_real_suspend" then
        s.injected_expected_kind = "suspend"
    else
        s.injected_expected_kind = "wake"
    end
    s.injected_ticket = (tonumber(s.injected_ticket) or 0) + 1
    local ticket = s.injected_ticket
    s.injected_reason = why
    s.injected_until = os.time() + 3
    local issued = false
    local backend = "none"
    local ok_lipc, lipc = pcall(require, "liblipclua")
    if ok_lipc and lipc and type(lipc.init) == "function" then
        local ok_handle, handle = pcall(lipc.init, "com.github.koreader.miuread.pseudolock")
        if ok_handle and handle then
            local ok = pcall(handle.set_int_property, handle, "com.lab126.powerd", "powerButton", 1)
            pcall(handle.close, handle)
            issued = ok == true
            backend = "lipc"
        end
    end
    if not issued then
        local ok = os.execute("lipc-set-prop -i com.lab126.powerd powerButton 1 >/dev/null 2>&1")
        issued = ok == true or ok == 0
        backend = "lipc-cli"
    end
    logger.info("[MiuRead][PseudoLock] kindle power transition requested",
        "reason=", why, "backend=", backend,
        "issued=", tostring(issued), "ticket=", tostring(ticket))
    if not issued then
        s.injected_expected_kind = nil
        s.injected_reason = nil
        s.injected_until = 0
    end
    return issued
end

local function cancel_kobo_real_suspend()
    if type(Device.suspend) == "function" then
        pcall(UIManager.unschedule, UIManager, Device.suspend)
    end
    -- Kobo may have calculated an extended screensaver wait because of extra
    -- anti-ghosting flashes. The pseudo lock owns the screen now, so no delayed
    -- real suspend should remain armed.
    Device.screensaver_suspend_wait_timeout = nil
    logger.info("[MiuRead][PseudoLock] kobo real suspend cancelled")
    return true
end

local function release_pseudo_lease(reason)
    SuspendWorkLease.release("pseudo_lockscreen")
    logger.info("[MiuRead][PseudoLock] lease released", "reason=", tostring(reason or "unknown"))
end

local function clear_runtime(reason)
    local s = state()
    restore_kindle_autosuspend(reason)
    set_phase(s, PHASE_OFF, reason or "clear")
    s.commit_started_at = 0
    s.commit_generation = (tonumber(s.commit_generation) or 0) + 1
    s.commit_suspend_seen = false
    s.commit_native_returned = false
    s.wake_attempts = 0
    s.last_power_kind = nil
    s.last_power_source = nil
    s.last_power_source_name = nil
    s.last_power_event_at = 0
    s.last_power_self_injected = false
    s.injected_expected_kind = nil
    s.injected_reason = nil
    s.injected_until = 0
    s.last_power_injected_ticket = nil
    s.last_reason = tostring(reason or "clear")
    s.generation = (tonumber(s.generation) or 0) + 1
    release_pseudo_lease(reason)
end

local function restore_visible_surface(reason)
    -- Used only when an automatic real-suspend handoff fails while the device
    -- is still awake. Drop the pseudo guards first so Screensaver:close() is
    -- never swallowed by the Kindle private-wake guard. The safe fallback is a
    -- visible, interactive surface rather than an ambiguous half-suspended one.
    clear_runtime(reason or "commit_fallback_visible")
    restore_user_input()
    local ok_ss, Screensaver = pcall(require, "ui/screensaver")
    if ok_ss and Screensaver and type(Screensaver.close) == "function" then
        pcall(Screensaver.close, Screensaver)
    end
    local powerd = Device and Device.powerd
    if powerd and type(powerd.afterResume) == "function" then
        pcall(powerd.afterResume, powerd)
    end
    pcall(UIManager.setDirty, UIManager, "all", "full")
    logger.warn("[MiuRead][PseudoLock] automatic suspend fell back to visible UI",
        "reason=", tostring(reason or "unknown"))
    return true
end

local function invalidate_commit(s)
    s = s or state()
    s.commit_pending = false
    s.commit_started_at = 0
    s.commit_suspend_seen = false
    s.commit_native_returned = false
    -- If the automatic Kindle powerButton request is cancelled by a cover/key
    -- event before its synthetic edge is observed, do not let that stale tag
    -- authenticate a later unrelated power event.
    if s.injected_reason == "download_complete_real_suspend" then
        s.injected_expected_kind = nil
        s.injected_reason = nil
        s.injected_until = 0
    end
    s.commit_generation = (tonumber(s.commit_generation) or 0) + 1
    return s.commit_generation
end

local function arm_user_exit_fallback(generation, reason)
    UIManager:scheduleIn(1.0, function()
        local current = state()
        if current.active and current.generation == generation
            and current.user_exit_pending == true then
            logger.warn("[MiuRead][PseudoLock][UserExit] visible resume fallback",
                "reason=", tostring(reason or "unknown"),
                "generation=", tostring(generation))
            restore_visible_surface("kindle_user_exit_fallback_" .. tostring(reason or "unknown"))
        end
    end)
end

local function begin_user_exit(reason, ev)
    local s = state()
    if not s.active then return false end
    if s.phase == PHASE_EXITING then return true end
    if s.commit_pending or s.phase == PHASE_COMMITTING then invalidate_commit(s) end

    -- User intent is a hard preemption boundary. From this point no stale
    -- synthetic ticket or background callback is allowed to put the screen
    -- back into LOCKED. Power/network/worker cleanup happens later.
    s.injected_expected_kind = nil
    s.injected_reason = nil
    s.injected_until = 0
    s.user_exit_started_at = os.time()
    set_phase(s, PHASE_EXITING, "user:" .. tostring(reason or "unknown"))

    local restored = restore_user_input()
    -- Release the pseudo standby ownership immediately. The actual Amazon
    -- power transition may still need a synthetic user_unlock edge, but user
    -- visibility no longer depends on any download worker or lease.
    release_pseudo_lease("user_exit:" .. tostring(reason or "unknown"))
    local generation = tonumber(s.generation or 0) or 0
    logger.info("[MiuRead][WakePriority]",
        "source=", tostring(reason or "unknown"),
        "phase=", PHASE_EXITING, "action=USER_EXIT",
        "raw=", tostring(ev and ev.name or "none"),
        "self_injected=", tostring(ev and ev.self_injected == true or false),
        "input_restored=", tostring(restored),
        "generation=", tostring(generation))
    arm_user_exit_fallback(generation, reason)
    return true
end

function M.active()
    return state().active == true
end

function M.platform()
    return tostring(state().platform or "other")
end

function M.device_platform()
    return platform_name()
end

function M.background_supported()
    local platform = platform_name()
    return platform == "kindle" or platform == "kobo", platform
end

function M.system_active()
    return state().system_active == true
end

function M.commit_pending()
    return state().commit_pending == true
end

function M.snapshot()
    local s = state()
    return {
        active = s.active == true,
        phase = tostring(s.phase or (s.active and PHASE_LOCKED or PHASE_OFF)),
        phase_changed_at = tonumber(s.phase_changed_at or 0) or 0,
        phase_reason = tostring(s.phase_reason or ""),
        user_exit_started_at = tonumber(s.user_exit_started_at or 0) or 0,
        platform = tostring(s.platform or "other"),
        system_active = s.system_active == true,
        internal_resume_pending = s.internal_resume_pending == true,
        exit_requested = s.exit_requested == true,
        user_exit_pending = s.user_exit_pending == true,
        commit_pending = s.commit_pending == true,
        commit_started_at = tonumber(s.commit_started_at or 0) or 0,
        commit_generation = tonumber(s.commit_generation or 0) or 0,
        commit_suspend_seen = s.commit_suspend_seen == true,
        commit_native_returned = s.commit_native_returned == true,
        entered_at = tonumber(s.entered_at or 0) or 0,
        generation = tonumber(s.generation or 0) or 0,
        wake_attempts = tonumber(s.wake_attempts or 0) or 0,
        download_active = s.download_active == true,
        last_power_kind = s.last_power_kind,
        last_power_source = tonumber(s.last_power_source),
        last_power_source_name = s.last_power_source_name,
        last_power_self_injected = s.last_power_self_injected == true,
        last_power_injected_ticket = tonumber(s.last_power_injected_ticket),
        pending_user_sleep_origin = s.pending_user_sleep_origin,
    }
end

function M.mark_user_sleep(origin)
    local s = state()
    s.pending_user_sleep_origin = tostring(origin or "miuread")
    s.pending_user_sleep_at = os.time()
    logger.info("[MiuRead][PowerEvent] user sleep requested",
        "origin=", s.pending_user_sleep_origin)
    return true
end

function M.consume_user_sleep_origin()
    local s = state()
    local origin = s.pending_user_sleep_origin
    local age = os.time() - (tonumber(s.pending_user_sleep_at) or 0)
    s.pending_user_sleep_origin = nil
    s.pending_user_sleep_at = 0
    if origin and age >= 0 and age <= 5 then return tostring(origin) end
    return nil
end

function M.set_download_active(value)
    local s = state()
    local supported = M.background_supported()
    s.download_active = value == true and supported == true
    if not s.download_active and not s.active then
        s.commit_pending = false
    elseif not s.download_active and s.active then
        -- Do not let a stale pseudo lock outlive its only background owner.
        -- The ordinary completion path also calls background_task_done(); this
        -- delayed check is an idempotent safety net for cancel/hibernate/error
        -- paths that lose their final UI callback.
        local generation = tonumber(s.generation or 0) or 0
        UIManager:scheduleIn(0.30, function()
            local current = state()
            if current.active and current.generation == generation
                and current.download_active ~= true
                and current.user_exit_pending ~= true then
                logger.warn("[MiuRead][PseudoLock][FailOpen] no live download owner",
                    "platform=", tostring(current.platform),
                    "generation=", tostring(generation))
                pcall(M.background_task_done, "download_inactive_safety")
            end
        end)
    end
    return true
end

function M.download_active()
    return state().download_active == true
end

-- Keep the raw Amazon powerd source before KOReader turns it into generic
-- Suspend/Resume callbacks. BUTTON_* and HALL_* are materially different for
-- a pseudo lock: opening a magnetic cover is a real user-visible wake, while
-- the BUTTON_WAKEUP generated by MiuRead's own powerButton write is private.
local function install_kindle_power_source_guard()
    local is_kindle = false
    if type(Device.isKindle) == "function" then
        local ok, value = pcall(Device.isKindle, Device)
        is_kindle = ok and value == true
    end
    if not is_kindle then return false end

    if type(Device.intoScreenSaver) == "function"
        and Device.__miuread_pseudo_into_ss_guard ~= true then
        local original_into = Device.intoScreenSaver
        Device.intoScreenSaver = function(self, source, ...)
            record_kindle_power_event("suspend", source)
            return original_into(self, source, ...)
        end
        Device.__miuread_pseudo_into_ss_guard = true
    end

    if type(Device.outofScreenSaver) == "function"
        and Device.__miuread_pseudo_out_ss_guard ~= true then
        local original_out = Device.outofScreenSaver
        Device.outofScreenSaver = function(self, source, ...)
            local self_injected = record_kindle_power_event("wake", source)
            local s = state()
            local numeric = tonumber(source)
            if s.active then
                if numeric == 6 then
                    -- HALL_WAKEUP can only come from opening the cover. It is a
                    -- hard user-visible wake and must win over every internal
                    -- pseudo-lock/commit state.
                    begin_user_exit("HALL_WAKEUP", recent_power_event("wake", 1))
                elseif numeric == 1 and not self_injected then
                    -- A raw BUTTON_WAKEUP that was not consumed by MiuRead's
                    -- one-shot injection ticket is user intent. Do not reject
                    -- it merely because an older internal resume is still
                    -- pending; that was the lockout race in beta.13-15.
                    begin_user_exit("BUTTON_WAKEUP", recent_power_event("wake", 1))
                elseif numeric == 1 and self_injected then
                    logger.info("[MiuRead][PseudoLock][InternalWake]",
                        "reason=self_injected",
                        "ticket=", tostring(s.last_power_injected_ticket or "-"),
                        "generation=", tostring(s.generation or 0))
                end
            end
            return original_out(self, source, ...)
        end
        Device.__miuread_pseudo_out_ss_guard = true
    end

    -- IntoSS/BUTTON_SUSPEND is not proof of kernel suspend on Kindle, and the
    -- upstream Kindle backend explicitly cannot distinguish a real button from
    -- a synthetic powerButton write. ReadyToSuspend is the later powerd signal
    -- that the system is actually committing suspend, so beta.15 keeps the
    -- pseudo lease until this confirmation arrives.
    if type(Device.readyToSuspend) == "function"
        and Device.__miuread_pseudo_ready_suspend_guard ~= true then
        local original_ready = Device.readyToSuspend
        Device.readyToSuspend = function(self, delay, ...)
            local result = original_ready(self, delay, ...)
            local s = state()
            if s.active and s.platform == "kindle" and s.phase == PHASE_COMMITTING then
                logger.info("[MiuRead][PseudoLock] Kindle real suspend confirmed",
                    "delay=", tostring(delay or ""),
                    "generation=", tostring(s.commit_generation or 0),
                    "suspend_edge=", tostring(s.commit_suspend_seen == true))
                clear_runtime("kindle_ready_to_suspend")
            end
            return result
        end
        Device.__miuread_pseudo_ready_suspend_guard = true
    end
    return true
end

install_kindle_power_source_guard()

-- Kobo's generic KOReader power path normally disables Wi-Fi before it emits
-- Suspend. For a live MiuRead download that would break the very connection we
-- are trying to preserve. Intercept only that first Power/Suspend edge, paint
-- KOReader's normal sleep screen, run the normal beforeSuspend callbacks, but
-- deliberately skip Wi-Fi shutdown and the kernel-suspend timer. If MiuRead's
-- Suspend callback fails to establish the pseudo lock, fall back to KOReader's
-- normal safe Wi-Fi-off + delayed suspend behavior.
local function install_kobo_power_guard()
    local is_kobo = platform_name() == "kobo"
    if not is_kobo or type(Device.onPowerEvent) ~= "function" then return false end
    if Device.__miuread_pseudo_power_guard == true then return true end
    local original = Device.onPowerEvent
    Device.onPowerEvent = function(self, ev)
        local shared = state()

        -- A Kobo pseudo lock never entered kernel suspend. Repeated Suspend
        -- edges (AutoSuspend, a still-closed cover, or duplicate device events)
        -- must therefore stay visual-only; handing one to the native path would
        -- shut Wi-Fi down underneath the live download.
        if shared.active == true and shared.platform == "kobo"
            and self.screen_saver_mode == true and ev == "Suspend" then
            cancel_kobo_real_suspend()
            logger.info("[MiuRead][PseudoLock] repeated Kobo suspend held",
                "generation=", tostring(shared.generation or 0))
            return
        end

        -- The pseudo Kobo screen is visual only; no kernel suspend actually
        -- happened. Handle the next Power/Resume as a pure UI unlock instead of
        -- calling the hardware resume path on a device that never slept.
        if shared.active == true and shared.platform == "kobo"
            and self.screen_saver_mode == true and (ev == "Power" or ev == "Resume") then
            if self.is_cover_closed then
                logger.info("[MiuRead][PseudoLock] Kobo wake ignored while sleep cover remains closed")
                return
            end
            local finishing_real_suspend = shared.commit_native_returned == true
            begin_user_exit(self.is_cover_closed == false and "KoboCoverOrPowerWake" or tostring(ev), nil)
            clear_runtime(finishing_real_suspend and "kobo_real_suspend_resume" or "kobo_user_resume")
            local Screensaver = require("ui/screensaver")
            pcall(UIManager.unschedule, UIManager, self.suspend)
            Screensaver:close()
            self.powerd:afterResume()
            restore_user_input()
            pcall(UIManager.setDirty, UIManager, "all", "full")
            logger.info("[MiuRead][WakePriority]",
                "source=", tostring(ev), "platform=kobo", "action=VISIBLE")
            return
        end

        if shared.download_active == true and self.screen_saver_mode ~= true
            and (ev == "Power" or ev == "Suspend") then
            -- beta.13 waited for Plugin:onSuspend to call begin(), but Kobo's
            -- device handler reaches its Wi-Fi/suspend decision before plugin
            -- listeners finish that same event. Arm the lease first, before any
            -- screensaver or power side effect, so the decision is deterministic.
            local entered, reason = M.begin("kobo_pre_suspend")
            if entered ~= true then
                logger.warn("[MiuRead][PseudoLock] Kobo pre-suspend arm failed; using native suspend",
                    "event=", tostring(ev), "reason=", tostring(reason or "unknown"))
                return original(self, ev)
            end

            local ok, err = xpcall(function()
                local Screensaver = require("ui/screensaver")
                logger.info("[MiuRead][PseudoLock] Kobo pre-suspend armed", "event=", tostring(ev))
                Screensaver:setup()
                Screensaver:show()
                if type(self.needsScreenRefreshAfterResume) == "function" and self:needsScreenRefreshAfterResume() then
                    self.screen:refreshFull(0, 0, self.screen:getWidth(), self.screen:getHeight())
                end
                UIManager:forceRePaint()
                self.powerd:beforeSuspend()
                cancel_kobo_real_suspend()
                set_frontlight_hw_off()
            end, debug.traceback)
            if not ok then
                logger.warn("[MiuRead][PseudoLock] Kobo pseudo suspend setup failed; using native suspend",
                    tostring(err))
                M.force_clear("kobo_pre_suspend_setup_failed")
                return original(self, ev)
            end

            logger.info("[MiuRead][PseudoLock] Kobo kept ACTIVE with native sleep screen",
                "generation=", tostring(state().generation or 0))
            return
        end
        return original(self, ev)
    end
    Device.__miuread_pseudo_power_guard = true
    return true
end

install_kobo_power_guard()

-- Called from MiuRead's Suspend callback after KOReader has already painted the
-- native sleep screen. On Kobo we can cancel the scheduled kernel suspend and
-- simply keep that screen visible. On Kindle Amazon powerd has already entered
-- screenSaver, so beta.11 immediately bounces powerd back to ACTIVE while
-- deliberately keeping KOReader's sleep-screen widget on top.
function M.begin(reason)
    local s = state()
    if s.active then return true, "already_active" end
    local platform = platform_name()
    if platform ~= "kindle" and platform ~= "kobo" then
        return false, "unsupported_platform"
    end
    local lease_ok = SuspendWorkLease.acquire("pseudo_lockscreen")
    if lease_ok ~= true then return false, "lease_failed" end

    s.platform = platform
    s.system_active = platform == "kobo"
    set_phase(s, platform == "kindle" and PHASE_ENTERING or PHASE_LOCKED,
        "begin:" .. tostring(reason or "download"))
    s.injected_expected_kind = nil
    s.injected_reason = nil
    s.injected_until = 0
    s.last_power_injected_ticket = nil
    s.commit_pending = false
    s.commit_started_at = 0
    s.commit_generation = (tonumber(s.commit_generation) or 0) + 1
    s.commit_suspend_seen = false
    s.commit_native_returned = false
    s.entered_at = os.time()
    s.wake_attempts = 0
    s.last_reason = tostring(reason or "download")
    s.generation = (tonumber(s.generation) or 0) + 1

    set_frontlight_hw_off()
    if platform == "kobo" then
        cancel_kobo_real_suspend()
    elseif platform == "kindle" then
        -- KOReader restarts AutoSuspend after every Resume. The private wake
        -- used by PseudoLock is not a user interaction, so letting that timer
        -- run can manufacture another Suspend a few minutes later. Keep the
        -- user's original setting and restore it when the pseudo lock ends.
        pause_kindle_autosuspend()
    end
    logger.info("[MiuRead][PseudoLock] entered",
        "platform=", platform, "reason=", tostring(reason or "download"),
        "generation=", tostring(s.generation))
    return true, platform
end

function M.after_suspend()
    local s = state()
    if not s.active or s.platform ~= "kindle" or s.phase ~= PHASE_ENTERING
        or not s.internal_resume_pending then return false end
    s.wake_attempts = (tonumber(s.wake_attempts) or 0) + 1
    local issued = kindle_power_button("enter_active_pseudo_lock")
    if issued and s.wake_attempts < 2 then
        -- Some firmware ignores a power transition while it is still finishing
        -- the original goingToScreenSaver event. Retry once only if Resume has
        -- not arrived; generation matching prevents a stale retry from running
        -- after a user has already exited the pseudo lock.
        local generation = tonumber(s.generation or 0) or 0
        UIManager:scheduleIn(0.8, function()
            local current = state()
            if current.active and current.generation == generation
                and current.phase == PHASE_ENTERING
                and current.internal_resume_pending then
                current.wake_attempts = (tonumber(current.wake_attempts) or 0) + 1
                kindle_power_button("enter_active_pseudo_lock_retry")
            end
        end)
    end
    return issued
end

-- Kindle's Device:outofScreenSaver normally closes the KOReader sleep-screen
-- widget before broadcasting Resume. During the private wake used to return
-- powerd to ACTIVE, keep that widget in place. This guard is deliberately
-- Kindle-only; Kobo's next Power press must be able to close its native screen.
local function install_screensaver_close_guard()
    local ok, Screensaver = pcall(require, "ui/screensaver")
    if not ok or type(Screensaver) ~= "table" or type(Screensaver.close) ~= "function" then return false end
    if Screensaver.__miuread_pseudo_close_guard == true then return true end
    local original = Screensaver.close
    Screensaver.close = function(self, ...)
        local s = state()
        if s.active and s.platform == "kindle" and s.phase == PHASE_ENTERING
            and s.internal_resume_pending then
            logger.info("[MiuRead][PseudoLock] kept sleep-screen widget during internal Kindle wake")
            return false
        end
        return original(self, ...)
    end
    Screensaver.__miuread_pseudo_close_guard = true
    return true
end

install_screensaver_close_guard()

-- Return values:
--   "hold"  = Kindle's private wake; do NOT run normal MiuRead Resume.
--   "exit"  = a real user-visible wake from pseudo lock; run normal Resume.
--   "normal"= pseudo lock is not involved.
function M.on_resume_event()
    local s = state()
    if not s.active or s.phase == PHASE_OFF then return "normal" end

    if s.phase == PHASE_EXITING then
        local ev = recent_power_event("wake", 4)
        local started = tonumber(s.user_exit_started_at or 0) or 0
        local elapsed_ms = started > 0 and math.max(0, os.time() - started) * 1000 or 0
        logger.info("[MiuRead][PseudoLock][Visible]",
            "source=", tostring(ev and ev.name or "explicit_unlock"),
            "self_injected=", tostring(ev and ev.self_injected == true or false),
            "elapsed_ms=", tostring(elapsed_ms), "fallback=false")
        clear_runtime("user_resume")
        restore_user_input()
        return "exit"
    end

    if s.platform == "kindle" and s.phase == PHASE_ENTERING then
        set_phase(s, PHASE_LOCKED, "internal_resume")
        s.system_active = true
        inhibit_non_power_input()
        set_frontlight_hw_off()
        logger.info("[MiuRead][PseudoLock] Kindle returned ACTIVE behind retained sleep screen",
            "generation=", tostring(s.generation))
        return "hold"
    end

    if s.platform == "kindle" and s.phase == PHASE_LOCKED then
        local ev = recent_power_event("wake", 4)
        s.system_active = true
        inhibit_non_power_input()
        set_frontlight_hw_off()
        logger.info("[MiuRead][PseudoLock] unauthenticated Kindle resume held",
            "source=", tostring(ev and ev.name or "unknown"),
            "self_injected=", tostring(ev and ev.self_injected == true or false),
            "generation=", tostring(s.generation))
        return "hold"
    end

    if s.platform == "kindle" and s.phase == PHASE_COMMITTING then
        -- A lifecycle Resume during the automatic real-suspend handoff is not
        -- permission to expose or to re-arm the download. A genuine BUTTON or
        -- HALL wake is already promoted to EXITING by the raw-source guard.
        logger.info("[MiuRead][PseudoLock] commit-phase resume held",
            "generation=", tostring(s.commit_generation or 0))
        return "commit"
    end

    logger.warn("[MiuRead][PseudoLock] unexpected active phase; failing visible",
        "phase=", tostring(s.phase), "platform=", tostring(s.platform))
    restore_visible_surface("unexpected_resume_phase")
    return "exit"
end

-- Called before ordinary duplicate-Suspend handling. beta.11/12 assumed every
-- second Kindle Suspend was a physical power-key press. That is not safe:
-- KOReader AutoSuspend and other internal powerd edges can produce the same
-- generic callback. beta.13 only accepts a recent raw BUTTON_SUSPEND as the
-- user-key path, keeps HALL_SUSPEND/unknown edges locked, and separately lets
-- HALL_WAKEUP escape through on_resume_event.
function M.on_suspend_while_active()
    local s = state()
    if not s.active then return "none" end

    -- Physical Kindle power intent has absolute priority. The initial key that
    -- entered pseudo lock is seen before M.begin(), so any later unconsumed
    -- BUTTON_SUSPEND belongs to the user. Handle it before system_active or
    -- commit state checks so a stale internal_resume_pending flag cannot trap
    -- the user behind the sleep screen.
    if s.platform == "kindle" then
        local ev = recent_power_event("suspend", 3)
        if ev and ev.source == 2 and not ev.self_injected then
            begin_user_exit("BUTTON_SUSPEND", ev)
            s.internal_resume_pending = true
            s.system_active = false
            local generation = tonumber(s.generation or 0) or 0
            UIManager:scheduleIn(0.12, function()
                local current = state()
                if current.active and current.generation == generation
                    and current.user_exit_pending == true
                    and current.internal_resume_pending == true then
                    kindle_power_button("user_unlock")
                end
            end)
            return "unlock"
        end
    end

    if s.phase == PHASE_COMMITTING then
        if s.platform == "kindle" then
            local ev = recent_power_event("suspend", 3)
            s.commit_suspend_seen = true
            s.system_active = false
            -- IntoSS only means powerd entered the screensaver transition. Keep
            -- the pseudo state/lease until ReadyToSuspend confirms real sleep.
            logger.info("[MiuRead][PseudoLock] Kindle suspend edge observed; awaiting ReadyToSuspend",
                "source=", tostring(ev and ev.name or "none"),
                "self_injected=", tostring(ev and ev.self_injected == true or false),
                "generation=", tostring(s.commit_generation or 0))
            return "hold"
        end
        -- Kobo commits through a synchronous Device.suspend call below, so any
        -- duplicate Suspend edge while the handoff is armed remains visual-only.
        logger.info("[MiuRead][PseudoLock] Kobo automatic suspend handoff already pending",
            "generation=", tostring(s.commit_generation or 0))
        return "hold"
    end

    if s.platform == "kindle" and s.phase == PHASE_LOCKED and s.system_active then
        local ev = recent_power_event("suspend", 3)
        logger.info("[MiuRead][PseudoLock] internal/unknown Kindle suspend held",
            "source=", tostring(ev and ev.name or "none"),
            "self_injected=", tostring(ev and ev.self_injected == true or false),
            "age=", tostring(ev and ev.age or -1),
            "generation=", tostring(s.generation))
        if ev then
            -- A raw goingToScreenSaver edge really did move Amazon powerd away
            -- from ACTIVE. Bounce it back just like the initial pseudo-lock
            -- entry, but keep user_exit_pending false so the sleep screen stays
            -- visible and the Resume remains INTERNAL_WAKE.
            s.internal_resume_pending = true
            s.system_active = false
            local generation = tonumber(s.generation or 0) or 0
            UIManager:scheduleIn(0.15, function()
                local current = state()
                if current.active and current.generation == generation
                    and current.phase == PHASE_LOCKED
                    and current.internal_resume_pending then
                    kindle_power_button("internal_suspend_hold")
                end
            end)
        end
        return "hold"
    end
    return "already_locked"
end

local function other_work_active()
    local snapshot = SuspendWorkLease.snapshot()
    for reason, enabled in pairs(snapshot.reasons or {}) do
        if enabled == true and reason ~= "pseudo_lockscreen" and reason ~= "download" then
            return true, tostring(reason)
        end
    end
    return false, nil
end

local function commit_if_idle()
    local s = state()
    if not s.active or s.phase ~= PHASE_LOCKED then return false end
    local busy, reason = other_work_active()
    if busy then
        logger.info("[MiuRead][PseudoLock] real suspend deferred",
            "reason=", tostring(reason or "background_work"))
        UIManager:scheduleIn(0.6, commit_if_idle)
        return false
    end

    -- A completed worker can briefly reacquire its download lease through a
    -- deferred UI callback even though set_download_active(false) has already
    -- run. No live download remains at this point, so discard that stale claim
    -- before handing power control back to the platform.
    SuspendWorkLease.release("download")

    if s.platform == "kindle" then
        -- Never inject a second power transition while Kindle is already in an
        -- internal screensaver/wake edge. Wait for the pseudo lock to be fully
        -- ACTIVE, which also gives a just-pressed user power key time to win.
        if s.system_active ~= true or s.internal_resume_pending or s.user_exit_pending then
            UIManager:scheduleIn(0.35, commit_if_idle)
            return false
        end
        set_phase(s, PHASE_COMMITTING, "download_finished")
        s.commit_started_at = os.time()
        s.commit_suspend_seen = false
        s.commit_native_returned = false
        s.commit_generation = (tonumber(s.commit_generation) or 0) + 1
        local token = s.commit_generation
        s.internal_resume_pending = false
        logger.info("[MiuRead][PseudoLock] download complete; requesting confirmed Kindle suspend",
            "generation=", tostring(token))
        local issued = kindle_power_button("download_complete_real_suspend")
        if not issued then
            invalidate_commit(s)
            restore_visible_surface("kindle_commit_request_failed")
            return false
        end

        -- If powerd never reaches ReadyToSuspend, do not leave the device in an
        -- ambiguous screenSaver/ACTIVE state. A running timer implies the kernel
        -- never actually slept; recover to a visible UI instead of retrying
        -- suspend indefinitely.
        UIManager:scheduleIn(2.5, function()
            local current = state()
            if not current.active or current.platform ~= "kindle"
                or not current.commit_pending or current.commit_generation ~= token then return end
            logger.warn("[MiuRead][PseudoLock] Kindle real suspend confirmation timed out",
                "generation=", tostring(token),
                "suspend_edge=", tostring(current.commit_suspend_seen == true))
            local saw_suspend = current.commit_suspend_seen == true
            invalidate_commit(current)
            if saw_suspend then
                begin_user_exit("COMMIT_TIMEOUT", nil)
                current = state()
                if current.active then
                    current.internal_resume_pending = true
                    current.system_active = false
                end
                local recovered = kindle_power_button("commit_timeout_visible_recovery")
                if not recovered then
                    restore_visible_surface("kindle_commit_timeout_recovery_failed")
                end
            else
                restore_visible_surface("kindle_commit_timeout_no_suspend_edge")
            end
        end)
        return true
    elseif s.platform == "kobo" then
        set_phase(s, PHASE_COMMITTING, "download_finished")
        s.commit_started_at = os.time()
        s.commit_suspend_seen = false
        s.commit_native_returned = false
        s.commit_generation = (tonumber(s.commit_generation) or 0) + 1
        local token = s.commit_generation
        logger.info("[MiuRead][PseudoLock] download complete; entering confirmed Kobo suspend",
            "generation=", tostring(token))

        -- Restore KOReader's normal Kobo Wi-Fi-off safety rule immediately
        -- before the synchronous kernel suspend call.
        local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
        if ok_nm and NetworkMgr and type(NetworkMgr.isWifiOn) == "function"
            and type(NetworkMgr.disableWifi) == "function" then
            local ok_on, on = pcall(NetworkMgr.isWifiOn, NetworkMgr)
            if ok_on and on == true then pcall(NetworkMgr.disableWifi, NetworkMgr) end
        end

        UIManager:scheduleIn(0.05, function()
            local current = state()
            if not current.active or current.platform ~= "kobo"
                or not current.commit_pending or current.commit_generation ~= token then return end
            if type(Device.suspend) ~= "function" then
                invalidate_commit(current)
                restore_visible_surface("kobo_native_suspend_unavailable")
                return
            end

            -- Keep the pseudo state until the last possible instant, but release
            -- preventStandby immediately before the synchronous native call.
            -- Device.suspend returns only after the kernel has resumed, which is
            -- the confirmation beta.14 was missing. There is no timer gap here.
            SuspendWorkLease.release("pseudo_lockscreen")
            logger.info("[MiuRead][PseudoLock] Kobo native suspend call entered",
                "generation=", tostring(token))
            local ok_suspend, err = pcall(Device.suspend, Device)
            current = state()
            if not current.active or current.platform ~= "kobo"
                or current.commit_generation ~= token then return end
            current.commit_pending = false
            current.commit_native_returned = true
            logger.info("[MiuRead][PseudoLock] Kobo native suspend returned",
                "ok=", tostring(ok_suspend), "generation=", tostring(token),
                "error=", tostring(ok_suspend and "" or err))

            -- Normally the wake Power/Resume edge closes the sleep screen. Keep
            -- a short fallback for boards/firmware that return from suspend
            -- without emitting that edge to KOReader.
            UIManager:scheduleIn(0.35, function()
                local after = state()
                if after.active and after.platform == "kobo"
                    and after.commit_native_returned == true
                    and after.commit_generation == token then
                    restore_visible_surface(ok_suspend and "kobo_resume_event_missing"
                        or "kobo_native_suspend_failed")
                end
            end)
        end)
        return true
    end
    return false
end

function M.background_task_done(reason)
    local s = state()
    if not s.active then return false end
    logger.info("[MiuRead][PseudoLock] background task finished",
        "reason=", tostring(reason or "unknown"), "platform=", tostring(s.platform),
        "phase=", tostring(s.phase or "unknown"))
    -- Small quiet window: if the user presses power/opens the cover exactly as
    -- the worker finishes, that user event is processed before auto-suspend.
    UIManager:scheduleIn(0.35, commit_if_idle)
    return true
end

function M.force_clear(reason)
    if not M.active() then return false end
    clear_runtime(reason or "force_clear")
    return true
end

return M
