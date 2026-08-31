-- 合并版 utils.lua
-- 基础取自 KOAI（UTF-8 清洗、截断、去重等完整工具集），
-- 并保留 AI Reading Assistant 的“完整对话记录”显示函数（createConversationText）。
local Utils = {}

local REPLACEMENT = ""

local function isContinuation(byte)
  return byte and byte >= 0x80 and byte <= 0xBF
end

-- 清理损坏的 UTF-8 与 JSON 不接受的控制字符，避免中文在字节边界被截断后导致 HTTP 400。
function Utils.sanitize_utf8(text)
  text = tostring(text or "")
  local out = {}
  local index = 1
  local length = #text
  while index <= length do
    local b1 = text:byte(index)
    if b1 == 9 or b1 == 10 or b1 == 13 then
      out[#out + 1] = string.char(b1)
      index = index + 1
    elseif b1 < 0x20 or b1 == 0x7F then
      out[#out + 1] = " "
      index = index + 1
    elseif b1 <= 0x7F then
      out[#out + 1] = string.char(b1)
      index = index + 1
    elseif b1 >= 0xC2 and b1 <= 0xDF and isContinuation(text:byte(index + 1)) then
      out[#out + 1] = text:sub(index, index + 1)
      index = index + 2
    elseif b1 == 0xE0
        and text:byte(index + 1) and text:byte(index + 1) >= 0xA0 and text:byte(index + 1) <= 0xBF
        and isContinuation(text:byte(index + 2)) then
      out[#out + 1] = text:sub(index, index + 2)
      index = index + 3
    elseif ((b1 >= 0xE1 and b1 <= 0xEC) or (b1 >= 0xEE and b1 <= 0xEF))
        and isContinuation(text:byte(index + 1)) and isContinuation(text:byte(index + 2)) then
      out[#out + 1] = text:sub(index, index + 2)
      index = index + 3
    elseif b1 == 0xED
        and text:byte(index + 1) and text:byte(index + 1) >= 0x80 and text:byte(index + 1) <= 0x9F
        and isContinuation(text:byte(index + 2)) then
      out[#out + 1] = text:sub(index, index + 2)
      index = index + 3
    elseif b1 == 0xF0
        and text:byte(index + 1) and text:byte(index + 1) >= 0x90 and text:byte(index + 1) <= 0xBF
        and isContinuation(text:byte(index + 2)) and isContinuation(text:byte(index + 3)) then
      out[#out + 1] = text:sub(index, index + 3)
      index = index + 4
    elseif b1 >= 0xF1 and b1 <= 0xF3
        and isContinuation(text:byte(index + 1)) and isContinuation(text:byte(index + 2))
        and isContinuation(text:byte(index + 3)) then
      out[#out + 1] = text:sub(index, index + 3)
      index = index + 4
    elseif b1 == 0xF4
        and text:byte(index + 1) and text:byte(index + 1) >= 0x80 and text:byte(index + 1) <= 0x8F
        and isContinuation(text:byte(index + 2)) and isContinuation(text:byte(index + 3)) then
      out[#out + 1] = text:sub(index, index + 3)
      index = index + 4
    else
      out[#out + 1] = REPLACEMENT
      index = index + 1
    end
  end
  return table.concat(out)
end

function Utils.normalize_whitespace(text)
  text = Utils.sanitize_utf8(text)
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  text = text:gsub("\t", " "):gsub(" +", " ")
  text = text:gsub("\n%s+", "\n")
  text = text:gsub("\n\n\n+", "\n\n")
  return text:match("^%s*(.-)%s*$") or ""
end

local function charByteLength(first_byte)
  if not first_byte then return 0 end
  if first_byte <= 0x7F then return 1 end
  if first_byte <= 0xDF then return 2 end
  if first_byte <= 0xEF then return 3 end
  return 4
end

function Utils.utf8Length(text)
  text = Utils.sanitize_utf8(text)
  local count = 0
  local index = 1
  while index <= #text do
    count = count + 1
    index = index + charByteLength(text:byte(index))
  end
  return count
end

function Utils.utf8Chars(text)
  text = Utils.sanitize_utf8(text)
  local chars = {}
  local index = 1
  while index <= #text do
    local size = charByteLength(text:byte(index))
    chars[#chars + 1] = text:sub(index, index + size - 1)
    index = index + size
  end
  return chars
end

function Utils.utf8Truncate(text, max_chars, suffix)
  text = Utils.sanitize_utf8(text)
  max_chars = tonumber(max_chars) or 0
  if max_chars <= 0 then return "" end
  local chars = Utils.utf8Chars(text)
  if #chars <= max_chars then return text end
  local out = {}
  for index = 1, max_chars do out[index] = chars[index] end
  return table.concat(out) .. tostring(suffix or "")
end

function Utils.utf8Tail(text, max_chars)
  local chars = Utils.utf8Chars(text)
  max_chars = tonumber(max_chars) or 0
  if max_chars <= 0 then return "" end
  local first = math.max(1, #chars - max_chars + 1)
  local out = {}
  for index = first, #chars do out[#out + 1] = chars[index] end
  return table.concat(out)
end

function Utils.utf8PrefixByBytes(text, max_bytes)
  text = Utils.sanitize_utf8(text)
  max_bytes = tonumber(max_bytes) or 0
  if max_bytes <= 0 then return "" end
  if #text <= max_bytes then return text end
  local index = 1
  local last = 0
  while index <= #text do
    local size = charByteLength(text:byte(index))
    if index + size - 1 > max_bytes then break end
    last = index + size - 1
    index = index + size
  end
  return text:sub(1, last)
end

function Utils.utf8MiddleTruncate(text, max_chars, marker)
  text = Utils.sanitize_utf8(text)
  max_chars = tonumber(max_chars) or 0
  marker = marker or "\n……\n"
  local chars = Utils.utf8Chars(text)
  if #chars <= max_chars or max_chars <= 0 then return text end
  local left_count = math.floor(max_chars / 2)
  local right_count = max_chars - left_count
  local left, right = {}, {}
  for index = 1, left_count do left[#left + 1] = chars[index] end
  for index = #chars - right_count + 1, #chars do right[#right + 1] = chars[index] end
  return table.concat(left) .. marker .. table.concat(right)
end

function Utils.removePrefixChars(text, count)
  local chars = Utils.utf8Chars(text)
  count = tonumber(count) or 0
  if count <= 0 then return table.concat(chars) end
  local out = {}
  for index = count + 1, #chars do out[#out + 1] = chars[index] end
  return table.concat(out)
end

-- 只比较相邻页面的尾部与头部，避免把原著中合法重复的句子全局删除。
function Utils.longestAdjacentOverlap(previous_text, current_text, max_chars, min_chars)
  local previous = Utils.utf8Chars(Utils.normalize_whitespace(previous_text or ""))
  local current = Utils.utf8Chars(Utils.normalize_whitespace(current_text or ""))
  max_chars = math.min(tonumber(max_chars) or 240, #previous, #current)
  min_chars = tonumber(min_chars) or 12
  for count = max_chars, min_chars, -1 do
    local left, right = {}, {}
    for index = #previous - count + 1, #previous do left[#left + 1] = previous[index] end
    for index = 1, count do right[#right + 1] = current[index] end
    if table.concat(left) == table.concat(right) then return count end
  end
  return 0
end

function Utils.expand_to_sentence(text, prev_context, next_context)
  if not text then return "" end
  prev_context = Utils.sanitize_utf8(prev_context or "")
  next_context = Utils.sanitize_utf8(next_context or "")

  local separators = { "%.", "%?", "%!", "。", "？", "！", ";", "；", "\n" }
  local last_sep_end = 0
  for _, separator in ipairs(separators) do
    local current = 1
    while true do
      local start_pos, end_pos = prev_context:find(separator, current)
      if not start_pos then break end
      if end_pos > last_sep_end then last_sep_end = end_pos end
      current = end_pos + 1
    end
  end
  local prefix = prev_context:sub(last_sep_end + 1)

  local first_sep_end = nil
  for _, separator in ipairs(separators) do
    local start_pos, end_pos = next_context:find(separator)
    if start_pos and (not first_sep_end or end_pos < first_sep_end) then
      first_sep_end = end_pos
    end
  end

  local suffix = first_sep_end and next_context:sub(1, first_sep_end) or next_context
  return Utils.normalize_whitespace(prefix .. text .. suffix)
end

-- KOAI 风格：只返回最后一条 AI 回答（精读场景不把大段上下文刷进查看器）。
function Utils.createResultText(message_history)
  for index = #message_history, 1, -1 do
    if message_history[index].role == "assistant" then
      return Utils.normalize_whitespace(message_history[index].content)
    end
  end
  return ""
end

-- AI Reading Assistant 风格：完整对话记录（原文 + AI 助手逐条）。
function Utils.createConversationText(message_history)
  local _ = require("gettext")
  local result_text = ""
  for i = 1, #message_history do
    if message_history[i].role == "user" then
      result_text = result_text .. _("原文: ") .. message_history[i].content .. "\n\n"
    elseif message_history[i].role == "assistant" then
      result_text = result_text .. _("KOAI: ") .. message_history[i].content .. "\n\n"
    end
  end
  return result_text
end

function Utils.formatNumber(value)
  value = tonumber(value) or 0
  local text = tostring(math.floor(value + 0.5))
  while true do
    local replaced
    text, replaced = text:gsub("^(%-?%d+)(%d%d%d)", "%1,%2")
    if replaced == 0 then break end
  end
  return text
end

return Utils
