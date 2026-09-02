local Version = require("version")
local T = require("ffi/util").template
local logger = require("logger")

local runtime_source = debug.getinfo(1, "S").source:gsub("^@", "")
local runtime_root = runtime_source:match("^(.*)/lib/runtime%.lua$")
local Compatibility = dofile(runtime_root .. "/lib/koreader_compat.lua")
local InputSchemes = dofile(runtime_root .. "/lib/input_schemes.lua")
local PluginVersion = dofile(runtime_root .. "/lib/plugin_version.lua")

local Runtime = {
    state = "idle",
    installed = false,
    supported = false,
    data_loaded = false,
    adapter_name = nil,
    compatibility_admission = nil,
    compatibility_status = nil,
    error_message = nil,
    active_lexicon_mode = nil,
    lexicon_fallback_reason = nil,
    profiling_enabled = os.getenv("CHINESE_PINYIN_PROFILE") == "1",
    profiling_stats = {},
    Compatibility = Compatibility,
    InputSchemes = InputSchemes,
    plugin_version = PluginVersion,
}

function Runtime:setProfilingEnabled(enabled, reset)
    self.profiling_enabled = enabled == true
    if reset ~= false then
        self.profiling_stats = {}
    end
    return self.profiling_enabled
end

function Runtime:_recordProfiling(name, elapsed)
    if not self.profiling_enabled or type(elapsed) ~= "number" then
        return
    end
    local item = self.profiling_stats[name]
    if not item then
        item = { count = 0, total = 0, maximum = 0 }
        self.profiling_stats[name] = item
    end
    item.count = item.count + 1
    item.total = item.total + elapsed
    item.maximum = math.max(item.maximum, elapsed)
end

function Runtime:_profilingCallback()
    if not self.profiling_enabled then
        return nil
    end
    return function(name, elapsed)
        self:_recordProfiling(name, elapsed)
    end
end

function Runtime:getProfilingStats(reset)
    local result = {}
    for name, item in pairs(self.profiling_stats or {}) do
        result[name] = {
            count = item.count,
            total_ms = item.total * 1000,
            maximum_ms = item.maximum * 1000,
            mean_ms = item.count > 0 and item.total * 1000 / item.count or 0,
        }
    end
    if reset then
        self.profiling_stats = {}
    end
    return result
end

local MAX_PREDICTION_CONTEXT_KEYS = 5
local MAX_PERSONAL_PREDICTION_POOL = 3
local MAX_STATIC_PREDICTION_POOL = 5
local MAX_PERSONAL_ONLY_RESULTS = 2
local SAFE_BACKOFF_FLAG = 32
local MAX_CATEGORY_STATE_RULES = 12
local MAX_CATEGORY_OPEN_FRAME_RULES = 2
local MAX_CATEGORY_TECHNICAL_CLASSES = 4
local MAX_CATEGORY_KEYWORDS_PER_CLASS = 12

-- A deliberately small last-resort model for contexts that have neither a
-- learned association nor a static exact/safe relation.  These rules cover
-- productive Chinese status endings and broad technical noun classes without
-- adding another database query, cache, or model file.  They run on the
-- already-bounded (at most twelve Han characters) committed context.
local CATEGORY_FALLBACK_BLOCKERS = {
    "为什么", "怎么样", "怎么办", "有没有", "是不是", "能不能",
    "要不要", "如何", "怎么", "何时", "多少", "请问",
    "什么", "谁", "哪个", "哪", "哪里", "哪儿", "谁的",
    "尚未", "还没", "并未", "并非", "是否", "能否", "可否",
    "没有", "不能", "无法", "不再", "未能",
    "未", "没", "不", "否", "非",
}

local CATEGORY_FALLBACK_QUESTION_ENDINGS = { "吗", "呢", "么", "嘛" }

local CATEGORY_FALLBACK_CHAT_ENDINGS = {
    "生日快乐", "周末愉快", "一路平安", "好久不见",
    "辛苦了", "谢谢你", "晚安", "再见", "你好", "收到",
    "好的", "在吗", "有空吗", "最近怎么样",
}

local CATEGORY_STATE_RULES = {
    { "不一致", { "需要重新校验", "会导致验证失败", "需要检查数据来源", "可以重新同步" } },
    { "没有响应", { "可以稍后重试", "需要检查连接状态", "可以切换处理方式", "应保留当前进度" } },
    { "尚未返回", { "可以继续等待", "需要检查当前状态", "可以稍后重新查询", "不应重复提交" } },
    { "未通过", { "需要重新检查", "可以再次验证", "需要查看失败原因", "不应继续后续操作" } },
    { "重试上限", { "需要停止重试", "应保留错误信息", "需要检查失败原因", "可以稍后重新开始" } },
    { "失败", { "可以重新尝试", "需要检查原因", "应保留错误信息", "可以恢复之前状态" } },
    { "完成", { "可以继续下一步", "需要再检查一遍", "记得保存结果", "可以通知相关人员" } },
    { "超时", { "可以重新尝试", "需要检查连接状态", "会导致当前操作失败", "应保留当前状态" } },
    { "过期", { "需要及时更新", "将无法继续使用", "需要重新验证", "需要重新申请" } },
    { "异常", { "需要保留日志", "可以尝试恢复", "会影响当前操作", "需要进一步检查" } },
    { "不足", { "需要降低资源占用", "会影响运行稳定性", "可以减少后台任务", "需要进一步优化" } },
    { "无效", { "需要重新配置", "会阻止后续操作", "需要检查有效期", "可以重新获取" } },
}

-- The bare endings below are commonly complete utterances and should stay
-- quiet. With a non-empty left frame, however, they are productive clause
-- openings; treating both forms as blocked loses useful continuations.
local CATEGORY_OPEN_FRAME_RULES = {
    { "没有必要", { "继续这样做", "再等下去", "担心这个问题", "重复处理" } },
    { "是否可以", { "继续操作", "开始处理", "按计划执行", "稍后再试" } },
}

local CATEGORY_TECHNICAL_RULES = {
    {
        { "响应时间", "处理速度", "输入延迟", "候选延迟", "吞吐量",
          "命中率", "准确率", "内存占用", "磁盘占用", "峰值内存",
          "功耗", "性能" },
        { "需要持续测量", "可以进一步优化", "会影响整体性能", "应该保持稳定" },
    },
    {
        { "内存", "缓存", "存储", "数据库", "索引", "文件系统",
          "词库", "日志", "磁盘" },
        { "需要控制资源占用", "可以按需加载", "应该设置容量上限", "会影响运行稳定性" },
    },
    {
        { "访问权限", "数字证书", "传输协议", "接口配置", "网络连接",
          "数据校验", "数据同步", "数据备份", "数据恢复", "版本升级",
          "安装程序", "系统组件" },
        { "需要进一步确认", "应该定期检查", "可以按需更新", "会影响后续操作" },
    },
    {
        { "并发控制", "模型推理", "编码", "解码", "渲染", "向量检索",
          "语义检索", "模型量化", "模型蒸馏", "模型剪枝", "事件循环",
          "一致性哈希" },
        { "需要进一步评估", "可以按需调整", "会影响整体性能", "应该结合实际场景选择" },
    },
}

assert(#CATEGORY_STATE_RULES <= MAX_CATEGORY_STATE_RULES)
assert(#CATEGORY_OPEN_FRAME_RULES <= MAX_CATEGORY_OPEN_FRAME_RULES)
assert(#CATEGORY_TECHNICAL_RULES <= MAX_CATEGORY_TECHNICAL_CLASSES)
for _, rule in ipairs(CATEGORY_TECHNICAL_RULES) do
    assert(#rule[1] <= MAX_CATEGORY_KEYWORDS_PER_CLASS)
end

local function oneLine(value)
    local message = tostring(value or "unknown lexicon error")
    return message:match("^[^\r\n]+") or message
end

local function boundedPredictionContexts(context_keys)
    if type(context_keys) ~= "table" then
        return {}
    end
    local contexts, seen = {}, {}
    for index, context in ipairs(context_keys) do
        local text = type(context) == "table" and context.text or context
        local kind = type(context) == "table" and context.kind
            or (index == 1 and "exact" or "suffix")
        if kind ~= "exact" and kind ~= "trusted_token" and kind ~= "suffix" then
            kind = index == 1 and "exact" or "suffix"
        end
        if #contexts >= MAX_PREDICTION_CONTEXT_KEYS then
            break
        elseif type(text) == "string" and text ~= "" and not seen[text] then
            seen[text] = true
            contexts[#contexts + 1] = { text = text, kind = kind }
        end
    end
    return contexts
end

local function predictionContextTexts(contexts)
    local texts = {}
    for index, context in ipairs(contexts) do
        texts[index] = context.text
    end
    return texts
end

local function endsWith(value, suffix)
    return #value >= #suffix and value:sub(-#suffix) == suffix
end

local function containsAny(value, patterns)
    for _, pattern in ipairs(patterns) do
        if value:find(pattern, 1, true) then
            return true
        end
    end
    return false
end

local function copyCategoryCandidates(candidates, limit)
    local result = {}
    for index = 1, math.min(#candidates, limit) do
        result[index] = candidates[index]
    end
    return result
end

local function matchesTechnicalContext(context, keywords)
    for _, keyword in ipairs(keywords) do
        if endsWith(context, keyword) then
            return true
        end
    end
    return false
end

local function categoryFallback(context, limit)
    if type(context) ~= "string" or context == "" then
        return {}
    end
    for _, ending in ipairs(CATEGORY_FALLBACK_CHAT_ENDINGS) do
        if endsWith(context, ending) then
            return {}
        end
    end
    for _, ending in ipairs(CATEGORY_FALLBACK_QUESTION_ENDINGS) do
        if endsWith(context, ending) then
            return {}
        end
    end

    for _, rule in ipairs(CATEGORY_OPEN_FRAME_RULES) do
        local suffix, candidates = rule[1], rule[2]
        if context ~= suffix and endsWith(context, suffix) then
            local prefix = context:sub(1, #context - #suffix)
            if containsAny(prefix, CATEGORY_FALLBACK_BLOCKERS) then
                return {}
            end
            return copyCategoryCandidates(candidates, limit)
        end
    end

    -- Status rules are productive only when their left frame is affirmative.
    -- Inspecting the whole bounded prefix catches non-adjacent forms such as
    -- “没有发生连接失败”, which the database suffix guard intentionally does
    -- not try to model.
    for _, rule in ipairs(CATEGORY_STATE_RULES) do
        local suffix, candidates = rule[1], rule[2]
        if endsWith(context, suffix) then
            local prefix = context:sub(1, #context - #suffix)
            if containsAny(prefix, CATEGORY_FALLBACK_BLOCKERS) then
                return {}
            end
            return copyCategoryCandidates(candidates, limit)
        end
    end


    -- Technical class fallback is deliberately conservative: any negative or
    -- interrogative frame abstains, and keywords are multi-character domain
    -- terms rather than single ambiguous Han characters.
    if containsAny(context, CATEGORY_FALLBACK_BLOCKERS) then
        return {}
    end
    for _, rule in ipairs(CATEGORY_TECHNICAL_RULES) do
        local keywords, candidates = rule[1], rule[2]
        if matchesTechnicalContext(context, keywords) then
            return copyCategoryCandidates(candidates, limit)
        end
    end
    return {}
end

function Runtime:_getCategoryFallbackStats()
    local keyword_counts = {}
    for index, rule in ipairs(CATEGORY_TECHNICAL_RULES) do
        keyword_counts[index] = #rule[1]
    end
    return {
        state_rules = #CATEGORY_STATE_RULES,
        open_frame_rules = #CATEGORY_OPEN_FRAME_RULES,
        technical_classes = #CATEGORY_TECHNICAL_RULES,
        technical_keyword_counts = keyword_counts,
    }
end

local function predictionContextIndex(contexts, context)
    if type(context) ~= "string" then
        return nil
    end
    for index, candidate in ipairs(contexts) do
        if candidate.text == context then
            return index
        end
    end
    return nil
end

local function positiveInteger(value, fallback)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge
            or value < 1 then
        return fallback
    end
    return math.floor(value)
end

local function normalizePredictionRows(candidates, maximum)
    local rows, seen = {}, {}
    if type(candidates) ~= "table" then
        return rows
    end
    for index, candidate in ipairs(candidates) do
        local text = type(candidate) == "table"
            and (candidate.text or candidate.candidate or candidate.next_text)
            or candidate
        if type(text) == "string" and text ~= "" and not seen[text] then
            seen[text] = true
            local source = type(candidate) == "table" and candidate or {}
            rows[#rows + 1] = {
                text = text,
                rank = positiveInteger(source.rank, index),
                count = positiveInteger(source.count, nil),
                effective_count = positiveInteger(source.effective_count, nil),
                last_used = positiveInteger(source.last_used, 0),
                quality = tonumber(source.quality) or 0,
                source_mask = positiveInteger(source.source_mask, 0),
                flags = positiveInteger(source.flags, 0),
            }
            if #rows >= maximum then
                break
            end
        end
    end
    return rows
end

local function firstPredictionGroup(groups)
    -- Groups are keyed by caller context index and may therefore be sparse.
    for index = 1, MAX_PREDICTION_CONTEXT_KEYS do
        if groups[index] and #groups[index] > 0 then
            return index, groups[index]
        end
    end
    return nil, {}
end

local function hasFlag(value, flag)
    return math.floor((tonumber(value) or 0) / flag) % 2 == 1
end

local function mergePredictionRows(personal, static, limit)
    local merged = {}
    for index, row in ipairs(static) do
        local item = merged[row.text]
        if not item then
            item = { text = row.text }
            merged[row.text] = item
        end
        item.static = true
        item.static_rank = math.min(item.static_rank or math.huge, row.rank or index)
        item.static_flags = row.flags or 0
        local static_score = 10000 - (item.static_rank - 1) * 1200
        if hasFlag(item.static_flags, SAFE_BACKOFF_FLAG) then
            static_score = static_score - 300
        end
        item.static_score = math.max(item.static_score or -math.huge, static_score)
    end
    for index, row in ipairs(personal) do
        local item = merged[row.text]
        if not item then
            item = { text = row.text }
            merged[row.text] = item
        end
        item.personal = true
        item.personal_rank = math.min(item.personal_rank or math.huge, row.rank or index)
        item.personal_count = math.max(
            item.personal_count or 0,
            row.effective_count or row.count or 2)
        -- A twice-seen candidate remains weaker than the top static item;
        -- repeated/recent observations can promote it without floating point
        -- language-model work on the commit path.
        item.personal_score = math.max(
            item.personal_score or -math.huge,
            7600 + math.min(item.personal_count, 10) * 600
                - (item.personal_rank - 1) * 10)
    end

    local ranked = {}
    for _, item in pairs(merged) do
        if item.static and item.personal then
            item.score = math.max(item.static_score, item.personal_score) + 2400
            item.shared = true
        else
            item.score = item.static_score or item.personal_score
            item.shared = false
        end
        ranked[#ranked + 1] = item
    end
    table.sort(ranked, function(left, right)
        if left.score ~= right.score then
            return left.score > right.score
        elseif left.shared ~= right.shared then
            return left.shared
        elseif (left.static_rank or math.huge) ~= (right.static_rank or math.huge) then
            return (left.static_rank or math.huge) < (right.static_rank or math.huge)
        elseif (left.personal_rank or math.huge) ~= (right.personal_rank or math.huge) then
            return (left.personal_rank or math.huge) < (right.personal_rank or math.huge)
        end
        return left.text < right.text
    end)

    local result, personal_only_count = {}, 0
    for _, item in ipairs(ranked) do
        local personal_only = item.personal and not item.static
        if not personal_only or personal_only_count < MAX_PERSONAL_ONLY_RESULTS then
            result[#result + 1] = item.text
            if personal_only then
                personal_only_count = personal_only_count + 1
            end
            if #result >= limit then
                break
            end
        end
    end
    return result
end

local function probeFailureMessage(reason)
    reason = oneLine(reason or "unknown capability failure")
    local missing = reason:match("^capability_missing:%s*(.*)$")
    if missing then
        return "KOReader 能力缺失：" .. missing
    end
    local conflict = reason:match("^hook_conflict:%s*(.*)$")
    if conflict then
        return "检测到 hook 冲突：" .. conflict
    end
    return "KOReader 能力检测失败：" .. reason
end

function Runtime:_rollbackInstall()
    if self.adapter and self.adapter.uninstall then
        pcall(self.adapter.uninstall, self, "raw")
    end
    self:flush()
    self:_releaseData()
    self.supported = false
    self.installed = false
    self.state = "idle"
    self.engines = nil
    self.settings = nil
    self.Settings = nil
    self.ShuangpinDecoder = nil
    self.adapter = nil
    self.adapter_name = nil
    self.compatibility = nil
    self.compatibility_admission = nil
    self.compatibility_status = nil
    self.compatibility_probe_passed = nil
    self.release_tag = nil
end

function Runtime:_failInstall(message)
    self.error_message = oneLine(message)
    self._install_failure_notice_pending = not self._install_failure_notified
    self:_rollbackInstall()
    return false
end

function Runtime:consumeInstallFailureNotice()
    if not self._install_failure_notice_pending or self._install_failure_notified
            or not self.error_message then
        return nil
    end
    self._install_failure_notice_pending = false
    self._install_failure_notified = true
    return self.error_message
end

function Runtime:install(root)
    if self.state == "active" then
        return self.supported
    elseif self.state == "installing" or self.state == "failed_session" then
        return false
    end
    self.state = "installing"
    self.installed = false
    self.supported = false
    self.error_message = nil
    self._install_failure_notice_pending = false
    self.adapter_name = nil
    self.compatibility = nil
    self.compatibility_admission = nil
    self.compatibility_status = nil
    self.compatibility_probe_passed = nil
    self.release_tag = nil
    self.root = root
    local revision_ok, revision = pcall(Version.getCurrentRevision, Version)
    self.revision = revision_ok and revision or nil

    local resolve_ok, compatibility, admission_reason = pcall(
        Compatibility.resolve, self.revision)
    if not resolve_ok then
        return self:_failInstall("KOReader 版本准入异常：" .. tostring(compatibility))
    elseif not compatibility then
        return self:_failInstall("KOReader 版本准入失败：" .. tostring(admission_reason))
    end
    self.compatibility = compatibility
    self.adapter_name = self.compatibility.adapter_name
    self.release_tag = self.compatibility.release_tag
    self.compatibility_admission = self.compatibility.admission

    local loaded, load_err = pcall(function()
        self.adapter = dofile(root .. "/lib/"
            .. self.compatibility.adapter .. "_adapter.lua")
    end)
    if not loaded then
        return self:_failInstall(
            "KOReader 能力检测失败：无法加载适配器：" .. tostring(load_err))
    elseif type(self.adapter.probe) ~= "function" then
        return self:_failInstall("KOReader 能力缺失：release_adapter.probe")
    end

    local probe_ok, compatible, probe_reason = pcall(self.adapter.probe, self)
    if not probe_ok then
        return self:_failInstall("KOReader 能力检测异常：" .. tostring(compatible))
    elseif compatible ~= true then
        return self:_failInstall(probeFailureMessage(probe_reason))
    end
    self.compatibility_probe_passed = true

    local initialized, initialization_err = pcall(function()
        self.ShuangpinDecoder = dofile(root .. "/lib/shuangpin_decoder.lua")
        self.Settings = dofile(root .. "/lib/settings.lua")
        self.settings = self.Settings:new()
        self.engines = setmetatable({}, { __mode = "k" })
    end)
    if not initialized then
        return self:_failInstall(
            "拼音插件初始化异常：" .. tostring(initialization_err))
    end

    local ok, result = pcall(self.adapter.install, self)
    if not ok or result == false then
        return self:_failInstall("拼音插件安装异常：" .. tostring(result))
    end
    self.compatibility_probe_passed = nil
    self.compatibility_status = self.compatibility_admission == "runtime_probe"
        and "runtime_verified" or self.compatibility_admission
    self.supported = true
    self.installed = true
    self.state = "active"
    return true
end

function Runtime:_loadCompatibilityLexiconData()
    local phrase_overlay = dofile(self.root .. "/data/phrase_overlay.lua")
    self.overlay_exact = phrase_overlay.exact or {}
    self.overlay_abbr = phrase_overlay.abbr or {}
    self.overlay_metadata = phrase_overlay.metadata or {}
    -- phrase_overlay.abbr is already the deterministic merge of the base and
    -- compatibility overlay abbreviation maps.
    self.abbreviation_map = self.overlay_abbr
end

function Runtime:_loadFullLexiconData()
    local abbreviation_data = dofile(self.root .. "/data/pinyin_abbr_data.lua")
    self.overlay_exact = {}
    self.overlay_abbr = {}
    self.overlay_metadata = nil
    self.abbreviation_map = abbreviation_data.abbr or abbreviation_data
end

function Runtime:_closeLexiconProvider()
    local provider = self.lexicon_provider
    self.lexicon_provider = nil
    if provider and provider.close then
        pcall(provider.close, provider)
    end
end

function Runtime:_updateEngineLexicon(engine, provider)
    engine.abbreviation_map = self.abbreviation_map
    engine.overlay_exact = self.overlay_exact
    engine.overlay_abbr = self.overlay_abbr
    engine.abbreviation_overlay_merged = true
    engine.lexicon_provider = provider
    engine.static_candidate_cache_enabled = provider
        and type(provider.getCapabilities) == "function" or false
    engine.short_lexicon_cache = {}
    engine.short_lexicon_cache_order = {}
    if engine.invalidateCandidateCaches then
        engine:invalidateCandidateCaches()
    end
    if engine.sentence_decoder then
        engine.sentence_decoder:setProvider(provider)
    end
end

function Runtime:_fallbackLexicon(reason)
    if self.active_lexicon_mode ~= "full" then
        return false
    end
    self.lexicon_fallback_reason = oneLine(reason)
    logger.warn("Wanxiang lexicon unavailable; using compatibility lexicon:",
        self.lexicon_fallback_reason)
    self:_closeLexiconProvider()
    local ok, err = pcall(self._loadCompatibilityLexiconData, self)
    if not ok then
        self:disableForSession("compatibility lexicon loading failed: " .. tostring(err))
        return false
    end
    self.active_lexicon_mode = "compatibility"
    for engine in pairs(self.engines or {}) do
        -- This callback may run inside the sentence decoder. Avoid recursively
        -- refreshing candidates; the active refresh will finish with the
        -- compatibility maps and subsequent keys use the legacy path.
        self:_updateEngineLexicon(engine, nil)
    end
    return true
end

function Runtime:_initializeLexicon()
    self.active_lexicon_mode = nil
    self.lexicon_fallback_reason = nil
    if self.settings:getLexiconMode() == "compatibility" then
        self:_loadCompatibilityLexiconData()
        self.active_lexicon_mode = "compatibility"
        return
    end

    self:_loadFullLexiconData()
    local WanxiangLexicon = dofile(self.root .. "/lib/wanxiang_lexicon.lua")
    self._lexicon_initializing = true
    local provider = WanxiangLexicon:new{
        path = self.root .. "/data/wanxiang.sqlite3",
        on_error = function(reason)
            self.lexicon_fallback_reason = oneLine(reason)
            if not self._lexicon_initializing then
                self:_fallbackLexicon(reason)
            end
        end,
    }
    local available = provider:isAvailable()
    self._lexicon_initializing = nil
    if available then
        self.lexicon_provider = provider
        self.active_lexicon_mode = "full"
        return
    end

    local stats = provider:getStats()
    provider:close()
    self.lexicon_fallback_reason = oneLine(
        self.lexicon_fallback_reason or stats.error or "Wanxiang database unavailable")
    self:_loadCompatibilityLexiconData()
    self.active_lexicon_mode = "compatibility"
    logger.warn("Wanxiang lexicon initialization failed; using compatibility lexicon:",
        self.lexicon_fallback_reason)
end

function Runtime:_warmFullLexiconPath()
    if not self.lexicon_provider then
        return
    end
    -- Exercise one representative sentence while the keyboard is being
    -- created. This pays the decoder/SQLite one-time setup cost in the existing
    -- lazy data-load phase instead of delaying the first visible keystroke.
    local warm = self.PinyinIME:new{
        code_map = self.code_map,
        abbreviation_map = self.abbreviation_map,
        overlay_exact = self.overlay_exact,
        overlay_abbr = self.overlay_abbr,
        abbreviation_overlay_merged = true,
        correction_full = self.correction_full,
        sorted_codes = self.sorted_codes,
        syllable_set = self.syllable_set,
        lexicon_provider = self.lexicon_provider,
    }
    warm:processText("woshizhongguoren")
    warm:cancel()
end

function Runtime:_lookupPredictions(context_keys, limit)
    local settings = self.settings
    if settings and settings.isPredictionEnabled
            and not settings:isPredictionEnabled() then
        return {}
    end
    limit = math.max(1, math.min(math.floor(tonumber(limit) or 5), 5))
    local contexts = boundedPredictionContexts(context_keys)
    if #contexts == 0 then
        return {}
    end
    local context_texts = predictionContextTexts(contexts)

    local personal_groups = {}
    local structured_personal = false
    local personalization_enabled = not settings
        or not settings.isPersonalizationEnabled
        or settings:isPersonalizationEnabled()
    if personalization_enabled and settings
            and settings.getAssociationCandidatesByContext then
        local ok, groups = pcall(
            settings.getAssociationCandidatesByContext,
            settings, context_texts, MAX_PERSONAL_PREDICTION_POOL)
        if ok and type(groups) == "table" then
            structured_personal = true
            for _, group in ipairs(groups) do
                local context_index = type(group) == "table"
                    and positiveInteger(group.context_index, nil) or nil
                if not context_index and type(group) == "table" then
                    context_index = predictionContextIndex(contexts, group.context)
                end
                if context_index and context_index <= #contexts
                        and type(group.candidates) == "table" then
                    local rows = normalizePredictionRows(
                        group.candidates, MAX_PERSONAL_PREDICTION_POOL)
                    if #rows > 0 and not personal_groups[context_index] then
                        personal_groups[context_index] = rows
                    end
                elseif type(group) ~= "table" then
                    structured_personal = false
                    break
                end
            end
        end
    end

    -- Keep the original string-only settings contract working. Single-context
    -- calls retain specificity information which its waterfall result omitted.
    if personalization_enabled and not structured_personal
            and settings and settings.getAssociationCandidates then
        for context_index, context in ipairs(context_texts) do
            local ok, candidates = pcall(
                settings.getAssociationCandidates, settings,
                { context }, MAX_PERSONAL_PREDICTION_POOL)
            local rows = ok and normalizePredictionRows(
                candidates, MAX_PERSONAL_PREDICTION_POOL) or {}
            if #rows > 0 then
                personal_groups[context_index] = rows
                break
            end
        end
    end

    local static_groups = {}
    local provider = self.lexicon_provider
    local detailed_static = false
    if provider and provider.predictDetailed then
        local provider_contexts = context_texts
        local supports_typed = provider.supportsTypedPredictionContexts
        if type(supports_typed) == "function" then
            local ok, supported = pcall(supports_typed, provider)
            supports_typed = ok and supported == true
        end
        if supports_typed == true then
            provider_contexts = contexts
        end
        local ok, payload = pcall(
            provider.predictDetailed, provider, provider_contexts,
            MAX_STATIC_PREDICTION_POOL)
        if ok and type(payload) == "table"
                and type(payload.candidates) == "table" then
            local rows = normalizePredictionRows(
                payload.candidates, MAX_STATIC_PREDICTION_POOL)
            if #rows == 0 then
                -- An empty structured result is valid (including a v1
                -- database); do not retry the same work through predict().
                detailed_static = true
            else
                local context_index = predictionContextIndex(
                    contexts, payload.matched_context)
                if context_index then
                    static_groups[context_index] = rows
                    detailed_static = true
                end
            end
        end
    end

    -- Older providers return strings only. Probe each bounded key separately
    -- to preserve the same full-context-before-suffix contract.
    if not detailed_static and provider and provider.predict then
        for context_index, context in ipairs(context_texts) do
            local ok, candidates = pcall(
                provider.predict, provider, { context }, MAX_STATIC_PREDICTION_POOL)
            local rows = ok and normalizePredictionRows(
                candidates, MAX_STATIC_PREDICTION_POOL) or {}
            if #rows > 0 then
                static_groups[context_index] = rows
                break
            end
        end
    end

    local personal_index, personal = firstPredictionGroup(personal_groups)
    local static_index, static = firstPredictionGroup(static_groups)
    local selected_index = personal_index
    if static_index and (not selected_index or static_index < selected_index) then
        selected_index = static_index
    end
    if not selected_index then
        return categoryFallback(context_texts[1], limit)
    end
    if personal_index ~= selected_index then
        personal = {}
    end
    if static_index ~= selected_index then
        static = {}
    end
    return mergePredictionRows(personal, static, limit)
end

function Runtime:ensureDataLoaded()
    if self.data_loaded then
        return true
    elseif self.state ~= "active" then
        return false, self.error_message or "input method is not active"
    end

    local started = os.clock()
    local memory_before = collectgarbage("count")
    local ok, err = pcall(function()
        if not self.PinyinIME then
            self.PinyinIME = dofile(self.root .. "/lib/pinyinime.lua")
        end
        self.code_map = dofile(self.root .. "/data/pinyin_data.lua")
        self:_initializeLexicon()
        local corrections = dofile(self.root .. "/data/pinyin_corrections.lua")
        self.correction_full = corrections.full or {}
        self.correction_metadata = corrections.metadata or {}
        local resources = self:_prepareInputSchemeResources(self.settings:getInputScheme())
        self:_activateInputSchemeResources(resources)
        if not self.CandidateBar then
            self.CandidateBar = dofile(self.root .. "/widgets/candidatebar.lua")
        end
        if not self.CandidatePanel then
            self.CandidatePanel = dofile(self.root .. "/widgets/candidatepanel.lua")
        end
        self.sorted_codes = {}
        for code in pairs(self.code_map) do
            self.sorted_codes[#self.sorted_codes + 1] = code
        end
        table.sort(self.sorted_codes)
        self.syllable_set = self.PinyinIME.makeSyllableSet()
        self:_warmFullLexiconPath()
    end)
    if not ok then
        self.error_message = "Chinese pinyin data loading failed: " .. tostring(err)
        self:disableForSession(self.error_message)
        return false, err
    end
    self.data_loaded = true
    logger.info(string.format(
        "Chinese pinyin data loaded in %.3fs (Lua heap +%.1f KiB)",
        os.clock() - started, collectgarbage("count") - memory_before))
    return true
end

-- Deferred data hook (custom lazy-load patch): invoked by the engine on its
-- first composition keystroke. Loads the heavy data files and retro-fills an
-- engine that was created before the data became available.
function Runtime:_loadDeferredEngineData(engine)
    local ok, err = self:ensureDataLoaded()
    if not ok then
        return false, err
    end
    self:_populateEngineData(engine)
    return true
end

-- Copy the freshly loaded data maps into a deferred engine; the existing
-- _updateEngineLexicon refresh invalidates its candidate caches.
function Runtime:_populateEngineData(engine)
    engine.code_map = self.code_map
    engine.sorted_codes = self.sorted_codes
    engine.correction_full = self.correction_full
    engine.correction_shuangpin = self.correction_shuangpin
    engine.shuangpin_decoder = self.shuangpin_decoder
    if self.syllable_set then
        engine.syllables = self.syllable_set
        local max_len = 0
        for syllable in pairs(self.syllable_set) do
            if #syllable > max_len then
                max_len = #syllable
            end
        end
        engine.max_syllable_length = max_len
    end
    self:_updateEngineLexicon(engine, self.lexicon_provider)
end

function Runtime:newInputMethod()
    if not self.PinyinIME then
        -- Light module load: engine constructor, key wrappers and candidate
        -- bar widgets only. The lexicon/code-map data files stay on disk
        -- until the first composition keystroke (_loadDeferredEngineData).
        self.PinyinIME = dofile(self.root .. "/lib/pinyinime.lua")
        self.CandidateBar = dofile(self.root .. "/widgets/candidatebar.lua")
        self.CandidatePanel = dofile(self.root .. "/widgets/candidatepanel.lua")
    end
    -- Custom lazy-load patch: create the engine without the heavy data when
    -- the setting is on. The engine runs on empty maps (idle state, empty
    -- candidates) until processText pulls the data in via ensure_data.
    local deferred = self.settings and self.settings.isDeferredDataLoadEnabled
        and self.settings:isDeferredDataLoadEnabled()
        and not self.data_loaded
    if not deferred then
        local loaded = self:ensureDataLoaded()
        if not loaded then
            return nil
        end
    end
    local engine = self.PinyinIME:new{
        code_map = self.code_map,
        abbreviation_map = self.abbreviation_map,
        overlay_exact = self.overlay_exact,
        overlay_abbr = self.overlay_abbr,
        abbreviation_overlay_merged = true,
        user_frequency = self.settings.user_frequency,
        personalization_enabled = self.settings:isPersonalizationEnabled(),
        prediction_enabled = self.settings:isPredictionEnabled(),
        get_learning_sequence = function()
            return self.settings:getLearningSequence()
        end,
        correction_full = self.correction_full,
        correction_shuangpin = self.correction_shuangpin,
        shuangpin_decoder = self.shuangpin_decoder,
        shuangpin_data_file = self.shuangpin_resources
            and self.shuangpin_resources.data_file or nil,
        sorted_codes = self.sorted_codes,
        syllable_set = self.syllable_set,
        input_scheme = self.settings:getInputScheme(),
        on_timing = self:_profilingCallback(),
        on_prepare_scheme = function(scheme)
            return self:_prepareInputSchemeResources(scheme)
        end,
        on_commit = function(code, candidate)
            if self.settings:isPersonalizationEnabled() then
                self.settings:learn(code, candidate)
            end
        end,
        prediction_lookup = function(context_keys, limit)
            return self:_lookupPredictions(context_keys, limit)
        end,
        on_association_commit = function(previous_text, current_text)
            if self.settings:isPersonalizationEnabled()
                    and self.settings:isPredictionEnabled() then
                self.settings:learnAssociation(previous_text, current_text)
            end
        end,
        on_toggle_scheme = function()
            return self:toggleInputScheme(true)
        end,
        on_scheme_changed = function(changed_engine)
            local inputbox = changed_engine.inputbox
            local keyboard = inputbox and inputbox.keyboard
            if keyboard and keyboard._updateInputMethodSchemeKey then
                keyboard:_updateInputMethodSchemeKey()
            end
        end,
        on_error = function(reason, keyboard)
            self:disableForSession(reason, keyboard)
        end,
        lexicon_provider = self.lexicon_provider,
        on_lexicon_error = function(reason)
            self:_fallbackLexicon(reason)
        end,
        ensure_data = deferred and function(engine)
            return self:_loadDeferredEngineData(engine)
        end or nil,
    }
    self.engines[engine] = true
    return engine
end

function Runtime:_releaseData()
    self:_closeLexiconProvider()
    self.code_map = nil
    self.abbreviation_map = nil
    self.overlay_exact = nil
    self.overlay_abbr = nil
    self.overlay_metadata = nil
    self.correction_full = nil
    self.correction_metadata = nil
    self.shuangpin_decoder = nil
    self.correction_shuangpin = nil
    self.shuangpin_resources = nil
    self.sorted_codes = nil
    self.syllable_set = nil
    self.CandidateBar = nil
    self.CandidatePanel = nil
    self.PinyinIME = nil
    self.active_lexicon_mode = nil
    self.lexicon_fallback_reason = nil
    self._lexicon_initializing = nil
    self.data_loaded = false
end

function Runtime:disableForSession(reason, keyboard)
    if self.state == "failed_session" then
        return false
    end
    self.state = "failed_session"
    self.supported = false
    local full_reason = tostring(reason or "unknown compatibility error")
    self.error_message = full_reason:match("^[^\n]+") or full_reason
    self:_closeInputSchemeDialog()
    logger.err("Chinese pinyin disabled for this session:", full_reason,
        debug.traceback("", 2))

    local keyboards, seen = {}, {}
    if keyboard then
        keyboards[#keyboards + 1] = keyboard
        seen[keyboard] = true
    end
    for _, item in pairs(self.legacy_active or {}) do
        if item.keyboard and not seen[item.keyboard] then
            keyboards[#keyboards + 1] = item.keyboard
            seen[item.keyboard] = true
        end
    end

    local function finishFallback()
        if self.adapter and self.adapter.uninstall then
            pcall(self.adapter.uninstall, self, "raw")
        end
        self:flush()
        self:_releaseData()
        for _, active_keyboard in ipairs(keyboards) do
            pcall(function()
                local layout = active_keyboard:getKeyboardLayout()
                active_keyboard:setKeyboardLayout(layout)
            end)
        end
        if not self._failure_notified then
            self._failure_notified = true
            local manager_ok, UIManager = pcall(require, "ui/uimanager")
            local message_ok, InfoMessage = pcall(require, "ui/widget/infomessage")
            if manager_ok and message_ok then
                pcall(UIManager.show, UIManager, InfoMessage:new{
                    text = "中文拼音插件发生兼容错误，本次会话已停用并恢复 KOReader 原生输入。"
                        .. "\n\n" .. self.error_message,
                })
            end
        end
    end

    local function protectedFallback()
        local ok, fallback_err = xpcall(finishFallback, debug.traceback)
        if not ok then
            logger.err("Chinese pinyin session fallback failed:", fallback_err)
        end
    end
    local manager_ok, UIManager = pcall(require, "ui/uimanager")
    local scheduled = manager_ok and pcall(
        UIManager.scheduleIn, UIManager, 0, protectedFallback)
    if not scheduled then
        protectedFallback()
    end
    return true
end

function Runtime:flush()
    if self.settings and self.settings.flush then
        pcall(self.settings.flush, self.settings)
    end
end

function Runtime:isPersonalizationEnabled()
    return not self.settings or self.settings:isPersonalizationEnabled()
end

function Runtime:setPersonalizationEnabled(enabled)
    if not self.supported or not self.settings then
        return false
    end
    enabled = enabled ~= false
    local changed = self.settings:setPersonalizationEnabled(enabled)
    if not changed then
        return false
    end
    for engine in pairs(self.engines or {}) do
        engine:setPersonalizationEnabled(enabled)
    end
    return true
end

function Runtime:isPredictionEnabled()
    return not self.settings or self.settings:isPredictionEnabled()
end

function Runtime:setPredictionEnabled(enabled)
    if not self.supported or not self.settings then
        return false
    end
    enabled = enabled ~= false
    local changed = self.settings:setPredictionEnabled(enabled)
    if not changed then
        return false
    end
    for engine in pairs(self.engines or {}) do
        engine:setPredictionEnabled(enabled)
    end
    return true
end

function Runtime:hasPersonalizationData()
    if self.settings and self.settings:hasLearning() then
        return true
    end
    for engine in pairs(self.engines or {}) do
        if engine:hasSessionPersonalization() then
            return true
        end
    end
    return false
end

function Runtime:clearPersonalization()
    if not self.settings then
        return false
    end
    self.settings:clearLearning()
    for engine in pairs(self.engines or {}) do
        engine:clearPersonalization()
    end
    return true
end

function Runtime:getInputScheme()
    return self.settings and self.settings:getInputScheme() or "full"
end

function Runtime:_prepareInputSchemeResources(scheme)
    scheme = self.InputSchemes.normalize(scheme)
    local definition = self.InputSchemes.get(scheme)
    if not definition.is_shuangpin then
        return nil
    end
    if self.shuangpin_resources
            and self.shuangpin_resources.data_file == definition.data_file then
        return self.shuangpin_resources
    end
    local data = dofile(self.root .. "/" .. definition.data_file)
    if type(data) ~= "table" or type(data.codes) ~= "table"
            or type(data.canonical) ~= "table"
            or type(data.key_layout) ~= "table"
            or data.alphabet ~= definition.alphabet then
        error("invalid double-pinyin data for " .. scheme)
    end
    local decoder = self.ShuangpinDecoder:new{ code_map = data.codes }
    for syllable, code in pairs(data.canonical) do
        if type(syllable) ~= "string" or type(code) ~= "string" or #code ~= 2 then
            error("invalid canonical double-pinyin entry for " .. scheme)
        end
        for index = 1, #code do
            if not self.InputSchemes.isAllowedCharacter(
                    scheme, code:sub(index, index)) then
                error("invalid double-pinyin key for " .. scheme .. ": " .. code)
            end
        end
        local decoded = decoder:decode(code)
        if decoded.status ~= "valid" or decoded.lookup_code ~= syllable then
            error("double-pinyin validation failed for " .. scheme .. ": " .. code)
        end
    end
    if definition.requires_semicolon and data.key_layout[";"] ~= "ing" then
        error("double-pinyin semicolon mapping is unavailable for " .. scheme)
    end
    return {
        data_file = definition.data_file,
        decoder = decoder,
        corrections = self.ShuangpinDecoder.buildCorrections(
            data.codes, nil, data.canonical),
    }
end

function Runtime:_activateInputSchemeResources(resources)
    self.shuangpin_resources = resources
    self.shuangpin_decoder = resources and resources.decoder or nil
    self.correction_shuangpin = resources and resources.corrections or nil
end

function Runtime:_closeInputSchemeDialog()
    local dialog = self.input_scheme_dialog
    self.input_scheme_dialog = nil
    if dialog then
        local ok, UIManager = pcall(require, "ui/uimanager")
        if ok then
            pcall(UIManager.close, UIManager, dialog)
        end
    end
end

function Runtime:showInputSchemeDialog()
    if not self.supported or not self.settings then
        return false
    end
    self:_closeInputSchemeDialog()
    local InputSchemeDialog = dofile(self.root .. "/widgets/inputschemedialog.lua")
    local UIManager = require("ui/uimanager")
    local dialog
    dialog = InputSchemeDialog:new{
        schemes = self.InputSchemes,
        get_current_scheme = function()
            return self:getInputScheme()
        end,
        on_select = function(scheme)
            self:setInputScheme(scheme, true)
        end,
        -- Ownership cleanup only. Pixel restoration is handled by the normal
        -- window-stack repaint after UIManager removes the dialog.
        on_close = function(closed)
            if self.input_scheme_dialog == closed then
                self.input_scheme_dialog = nil
            end
        end,
    }
    self.input_scheme_dialog = dialog
    UIManager:show(dialog)
    return true
end

function Runtime:setInputScheme(scheme, finish_composition)
    if not self.supported or not self.settings then
        return false
    end
    scheme = self.InputSchemes.normalize(scheme)
    if scheme == self:getInputScheme() then
        return false
    end
    local resources
    local prepared, prepare_err = xpcall(function()
        resources = self:_prepareInputSchemeResources(scheme)
    end, debug.traceback)
    if not prepared then
        logger.err("Chinese pinyin scheme preparation failed:", prepare_err)
        return false
    end
    local ok, err = xpcall(function()
        for engine in pairs(self.engines or {}) do
            local _, changed = engine:setInputScheme(
                scheme, finish_composition ~= false, resources)
            if not changed then
                error("input engine rejected scheme " .. scheme)
            end
            if self.state ~= "active" then
                return
            end
        end
        if self.adapter and self.adapter.updateSchemeLabels then
            self.adapter.updateSchemeLabels(self, scheme)
        end
        self.settings:setInputScheme(scheme)
        self:_activateInputSchemeResources(resources)
    end, debug.traceback)
    if not ok then
        logger.err("Chinese pinyin scheme switch failed:", err)
        return false
    end
    return self.state == "active"
end

function Runtime:toggleInputScheme(finish_composition)
    local scheme = self:getInputScheme() == "full"
        and (self.settings.last_shuangpin_scheme or "flypy") or "full"
    return self:setInputScheme(scheme, finish_composition)
end

function Runtime:buildInputSchemeMenuItem()
    local sub_items = {}
    for _, definition in ipairs(self.InputSchemes.list()) do
        local scheme = definition.id
        sub_items[#sub_items + 1] = {
            text = definition.name,
            radio = true,
            checked_func = function() return self:getInputScheme() == scheme end,
            callback = function() self:setInputScheme(scheme, true) end,
        }
    end
    return {
        text_func = function()
            return T("输入方案：%1", self.InputSchemes.getName(self:getInputScheme()))
        end,
        help_text = "长按简体中文键盘的空格键，可选择全拼或受支持的双拼方案。",
        enabled_func = function() return self.supported end,
        sub_item_table = sub_items,
    }
end

function Runtime:buildPersonalizationMenuItem()
    return {
        text = "个性化学习",
        help_text = "根据你的候选选择调整排序并学习常用的后续词。关闭后保留已有数据，但不再使用或记录。",
        checked_func = function()
            return self:isPersonalizationEnabled()
        end,
        callback = function()
            self:setPersonalizationEnabled(not self:isPersonalizationEnabled())
        end,
    }
end

function Runtime:buildPredictionMenuItem()
    return {
        text = "后续词联想",
        help_text = "提交中文候选后，根据最近的输入显示最多五个后续词候选。",
        checked_func = function()
            return self:isPredictionEnabled()
        end,
        callback = function()
            self:setPredictionEnabled(not self:isPredictionEnabled())
        end,
    }
end

function Runtime:buildDeferredLoadMenuItem()
    return {
        text = "延迟加载词库数据",
        help_text = "开启后，词库与拼音数据在第一次敲拼音时才载入："
            .. "长按查词典、全文搜索等弹出输入窗口时不再预载约 14MB 数据、"
            .. "不产生 1 秒左右的一次性卡顿；代价是每个会话第一次打拼音时"
            .. "才付出这次载入。关闭则恢复键盘弹出时预载。"
            .. "词库已载入后，本开关本次会话不再有变化。",
        checked_func = function()
            return self.settings and self.settings.isDeferredDataLoadEnabled
                and self.settings:isDeferredDataLoadEnabled() or true
        end,
        callback = function()
            if self.settings and self.settings.isDeferredDataLoadEnabled then
                self.settings:setDeferredDataLoadEnabled(
                    not self.settings:isDeferredDataLoadEnabled())
            end
        end,
    }
end

function Runtime:getLexiconStatus()
    local requested = self.settings and self.settings:getLexiconMode() or "auto"
    if not self.data_loaded then
        return requested == "compatibility" and "兼容词库（尚未载入）"
            or "完整万象词库（输入时自动载入）"
    elseif self.active_lexicon_mode == "full" then
        local stats = self.lexicon_provider and self.lexicon_provider:getStats() or {}
        local metadata = stats.metadata or {}
        if metadata.schema_version == "5" then
            return "完整万象词库（V5 单轨；热点编码："
                .. (metadata.code_head_count or "0") .. "；联想上下文："
                .. (metadata.prediction_head_count or "0") .. "）"
        end
        return "完整万象词库（V5 校验失败）"
    elseif self.lexicon_fallback_reason then
        return "兼容词库（万象回退：" .. self.lexicon_fallback_reason .. ")"
    end
    return "兼容词库"
end

function Runtime:getCompatibilityStatus()
    local labels = {
        verified_release = "正式验证",
        verified_commit = "提交验证",
        runtime_verified = "本机运行时验证",
    }
    return labels[self.compatibility_status] or "未验证"
end

function Runtime:getStatusText()
    local status = self.supported and "已启用" or "已停用"
    local lines = {
        "插件版本：" .. self.plugin_version,
        "运行状态：" .. status,
        "兼容性验证：" .. self:getCompatibilityStatus(),
        "输入方案：" .. self.InputSchemes.getName(self:getInputScheme()),
        "实际词库模式：" .. self:getLexiconStatus(),
        "个性化学习：" .. (self:isPersonalizationEnabled() and "已开启" or "已关闭"),
        "后续词联想：" .. (self:isPredictionEnabled() and "已开启" or "已关闭"),
    }
    if self.error_message then
        lines[#lines + 1] = "技术详情：" .. self.error_message
    end
    return table.concat(lines, "\n")
end

function Runtime:setLexiconMode(mode)
    if not self.supported or not self.settings then
        return false
    end
    mode = mode == "compatibility" and "compatibility" or "auto"
    local changed = self.settings:setLexiconMode(mode)
    if not self.data_loaded then
        return changed
    end

    local ok, err = pcall(function()
        self:_closeLexiconProvider()
        if mode == "compatibility" then
            self.lexicon_fallback_reason = nil
            self:_loadCompatibilityLexiconData()
            self.active_lexicon_mode = "compatibility"
        else
            self:_initializeLexicon()
        end
        for engine in pairs(self.engines or {}) do
            self:_updateEngineLexicon(engine, self.lexicon_provider)
            if engine:isComposing() then
                engine:_refreshCandidates()
            end
        end
    end)
    if not ok then
        self:disableForSession("lexicon mode switch failed: " .. tostring(err))
        return false
    end
    return changed and self.state == "active"
end

function Runtime:buildLexiconModeMenuItem()
    return {
        text_func = function()
            local mode = self.settings and self.settings:getLexiconMode() == "compatibility"
                and "兼容词库" or "自动（完整万象词库）"
            return T("词库模式：%1", mode)
        end,
        help_text = "自动模式只读访问插件目录内的万象 SQLite；失败时自动回退兼容词库。用户学习数据仍单独保存。",
        enabled_func = function() return self.supported end,
        sub_item_table = {
            {
                text = "自动（完整万象词库）",
                radio = true,
                checked_func = function()
                    return self.settings and self.settings:getLexiconMode() == "auto"
                end,
                callback = function() self:setLexiconMode("auto") end,
            },
            {
                text = "兼容词库",
                radio = true,
                checked_func = function()
                    return self.settings and self.settings:getLexiconMode() == "compatibility"
                end,
                callback = function() self:setLexiconMode("compatibility") end,
            },
        },
    }
end

function Runtime:uninstall()
    self:_closeInputSchemeDialog()
    if self.adapter and self.adapter.uninstall then
        pcall(self.adapter.uninstall, self, "candidate")
    end
    self:flush()
    self:_releaseData()
    self.supported = false
    self.installed = false
    self.state = "idle"
    self.engines = nil
    self.settings = nil
    self.Settings = nil
    self.adapter = nil
    self.adapter_name = nil
    self.compatibility = nil
    self.compatibility_admission = nil
    self.compatibility_status = nil
    self.compatibility_probe_passed = nil
    self.release_tag = nil
    self.error_message = nil
    self._install_failure_notice_pending = false
    self._failure_notified = nil
    self.ShuangpinDecoder = nil
end

return Runtime
