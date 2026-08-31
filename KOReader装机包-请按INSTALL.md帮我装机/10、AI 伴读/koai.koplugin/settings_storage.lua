-- 合并版 settings_storage.lua
-- v1.34 起设置保存为 settings 目录下的 KOAI_settings.json。
-- 读取时自动回退兼容旧文件：aireadingassistant_settings.json（合并版/10 号旧版）
-- 与 koaireader_settings.json（11 号旧版，白名单键迁移，无需重填 Key）。
local json = require("json")
local util = require("util")

local SettingsStorage = {}

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

function SettingsStorage.getSettingsPath()
  return getSettingsDir() .. "/KOAI_settings.json"
end

-- 旧版存储路径（仅读取回退，保存一律写新文件）。
local function getLegacySettingsPath()
  return getSettingsDir() .. "/aireadingassistant_settings.json"
end

-- 旧版 KOAI 的设置文件（用于一次性迁移）
local function getKoaiSettingsPath()
  return getSettingsDir() .. "/koaireader_settings.json"
end

local function copyDefaults(default_config)
  local copy = {}
  for key, value in pairs(default_config) do
    copy[key] = value
  end
  return copy
end

local function readSettingsFile(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local content = file:read("*a")
  file:close()
  local ok, loaded = pcall(json.decode, content or "")
  if ok and type(loaded) == "table" then return loaded end
  return nil
end

-- 只把 KOAI 白名单键从旧设置合并进来，避免旧文件里的空值覆盖新配置。
local function mergeKoaiSettings(merged, loaded)
  -- 旧 KOAI 若在 DeepSeek 服务商下选过模型，直接迁移为 deepseek_model。
  if type(loaded.provider_models) == "table"
      and loaded.provider_models["DeepSeek (官方)"]
      and loaded.provider_models["DeepSeek (官方)"] ~= "" then
    merged.deepseek_model = loaded.provider_models["DeepSeek (官方)"]
  end
  if type(loaded.thinking_enabled) == "boolean" then
    merged.thinking_enabled = loaded.thinking_enabled
  end
  if type(loaded.auto_expand_to_sentence) == "boolean" then
    merged.auto_expand_to_sentence = loaded.auto_expand_to_sentence
  end
  if type(loaded.resume_prompt_enabled) == "boolean" then
    merged.resume_prompt_enabled = loaded.resume_prompt_enabled
  end
  if tonumber(loaded.resume_after_hours) then
    merged.resume_after_hours = tonumber(loaded.resume_after_hours)
  end
  if type(loaded.auto_capture_enabled) == "boolean" then
    merged.auto_capture_enabled = loaded.auto_capture_enabled
  end
  if tonumber(loaded.result_font_size) then
    merged.result_font_size = tonumber(loaded.result_font_size)
  end
  if loaded.storage_mode == "standard" or loaded.storage_mode == "compact" or loaded.storage_mode == "full" then
    merged.storage_mode = loaded.storage_mode
  end
  if tonumber(loaded.capture_chunk_bytes) then
    merged.capture_chunk_bytes = tonumber(loaded.capture_chunk_bytes)
  end
  if tonumber(loaded.recap_batch_max_bytes) then
    merged.recap_batch_max_bytes = tonumber(loaded.recap_batch_max_bytes)
  end
  if tonumber(loaded.compact_keep_recent_records) then
    merged.compact_keep_recent_records = tonumber(loaded.compact_keep_recent_records)
  end
end

function SettingsStorage.save(config)
  local path = SettingsStorage.getSettingsPath()
  local file = io.open(path, "w")
  if not file then return false end
  -- 剔除 helper 方法，其余全量保存（含 5 个 Prompt 与 power_mode 开关）
  local clean_config = {}
  for k, v in pairs(config) do
    if type(v) ~= "function" then
      clean_config[k] = v
    end
  end
  file:write(json.encode(clean_config))
  file:close()
  return true
end

function SettingsStorage.load(default_config)
  local merged = copyDefaults(default_config)

  -- 1) 本插件的设置：优先新文件 KOAI_settings.json，回退旧版 aireadingassistant_settings.json
  local loaded = readSettingsFile(SettingsStorage.getSettingsPath())
  if not loaded then
    loaded = readSettingsFile(getLegacySettingsPath())
  end
  if loaded then
    for k, v in pairs(loaded) do
      merged[k] = v
    end
  end

  -- 2) 旧版 KOAI 的设置：白名单合并（老用户 Key 直接带过来）
  local koai_loaded = readSettingsFile(getKoaiSettingsPath())
  if koai_loaded then
    mergeKoaiSettings(merged, koai_loaded)
  end

  return merged
end

return SettingsStorage
