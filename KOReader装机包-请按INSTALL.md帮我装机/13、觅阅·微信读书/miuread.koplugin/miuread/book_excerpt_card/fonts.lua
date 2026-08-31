--[[--
字体解析：把调用方传入的 CRE 字体族名解析成 Font:getFace 能打开的文件，
找不到时回退模板字体（cfont/ffont）。对齐 thought_popup/face_factory.lua。

@module koplugin.miuread.book_excerpt_card.fonts
--]]--

local Config = require("miuread.book_excerpt_card.config")
local Font = require("ui/font")
local Screen = require("device").screen
local util = require("util")

--- 当前阅读字体族名（KOReader cre_font）。UI Font:getFace 认的是文件名/别名，
-- 不能直接拿族名去加载（会变成 ./fonts/LXGW WenKai 无扩展名，FreeType error 1）。
local function getReaderFont()
    if _G.G_reader_settings and type(_G.G_reader_settings.readSetting) == "function" then
        local f = _G.G_reader_settings:readSetting("cre_font")
        if type(f) == "string" and f ~= "" then
            return f
        end
    end
    return nil
end

-- family → { file=, index= } | false。CRE 族名解析只做一次。
local cre_font_file_cache = {}

local function isUiFontName(name)
    if type(name) ~= "string" or name == "" then return false end
    if Font.fontmap and Font.fontmap[name] then return true end
    -- 已是字体文件名（含扩展名）
    local lower = name:lower()
    return lower:find("%.ttf$") or lower:find("%.otf$") or lower:find("%.ttc$")
        or lower:find("%.cff$") or lower:find("%.woff2?$")
end

--- 把 CRE 字体族名解析成 Font:getFace 能打开的文件名 + faceindex。
-- 对齐 thought_popup/face_factory.lua：cre.getFontFaceFilenameAndFaceIndex。
local function resolveCreFontFile(family)
    if type(family) ~= "string" or family == "" then return nil, nil end
    local cached = cre_font_file_cache[family]
    if cached == false then return nil, nil end
    if cached then return cached.file, cached.index end

    local path, faceindex
    local ok, cre = pcall(function()
        return require("document/credocument"):engineInit()
    end)
    if ok and cre and type(cre.getFontFaceFilenameAndFaceIndex) == "function" then
        path, faceindex = cre.getFontFaceFilenameAndFaceIndex(family, false, false)
    end
    if type(path) ~= "string" or path == "" then
        -- CRE 未就绪时：FontList 路径常是 LXGWWenKai-Regular.ttf，族名带空格对不上
        local compact = family:gsub("%s+", "")
        local ok_list, FontList = pcall(require, "fontlist")
        if ok_list and FontList and type(FontList.getFontList) == "function" then
            for _, fp in ipairs(FontList:getFontList() or {}) do
                if fp:find(family, 1, true) or (compact ~= "" and fp:find(compact, 1, true)) then
                    path = fp
                    break
                end
            end
        end
    end
    if type(path) ~= "string" or path == "" then
        cre_font_file_cache[family] = false
        return nil, nil
    end
    local _, basename = util.splitFilePathName(path)
    local file = (basename and basename ~= "") and basename or path
    local index = tonumber(faceindex)
    if index and index < 0 then index = nil end
    cre_font_file_cache[family] = { file = file, index = index }
    return file, index
end

--- 获取字体 face：CRE 族名先解析成文件；找不到再回退模板字体（cfont/ffont）。
local function safeGetFace(name, size, fallback)
    local font, faceindex = name, nil
    if name and not isUiFontName(name) then
        font, faceindex = resolveCreFontFile(name)
        if not font then
            font = fallback or "cfont"
            faceindex = nil
        end
    end
    -- Font:getFace 内部会按设备 DPI 缩放(size * Screen:scaleBySize(1));
    -- 卡片固定 @3x 导出,传入预补偿尺寸,使最终 face.size = size_pt * RENDER_SCALE
    -- (与画布 ds() 同一像素坐标系,不随设备 DPI 变化)
    local px_size = size * Config.RENDER_SCALE / Screen:scaleBySize(1)
    local face = Font:getFace(font, px_size, faceindex)
    if face then return face end
    return Font:getFace(fallback or "cfont", px_size)
end

return {
    getReaderFont = getReaderFont,
    safeGetFace = safeGetFace,
}
