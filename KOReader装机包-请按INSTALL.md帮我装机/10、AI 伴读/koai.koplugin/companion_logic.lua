-- KOAI 阅读助手：多对象卡片、分类型阅读模式、增量复盘与本地数据管理。
-- 修改版，GPLv3；详见 NOTICE.md。
local AICompanionViewer = require("aicompanionviewer")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local json = require("json")
local queryAI = require("ai_query")
local Storage = require("companion_storage")
local Utils = require("utils")

local Logic = {}

local function showText(title, text)
  UIManager:show(AICompanionViewer:new {
    title = title,
    text = Utils.normalize_whitespace(text or ""),
    disable_save_note = true,
    rich_text = true, -- 合并版：KOAI 输出启用富文本分层显示
  })
end

local function extractJson(raw)
  raw = Utils.sanitize_utf8(raw or "")
  raw = raw:gsub("^%s*```[Jj][Ss][Oo][Nn]%s*", "")
  raw = raw:gsub("^%s*```%s*", "")
  raw = raw:gsub("%s*```%s*$", "")
  local first = raw:find("{", 1, true)
  local last
  for index = #raw, 1, -1 do
    if raw:sub(index, index) == "}" then last = index; break end
  end
  if not first or not last or last <= first then return nil end
  local ok, data = pcall(json.decode, raw:sub(first, last))
  if ok and type(data) == "table" then return data end
  return nil
end


-- 仅用于 JSON 被截断时给用户展示“已生成的可读摘要”，不据此标记批次完成。
-- display 位于返回 JSON 最前面，因此即使后面的 characters 数组过长被截断，通常仍可完整取出。
local function extractJsonStringField(raw, field)
  raw = Utils.sanitize_utf8(raw or "")
  local pattern = '"' .. tostring(field) .. '"%s*:%s*"'
  local _, open_quote = raw:find(pattern)
  if not open_quote then return nil end
  local out, index = {}, open_quote + 1
  while index <= #raw do
    local ch = raw:sub(index, index)
    if ch == '"' then return table.concat(out) end
    if ch == "\\" then
      local esc = raw:sub(index + 1, index + 1)
      if esc == "" then return nil end
      if esc == '"' or esc == "\\" or esc == "/" then out[#out + 1] = esc
      elseif esc == "n" then out[#out + 1] = "\n"
      elseif esc == "r" then out[#out + 1] = "\r"
      elseif esc == "t" then out[#out + 1] = "\t"
      else out[#out + 1] = esc end
      index = index + 2
    else
      out[#out + 1] = ch
      index = index + 1
    end
  end
  return nil
end

local function runAI(title, messages, callback, options, error_callback)
  NetworkMgr:runWhenOnline(function()
    local waiting = InfoMessage:new {text = title .. "，请稍候……"}
    UIManager:show(waiting)
    UIManager:nextTick(function()
      local ok, result = pcall(function() return queryAI(messages, options or {}) end)
      UIManager:close(waiting)
      if not ok or not result then
        if error_callback then error_callback(tostring(result))
        else UIManager:show(InfoMessage:new {text = "调用失败：" .. tostring(result), timeout = 12}) end
        return
      end
      callback(result)
    end)
  end)
end

local function trimContext(text, max_chars)
  text = Utils.normalize_whitespace(text or "")
  return Utils.utf8MiddleTruncate(
    text,
    tonumber(max_chars) or 8000,
    "\n……（仅压缩本次 API 上下文，本地数据仍完整保留）……\n"
  )
end

local function joinCardValue(value)
  if type(value) == "table" then
    local parts = {}
    for _, item in ipairs(value) do
      local text
      if type(item) == "table" then
        text = item.name or item.title or item.summary or item.event or ""
      else
        text = tostring(item or "")
      end
      text = Utils.normalize_whitespace(text)
      if text ~= "" then parts[#parts + 1] = text end
    end
    return table.concat(parts, "、")
  end
  return Utils.normalize_whitespace(tostring(value or ""))
end

local function normalizeEntityType(value)
  value = Utils.normalize_whitespace(value or "")
  if value:find("地点", 1, true) then return "地点" end
  if value:find("组织", 1, true) or value:find("政权", 1, true) or value:find("家族", 1, true) then return "组织" end
  if value:find("事件", 1, true) then return "事件" end
  if value:find("典故", 1, true) then return "典故" end
  if value:find("概念", 1, true) or value:find("制度", 1, true) then return "概念" end
  return "人物"
end

local function modeDisplay(info)
  if info.automatic then
    return info.effective_label .. "（自动判断）"
  end
  return info.effective_label .. "（本书手动设置）"
end

local GROUP_MARKERS = {
  "三家", "诸侯", "群臣", "诸将", "诸王", "群雄", "众人", "各国", "双方",
  "集团", "家族", "阵营", "等人", "诸子", "百家", "联军", "诸国",
}

-- 只做保守的本地兜底。最终对象数量仍由模型结合语境判断，避免把“韩、赵、魏三家”误拆成三个人。
local function splitSelectedCandidates(text)
  text = Utils.normalize_whitespace(text or "")
  if text == "" then return {} end
  for _, marker in ipairs(GROUP_MARKERS) do
    if text:find(marker, 1, true) then return {} end
  end
  local normalized = text:gsub("\n", "、"):gsub("，", "、"):gsub(",", "、")
  normalized = normalized:gsub("；", "、"):gsub(";", "、")
  normalized = normalized:gsub("%s+[与和及]%s+", "、")
  if not normalized:find("、", 1, true) then return {} end
  local result, seen = {}, {}
  for part in (normalized .. "、"):gmatch("(.-)、") do
    part = Utils.normalize_whitespace(part)
    local leading = {"《", "〈", "【", "[", "（", "(", "“", "‘"}
    local trailing = {"》", "〉", "】", "]", "）", ")", "”", "’"}
    local changed = true
    while changed do
      changed = false
      for _, mark in ipairs(leading) do
        if part:sub(1, #mark) == mark then part = part:sub(#mark + 1); changed = true; break end
      end
    end
    changed = true
    while changed do
      changed = false
      for _, mark in ipairs(trailing) do
        if #part >= #mark and part:sub(-#mark) == mark then part = part:sub(1, #part - #mark); changed = true; break end
      end
    end
    part = Utils.normalize_whitespace(part)
    local length = Utils.utf8Length(part)
    local has_sentence_punctuation = part:find("。", 1, true) or part:find("！", 1, true)
        or part:find("？", 1, true) or part:find("：", 1, true) or part:find(":", 1, true)
    if part == "" or length < 2 or length > 18 or has_sentence_punctuation then return {} end
    local key = part:gsub("%s+", "")
    if not seen[key] then result[#result + 1] = part; seen[key] = true end
  end
  if #result < 2 or #result > 6 then return {} end
  return result
end

local function cardHasName(card, candidate)
  local target = Utils.normalize_whitespace(candidate or ""):gsub("%s+", "")
  local names = {card.name, card.title}
  if type(card.aliases) == "table" then
    for _, alias in ipairs(card.aliases) do names[#names + 1] = alias end
  end
  for _, name in ipairs(names) do
    local key = Utils.normalize_whitespace(name or ""):gsub("%s+", "")
    if key ~= "" and key == target then return true end
  end
  return false
end

local function buildCardDisplay(card, mode_info)
  local lines = {}
  local function add(label, value)
    value = joinCardValue(value)
    if value ~= "" and value ~= "无" then lines[#lines + 1] = label .. "｜" .. value end
  end

  local card_type = normalizeEntityType(card.type or card.category)
  lines[#lines + 1] = card_type .. "｜" .. tostring(card.name or card.title or "未命名")

  if mode_info.effective == "history" then
    add("名称体系", card.name_system)
    add("英文原名", card.original_name or card.english_name)
    add("别名", card.aliases)
    add("时代", card.era)
    add("生卒／在位", card.dates)
    add("身份／含义", card.identity or card.description)
    add("家族关系", card.family_relations)
    add("政治关系", card.political_relations)
    add("关系", card.relationships)
    add("当前文本", card.current_text or card.text_role)
    add("历史背景", card.historical_background or card.background)
    add("关键事件", card.key_events)
    add("后续史实", card.later_history)
    add("历史意义", card.historical_significance or card.significance)
    add("史实／来源说明", card.source_note)
    add("争议／不确定", card.controversies)
    add("辨认提示", card.identification_tip or card.tip)
  elseif mode_info.effective == "knowledge" then
    add("英文原名", card.original_name or card.english_name)
    add("别名", card.aliases)
    add("类别", card.category_detail or card.type)
    add("定义／身份", card.definition or card.identity or card.description)
    add("知识背景", card.knowledge_background or card.background)
    add("机制／原理", card.mechanism)
    add("关系", card.relationships)
    add("当前文本", card.current_text or card.text_role)
    add("应用", card.applications)
    add("常见误解", card.misconceptions)
    add("作用", card.significance)
    add("来源／不确定", card.source_note or card.controversies)
  else
    add("英文原名", card.original_name or card.english_name)
    add("其他译名／昵称", card.aliases)
    add("身份／含义", card.identity or card.description)
    add("关系", card.relationships)
    add("当前状态", card.current_status or card.status)
    add("当前故事线", card.current_storyline or card.storyline)
    add("作用", card.significance)
    add("首次记录", card.first_seen)
    add("最近记录", card.last_seen)
    add("典故背景", card.background)
    add("辨认提示", card.identification_tip or card.tip)
  end

  if card.needs_enrichment == true then
    add("需要补全", "模型本次未能返回该对象的独立字段；已先建立独立卡片，可再次单独划选更新。")
  end
  return table.concat(lines, "\n")
end

local function fallbackCards(selected_text, raw, position, mode_info)
  local candidates = splitSelectedCandidates(selected_text)
  if #candidates == 0 then candidates = {selected_text} end
  local cards = {}
  for _, name in ipairs(candidates) do
    cards[#cards + 1] = {
      name = name,
      aliases = {},
      type = "人物",
      current_text = Utils.utf8Truncate(Utils.normalize_whitespace(raw or ""), 600, "……"),
      first_seen = position.chapter,
      last_seen = position.chapter,
      reading_mode = mode_info.effective,
      mode_label = mode_info.effective_label,
      needs_enrichment = #candidates > 1,
    }
  end
  return cards
end

local function normalizeResponseCards(data, selected_text, raw, position, mode_info)
  local cards = {}
  if type(data) == "table" and type(data.cards) == "table" then
    for _, item in ipairs(data.cards) do if type(item) == "table" then cards[#cards + 1] = item end end
  elseif type(data) == "table" and type(data.card) == "table" then
    cards[1] = data.card
  end
  if #cards == 0 then return fallbackCards(selected_text, raw, position, mode_info) end

  local candidates = splitSelectedCandidates(selected_text)
  if #candidates > 1 then
    local returned = {}
    for _, card in ipairs(cards) do
      for _, candidate in ipairs(candidates) do
        if cardHasName(card, candidate) then returned[candidate] = true end
      end
    end

    -- 若模型仍把多人合成一个名字，不保存错误的合并卡；为每个对象建立独立兜底卡。
    local combined_only = #cards == 1 and not returned[candidates[1]]
    if combined_only then cards = {} end
    for _, candidate in ipairs(candidates) do
      if not returned[candidate] then
        cards[#cards + 1] = {
          name = candidate,
          type = "人物",
          current_text = type(data) == "table" and (data.selection_summary or data.shared_relationship) or "",
          shared_context = type(data) == "table" and data.shared_relationship or "",
          needs_enrichment = true,
        }
      end
    end
  end

  local normalized = {}
  for _, card in ipairs(cards) do
    local name = Utils.normalize_whitespace(card.name or card.title or "")
    if name ~= "" then
      card.name = name
      card.type = normalizeEntityType(card.type or card.category)
      card.aliases = type(card.aliases) == "table" and card.aliases or (card.aliases and {card.aliases} or {})
      card.first_seen = card.first_seen or position.chapter
      card.last_seen = card.last_seen or position.chapter
      card.reading_mode = mode_info.effective
      card.mode_label = mode_info.effective_label
      normalized[#normalized + 1] = card
    end
  end
  if #normalized == 0 then return fallbackCards(selected_text, raw, position, mode_info) end
  return normalized
end

local function buildCardSystemPrompt(mode_info)
  local common = [=[你是 KOAI 的人物、地点、组织、事件、典故与概念识别助手。用户可能一次划选一个对象，也可能划选多个并列对象。

对象拆分规则：
1. 必须先判断选区包含几个独立对象。像“韩康子、魏桓子”必须返回两张独立人物卡，绝不能把两个人名合成一张卡。
2. 每个独立人物、地点、组织、事件或概念分别放入 cards 数组的一项。
3. 如果选区本身指一个集合或集团，例如“韩、赵、魏三家”，可以建立一张组织／集团卡，不要机械拆成三个人。
4. 多个对象共同参与同一事件时，在 shared_relationship 中概括共同关系；个体信息仍分别写入各自卡片。
5. 已存在的别名、译名、姓氏、字、谥号、封号应归并；不能确定时明确标注，不得强行合并。
6. 只返回严格 JSON，不使用 Markdown 代码块，不在 JSON 外输出文字。

统一 JSON 格式：
{
  "cards":[{
    "name":"一个独立对象的统一名称",
    "type":"人物／地点／组织／事件／典故／概念",
    "aliases":["其他名称"],
    "original_name":"外文原名，没有则为空",
    "name_system":"姓名、字、谥号、庙号、封号等名称体系",
    "era":"时代",
    "dates":"生卒、在位或活动时间",
    "identity":"身份或准确含义",
    "family_relations":"家族关系",
    "political_relations":"政治关系",
    "relationships":"与当前相关对象的关系",
    "current_text":"当前选段实际说明了什么、该对象在本段的作用",
    "current_status":"截至当前文本的状态",
    "current_storyline":"当前故事线",
    "historical_background":"帮助理解所需的历史背景",
    "key_events":["关键事件"],
    "later_history":"后续史实或完整结局",
    "historical_significance":"历史意义",
    "knowledge_background":"完整知识背景",
    "mechanism":"机制或原理",
    "applications":"应用",
    "misconceptions":"常见误解",
    "significance":"对当前阅读的作用",
    "source_note":"哪些来自当前文本、哪些属于通行背景；可靠性说明",
    "controversies":"存在争议或不能确认之处",
    "identification_tip":"辨认提示",
    "first_seen":"本书首次可确认位置",
    "last_seen":"当前章节"
  }],
  "shared_relationship":"多个对象之间的共同关系；单对象时为空字符串",
  "selection_summary":"对本次选区的简短识别说明"
}]=]

  if mode_info.effective == "history" then
    return common .. [=[

当前为“历史／传记模式”。
1. 允许并且应当补充完整、通行的历史事实，不把人物后续生平、事件结果和历史影响视为剧透。
2. 对中国古代人物，优先解释姓、氏、名、字、谥号、庙号、封号、官职和所属家族／政治集团；不要把无实际帮助的拼音当成重点。
3. 必须明确区分：current_text 是当前节选实际讲到的内容；historical_background、later_history 和 historical_significance 是为理解而补充的通行史实。
4. 应解释事件前因、权力关系、制度背景、关键转折、后续结果和历史意义，使节选本也能独立读懂。
5. 史实存在争议、年代不确定或不同史籍记载不一时，写入 controversies 或 source_note，不得编造确定答案。]=]
  elseif mode_info.effective == "knowledge" then
    return common .. [=[

当前为“学术／知识模式”。
1. 不受剧情剧透限制，应补全定义、理论背景、机制、上下位概念、应用和常见误解。
2. 明确区分当前文本主张与通用知识背景；证据不足或学界有争议时必须注明。
3. 对人物可补充其完整学术身份与贡献；对概念应优先帮助用户建立可迁移的知识结构。]=]
  end

  return common .. [=[

当前为“小说／剧情模式”。
1. 严格只使用用户已经读到的语境和本地已读档案，不得透露后续剧情、隐藏身份、结局或尚未揭晓的关系。
2. current_text、current_status 和 current_storyline 只写截至当前阅读位置已经确认的信息。
3. 不能确定时直接说明，不得借助原著完整知识提前揭晓。]=]
end

local function mergeRecapData(book, data, position, raw, processed, mode_info)
  data = type(data) == "table" and data or {}
  local display = data.display or data.recap or data.summary or raw
  local resume = data.resume or data.continue_reading or display
  local recap = {
    chapter = position.chapter,
    chapter_key = position.chapter_key,
    page = position.page,
    percent = position.percent,
    created_at = os.time(),
    display = Utils.normalize_whitespace(tostring(display or "")),
    resume = Utils.normalize_whitespace(tostring(resume or "")),
    reading_mode = mode_info.effective,
    mode_label = mode_info.effective_label,
    processed_capture_id = processed and processed.last_id or nil,
    processed_chars = processed and processed.chars or nil,
    processed_count = processed and processed.count or nil,
  }
  Storage.saveRecap(book, position.chapter_key, recap)

  if type(data.characters) == "table" then
    for _, card in ipairs(data.characters) do
      if type(card) == "table" then
        card.type = card.type or "人物"
        card.first_seen = card.first_seen or position.chapter
        card.last_seen = position.chapter
        card.reading_mode = mode_info.effective
        card.mode_label = mode_info.effective_label
        Storage.mergeCard(book, card)
      end
    end
  end
  if type(data.allusions) == "table" then
    for _, card in ipairs(data.allusions) do
      if type(card) == "table" then
        card.type = card.type or "典故／概念"
        card.first_seen = card.first_seen or position.chapter
        card.last_seen = position.chapter
        card.reading_mode = mode_info.effective
        card.mode_label = mode_info.effective_label
        Storage.mergeCard(book, card)
      end
    end
  end

  local world = Storage.loadWorld(book)
  local keys = {
    "current_state", "storylines", "timeline", "relationships", "era_context", "factions",
    "causal_chain", "historical_impact", "source_note", "knowledge_map", "arguments",
    "concept_links", "open_questions",
  }
  for _, key in ipairs(keys) do if data[key] ~= nil then world[key] = data[key] end end
  world.chapter = position.chapter
  world.reading_mode = mode_info.effective
  world.mode_label = mode_info.effective_label
  Storage.saveWorld(book, world)
  if processed then Storage.markRecapProcessed(book, processed.last_id, position, processed.chars) end
  return recap
end

local function buildRecapSystemPrompt(mode_info)
  local common = [=[你是 KOAI 的长篇阅读增量复盘助手。请把“上一版累计复盘”和“本次新增已读文字”合并成新的累计复盘，并同步更新人物、典故、关系、故事线和时间线。

共同规则：
1. 上一版累计复盘代表已经建立的阅读记忆，本次新增文字代表这次需要吸收的内容。阅读记忆既可以来自 KOAI 实时采集，也可以来自用户明确确认“前文已读”后，插件从当前这一本电子书的起点回溯到首次 KOAI 采集点所建立的前序精读档案。不要机械重复旧内容。
2. 同名人物、多种译名、姓氏、字、谥号、昵称应归并；不能确定时明确标注，不得强行合并。
3. 每个独立人物分别放入 characters 数组，不能把“人物A、人物B”合成一个 name。
4. 返回严格 JSON，不使用 Markdown 代码块，不在 JSON 外输出文字。
5. display 是用户真正阅读的“累计精读复盘”，以完整、准确、真正帮助继续阅读为标准，不设固定字数，也不设固定栏目数量。简单内容自然短，复杂内容充分展开；不得为了“精炼”主动删掉重要人物、关系变化、关键细节、文化语境、叙事作用或尚待追踪的线索。
6. characters、allusions、relationships、storylines、timeline 等结构化字段也不设固定对象数量。只记录本批新增、首次出现、状态明显变化，或对后续理解确有长期价值的对象；不要机械罗列无变化对象，也不能因为预设数量而遗漏重要对象。
7. 若输出空间发生技术性压力，优先保证 display 完整，其次保留对后续阅读最关键的结构化更新；不要用“最多几个”“控制在多少字”之类规则人为截断内容。
8. display 不能写成事件流水账。对重要内容应说明“发生了什么 + 为什么重要 + 人物/关系/故事线发生了什么变化 + 继续阅读需要记住什么”。
9. 跨设备阅读必须尊重用户确认的前序阅读状态：
- 若用户选择“前文已读”，并且 KOAI 已从当前这一本电子书回溯提取了首次采集点之前的原文，则这部分“前序补建档案”与实时采集正文具有同等的已读上下文地位，应自然融入累计精读，不要把它当成缺失内容。
- 若用户选择“前文未读”，或尚未完成前序补建，则不得凭模型记忆、作品常识或网络知识把首次采集点之前的剧情伪装成用户已读内容。
- 小说模式始终不得使用当前阅读位置之后的内容。

JSON 格式：
{
  "display":"适合六英寸墨水屏阅读的新累计复盘，使用短段落和标签｜",
  "resume":"下次重新打开书时显示的精炼回顾",
  "current_state":"当前整体局势或知识状态",
  "characters":[{"name":"独立人物名","aliases":[],"type":"人物","identity":"身份","relationships":"关系","current_status":"状态","current_text":"当前文本作用","historical_background":"历史背景","later_history":"后续史实","historical_significance":"历史意义","source_note":"来源说明","first_seen":"首次位置"}],
  "allusions":[{"name":"典故、地点、组织、事件或概念","aliases":[],"type":"类型","identity":"含义","significance":"作用"}],
  "relationships":[{"from":"对象A","relation":"关系","to":"对象B"}],
  "storylines":[{"name":"故事线／议题","summary":"推进","status":"状态","people":["涉及对象"],"unresolved":["未解决问题"]}],
  "timeline":[{"time":"时间或顺序","event":"事件"}],
  "era_context":"时代或总体背景",
  "factions":[{"name":"政权／家族／阵营","position":"立场和力量"}],
  "causal_chain":["原因→过程→结果"],
  "historical_impact":"历史影响",
  "source_note":"当前文本与外部背景的区分、可靠性说明",
  "knowledge_map":["概念关系"],
  "arguments":["核心论点与依据"],
  "concept_links":["概念之间的联系"],
  "open_questions":["尚待理解的问题"]
}]=]

  if mode_info.effective == "history" then
    return common .. [=[

当前为“历史／传记模式”。
1. 允许并应补充理解本段所需的完整通行史实，包括事件前因、后续结果、人物完整生平和历史影响；这些不视为剧透。
2. display 固定优先使用这些可读标签（无内容的标签可以省略）：
概要｜……
当前局势｜……
关键事件｜……
人物关系｜……
时代背景｜……
因果链｜……
后续史实｜……
历史影响｜……
记忆要点｜……
3. 必须用“当前文本｜”与“历史背景｜／后续史实｜”清楚区分书中实际内容与补充知识。
4. 中国古代人物要处理姓、氏、名、字、谥号、庙号、封号和官职，帮助辨认同一人不同称谓。
5. 不同史籍存在冲突或学界有争议时，写入 source_note，不得伪装成确定事实。]=]
  elseif mode_info.effective == "knowledge" then
    return common .. [=[

当前为“学术／知识模式”。
1. display 固定优先使用这些可读标签（无内容的标签可以省略）：
概要｜……
核心论点｜……
重要概念｜……
机制／原理｜……
概念联系｜……
应用｜……
限制｜……
常见误解｜……
记忆要点｜……
2. 可以补充完整通用背景，但必须区分“当前文本主张”和“补充知识”。
3. 对证据强度、因果关系和学术争议保持准确，不得把推测写成结论。]=]
  end

  return common .. [=[

当前为“小说／剧情模式”。
1. 只使用“用户已确认的已读范围”内有文本依据的内容：包括 KOAI 实时采集正文，以及用户选择“前文已读”后由插件从当前电子书回溯提取并建立的前序精读档案。若用户选择“前文未读”或前序补档尚未完成，则不得凭模型熟悉作品而补写那部分内容。任何情况下都不得补充当前阅读位置之后的剧情、隐藏身份、关系、结局或伏笔答案。
2. display 应像一份“有内容的文学阅读档案”，而不是只列事件。根据本批实际内容，从下列标签中选必要项并充分展开：
概要｜本轮读到哪里、核心推进是什么
关键事件｜重要事件及其直接意义，不要把十几个事件用竖线挤成一行
人物变化｜身份、处境、态度、心理、行动或认知发生的变化
关系变化｜亲缘、婚姻、主仆、朋友、利益、权力或情感关系的新增与变化
关键细节｜重要称谓、物件、诗词曲文、语言细节、礼法习俗、地点或动作及其阅读价值
典故／文化｜当前文字真正涉及、且有助理解的典故、制度、风俗、称谓或文化背景
叙事线索｜截至已读位置已经显露的照应、对比、悬念、异常细节或伏笔“现象”；只能指出现象和可能意义，不能揭晓后文答案
故事线｜各条正在推进的故事线及当前状态
时间线｜只有时间顺序容易混淆时才列
未解决问题｜当前确实悬而未决、后续阅读需要留意的问题
记忆要点｜下次打开书最值得先想起的信息锚点，数量由当前内容决定
继续阅读注意｜接下来应特别留意的人物、关系、事件或线索，不得剧透
3. 对《红楼梦》这类人物多、称谓多、亲缘复杂的古典小说，尤其要帮助辨认人物身份、亲缘／姻亲／主仆关系、称谓变化、礼法习俗和诗词曲文在当前情节中的作用；不能只做情节摘要。
4. 所有状态都必须明确是“截至当前已读位置”。]=]
end

local function ensureCurrentPageCaptured(ui, book)
  local position = Storage.getPosition(ui)
  local visible = Storage.readVisibleText(ui)
  if visible ~= "" then Storage.appendVisibleText(book, position, visible) end
  Storage.updateReadingPositions(book, position)
end

local function recapMessages(book, batch, mode_info)
  local previous = Storage.loadLatestRecap(book)
  local previous_text = previous and (previous.display or previous.resume or "") or "尚无上一版复盘，这是首次生成。"
  local world_text = Storage.formatWorld(book)
  local cards_text = Storage.formatRelevantCards(book, "", batch.text, 18)
  local coverage_text = Storage.formatCaptureCoverage(book)
  local prior = Storage.loadPriorRecap(book)
  local prior_text = prior and (prior.display or prior.resume or "") or ""
  local user_content = table.concat({
    "书名：" .. book.title,
    book.authors ~= "" and ("作者：" .. book.authors) or "",
    "本书阅读模式：" .. modeDisplay(mode_info),
    "模式判断说明：" .. tostring(mode_info.reason or ""),
    "本批新增内容范围：" .. Storage.formatPosition(batch.first) .. " → " .. Storage.formatPosition(batch.last),
    "\nKOAI 实时采集覆盖：\n" .. coverage_text,
    prior_text ~= "" and ("\n前序已读补建档案（仅来自当前电子书首次采集点之前的原文）：\n" .. prior_text) or "",
    "\n上一版累计复盘：\n" .. previous_text,
    "\n当前故事线、关系与背景：\n" .. world_text,
    "\n与本批文字最相关的人物／典故卡片：\n" .. cards_text,
    "\n本次新增已读文字：\n" .. batch.text,
  }, "\n")
  return {
    {role = "system", content = buildRecapSystemPrompt(mode_info)},
    {role = "user", content = user_content},
  }
end

local function processRecapBatches(ui, book, preview)
  local config = require("configuration")
  local batch_limit = tonumber(config.recap_batch_max_bytes) or 70000
  local after_id = tonumber(preview.after_id) or 0
  local batch_number, processed_count, processed_chars = 0, 0, 0
  local final_recap, final_position
  local mode_info = preview.mode_info or Storage.getReadingModeInfo(book, "")

  local function finish()
    Storage.applyStoragePolicy(book)
    local position_text = final_position and Storage.formatPosition(final_position) or "未知位置"
    local header = table.concat({
      "阅读模式｜" .. modeDisplay(mode_info),
      "本次处理｜" .. Utils.formatNumber(processed_count) .. " 个去重页面片段，约 " .. Utils.formatNumber(processed_chars) .. " 字",
      "复盘已处理到｜" .. position_text,
      "内容依据｜用户已确认的已读范围：实时采集正文 + 已完成的前序原文补档（如有）",
      "",
    }, "\n")
    showText("当前进度复盘｜已处理到 " .. position_text, header .. tostring(final_recap and final_recap.display or "复盘已更新。"))
  end

  local function fail(message)
    local processed_text = final_position and ("\n已成功处理到｜" .. Storage.formatPosition(final_position)) or ""
    UIManager:show(InfoMessage:new {
      text = "复盘生成中断：" .. tostring(message) .. processed_text
          .. "\n已成功完成的批次不会丢失，下次会从断点继续。",
      timeout = 15,
    })
  end

  local function nextBatch()
    local batch = Storage.readNextPendingBatch(book, after_id, batch_limit)
    if batch.count == 0 then finish(); return end
    batch_number = batch_number + 1
    runAI(
      "DeepSeek 正在生成复盘（第 " .. tostring(batch_number) .. "／约 " .. tostring(preview.estimated_batches) .. " 批）",
      recapMessages(book, batch, mode_info),
      function(raw)
        local data = extractJson(raw)
        if not data then
          -- v1.2.3：绝不再把坏 JSON 原样保存成复盘。
          -- 本批保持“未处理”，用户重试时会从同一断点继续，不会丢阅读原文。
          local partial_display = extractJsonStringField(raw, "display")
          local message = table.concat({
            "KOAI 返回的结构化复盘被截断或 JSON 格式不完整。",
            "本批没有写入阅读档案，也没有标记为已处理；可直接重新生成。",
            partial_display and partial_display ~= "" and ("\n已提取到的可读摘要：\n" .. partial_display) or "",
          }, "\n")
          showText("复盘未完整写入｜请重试", message)
          return
        end
        local recap = mergeRecapData(book, data, batch.last, raw, batch, mode_info)
        final_recap, final_position = recap, batch.last
        processed_count = processed_count + batch.count
        processed_chars = processed_chars + batch.chars
        after_id = batch.last_id
        if batch.has_more then UIManager:nextTick(nextBatch) else finish() end
      end,
      {max_tokens = tonumber(config.response_max_tokens) or 8192, temperature = 0.2},
      fail
    )
  end

  nextBatch()
end

function Logic.generateChapterRecap(ui)
  local book = Storage.getBookInfo(ui)
  ensureCurrentPageCaptured(ui, book)
  local preview = Storage.getPendingRecapInfo(book)
  local mode_info = Storage.getReadingModeInfo(book, "")
  preview.mode_info = mode_info
  if preview.count == 0 then
    local processed = preview.processed_position and Storage.formatPosition(preview.processed_position) or "尚未生成"
    local latest = Storage.loadLatestRecap(book)
    if latest and tostring(latest.display or "") ~= "" then
      -- v1.2.4：没有新增内容时也直接打开最新复盘。
      -- 这样升级显示修复后可以马上查看旧复盘的新排版，不需要再次调用 API。
      local header = table.concat({
        "阅读模式｜" .. modeDisplay(mode_info),
        "本次处理｜没有新增内容，不调用 API",
        "复盘已处理到｜" .. processed,
        "内容依据｜用户已确认的已读范围：实时采集正文 + 已完成的前序原文补档（如有）",
        "",
      }, "\n")
      showText("当前进度复盘｜已处理到 " .. processed, header .. tostring(latest.display or ""))
    else
      UIManager:show(InfoMessage:new {
        text = "目前没有尚未处理的新阅读内容。\n阅读模式｜" .. modeDisplay(mode_info) .. "\n复盘已处理到｜" .. processed,
        timeout = 8,
      })
    end
    return
  end

  local first_text = preview.first and Storage.formatPosition(preview.first) or "未知"
  local last_text = preview.last and Storage.formatPosition(preview.last) or "未知"
  local confirm_text = table.concat({
    "本次预计处理多少新内容",
    "",
    "阅读模式｜" .. modeDisplay(mode_info),
    "新增去重页面片段｜" .. Utils.formatNumber(preview.count) .. " 个",
    "新增文字｜约 " .. Utils.formatNumber(preview.chars) .. " 字",
    "范围｜" .. first_text .. " → " .. last_text,
    "预计 API 请求｜约 " .. tostring(preview.estimated_batches) .. " 次",
    "",
    "长内容会自动分批处理并逐批保存。中途失败时，下次会从已完成的位置继续，不会从头重复收费。是否开始？",
  }, "\n")
  UIManager:show(ConfirmBox:new {
    text = confirm_text,
    ok_text = "开始生成",
    cancel_text = "稍后再说",
    ok_callback = function() processRecapBatches(ui, book, preview) end,
  })
end

function Logic.createCard(ui, selected_text, context_text)
  selected_text = Utils.normalize_whitespace(selected_text or "")
  context_text = Utils.normalize_whitespace(context_text or "")
  if selected_text == "" then return end
  local book = Storage.getBookInfo(ui)
  local position = Storage.getPosition(ui)
  local mode_info = Storage.getReadingModeInfo(book, selected_text .. "\n" .. context_text)
  local existing = Storage.formatRelevantCards(book, selected_text, context_text, 14)
  local user_content = table.concat({
    "书名：" .. book.title,
    book.authors ~= "" and ("作者：" .. book.authors) or "",
    "本书阅读模式：" .. modeDisplay(mode_info),
    "模式判断说明：" .. tostring(mode_info.reason or ""),
    "当前章节：" .. position.chapter,
    "划选对象：" .. selected_text,
    context_text ~= "" and ("所在语境：" .. context_text) or "",
    "\n本地检索出的相关卡片：\n" .. existing,
  }, "\n")

  runAI(
    "DeepSeek 正在识别并建立人物／典故卡片",
    {
      {role = "system", content = buildCardSystemPrompt(mode_info)},
      {role = "user", content = user_content},
    },
    function(raw)
      local data = extractJson(raw) or {}
      local cards = normalizeResponseCards(data, selected_text, raw, position, mode_info)
      local displays, names = {}, {}
      local has_fallback = false
      for _, card in ipairs(cards) do
        card.display = buildCardDisplay(card, mode_info)
        local saved = Storage.mergeCard(book, card)
        if saved then
          displays[#displays + 1] = buildCardDisplay(saved, mode_info)
          names[#names + 1] = saved.name
          if saved.needs_enrichment == true then has_fallback = true end
        end
      end

      local shared = Utils.normalize_whitespace(data.shared_relationship or data.common_relationship or (#names > 1 and data.selection_summary) or "")
      if #names > 1 then
        Storage.markCardSuperseded(book, selected_text, names)
        if shared ~= "" then Storage.addSharedRelationship(book, names, shared, position.chapter) end
      end

      local output = {"阅读模式｜" .. modeDisplay(mode_info)}
      for _, display in ipairs(displays) do output[#output + 1] = "\n" .. display end
      if shared ~= "" then output[#output + 1] = "\n共同关系｜" .. shared end
      if has_fallback then
        output[#output + 1] = "\n提示｜模型本次没有完整返回所有独立对象，插件已避免合并人名并建立独立卡片；可单独划选相关对象继续补全。"
      end
      showText("人物／典故｜已生成 " .. tostring(#names) .. " 张卡片", table.concat(output, "\n"))
    end,
    {max_tokens = 6144, temperature = 0.15}
  )
end

function Logic.showReadingModeMenu(ui)
  local book = Storage.getBookInfo(ui)
  local current = Storage.getReadingModeInfo(book, "")
  local dialog
  local function choose(mode)
    return function()
      UIManager:close(dialog)
      Storage.setReadingMode(book, mode)
      local updated = Storage.getReadingModeInfo(book, "")
      UIManager:show(InfoMessage:new {
        text = "《" .. book.title .. "》\n阅读模式已设为：" .. modeDisplay(updated)
            .. "\n\n小说模式严格防剧透；历史模式补全史实；知识模式补全概念背景。",
        timeout = 9,
      })
    end
  end
  dialog = ButtonDialog:new {
    title = "本书阅读模式｜当前：" .. modeDisplay(current),
    title_align = "center",
    buttons = {
      {{text = "自动判断｜当前识别为 " .. current.effective_label, callback = choose("auto")}},
      {{text = "小说／剧情｜严格无剧透", callback = choose("novel")}},
      {{text = "历史／传记｜补全完整史实", callback = choose("history")}},
      {{text = "学术／知识｜补全知识背景", callback = choose("knowledge")}},
      {{text = "关闭", callback = function() UIManager:close(dialog) end}},
    },
  }
  UIManager:show(dialog)
end


local function priorBackfillMessages(book, batch, previous_text, mode_info)
  local system = [=[这是 KOAI 的“跨设备前序补档”阶段。用户已经明确确认：首次 KOAI 采集点之前的内容自己已经读过。

你收到的“本批前序原文”由插件直接从当前设备上的这一本电子书中，按从书籍开头到首次 KOAI 采集点之前的顺序回溯提取。它是有原文依据的已读内容，不是模型记忆。

任务：
1. 把“上一批前序累计精读档案”和“本批前序原文”按阅读顺序合并，建立越来越完整的前序精读档案。
2. 不设固定字数、不设人物数量、不设栏目数量。复杂内容充分展开；不得为了简短删掉重要人物、亲缘／姻亲／主仆关系、称谓、关键事件、关键细节、诗词曲文、典故文化、叙事线索和未解决问题。
3. 小说只能处理本批及更早已经提供的原文，绝对不能利用模型知道的后文补充情节、隐藏身份、结局或伏笔答案。
4. 这是“补建已读上下文”，不是给用户重新讲一遍全书。重点是建立后续精读所需的连续人物关系、事件因果、叙事线索和文化语境。
5. 返回格式沿用下面的 KOAI 累计复盘 JSON 规范。]=] .. "\n\n" .. buildRecapSystemPrompt(mode_info)

  local user_content = table.concat({
    "书名：" .. book.title,
    book.authors ~= "" and ("作者：" .. book.authors) or "",
    "阅读模式：" .. modeDisplay(mode_info),
    "本批回溯页范围｜第" .. tostring(batch.start_page) .. "页 → 第" .. tostring(batch.end_page) .. "页",
    "\n上一批前序累计精读档案：\n" .. (previous_text ~= "" and previous_text or "这是第一批，从书籍开头开始建立。"),
    "\n本批前序已读原文：\n" .. tostring(batch.text or ""),
  }, "\n")
  return {
    {role = "system", content = system},
    {role = "user", content = user_content},
  }
end

local function mergePriorWithCurrent(ui, book, prior_data, mode_info, done_callback)
  local current = Storage.loadLatestRecap(book)
  local prior_text = tostring(prior_data and (prior_data.display or prior_data.resume) or "")
  if prior_text == "" then
    if done_callback then done_callback(nil) end
    return
  end

  local state = Storage.loadState(book)
  local position = state.last_recap_position or (current and {
    chapter = current.chapter,
    chapter_key = current.chapter_key,
    page = current.page,
    percent = current.percent,
  }) or Storage.getPosition(ui)

  if not current or tostring(current.display or current.resume or "") == "" then
    local recap = mergeRecapData(book, prior_data, position, "", nil, mode_info)
    local merged_state = Storage.loadState(book)
    merged_state.prior_merged_into_latest_at = os.time()
    Storage.saveState(book, merged_state)
    if done_callback then done_callback(recap) end
    return
  end

  local system = buildRecapSystemPrompt(mode_info) .. [=[

现在执行一次“跨设备前序补档后的总档案整合”，不是新增剧情分析。
时间顺序必须是：
① 前序补建档案：书籍开头 → 首次 KOAI 采集点之前；
② 现有累计档案：首次 KOAI 采集点 → 当前已读位置。

请把两者整合成一份连续的累计精读档案。不能因为前序内容较多就把人物关系、关键事件、文化语境和叙事线索压没；也不能重复堆叠同一信息。不得加入当前已读位置之后的任何内容。返回同一套严格 JSON。]=]

  local user_content = table.concat({
    "书名：" .. book.title,
    "阅读模式：" .. modeDisplay(mode_info),
    "\n前序已读补建档案：\n" .. prior_text,
    "\n首次采集点之后的现有累计档案：\n" .. tostring(current.display or current.resume or ""),
    "\n当前故事线／关系／时间线：\n" .. Storage.formatWorld(book),
  }, "\n")

  runAI(
    "正在把前序补档与当前档案合并",
    {{role = "system", content = system}, {role = "user", content = user_content}},
    function(raw)
      local data = extractJson(raw)
      if not data then
        UIManager:show(InfoMessage:new {
          text = "前序精读档案已经补建成功，但最后一次总档案合并返回格式不完整。\n不会丢数据；后续精读仍会同时读取前序档案与现有累计档案。",
          timeout = 14,
        })
        if done_callback then done_callback(nil) end
        return
      end
      local recap = mergeRecapData(book, data, position, raw, nil, mode_info)
      local merged_state = Storage.loadState(book)
      merged_state.prior_merged_into_latest_at = os.time()
      Storage.saveState(book, merged_state)
      if done_callback then done_callback(recap) end
    end,
    {max_tokens = tonumber(require("configuration").response_max_tokens) or 8192, temperature = 0.18},
    function(message)
      UIManager:show(InfoMessage:new {
        text = "前序补档已经保存，但总档案合并暂时失败：" .. tostring(message)
            .. "\n之后可以重新生成当前进度复盘，前序档案不会丢失。",
        timeout = 14,
      })
      if done_callback then done_callback(nil) end
    end
  )
end

local function processPriorBackfill(ui, book)
  local config = require("configuration")
  local range = Storage.getPriorBackfillRange(ui, book)
  if range.end_page < 1 then
    Storage.setPriorReadingStatus(book, "from_start")
    UIManager:show(InfoMessage:new {text = "当前位置接近书籍开头，不需要补建前序档案。", timeout = 7})
    return
  end
  if not Storage.canBackfillPriorText(ui) then
    UIManager:show(InfoMessage:new {
      text = "当前书籍格式暂时不能在不改变阅读位置的情况下自动回溯正文。\n你的“前文已读”状态可以保留，但不会凭模型记忆补写。",
      timeout = 12,
    })
    Storage.setPriorReadingStatus(book, "read")
    return
  end

  Storage.createMaintenanceBackup(book, "before_prior_backfill")
  Storage.setPriorReadingStatus(book, "read")

  local prior = Storage.loadPriorRecap(book) or {}
  local start_page = tonumber(prior.next_page) or 1
  if tonumber(prior.end_page) ~= tonumber(range.end_page) or start_page < 1 or start_page > range.end_page + 1 then
    prior = {}
    start_page = 1
  end

  local state = Storage.loadState(book)
  state.prior_backfill_status = "in_progress"
  state.prior_backfill_start_page = 1
  state.prior_backfill_end_page = range.end_page
  Storage.saveState(book, state)

  local mode_info = Storage.getReadingModeInfo(book, "")
  local batch_limit = tonumber(config.recap_batch_max_bytes) or 70000
  local previous_text = tostring(prior.display or prior.resume or "")
  local batch_no = tonumber(prior.batch_no) or 0
  local final_data = prior

  local function finish()
    local finished = Storage.loadPriorRecap(book) or final_data or {}
    finished.status = "complete"
    finished.next_page = range.end_page + 1
    finished.end_page = range.end_page
    finished.completed_at = os.time()
    Storage.savePriorRecap(book, finished)

    local st = Storage.loadState(book)
    st.prior_reading_status = "read"
    st.prior_backfill_status = "complete"
    st.prior_backfill_completed_at = os.time()
    st.prior_backfill_start_page = 1
    st.prior_backfill_end_page = range.end_page
    Storage.saveState(book, st)

    mergePriorWithCurrent(ui, book, finished, mode_info, function()
      UIManager:show(InfoMessage:new {
        text = "前序精读档案已补建完成。\n"
            .. "范围｜书籍开头 → 首次 KOAI 采集点之前\n"
            .. "以后中文精读、当前进度复盘和全书档案都会把这部分作为已读上下文连续使用。",
        timeout = 15,
      })
    end)
  end

  local function nextBatch()
    if start_page > range.end_page then finish(); return end
    local batch, err = Storage.readPriorTextBatch(ui, start_page, range.end_page, batch_limit)
    if not batch then
      UIManager:show(InfoMessage:new {
        text = "前序补档读取失败：" .. tostring(err) .. "\n已经完成的批次不会丢失。",
        timeout = 12,
      })
      return
    end
    if batch.count == 0 then finish(); return end

    if tostring(batch.text or "") == "" then
      start_page = tonumber(batch.next_page) or (start_page + 1)
      UIManager:nextTick(nextBatch)
      return
    end

    batch_no = batch_no + 1
    runAI(
      "正在补建前序精读档案｜第 " .. tostring(batch_no) .. " 批",
      priorBackfillMessages(book, batch, previous_text, mode_info),
      function(raw)
        local data = extractJson(raw)
        if not data then
          local partial = extractJsonStringField(raw, "display")
          UIManager:show(InfoMessage:new {
            text = "本批前序补档返回格式不完整，未推进断点。"
                .. (partial and partial ~= "" and ("\n\n已生成内容预览：\n" .. partial) or "")
                .. "\n重新进入“前序阅读状态”即可从同一页继续。",
            timeout = 15,
          })
          return
        end

        previous_text = tostring(data.display or data.resume or previous_text)
        final_data = data
        final_data.status = "in_progress"
        final_data.start_page = 1
        final_data.end_page = range.end_page
        final_data.last_batch_start_page = batch.start_page
        final_data.last_batch_end_page = batch.end_page
        final_data.next_page = batch.next_page
        final_data.batch_no = batch_no
        Storage.savePriorRecap(book, final_data)

        start_page = tonumber(batch.next_page) or (batch.end_page + 1)
        if batch.has_more then UIManager:nextTick(nextBatch) else finish() end
      end,
      {max_tokens = tonumber(config.response_max_tokens) or 8192, temperature = 0.18},
      function(message)
        UIManager:show(InfoMessage:new {
          text = "前序补档在第 " .. tostring(batch_no) .. " 批中断：" .. tostring(message)
              .. "\n已完成部分已经保存，下次从断点继续。",
          timeout = 14,
        })
      end
    )
  end

  nextBatch()
end

function Logic.showPriorReadingMenu(ui, automatic)
  local book = Storage.getBookInfo(ui)
  local range = Storage.getPriorBackfillRange(ui, book)
  local info = Storage.getPriorReadingInfo(book)
  local dialog

  local function closeAnd(callback)
    return function()
      UIManager:close(dialog)
      UIManager:nextTick(callback)
    end
  end

  local title = automatic and "检测到从书籍中途开始建立 KOAI 档案" or ("前序阅读状态｜" .. Storage.formatPriorReadingStatus(book))
  local buttons = {
    {{text = "前文已读｜按本书原文补建精读档案", callback = closeAnd(function()
      local estimated = math.max(1, math.ceil(math.max(1, range.end_page) / 40))
      UIManager:show(ConfirmBox:new {
        text = table.concat({
          "你确认首次 KOAI 采集点之前的内容已经读过。",
          "",
          "KOAI 将直接从当前这一本电子书的开头回溯到首次采集点之前，按顺序读取原文并分批建立精读档案。",
          "不会翻动你的当前阅读位置，也不会使用模型记忆补剧情，更不会读取当前进度之后的正文。",
          "",
          "回溯范围｜第1页 → 第" .. tostring(range.end_page) .. "页附近",
          "预计 API 请求｜约 " .. tostring(estimated) .. " 次起（实际按文字量自动分批）",
          "",
          "分批是 API 上下文的技术处理，不代表删减内容；提示词不设置固定字数、人物数或栏目数。",
        }, "\n"),
        ok_text = "确认补建",
        cancel_text = "取消",
        ok_callback = function() processPriorBackfill(ui, book) end,
      })
    end)}},
    {{text = "前文未读｜从当前阅读起点开始", callback = closeAnd(function()
      Storage.setPriorReadingStatus(book, "unread")
      UIManager:show(InfoMessage:new {
        text = "已记录：首次 KOAI 采集点之前视为未读。\n以后不会把那部分作品知识当作你的已读上下文。",
        timeout = 9,
      })
    end)}},
  }

  if info.status == "read" and info.backfill_status == "complete" then
    buttons[#buttons + 1] = {{text = "重新补建前序档案", callback = closeAnd(function()
      Storage.clearPriorRecap(book)
      processPriorBackfill(ui, book)
    end)}}
  elseif info.status == "read" and info.backfill_status == "in_progress" then
    buttons[#buttons + 1] = {{text = "继续上次未完成的补档", callback = closeAnd(function()
      processPriorBackfill(ui, book)
    end)}}
  end

  buttons[#buttons + 1] = {{text = automatic and "稍后决定" or "关闭", callback = function()
    UIManager:close(dialog)
  end}}

  dialog = ButtonDialog:new {
    title = title,
    title_align = "center",
    buttons = buttons,
  }
  Storage.markPriorReadingPrompted(book)
  UIManager:show(dialog)
end

function Logic.maybePromptPriorReading(ui)
  local book = Storage.getBookInfo(ui)
  local should_prompt = Storage.shouldPromptPriorReading(ui, book)
  if should_prompt then
    Logic.showPriorReadingMenu(ui, true)
    return true
  end
  return false
end


function Logic.showResume(ui)
  local book = Storage.getBookInfo(ui)
  showText("继续阅读回顾", Storage.formatResume(book))
end

function Logic.showCards(ui)
  local book = Storage.getBookInfo(ui)
  showText("人物与典故", Storage.formatCards(book))
end

function Logic.showWorld(ui)
  local book = Storage.getBookInfo(ui)
  showText("故事线、关系与背景", Storage.formatWorld(book))
end

function Logic.showArchive(ui)
  local book = Storage.getBookInfo(ui)
  showText("全书阅读档案", Storage.formatArchive(book))
end

function Logic.exportArchive(ui)
  local book = Storage.getBookInfo(ui)
  local path = Storage.exportMarkdown(book)
  UIManager:show(InfoMessage:new {text = path and ("已导出到：\n" .. path) or "导出失败。", timeout = 8})
end

function Logic.showResumePrompt(ui)
  local book = Storage.getBookInfo(ui)
  local recap = Storage.loadLatestRecap(book)
  if recap then
    UIManager:show(ConfirmBox:new {
      text = "这本书已超过10小时未读。是否先查看前情回顾？",
      ok_text = "查看回顾",
      cancel_text = "直接阅读",
      ok_callback = function() Logic.showResume(ui) end,
    })
  else
    UIManager:show(ConfirmBox:new {
      text = "这本书已超过10小时未读，但还没有本地复盘。是否查看本次新增内容数量并生成回顾？",
      ok_text = "查看并生成",
      cancel_text = "直接阅读",
      ok_callback = function() Logic.generateChapterRecap(ui) end,
    })
  end
end

local function confirmCleanup(text, callback)
  UIManager:show(ConfirmBox:new {text = text, ok_text = "确认", cancel_text = "取消", ok_callback = callback})
end

function Logic.showDataManager(ui)
  local book = Storage.getBookInfo(ui)
  local dialog
  local function closeAnd(callback)
    return function() UIManager:close(dialog); UIManager:nextTick(callback) end
  end
  dialog = ButtonDialog:new {
    title = "KOAI 本地数据管理",
    title_align = "center",
    buttons = {
      {{text = "查看本书与全部占用", callback = closeAnd(function() showText("本地数据占用", Storage.getUsageReport(book)) end)}},
      {{text = "整理重复采集", callback = closeAnd(function()
        confirmCleanup("将重新整理本书的分块采集记录，移除完全重复页面。不会调用 AI，也不会删除人物卡和复盘。", function()
          Storage.createMaintenanceBackup(book, "before_dedup")
          local result = Storage.compactDuplicateCaptures(book)
          UIManager:show(InfoMessage:new {
            text = result and ("整理完成：保留 " .. tostring(result.kept) .. " 条，移除 " .. tostring(result.removed) .. " 条重复记录。")
                or "整理失败，请先备份后重试。",
            timeout = 10,
          })
        end)
      end)}},
      {{text = "按当前保存模式整理空间", callback = closeAnd(function()
        confirmCleanup("标准／完整档案模式不会删除已读原文；节省空间模式会在已有复盘后只保留最近一段原始文字。是否继续？", function()
          Storage.createMaintenanceBackup(book, "before_space_cleanup")
          local result = Storage.applyStoragePolicy(book)
          UIManager:show(InfoMessage:new {
            text = result and ("空间整理完成，移除 " .. tostring(result.removed) .. " 条已处理记录。")
                or "当前模式无需清理原始文字。",
            timeout = 10,
          })
        end)
      end)}},
      {{text = "清理过期备份", callback = closeAnd(function()
        Storage.cleanupBackups(book)
        UIManager:show(InfoMessage:new {text = "已按当前保存模式保留最近的必要备份。", timeout = 6})
      end)}},
      {{text = "清理已迁移的旧版采集文件", callback = closeAnd(function()
        confirmCleanup("旧版章节 TXT 已迁移到新版分块存储。清理后可节省空间，但旧版插件将不能再读取这些原始采集文件。人物卡、复盘与新版数据不受影响。", function()
          Storage.createMaintenanceBackup(book, "before_legacy_cleanup")
          local ok, count = Storage.cleanupLegacyCaptureFiles(book)
          UIManager:show(InfoMessage:new {
            text = ok and ("已清理 " .. tostring(count) .. " 个旧版采集文件。") or ("清理失败：" .. tostring(count)),
            timeout = 10,
          })
        end)
      end)}},
      {{text = "删除本书全部 KOAI 数据", callback = closeAnd(function()
        confirmCleanup("这会删除本书的已读采集、人物卡、复盘、故事线和时间线，且无法通过插件撤销。API Key和其他书籍不受影响。", function()
          confirmCleanup("最后确认：真的删除《" .. book.title .. "》的全部 KOAI 数据吗？", function()
            local ok = Storage.deleteBookData(book)
            UIManager:show(InfoMessage:new {text = ok and "本书 KOAI 数据已删除。" or "删除失败。", timeout = 8})
          end)
        end)
      end)}},
      {{text = "关闭", callback = function() UIManager:close(dialog) end}},
    },
  }
  UIManager:show(dialog)
end

function Logic.showHub(ui)
  local book = Storage.getBookInfo(ui)
  local mode_info = Storage.getReadingModeInfo(book, "")
  local dialog
  local function runAndClose(callback)
    return function() UIManager:close(dialog); UIManager:nextTick(callback) end
  end
  dialog = ButtonDialog:new {
    title = "KOAI 阅读助手",
    title_align = "center",
    buttons = {
      {{text = "本书阅读模式｜" .. modeDisplay(mode_info), callback = runAndClose(function() Logic.showReadingModeMenu(ui) end)}},
      {{text = "前序阅读状态｜" .. Storage.formatPriorReadingStatus(book), callback = runAndClose(function() Logic.showPriorReadingMenu(ui, false) end)}},
      {{text = "继续阅读回顾", callback = runAndClose(function() Logic.showResume(ui) end)}},
      {{text = "生成／更新当前进度复盘", callback = runAndClose(function() Logic.generateChapterRecap(ui) end)}},
      {{text = "人物与典故", callback = runAndClose(function() Logic.showCards(ui) end)}},
      {{text = "故事线、人物关系与时间线", callback = runAndClose(function() Logic.showWorld(ui) end)}},
      {{text = "全书阅读档案", callback = runAndClose(function() Logic.showArchive(ui) end)}},
      {{text = "导出 Markdown 阅读档案", callback = runAndClose(function() Logic.exportArchive(ui) end)}},
      {{text = "本地数据管理", callback = runAndClose(function() Logic.showDataManager(ui) end)}},
      {{text = "关闭", callback = function() UIManager:close(dialog) end}},
    },
  }
  UIManager:show(dialog)
end

return Logic
