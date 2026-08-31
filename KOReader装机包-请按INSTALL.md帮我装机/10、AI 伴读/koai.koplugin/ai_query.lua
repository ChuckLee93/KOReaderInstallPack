-- KOAI ai_query.lua —— DeepSeek 专用请求层（个人自用插件，密钥已写死）
-- 请求清洗、max_tokens/温度控制与友好报错沿用 KOAI；思考模式仅在 DeepSeek 端点有效（本插件只用 DeepSeek）。
local CONFIGURATION
local ok_cfg, result_cfg = pcall(function() return require("configuration") end)
if ok_cfg then
  CONFIGURATION = result_cfg
else
  CONFIGURATION = {}
  print("configuration.lua not found, using defaults")
end

local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local Utils = require("utils")

-- 个人 DeepSeek 账号
local API_URL = "https://api.deepseek.com/chat/completions"
local API_KEY = "输入API密钥"
local DEFAULT_MODEL = "deepseek-v4-flash"

local function cleanMessages(message_history)
  local cleaned = {}
  for _, message in ipairs(message_history or {}) do
    if type(message) == "table" then
      cleaned[#cleaned + 1] = {
        role = tostring(message.role or "user"),
        content = Utils.sanitize_utf8(message.content or ""),
      }
    end
  end
  return cleaned
end

local function formatOpenAIRequest(message_history, model, options)
  options = options or {}
  local request = {
    model = model,
    messages = cleanMessages(message_history),
  }
  -- DeepSeek 思考模式：默认关闭，遇到极难古籍/复杂学术段落可在设置中临时开启。
  if CONFIGURATION.thinking_enabled then
    request.thinking = { type = "enabled" }
    request.reasoning_effort = "high"
  end
  local safety_limit = tonumber(options.max_tokens or CONFIGURATION.response_max_tokens)
  if safety_limit and safety_limit > 0 then request.max_tokens = safety_limit end
  if options.temperature ~= nil then request.temperature = options.temperature end
  return request
end

local function parseOpenAIResponse(response)
  local message = response and response.choices and response.choices[1] and response.choices[1].message
  if message and type(message.content) == "string" and message.content ~= "" then
    return Utils.sanitize_utf8(message.content)
  end
  error("KOAI 返回内容为空或格式异常")
end

local function extractServerMessage(raw_response)
  raw_response = Utils.sanitize_utf8(raw_response or "")
  local ok, data = pcall(json.decode, raw_response)
  if ok and type(data) == "table" and type(data.error) == "table" and data.error.message then
    return Utils.utf8Truncate(tostring(data.error.message), 300, "……")
  end
  local compact = Utils.normalize_whitespace(raw_response)
  if compact ~= "" then return Utils.utf8Truncate(compact, 300, "……") end
  return nil
end

local function conciseHttpError(code, raw_response)
  code = tonumber(code)
  local server_message = extractServerMessage(raw_response)
  if code == 400 then
    return "请求格式被服务商拒绝（HTTP 400）" .. (server_message and ("：" .. server_message) or "")
  elseif code == 401 or code == 403 then
    return "API Key 无效、已撤销或无权限" .. (server_message and ("：" .. server_message) or "")
  elseif code == 402 then
    return "服务商账户余额不足" .. (server_message and ("：" .. server_message) or "")
  elseif code == 429 then
    return "请求过于频繁，请稍后再试" .. (server_message and ("：" .. server_message) or "")
  elseif code and code >= 500 then
    return "服务商暂时不可用" .. (server_message and ("：" .. server_message) or "")
  end
  return "HTTP " .. tostring(code) .. (server_message and ("：" .. server_message) or "")
end

local function queryAI(message_history, options)
  local model = CONFIGURATION.deepseek_model or DEFAULT_MODEL

  local requestBodyTable = formatOpenAIRequest(message_history, model, options)

  local ok_encode, requestBody = pcall(json.encode, requestBodyTable)
  if not ok_encode or not requestBody then
    error("请求内容无法编码，请检查选中文字或本地阅读档案")
  end
  requestBody = Utils.sanitize_utf8(requestBody)

  local headers = {
    ["Content-Type"] = "application/json",
    ["Content-Length"] = tostring(#requestBody),
    ["Authorization"] = "Bearer " .. API_KEY,
  }

  local responseBody = {}

  local res, code = https.request {
    url = API_URL,
    method = "POST",
    headers = headers,
    source = ltn12.source.string(requestBody),
    sink = ltn12.sink.table(responseBody),
  }

  local raw_response = table.concat(responseBody)
  if tonumber(code) ~= 200 then
    error(conciseHttpError(code, raw_response))
  end

  local ok, response = pcall(json.decode, Utils.sanitize_utf8(raw_response))
  if not ok or type(response) ~= "table" then
    error("KOAI 返回了无法解析的数据")
  end

  return parseOpenAIResponse(response)
end

return queryAI
