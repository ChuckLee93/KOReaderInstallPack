local Device = require("device")
local Font = require("ui/font")
local ThoughtFaceFactory

local Screen = Device.screen
local UiScale = {}

local display_mode = "standard"
local ui_font_name = nil
local MODE_FACTORS = {
    compact = {font = 1.08, icon = 1.04, spacing = .96},
    -- The previous standard setting was still too small on 300 ppi Kindles.
    -- Use the midpoint between the old standard and large modes as the new
    -- default, while keeping geometry growth restrained so the 4x2 shelf fits.
    standard = {font = 1.34, icon = 1.22, spacing = 1.02},
    large = {font = 1.49, icon = 1.34, spacing = 1.08},
}

local function clamp(value, minimum, maximum)
    value = tonumber(value) or 0
    if minimum ~= nil and value < minimum then value = minimum end
    if maximum ~= nil and value > maximum then value = maximum end
    return value
end

function UiScale.setDisplayMode(mode)
    mode = tostring(mode or "standard")
    if not MODE_FACTORS[mode] then mode = "standard" end
    display_mode = mode
end

function UiScale.getDisplayMode()
    return display_mode
end

function UiScale.setFontName(name)
    name = type(name) == "string" and name:match("^%s*(.-)%s*$") or ""
    ui_font_name = name ~= "" and name or nil
end

function UiScale.getFontName()
    return ui_font_name
end

local function text_face(name, size)
    if ui_font_name then
        if not ThoughtFaceFactory then
            local ok, module = pcall(require, "miuread.thought_face_factory")
            if ok then ThoughtFaceFactory = module end
        end
        if ThoughtFaceFactory then
            local ok, face = pcall(ThoughtFaceFactory.getFace, ThoughtFaceFactory, ui_font_name, size, name)
            if ok and face then return face end
        end
    end
    return Font:getFace(name, size)
end

function UiScale.metrics()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local short = math.max(1, math.min(sw, sh))
    local long = math.max(sw, sh)
    local density = 1
    if type(Screen.scaleBySize) == "function" then
        local ok, scaled = pcall(Screen.scaleBySize, Screen, 100)
        if ok and tonumber(scaled) and tonumber(scaled) > 0 then
            density = tonumber(scaled) / 100
        end
    end
    density = clamp(density, .65, 2.5)
    local logical_short = short / density
    local logical_long = long / density
    local ratio = math.sqrt((logical_short / 758) * (logical_long / 1024))
    -- Geometry remains conservative so eight covers continue to fit. Text and
    -- icon comfort are handled independently below instead of shrinking every
    -- element with a single global factor.
    ratio = clamp(ratio * 1.16, .98, 1.30)
    local portrait = sw < sh
    return {
        sw = sw,
        sh = sh,
        short = short,
        long = long,
        density = density,
        ratio = ratio,
        portrait = portrait,
        aspect = long / short,
        display_mode = display_mode,
    }
end

function UiScale.dp(value, minimum, maximum)
    local m = UiScale.metrics()
    local factor = MODE_FACTORS[display_mode] or MODE_FACTORS.standard
    local logical = (tonumber(value) or 0) * m.ratio * factor.spacing
    logical = clamp(logical, minimum, maximum)
    local raw = logical
    if type(Screen.scaleBySize) == "function" then
        local ok, scaled = pcall(Screen.scaleBySize, Screen, logical)
        if ok and tonumber(scaled) then raw = tonumber(scaled) end
    end
    return math.max(0, math.floor(raw + .5))
end

function UiScale.raw(value, minimum, maximum)
    local m = UiScale.metrics()
    local factor = MODE_FACTORS[display_mode] or MODE_FACTORS.standard
    local raw = math.floor((tonumber(value) or 0) * m.ratio * factor.spacing + .5)
    return math.floor(clamp(raw, minimum, maximum) + .5)
end

function UiScale.face(name, nominal, maximum, minimum)
    local m = UiScale.metrics()
    local factors = MODE_FACTORS[display_mode] or MODE_FACTORS.standard
    local orientation_factor = m.portrait and 1 or 1.03
    local adjusted = (tonumber(nominal) or 10) * m.ratio * factors.font * orientation_factor
    local floor_size = math.max(1, (tonumber(minimum) or 1) * m.ratio * factors.font * orientation_factor)
    -- maximum is a visual cap in the old call sites. Scale it with the same
    -- comfort factor, otherwise a larger requested mode gets clipped early.
    local cap = math.max(floor_size, (tonumber(maximum) or adjusted) * m.ratio * factors.font * orientation_factor)
    local size = math.max(1, math.floor(clamp(adjusted, floor_size, cap) + .5))
    return text_face(name, size)
end

function UiScale.iconFace(name, nominal, maximum, minimum)
    local m = UiScale.metrics()
    local factors = MODE_FACTORS[display_mode] or MODE_FACTORS.standard
    local adjusted = (tonumber(nominal) or 10) * m.ratio * factors.icon
    local floor_size = math.max(1, (tonumber(minimum) or 1) * m.ratio * factors.icon)
    local cap = math.max(floor_size, (tonumber(maximum) or adjusted) * m.ratio * factors.icon)
    return Font:getFace(name, math.max(1, math.floor(clamp(adjusted, floor_size, cap) + .5)))
end

function UiScale.line(kind)
    local m = UiScale.metrics()
    local base = kind == "thick" and 2 or 1
    local value = math.floor(base * m.density * math.max(.84, m.ratio) + .5)
    if kind == "thick" then return clamp(value, 3, 5) end
    -- A one-pixel line is easily lost on several Kindle/Kobo panels after
    -- partial refresh. Keep all visible UI borders at least two device pixels.
    return clamp(value, 2, 3)
end

function UiScale.radius(value, minimum, maximum)
    return UiScale.dp(value, minimum or 3, maximum or 18)
end

return UiScale
