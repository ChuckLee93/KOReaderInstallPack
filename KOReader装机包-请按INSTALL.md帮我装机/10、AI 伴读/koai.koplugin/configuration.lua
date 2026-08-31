-- KOAI configuration.lua（DeepSeek 专用版）
-- 默认值 = 轻量划词/词典 + 5 个划词 Prompt；power_mode 开启时追加 KOAI 精读模块配置。
-- DeepSeek API Key 已写死在 ai_query.lua 中，无需填写。
-- 实际设置保存在 KOReader settings 目录的 aireadingassistant_settings.json 中（菜单里改即可，
-- 旧版 AI Reading Assistant 与旧版 KOAI 的设置会被自动读取合并）。
local CONFIGURATION = {
  -- ===== 精读模式总开关（KOAI）=====
  -- false：只启用轻量划词/词典功能（原 10 号插件），不加载 KOAI 模块，不自动采集，不费 token。
  -- true ：启用 KOAI 精读（人物卡、复盘、久读回顾、已读上下文），适合名著大部头/文献。
  power_mode = false,

  -- ===== DeepSeek =====
  deepseek_model = "deepseek-v4-flash",

  -- 5 个划词 Prompt（两种模式共用；精读模式会自动附带已读上下文与防剧透规则）
  enabled1 = true,
  menu_text1 = "学术概念解析",
  prompt1 = "你是一名博学的学术专家与百科全书式伴读助手。请对选中的专业概念、名词术语、理论假说或人物事件进行深度解析：\n1. 【核心定义】：用简练通俗的语言解释其核心定义与学术定位。\n2. 【专业脉络】：详述其历史背景、关联理论、核心学派或演进过程。\n3. 【价值意义】：说明该名词在其专业领域的价值或现实意义。\n请返回不超过400字的纯文本，不要使用markdown格式。",

  enabled2 = true,
  menu_text2 = "英语句子翻译",
  prompt2 = "你是一名精通双语的资深翻译家与语言专家。请对选中的英文文本执行以下任务：\n1. 【精准翻译】：将该段英文翻译为流畅、自然、契合中文表达习惯的译文（信达雅）。\n2. 【核心词汇】：提取句中的重点生词、词组，并附带音标及简明中文释义。\n3. 【难点剖析】：如果句子结构复杂，请简要分析其主干句型、从句或特殊语法现象。\n请返回纯文本，不要使用markdown格式。",

  enabled3 = true,
  menu_text3 = "人文历史解读",
  prompt3 = "你是一名贯通中外历史的人文学者与伴读顾问。请对选中的人物、事件、典故、制度、称谓、地名或历史性语句进行深度解读：\n1. 【知识释义】：说明涉及的人物、事件、典故、制度或名词的基本史实与时代背景，生僻的称谓、官职、年号等附简明释义。\n2. 【因果脉络】：梳理其来龙去脉——起因、经过、结果与后续影响；若句中隐含人物关系或因果，请理清谁对谁做了什么、导向了什么。\n3. 【深层理解】：剖析关键人物的动机、立场与利益考量，补充必要的文化语境、史学评价或常见误读。\n请返回不超过400字的纯文本，不要使用markdown格式。",

  enabled4 = true,
  menu_text4 = "通用语境赏析",
  prompt4 = "你是一名博闻强识的阅读向导与文学评论家。请对选中的书籍文字执行以下分析：\n1. 【语境解析】：结合书籍的上下文，深度解读这段文字在情节、逻辑或论点中的承载与承接作用。\n2. 【文学赏析】：剖析其中蕴含的修辞手法、文学隐喻、人物心理、时代背景或叙事艺术。\n3. 【思考延伸】：提出一个与此相关的启发性思考或关联知识点。\n请返回纯文本，不要使用markdown格式。",

  enabled5 = true,
  menu_text5 = "古文典籍解读",
  prompt5 = "你是古籍研读助手，处理选中古文文本：\n1. 【白话译文】通顺完整翻译成现代汉语。\n2. 【关键字词】标注重点实词虚词释义。\n3. 【典故背景】解释涉及的历史典故、人物、时代背景。\n请返回纯文本，禁止markdown格式，输出控制在400字以内。",

  -- 查看器中显示 AI 响应的最大行数（0 = 不限制）
  max_ai_response_lines = 20,

  -- 划词时自动扩展到最近句子边界
  auto_expand_to_sentence = true,

  -- ===== KOAI 精读模块配置（power_mode 开启时生效）=====
  -- DeepSeek 思考模式：默认关闭，遇到极难古籍/复杂学术段落可临时开启。
  thinking_enabled = false,

  -- 异常防护上限：避免模型偶发失控而一次耗尽余额。
  response_max_tokens = 8192,

  -- 超过该小时数再次打开/唤醒时提示前情回顾。
  resume_prompt_enabled = true,
  resume_after_hours = 10,

  -- 自动采集实际翻阅过的当前屏文字（仅本地保存，生成复盘时才发送）。
  auto_capture_enabled = true,

  capture_chunk_bytes = 98304,
  recap_batch_max_bytes = 70000,
  storage_mode = "standard",
  compact_keep_recent_records = 30,

  -- KOAI 结果字号（默认比轻量模式大一档）。
  result_font_size = 24,
}

local settings_storage = require("settings_storage")
local current_config = settings_storage.load(CONFIGURATION)

function current_config:update(updates)
  for k, v in pairs(updates) do
    self[k] = v
  end
  settings_storage.save(self)
end

return current_config
