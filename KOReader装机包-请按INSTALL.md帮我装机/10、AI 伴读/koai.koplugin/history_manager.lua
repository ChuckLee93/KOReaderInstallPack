-- KOAI history_manager.lua
-- 查询历史存储：保存／加载划词与精读对话记录（最多 50 条）。
-- v1.34 起：文件统一为 settings 目录下的 KOAI_history.json；
-- 读取时自动回退兼容旧位置（settings/ 与 koreader 根目录的 aireadingassistant_history.json）。
local json = require("json")
local util = require("util")

local HistoryManager = {}

-- 目录解析与 settings_storage.lua 保持一致（优先 DataStorage）。
local function getSettingsDir()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage and type(DataStorage.getSettingsDir) == "function" then
        local ok, path = pcall(function() return DataStorage:getSettingsDir() end)
        if ok and path and path ~= "" then return path end
    end

    if util and type(util.getSettingsDir) == "function" then
        local ok, path = pcall(util.getSettingsDir)
        if ok and path and path ~= "" then return path end
    end

    if ok_ds and DataStorage and type(DataStorage.getDataDir) == "function" then
        local ok, path = pcall(function() return DataStorage:getDataDir() end)
        if ok and path and path ~= "" then return path .. "/settings" end
    end

    return "."
end

function HistoryManager:getHistoryPath()
    return getSettingsDir() .. "/KOAI_history.json"
end

-- 旧版路径（仅读取兼容；历史文件曾落在 koreader 根目录）。
local function getLegacyPaths()
    local dir = getSettingsDir()
    local paths = { dir .. "/aireadingassistant_history.json" }
    if dir ~= "." then
        table.insert(paths, "./aireadingassistant_history.json")
    end
    return paths
end

local function readHistoryFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return nil end
    local ok, res = pcall(json.decode, content)
    if ok and type(res) == "table" then return res end
    return nil
end

function HistoryManager:loadHistory()
    local history = readHistoryFile(self:getHistoryPath())
    if not history then
        for _, path in ipairs(getLegacyPaths()) do
            history = readHistoryFile(path)
            if history then break end
        end
    end
    return history or {}
end

function HistoryManager:saveHistory(history)
    local f = io.open(self:getHistoryPath(), "w")
    if not f then return false end
    f:write(json.encode(history or {}))
    f:close()
    return true
end

function HistoryManager:saveConversation(conversation)
    if not conversation or #conversation == 0 then return end

    local history = self:loadHistory()

    table.insert(history, {
        timestamp = os.time(),
        messages = conversation
    })

    -- Keep last 50 conversations to prevent unlimited growth
    if #history > 50 then
        table.remove(history, 1)
    end

    self:saveHistory(history)
end

return HistoryManager
