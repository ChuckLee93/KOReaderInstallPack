-- KOAI 阅读助手：面向六英寸墨水屏的结构化文本显示格式化。
-- 只改变显示样式，不改写用户已经保存的卡片、复盘与笔记原文。
local TextBoxWidget = require("ui/widget/textboxwidget")

local Formatter = {}

local HEADER = TextBoxWidget.PTF_HEADER
local BOLD_START = TextBoxWidget.PTF_BOLD_START
local BOLD_END = TextBoxWidget.PTF_BOLD_END
local PTF_SUPPORTED = type(HEADER) == "string"
    and type(BOLD_START) == "string"
    and type(BOLD_END) == "string"

local section_headings = {
  ["概要"] = true,
  ["已读内容概要"] = true,
  ["当前进展"] = true,
  ["关键事件"] = true,
  ["人物变化"] = true,
  ["关系变化"] = true,
  ["关键细节"] = true,
  ["典故／文化"] = true,
  ["叙事线索"] = true,
  ["人物关系"] = true,
  ["故事线"] = true,
  ["时间线"] = true,
  ["典故背景"] = true,
  ["地点与组织"] = true,
  ["重要概念"] = true,
  ["未解决问题"] = true,
  ["记忆要点"] = true,
  ["继续阅读注意"] = true,
  ["当前人物"] = true,
  ["当前局势"] = true,
  ["阅读重点"] = true,
  ["例句"] = true,
  ["应用"] = true,
  ["易误读"] = true,
  ["辨认提示"] = true,
  ["译义"] = true,
  ["释义"] = true,
  ["结构"] = true,
  ["语法"] = true,
  ["意象"] = true,
  ["情感"] = true,
  ["背景"] = true,
  ["时代背景"] = true,
  ["政权／家族／阵营"] = true,
  ["因果链"] = true,
  ["故事线／议题"] = true,
  ["共同关系"] = true,
  ["历史影响"] = true,
  ["知识结构"] = true,
  ["核心论点"] = true,
  ["概念联系"] = true,
  ["来源／可靠性"] = true,
}

-- 复盘正文中的这些标签按“标题 + 下一行正文”显示，避免六英寸屏上一整坨。
-- 顶部元信息（阅读模式、本次处理、复盘已处理到等）仍保持紧凑单行。
local block_labels = {
  ["概要"] = true,
  ["已读内容概要"] = true,
  ["当前进展"] = true,
  ["关键事件"] = true,
  ["人物变化"] = true,
  ["关系变化"] = true,
  ["关键细节"] = true,
  ["典故／文化"] = true,
  ["叙事线索"] = true,
  ["人物关系"] = true,
  ["故事线"] = true,
  ["时间线"] = true,
  ["典故背景"] = true,
  ["地点与组织"] = true,
  ["重要概念"] = true,
  ["未解决问题"] = true,
  ["记忆要点"] = true,
  ["继续阅读注意"] = true,
  ["当前人物"] = true,
  ["当前局势"] = true,
  ["阅读重点"] = true,
  ["核心论点"] = true,
  ["概念联系"] = true,
  ["机制／原理"] = true,
  ["应用"] = true,
  ["限制"] = true,
  ["常见误解"] = true,
  ["时代背景"] = true,
  ["因果链"] = true,
  ["后续史实"] = true,
  ["历史影响"] = true,
  ["来源／可靠性"] = true,
}

local card_types = {
  ["人物"] = true,
  ["地点"] = true,
  ["组织"] = true,
  ["事件"] = true,
  ["典故"] = true,
  ["典故／概念"] = true,
  ["概念"] = true,
  ["卡片"] = true,
  ["人物／典故"] = true,
}

local known_labels = {
  ["统一名称"] = true,
  ["名称"] = true,
  ["人物"] = true,
  ["地点"] = true,
  ["组织"] = true,
  ["事件"] = true,
  ["典故"] = true,
  ["概念"] = true,
  ["别名"] = true,
  ["英文原名"] = true,
  ["其他译名／昵称"] = true,
  ["身份"] = true,
  ["身份／含义"] = true,
  ["含义"] = true,
  ["关系"] = true,
  ["当前状态"] = true,
  ["当前故事线"] = true,
  ["作用"] = true,
  ["首次记录"] = true,
  ["最近记录"] = true,
  ["首次出现"] = true,
  ["最近出现"] = true,
  ["首次与最近出现"] = true,
  ["其他译名"] = true,
  ["昵称"] = true,
  ["典故背景"] = true,
  ["辨认提示"] = true,
  ["释义"] = true,
  ["今译"] = true,
  ["字词"] = true,
  ["炼字"] = true,
  ["意象"] = true,
  ["情感"] = true,
  ["修辞"] = true,
  ["背景"] = true,
  ["全诗作用"] = true,
  ["译义"] = true,
  ["翻译"] = true,
  ["结构"] = true,
  ["主干"] = true,
  ["语法"] = true,
  ["词义"] = true,
  ["词汇"] = true,
  ["语气"] = true,
  ["逻辑"] = true,
  ["例句"] = true,
  ["应用"] = true,
  ["易误读"] = true,
  ["概要"] = true,
  ["当前进展"] = true,
  ["关键事件"] = true,
  ["人物变化"] = true,
  ["关系变化"] = true,
  ["关键细节"] = true,
  ["典故／文化"] = true,
  ["叙事线索"] = true,
  ["故事线"] = true,
  ["时间线"] = true,
  ["未解决问题"] = true,
  ["记忆要点"] = true,
  ["继续阅读注意"] = true,
  ["总览"] = true,
  ["阅读模式"] = true,
  ["前序阅读状态"] = true,
  ["跨设备连续性"] = true,
  ["前序内容依据"] = true,
  ["KOAI实时采集起点"] = true,
  ["KOAI实时采集到"] = true,
  ["累计复盘位置"] = true,
  ["本次处理"] = true,
  ["复盘已处理到"] = true,
  ["已保存复盘节点"] = true,
  ["内容依据"] = true,
  ["前序未采集"] = true,
  ["本机正文采集到"] = true,
  ["本机正文采集起点"] = true,
  ["KOAI复盘覆盖到"] = true,
  ["阅读进度记录到"] = true,
  ["上次停留"] = true,
  ["最远已读"] = true,
  ["离开时间"] = true,
  ["限制"] = true,
  ["名称体系"] = true,
  ["时代"] = true,
  ["生卒／在位"] = true,
  ["家族关系"] = true,
  ["政治关系"] = true,
  ["当前文本"] = true,
  ["历史背景"] = true,
  ["关键事件"] = true,
  ["后续史实"] = true,
  ["历史意义"] = true,
  ["史实／来源说明"] = true,
  ["争议／不确定"] = true,
  ["类别"] = true,
  ["定义／身份"] = true,
  ["知识背景"] = true,
  ["机制／原理"] = true,
  ["常见误解"] = true,
  ["共同关系"] = true,
  ["提示"] = true,
  ["需要补全"] = true,
  ["时代背景"] = true,
  ["历史影响"] = true,
  ["来源／可靠性"] = true,
}

local function trim(text)
  text = tostring(text or "")
  return text:match("^%s*(.-)%s*$") or ""
end

local function bold(text)
  text = tostring(text or "")
  if not PTF_SUPPORTED then return text end
  return BOLD_START .. text .. BOLD_END
end

local function cleanControlChars(text)
  text = tostring(text or "")
  if not PTF_SUPPORTED then return text end
  text = text:gsub(HEADER, "")
  text = text:gsub(BOLD_START, "")
  text = text:gsub(BOLD_END, "")
  return text
end


-- v1.2.3：旧版在 AI 返回 JSON 被截断时，会把整段原始 JSON 当作 display 保存。
-- 这里在“显示层”尽量从原始 JSON 中取出最前面的 display 字段，
-- 这样已经生成过的坏复盘无需重新付费，也不会继续在 KO2 上显示代码。
local function utf8FromCodepoint(code)
  code = tonumber(code)
  if not code then return "" end
  if code <= 0x7F then
    return string.char(code)
  elseif code <= 0x7FF then
    return string.char(0xC0 + math.floor(code / 0x40), 0x80 + (code % 0x40))
  elseif code <= 0xFFFF then
    return string.char(
      0xE0 + math.floor(code / 0x1000),
      0x80 + (math.floor(code / 0x40) % 0x40),
      0x80 + (code % 0x40)
    )
  elseif code <= 0x10FFFF then
    return string.char(
      0xF0 + math.floor(code / 0x40000),
      0x80 + (math.floor(code / 0x1000) % 0x40),
      0x80 + (math.floor(code / 0x40) % 0x40),
      0x80 + (code % 0x40)
    )
  end
  return ""
end

local function extractJsonStringField(text, field)
  text = tostring(text or "")
  local pattern = '"' .. tostring(field) .. '"%s*:%s*"'
  local _, open_quote = text:find(pattern)
  if not open_quote then return nil end
  local out, index = {}, open_quote + 1
  while index <= #text do
    local ch = text:sub(index, index)
    if ch == '"' then return table.concat(out) end
    if ch == "\\" then
      local esc = text:sub(index + 1, index + 1)
      if esc == "" then return nil end
      if esc == '"' or esc == "\\" or esc == "/" then
        out[#out + 1] = esc
        index = index + 2
      elseif esc == "n" then
        out[#out + 1] = "\n"
        index = index + 2
      elseif esc == "r" then
        out[#out + 1] = "\r"
        index = index + 2
      elseif esc == "t" then
        out[#out + 1] = "\t"
        index = index + 2
      elseif esc == "b" then
        out[#out + 1] = "\b"
        index = index + 2
      elseif esc == "f" then
        out[#out + 1] = "\f"
        index = index + 2
      elseif esc == "u" then
        local hex = text:sub(index + 2, index + 5)
        if #hex < 4 or not hex:match("^[0-9a-fA-F]+$") then return nil end
        local code = tonumber(hex, 16)
        index = index + 6
        -- 支持 JSON 中的 UTF-16 surrogate pair。
        if code and code >= 0xD800 and code <= 0xDBFF
            and text:sub(index, index + 1) == "\\u" then
          local low_hex = text:sub(index + 2, index + 5)
          local low = tonumber(low_hex, 16)
          if low and low >= 0xDC00 and low <= 0xDFFF then
            code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
            index = index + 6
          end
        end
        out[#out + 1] = utf8FromCodepoint(code)
      else
        -- 非标准转义不强行报错，尽量保留可读字符。
        out[#out + 1] = esc
        index = index + 2
      end
    else
      out[#out + 1] = ch
      index = index + 1
    end
  end
  return nil
end

local function unwrapBrokenRecapJson(text)
  text = tostring(text or "")
  if not text:find('"display"', 1, true) then return text end

  local display = extractJsonStringField(text, "display")
  if not display or display == "" then return text end

  local first_brace = text:find("{", 1, true)
  local display_pos = text:find('"display"', 1, true)
  if not first_brace or not display_pos or first_brace > display_pos then return text end

  -- 只有确实像“正文头部 + JSON”或“纯 JSON”时才替换，避免误伤普通文章。
  local before = text:sub(1, first_brace - 1)
  local trimmed_before = before:match("^%s*(.-)%s*$") or ""
  local looks_json = trimmed_before == ""
      or before:find("```json", 1, true)
      or before:find("```JSON", 1, true)
      or before:find("```Json", 1, true)
  if not looks_json then
    -- KOAI 的复盘头部通常包含这些标签；允许保留头部后只替换 JSON 部分。
    looks_json = before:find("复盘已处理到", 1, true) ~= nil
        or before:find("本次处理", 1, true) ~= nil
  end
  if not looks_json then return text end

  before = before:gsub("```[Jj][Ss][Oo][Nn]%s*$", "")
  before = before:gsub("```%s*$", "")
  before = before:match("^%s*(.-)%s*$") or ""
  if before ~= "" then return before .. "\n\n" .. display end
  return display
end

-- v1.2.4：DeepSeek 偶尔会把多个“标签｜内容”压在同一物理行里，
-- 甚至把上一段的续句放在最前面，例如：
-- “李守中……。｜关键事件｜王夫人……｜人物变化｜李纨……”
-- 旧格式器只识别“行首标签”，于是后半段全部挤成一大坨。
-- 这里仅对 KOAI 已知标签做断行，不会把普通正文中的竖线一概拆掉。
local function escapeLuaPattern(text)
  return (tostring(text or ""):gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end

local function normalizeInlineKnownLabels(text)
  text = tostring(text or "")
  for label, _ in pairs(known_labels) do
    local escaped = escapeLuaPattern(label)
    local replacement = "\n" .. label .. "｜"

    -- 全角／半角竖线以及混用形式：｜标签｜  | 标签 |  ｜标签|  |标签｜
    text = text:gsub("｜%s*" .. escaped .. "%s*｜", replacement)
    text = text:gsub("|%s*" .. escaped .. "%s*|", replacement)
    text = text:gsub("｜%s*" .. escaped .. "%s*|", replacement)
    text = text:gsub("|%s*" .. escaped .. "%s*｜", replacement)

    -- 某些模型会漏掉前一个竖线，直接在句号后接“标签｜”。
    text = text:gsub("([。！？；])%s*" .. escaped .. "%s*｜", "%1\n" .. label .. "｜")
    text = text:gsub("([。！？；])%s*" .. escaped .. "%s*|", "%1\n" .. label .. "｜")
  end
  return text
end

local function isNumberedHeading(line)
  if line:match("^%d+[%.、]%s*.+$") then return true end
  if line:match("^[一二三四五六七八九十]+[、]%s*.+$") then return true end
  return false
end

local function looksLikeBookTitle(line)
  return line:match("^《.-》") ~= nil
end

local function looksLikeBracketHeading(line)
  return line:match("^【.-】$") ~= nil
end

local function appendBlank(lines)
  if #lines == 0 or lines[#lines] ~= "" then table.insert(lines, "") end
end

local function appendDivider(lines)
  appendBlank(lines)
  table.insert(lines, "────────────────")
end

local function splitPipeSegments(line)
  line = tostring(line or "")
  -- 兼容旧卡片中的 ASCII | 和新版全角 ｜。
  line = line:gsub("%s+|%s+", "｜")
  local parts = {}
  local start_index = 1
  while true do
    local pipe_index = line:find("｜", start_index, true)
    if not pipe_index then
      table.insert(parts, trim(line:sub(start_index)))
      break
    end
    table.insert(parts, trim(line:sub(start_index, pipe_index - 1)))
    start_index = pipe_index + #"｜"
  end
  return parts
end

local function isLikelyEntityName(text)
  text = trim(text)
  if text == "" or known_labels[text] or card_types[text] then return false end
  -- UTF-8 字节数限制较宽松，足以覆盖中外文姓名与短典故名。
  return #text <= 72 and not text:find("[。！？；:]$")
end

local function appendLabelLine(output, label, value)
  label = trim(label)
  value = trim(value)
  if label == "" then
    if value ~= "" then table.insert(output, value) end
    return
  end
  if card_types[label] and value ~= "" then
    appendDivider(output)
    table.insert(output, bold("◆ " .. value) .. " 〔" .. label .. "〕")
    table.insert(output, "")
  elseif block_labels[label] and value ~= "" then
    -- 复盘主体：标签独占一行，正文另起一行，并在区块之间留一行。
    appendBlank(output)
    table.insert(output, bold("▌ " .. label))
    table.insert(output, value)
    table.insert(output, "")
  elseif value ~= "" then
    -- 顶部状态、卡片元数据等保持紧凑。
    table.insert(output, bold("▌" .. label .. "｜") .. value)
  else
    appendBlank(output)
    table.insert(output, bold("◆ " .. label))
    table.insert(output, "")
  end
end

-- DeepSeek 偶尔会把整张卡片压成一行：
-- 统一名称｜人物名｜英文原名｜...｜身份｜...
-- 这不是“一个标签对应一个超长值”，而是连续的“标签－内容”对。
local function looksLikeAlternatingLabelPairs(parts)
  if #parts < 4 then return false end
  local pair_count = math.floor(#parts / 2)
  local label_count = 0
  for index = 1, pair_count * 2, 2 do
    if known_labels[trim(parts[index])] then label_count = label_count + 1 end
  end
  return label_count >= 2 and label_count * 2 >= pair_count
end

local function appendAlternatingLabelPairs(output, parts)
  local index = 1
  while index <= #parts do
    local label = trim(parts[index])
    local value = trim(parts[index + 1] or "")
    if known_labels[label] then
      if (label == "统一名称" or label == "名称") and value ~= "" then
        if #output > 0 then appendDivider(output) end
        table.insert(output, bold("◆ " .. value))
        table.insert(output, "")
      else
        appendLabelLine(output, label, value)
      end
      index = index + 2
    else
      if label ~= "" then table.insert(output, "• " .. label) end
      index = index + 1
    end
  end
end

-- 将旧版与新版纯文本统一转换为 TextBoxWidget 轻量粗体标记。
-- 旧数据无需重新调用 AI；每次打开时即时套用样式。
function Formatter.format(text)
  text = unwrapBrokenRecapJson(text)
  text = cleanControlChars(text)
  if not PTF_SUPPORTED then return text:gsub("[#*]", "") end
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  text = normalizeInlineKnownLabels(text)
  text = text:gsub("[#*]", "")

  local output = {}
  local first_nonempty_seen = false
  local previous_was_blank = false

  for raw_line in (text .. "\n"):gmatch("(.-)\n") do
    local line = trim(raw_line)

    if line == "" then
      if not previous_was_blank and #output > 0 then table.insert(output, "") end
      previous_was_blank = true
    else
      previous_was_blank = false
      local parts = splitPipeSegments(line)

      if not first_nonempty_seen then
        first_nonempty_seen = true
        if looksLikeAlternatingLabelPairs(parts) then
          appendAlternatingLabelPairs(output, parts)
        elseif #parts >= 2 and card_types[parts[1]] and parts[2] ~= "" then
          table.insert(output, bold("◆ " .. parts[2]) .. " 〔" .. parts[1] .. "〕")
          table.insert(output, "")
          for index = 3, #parts do
            if parts[index] ~= "" then table.insert(output, "• " .. parts[index]) end
          end
        elseif #parts >= 3 and isLikelyEntityName(parts[1]) then
          -- 兼容旧版 AI 返回的单行卡片：姓名｜说明｜关系｜出场｜作用。
          table.insert(output, bold("◆ " .. parts[1]))
          table.insert(output, "")
          for index = 2, #parts do
            if parts[index] ~= "" then table.insert(output, "• " .. parts[index]) end
          end
        elseif #parts >= 2 and known_labels[parts[1]] then
          appendLabelLine(output, parts[1], table.concat(parts, "｜", 2))
        else
          table.insert(output, bold(line))
          table.insert(output, "")
        end
      elseif looksLikeAlternatingLabelPairs(parts) then
        appendAlternatingLabelPairs(output, parts)
      elseif #parts >= 2 and card_types[parts[1]] and parts[2] ~= "" then
        appendLabelLine(output, parts[1], parts[2])
        for index = 3, #parts do
          if parts[index] ~= "" then table.insert(output, "• " .. parts[index]) end
        end
      elseif #parts >= 3 and isLikelyEntityName(parts[1]) then
        appendDivider(output)
        table.insert(output, bold("◆ " .. parts[1]))
        table.insert(output, "")
        for index = 2, #parts do
          if parts[index] ~= "" then table.insert(output, "• " .. parts[index]) end
        end
      elseif #parts >= 2 and (known_labels[parts[1]] or #parts == 2) then
        appendLabelLine(output, parts[1], table.concat(parts, "｜", 2))
      elseif section_headings[line] or isNumberedHeading(line) or looksLikeBracketHeading(line) then
        appendBlank(output)
        table.insert(output, bold("◆ " .. line))
        table.insert(output, "")
      elseif looksLikeBookTitle(line) then
        appendDivider(output)
        table.insert(output, bold(line))
        table.insert(output, "")
      elseif line:match("^•") or line:match("^[%-·] ") then
        table.insert(output, "  " .. line)
      else
        table.insert(output, line)
      end
    end
  end

  while #output > 0 and output[#output] == "" do table.remove(output) end
  return HEADER .. table.concat(output, "\n")
end

return Formatter
