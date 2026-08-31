-- sui_aa_paint.lua — Simple UI
-- Shared anti-aliasing primitives for widgets that paint curved shapes
-- (circles, rounded rects, capsule strokes) directly into an offscreen 8-bit
-- buffer, in BLACK ink, ahead of compositing via infra/sui_core.lua's
-- UI.paintWithAlphaMask (the same role TextWidget:paintTo plays for text).
--
-- Coverage-based, not supersampled: for every candidate pixel, this computes
-- how far the pixel's centre sits from the shape's edge and blends ink into
-- it proportionally (see blendPixel below). This needs no supersampling —
-- Blitbuffer's own :scale() is nearest-neighbour, so drawing at a larger
-- size and scaling down would not actually smooth anything.
--
-- Used by modules/module_clock.lua (analogue clock face) and
-- engines/sui_quickactions_render.lua (quick-action tile background/border).

local Blitbuffer = require("ffi/blitbuffer")

local M = {}

-- Blends `cov` (coverage in [0,1], 1 = full ink) as black into pixel
-- (px,py) of `bb`, clipped to [x0,x1] x [y0,y1]. Over-composites onto
-- whatever grey value is already there, so overlapping shapes (e.g. a fill
-- and the stroke painted on top of it) compound correctly instead of one
-- overwriting the other.
function M.blendPixel(bb, px, py, cov, x0, y0, x1, y1)
    if cov <= 0 then return end
    if px < x0 or px > x1 or py < y0 or py > y1 then return end
    if cov > 1 then cov = 1 end
    local g = bb:getPixel(px, py):getColor8().a
    bb:setPixel(px, py, Blitbuffer.Color8(math.floor(g * (1 - cov) + 0.5)))
end

-- Paints an anti-aliased capsule (a straight stroke of full width `width`,
-- rounded at both ends) from (ax,ay) to (bx,by) onto `bb`. For every
-- candidate pixel, projects it onto the segment to find the nearest point
-- on the stroke's centre line, then blends by how far the pixel's centre
-- sits inside the stroke's half-width — pixels fully inside get full ink,
-- pixels straddling the edge get partial ink, giving a smooth edge at
-- whatever resolution `bb` actually is.
function M.paintCapsule(bb, ax, ay, bx, by, width, x0, y0, x1, y1)
    local half = width / 2
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    local minx = math.floor(math.min(ax, bx) - half - 1)
    local maxx = math.floor(math.max(ax, bx) + half + 1)
    local miny = math.floor(math.min(ay, by) - half - 1)
    local maxy = math.floor(math.max(ay, by) + half + 1)
    for py = miny, maxy do
        for px = minx, maxx do
            local t = len2 > 0 and ((px - ax) * dx + (py - ay) * dy) / len2 or 0
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
            local qx, qy = ax + t * dx, ay + t * dy
            local ddx, ddy = px - qx, py - qy
            local dist = math.sqrt(ddx * ddx + ddy * ddy)
            M.blendPixel(bb, px, py, half + 0.5 - dist, x0, y0, x1, y1)
        end
    end
end

-- Signed distance from point (px,py) to the edge of a rounded rectangle
-- centred at (cx,cy) with half-extents (hw,hh) and corner radius `radius`
-- (clamped to fit within the half-extents). Negative = inside the shape,
-- positive = outside, zero = exactly on the edge. A plain rectangle
-- (radius = 0) and a circle/stadium (radius = min(hw,hh)) both fall out of
-- this same formula, so callers never need a separate code path per shape.
local function _roundedRectSDF(px, py, cx, cy, hw, hh, radius)
    radius = math.min(radius, hw, hh)
    local qx = math.abs(px - cx) - hw + radius
    local qy = math.abs(py - cy) - hh + radius
    local ax, ay = math.max(qx, 0), math.max(qy, 0)
    return math.sqrt(ax * ax + ay * ay) + math.min(math.max(qx, qy), 0) - radius
end

-- Paints an anti-aliased, filled rounded rectangle (x,y,w,h,radius) onto
-- `bb`. Shares _roundedRectSDF with paintRoundedRectStroke below, so a
-- filled shape's corners always match its own border's corners exactly.
function M.paintRoundedRectFill(bb, x, y, w, h, radius, x0, y0, x1, y1)
    local cx, cy = x + w / 2, y + h / 2
    local hw, hh = w / 2, h / 2
    local minx = math.floor(x - 1)
    local maxx = math.floor(x + w + 1)
    local miny = math.floor(y - 1)
    local maxy = math.floor(y + h + 1)
    for py = miny, maxy do
        for px = minx, maxx do
            local d = _roundedRectSDF(px + 0.5, py + 0.5, cx, cy, hw, hh, radius)
            M.blendPixel(bb, px, py, 0.5 - d, x0, y0, x1, y1)
        end
    end
end

-- Paints an anti-aliased rounded-rectangle outline (stroke), `thickness`
-- wide, centred on the rounded rect (x,y,w,h,radius) — same centre-line
-- convention as paintCapsule. Callers wanting the stroke fully inside a
-- given outer rect (the usual "border" look) inset x/y/w/h by half the
-- thickness and shrink radius by the same amount before calling this.
function M.paintRoundedRectStroke(bb, x, y, w, h, radius, thickness, x0, y0, x1, y1)
    local cx, cy = x + w / 2, y + h / 2
    local hw, hh = w / 2, h / 2
    local half_t = thickness / 2
    local minx = math.floor(x - half_t - 1)
    local maxx = math.floor(x + w + half_t + 1)
    local miny = math.floor(y - half_t - 1)
    local maxy = math.floor(y + h + half_t + 1)
    for py = miny, maxy do
        for px = minx, maxx do
            local d = _roundedRectSDF(px + 0.5, py + 0.5, cx, cy, hw, hh, radius)
            M.blendPixel(bb, px, py, half_t + 0.5 - math.abs(d), x0, y0, x1, y1)
        end
    end
end

return M
