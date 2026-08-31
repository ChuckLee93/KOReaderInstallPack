--[[--
RGB32 彩色渲染补丁（加载即生效，见 init.lua require 顺序）。

koreader RenderText:renderUtf8Text 对 RGB32 目标用 colorblitFrom(灰度染色):
C 库 BB_color_blit_from 把颜色亮度当灰度,深色字(如 #270007)渲染成黑灰。
彩色卡片(RGB32)必须走 colorblitFromRGB32(用 RGB 通道正确染色)。
只在目标为 RGB32 时替换,BB8/BB8A(e-ink 屏)保持原灰度路径,不影响 UI。

@module koplugin.miuread.book_excerpt_card.rgb32
--]]--

local BlitBuffer = require("ffi/blitbuffer")
local RenderText = require("ui/rendertext")
local logger = require("logger")
local util = require("util")

do
    local orig_render_utf8 = RenderText.renderUtf8Text
    local bit = require("bit")
    local is_rgb32 = function(bb)
        return bb and bb.getType and bb:getType() == BlitBuffer.TYPE_BBRGB32
    end
    -- 字符 → charcode(与 rendertext.utf8Chars 语义一致:UTF-8 解码)
    local function charToCode(ch)
        local b1 = ch:byte(1)
        if b1 < 0x80 then return b1 end
        if b1 < 0xE0 then
            return bit.lshift(bit.band(b1, 0x1F), 6) + ch:byte(2) - 0x80
        elseif b1 < 0xF0 then
            return bit.lshift(bit.band(b1, 0x0F), 12)
                + (ch:byte(2) - 0x80) * 64 + (ch:byte(3) - 0x80)
        else
            return bit.lshift(bit.band(b1, 0x07), 18)
                + (ch:byte(2) - 0x80) * 4096
                + (ch:byte(3) - 0x80) * 64 + (ch:byte(4) - 0x80)
        end
    end
    function RenderText:renderUtf8Text(dest_bb, x, baseline, face, text, kerning, bold, fgcolor, width, char_pads)
        if is_rgb32(dest_bb) and fgcolor and fgcolor.r ~= nil then
            -- RGB32 目标:逐字用 colorblitFromRGB32 染色(与 koreader textboxwidget 一致)
            if not text then
                logger.warn("renderUtf8Text called without text")
                return 0
            end
            local pen_x = 0
            local prevcharcode = 0
            local text_width = dest_bb:getWidth() - x
            if width and width < text_width then
                text_width = width
            end
            local char_idx = 0
            for _, ch in ipairs(util.splitToChars(text)) do
                local charcode = charToCode(ch)
                if pen_x < text_width then
                    local glyph = RenderText:getGlyph(face, charcode, bold)
                    if kerning and (prevcharcode ~= 0) then
                        pen_x = pen_x + face.ftsize:getKerning(prevcharcode, charcode)
                    end
                    dest_bb:colorblitFromRGB32(
                        glyph.bb,
                        x + pen_x + glyph.l,
                        baseline - glyph.t,
                        0, 0,
                        glyph.bb:getWidth(), glyph.bb:getHeight(),
                        fgcolor)
                    pen_x = pen_x + glyph.ax
                    prevcharcode = charcode
                end
                if char_pads then
                    char_idx = char_idx + 1
                    pen_x = pen_x + (char_pads[char_idx] or 0)
                end
            end
            return pen_x
        end
        return orig_render_utf8(self, dest_bb, x, baseline, face, text, kerning, bold, fgcolor, width, char_pads)
    end
end

return true
