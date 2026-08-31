local UIManager = require("ui/uimanager")
local dump = require("dump")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local ok_ffiutil, ffiutil = pcall(require, "ffi/util")

local LearningWriter = {}
LearningWriter.__index = LearningWriter

local POLL_INTERVAL = 0.05
local RETRY_DELAY = 2

local function removeFile(path)
    if path then
        pcall(os.remove, path)
    end
end

local function escapePattern(value)
    return (value:gsub("([^%w])", "%%%1"))
end

local function cleanupStaleFiles(path)
    local directory, basename = path:match("^(.*)/([^/]+)$")
    if not directory or lfs.attributes(directory, "mode") ~= "directory" then
        return
    end
    local escaped = escapePattern(basename)
    local iterator, state = lfs.dir(directory)
    if not iterator then
        return
    end
    for name in iterator, state do
        if name:match("^" .. escaped .. "%.pinyinime%.tmp%.")
                or name:match("^" .. escaped
                    .. "%.old%.pinyinime%.tmp%.") then
            removeFile(directory .. "/" .. name)
        end
    end
end

local function atomicWrite(path, data, token)
    local temporary = string.format("%s.pinyinime.tmp.%s", path, token)
    local backup_temporary = string.format("%s.old.pinyinime.tmp.%s", path, token)
    removeFile(temporary)
    removeFile(backup_temporary)

    local serialized = table.concat({
        "-- ", path, "\nreturn ", dump(data, nil, true), "\n",
    })
    local written, write_err = util.writeToFile(serialized, temporary, true)
    if not written then
        removeFile(temporary)
        return false, write_err or "temporary settings write failed"
    end

    local mode = lfs.attributes(path, "mode")
    local mtime = mode == "file" and lfs.attributes(path, "modification") or nil
    if mtime and mtime < os.time() - 60 then
        local previous, read_err = util.readFromFile(path, "rb")
        if previous then
            local backed_up, backup_err = util.writeToFile(
                previous, backup_temporary, true)
            if not backed_up then
                removeFile(temporary)
                removeFile(backup_temporary)
                return false, backup_err or "settings backup write failed"
            end
            local renamed, rename_err = os.rename(
                backup_temporary, path .. ".old")
            if not renamed then
                removeFile(temporary)
                removeFile(backup_temporary)
                return false, rename_err or "settings backup replace failed"
            end
        elseif read_err then
            removeFile(temporary)
            return false, read_err
        end
    end

    local replaced, replace_err = os.rename(temporary, path)
    if not replaced then
        removeFile(temporary)
        return false, replace_err or "settings replace failed"
    end
    if ok_ffiutil and ffiutil.fsyncDirectory then
        ffiutil.fsyncDirectory(path)
    end
    return true
end

function LearningWriter:new(options)
    cleanupStaleFiles(assert(options.path))
    local instance = setmetatable({
        path = options.path,
        data = assert(options.data),
        on_settled = options.on_settled,
        dirty_generation = 0,
        persisted_generation = 0,
        inflight_generation = nil,
        pid = nil,
        read_fd = nil,
        poll_action = nil,
        restart_action = nil,
        retry_action = nil,
        starts = 0,
        completions = 0,
        failures = 0,
        max_start_ms = 0,
        max_completion_ms = 0,
    }, self)
    return instance
end

function LearningWriter:markDirty(generation)
    if generation then
        self.dirty_generation = math.max(
            self.dirty_generation, generation)
    else
        self.dirty_generation = self.dirty_generation + 1
    end
    return self.dirty_generation
end

function LearningWriter:isInFlight()
    return self.pid ~= nil
end

function LearningWriter:isSettled()
    return not self.pid
        and self.persisted_generation >= self.dirty_generation
end

function LearningWriter:_cancelAction(field)
    local action = self[field]
    if action then
        pcall(UIManager.unschedule, UIManager, action)
        self[field] = nil
    end
end

function LearningWriter:_schedulePoll()
    if self.poll_action then
        return
    end
    local action
    action = function()
        if self.poll_action ~= action then
            return
        end
        self.poll_action = nil
        if not self:_consumeChild(false, true) and self.pid then
            self:_schedulePoll()
        end
    end
    self.poll_action = action
    UIManager:scheduleIn(POLL_INTERVAL, action)
end

function LearningWriter:_scheduleRetry()
    if self.retry_action or self.pid
            or self.persisted_generation >= self.dirty_generation then
        return
    end
    local action
    action = function()
        if self.retry_action ~= action then
            return
        end
        self.retry_action = nil
        self:startAsync()
    end
    self.retry_action = action
    UIManager:scheduleIn(RETRY_DELAY, action)
end

function LearningWriter:_scheduleRestart()
    if self.restart_action or self.pid
            or self.persisted_generation >= self.dirty_generation then
        return
    end
    local action
    action = function()
        if self.restart_action ~= action then
            return
        end
        self.restart_action = nil
        self:startAsync()
    end
    self.restart_action = action
    UIManager:nextTick(action)
end

function LearningWriter:_finishChild(payload, allow_restart)
    local started = os.clock()
    local generation = self.inflight_generation or 0
    local success = payload == "OK:" .. tostring(generation)
    self.pid = nil
    self.read_fd = nil
    self.inflight_generation = nil
    self.completions = self.completions + 1
    if success then
        self.persisted_generation = math.max(
            self.persisted_generation, generation)
    else
        self.failures = self.failures + 1
    end
    if self.on_settled then
        pcall(self.on_settled, success, self:isSettled())
    end
    if allow_restart and not self:isSettled() then
        if success then
            self:_scheduleRestart()
        else
            self:_scheduleRetry()
        end
    end
    self.max_completion_ms = math.max(
        self.max_completion_ms, (os.clock() - started) * 1000)
    return success
end

function LearningWriter:_consumeChild(wait, allow_restart)
    if not self.pid then
        return true
    end
    local checked, done = pcall(
        ffiutil.isSubProcessDone, self.pid, wait == true)
    if not checked or not done then
        return false
    end
    local payload = ""
    if self.read_fd then
        local read_ok, result = pcall(ffiutil.readAllFromFD, self.read_fd)
        if read_ok then
            payload = result
        else
            payload = "ERR:" .. tostring(result)
        end
    end
    return self:_finishChild(payload, allow_restart)
end

function LearningWriter:startAsync()
    if self.pid then
        return true
    end
    if self.persisted_generation >= self.dirty_generation then
        return true
    end
    if not ok_ffiutil or type(ffiutil.runInSubProcess) ~= "function" then
        self:_scheduleRetry()
        return false, "subprocess writer unavailable"
    end
    self:_cancelAction("retry_action")
    self:_cancelAction("restart_action")
    local generation = self.dirty_generation
    local path = self.path
    local data = self.data
    local started = os.clock()
    local launched, pid, read_fd = pcall(ffiutil.runInSubProcess,
        function(child_pid, child_write_fd)
        local ok, result, err = pcall(atomicWrite, path, data, child_pid)
        local payload
        if ok and result then
            payload = "OK:" .. tostring(generation)
        else
            payload = "ERR:" .. tostring(err or result)
        end
        ffiutil.writeToFD(child_write_fd, payload, true)
    end, true)
    self.max_start_ms = math.max(
        self.max_start_ms, (os.clock() - started) * 1000)
    if not launched or not pid then
        self.failures = self.failures + 1
        self:_scheduleRetry()
        return false, launched and read_fd or pid
    end
    self.pid = pid
    self.read_fd = read_fd
    self.inflight_generation = generation
    self.starts = self.starts + 1
    self:_schedulePoll()
    return true
end

function LearningWriter:flushSync()
    self:_cancelAction("poll_action")
    self:_cancelAction("restart_action")
    self:_cancelAction("retry_action")
    if self.pid then
        self:_consumeChild(true, false)
    end
    if self.persisted_generation >= self.dirty_generation then
        return true
    end
    local generation = self.dirty_generation
    local ok, err = atomicWrite(self.path, self.data, "parent")
    if ok then
        self.persisted_generation = generation
        if self.on_settled then
            pcall(self.on_settled, true, true)
        end
        return true
    end
    self.failures = self.failures + 1
    if self.on_settled then
        pcall(self.on_settled, false, false)
    end
    return false, err
end

function LearningWriter:getStats()
    return {
        dirty_generation = self.dirty_generation,
        persisted_generation = self.persisted_generation,
        in_flight = self.pid and 1 or 0,
        poll_tasks = self.poll_action and 1 or 0,
        restart_tasks = self.restart_action and 1 or 0,
        retry_tasks = self.retry_action and 1 or 0,
        starts = self.starts,
        completions = self.completions,
        failures = self.failures,
        max_start_ms = self.max_start_ms,
        max_completion_ms = self.max_completion_ms,
    }
end

return LearningWriter
