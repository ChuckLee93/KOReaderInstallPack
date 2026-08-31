--[[--
生僻字注音插件 (Rare-Char Pinyin Annotator for KOReader)
自用修改版, 仅作个人使用。

仿 Kindle "生字注音" 功能: 在中文页面每个汉字上方(或下方)叠加拼音,
并可按"常用度等级"控制只给较生僻的字注音。

v6.2: 词组辨音改为始终开启(纯查表不影响翻页, 不设开关); 菜单仅保留
  「生词本注音: 开/关」一项开关, 开关状态直接写在菜单文字里。
v6.1: 单字生词读音也走词组辨音(行列 háng / 举行 xíng), 不再锁默认读音。
v6.0 新增(在 v5.7 性能底座上, 不改动任何快筛/缓存/预算机制):
  * 生词本关联: 查词加入生词本(vocabbuilder)的词, 整词出现在页面上才注音
    (词级精确匹配: "感悟"入本则"感""悟"单独出现不注); 单字入本则该字处处注音。
    只读 SQLite + mtime 检查同步, 删改生词自动生效, 不常驻连接。
  * 多音字词组辨音: 结合上下文词组判断读音(银行 háng / 行走 xíng),
    最长匹配优先, 未命中回退常用读音。词组表惰性加载, 首次触发才读入。
  * 默认读音修正: 修正 kTGHZ2013 把罕见读音排前的字(行 háng→xíng 等 430 字)。
  * 单页注音上限 30(保险丝): 建计划阶段收满即停, 扫描与绘制两头都省。

实现要点:
  * 通过 crengine 的 getPageXPointer / getNextVisibleChar 逐个字符遍历当前页,
    并用 getScreenBoxesFromPositions 取得每个字的屏幕坐标盒子;
  * 用 TextWidget 把拼音直接绘制到屏幕缓冲 Screen.bb 上, 再局部刷新。

@module koplugin.Pinyin
--]]--

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
local Screen = require("device").screen
local Blitbuffer = require("ffi/blitbuffer")
local util = require("util")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local DataStorage = require("datastorage")

local PinyinData = require("pinyin_data")

-- v6.0 数据表(均自动生成, 详见 gen_phrase_data.py):
--   polyphone_index.lua: 多音字索引(小, 启动即载) —— 命中才惰性加载词组表
--   phrase_data.lua:     词组辨音表(约 320KB, 惰性加载)
--   default_fix.lua:     默认读音修正表(小, 启动即载)
local ok_idx, PolyIdx = pcall(require, "polyphone_index")
if not ok_idx or type(PolyIdx) ~= "table" then PolyIdx = {} end
local ok_fix, DefaultFix = pcall(require, "default_fix")
if not ok_fix or type(DefaultFix) ~= "table" then DefaultFix = {} end

-- 插件配置(config.lua): 两项高级开关, 默认均为关闭。修改后需重启 KOReader 生效。
local ok_cfg, PinyinConfig = pcall(require, "config")
if not ok_cfg or type(PinyinConfig) ~= "table" or PinyinConfig._pinyin ~= true then
    PinyinConfig = {}
end
local CFG_DEBUG_LOG = PinyinConfig.enable_debug_log == true
local CFG_SHOW_DIAG = PinyinConfig.show_diagnostics == true

-- 等级阈值: rank 越大越生僻。show = (rank > 阈值), 阈值越大注音越少。
-- 1-5 级在"仅极生僻"与"较生僻"之间等差细分(7000→4000):
--   1 级 = 最生僻字 (rank>7000, 最严)
--   2 级 = 生僻字 (rank>6250, 默认)
--   3 级 = 较生僻字 (rank>5500)
--   4 级 = 生字较多 (rank>4750)
--   5 级 = 生字注音 (rank>4000, 最宽)
local LEVEL_THRESHOLD = {
    [1] = 7000,
    [2] = 6250,  -- 默认
    [3] = 5500,
    [4] = 4750,
    [5] = 4000,  -- 生字注音 (rank>4000, 最宽, 覆盖原"默认 3 级")
}
local DEFAULT_LEVEL = 2

-- v6.0 参数
local VOCAB_DB = DataStorage:getSettingsDir() .. "/vocabulary_builder.sqlite3"
local LOOKAHEAD = 5       -- 辨音右窗(字后最多取 5 个字, 配合左窗凑 2~6 字词组)
local MAX_WORD_LEN = 6    -- 词组匹配最大长度(字)
local MAX_ANNOT = 30      -- 单页注音上限(保险丝): 收满即停, 扫描与绘制都省

-- 插件版本(对外显示 v2.0; 内部开发迭代号 6.4, 仅记录于 README/日志)
local VERSION = "2.0"

local Pinyin = WidgetContainer:extend{
    name = "pinyin",
    is_doc_only = true,
}

-- 取字读音: 优先用修正表(kTGHZ2013 部分字罕见读音排前), 回退插件默认
local function resolvePy(entry, ch)
    return DefaultFix[ch] or entry:match("^([^|]+)")
end

-- 惰性加载词组辨音表(首次遇到多音字才 require, 之后常驻; false=加载失败不再重试)
local function getPhrases(self)
    if self._phrases ~= nil then return self._phrases end
    local ok, P = pcall(require, "phrase_data")
    self._phrases = (ok and type(P) == "table") and P or false
    return self._phrases
end

function Pinyin:init()
    self.enabled = G_reader_settings:readSetting("pinyin_enabled", false)
    self.level = G_reader_settings:readSetting("pinyin_level", DEFAULT_LEVEL)
    self.font_size = G_reader_settings:readSetting("pinyin_font_size", 12)
    self.font_name = G_reader_settings:readSetting("pinyin_font", "cfont")
    self.position = "above"  -- 固定显示在汉字上方, 不开放修改
    self.gray = G_reader_settings:readSetting("pinyin_gray", false)
    self.debug = CFG_DEBUG_LOG  -- 由 config.lua 的 enable_debug_log 控制, 默认关闭
    self.show_diagnostics = CFG_SHOW_DIAG  -- 由 config.lua 的 show_diagnostics 控制, 默认关闭
    self.vocab_link = G_reader_settings:readSetting("pinyin_vocab_link", true)
    self.plan = {}  -- view module 绘制计划
    self._vocab = nil    -- 生词本词表(惰性, mtime 同步)
    self._phrases = nil  -- 词组辨音表(惰性)

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    if self.ui and self.ui.view and self.ui.view.registerViewModule then
        self.ui.view:registerViewModule("pinyin_overlay", self)
    end

    if self.enabled then
        -- 文档就绪后延迟绘制首屏(给 crengine/ReaderView 一点时间完成首屏渲染)
        UIManager:scheduleIn(0.3, function()
            self:drawPinyin()
        end)
    end
end

-- ---------------------------------------------------------------------------
-- 生词本关联: 只读 SQLite + mtime 同步
-- ---------------------------------------------------------------------------

-- 检查生词库是否变化; 未变时成本 = 一次 stat(微秒级)。变化才重读并作废页面缓存。
function Pinyin:_refreshVocab()
    if not self.vocab_link then
        if self._vocab ~= nil then
            self._vocab = nil
            self._plan_cache = {}
        end
        return
    end
    local mtime
    local ok_lfs, m = pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        return lfs.attributes(VOCAB_DB, "modification")
    end)
    mtime = (ok_lfs and m) or nil
    if not mtime then
        -- 生词库不存在(未用过生词本)或取不到时间: 视为无生词
        if self._vocab ~= nil then
            self._vocab = nil
            self._plan_cache = {}
        end
        return
    end
    if self._vocab and self._vocab.mtime == mtime then
        return -- 未变化, 零成本
    end
    -- mtime 变了(加词/删词/复习都会写库): 重读词表
    local v = { mtime = mtime, words = {}, charset = {}, maxlen = 0, n = 0, bytes = 0 }
    local ok_sq, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if ok_sq then
        pcall(function()
            local conn = SQ3.open(VOCAB_DB)
            local res = conn:exec("SELECT word FROM vocabulary;")
            conn:close()
            if res and type(res.word) == "table" then
                for _, w in ipairs(res.word) do
                    if type(w) == "string" and w ~= "" then
                        v.words[w] = true
                        v.n = v.n + 1
                        v.bytes = v.bytes + #w
                        local n = 0
                        for ch in w:gmatch(util.UTF8_CHAR_PATTERN) do
                            v.charset[ch] = true
                            n = n + 1
                        end
                        if n > v.maxlen then v.maxlen = n end
                    end
                end
            end
        end)
    end
    -- 复习/回顾只改时间字段不改词表: 词数与总字节数相同则视为词表未变, 不作废缓存
    if self._vocab and self._vocab.n == v.n and self._vocab.bytes == v.bytes then
        self._vocab.mtime = mtime
    else
        self._vocab = v
        self._plan_cache = {}
    end
end

-- 文本里是否出现任何生词(纯 C 速度的 plain find; 页级快筛与行级收窄共用)
local function textHasVocabWord(v, text)
    for w in pairs(v.words) do
        if text:find(w, 1, true) then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- 词组辨音与生词匹配(全部只发生在"本来就要注音"的字之后, 纯查表)
-- ---------------------------------------------------------------------------

-- 核心查表: 在单字数组 chs 里, 以第 j 个字为中心, 取 2~6 字窗口(最长优先)
-- 查词组表; 命中返回该字在词组内对应位置的读音, 未命中返回 nil。
local function phraseLookup(self, chs, j, stats)
    local phrases = getPhrases(self)
    if not phrases then return nil end
    local n = #chs
    local maxL = MAX_WORD_LEN
    if maxL > n then maxL = n end
    for L = maxL, 2, -1 do
        local s_lo = j - L + 1
        if s_lo < 1 then s_lo = 1 end
        for s = s_lo, j do
            local e = s + L - 1
            if e <= n then
                local val = phrases[table.concat(chs, nil, s, e)]
                if val then
                    local idx = 1
                    for py in val:gmatch("[^%s]+") do
                        if idx == j - s + 1 then
                            if stats then
                                stats.phrase_hits = (stats.phrase_hits or 0) + 1
                            end
                            return py
                        end
                        idx = idx + 1
                    end
                end
            end
        end
    end
    return nil
end

-- 词 w 的逐字读音: 词组表直接命中用词组读音; 否则用词的"最长前缀"定位
-- 各字读音(如生词"银行家"不在词组表, 但前缀"银行"命中 → 行 读 háng,
-- 前缀覆盖不到的字用默认读音)。不用任意子串窗口, 避免词内其他子词
-- (如"银行家"里的"行家")劫走读音。
function Pinyin:_wordPys(w)
    local chs = {}
    for ch in w:gmatch(util.UTF8_CHAR_PATTERN) do
        chs[#chs + 1] = ch
    end
    local n = #chs
    local out = {}
    local phrases = getPhrases(self)
    if phrases then
        local pys = nil
        local cover = 0
        local val = phrases[w]
        if val then
            for py in val:gmatch("[^%s]+") do
                pys = pys or {}
                pys[#pys + 1] = py
            end
            cover = n
        else
            -- 最长前缀(≥2 字, 上限 MAX_WORD_LEN)
            for L = math.min(n, MAX_WORD_LEN), 2, -1 do
                local pv = phrases[table.concat(chs, nil, 1, L)]
                if pv then
                    pys = {}
                    for py in pv:gmatch("[^%s]+") do
                        pys[#pys + 1] = py
                    end
                    cover = L
                    break
                end
            end
        end
        if pys then
            for k = 1, n do
                if k <= cover then
                    out[k] = pys[k]
                else
                    local entry = PinyinData.data[chs[k]]
                    out[k] = entry and resolvePy(entry, chs[k]) or nil
                end
            end
            return out
        end
    end
    for k = 1, n do
        local entry = PinyinData.data[chs[k]]
        out[k] = entry and resolvePy(entry, chs[k]) or nil
    end
    return out
end

-- 生词词组匹配: 词尾落在 rt[j] 时, 从最长到最短尝试 rt 片段是否为生词。
-- 命中则给词内各字写入 word_py(优先于等级注音, 自然去重); 与已命中词重叠则试更短。
function Pinyin:_matchVocabWord(rt, j, stats)
    local v = self._vocab
    if not v or v.n == 0 then return end
    if not v.charset[rt[j].ch] then return end -- 词尾字必在生词字集里, 一次查表预筛
    local maxL = v.maxlen
    if maxL > MAX_WORD_LEN then maxL = MAX_WORD_LEN end
    if maxL > j then maxL = j end
    for L = maxL, 1, -1 do
        local s = j - L + 1
        if s >= 1 then
            local buf = {}
            for k = s, j do buf[#buf + 1] = rt[k].ch end
            local w = table.concat(buf)
            if v.words[w] then
                local overlap = false
                for k = s, j do
                    if rt[k].word_py or rt[k].vocab_show then
                        overlap = true; break
                    end
                end
                if not overlap then
                    if L == 1 then
                        -- 单字生词: 只标记"必须注音", 读音不在此锁定, 留到发射时
                        -- 经词组辨音决定(如"行"在"行列"读 háng、单独出现读默认 xíng)。
                        -- 若此处直接写 word_py=_wordPys(w), 单字查不到词组表(词组
                        -- 均为 2~6 字), 必然回退默认读音, 辨音永远没有机会执行。
                        rt[j].vocab_show = true
                    else
                        local pys = self:_wordPys(w)
                        for k = s, j do
                            local py = pys[k - s + 1]
                            if py then rt[k].word_py = py end
                        end
                    end
                    stats.vocab_matches = (stats.vocab_matches or 0) + 1
                    return
                end
                -- 与已注音词重叠: 试更短的词(最长匹配优先, 不重复标注)
            end
        end
    end
end

-- 多音字辨音: 取 rt[j] 前后各 LOOKAHEAD 字作窗口, 最长优先查词组表;
-- 命中返回对应位置读音, 未命中返回 nil(回退默认)。
function Pinyin:_disambiguate(rt, j, stats)
    local n = #rt
    local lo = j - LOOKAHEAD
    if lo < 1 then lo = 1 end
    local hi = j + LOOKAHEAD
    if hi > n then hi = n end
    local chs = {}
    for k = lo, hi do
        chs[#chs + 1] = rt[k].ch
    end
    return phraseLookup(self, chs, j - lo + 1, stats)
end

-- 发射一条注音(推迟到字滑出右窗或区间结束时; 盒子也在此时才取, 仍在同一次
-- drawPinyin 调用内, 屏幕状态与逐字遍历时一致)。
-- 优先级: 生词词组 word_py > 单字生词(必注, 读音经词组辨音) > 等级过滤。
function Pinyin:_emitRec(rt, j, plan, stats, doc)
    local rec = rt[j]
    if stats.emitted >= MAX_ANNOT then
        stats.capped = true
        return
    end
    local py
    if rec.word_py then
        py = rec.word_py
    elseif rec.show or rec.vocab_show then
        py = rec.py
        -- 词组辨音始终开启(v6.2): 只对"本来就要注音"的多音字做纯查表
        -- (实测单字 <0.01ms, 无注音页面成本为零), 无需开关。
        if PolyIdx[rec.ch] then
            local d = self:_disambiguate(rt, j, stats)
            if d then py = d end
        end
    else
        return
    end
    if not py then return end
    local boxes = doc:getScreenBoxesFromPositions(rec.xp, rec.next_xp, true)
    local box = boxes and boxes[1]
    local bx, by, bw, bh
    if box then
        bx, by, bw, bh = box.x, box.y, box.w, box.h
    else
        -- 极少数情况盒子取不到, 退回用屏幕坐标定位(字宽按字号近似)
        local sy, sx = doc:getScreenPositionFromXPointer(rec.xp)
        if sx and sy then
            bx, by, bw, bh = sx, sy,
                math.floor(self.font_size), math.floor(self.font_size)
        end
    end
    if not bx then return end
    stats.emitted = (stats.emitted or 0) + 1
    stats.boxes = stats.boxes + 1
    plan[#plan + 1] = {
        x = bx, y = by, w = bw, h = bh,
        chars = { { ch = rec.ch, py = py, cx = bx + bw / 2 } },
    }
end

function Pinyin:onReaderReady()
    -- 注册为 ReaderView 的 view module, 这样每次页面重绘都会自动调用 paintTo,
    -- 拼音能稳定地画在页面内容之上, 不再依赖 setDirty 回调的时机。
    if self.ui and self.ui.view and self.ui.view.registerViewModule then
        self.ui.view:registerViewModule("pinyin_overlay", self)
    end
    if self.enabled then
        -- 文档就绪后再延迟一点, 确保当前页坐标已建立
        UIManager:scheduleIn(0.5, function()
            self:drawPinyin()
        end)
    end
end

function Pinyin:onPageUpdate(new_page)
    if self.enabled then
        -- 同步更新 plan: PageUpdate 事件在 ReaderView 重绘之前被广播,
        -- 此时把 plan 换成新页, 接下来的页面重绘就会直接画新页拼音。
        self:drawPinyin(new_page)
    end
end

-- 滚动模式下没有 PageUpdate, 而是 PosUpdate; 同时监听避免翻页/滚动后不刷新。
function Pinyin:onPosUpdate()
    if self.enabled then
        self:drawPinyin()
    end
end

-- 取得当前阅读页号
function Pinyin:getCurrentPage()
    if self.view and self.view.state and self.view.state.page then
        return self.view.state.page
    end
    local doc = self.ui and self.ui.document
    if doc and doc.getCurrentPage then
        local ok, p = pcall(doc.getCurrentPage, doc)
        if ok and p then return p end
    end
    return nil
end

-- 核心: 在当前页每个汉字上方/下方绘制拼音
-- target_page: 可选, 指定要绘制的页号; 不传则取当前页。
function Pinyin:drawPinyin(target_page)
    if not self.enabled then return end
    if not (self.ui and self.ui.dialog) then return end
    local doc = self.ui and self.ui.document
    if not doc or type(doc.getPageXPointer) ~= "function" then
        -- 仅支持 crengine 类文档; PDF/DjVu 暂不支持。已实测 EPUB/DOCX/HTML 可正常取字注音, 其它格式未充分测试(可能显示不出拼音)。
        return
    end
    local page = target_page or self:getCurrentPage()
    if self.debug then
        logger.warn(string.format("[Pinyin] drawPinyin called, target_page=%s current_page=%s",
            tostring(target_page), tostring(self:getCurrentPage())))
    end
    if not page or page < 1 then return end
    local t_start = os.clock()

    -- 生词库同步(mtime 检查, 微秒级; 词表变化才作废页面缓存)
    self:_refreshVocab()

    local ok, pos0 = pcall(doc.getPageXPointer, doc, page)
    if not ok or not pos0 then return end
    local pos1 = doc:getPageXPointer(page + 1)
    if not pos1 then return end

    local face = Font:getFace(self.font_name, self.font_size)
    local pinyin_h = math.floor(self.font_size * 1.25)
    local threshold = LEVEL_THRESHOLD[self.level] or 4000
    local fgcolor = self.gray and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK

    -- 快筛 + 缓存通道: 先一次性取整页文本(1 次 CRE 调用), 纯 Lua 查本页是否有
    -- 需要注音的字(等级目标字, 或整词出现的生词)。绝大多数页面两者皆无 →
    -- 直接返回, 完全跳过下面的逐字遍历(逐字遍历要 300~600 字 × 3 次 CRE 桥调用,
    -- 是翻页"长时间不动"的元凶)。有目标的页面才走逐字定位通道, 且结果按
    -- (页码|等级|字号) 缓存, 翻回同一页零成本。
    local cache_key = string.format("%d|%d|%d", page, self.level, self.font_size)
    if not self._plan_cache then self._plan_cache = {} end
    if self._plan_cache[cache_key] ~= nil then
        -- 缓存命中: 直接复用上次的绘制计划, 同时把诊断数据也切到本页,
        -- 保证"诊断数字"始终对应当前页(旧版缓存命中不更新 last_stats,
        -- 导致诊断显示的是几页前的数据, 与页面注音对不上)。
        local cached = self._plan_cache[cache_key]
        self.plan = cached.plan or {}
        self.last_stats = cached.stats
        self.last_stats_page = cached.page or page
        self.last_detail = {}
        self.last_box_words = {}
        self.plan_face = face
        self.plan_pinyin_h = pinyin_h
        self.plan_fgcolor = fgcolor
        self.last_plan_page = page
        if self.ui and self.ui.dialog then
            UIManager:setDirty(self.ui.dialog, "ui")
        end
        return
    end

    local full_text = doc:getTextFromXPointers(pos0, pos1)
    if type(full_text) == "table" then
        full_text = full_text.text or ""
    end
    local vocab_on = self.vocab_link and self._vocab ~= nil and self._vocab.n > 0
    local page_vocab = vocab_on and type(full_text) == "string"
        and full_text ~= "" and textHasVocabWord(self._vocab, full_text) or false
    -- 快筛同时统计整页目标字总数(full_target_count), 供段级定位的覆盖校验用:
    -- 若行级盒子漏检了某些目标字, 据此判定回退全页遍历, 保证不丢注音。
    local full_target_count = 0
    if type(full_text) == "string" and full_text ~= "" then
        for ch in full_text:gmatch(util.UTF8_CHAR_PATTERN) do
            local entry = PinyinData.data[ch]
            if entry then
                local rk = tonumber(entry:match("|(%d+)$")) or 999999
                if rk > threshold then
                    full_target_count = full_target_count + 1
                end
            end
        end
        if full_target_count == 0 and not page_vocab then
            -- 本页无目标字也无生词: 清空计划并返回, 翻页自身的重绘会自然清掉旧拼音,
            -- 不再请求额外重绘, 翻页开销降至接近零。
            self.plan = {}
            local empty_stats = { boxes = 0, words = 0, chars = 0,
                                  with_data = 0, shown = 0, filtered = 0,
                                  no_data = 0, elapsed_ms = 0,
                                  emitted = 0, vocab_matches = 0, phrase_hits = 0 }
            self._plan_cache[cache_key] = { plan = {}, stats = empty_stats, page = page }
            self.last_stats = empty_stats
            self.last_stats_page = page
            self.last_detail = {}
            self.last_box_words = {}
            self.last_plan_page = page
            return
        end
    end

    -- 段级定位: 快筛已确认本页有目标(生僻字或整词生词)。先用 1 次调用取整页的
    -- 行级盒子(getScreenBoxesFromPositions 返回约一页行数目的盒子, 屏幕坐标),
    -- 再对每个行盒用 getTextFromPositions 取该行文本与 xpointer 边界,
    -- 只对"确实含目标"的行做逐字定位——把逐字遍历从"全页 300~600 字"
    -- 缩到"仅含目标的行(每行约 20~50 字)", 目标越少的页省得越多。
    -- 行级命中的目标字总数与整页统计对比: 若行级漏检(某些行盒取不到文本),
    -- 自动回退全页逐字遍历, 功能优先、不丢注音。
    local plan = {}
    local stats = { boxes = 0, words = 0, chars = 0,
                    with_data = 0, shown = 0, filtered = 0,
                    no_data = 0, elapsed_ms = 0,
                    emitted = 0, vocab_matches = 0, phrase_hits = 0 }
    local detail = {}
    local box_words = {}
    local MAX_DETAIL = 400

    local iter = 0
    local MAX_ITER = 1500       -- 单页逐字上限: 一页最多约 600 字, 1500 足够, 防呆
    local BUDGET_SEC = 0.25     -- 单页处理耗时预算(秒): 超时立即停止扫描, 绝不长时间冻结 UI。
                                -- v5.4 曾降到 0.2s, 但 5 级(注音最多)实测 ~19% 的页仅超 3~4ms
                                -- 被整页放弃导致"页面没注音"; 放宽回 0.25s 并配合"超时画部分",
                                -- 实测 203/204ms 的页均能完成, 残余超时页也至少有部分拼音。
    local t0 = os.clock()       -- 预算计时起点
    local aborted = false       -- 超预算标志

    -- 1) 整页行盒 → 逐行取文本, 筛出含目标(生僻字/整词生词)的行, 得到待遍历区间
    local ranges = {}          -- 待逐字定位的区间列表
    local method = "FULL"      -- 实际使用的通道: SEG=仅目标行, FULL=整页(回退)
    local seg_target_count = 0 -- 行级命生的目标字总数(用于覆盖校验)
    local seg_vocab_hit = false
    local seg_boxes = doc:getScreenBoxesFromPositions(pos0, pos1, true)
    if seg_boxes and #seg_boxes > 0 then
        local seg_i = 0
        for _, sb in ipairs(seg_boxes) do
            seg_i = seg_i + 1
            -- 预算保护: 每处理 1 个行盒都检查耗时(含行内逐字统计成本),
            -- 超时立即放弃本页
            if os.clock() - t0 > BUDGET_SEC then
                aborted = true
                break
            end
            local tr = doc:getTextFromPositions(
                { x = sb.x, y = sb.y },
                { x = sb.x + sb.w, y = sb.y + sb.h },
                true)  -- do_not_draw_selection: 避免 crengine 每行都绘制选区高亮(重开销)
            if tr and tr.text and tr.text ~= "" and tr.pos0 and tr.pos1 then
                local n_t = 0
                for ch in tr.text:gmatch(util.UTF8_CHAR_PATTERN) do
                    local entry = PinyinData.data[ch]
                    if entry then
                        local rk = tonumber(entry:match("|(%d+)$")) or 999999
                        if rk > threshold then
                            n_t = n_t + 1
                        end
                    end
                end
                local line_vocab = page_vocab and textHasVocabWord(self._vocab, tr.text)
                if line_vocab then seg_vocab_hit = true end
                if n_t > 0 or line_vocab then
                    seg_target_count = seg_target_count + n_t
                    ranges[#ranges + 1] = { pos0 = tr.pos0, pos1 = tr.pos1 }
                end
            end
        end
        -- 行级覆盖完整(生僻字不丢, 且页面生词都能在行内找到)才走最快通道;
        -- 生词跨行被行级漏检时回退整页遍历——整页通道的字流连续, 跨行词也能匹配。
        if seg_target_count >= full_target_count and (not page_vocab or seg_vocab_hit) then
            method = "SEG"
        else
            ranges = { { pos0 = pos0, pos1 = pos1 } }
        end
    else
        -- 行盒取不到: 直接整页遍历
        ranges = { { pos0 = pos0, pos1 = pos1 } }
    end

    -- 2) 逐字定位: 仅对目标行(或回退时的整页)做逐字遍历。
    --    每个字: 先取文本(便宜) → 拆字查拼音按等级过滤(纯 Lua) →
    --    生词词尾字做词组匹配(纯 Lua 查表) → 字滑出右窗(LOOKAHEAD 字)时
    --    才决定最终读音(词组辨音)并取屏幕盒子(昂贵)发射。
    for _, rg in ipairs(ranges) do
        local xp = rg.pos0
        local rt = {}          -- 本区间已遍历字符的记录(字, xpointer, 读音决策)
        local next_emit = 1    -- 下一个待发射记录的下标
        while xp and iter < MAX_ITER do
            iter = iter + 1
            -- 预算保护: 每查 1 字都检查耗时(单字成本波动大, 实测约 0.5~1.8ms/字,
            -- 每字检查使最坏严格上界 = 预算 + 1 字成本, 不再有漏网窗口)
            if os.clock() - t0 > BUDGET_SEC then
                aborted = true
                break
            end
            -- compareXPointers 返回 1 表示 xp 在 rg.pos1 之前(有序), 0 相同, -1 之后。
            local cmp = doc:compareXPointers(xp, rg.pos1)
            if not cmp or cmp ~= 1 then break end

            local next_xp = doc:getNextVisibleChar(xp)
            if not next_xp or next_xp == xp then break end

            -- 先取该段的文本(便宜); 屏幕盒子留到发射时才取(昂贵)。
            local tr = doc:getTextFromXPointers(xp, next_xp)
            local word = (type(tr) == "string" and tr)
                       or (type(tr) == "table" and tr.text) or ""

            if word ~= "" then
                stats.words = stats.words + 1
                if self.debug and #box_words < 512 then
                    local wshow = word:sub(1, 40)
                    box_words[#box_words + 1] = string.format("#%d:%s%s",
                        stats.words, wshow, #word > 40 and "…" or "")
                end
                -- 拆字并做拼音查表与等级过滤(纯 Lua, 便宜)
                for ch in word:gmatch(util.UTF8_CHAR_PATTERN) do
                    stats.chars = stats.chars + 1
                    local rec = { ch = ch, xp = xp, next_xp = next_xp }
                    local entry = PinyinData.data[ch]
                    if entry then
                        stats.with_data = stats.with_data + 1
                        local rk = tonumber(entry:match("|(%d+)$")) or 999999
                        rec.py = resolvePy(entry, ch)
                        if rk > threshold then
                            rec.show = true
                            stats.shown = stats.shown + 1
                        else
                            stats.filtered = stats.filtered + 1
                            if self.debug and #detail < MAX_DETAIL then
                                detail[#detail + 1] = string.format(
                                    "  [filtered] '%s' rank=%d thr=%d",
                                    ch, rk, threshold)
                            end
                        end
                    else
                        stats.no_data = stats.no_data + 1
                        if self.debug and #detail < MAX_DETAIL then
                            detail[#detail + 1] = string.format("  [no-data] '%s'", ch)
                        end
                    end
                    rt[#rt + 1] = rec
                    -- 生词词组匹配(词尾落在刚追加的字; 预筛一次查表)
                    if vocab_on then
                        self:_matchVocabWord(rt, #rt, stats)
                    end
                end
            end

            -- 发射已滑出右窗的记录(此时该字的辨音右上下文已齐)
            while next_emit <= #rt - LOOKAHEAD do
                self:_emitRec(rt, next_emit, plan, stats, doc)
                if stats.capped then break end
                next_emit = next_emit + 1
            end
            if stats.capped then break end
            xp = next_xp
        end
        -- 区间结束: 发射剩余记录(右上下文不足 LOOKAHEAD 字, 按已有窗口辨音)
        while next_emit <= #rt and not stats.capped do
            self:_emitRec(rt, next_emit, plan, stats, doc)
            if stats.capped then break end
            next_emit = next_emit + 1
        end
        if aborted or stats.capped then break end
    end

    -- 超预算中止: 绝不长时间冻结 UI(死机根因)。与旧版"整页放弃"不同,
    -- 已扫出的拼音照常画出来并缓存, 页面至少有部分注音, 翻回也不重扫。
    if aborted then
        stats.elapsed_ms = math.floor((os.clock() - t_start) * 1000)
        if self.debug then
            logger.warn(string.format("[Pinyin] page=%d over budget (%.2fs), partial plan=%d kept, elapsed=%dms",
                page, BUDGET_SEC, #plan, stats.elapsed_ms))
        end
        -- 缓存部分计划: 翻回同一页直接复用, 不再重扫(避免再次超时/卡顿)
        self._plan_cache[cache_key] = { plan = plan, stats = stats, page = page }
        self.plan = plan
        self.plan_face = face
        self.plan_pinyin_h = pinyin_h
        self.plan_fgcolor = fgcolor
        self.last_plan_page = page
        self.last_stats = stats
        self.last_stats_page = page
        self.last_detail = {}
        self.last_box_words = {}
        -- 有部分拼音才请求重绘(空计划重绘纯浪费); 超时后尽量少打扰
        if #plan > 0 and self.ui and self.ui.dialog then
            UIManager:setDirty(self.ui.dialog, "ui")
        end
        return
    end

    -- 缓存本页绘制计划: 翻回同一页不再重扫。简单防膨胀: 超过 24 页缓存清空。
    self._plan_cache[cache_key] = { plan = plan, stats = stats, page = page }
    local n_cache = 0
    for _ in pairs(self._plan_cache) do
        n_cache = n_cache + 1
        if n_cache > 24 then
            self._plan_cache = {}
            break
        end
    end

    if self.debug then
        stats.elapsed_ms = math.floor((os.clock() - t_start) * 1000)
        logger.warn(string.format(
            "[Pinyin] page=%d level=%d thr=%d method=%s | boxes=%d words=%d chars=%d with_data=%d shown=%d filtered=%d no_data=%d iter=%d emitted=%d vocab=%d phrase=%d elapsed=%dms",
            page, self.level, threshold, method,
            stats.boxes, stats.words, stats.chars, stats.with_data,
            stats.shown, stats.filtered, stats.no_data, iter,
            stats.emitted, stats.vocab_matches, stats.phrase_hits, stats.elapsed_ms))
        for _, l in ipairs(detail) do
            logger.warn("[Pinyin]" .. l)
        end
    end

    -- 保存诊断信息, 供菜单"查看诊断信息"直接弹窗(无需翻 crash.log)
    self.last_stats = stats
    self.last_stats_page = page
    self.last_detail = detail
    self.last_box_words = box_words

    -- 保存绘制计划与样式, 由 view module 的 paintTo 在页面重绘后自动绘制。
    self.plan = plan
    self.plan_face = face
    self.plan_pinyin_h = pinyin_h
    self.plan_fgcolor = fgcolor
    self.last_plan_page = page

    -- 请求 ReaderView 重绘, 重绘时会调用本插件的 paintTo, 把拼音画在页面之上。
    if self.ui and self.ui.dialog then
        if self.debug then
            logger.warn(string.format("[Pinyin] setDirty requested for page=%d", page))
        end
        UIManager:setDirty(self.ui.dialog, "ui")
    end
end

-- ReaderView 的 view module 绘制回调: 在每次页面重绘后被调用。
function Pinyin:paintTo(bb, x, y)
    if not self.enabled then return end
    if not self.plan or #self.plan == 0 then return end
    if self.debug then
        logger.warn(string.format("[Pinyin] paintTo called, plan_page=%s plan_items=%d",
            tostring(self.last_plan_page), #self.plan))
    end
    local face = self.plan_face
    local pinyin_h = self.plan_pinyin_h
    local fgcolor = self.plan_fgcolor
    if not face then return end
    for _, item in ipairs(self.plan) do
        for _, c in ipairs(item.chars) do
            local iy
            if self.position == "above" then
                if item.y >= pinyin_h then
                    iy = item.y - pinyin_h
                else
                    iy = item.y + item.h -- 顶部空间不足则改放下方
                end
            else
                iy = item.y + item.h
            end
            if iy >= 0 then
                local tw = TextWidget:new{
                    text = c.py, face = face, bold = false, fgcolor = fgcolor,
                }
                local tw_w = tw:getWidth()
                local ix = math.floor(c.cx - tw_w / 2)
                tw:paintTo(bb, ix + x, iy + y)
                tw:free()
            end
        end
    end
end

-- 关闭时清除已绘制的拼音: 清空计划并请求整屏重绘
function Pinyin:clearPinyin()
    self.plan = {}
    if self.ui and self.ui.dialog then
        UIManager:setDirty(self.ui.dialog, "full")
    end
end

function Pinyin:addToMainMenu(menu_items)
    menu_items.pinyin = {
        text = _("生僻字注音"),
        -- 用 "tools" 排序提示, 把项放进主菜单的"工具"分组,
        -- 与"更多工具"分组是并列的同级分组(比嵌套在"更多工具"里更靠前、更显眼)。
        -- 注意: KOReader 插件项无法直接成为主菜单的一级按钮(需改 KOReader 核心),
        -- 放进某个一级分组是插件能稳定达到的最靠前位置。空 sorting_hint 会被当成
        -- "孤儿项"塞进分组数组、导致菜单项不显示甚至主菜单打不开(已踩坑验证)。
        sorting_hint = "tools",
        sub_item_table = self:genMenuItems(),
    }
end

function Pinyin:genMenuItems()
    local sub = {}

    table.insert(sub, {
        text_func = function()
            return self.enabled and _("关闭拼音标注") or _("开启拼音标注")
        end,
        checked = self.enabled,
        callback = function()
            self.enabled = not self.enabled
            G_reader_settings:saveSetting("pinyin_enabled", self.enabled)
            if self.enabled then
                if not (PinyinData and PinyinData.data and next(PinyinData.data)) then
                    UIManager:show(InfoMessage:new{
                        text = _("未找到拼音数据文件 pinyin_data.lua, 请先运行 generate_data.py 生成。"),
                    })
                    self.enabled = false
                    return
                end
                self:drawPinyin()
            else
                self:clearPinyin()
            end
        end,
    })

    table.insert(sub, {
        text_func = function()
            return T(_("标注等级: %1 (越高注音越多)"), self.level)
        end,
        help_text = _("标注等级 1-5(越高注音越多):\n1 级 = 最生僻字\n2 级 = 生僻字(默认)\n3 级 = 较生僻字\n4 级 = 生字较多\n5 级 = 生字注音(覆盖面最宽)"),
        keep_menu_open = true,
        callback = function(touchmenu)
            local SpinWidget = require("ui/widget/spinwidget")
            UIManager:show(SpinWidget:new{
                title_text = _("标注等级"),
                info_text = _("标注等级决定给多生僻的字注音 (rank 越小越常用):\n1 级:最生僻字 (rank>7000)\n2 级(默认):生僻字 (rank>6250)\n3 级:较生僻字 (rank>5500)\n4 级:生字较多 (rank>4750)\n5 级:生字注音 (rank>4000, 覆盖面最宽)"),
                value = self.level, value_min = 1, value_max = 5, value_step = 1,
                ok_text = _("设定"),
                callback = function(spin)
                    self.level = spin.value
                    G_reader_settings:saveSetting("pinyin_level", self.level)
                    if self.enabled then self:drawPinyin() end
                    if touchmenu then touchmenu:updateItems() end
                end,
            })
        end,
    })

    table.insert(sub, {
        text_func = function()
            return T(_("生词本注音: %1"), self.vocab_link and _("开") or _("关"))
        end,
        checked = self.vocab_link,
        help_text = _("查词加入生词本的词, 整词出现在页面上才注音(词级精确匹配):\n· \"感悟\"入本 → 只注整词出现的\"感悟\", \"感\"\"悟\"单独出现不注\n· 单字入本 → 该字每次出现都注(读音结合上下文词组辨音)\n· 需安装 KOReader 官方\"生词本\"(vocabbuilder)插件\n· 删改生词后自动同步(下次翻页生效)\n· 无生词的页面零开销\n· 多音字词组辨音始终开启, 不设开关(纯查表, 不影响翻页速度)"),
        callback = function()
            self.vocab_link = not self.vocab_link
            G_reader_settings:saveSetting("pinyin_vocab_link", self.vocab_link)
            self._vocab = nil  -- 重新加载词表
            self._plan_cache = {}
            if self.enabled then self:drawPinyin() end
        end,
    })

    table.insert(sub, {
        text_func = function()
            return T(_("拼音字号: %1"), self.font_size)
        end,
        keep_menu_open = true,
        callback = function(touchmenu)
            local SpinWidget = require("ui/widget/spinwidget")
            UIManager:show(SpinWidget:new{
                title_text = _("拼音字号"),
                info_text = _("拼音标注的字体大小(点)。"),
                value = self.font_size, value_min = 8, value_max = 28, value_step = 1,
                ok_text = _("设定"),
                callback = function(spin)
                    self.font_size = spin.value
                    G_reader_settings:saveSetting("pinyin_font_size", self.font_size)
                    if self.enabled then self:drawPinyin() end
                    if touchmenu then touchmenu:updateItems() end
                end,
            })
        end,
    })

    table.insert(sub, {
        text = _("颜色: 深灰"),
        checked = self.gray,
        callback = function()
            self.gray = not self.gray
            G_reader_settings:saveSetting("pinyin_gray", self.gray)
            if self.enabled then self:drawPinyin() end
        end,
    })

    if CFG_DEBUG_LOG then
    table.insert(sub, {
        text = _("调试日志 (写 KOReader 日志)"),
        checked = self.debug,
        callback = function()
            self.debug = not self.debug
            UIManager:show(InfoMessage:new{
                text = self.debug
                    and _("已开启调试日志。翻页/重绘后, 每个盒子的取字、拼音数据、等级过滤结果都会写入 KOReader 日志(crash.log)。")
                    or _("已关闭调试日志。"),
            })
        end,
    })
    end

    if CFG_SHOW_DIAG then
    table.insert(sub, {
        text = _("查看诊断信息"),
        keep_menu_open = true,
        callback = function()
            local s = self.last_stats
            if not s then
                UIManager:show(InfoMessage:new{
                    text = _("还没有诊断数据。请先开启拼音标注并翻几页, 再来查看。"),
                })
                return
            end
            local lines = {}
            table.insert(lines, string.format("本页统计 (level=%d):", self.level))
            table.insert(lines, string.format("统计数据页码 stats_page = %s", tostring(self.last_stats_page)))
            table.insert(lines, string.format("计划页码 plan_page     = %s", tostring(self.last_plan_page)))
            table.insert(lines, string.format("盒子数 boxes      = %d", s.boxes))
            table.insert(lines, string.format("取到字 words      = %d", s.words))
            table.insert(lines, string.format("取出字 chars      = %d", s.chars))
            table.insert(lines, string.format("有拼音数据        = %d", s.with_data))
            table.insert(lines, string.format("等级候选 shown    = %d", s.shown))
            table.insert(lines, string.format("实际绘制 emitted  = %d / 上限 %d", s.emitted or 0, MAX_ANNOT))
            table.insert(lines, string.format("生词命中 vocab    = %d", s.vocab_matches or 0))
            table.insert(lines, string.format("辨音命中 phrase   = %d", s.phrase_hits or 0))
            table.insert(lines, string.format("本页耗时 elapsed  = %dms", s.elapsed_ms or 0))
            table.insert(lines, string.format("被等级过滤 filtered= %d", s.filtered))
            table.insert(lines, string.format("无拼音数据        = %d", s.no_data))
            table.insert(lines, "")
            table.insert(lines, "判读:")
            if s.capped then
                table.insert(lines, "· 本页注音已达上限, 其余字未注(保险丝保护)")
            end
            if s.aborted then
                table.insert(lines, "· 本页扫描超时: 已显示找到的部分注音, 未注的字已缓存不再重扫")
            elseif s.words == 0 then
                table.insert(lines, "· 本页无目标字, 页面无拼音属正常")
            else
                table.insert(lines, "· emitted 远小于 shown → 达上限或盒子取不到")
                table.insert(lines, "· vocab>0 而 emitted=0 → 生词跨行断开, 词级匹配未命中")
            end
            if self.last_box_words and #self.last_box_words > 0 then
                table.insert(lines, "")
                table.insert(lines, string.format("本页盒子内容(%d 个):", #self.last_box_words))
                for _, bw in ipairs(self.last_box_words) do
                    table.insert(lines, "  " .. bw)
                end
            end
            if self.debug and self.last_detail and #self.last_detail > 0 then
                table.insert(lines, "")
                table.insert(lines, string.format("明细(前 %d 条):", #self.last_detail))
                for _, l in ipairs(self.last_detail) do
                    table.insert(lines, l)
                end
            end
            UIManager:show(TextViewer:new{
                title = _("生僻字注音诊断"),
                text = table.concat(lines, "\n"),
                width = math.floor(Screen:getWidth() * 0.9),
                height = math.floor(Screen:getHeight() * 0.9),
            })
        end,
    })
    end

    table.insert(sub, {
        text = _("关于 / 帮助"),
        keep_menu_open = true,
        callback = function()
            local about = string.format(
                "生僻字注音 v%s\n\n" ..
                "在中文页面每个汉字上方叠加拼音，模仿Kindle原生\"生字注音\"功能。\n" ..
                "·标注等级：控制生僻字注音范围（1最严，5覆盖面最宽）。\n" ..
                "·新增生词本联动（给生词本中的单字和整词添加注音）。\n" ..
                "·新增多音字词组辨音：结合上下文判断读音。\n" ..
                "·已测试: EPUB / DOCX / HTML(建议用 EPUB); 其它格式未测试, 可能显示不出拼音。\n" ..
                "· PDF / DjVu 因引擎限制暂不支持。",
                VERSION)
            UIManager:show(InfoMessage:new{ text = about })
        end,
    })

    return sub
end

return Pinyin
