-- 2-disable-wikipedia.lua
-- 国内网络环境：彻底移除 KOReader 的维基百科功能
-- 生效范围：
--   1) 搜索菜单的"查询维基百科 / 维基百科查询记录"（不再注册）
--   2) 设置菜单里的"维基百科设置"（不再注册）
--   3) 手势管理/配置动作列表里的 wikipedia_lookup（官方 API 删除）
--   4) 查词窗口默认布局兜底剔除 wikipedia（当前已自定义布局不含它）
--   5) 高亮菜单精简：维基/查看HTML/分享/网页搜索/翻译（原 simpleUI 逻辑并入）

------------------------------------------------------------
-- 1) 模块空壳化：require 时返回空壳，真正跳过源文件加载编译
------------------------------------------------------------
local stub = {}
function stub:new(o)
    o = o or {}
    return o
end
package.preload["apps/reader/modules/readerwikipedia"] = function()
    return stub
end

-- 保险：万一补丁运行时该模块已被加载，让已加载副本也不再注册菜单
local loaded = package.loaded["apps/reader/modules/readerwikipedia"]
if loaded then
    loaded.init = function(self) end
end

------------------------------------------------------------
-- 2) 手势/动作注册表：删除 wikipedia_lookup
------------------------------------------------------------
local ok, Dispatcher = pcall(require, "dispatcher")
if ok and Dispatcher and Dispatcher.removeAction then
    Dispatcher:removeAction("wikipedia_lookup")
end

------------------------------------------------------------
-- 3) 查词窗口：默认布局剔除 wikipedia（防止将来重置设置后又冒出）
------------------------------------------------------------
local ok2, ReaderDictionary = pcall(require, "apps/reader/modules/readerdictionary")
if ok2 and ReaderDictionary then
    local orig_dict_init = ReaderDictionary.init
    ReaderDictionary.init = function(self)
        orig_dict_init(self)
        if self.default_layout then
            for _, row in ipairs(self.default_layout) do
                for i = #row, 1, -1 do
                    if row[i] == "wikipedia" then table.remove(row, i) end
                end
            end
        end
    end
end

------------------------------------------------------------
-- 4) 高亮菜单精简（与 simpleUI 里的旧代码一致，两处并存不冲突）
------------------------------------------------------------
local ok3, ReaderHighlight = pcall(require, "apps/reader/modules/readerhighlight")
if ok3 and ReaderHighlight then
    local orig_hl_init = ReaderHighlight.init
    ReaderHighlight.init = function(self)
        orig_hl_init(self)
        if self.removeFromHighlightDialog then
            self:removeFromHighlightDialog("01_select")
            self:removeFromHighlightDialog("05_wikipedia")
            self:removeFromHighlightDialog("05_encyclopedia")
            self:removeFromHighlightDialog("07_translate")
            self:removeFromHighlightDialog("08_view_html")
            self:removeFromHighlightDialog("09_view_html")
            self:removeFromHighlightDialog("08_share_text")
            self:removeFromHighlightDialog("10_share")
            self:removeFromHighlightDialog("12_search")
        end
    end
end
