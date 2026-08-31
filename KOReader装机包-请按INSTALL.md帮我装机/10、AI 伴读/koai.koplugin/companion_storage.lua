-- KOAI 阅读助手：分块存储、去重采集、增量复盘与旧版数据迁移。
-- 修改版，GPLv3；详见 NOTICE.md。
local DataStorage = require("datastorage")
local Device = require("device")
local json = require("json")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end
local util = require("util")
local Utils = require("utils")

local Storage = {}
local Screen = Device.screen

local DATA_ROOT = DataStorage:getDataDir() .. "/data"
local NEW_BASE_DIR = DATA_ROOT .. "/koaireader"
local LEGACY_BASE_DIR = DATA_ROOT .. "/aireadingassistant"
local CAPTURE_SCHEMA_VERSION = 2
local CARD_SCHEMA_VERSION = 3
local DEFAULT_CHUNK_BYTES = 98304

local capture_cache = {}
local card_index_cache = {}
local schema_ready = {}

local function ensureDir(path)
  if not path or path == "" then return false end
  if lfs.attributes(path, "mode") == "directory" then return true end
  local prefix = ""
  if path:sub(1, 1) == "/" then prefix = "/" end
  for part in path:gmatch("[^/]+") do
    if prefix == "" or prefix == "/" then prefix = prefix .. part else prefix = prefix .. "/" .. part end
    if lfs.attributes(prefix, "mode") ~= "directory" then lfs.mkdir(prefix) end
  end
  return lfs.attributes(path, "mode") == "directory"
end

local function readFile(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local content = file:read("*a")
  file:close()
  return content
end

local function writeFileAtomic(path, content)
  local tmp = path .. ".tmp"
  local file = io.open(tmp, "wb")
  if not file then return false end
  file:write(content or "")
  file:close()
  os.remove(path)
  local ok = os.rename(tmp, path)
  if not ok then os.remove(tmp) end
  return ok and true or false
end

local function readJson(path, default)
  local content = readFile(path)
  if not content or content == "" then return default end
  local ok, data = pcall(json.decode, Utils.sanitize_utf8(content))
  if ok and type(data) == "table" then return data end
  return default
end

local function writeJson(path, data)
  local ok, encoded = pcall(json.encode, data or {})
  if not ok then return false end
  return writeFileAtomic(path, encoded)
end

local function copyFile(source, target)
  local input = io.open(source, "rb")
  if not input then return false end
  local output = io.open(target, "wb")
  if not output then input:close(); return false end
  while true do
    local chunk = input:read(65536)
    if not chunk then break end
    output:write(chunk)
  end
  input:close()
  output:close()
  return true
end

local function copyTree(source, target)
  if lfs.attributes(source, "mode") ~= "directory" then return false end
  ensureDir(target)
  for name in lfs.dir(source) do
    if name ~= "." and name ~= ".." then
      local source_path = source .. "/" .. name
      local target_path = target .. "/" .. name
      local mode = lfs.attributes(source_path, "mode")
      if mode == "directory" then
        if not copyTree(source_path, target_path) then return false end
      elseif mode == "file" then
        if not copyFile(source_path, target_path) then return false end
      end
    end
  end
  return true
end

local function removeTree(path)
  local mode = lfs.attributes(path, "mode")
  if mode == "file" then return os.remove(path) end
  if mode ~= "directory" then return true end
  for name in lfs.dir(path) do
    if name ~= "." and name ~= ".." then removeTree(path .. "/" .. name) end
  end
  return lfs.rmdir(path)
end

local function resolveBaseDir()
  ensureDir(DATA_ROOT)
  if lfs.attributes(NEW_BASE_DIR, "mode") == "directory" then return NEW_BASE_DIR end
  if lfs.attributes(LEGACY_BASE_DIR, "mode") == "directory" then
    if os.rename(LEGACY_BASE_DIR, NEW_BASE_DIR) then return NEW_BASE_DIR end
    if copyTree(LEGACY_BASE_DIR, NEW_BASE_DIR) then return NEW_BASE_DIR end
    return LEGACY_BASE_DIR
  end
  ensureDir(NEW_BASE_DIR)
  return NEW_BASE_DIR
end

local BASE_DIR = resolveBaseDir()
local BOOKS_DIR = BASE_DIR .. "/books"
local EXPORTS_DIR = BASE_DIR .. "/exports"
local BACKUPS_DIR = BASE_DIR .. "/backups"

local function hashText(text)
  text = tostring(text or "")
  local hash = 5381
  for index = 1, #text do hash = (hash * 33 + text:byte(index)) % 2147483647 end
  return string.format("%08x", hash)
end

local function safeName(text)
  text = Utils.normalize_whitespace(text or "")
  text = text:gsub("[\\/:*?\"<>|]", "_"):gsub("%s+", "_"):gsub("_+", "_")
  if text == "" then text = "未命名" end
  return Utils.utf8Truncate(text, 48)
end

local function basename(path)
  if util and util.splitFilePathName then
    local ok, _, name = pcall(util.splitFilePathName, path or "")
    if ok and name and name ~= "" then return name end
  end
  return tostring(path or ""):match("([^/\\]+)$") or "未命名书籍"
end

local function getConfig()
  local ok, config = pcall(require, "configuration")
  return ok and config or {}
end


local READING_MODE_LABELS = {
  auto = "自动判断",
  novel = "小说／剧情",
  history = "历史／传记",
  knowledge = "学术／知识",
}

local HISTORY_HINTS = {
  "资治通鉴", "史记", "汉书", "后汉书", "三国志", "左传", "春秋", "战国策",
  "旧唐书", "新唐书", "宋史", "元史", "明史", "清史", "通史", "断代史",
  "历史", "史话", "史纲", "纪传", "编年", "国史", "实录", "年谱", "传记",
  "帝国", "王朝", "朝代", "战争史", "人物传", "列传", "本纪", "世家",
}

local KNOWLEDGE_HINTS = {
  "导论", "概论", "教程", "教材", "手册", "原理", "方法", "理论", "研究",
  "哲学", "经济学", "心理学", "社会学", "政治学", "法学", "管理学", "医学",
  "科学", "技术", "编程", "数学", "物理", "化学", "生物", "统计", "数据",
  "人工智能", "机器学习", "科普", "百科", "词典", "辞典",
}

local NOVEL_HINTS = {
  "小说", "红楼梦", "西游记", "水浒传", "三国演义", "聊斋", "儒林外史",
  "百年孤独", "战争与和平", "安娜·卡列尼娜", "追忆似水年华", "福尔摩斯",
}

local function containsAny(text, hints)
  text = tostring(text or ""):lower()
  for _, hint in ipairs(hints) do
    if text:find(tostring(hint):lower(), 1, true) then return true, hint end
  end
  return false, nil
end

local function detectReadingMode(book, sample_text)
  local title = tostring(book and book.title or "")
  local authors = tostring(book and book.authors or "")
  local metadata = table.concat({title, authors}, "\n")
  local sample = tostring(sample_text or "")

  -- v1.2.3：先看书名/作者元数据，再看正文样本。
  -- 旧版把“研究、理论”等泛化词放在经典小说名之前，
  -- 可能让《红楼梦》等小说因为前言/注释中出现“研究”而误判成学术模式。
  local novel_meta, novel_hint = containsAny(metadata, NOVEL_HINTS)
  local history_meta, history_hint = containsAny(metadata, HISTORY_HINTS)
  local knowledge_meta, knowledge_hint = containsAny(metadata, KNOWLEDGE_HINTS)

  -- 书名同时明确写着“某某研究/导论/教程”时，仍应尊重知识类标题。
  if knowledge_meta and (not novel_meta or title:find("研究", 1, true) or title:find("导论", 1, true)
      or title:find("教程", 1, true) or title:find("概论", 1, true)) then
    return "knowledge", "书名／元数据检测到学术／知识线索：" .. tostring(knowledge_hint)
  end
  if novel_meta then return "novel", "书名／元数据检测到小说／剧情线索：" .. tostring(novel_hint) end
  if history_meta then return "history", "书名／元数据检测到历史／传记线索：" .. tostring(history_hint) end
  if knowledge_meta then return "knowledge", "书名／元数据检测到学术／知识线索：" .. tostring(knowledge_hint) end

  -- 正文样本中，明确的经典小说线索优先于“研究/理论”等泛化知识词。
  local matched, hint = containsAny(sample, NOVEL_HINTS)
  if matched then return "novel", "正文检测到小说／剧情线索：" .. tostring(hint) end
  matched, hint = containsAny(sample, HISTORY_HINTS)
  if matched then return "history", "正文检测到历史／传记线索：" .. tostring(hint) end
  matched, hint = containsAny(sample, KNOWLEDGE_HINTS)
  if matched then return "knowledge", "正文检测到学术／知识线索：" .. tostring(hint) end
  return "novel", "未检测到明确历史或知识类线索，按小说／剧情模式处理"
end

function Storage.getReadingModeInfo(book, sample_text)
  local state = Storage.loadState(book)
  local selected = tostring(state.reading_mode or "auto")
  if not READING_MODE_LABELS[selected] then selected = "auto" end
  local effective, reason
  if selected == "auto" then
    effective, reason = detectReadingMode(book, sample_text)
  else
    effective, reason = selected, "用户为本书手动指定"
  end
  return {
    selected = selected,
    selected_label = READING_MODE_LABELS[selected],
    effective = effective,
    effective_label = READING_MODE_LABELS[effective] or effective,
    reason = reason,
    automatic = selected == "auto",
  }
end

function Storage.setReadingMode(book, mode)
  mode = tostring(mode or "auto")
  if not READING_MODE_LABELS[mode] then return false end
  local state = Storage.loadState(book)
  state.reading_mode = mode
  state.reading_mode_updated_at = os.time()
  Storage.saveState(book, state)
  return true
end

function Storage.formatReadingMode(book, sample_text)
  local info = Storage.getReadingModeInfo(book, sample_text)
  if info.automatic then
    return info.selected_label .. " → " .. info.effective_label
  end
  return info.effective_label
end

local function backupKeepCount()
  local mode = tostring(getConfig().storage_mode or "standard")
  if mode == "compact" then return 2 end
  if mode == "full" then return 5 end
  return 3
end

local function getDocumentProps(ui)
  local props = {}
  if ui and ui.document and ui.document.getProps then
    local ok, value = pcall(function() return ui.document:getProps() end)
    if ok and type(value) == "table" then props = value end
  end
  if ui and type(ui.doc_props) == "table" then
    for key, value in pairs(ui.doc_props) do if props[key] == nil then props[key] = value end end
  end
  return props
end

local function stringifyAuthors(value)
  if type(value) == "table" then
    local result = {}
    for _, item in ipairs(value) do result[#result + 1] = tostring(item) end
    return table.concat(result, "、")
  end
  return tostring(value or "")
end

function Storage.loadState(book)
  local state = readJson(book.state_path, {})
  if type(state) ~= "table" then state = {} end
  state.created_at = state.created_at or os.time()
  return state
end

function Storage.saveState(book, state)
  state = state or {}
  state.updated_at = os.time()
  return writeJson(book.state_path, state)
end

local function getCurrentPage(ui)
  local candidates = {
    function() return ui:getCurrentPage() end,
    function() return ui.paging.current_page end,
    function() return ui.rolling.current_page end,
    function() return ui.document:getCurrentPage() end,
  }
  for _, candidate in ipairs(candidates) do
    local ok, value = pcall(candidate)
    if ok and tonumber(value) then return tonumber(value) end
  end
  return 0
end

local function getCurrentPercent(ui)
  local candidates = {
    function() return ui.paging:getLastPercent() end,
    function() return ui.rolling:getLastPercent() end,
  }
  for _, candidate in ipairs(candidates) do
    local ok, value = pcall(candidate)
    if ok and tonumber(value) then
      local percent = tonumber(value)
      if percent <= 1 then percent = percent * 100 end
      return math.max(0, math.min(100, percent))
    end
  end
  return 0
end

local function getXPointer(ui)
  if ui and ui.document and ui.document.getXPointer then
    local ok, value = pcall(function() return ui.document:getXPointer() end)
    if ok and value and value ~= "" then return tostring(value) end
  end
  return ""
end

local function getChapterTitle(ui, page)
  local title
  if ui and ui.toc and ui.toc.getTocTitleByPage then
    local ok, value = pcall(function() return ui.toc:getTocTitleByPage(page) end)
    if ok and value and value ~= "" then title = value end
  end
  if not title and ui and ui.toc and ui.toc.getTocTitleByXPointer and ui.document and ui.document.getXPointer then
    local ok, value = pcall(function() return ui.toc:getTocTitleByXPointer(ui.document:getXPointer()) end)
    if ok and value and value ~= "" then title = value end
  end
  title = Utils.normalize_whitespace(tostring(title or ""))
  if title == "" then title = page and page > 0 and ("当前位置（第" .. tostring(page) .. "页）") or "当前位置" end
  return title
end

function Storage.getPosition(ui)
  local page = getCurrentPage(ui)
  local percent = getCurrentPercent(ui)
  local chapter = getChapterTitle(ui, page)
  local chapter_key = safeName(chapter) .. "_" .. hashText(chapter)
  local xpointer = getXPointer(ui)
  local position_key
  if xpointer ~= "" then
    position_key = chapter_key .. "|x:" .. hashText(xpointer)
  elseif page > 0 then
    position_key = chapter_key .. "|p:" .. tostring(page)
  else
    position_key = chapter_key .. "|pct:" .. string.format("%.3f", percent)
  end
  return {
    page = page,
    percent = percent,
    chapter = chapter,
    chapter_key = chapter_key,
    xpointer = xpointer,
    position_key = position_key,
    captured_at = os.time(),
  }
end

function Storage.formatPosition(position)
  position = position or {}
  local text = tostring(position.chapter or "当前位置")
  if tonumber(position.percent) and tonumber(position.percent) > 0 then
    text = text .. string.format("｜%.1f%%", tonumber(position.percent))
  elseif tonumber(position.page) and tonumber(position.page) > 0 then
    text = text .. "｜第" .. tostring(position.page) .. "页"
  end
  return text
end


local function getPageCount(ui)
  if not (ui and ui.document) then return 0 end
  local candidates = {
    function() return ui.document:getPageCount() end,
    function() return ui.document.info and ui.document.info.number_of_pages end,
  }
  for _, candidate in ipairs(candidates) do
    local ok, value = pcall(candidate)
    if ok and tonumber(value) and tonumber(value) > 0 then return tonumber(value) end
  end
  return 0
end

function Storage.getPriorReadingInfo(book)
  local state = Storage.loadState(book)
  local status = tostring(state.prior_reading_status or "unknown")
  if status ~= "read" and status ~= "unread" and status ~= "from_start" then status = "unknown" end
  return {
    status = status,
    backfill_status = tostring(state.prior_backfill_status or ""),
    backfill_completed_at = tonumber(state.prior_backfill_completed_at) or 0,
    backfill_start_page = tonumber(state.prior_backfill_start_page) or 0,
    backfill_end_page = tonumber(state.prior_backfill_end_page) or 0,
    prompted_at = tonumber(state.prior_reading_prompted_at) or 0,
  }
end

function Storage.setPriorReadingStatus(book, status)
  status = tostring(status or "unknown")
  if status ~= "read" and status ~= "unread" and status ~= "from_start" and status ~= "unknown" then return false end
  local state = Storage.loadState(book)
  state.prior_reading_status = status
  state.prior_reading_updated_at = os.time()
  if status == "unread" or status == "from_start" then
    state.prior_backfill_status = ""
  end
  Storage.saveState(book, state)
  return true
end

function Storage.markPriorReadingPrompted(book)
  local state = Storage.loadState(book)
  state.prior_reading_prompted_at = os.time()
  Storage.saveState(book, state)
end

function Storage.loadPriorRecap(book)
  return readJson(book.prior_recap_path, nil)
end

function Storage.savePriorRecap(book, data)
  data = type(data) == "table" and data or {}
  data.updated_at = os.time()
  return writeJson(book.prior_recap_path, data)
end

function Storage.clearPriorRecap(book)
  os.remove(book.prior_recap_path)
  local state = Storage.loadState(book)
  state.prior_backfill_status = ""
  state.prior_backfill_completed_at = nil
  state.prior_backfill_start_page = nil
  state.prior_backfill_end_page = nil
  Storage.saveState(book, state)
  return true
end

function Storage.getPriorBackfillRange(ui, book)
  local current = Storage.getPosition(ui)
  local coverage = Storage.getCaptureCoverage(book)
  local end_page = 0
  if coverage.first and tonumber(coverage.first.page) and tonumber(coverage.first.page) > 1 then
    end_page = tonumber(coverage.first.page) - 1
  elseif tonumber(current.page) and tonumber(current.page) > 1 then
    end_page = tonumber(current.page) - 1
  end
  local page_count = getPageCount(ui)
  if page_count > 0 and end_page >= page_count then end_page = page_count - 1 end
  if end_page < 1 then end_page = 0 end
  local percent = tonumber(current.percent) or 0
  return {
    start_page = 1,
    end_page = end_page,
    page_count = page_count,
    current = current,
    starts_mid_book = end_page > 0 and ((percent >= 1.0) or end_page >= 3),
  }
end

function Storage.shouldPromptPriorReading(ui, book)
  local info = Storage.getPriorReadingInfo(book)
  if info.status ~= "unknown" then return false, info end
  local range = Storage.getPriorBackfillRange(ui, book)
  if not range.starts_mid_book then
    Storage.setPriorReadingStatus(book, "from_start")
    return false, Storage.getPriorReadingInfo(book)
  end
  return true, range
end

local function pageTitle(ui, page)
  local title = ""
  if ui and ui.toc and ui.toc.getTocTitleByPage then
    local ok, value = pcall(function() return ui.toc:getTocTitleByPage(page) end)
    if ok and value then title = Utils.normalize_whitespace(tostring(value)) end
  end
  if title == "" then title = "第" .. tostring(page) .. "页附近" end
  return title
end

function Storage.canBackfillPriorText(ui)
  local doc = ui and ui.document
  return doc and type(doc.getPageXPointer) == "function" and type(doc.getTextFromXPointers) == "function"
end

function Storage.readPriorTextBatch(ui, from_page, end_page, max_bytes)
  from_page = math.max(1, tonumber(from_page) or 1)
  end_page = math.max(0, tonumber(end_page) or 0)
  max_bytes = math.max(12000, tonumber(max_bytes) or 70000)
  if from_page > end_page then return {count = 0, has_more = false} end
  if not Storage.canBackfillPriorText(ui) then return nil, "当前书籍格式无法在不翻页的情况下安全回溯正文" end

  local doc = ui.document
  local to_page = math.min(end_page, from_page + 39)
  local text = ""

  local function readRange(a, b)
    local ok, value = pcall(function()
      local xp0 = doc:getPageXPointer(a)
      local xp1 = doc:getPageXPointer(b + 1)
      if not xp0 or not xp1 then return "" end
      return doc:getTextFromXPointers(xp0, xp1, false)
    end)
    if not ok then return "" end
    if type(value) == "table" then value = value.text or "" end
    return Utils.normalize_whitespace(tostring(value or ""))
  end

  text = readRange(from_page, to_page)
  while #text > max_bytes and to_page > from_page do
    to_page = from_page + math.max(0, math.floor((to_page - from_page) / 2))
    text = readRange(from_page, to_page)
  end

  if text == "" then
    -- 某些电子书在个别排版页拿不到文字，逐页向后跳过，避免补档卡死。
    return {
      count = 1,
      text = "",
      start_page = from_page,
      end_page = from_page,
      first = {page = from_page, chapter = pageTitle(ui, from_page)},
      last = {page = from_page, chapter = pageTitle(ui, from_page)},
      has_more = from_page < end_page,
      next_page = from_page + 1,
    }
  end

  return {
    count = to_page - from_page + 1,
    text = text,
    chars = Utils.utf8Length(text),
    start_page = from_page,
    end_page = to_page,
    first = {page = from_page, chapter = pageTitle(ui, from_page)},
    last = {page = to_page, chapter = pageTitle(ui, to_page)},
    has_more = to_page < end_page,
    next_page = to_page + 1,
  }
end

function Storage.formatPriorReadingStatus(book)
  local info = Storage.getPriorReadingInfo(book)
  if info.status == "read" then
    if info.backfill_status == "complete" then return "前文已读｜已补建精读档案" end
    if info.backfill_status == "in_progress" then return "前文已读｜补档未完成，可继续" end
    return "前文已读｜尚未补建"
  elseif info.status == "unread" then
    return "前文未读｜从当前起点开始"
  elseif info.status == "from_start" then
    return "从本书开头开始记录"
  end
  return "尚未确认"
end

function Storage.getPrecisionContext(book)
  local parts = {}
  local prior = Storage.loadPriorRecap(book)
  local latest = Storage.loadLatestRecap(book)
  local state = Storage.loadState(book)
  local info = Storage.getPriorReadingInfo(book)

  parts[#parts + 1] = "前序阅读状态｜" .. Storage.formatPriorReadingStatus(book)
  local merged_at = tonumber(state.prior_merged_into_latest_at) or 0
  if info.status == "read" and prior and tostring(prior.display or prior.resume or "") ~= ""
      and (not latest or merged_at <= 0) then
    parts[#parts + 1] = "\n前序已读精读基线（由当前这本电子书的起点回溯到首次 KOAI 采集点生成，不含后文）：\n"
        .. tostring(prior.display or prior.resume or "")
  end
  if latest and tostring(latest.display or latest.resume or "") ~= "" then
    parts[#parts + 1] = "\n截至当前已读位置的累计复盘：\n" .. tostring(latest.display or latest.resume or "")
  end
  if state.last_recap_position then
    parts[#parts + 1] = "\n累计复盘位置｜" .. Storage.formatPosition(state.last_recap_position)
  end
  return table.concat(parts, "\n")
end

local function isFurther(candidate, previous)
  if type(previous) ~= "table" then return true end
  local cp, pp = tonumber(candidate.percent) or 0, tonumber(previous.percent) or 0
  if cp > 0 or pp > 0 then return cp > pp + 0.001 end
  return (tonumber(candidate.page) or 0) > (tonumber(previous.page) or 0)
end

function Storage.updateReadingPositions(book, current)
  local state = Storage.loadState(book)
  state.last_position = current
  if isFurther(current, state.furthest_position) then state.furthest_position = current end
  state.last_active_at = os.time()
  Storage.saveState(book, state)
  return state
end

function Storage.readVisibleText(ui)
  if not ui or not ui.document or not ui.document.getTextFromPositions then return "" end
  local result, old_text_wrap
  local ok = pcall(function()
    local x0, y0, x1, y1, page
    if ui.rolling then
      x0, y0 = 0, 0
      x1, y1 = Screen:getWidth(), Screen:getHeight()
    else
      if ui.getCurrentPage then page = ui:getCurrentPage()
      elseif ui.document.getCurrentPage then page = ui.document:getCurrentPage() end
      if ui.document.configurable then
        old_text_wrap = ui.document.configurable.text_wrap
        ui.document.configurable.text_wrap = 0
      end
      local page_boxes = page and ui.document.getTextBoxes and ui.document:getTextBoxes(page) or nil
      if page_boxes and page_boxes[1] and page_boxes[1][1]
          and page_boxes[#page_boxes] and page_boxes[#page_boxes][#page_boxes[#page_boxes]] then
        local first = page_boxes[1][1]
        local last = page_boxes[#page_boxes][#page_boxes[#page_boxes]]
        x0, y0, x1, y1 = first.x0, first.y0, last.x1, last.y1
      end
    end
    if x0 then
      result = ui.document:getTextFromPositions({x = x0, y = y0, page = page}, {x = x1, y = y1}, true)
    end
  end)
  if old_text_wrap ~= nil and ui.document.configurable then ui.document.configurable.text_wrap = old_text_wrap end
  if not ok or type(result) ~= "table" then return "" end
  return Utils.normalize_whitespace(result.text or "")
end

local function captureChunkPath(book, number)
  return book.captures_dir .. "/chunk_" .. string.format("%06d", number) .. ".jsonl"
end

local function defaultCaptureIndex()
  return {
    schema_version = CAPTURE_SCHEMA_VERSION,
    next_id = 1,
    current_chunk = 1,
    current_chunk_size = 0,
    total_records = 0,
    total_chars = 0,
    last_record = nil,
  }
end

local function loadCaptureCache(book)
  if capture_cache[book.id] then return capture_cache[book.id] end
  local index = readJson(book.capture_index_path, defaultCaptureIndex())
  if type(index) ~= "table" then index = defaultCaptureIndex() end
  index.next_id = tonumber(index.next_id) or 1
  index.current_chunk = tonumber(index.current_chunk) or 1
  index.current_chunk_size = tonumber(index.current_chunk_size) or 0
  local cache = {index = index, seen = {}, content_seen = {}}
  local file = io.open(book.capture_keys_path, "rb")
  if file then
    for line in file:lines() do
      local kind, key = line:match("^([PC])\t([^\t]+)")
      if kind == "P" then cache.seen[key] = true
      elseif kind == "C" then cache.content_seen[key] = true end
    end
    file:close()
  end
  capture_cache[book.id] = cache
  return cache
end

local function isForwardAdjacent(previous, current)
  if type(previous) ~= "table" or previous.chapter_key ~= current.chapter_key then return false end
  local pp, cp = tonumber(previous.percent) or 0, tonumber(current.percent) or 0
  if pp > 0 and cp > 0 then return cp >= pp end
  local ppage, cpage = tonumber(previous.page) or 0, tonumber(current.page) or 0
  return ppage > 0 and cpage >= ppage
end

local function appendKeyLog(book, position_hash, content_hash, id)
  local file = io.open(book.capture_keys_path, "ab")
  if not file then return false end
  file:write("P\t", position_hash, "\t", tostring(id), "\n")
  file:write("C\t", content_hash, "\t", tostring(id), "\n")
  file:close()
  return true
end

local function appendCaptureRecord(book, position, text, options)
  options = options or {}
  text = Utils.normalize_whitespace(text or "")
  if text == "" then return false, "empty" end
  local cache = loadCaptureCache(book)
  local index = cache.index
  local original_digest = hashText(text)
  local position_key = position.position_key or (position.chapter_key .. "|p:" .. tostring(position.page or 0))
  local position_hash = hashText(position_key .. "|" .. original_digest)
  local content_hash = hashText(position.chapter_key .. "|" .. original_digest)
  if cache.seen[position_hash] or cache.content_seen[content_hash] then return false, "duplicate" end

  if options.remove_overlap ~= false and index.last_record and isForwardAdjacent(index.last_record, position) then
    local overlap = Utils.longestAdjacentOverlap(index.last_record.text_tail or "", text, 260, 12)
    if overlap > 0 then text = Utils.normalize_whitespace(Utils.removePrefixChars(text, overlap)) end
    if Utils.utf8Length(text) < 2 then return false, "overlap" end
  end

  local id = tonumber(index.next_id) or 1
  local record = {
    id = id,
    chapter = position.chapter,
    chapter_key = position.chapter_key,
    page = position.page,
    percent = position.percent,
    xpointer = position.xpointer,
    position_key = position_key,
    captured_at = tonumber(options.captured_at or position.captured_at) or os.time(),
    text = text,
    chars = Utils.utf8Length(text),
    digest = hashText(text),
    original_digest = original_digest,
  }

  -- v1.2.6：永久记录这本书在“本机 KOAI”第一次真正采集到正文的位置。
  -- 后续即使整理空间或重建 captures，也不会把更晚的现存记录误认成最初采集点。
  local state = Storage.loadState(book)
  if type(state.capture_origin_position) ~= "table" then
    state.capture_origin_position = {
      chapter = record.chapter,
      chapter_key = record.chapter_key,
      page = record.page,
      percent = record.percent,
      xpointer = record.xpointer,
      position_key = record.position_key,
      captured_at = record.captured_at,
    }
    state.capture_origin_at = record.captured_at
    Storage.saveState(book, state)
  end

  local ok, encoded = pcall(json.encode, record)
  if not ok then return false, "encode" end
  encoded = encoded .. "\n"

  local chunk_bytes = tonumber(getConfig().capture_chunk_bytes) or DEFAULT_CHUNK_BYTES
  if index.current_chunk_size > 0 and index.current_chunk_size + #encoded > chunk_bytes then
    index.current_chunk = index.current_chunk + 1
    index.current_chunk_size = 0
  end
  local file = io.open(captureChunkPath(book, index.current_chunk), "ab")
  if not file then return false, "open" end
  file:write(encoded)
  file:close()
  appendKeyLog(book, position_hash, content_hash, id)

  cache.seen[position_hash] = true
  cache.content_seen[content_hash] = true
  index.next_id = id + 1
  index.current_chunk_size = index.current_chunk_size + #encoded
  index.total_records = (tonumber(index.total_records) or 0) + 1
  index.total_chars = (tonumber(index.total_chars) or 0) + record.chars
  if not index.first_record then
    index.first_record = {
      id = id,
      chapter = record.chapter,
      chapter_key = record.chapter_key,
      page = record.page,
      percent = record.percent,
      xpointer = record.xpointer,
      position_key = record.position_key,
      captured_at = record.captured_at,
    }
  end
  index.last_record = {
    id = id,
    chapter = record.chapter,
    chapter_key = record.chapter_key,
    page = record.page,
    percent = record.percent,
    xpointer = record.xpointer,
    position_key = record.position_key,
    captured_at = record.captured_at,
    text_tail = Utils.utf8Tail(text, 320),
  }
  writeJson(book.capture_index_path, index)
  return true, "saved", record
end

function Storage.appendVisibleText(book, position, text)
  return appendCaptureRecord(book, position, text, {remove_overlap = true})
end

local function listSortedFiles(path, pattern)
  local result = {}
  if lfs.attributes(path, "mode") ~= "directory" then return result end
  for name in lfs.dir(path) do
    if name ~= "." and name ~= ".." and (not pattern or name:match(pattern)) then result[#result + 1] = name end
  end
  table.sort(result)
  return result
end

local function eachCaptureRecord(book, callback)
  for _, name in ipairs(listSortedFiles(book.captures_dir, "^chunk_%d+%.jsonl$")) do
    local file = io.open(book.captures_dir .. "/" .. name, "rb")
    if file then
      for line in file:lines() do
        local ok, record = pcall(json.decode, Utils.sanitize_utf8(line))
        if ok and type(record) == "table" and tonumber(record.id) then
          if callback(record) == false then file:close(); return false end
        end
      end
      file:close()
    end
  end
  return true
end

local function captureRecordPosition(record)
  if type(record) ~= "table" then return nil end
  return {
    chapter = record.chapter,
    chapter_key = record.chapter_key,
    page = record.page,
    percent = record.percent,
    xpointer = record.xpointer,
    position_key = record.position_key,
    captured_at = record.captured_at,
  }
end

function Storage.getCaptureCoverage(book)
  local index = readJson(book.capture_index_path, defaultCaptureIndex())
  if type(index) ~= "table" then index = defaultCaptureIndex() end
  local state = Storage.loadState(book)
  local first = captureRecordPosition(state.capture_origin_position) or captureRecordPosition(index.first_record)
  local last = captureRecordPosition(index.last_record)
  local count = tonumber(index.total_records) or 0
  local chars = tonumber(index.total_chars) or 0

  -- v1.2.6：旧版索引没有 first_record / capture_origin_position。仅在需要时扫描一次旧分块，
  -- 不改动原始记录；找到后同时回填不可变的“本机首次采集位置”，保证无痕升级。
  if count > 0 and not first then
    eachCaptureRecord(book, function(record)
      if not first then first = captureRecordPosition(record) end
      last = captureRecordPosition(record) or last
    end)
    if first then
      index.first_record = index.first_record or first
      if last and not index.last_record then index.last_record = last end
      writeJson(book.capture_index_path, index)
      state.capture_origin_position = first
      state.capture_origin_at = first.captured_at or os.time()
      Storage.saveState(book, state)
    end
  elseif first and type(state.capture_origin_position) ~= "table" then
    state.capture_origin_position = first
    state.capture_origin_at = first.captured_at or os.time()
    Storage.saveState(book, state)
  end

  local starts_mid_book = false
  if first then
    local pct = tonumber(first.percent) or 0
    local page = tonumber(first.page) or 0
    starts_mid_book = pct >= 1.0 or (pct <= 0 and page > 3)
  end
  return {
    first = first,
    last = last,
    count = count,
    chars = chars,
    starts_mid_book = starts_mid_book,
  }
end

function Storage.formatCaptureCoverage(book)
  local coverage = Storage.getCaptureCoverage(book)
  local state = Storage.loadState(book)
  local prior_info = Storage.getPriorReadingInfo(book)
  local lines = {}
  if state.furthest_position then
    lines[#lines + 1] = "阅读进度记录到｜" .. Storage.formatPosition(state.furthest_position)
  end
  if coverage.first then
    lines[#lines + 1] = "KOAI实时采集起点｜" .. Storage.formatPosition(coverage.first)
  else
    lines[#lines + 1] = "KOAI实时采集起点｜尚无采集正文"
  end
  if coverage.last then
    lines[#lines + 1] = "KOAI实时采集到｜" .. Storage.formatPosition(coverage.last)
  end
  lines[#lines + 1] = "前序阅读状态｜" .. Storage.formatPriorReadingStatus(book)
  if prior_info.status == "read" and prior_info.backfill_status == "complete" then
    lines[#lines + 1] = "前序内容依据｜已从当前电子书开头回溯至首次实时采集点之前，并建立精读档案"
  elseif prior_info.status == "unread" then
    lines[#lines + 1] = "前序内容依据｜用户确认未读，不纳入当前精读上下文"
  elseif coverage.starts_mid_book then
    lines[#lines + 1] = "前序内容依据｜尚未确认；不会凭模型记忆自动补写"
  else
    lines[#lines + 1] = "内容依据｜从书籍开头连续建立 KOAI 阅读档案"
  end
  return table.concat(lines, "\n")
end

function Storage.getPendingRecapInfo(book)
  local state = Storage.loadState(book)
  local after_id = tonumber(state.last_recap_capture_id) or 0
  local info = {after_id = after_id, count = 0, chars = 0, bytes = 0, first = nil, last = nil}
  eachCaptureRecord(book, function(record)
    if tonumber(record.id) > after_id then
      info.count = info.count + 1
      info.chars = info.chars + (tonumber(record.chars) or Utils.utf8Length(record.text or ""))
      info.bytes = info.bytes + #(record.text or "")
      info.first = info.first or record
      info.last = record
    end
  end)
  local batch_bytes = tonumber(getConfig().recap_batch_max_bytes) or 70000
  info.estimated_batches = info.bytes > 0 and math.max(1, math.ceil(info.bytes / batch_bytes)) or 0
  info.processed_position = state.last_recap_position
  return info
end

function Storage.readNextPendingBatch(book, after_id, max_bytes)
  after_id = tonumber(after_id) or 0
  max_bytes = tonumber(max_bytes) or 70000
  local batch = {text_parts = {}, count = 0, chars = 0, bytes = 0, first = nil, last = nil, last_id = after_id}
  local stopped = false
  eachCaptureRecord(book, function(record)
    local id = tonumber(record.id) or 0
    if id > after_id then
      local marker = "\n\n【" .. Storage.formatPosition(record) .. "】\n"
      local addition = marker .. tostring(record.text or "")
      if batch.count > 0 and batch.bytes + #addition > max_bytes then
        stopped = true
        return false
      end
      batch.text_parts[#batch.text_parts + 1] = addition
      batch.count = batch.count + 1
      batch.bytes = batch.bytes + #addition
      batch.chars = batch.chars + (tonumber(record.chars) or Utils.utf8Length(record.text or ""))
      batch.first = batch.first or record
      batch.last = record
      batch.last_id = id
    end
  end)
  batch.text = table.concat(batch.text_parts)
  batch.text_parts = nil
  batch.has_more = stopped
  return batch
end

function Storage.markRecapProcessed(book, capture_id, position, chars)
  local state = Storage.loadState(book)
  state.last_recap_capture_id = tonumber(capture_id) or state.last_recap_capture_id
  state.last_recap_position = position or state.last_recap_position
  state.last_recap_processed_at = os.time()
  state.total_recap_chars = (tonumber(state.total_recap_chars) or 0) + (tonumber(chars) or 0)
  Storage.saveState(book, state)
end

local function parseTimestamp(text)
  local year, month, day, hour, minute = tostring(text or ""):match("(%d%d%d%d)%-(%d%d)%-(%d%d)%s+(%d%d):(%d%d)")
  if year then
    return os.time({year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = tonumber(hour), min = tonumber(minute), sec = 0})
  end
  return os.time()
end

local function splitLargeLegacyText(text, max_chars)
  local chars = Utils.utf8Chars(text)
  local result = {}
  local current = {}
  for _, char in ipairs(chars) do
    current[#current + 1] = char
    if #current >= max_chars then result[#result + 1] = table.concat(current); current = {} end
  end
  if #current > 0 then result[#result + 1] = table.concat(current) end
  return result
end

local function migrateLegacyCaptureFile(book, file_name, state)
  local path = book.legacy_chapters_dir .. "/" .. file_name
  local content = Utils.sanitize_utf8(readFile(path) or "")
  if content == "" then return 0, 0 end
  local chapter_key = file_name:gsub("%.txt$", "")
  local markers = {}
  local search = 1
  while true do
    local start_pos, end_pos, page, stamp = content:find("【页面%s*(.-)｜(.-)】\n", search)
    if not start_pos then break end
    markers[#markers + 1] = {start_pos = start_pos, end_pos = end_pos, page = tonumber(page) or 0, stamp = stamp}
    search = end_pos + 1
  end
  local migrated, processed_id = 0, 0
  local latest_recap_at = tonumber(state.latest_recap_at) or 0
  local function saveBlock(text, page, captured_at, sequence)
    text = Utils.normalize_whitespace(text)
    if text == "" then return end
    local position = {
      page = page or 0,
      percent = 0,
      chapter = chapter_key,
      chapter_key = chapter_key,
      xpointer = "",
      position_key = chapter_key .. "|legacy:" .. tostring(page or 0) .. ":" .. tostring(sequence or 0),
      captured_at = captured_at,
    }
    local ok, _, record = appendCaptureRecord(book, position, text, {captured_at = captured_at, remove_overlap = true})
    if ok and record then
      migrated = migrated + 1
      if latest_recap_at > 0 and captured_at <= latest_recap_at then processed_id = math.max(processed_id, record.id) end
    end
  end
  if #markers == 0 then
    local sequence = 0
    for _, block in ipairs(splitLargeLegacyText(content, 5000)) do
      sequence = sequence + 1
      saveBlock(block, sequence, lfs.attributes(path, "modification") or os.time(), sequence)
    end
  else
    for index, marker in ipairs(markers) do
      local next_start = markers[index + 1] and markers[index + 1].start_pos or (#content + 1)
      local block = content:sub(marker.end_pos + 1, next_start - 1)
      saveBlock(block, marker.page, parseTimestamp(marker.stamp), index)
    end
  end
  return migrated, processed_id
end

local function normalizeKey(text)
  text = Utils.normalize_whitespace(tostring(text or "")):lower()
  return text:gsub("[%s%p]", "")
end

local function asArray(value)
  if type(value) == "table" then return value end
  if value == nil or value == "" then return {} end
  return {tostring(value)}
end

local function mergeList(target, source)
  target = asArray(target)
  local seen = {}
  for _, item in ipairs(target) do seen[normalizeKey(item)] = true end
  for _, item in ipairs(asArray(source)) do
    local key = normalizeKey(item)
    if key ~= "" and not seen[key] then target[#target + 1] = tostring(item); seen[key] = true end
  end
  return target
end

local function loadCardIndex(book)
  if card_index_cache[book.id] then return card_index_cache[book.id] end
  local index = readJson(book.card_index_path, {schema_version = CARD_SCHEMA_VERSION, items = {}})
  if type(index.items) ~= "table" then index.items = {} end
  card_index_cache[book.id] = index
  return index
end

local function saveCardIndex(book, index)
  card_index_cache[book.id] = index
  return writeJson(book.card_index_path, index)
end

local function cardPath(book, id)
  return book.cards_dir .. "/card_" .. tostring(id) .. ".json"
end

local function findCardEntry(index, name, aliases)
  local lookup = {[normalizeKey(name)] = true}
  for _, alias in ipairs(asArray(aliases)) do lookup[normalizeKey(alias)] = true end
  for _, entry in ipairs(index.items) do
    local keys = {[normalizeKey(entry.name)] = true}
    for _, alias in ipairs(asArray(entry.aliases)) do keys[normalizeKey(alias)] = true end
    for key in pairs(lookup) do if key ~= "" and keys[key] then return entry end end
  end
  return nil
end

local function migrateLegacyCards(book)
  local state = Storage.loadState(book)
  local current_version = tonumber(state.card_schema_version) or 0
  if current_version == CARD_SCHEMA_VERSION then return end

  -- v1.2.x 已经使用独立卡片文件，只需提升结构版本，避免重复导入旧 cards.json。
  if current_version >= 2 then
    state.card_schema_version = CARD_SCHEMA_VERSION
    Storage.saveState(book, state)
    return
  end

  local legacy = readJson(book.legacy_cards_path, {items = {}})
  if type(legacy.items) == "table" then
    for _, card in ipairs(legacy.items) do Storage.mergeCard(book, card) end
  end
  state.card_schema_version = CARD_SCHEMA_VERSION
  Storage.saveState(book, state)
end

function Storage.loadCards(book)
  local index = loadCardIndex(book)
  local result = {items = {}}
  for _, entry in ipairs(index.items) do
    if entry.hidden ~= true then
      local card = readJson(cardPath(book, entry.id), nil)
      if type(card) == "table" and card.hidden ~= true then result.items[#result.items + 1] = card end
    end
  end
  return result
end

function Storage.mergeCard(book, incoming)
  if type(incoming) ~= "table" then return nil end
  local name = Utils.normalize_whitespace(incoming.name or incoming.title or "")
  if name == "" then return nil end
  local aliases = mergeList(incoming.aliases, incoming.original_name or incoming.english_name)
  local index = loadCardIndex(book)
  local entry = findCardEntry(index, name, aliases)
  local card
  if entry then
    card = readJson(cardPath(book, entry.id), {})
  else
    local id = hashText(normalizeKey(name) .. "|" .. tostring(os.time()) .. "|" .. tostring(#index.items + 1))
    entry = {id = id, name = name, aliases = {}, created_at = os.time()}
    index.items[#index.items + 1] = entry
    card = {name = name, aliases = {}, created_at = entry.created_at}
  end

  card.name = name
  card.aliases = mergeList(card.aliases, aliases)
  card.type = incoming.type or incoming.category or card.type or "人物／典故"

  local fields = {
    "original_name", "english_name", "name_system", "era", "dates", "identity",
    "description", "family_relations", "political_relations", "relationships",
    "current_status", "status", "current_text", "text_role", "current_storyline",
    "storyline", "significance", "background", "historical_background", "key_events",
    "later_history", "historical_significance", "identification_tip", "tip",
    "source_note", "controversies", "definition", "category_detail", "mechanism",
    "applications", "misconceptions", "knowledge_background", "reading_mode",
    "mode_label", "shared_context", "needs_enrichment", "display",
  }
  for _, key in ipairs(fields) do
    local value = incoming[key]
    if value ~= nil and value ~= "" then card[key] = value end
  end

  card.first_seen = card.first_seen or incoming.first_seen
  card.last_seen = incoming.last_seen or card.last_seen
  card.hidden = incoming.hidden == true or card.hidden == true
  card.superseded_by = incoming.superseded_by or card.superseded_by
  card.updated_at = os.time()
  writeJson(cardPath(book, entry.id), card)

  entry.name = card.name
  entry.aliases = card.aliases
  entry.type = card.type
  entry.hidden = card.hidden == true
  entry.superseded_by = card.superseded_by
  entry.updated_at = card.updated_at
  saveCardIndex(book, index)
  return card
end

function Storage.mergeCards(book, items)
  if type(items) ~= "table" then return end
  for _, item in ipairs(items) do Storage.mergeCard(book, item) end
end


function Storage.markCardSuperseded(book, combined_name, replacement_names)
  combined_name = Utils.normalize_whitespace(combined_name or "")
  if combined_name == "" or type(replacement_names) ~= "table" or #replacement_names < 2 then return false end
  local index = loadCardIndex(book)
  local target_key = normalizeKey(combined_name)
  for _, entry in ipairs(index.items) do
    if normalizeKey(entry.name) == target_key then
      local card = readJson(cardPath(book, entry.id), {})
      card.hidden = true
      card.superseded_by = replacement_names
      card.updated_at = os.time()
      writeJson(cardPath(book, entry.id), card)
      entry.hidden = true
      entry.superseded_by = replacement_names
      entry.updated_at = card.updated_at
      saveCardIndex(book, index)
      return true
    end
  end
  return false
end

function Storage.addSharedRelationship(book, names, summary, chapter)
  summary = Utils.normalize_whitespace(summary or "")
  if summary == "" or type(names) ~= "table" or #names < 2 then return false end
  local normalized_names = {}
  for _, name in ipairs(names) do
    name = Utils.normalize_whitespace(name or "")
    if name ~= "" then normalized_names[#normalized_names + 1] = name end
  end
  if #normalized_names < 2 then return false end
  table.sort(normalized_names)
  local key = hashText(table.concat(normalized_names, "|"))
  local world = Storage.loadWorld(book)
  world.shared_relationships = type(world.shared_relationships) == "table" and world.shared_relationships or {}
  local found
  for _, item in ipairs(world.shared_relationships) do
    if type(item) == "table" and item.key == key then found = item; break end
  end
  if not found then
    found = {key = key, people = normalized_names, created_at = os.time()}
    world.shared_relationships[#world.shared_relationships + 1] = found
  end
  found.summary = summary
  found.chapter = chapter or found.chapter
  found.updated_at = os.time()
  Storage.saveWorld(book, world)
  return true
end

local function cardValue(value)
  if type(value) == "table" then
    local result = {}
    for _, item in ipairs(value) do
      if type(item) == "table" then
        result[#result + 1] = tostring(item.name or item.title or item.summary or item.event or "")
      else
        result[#result + 1] = tostring(item)
      end
    end
    return table.concat(result, "、")
  end
  return tostring(value or "")
end

local function cardToText(card)
  local lines = {tostring(card.type or "卡片") .. "｜" .. tostring(card.name or "未命名")}
  local function add(label, value)
    value = Utils.normalize_whitespace(cardValue(value))
    if value ~= "" and value ~= "无" then lines[#lines + 1] = label .. "｜" .. value end
  end

  add("名称体系", card.name_system)
  add("英文原名", card.original_name or card.english_name)
  add("别名", card.aliases)
  add("时代", card.era)
  add("生卒／在位", card.dates)
  add("身份／含义", card.identity or card.description or card.definition)
  add("家族关系", card.family_relations)
  add("政治关系", card.political_relations)
  add("关系", card.relationships)
  add("当前文本", card.current_text or card.text_role)
  add("当前状态", card.current_status or card.status)
  add("当前故事线", card.current_storyline or card.storyline)
  add("历史背景", card.historical_background or card.background)
  add("关键事件", card.key_events)
  add("后续史实", card.later_history)
  add("历史意义", card.historical_significance)
  add("知识背景", card.knowledge_background)
  add("机制／原理", card.mechanism)
  add("应用", card.applications)
  add("常见误解", card.misconceptions)
  add("作用", card.significance)
  add("史实／来源说明", card.source_note)
  add("争议／不确定", card.controversies)
  add("辨认提示", card.identification_tip or card.tip)
  add("首次记录", card.first_seen)
  add("最近记录", card.last_seen)
  if #lines == 1 and card.display and card.display ~= "" then lines[#lines + 1] = "说明｜" .. tostring(card.display) end
  return table.concat(lines, "\n")
end

function Storage.formatRelevantCards(book, query, context, max_items)
  local index = loadCardIndex(book)
  local haystack = (tostring(query or "") .. "\n" .. tostring(context or "")):lower()
  local scored = {}
  for _, entry in ipairs(index.items) do
    if entry.hidden ~= true then
    local score = 0
    local terms = {entry.name}
    for _, alias in ipairs(asArray(entry.aliases)) do terms[#terms + 1] = alias end
    for _, term in ipairs(terms) do
      term = Utils.normalize_whitespace(term or ""):lower()
      if term ~= "" then
        if tostring(query or ""):lower() == term then score = score + 100
        elseif haystack:find(term, 1, true) then score = score + 20 end
      end
    end
    if score > 0 then scored[#scored + 1] = {entry = entry, score = score}
    else scored[#scored + 1] = {entry = entry, score = 0} end
    end
  end
  table.sort(scored, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return (tonumber(a.entry.updated_at) or 0) > (tonumber(b.entry.updated_at) or 0)
  end)
  max_items = tonumber(max_items) or 16
  local positive_count = 0
  for _, item in ipairs(scored) do if item.score > 0 then positive_count = positive_count + 1 end end
  local take = positive_count > 0 and math.min(max_items, positive_count) or math.min(3, max_items, #scored)
  local lines = {}
  for index_number = 1, take do
    local card = readJson(cardPath(book, scored[index_number].entry.id), nil)
    if card then lines[#lines + 1] = cardToText(card) end
  end
  return #lines > 0 and table.concat(lines, "\n\n") or "尚无相关人物或典故卡片。"
end

function Storage.formatCards(book)
  local index = loadCardIndex(book)
  if #index.items == 0 then return "尚未建立人物或典故卡片。" end
  local entries = {}
  for _, entry in ipairs(index.items) do if entry.hidden ~= true then entries[#entries + 1] = entry end end
  table.sort(entries, function(a, b)
    local ta, tb = tonumber(a.updated_at or a.created_at) or 0, tonumber(b.updated_at or b.created_at) or 0
    if ta ~= tb then return ta > tb end
    return tostring(a.name or "") < tostring(b.name or "")
  end)
  local mode_info = Storage.getReadingModeInfo(book, "")
  local mode_text = mode_info.automatic and (mode_info.effective_label .. "（自动判断）") or mode_info.effective_label
  local lines = {
    "《" .. book.title .. "》人物与典故",
    "阅读模式｜" .. mode_text,
    "总览｜共 " .. tostring(#entries) .. " 张卡片，按最近更新排列",
  }
  for _, entry in ipairs(entries) do
    local card = readJson(cardPath(book, entry.id), nil)
    if card and card.hidden ~= true then lines[#lines + 1] = "\n" .. cardToText(card) end
  end
  return table.concat(lines, "\n")
end

function Storage.saveWorld(book, world)
  world = world or {}
  world.updated_at = os.time()
  return writeJson(book.world_path, world)
end

function Storage.loadWorld(book)
  return readJson(book.world_path, {})
end

local function joinList(value)
  if type(value) == "table" then
    local result = {}
    for _, item in ipairs(value) do
      if type(item) == "table" then result[#result + 1] = item.name or item.title or item.summary or ""
      else result[#result + 1] = tostring(item) end
    end
    return table.concat(result, "、")
  end
  return tostring(value or "")
end

function Storage.formatWorld(book)
  local world = Storage.loadWorld(book)
  if not next(world) then return "尚未生成故事线、关系与背景。请先生成当前进度复盘。" end
  local mode_info = Storage.getReadingModeInfo(book, "")
  local lines = {
    "《" .. book.title .. "》故事线、关系与背景",
    "阅读模式｜" .. (mode_info.automatic and (mode_info.effective_label .. "（自动判断）") or mode_info.effective_label),
  }
  if world.current_state and world.current_state ~= "" then lines[#lines + 1] = "\n当前局势｜" .. tostring(world.current_state) end
  if world.era_context and world.era_context ~= "" then lines[#lines + 1] = "时代背景｜" .. tostring(world.era_context) end
  if type(world.factions) == "table" and #world.factions > 0 then
    lines[#lines + 1] = "\n政权／家族／阵营"
    for _, item in ipairs(world.factions) do
      if type(item) == "table" then
        lines[#lines + 1] = "• " .. tostring(item.name or item.title or "") .. "｜" .. tostring(item.position or item.summary or item.status or "")
      else
        lines[#lines + 1] = "• " .. tostring(item)
      end
    end
  end
  if type(world.causal_chain) == "table" and #world.causal_chain > 0 then
    lines[#lines + 1] = "\n因果链"
    for _, item in ipairs(world.causal_chain) do lines[#lines + 1] = "• " .. tostring(item) end
  elseif world.causal_chain and world.causal_chain ~= "" then
    lines[#lines + 1] = "因果链｜" .. tostring(world.causal_chain)
  end
  if type(world.storylines) == "table" and #world.storylines > 0 then
    lines[#lines + 1] = "\n故事线／议题"
    for _, item in ipairs(world.storylines) do
      if type(item) == "table" then
        lines[#lines + 1] = "\n" .. tostring(item.name or item.title or "未命名故事线")
        if item.summary then lines[#lines + 1] = "进展｜" .. tostring(item.summary) end
        if item.status then lines[#lines + 1] = "状态｜" .. tostring(item.status) end
        if item.people then lines[#lines + 1] = "涉及｜" .. joinList(item.people) end
        if item.unresolved then lines[#lines + 1] = "未解决｜" .. joinList(item.unresolved) end
      else
        lines[#lines + 1] = "• " .. tostring(item)
      end
    end
  end
  if type(world.timeline) == "table" and #world.timeline > 0 then
    lines[#lines + 1] = "\n时间线"
    for _, item in ipairs(world.timeline) do
      if type(item) == "table" then
        lines[#lines + 1] = "• " .. tostring(item.time or item.order or "") .. " " .. tostring(item.event or item.summary or "")
      else
        lines[#lines + 1] = "• " .. tostring(item)
      end
    end
  end
  if type(world.relationships) == "table" and #world.relationships > 0 then
    lines[#lines + 1] = "\n人物关系"
    for _, item in ipairs(world.relationships) do
      if type(item) == "table" then
        lines[#lines + 1] = "• " .. tostring(item.from or "") .. " — " .. tostring(item.relation or "关联") .. " — " .. tostring(item.to or "")
      else
        lines[#lines + 1] = "• " .. tostring(item)
      end
    end
  end
  if type(world.shared_relationships) == "table" and #world.shared_relationships > 0 then
    lines[#lines + 1] = "\n共同关系"
    for _, item in ipairs(world.shared_relationships) do
      if type(item) == "table" then
        lines[#lines + 1] = "• " .. joinList(item.people) .. "｜" .. tostring(item.summary or "")
      end
    end
  end
  if world.historical_impact and world.historical_impact ~= "" then lines[#lines + 1] = "\n历史影响｜" .. tostring(world.historical_impact) end
  if type(world.knowledge_map) == "table" and #world.knowledge_map > 0 then
    lines[#lines + 1] = "\n知识结构"
    for _, item in ipairs(world.knowledge_map) do lines[#lines + 1] = "• " .. tostring(item) end
  end
  if type(world.arguments) == "table" and #world.arguments > 0 then
    lines[#lines + 1] = "\n核心论点"
    for _, item in ipairs(world.arguments) do lines[#lines + 1] = "• " .. tostring(item) end
  end
  if type(world.concept_links) == "table" and #world.concept_links > 0 then
    lines[#lines + 1] = "\n概念联系"
    for _, item in ipairs(world.concept_links) do lines[#lines + 1] = "• " .. tostring(item) end
  end
  if type(world.open_questions) == "table" and #world.open_questions > 0 then
    lines[#lines + 1] = "\n未解决问题"
    for _, item in ipairs(world.open_questions) do lines[#lines + 1] = "• " .. tostring(item) end
  end
  if world.source_note and world.source_note ~= "" then lines[#lines + 1] = "\n来源／可靠性｜" .. tostring(world.source_note) end
  return table.concat(lines, "\n")
end

function Storage.recapPath(book, chapter_key)
  return book.recaps_dir .. "/" .. tostring(chapter_key) .. ".json"
end

function Storage.saveRecap(book, chapter_key, recap)
  recap = recap or {}
  recap.chapter_key = chapter_key
  recap.created_at = recap.created_at or os.time()
  local ok = writeJson(Storage.recapPath(book, chapter_key), recap)
  if ok then
    local state = Storage.loadState(book)
    state.latest_recap_key = chapter_key
    state.latest_recap_title = recap.chapter or chapter_key
    state.latest_recap_at = recap.created_at
    Storage.saveState(book, state)
  end
  return ok
end

function Storage.loadRecap(book, chapter_key)
  if not chapter_key or chapter_key == "" then return nil end
  return readJson(Storage.recapPath(book, chapter_key), nil)
end

function Storage.loadLatestRecap(book)
  local state = Storage.loadState(book)
  return Storage.loadRecap(book, state.latest_recap_key)
end

function Storage.listRecaps(book)
  local result = {}
  for _, name in ipairs(listSortedFiles(book.recaps_dir, "%.json$")) do
    local item = readJson(book.recaps_dir .. "/" .. name, nil)
    if type(item) == "table" then result[#result + 1] = item end
  end
  table.sort(result, function(a, b) return (tonumber(a.created_at) or 0) < (tonumber(b.created_at) or 0) end)
  return result
end

function Storage.formatArchive(book)
  local state = Storage.loadState(book)
  local recaps = Storage.listRecaps(book)
  local latest = Storage.loadLatestRecap(book)
  local coverage = Storage.getCaptureCoverage(book)

  -- v1.2.6：全书档案以“当前阅读进度／本机采集覆盖／AI 复盘覆盖”三者分开显示。
  -- 这样从其他 Kindle 接着读时，不会把“已经读到第五回”误写成“本机拥有第一至第五回原文”。
  if latest then
    local latest_key = tostring(latest.chapter_key or state.latest_recap_key or "")
    local found = false
    for _, recap in ipairs(recaps) do
      local key = tostring(recap.chapter_key or "")
      if latest_key ~= "" and key == latest_key then found = true; break end
      if latest_key == "" and tonumber(recap.created_at) == tonumber(latest.created_at) then found = true; break end
    end
    if not found then recaps[#recaps + 1] = latest end
  end

  local lines = {"《" .. book.title .. "》KOAI 全书阅读档案"}
  if state.furthest_position then
    lines[#lines + 1] = "阅读进度记录到｜" .. Storage.formatPosition(state.furthest_position)
  elseif state.last_position then
    lines[#lines + 1] = "阅读进度记录到｜" .. Storage.formatPosition(state.last_position)
  end
  if state.last_recap_position then
    lines[#lines + 1] = "KOAI复盘覆盖到｜" .. Storage.formatPosition(state.last_recap_position)
  elseif latest then
    lines[#lines + 1] = "KOAI复盘覆盖到｜" .. tostring(latest.chapter or "最新复盘")
  else
    lines[#lines + 1] = "KOAI复盘覆盖到｜尚未生成"
  end
  lines[#lines + 1] = "前序阅读状态｜" .. Storage.formatPriorReadingStatus(book)
  if coverage.first then
    lines[#lines + 1] = "KOAI实时采集起点｜" .. Storage.formatPosition(coverage.first)
  end
  local prior = Storage.loadPriorRecap(book)
  local prior_info = Storage.getPriorReadingInfo(book)
  if prior_info.status == "read" and prior_info.backfill_status == "complete" then
    lines[#lines + 1] = "跨设备连续性｜前序已读内容已按当前电子书原文补建，并纳入精读上下文"
  elseif prior_info.status == "unread" then
    lines[#lines + 1] = "跨设备连续性｜前序确认未读，从首次实时采集点开始"
  elseif coverage.starts_mid_book then
    lines[#lines + 1] = "跨设备连续性｜前序是否已读尚未确认"
  end
  lines[#lines + 1] = "已保存复盘节点｜" .. tostring(#recaps) .. " 个"

  if #recaps == 0 then
    lines[#lines + 1] = "\n尚未生成进度复盘。"
    return table.concat(lines, "\n")
  end
  table.sort(recaps, function(a, b) return (tonumber(a.created_at) or 0) < (tonumber(b.created_at) or 0) end)

  if prior_info.status == "read" and prior and tostring(prior.display or prior.resume or "") ~= "" then
    lines[#lines + 1] = "\n◆ 前序已读补建档案"
    lines[#lines + 1] = tostring(prior.display or prior.resume or "")
  end

  if latest then
    lines[#lines + 1] = "\n◆ 最新累计档案｜" .. tostring(latest.chapter or "最新位置")
    local latest_text = Utils.normalize_whitespace(latest.display or latest.resume or latest.summary or "")
    lines[#lines + 1] = latest_text
  end

  local latest_key = latest and tostring(latest.chapter_key or state.latest_recap_key or "") or ""
  local history_count = 0
  for _, recap in ipairs(recaps) do
    local key = tostring(recap.chapter_key or "")
    local is_latest = latest and ((latest_key ~= "" and key == latest_key)
        or (latest_key == "" and tonumber(recap.created_at) == tonumber(latest.created_at)))
    if not is_latest then history_count = history_count + 1 end
  end

  if history_count > 0 then
    lines[#lines + 1] = "\n◆ 历史复盘节点"
    for _, recap in ipairs(recaps) do
      local key = tostring(recap.chapter_key or "")
      local is_latest = latest and ((latest_key ~= "" and key == latest_key)
          or (latest_key == "" and tonumber(recap.created_at) == tonumber(latest.created_at)))
      if not is_latest then
        lines[#lines + 1] = "\n" .. tostring(recap.chapter or "章节") .. "｜" .. os.date("%Y-%m-%d", tonumber(recap.created_at) or os.time())
        local text = Utils.normalize_whitespace(recap.resume or recap.display or recap.summary or "")
        lines[#lines + 1] = text
      end
    end
  end
  return table.concat(lines, "\n")
end

function Storage.formatResume(book)
  local state = Storage.loadState(book)
  local recap = Storage.loadLatestRecap(book)
  local mode_info = Storage.getReadingModeInfo(book, "")
  local mode_text = mode_info.automatic and (mode_info.effective_label .. "（自动判断）") or mode_info.effective_label
  local lines = {"《" .. book.title .. "》继续阅读回顾", "阅读模式｜" .. mode_text}
  local coverage = Storage.getCaptureCoverage(book)
  if state.last_position then lines[#lines + 1] = "上次停留｜" .. Storage.formatPosition(state.last_position) end
  if state.furthest_position then lines[#lines + 1] = "最远已读｜" .. Storage.formatPosition(state.furthest_position) end
  if state.last_recap_position then lines[#lines + 1] = "复盘已处理到｜" .. Storage.formatPosition(state.last_recap_position) end
  lines[#lines + 1] = "前序阅读状态｜" .. Storage.formatPriorReadingStatus(book)
  if coverage.first then lines[#lines + 1] = "KOAI实时采集起点｜" .. Storage.formatPosition(coverage.first) end
  if state.last_left_at then lines[#lines + 1] = "离开时间｜" .. os.date("%Y-%m-%d %H:%M", tonumber(state.last_left_at)) end
  if recap then
    local body = recap.resume or recap.display or recap.summary or ""
    if body ~= "" then lines[#lines + 1] = "\n" .. body end
  else
    lines[#lines + 1] = "\n尚无进度复盘。生成后会记录已处理位置，后续只分析新增内容。"
  end
  return table.concat(lines, "\n")
end

function Storage.exportMarkdown(book)
  ensureDir(EXPORTS_DIR)
  local content = {
    "# " .. book.title .. "｜KOAI 阅读档案", "", Storage.formatResume(book), "",
    Storage.formatCards(book), "", Storage.formatWorld(book), "", Storage.formatArchive(book),
  }
  local path = EXPORTS_DIR .. "/" .. safeName(book.title) .. "_KOAI阅读档案.md"
  if writeFileAtomic(path, table.concat(content, "\n\n---\n\n")) then return path end
  return nil
end

local function directorySize(path)
  local mode = lfs.attributes(path, "mode")
  if mode == "file" then return tonumber(lfs.attributes(path, "size")) or 0 end
  if mode ~= "directory" then return 0 end
  local total = 0
  for name in lfs.dir(path) do if name ~= "." and name ~= ".." then total = total + directorySize(path .. "/" .. name) end end
  return total
end

local function formatBytes(bytes)
  bytes = tonumber(bytes) or 0
  if bytes < 1024 then return tostring(bytes) .. " B" end
  if bytes < 1024 * 1024 then return string.format("%.1f KB", bytes / 1024) end
  if bytes < 1024 * 1024 * 1024 then return string.format("%.2f MB", bytes / 1024 / 1024) end
  return string.format("%.2f GB", bytes / 1024 / 1024 / 1024)
end

function Storage.getUsageReport(book)
  local capture_size = directorySize(book.captures_dir) + directorySize(book.capture_index_path) + directorySize(book.capture_keys_path)
  local card_size = directorySize(book.cards_dir) + directorySize(book.card_index_path)
  local recap_size = directorySize(book.recaps_dir) + directorySize(book.world_path)
  local legacy_size = directorySize(book.legacy_chapters_dir) + directorySize(book.legacy_cards_path)
  local book_total = directorySize(book.dir)
  local all_total = directorySize(BASE_DIR)
  local mode = tostring(getConfig().storage_mode or "standard")
  local mode_text = mode == "compact" and "节省空间" or (mode == "full" and "完整档案" or "标准")
  return table.concat({
    "《" .. book.title .. "》本地数据占用",
    "保存模式｜" .. mode_text,
    "本书总计｜" .. formatBytes(book_total),
    "去重后的已读文字｜" .. formatBytes(capture_size),
    "人物与典故卡片｜" .. formatBytes(card_size),
    "复盘、故事线与时间线｜" .. formatBytes(recap_size),
    "尚未清理的旧版采集文件｜" .. formatBytes(legacy_size),
    "KOAI 全部数据｜" .. formatBytes(all_total),
  }, "\n")
end

local function rotateBackups(book_id, keep)
  local root = BACKUPS_DIR .. "/" .. tostring(book_id)
  local dirs = listSortedFiles(root)
  table.sort(dirs, function(a, b) return a > b end)
  for index = keep + 1, #dirs do removeTree(root .. "/" .. dirs[index]) end
end

local function createUpgradeBackup(book, label)
  local root = BACKUPS_DIR .. "/" .. book.id
  ensureDir(root)
  local stamp = os.date("%Y%m%d_%H%M%S") .. "_" .. safeName(label or "backup")
  local target = root .. "/" .. stamp
  ensureDir(target)
  local files = {
    {book.state_path, "state.json"}, {book.legacy_cards_path, "cards.json"}, {book.world_path, "world.json"},
    {book.capture_index_path, "capture_index.json"}, {book.card_index_path, "card_index.json"},
  }
  for _, pair in ipairs(files) do if lfs.attributes(pair[1], "mode") == "file" then copyFile(pair[1], target .. "/" .. pair[2]) end end
  if lfs.attributes(book.cards_dir, "mode") == "directory" then copyTree(book.cards_dir, target .. "/cards") end
  if lfs.attributes(book.recaps_dir, "mode") == "directory" then copyTree(book.recaps_dir, target .. "/recaps") end
  rotateBackups(book.id, backupKeepCount())
end

function Storage.createMaintenanceBackup(book, label)
  createUpgradeBackup(book, label or "maintenance")
  return true
end

function Storage.cleanupBackups(book)
  rotateBackups(book.id, backupKeepCount())
  return true
end

local function ensureBookSchema(book)
  if schema_ready[book.id] then return end
  local state = Storage.loadState(book)
  local feature_version = tonumber(state.koai_feature_version) or 0
  if feature_version < 127 then
    createUpgradeBackup(book, "before_v1.2.7")
  elseif tonumber(state.storage_schema_version) ~= CAPTURE_SCHEMA_VERSION then
    createUpgradeBackup(book, "before_storage_migration")
  end
  migrateLegacyCards(book)
  state = Storage.loadState(book)
  if tonumber(state.capture_schema_version) ~= CAPTURE_SCHEMA_VERSION then
    local total, processed_id = 0, tonumber(state.last_recap_capture_id) or 0
    for _, name in ipairs(listSortedFiles(book.legacy_chapters_dir, "%.txt$")) do
      local count, processed = migrateLegacyCaptureFile(book, name, state)
      total = total + count
      processed_id = math.max(processed_id, processed)
    end
    state = Storage.loadState(book)
    if not state.last_recap_capture_id and processed_id > 0 then state.last_recap_capture_id = processed_id end
    state.capture_schema_version = CAPTURE_SCHEMA_VERSION
    state.storage_schema_version = CAPTURE_SCHEMA_VERSION
    state.legacy_capture_records_migrated = total
    Storage.saveState(book, state)
  end
  state = Storage.loadState(book)
  state.koai_feature_version = 127
  if not state.reading_mode then state.reading_mode = "auto" end
  Storage.saveState(book, state)
  schema_ready[book.id] = true
end

function Storage.getBookInfo(ui)
  ensureDir(BOOKS_DIR); ensureDir(EXPORTS_DIR); ensureDir(BACKUPS_DIR)
  local path = ui and ui.document and ui.document.file or ""
  local props = getDocumentProps(ui)
  local title = Utils.normalize_whitespace(tostring(props.title or props.doc_title or basename(path)))
  if title == "" then title = basename(path) end
  local authors = stringifyAuthors(props.authors or props.author)
  local file_attrs = path ~= "" and lfs.attributes(path) or nil
  local size = file_attrs and file_attrs.size or 0
  local signature = table.concat({title, authors, basename(path), tostring(size)}, "|")
  local book_id = hashText(signature)
  local dir = BOOKS_DIR .. "/" .. book_id
  local info = {
    id = book_id, title = title, authors = authors, path = path, dir = dir,
    state_path = dir .. "/state.json",
    world_path = dir .. "/world.json",
    legacy_cards_path = dir .. "/cards.json",
    legacy_chapters_dir = dir .. "/chapters",
    captures_dir = dir .. "/captures",
    capture_index_path = dir .. "/capture_index.json",
    capture_keys_path = dir .. "/capture_keys.log",
    cards_dir = dir .. "/cards",
    card_index_path = dir .. "/card_index.json",
    recaps_dir = dir .. "/recaps",
    prior_recap_path = dir .. "/prior_recap.json",
  }
  ensureDir(dir); ensureDir(info.legacy_chapters_dir); ensureDir(info.captures_dir); ensureDir(info.cards_dir); ensureDir(info.recaps_dir)
  local state = Storage.loadState(info)
  if state.book_id ~= book_id or state.title ~= title or state.authors ~= authors or state.path ~= path then
    state.book_id, state.title, state.authors, state.path = book_id, title, authors, path
    Storage.saveState(info, state)
  end
  ensureBookSchema(info)
  return info
end

local function rebuildCaptureStore(book, keep_after_id)
  local temp_dir = book.dir .. "/captures_rebuild"
  local temp_index_path = book.dir .. "/capture_index.rebuild.json"
  local temp_keys_path = book.dir .. "/capture_keys.rebuild.log"
  removeTree(temp_dir); ensureDir(temp_dir); os.remove(temp_index_path); os.remove(temp_keys_path)
  local index = defaultCaptureIndex()
  local seen, content_seen = {}, {}
  local kept, removed = 0, 0
  local function writeRecord(record)
    local ok, encoded = pcall(json.encode, record)
    if not ok then return false end
    encoded = encoded .. "\n"
    if index.current_chunk_size > 0 and index.current_chunk_size + #encoded > DEFAULT_CHUNK_BYTES then
      index.current_chunk = index.current_chunk + 1; index.current_chunk_size = 0
    end
    local path = temp_dir .. "/chunk_" .. string.format("%06d", index.current_chunk) .. ".jsonl"
    local file = io.open(path, "ab")
    if not file then return false end
    file:write(encoded); file:close()
    local position_hash = hashText(tostring(record.position_key or "") .. "|" .. tostring(record.original_digest or record.digest or ""))
    local content_hash = hashText(tostring(record.chapter_key or "") .. "|" .. tostring(record.original_digest or record.digest or ""))
    local keyfile = io.open(temp_keys_path, "ab")
    if keyfile then
      keyfile:write("P\t", position_hash, "\t", tostring(record.id), "\n")
      keyfile:write("C\t", content_hash, "\t", tostring(record.id), "\n")
      keyfile:close()
    end
    seen[position_hash], content_seen[content_hash] = true, true
    index.current_chunk_size = index.current_chunk_size + #encoded
    index.total_records = index.total_records + 1
    index.total_chars = index.total_chars + (tonumber(record.chars) or Utils.utf8Length(record.text or ""))
    index.next_id = math.max(index.next_id, (tonumber(record.id) or 0) + 1)
    index.last_record = {
      id = record.id, chapter = record.chapter, chapter_key = record.chapter_key, page = record.page,
      percent = record.percent, xpointer = record.xpointer, position_key = record.position_key,
      captured_at = record.captured_at, text_tail = Utils.utf8Tail(record.text or "", 320),
    }
    return true
  end
  eachCaptureRecord(book, function(record)
    local pkey = hashText(tostring(record.position_key or "") .. "|" .. tostring(record.original_digest or record.digest or ""))
    local ckey = hashText(tostring(record.chapter_key or "") .. "|" .. tostring(record.original_digest or record.digest or ""))
    local unique = not seen[pkey] and not content_seen[ckey]
    if not unique then
      removed = removed + 1
      return
    end

    -- 即使节省空间模式删除了已处理原文，也保留永久去重指纹；以后回看旧页不会再次采集或进入新复盘。
    seen[pkey], content_seen[ckey] = true, true
    local keep_record = not (keep_after_id and tonumber(record.id) <= keep_after_id)
    if keep_record then
      -- writeRecord 会把指纹再写入日志；这里先临时撤销，避免其判定逻辑受影响。
      if writeRecord(record) then kept = kept + 1 else removed = removed + 1 end
    else
      local keyfile = io.open(temp_keys_path, "ab")
      if keyfile then
        keyfile:write("P\t", pkey, "\t", tostring(record.id), "\n")
        keyfile:write("C\t", ckey, "\t", tostring(record.id), "\n")
        keyfile:close()
      end
      removed = removed + 1
      index.next_id = math.max(index.next_id, (tonumber(record.id) or 0) + 1)
    end
  end)
  writeJson(temp_index_path, index)
  local old_dir = book.dir .. "/captures_old"
  removeTree(old_dir)
  os.rename(book.captures_dir, old_dir)
  if not os.rename(temp_dir, book.captures_dir) then os.rename(old_dir, book.captures_dir); return nil end
  os.remove(book.capture_index_path); os.rename(temp_index_path, book.capture_index_path)
  os.remove(book.capture_keys_path); os.rename(temp_keys_path, book.capture_keys_path)
  removeTree(old_dir)
  capture_cache[book.id] = nil
  return {kept = kept, removed = removed}
end

function Storage.compactDuplicateCaptures(book)
  return rebuildCaptureStore(book, nil)
end

function Storage.applyStoragePolicy(book)
  local config = getConfig()
  if tostring(config.storage_mode or "standard") ~= "compact" then return nil end
  local state = Storage.loadState(book)
  local processed = tonumber(state.last_recap_capture_id) or 0
  local keep_recent = tonumber(config.compact_keep_recent_records) or 30
  local cutoff = math.max(0, processed - keep_recent)
  if cutoff <= 0 then return nil end
  return rebuildCaptureStore(book, cutoff)
end

function Storage.cleanupLegacyCaptureFiles(book)
  local state = Storage.loadState(book)
  if tonumber(state.capture_schema_version) ~= CAPTURE_SCHEMA_VERSION then return false, "旧数据尚未迁移" end
  local removed = 0
  for _, name in ipairs(listSortedFiles(book.legacy_chapters_dir, "%.txt$")) do
    if os.remove(book.legacy_chapters_dir .. "/" .. name) then removed = removed + 1 end
  end
  return true, removed
end

function Storage.deleteBookData(book)
  capture_cache[book.id], card_index_cache[book.id], schema_ready[book.id] = nil, nil, nil
  return removeTree(book.dir)
end

function Storage.getBaseDir()
  ensureDir(BASE_DIR)
  return BASE_DIR
end

function Storage.hashText(text)
  return hashText(text)
end

return Storage
