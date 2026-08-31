local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local LineWidget = require("ui/widget/linewidget")
local Widget = require("ui/widget/widget")
local UiScale = require("miuread.ui_scale")

local Skin = {}

local function fixed_frame(width, height, options, content)
    options = options or {}
    local border = tonumber(options.bordersize) or 0
    local padding = tonumber(options.padding) or 0
    local inset = border + padding
    return FrameContainer:new{
        bordersize = border,
        padding = padding,
        margin = 0,
        radius = tonumber(options.radius) or 0,
        background = options.background or Blitbuffer.COLOR_WHITE,
        color = options.color or Blitbuffer.COLOR_BLACK,
        CenterContainer:new{
            dimen = Geom:new{
                w = math.max(1, width - inset * 2),
                h = math.max(1, height - inset * 2),
            },
            content or Widget:new{dimen = Geom:new{w = 1, h = 1}},
        },
    }
end

function Skin.frame(width, height, options, content)
    return fixed_frame(width, height, options, content)
end

function Skin.paper(width, height, options, content)
    options = options or {}
    -- Clean e-ink frame: regular border only, no decorative corner marks.
    local safe = math.max(UiScale.line("thin"), UiScale.dp(2, 2, 4))
    local frame_w = math.max(1, width - safe * 2)
    local frame_h = math.max(1, height - safe * 2)
    return CenterContainer:new{
        dimen = Geom:new{w = width, h = height},
        fixed_frame(frame_w, frame_h, {
            bordersize = options.bordersize or UiScale.line("thick"),
            padding = options.padding or 0,
            radius = options.radius or UiScale.radius(9, 6, 14),
            background = options.background or Blitbuffer.COLOR_WHITE,
            color = options.color or Blitbuffer.COLOR_DARK_GRAY,
        }, content),
    }
end

function Skin.divider(width, color, thickness)
    return LineWidget:new{
        background = color or Blitbuffer.COLOR_GRAY,
        dimen = Geom:new{w = math.max(1, width), h = math.max(1, thickness or UiScale.line("thin"))},
    }
end

function Skin.expand_region(region, amount)
    if not region then return nil end
    amount = math.max(UiScale.line("thick"), tonumber(amount) or UiScale.dp(3, 2, 5))
    local x = math.max(0, (tonumber(region.x) or 0) - amount)
    local y = math.max(0, (tonumber(region.y) or 0) - amount)
    local right = math.min(Device and Device.screen and Device.screen:getWidth() or ((tonumber(region.x) or 0) + (tonumber(region.w) or 1)),
        (tonumber(region.x) or 0) + (tonumber(region.w) or 1) + amount)
    local bottom = math.min(Device and Device.screen and Device.screen:getHeight() or ((tonumber(region.y) or 0) + (tonumber(region.h) or 1)),
        (tonumber(region.y) or 0) + (tonumber(region.h) or 1) + amount)
    return Geom:new{x = x, y = y, w = math.max(1, right - x), h = math.max(1, bottom - y)}
end

function Skin.dp(value, minimum, maximum)
    return UiScale.dp(value, minimum, maximum)
end

function Skin.radius(value, minimum, maximum)
    return UiScale.radius(value, minimum, maximum)
end

function Skin.line(kind)
    return UiScale.line(kind or "thin")
end

function Skin.face(name, nominal, maximum, minimum)
    return UiScale.face(name, nominal, maximum, minimum)
end

return Skin
