--[[
    封面生成器：为没有封面的书籍自动生成封面
]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local DocumentRegistry = require("document/documentregistry")
local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")

logger.info("[封面生成器] 补丁开始加载...")

local retry_count = 0
local MAX_RETRY = 30

local function installCoverGenerator()
    retry_count = retry_count + 1
    logger.info("[封面生成器] 第" .. retry_count .. "次尝试...")
    
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok then
        logger.info("[封面生成器] bookinfomanager 未就绪，0.5秒后重试")
        if retry_count < MAX_RETRY then
            UIManager:scheduleIn(0.5, installCoverGenerator)
        end
        return
    end
    
    if not BookInfoManager.extractBookInfo then
        logger.info("[封面生成器] extractBookInfo 不存在，等待...")
        if retry_count < MAX_RETRY then
            UIManager:scheduleIn(0.5, installCoverGenerator)
        end
        return
    end
    
    logger.info("[封面生成器] bookinfomanager 已就绪，开始 patch extractBookInfo...")
    
    local RenderText = require("ui/rendertext")
    local Font = require("ui/font")
    local Screen = require("device").screen
    local Blitbuffer = require("ffi/blitbuffer")
    local util = require("util")
    
    -- 生成封面函数
    local function generateCover(title, authors, filepath, fullsize)
        local target_w, target_h
        if fullsize then
            -- 固定 3:4比例，宽度 1200 像素
            target_w = 1200
            target_h = 1600
        else
            target_w = 300
            target_h = 400
        end
        
        local display_title = title or "Untitled"
        local display_authors = authors or ""
        
        -- 如果标题为空，从文件名提取
        if not title or title == "" then
            local basename = filepath:match("([^/]+)$") or filepath
            display_title = basename:gsub("%.[^%.]+$", "")
            display_title = display_title:gsub("%.[^%.]+$", "")
        end
        
        if #display_authors > 80 then
            display_authors = display_authors:sub(1, 77) .. "..."
        end
        
        -- 默认蓝色渐变背景
        logger.info("[封面生成器] 使用默认蓝色渐变背景")
        local bb = Blitbuffer.new(target_w, target_h, Blitbuffer.TYPE_BBRGB32)
        
        local split_y = math.floor(target_h * 2 / 3)
        local lighter_blue = Blitbuffer.ColorRGB32(212, 220, 243, 255)  -- #D4DCF3
        local darker_blue = Blitbuffer.ColorRGB32(130, 159, 227, 255)   -- #AAC3F0
        
        for y = 0, split_y - 1 do
            for x = 0, target_w - 1 do
                bb:setPixel(x, y, lighter_blue)
            end
        end
        for y = split_y, target_h - 1 do
            for x = 0, target_w - 1 do
                bb:setPixel(x, y, darker_blue)
            end
        end
        
        -- 标题字体调大
        local title_font_size = fullsize and math.min(96, math.max(52, math.floor(target_w / 6))) or 36
        -- 作者字体
        local authors_font_size = fullsize and math.min(70, math.max(30, math.floor(target_w / 13))) or 18
        
        -- 使用系统字体支持中文
        local title_face = Font:getFace("ffont", title_font_size)
        local authors_face = Font:getFace("ffont", authors_font_size)
        
        -- 文字颜色
        local title_color = Blitbuffer.ColorRGB32(1, 68, 142, 255)   -- #01448E
        local authors_color = Blitbuffer.ColorRGB32(8, 51, 93, 255)  -- #08335D
        
        local function getTextWidth(face, text)
            return RenderText:sizeUtf8Text(0, false, face, text, true, false).x
        end
        
        -- 按字符换行（不限制行数）
        local function wrapTextByChar(text, face, max_width)
            local chars = util.splitToChars(text)
            local lines = {}
            local current_line = ""
            for _, ch in ipairs(chars) do
                local test_line = current_line .. ch
                if getTextWidth(face, test_line) > max_width and current_line ~= "" then
                    table.insert(lines, current_line)
                    current_line = ch
                else
                    current_line = test_line
                end
            end
            if current_line ~= "" then
                table.insert(lines, current_line)
            end
            if #lines == 0 and #chars > 0 then
                for _, ch in ipairs(chars) do
                    table.insert(lines, ch)
                end
            end
            return lines
        end
        
        local function drawText(bb, lines, face, color, start_y, line_height)
            local y = start_y
            for _, line in ipairs(lines) do
                local line_width = getTextWidth(face, line)
                local line_x = math.floor((target_w - line_width) / 2)
                if line_x < 0 then line_x = 0 end
                RenderText:renderUtf8Text(bb, line_x, y + face.size, face, line, true, false, color)
                y = y + line_height
            end
        end
        
        local line_height = title_face.size + 8
        local max_text_width = target_w - 80
        
        -- 标题换行（不限制行数）
        local title_lines = wrapTextByChar(display_title, title_face, max_text_width)
        local title_height = #title_lines * line_height
        
        -- 标题垂直居中在上半部分
        local split_y = math.floor(target_h * 2 / 3)
        local title_y = math.floor((split_y - title_height) / 2)
        if title_y < 10 then title_y = 10 end
        drawText(bb, title_lines, title_face, title_color, title_y, line_height)
        
        -- 作者
        if display_authors ~= "" then
            local author_lines = wrapTextByChar(display_authors, authors_face, max_text_width)
            local author_height = #author_lines * line_height
            local author_y = split_y + math.floor((target_h - split_y - author_height) / 2)
            drawText(bb, author_lines, authors_face, authors_color, author_y, line_height)
        end
        
        return bb
    end
    
    -- 保存 PNG 函数
    local function savePNG(bb, filepath)
        local success, err = pcall(bb.writePNG, bb, filepath)
        if success then
            logger.info("[封面生成器] PNG 保存成功:", filepath)
        else
            logger.warn("[封面生成器] PNG 保存失败:", filepath, tostring(err))
        end
        return success
    end
    
    -- 保存原始函数
    local original_extract = BookInfoManager.extractBookInfo
    
    -- 覆盖 extractBookInfo
    function BookInfoManager:extractBookInfo(filepath, cover_specs)
        -- 调用原始函数
        local result = original_extract(self, filepath, cover_specs)
        
        -- 从 bookinfo 获取元数据（原始函数已经存到数据库了）
        local bookinfo = self:getBookInfo(filepath, false)
        
        if bookinfo and not bookinfo.has_cover and not bookinfo.ignore_cover then
            logger.info("[封面生成器] 书籍没有封面，尝试生成:", filepath)
            
            local title = bookinfo.title
            local authors = bookinfo.authors
            
            -- 如果 bookinfo 中也没有标题，从文件名提取
            if not title or title == "" then
                local basename = filepath:match("([^/]+)$") or filepath
                title = basename:gsub("%.[^%.]+$", "")
                title = title:gsub("%.[^%.]+$", "")
            end
            
            local cover_bb = generateCover(title, authors, filepath, true)
            if cover_bb then
                local sdr_dir = DocSettings:getSidecarDir(filepath)
                lfs.mkdir(sdr_dir)
                local cover_png = sdr_dir .. "/cover.png"
                savePNG(cover_bb, cover_png)
                cover_bb:free()
            end
        end
        
        return result
    end
    
    logger.info("[封面生成器] ========== 加载完成！==========")
end

installCoverGenerator()