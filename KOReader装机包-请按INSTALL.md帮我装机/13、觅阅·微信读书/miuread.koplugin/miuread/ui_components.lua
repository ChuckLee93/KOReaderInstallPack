local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local IconRegistry = require("miuread.icon_registry")

local Ui = {}

local AlignContainer = WidgetContainer:extend{
    dimen = nil,
    halign = "center",
    valign = "center",
}

function AlignContainer:init()
    self.dimen = self.dimen or Geom:new{w = 1, h = 1}
end

function AlignContainer:getSize()
    return Geom:new{w = self.dimen.w, h = self.dimen.h}
end

function AlignContainer:paintTo(bb, x, y)
    local child = self[1]
    if not child then return end
    local size = child:getSize()
    local cw, ch = tonumber(size.w) or 0, tonumber(size.h) or 0
    local dx = 0
    if self.halign == "right" then
        dx = self.dimen.w - cw
    elseif self.halign == "center" then
        dx = math.floor((self.dimen.w - cw) / 2)
    end
    local dy = 0
    if self.valign == "bottom" then
        dy = self.dimen.h - ch
    elseif self.valign == "center" then
        dy = math.floor((self.dimen.h - ch) / 2)
    end
    child:paintTo(bb, x + math.max(0, dx), y + math.max(0, dy))
end

function Ui.align(child, width, height, halign, valign)
    return AlignContainer:new{
        dimen = Geom:new{w = math.max(1, width), h = math.max(1, height)},
        halign = halign or "center",
        valign = valign or "center",
        child,
    }
end

function Ui.text(text, width, height, face, opts)
    opts = opts or {}
    local child = TextWidget:new{
        text = tostring(text or ""),
        face = face,
        bold = opts.bold == true,
        fgcolor = opts.fgcolor or Blitbuffer.COLOR_BLACK,
    }
    return Ui.align(child, width, height, opts.halign or opts.alignment or "center", opts.valign or "center")
end

function Ui.textbox(text, width, height, face, opts)
    opts = opts or {}
    local child = TextBoxWidget:new{
        text = tostring(text or ""),
        face = face,
        bold = opts.bold == true,
        width = math.max(1, width),
        height_adjust = true,
        height_overflow_show_ellipsis = opts.ellipsis ~= false,
        alignment = opts.text_alignment or opts.alignment or "left",
        fgcolor = opts.fgcolor or Blitbuffer.COLOR_BLACK,
    }
    return Ui.align(child, width, height, opts.halign or opts.alignment or "left", opts.valign or "center")
end

function Ui.icon(value, width, height, size, opts)
    opts = opts or {}
    local child = IconRegistry.widget(opts.icon_key or value, size, {
        path = opts.icon_path,
        face = opts.face,
        bold = opts.bold,
        fgcolor = opts.fgcolor,
        fallback_text = opts.fallback_text,
    })
    return Ui.align(child, width, height, opts.halign or "center", opts.valign or "center")
end

return Ui
