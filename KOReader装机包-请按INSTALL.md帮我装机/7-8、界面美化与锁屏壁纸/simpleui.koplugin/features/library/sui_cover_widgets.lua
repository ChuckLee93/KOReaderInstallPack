-- sui_cover_widgets.lua — Simple UI
-- Pure rendering code for folder/book cover decoration: the progress
-- pentagon, the "New" corner ribbon, rounded-rectangle badges (pages,
-- series index, "New"), the book spine, the folder-name label overlay,
-- the book-count circle badge, and 2×2 quad-cover assembly.
--
-- Nothing here reads settings or touches FileChooser/MosaicMenuItem —
-- every function takes the values it needs as parameters. sui_foldercovers.lua
-- reads settings once per update()/paintTo() cycle and passes them in. This
-- means every function below can be exercised and reasoned about in
-- isolation from the settings system and the monkeypatch machinery.
--
-- The only per-item state kept here is the font-size cache used by
-- buildFolderNameWidget (binary-searching the largest font that fits a
-- folder name is not cheap, so results are cached) and the rendered-ribbon
-- Blitbuffer cache (rotating text pixel-by-pixel is expensive, cached by
-- dimensions+label+colors). Both are cleared via the public clear*Cache()
-- functions, which sui_foldercovers.lua calls from M.invalidateCache().
--
-- Public API
-- ----------
--   CoverWidgets.buildProgressBadgeDesc(eff_size, status, percent_finished, border, dark)
--   CoverWidgets.drawProgressBadge(bb, ox, oy, desc)
--   CoverWidgets.buildProgressBadgeWidget(desc)
--       -- Widget wrapper (getSize/paintTo) around drawProgressBadge, for
--       -- consumers that need it embedded in an OverlapGroup rather than
--       -- painted directly onto a Blitbuffer — see engines/sui_book_grid.lua.
--   CoverWidgets.paintCornerRibbon(bb, cover_left, cover_right, cover_top, cover_h,
--                                  span, band_thick, label, font_sz, dark)
--   CoverWidgets.buildCornerRibbonWidget(cw, ch, dark, badge_scale, label)
--       -- Widget wrapper (getSize/paintTo) around paintCornerRibbon, for the
--       -- same reason buildProgressBadgeWidget exists — see
--       -- engines/sui_book_grid.lua's "New" badge, mode = "ribbon".
--   CoverWidgets.buildRectBadgeWidget(text, bold, cell_min, dark, new_badge, badge_scale)
--   CoverWidgets.buildSpine(img_h)
--   CoverWidgets.buildFolderNameWidget(item, available_w, max_font_size, fgcolor, bgcolor)
--   CoverWidgets.buildLabel(item, available_w, size, border, cv_scale, display, spine_w)
--       -- display: { label_mode, show_name, label_style, label_pos, label_color, label_scale }
--   CoverWidgets.buildBadge(mandatory, cover_dimen, cv_scale, cell_dimen, opts)
--       -- opts: { hidden, scale, dark, position }  ("bottom" | anything else = top)
--   CoverWidgets.computeCellGeometry(item, hide_spine)
--   CoverWidgets.assembleCoverWidget(item, content_widget, size, border, spine_w, display)
--   CoverWidgets.buildQuadGrid(img_list, w, h, border)
--       -- Pure 2×2 cover collage, no spine/label/badge/assembly — reusable
--       -- outside the library's mosaic context (e.g. module_collections.lua).
--   CoverWidgets.buildQuadCover(item, img_list, border, spine_w, max_img_w, max_img_h, display)
--       -- Wraps buildQuadGrid with assembleCoverWidget (mosaic's spine/label/badge).
--   CoverWidgets.installWidget(item, widget)
--   CoverWidgets.clearRibbonCache()
--   CoverWidgets.clearFontSizeCache()

local _  = require("infra/sui_i18n").translate
local BD = require("ui/bidi")

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local Screen          = require("device").screen
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local AlphaContainer  = require("ui/widget/container/alphacontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local TopContainer    = require("ui/widget/container/topcontainer")
local RightContainer  = require("ui/widget/container/rightcontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local SUIStyle        = require("features/sui_style")

local CoverWidgets = {}

-- ---------------------------------------------------------------------------
-- Shared geometry constants
-- ---------------------------------------------------------------------------

local _BASE_COVER_H = math.floor(Screen:scaleBySize(96))
local _BASE_DIR_FS  = SUIStyle.FS_SUBTITLE -- 20: directory name label ceiling for binary-search

local _EDGE_THICK  = math.max(1, Screen:scaleBySize(3))
local _EDGE_MARGIN = math.max(1, Screen:scaleBySize(1))
local _SPINE_W     = _EDGE_THICK * 2 + _EDGE_MARGIN * 2

local _LATERAL_PAD         = Screen:scaleBySize(10)
local _VERTICAL_PAD        = Screen:scaleBySize(4)
local _BADGE_MARGIN_BASE   = Screen:scaleBySize(8)
local _BADGE_MARGIN_R_BASE = Screen:scaleBySize(4)

local _LABEL_ALPHA = 0.75

-- ── Progress pentagon badge ──────────────────────────────────────────────────
-- Drawn directly onto the cover Blitbuffer (no intermediate buffer) so pixels
-- outside the pentagon are never written and the cover art shows through the
-- triangular tip without a white rectangle artefact.
--
-- Shape: downward-pointing pentagon (rectangle body + triangular tip).
-- States: "complete" → checkmark; percent_finished set → "42%"; otherwise bare.

local function pentagonPaintRect(bb, bx, by, bw, bh, color)
    local rect_h = math.floor(bh * 30 / 42)
    local tip_h  = bh - rect_h
    bb:paintRect(bx, by, bw, rect_h, color)
    for row = 0, tip_h - 1 do
        local frac = (row + 1) / tip_h
        local rw   = math.max(2, math.floor(bw * (1 - frac)))
        local rx   = bx + math.floor((bw - rw) / 2)
        bb:paintRect(rx, by + rect_h + row, rw, 1, color)
    end
end

local function drawCheckLine(bb, x0, y0, x1, y1, tk, color)
    local steps = math.max(math.abs(x1 - x0), math.abs(y1 - y0))
    if steps == 0 then steps = 1 end
    for i = 0, steps do
        local t = i / steps
        bb:paintRect(
            math.floor(x0 + t * (x1 - x0)),
            math.floor(y0 + t * (y1 - y0)),
            tk, tk, color)
    end
end

local function pentagonPaintCheck(bb, bx, by, bw, bh, color)
    local tk = math.max(2, math.floor(math.min(bw, bh) / 8))
    local lx0 = bx + math.floor(bw * 0.08); local ly0 = by + math.floor(bh * 0.62)
    local lx1 = bx + math.floor(bw * 0.30); local ly1 = by + math.floor(bh * 0.82)
    local rx1  = bx + math.floor(bw * 0.82); local ry1 = by + math.floor(bh * 0.18)
    drawCheckLine(bb, lx0, ly0, lx1, ly1, tk, color)
    drawCheckLine(bb, lx1, ly1, rx1, ry1, tk, color)
end

-- Returns a descriptor table for the progress badge, or nil when too small.
-- No Blitbuffer is allocated here — drawing is deferred to paintTo().
function CoverWidgets.buildProgressBadgeDesc(eff_size, status, percent_finished, border, dark)
    local bw = math.floor(eff_size * 1.3)
    local bh = math.floor(eff_size * 1.4)
    if bw < 4 or bh < 4 then return nil end

    local text_color  = dark and SUIStyle.COLOR.surface or SUIStyle.COLOR.text_primary
    local text_widget = nil

    if status == "abandoned" then
        local font_sz = math.max(7, math.floor(eff_size * 0.26))
        text_widget = TextWidget:new{
            text    = "\u{EAE3}",
            face    = Font:getFace(SUIStyle.FACE_ICONS, font_sz),
            bold    = false,
            fgcolor = text_color,
            padding = 0,
        }
    elseif percent_finished ~= nil and status ~= "complete" then
        local pct     = math.floor(percent_finished * 100 + 0.5)
        local font_sz = math.max(7, math.floor(eff_size * 0.26))
        text_widget = TextWidget:new{
            text    = pct .. "%",
            face    = Font:getFace(SUIStyle.FACE_REGULAR, font_sz),
            bold    = true,
            fgcolor = text_color,
            padding = 0,
        }
    end

    return {
        bw               = bw,
        bh               = bh,
        border           = border or SUIStyle.BADGE_BORDER_SZ,
        status           = status,
        percent_finished = percent_finished,
        eff_size         = eff_size,
        dark             = dark ~= false,
        text_widget      = text_widget,
    }
end

-- Draw the progress badge described by `desc` directly onto `bb` at (ox, oy).
function CoverWidgets.drawProgressBadge(bb, ox, oy, desc)
    local bw         = desc.bw
    local bh         = desc.bh
    local fr         = desc.border
    local fill_color = desc.dark and SUIStyle.COLOR.text_primary or SUIStyle.COLOR.surface
    local text_color = desc.dark and SUIStyle.COLOR.surface or SUIStyle.COLOR.text_primary
    local brd_color  = SUIStyle.BADGE_BORDER_CLR

    pentagonPaintRect(bb, ox,      oy,      bw + 2 * fr, bh + 2 * fr, brd_color)
    pentagonPaintRect(bb, ox + fr, oy + fr, bw,          bh,          fill_color)

    local rect_h     = math.floor(bh * 30 / 42)
    local pad_x      = math.floor(bw * 0.12)
    local pad_y      = math.floor(rect_h * 0.25)
    local icon_x     = ox + fr + pad_x
    local icon_y     = oy + fr + pad_y
    local icon_w     = bw - 2 * pad_x
    local icon_h     = rect_h - 2 * pad_y
    -- Shift content downward for visual balance with the triangular tip below.
    local text_y_offset = math.floor(rect_h * 0.15)

    if desc.status == "complete" then
        local sq   = math.min(icon_w, icon_h)
        local sq_x = icon_x + math.floor((icon_w - sq) / 2)
        local sq_y = oy + fr + math.floor((rect_h - sq) / 2) + text_y_offset
        pentagonPaintCheck(bb, sq_x, sq_y, sq, sq, text_color)
    elseif desc.status == "abandoned" then
        if desc.text_widget then
            local aw_sz = desc.text_widget:getSize()
            desc.text_widget:paintTo(bb,
                ox + fr + math.floor((bw     - aw_sz.w) / 2),
                oy + fr + math.floor((rect_h - aw_sz.h) / 2) + text_y_offset)
        end
    elseif desc.percent_finished ~= nil then
        if desc.text_widget then
            local tw_sz = desc.text_widget:getSize()
            desc.text_widget:paintTo(bb,
                ox + fr + math.floor((bw     - tw_sz.w) / 2),
                oy + fr + math.floor((rect_h - tw_sz.h) / 2) + text_y_offset)
        end
    end
    -- "not started": bare pentagon, no content drawn.
end

-- Widget wrapper around buildProgressBadgeDesc/drawProgressBadge, for
-- consumers that build a widget tree (OverlapGroup) instead of overriding
-- MosaicMenuItem:paintTo() directly (e.g. engines/sui_book_grid.lua's
-- GridRenderer cells). getSize()/paintTo() are enough to be laid out and
-- painted by a Group/OverlapGroup — the actual drawing still goes through
-- drawProgressBadge, so there is exactly one place that knows how to paint
-- the pentagon — but a no-op handleEvent() is also required below, since
-- this can end up nested inside an interactive (tappable) tree, not just a
-- passive one.
-- Returns nil when desc is nil (mirrors buildProgressBadgeDesc's own
-- "too small" guard).
local ProgressBadgeWidget = {}
ProgressBadgeWidget.__index = ProgressBadgeWidget

function ProgressBadgeWidget:getSize()
    local fr = self.desc.border
    return Geom:new{ w = self.desc.bw + 2 * fr, h = self.desc.bh + 2 * fr }
end

function ProgressBadgeWidget:paintTo(bb, x, y)
    CoverWidgets.drawProgressBadge(bb, x, y, self.desc)
end

-- getSize()/paintTo() are enough for a Group/OverlapGroup to lay this out
-- and paint it, but this badge can also end up nested inside an
-- interactive tree (sui_book_grid.lua wraps the cover -- badges included --
-- in a tappable InputContainer). WidgetContainer:propagateEvent() calls
-- `child:handleEvent(event)` unconditionally on every child while walking
-- down to find a gesture handler, with no existence check first, so a bare
-- table without this method crashes with "attempt to call method
-- 'handleEvent' (a nil value)" the moment a gesture is routed through it.
-- This badge never wants to consume events itself, so just decline and let
-- propagation continue elsewhere.
function ProgressBadgeWidget:handleEvent()
    return false
end

function CoverWidgets.buildProgressBadgeWidget(desc)
    if not desc then return nil end
    return setmetatable({ desc = desc }, ProgressBadgeWidget)
end

-- ── Corner ribbon ("New" style) ───────────────────────────────────────────
-- Paints a diagonal band across the top-right corner of the cover Blitbuffer
-- at 45°, with the label text rotated inside it.
--
-- Strategy: build a temp Blitbuffer (tw × band_thick) in axis-aligned space,
-- render border + fill + text into it once, then use a destination-driven
-- inverse-map loop to blit each screen pixel from the rotated source.
-- The result is cached by (dimensions, label, colors) so the per-pixel loop
-- only runs once per unique configuration, not once per cover.

local _ribbon_bb_cache = {}

function CoverWidgets.clearRibbonCache()
    for k, buf in pairs(_ribbon_bb_cache) do
        if buf and buf.free then buf:free() end
        _ribbon_bb_cache[k] = nil
    end
end

function CoverWidgets.paintCornerRibbon(bb, cover_left, cover_right, cover_top, cover_h,
                                        span, band_thick, label, font_sz, dark)
    local C = 0.70711  -- cos 45° = sin 45°

    -- Buffer width: (span + 2*band) * √2 so the ribbon ends protrude past both
    -- cover edges; the cover-bounds clipping hides the end-cuts cleanly.
    local tw = math.ceil((span + band_thick * 2) * 1.41422)
    local th = band_thick
    if tw <= 0 or th <= 0 then return end

    local bg  = dark and SUIStyle.COLOR.text_primary or SUIStyle.COLOR.surface
    local fg  = dark and SUIStyle.COLOR.surface or SUIStyle.COLOR.text_primary
    local brd = SUIStyle.BADGE_BORDER_CLR

    local cache_key = string.format("%d|%d|%d|%s|%d|%d|%s|%s",
        tw, th, bb:getType(), label, font_sz, dark and 1 or 0, tostring(SUIStyle.BADGE_BORDER_SZ), tostring(brd))
    local tmp = _ribbon_bb_cache[cache_key]

    if not tmp then
        tmp = Blitbuffer.new(tw, th, bb:getType())
        if not tmp then return end

        -- 1-px border on long edges, bg interior.
        local bw = SUIStyle.BADGE_BORDER_SZ
        tmp:paintRect(0, 0, tw, th, brd)
        if bw * 2 < th then
            tmp:paintRect(0, bw, tw, th - bw * 2, bg)
        end

        -- Render label; step font down 1pt at a time until it fits, min 6pt.
        local inner_h = math.max(1, th - bw * 2)
        local max_w   = math.floor(tw * 0.82)
        local lbl, lsz
        local fs = font_sz
        repeat
            if lbl and lbl.free then lbl:free() end
            lbl = TextWidget:new{
                text    = label,
                face    = Font:getFace(SUIStyle.FACE_REGULAR, fs),
                bold    = true,
                fgcolor = fg,
                padding = 0,
            }
            lsz = lbl:getSize()
            if lsz.w <= max_w and lsz.h <= inner_h then break end
            fs = fs - 1
        until fs < 6
        local lx = math.max(0, math.floor((tw - lsz.w) / 2))
        local ly = math.max(0, math.floor((th - lsz.h) / 2))
        lbl:paintTo(tmp, lx, ly)
        if lbl.free then lbl:free() end

        _ribbon_bb_cache[cache_key] = tmp
    end

    -- Destination-driven inverse-map: for each screen pixel in the ribbon's
    -- bounding box, reverse-rotate 45° to find the source pixel in tmp.
    local cx       = cover_right - math.floor(span / 2)
    local cy       = cover_top   + math.floor(span / 2)
    local half_box = math.ceil((tw + th) * C / 2) + 1
    local bb_w     = bb:getWidth()
    local bb_h     = bb:getHeight()
    local tw_half  = tw / 2
    local th_half  = th / 2
    for dy = cy - half_box, cy + half_box do
        if dy >= cover_top and dy < cover_top + cover_h and dy >= 0 and dy < bb_h then
            local dy_rel = dy - cy
            for dx = cx - half_box, cx + half_box do
                if dx >= cover_left and dx < cover_right and dx >= 0 and dx < bb_w then
                    local dx_rel = dx - cx
                    -- Inverse of +45° rotation (top-right "\" band).
                    local sx = math.floor(tw_half + (dx_rel + dy_rel) * C)
                    local sy = math.floor(th_half + (dy_rel - dx_rel) * C)
                    if sx >= 0 and sx < tw and sy >= 0 and sy < th then
                        bb:setPixel(dx, dy, tmp:getPixel(sx, sy))
                    end
                end
            end
        end
    end
end

-- Widget wrapper around paintCornerRibbon, for the same reason
-- ProgressBadgeWidget exists above: engines/sui_book_grid.lua builds a
-- widget tree (OverlapGroup) instead of overriding MosaicMenuItem:paintTo()
-- directly like sui_foldercovers.lua does, so the ribbon needs a
-- getSize()/paintTo()/handleEvent() shell rather than being painted
-- straight onto an already-known bb/x/y/fw/fh.
--
-- Unlike the rounded-rect badges (which are a small widget placed at a
-- corner offset via overlap_offset), the ribbon has no bounding box of its
-- own — it's a diagonal band drawn across the cover's top-right corner
-- REGION. So this widget's getSize() reports the *entire* cover size
-- (cw × ch) and it must be the OverlapGroup's full-size layer, not offset —
-- callers add it to the overlap group directly, without an overlap_offset,
-- same as cover_widget itself.
--
-- This intentionally skips the Library grid's "repaint the border edges
-- over the ribbon" step (see sui_foldercovers.lua) — that step exists to
-- restore the Library thumbnail's own persistent 1px frame where the ribbon
-- crosses it, but book-grid covers here (engines/sui_book_grid.lua) aren't
-- bordered the same way, so there is no border to restore.
local CornerRibbonWidget = {}
CornerRibbonWidget.__index = CornerRibbonWidget

function CornerRibbonWidget:getSize()
    return Geom:new{ w = self.cw, h = self.ch }
end

function CornerRibbonWidget:paintTo(bb, x, y)
    CoverWidgets.paintCornerRibbon(bb, x, x + self.cw, y, self.ch,
        self.span, self.band_thick, self.label, self.font_sz, self.dark)
end

-- See ProgressBadgeWidget:handleEvent() above for why this is required —
-- same crash, same fix, same reasoning.
function CornerRibbonWidget:handleEvent()
    return false
end

-- cw/ch: full cover size, NOT an offset/inset — see the class doc comment
-- above for why. span/band_thick/font_sz derivation copied verbatim from
-- sui_foldercovers.lua's ribbon call site so both grids draw an
-- identically-proportioned ribbon for the same cover size.
function CoverWidgets.buildCornerRibbonWidget(cw, ch, dark, badge_scale, label)
    if cw < 4 or ch < 4 then return nil end
    local cell_min   = math.min(cw, ch)
    local eff_size   = math.max(8, math.floor(cell_min * 0.1694 * (badge_scale or 1.0)))
    local span       = math.floor(eff_size * 2.5)
    local band_thick = math.floor(span * 0.40)
    local font_sz    = math.max(7, math.floor(eff_size * 0.26))
    return setmetatable({
        cw = cw, ch = ch, dark = dark,
        span = span, band_thick = band_thick,
        font_sz = font_sz, label = label or _("New"),
    }, CornerRibbonWidget)
end

function CoverWidgets.buildRectBadgeWidget(text, bold, cell_min, dark, new_badge, badge_scale)
    badge_scale = badge_scale or 1.0
    local eff_size = math.max(8, math.floor((cell_min or 40) * 0.15 * badge_scale))
    local font_sz  = math.max(7, math.floor(eff_size * 0.24))
    local pad_h    = math.max(1, math.floor(eff_size * 0.10))
    local pad_v    = math.max(1, math.floor(eff_size * 0.06))
    local corner   = math.max(1, math.floor(eff_size * 0.08))
    local border   = SUIStyle.BADGE_BORDER_SZ

    local bg = dark and SUIStyle.COLOR.text_primary or SUIStyle.COLOR.surface
    local fg = dark and SUIStyle.COLOR.surface or SUIStyle.COLOR.text_primary
    local border_color = SUIStyle.BADGE_BORDER_CLR

    local tw = TextWidget:new{
        text    = text,
        face    = Font:getFace(SUIStyle.FACE_REGULAR, font_sz),
        bold    = bold or false,
        fgcolor = fg,
        padding = 0,
    }
    local tsz    = tw:getSize()
    local lateral = pad_h * 4
    local inner_h = tsz.h + pad_v * 2
    -- Enforce a square minimum so short labels like "#1" are not tiny slivers.
    local inner_w = math.max(tsz.w + lateral, inner_h)
    local w = inner_w + border * 2
    local h = inner_h + border * 2
    if w < 4 or h < 4 then tw:free(); return nil end

    return FrameContainer:new{
        dimen      = Geom:new{ w = w, h = h },
        bordersize = border,
        color      = border_color,
        background = bg,
        radius     = corner,
        padding    = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            tw,
        },
    }
end

-- ── Book spine decoration ─────────────────────────────────────────────────────

function CoverWidgets.buildSpine(img_h)
    local h1 = math.floor(img_h * 0.97)
    local h2 = math.floor(img_h * 0.94)
    local y1 = math.floor((img_h - h1) / 2)
    local y2 = math.floor((img_h - h2) / 2)

    local function spineLine(h, y_off)
        local line = LineWidget:new{
            dimen      = Geom:new{ w = _EDGE_THICK, h = h },
            background = SUIStyle.COLOR.gray,
        }
        line.overlap_offset = { 0, y_off }
        return OverlapGroup:new{ dimen = Geom:new{ w = _EDGE_THICK, h = img_h }, line }
    end

    return HorizontalGroup:new{
        align = "center",
        spineLine(h2, y2),
        HorizontalSpan:new{ width = _EDGE_MARGIN },
        spineLine(h1, y1),
        HorizontalSpan:new{ width = _EDGE_MARGIN },
    }
end

-- ── Folder-name label overlay ─────────────────────────────────────────────────

-- Binary-search the largest font size where the folder name fits in two
-- lines within available_w. Result cached by text+width+max_fs.
-- Capitalises the first letter of each word.
--
-- Two-generation LRU cache pattern (generation A active, B previous; on
-- overflow B=A, A={} — effective capacity 2×MAX).
local _FS_CACHE_MAX   = 200
local _fs_cache_a     = {}
local _fs_cache_b     = {}
local _fs_cache_a_cnt = 0

local function fsCacheGet(key) return _fs_cache_a[key] or _fs_cache_b[key] end
local function fsCacheSet(key, value)
    if _fs_cache_a_cnt >= _FS_CACHE_MAX then
        _fs_cache_b     = _fs_cache_a
        _fs_cache_a     = {}
        _fs_cache_a_cnt = 0
    end
    _fs_cache_a[key] = value
    _fs_cache_a_cnt  = _fs_cache_a_cnt + 1
end

function CoverWidgets.clearFontSizeCache()
    _fs_cache_a, _fs_cache_b, _fs_cache_a_cnt = {}, {}, 0
end

-- `item` needs only `.text` and a writable `._fc_display_text` cache slot
-- (any table works — sui_foldercovers.lua passes the MosaicMenuItem instance
-- so the capitalised/bidi-wrapped text is computed once per item, not once
-- per render).
function CoverWidgets.buildFolderNameWidget(item, available_w, dir_max_font_size, fgcolor, bgcolor)
    if not item._fc_display_text then
        local text = item.text
        if text:match("/$") then text = text:sub(1, -2) end
        text = text:gsub("(%S+)", function(w) return w:sub(1,1):upper() .. w:sub(2) end)
        item._fc_display_text = BD.directory(text)
    end
    local text      = item._fc_display_text
    local max_fs    = dir_max_font_size or _BASE_DIR_FS
    local cache_key = text .. "\0" .. available_w .. "\0" .. max_fs
    local fg        = fgcolor or SUIStyle.COLOR.text_primary
    local bg        = bgcolor or SUIStyle.COLOR.surface

    local cached_fs = fsCacheGet(cache_key)
    if cached_fs then
        return TextBoxWidget:new{
            text      = text,
            face      = Font:getFace(SUIStyle.FACE_REGULAR, cached_fs),
            width     = available_w,
            alignment = "center",
            bold      = true,
            fgcolor   = fg,
            bgcolor   = bg,
        }
    end

    -- Pass 1: binary-search largest font where the longest word fits.
    local longest_word = ""
    for word in text:gmatch("%S+") do
        if #word > #longest_word then longest_word = word end
    end

    local dir_font_size = max_fs

    if longest_word ~= "" then
        local lo, hi = 10, dir_font_size
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            local tw = TextWidget:new{
                text = longest_word,
                face = Font:getFace(SUIStyle.FACE_REGULAR, mid),
                bold = true,
            }
            local word_w = tw:getWidth()
            tw:free()
            if word_w <= available_w then lo = mid else hi = mid - 1 end
        end
        dir_font_size = lo
    end

    -- Pass 2: binary-search largest font where the full text fits in two lines.
    -- Pass 1 narrows the range, minimising TextBoxWidget allocations.
    local lo, hi = 10, dir_font_size
    while lo < hi do
        local mid  = math.floor((lo + hi + 1) / 2)
        local fits = false
        local ok, tbw = pcall(function()
            return TextBoxWidget:new{
                text      = text,
                face      = Font:getFace(SUIStyle.FACE_REGULAR, mid),
                width     = available_w,
                alignment = "center",
                bold      = true,
            }
        end)
        if ok and tbw then
            fits = tbw:getSize().h <= tbw:getLineHeight() * 2.2
            tbw:free(true)
        end
        if fits then lo = mid else hi = mid - 1 end
    end
    dir_font_size = lo

    fsCacheSet(cache_key, dir_font_size)

    return TextBoxWidget:new{
        text      = text,
        face      = Font:getFace(SUIStyle.FACE_REGULAR, dir_font_size),
        width     = available_w,
        alignment = "center",
        bold      = true,
        fgcolor   = fg,
        bgcolor   = bg,
    }
end

-- Returns the overlay label widget, or nil when disabled.
-- `display` is the pre-read settings table:
--   { label_mode, show_name, label_style, label_pos, label_color, label_scale }
function CoverWidgets.buildLabel(item, available_w, size, border, cv_scale, display, spine_w)
    if display.label_mode ~= "overlay" then return nil end
    if not display.show_name            then return nil end
    local label_style = display.label_style
    local label_pos   = display.label_pos
    local dark        = display.label_color == "dark"
    local bg_color    = dark and SUIStyle.COLOR.text_primary or SUIStyle.COLOR.surface
    local fg_color    = dark and SUIStyle.COLOR.surface or SUIStyle.COLOR.text_primary

    local dir_max_fs = math.max(8, math.floor(_BASE_DIR_FS * (display.label_scale or 1.0)))
    local directory  = CoverWidgets.buildFolderNameWidget(item, available_w, dir_max_fs, fg_color, bg_color)
    local img_only   = Geom:new{ w = size.w, h = size.h }
    local img_dimen  = Geom:new{ w = size.w + border * 2, h = size.h + border * 2 }

    local frame = FrameContainer:new{
        padding        = 0,
        padding_top    = _VERTICAL_PAD,
        padding_bottom = _VERTICAL_PAD,
        padding_left   = _LATERAL_PAD,
        padding_right  = _LATERAL_PAD,
        bordersize     = border,
        background     = bg_color,
        directory,
    }

    local label_inner
    if label_style == "alpha" then
        label_inner = AlphaContainer:new{ alpha = _LABEL_ALPHA, frame }
    else
        label_inner = frame
    end

    local name_og = OverlapGroup:new{ dimen = img_dimen }

    if label_pos == "center" then
        name_og[1] = CenterContainer:new{ dimen = img_only, label_inner, overlap_align = "center" }
    elseif label_pos == "top" then
        name_og[1] = TopContainer:new{ dimen = img_dimen, label_inner, overlap_align = "center" }
    else
        name_og[1] = BottomContainer:new{ dimen = img_dimen, label_inner, overlap_align = "center" }
    end

    name_og.overlap_offset = { spine_w or _SPINE_W, 0 }
    return name_og
end

-- ── Folder book-count badge (circle) ─────────────────────────────────────────

-- `cell_dimen` is the full mosaic cell (used for sizing); when absent,
-- cover_dimen is used instead (produces a smaller badge).
-- `opts`: { hidden, scale, dark, position }  (position: "bottom" | top-default)
function CoverWidgets.buildBadge(mandatory, cover_dimen, cv_scale, cell_dimen, opts)
    opts = opts or {}
    if opts.hidden then return nil end
    local nb_text = mandatory and mandatory:match("(%d+) \u{F016}") or ""
    if nb_text == "" or nb_text == "0" then return nil end

    local badge_scale    = opts.scale or 1.0
    local nb_count       = tonumber(nb_text)
    local size_dimen     = cell_dimen or cover_dimen
    local cell_min       = math.min(size_dimen.w, size_dimen.h)
    local nb_size        = math.max(8, math.floor(cell_min * 0.13 * badge_scale))
    local nb_font_size   = math.max(7, math.floor(nb_size * 0.28))
    local badge_margin   = math.max(1, math.floor(_BADGE_MARGIN_BASE   * cv_scale))
    local badge_margin_r = math.max(1, math.floor(_BADGE_MARGIN_R_BASE * cv_scale))
    local dark           = opts.dark
    local bg_color       = dark and SUIStyle.COLOR.text_primary or SUIStyle.COLOR.surface
    local fg_color       = dark and SUIStyle.COLOR.surface or SUIStyle.COLOR.text_primary
    local border_color   = SUIStyle.BADGE_BORDER_CLR

    local badge = FrameContainer:new{
        padding    = 0,
        bordersize = SUIStyle.BADGE_BORDER_SZ,
        color      = border_color,
        background = bg_color,
        radius     = math.floor(nb_size / 2),
        dimen      = Geom:new{ w = nb_size, h = nb_size },
        CenterContainer:new{
            dimen = Geom:new{ w = nb_size - 2 * SUIStyle.BADGE_BORDER_SZ, h = nb_size - 2 * SUIStyle.BADGE_BORDER_SZ },
            (function()
                local tw = TextWidget:new{
                    text    = tostring(math.min(nb_count, 99)),
                    face    = Font:getFace(SUIStyle.FACE_REGULAR, nb_font_size),
                    fgcolor = fg_color,
                    bold    = true,
                }
                local _orig_pt = tw.paintTo
                tw.paintTo = function(self, bb, x, y)
                    _orig_pt(self, bb, x, y + 1) -- HACK: Change this +1 to the required value
                end
                return tw
            end)(),
        },
    }

    local inner = RightContainer:new{
        dimen = Geom:new{ w = cover_dimen.w, h = nb_size + badge_margin },
        FrameContainer:new{
            padding       = 0,
            padding_right = badge_margin_r,
            bordersize    = 0,
            badge,
        },
    }

    if opts.position == "bottom" then
        return BottomContainer:new{
            dimen          = cover_dimen,
            padding_bottom = badge_margin,
            inner,
            overlap_align  = "center",
        }
    else
        return TopContainer:new{
            dimen         = cover_dimen,
            padding_top   = badge_margin,
            inner,
            overlap_align = "center",
        }
    end
end

-- ── Shared geometry helper ────────────────────────────────────────────────────

-- Computes the five values every cover-building function needs.
-- self.height is already reduced by _STRIP_H in sui_foldercovers.lua's
-- update() wrapper before this is called, so it must NOT be subtracted again.
function CoverWidgets.computeCellGeometry(item, hide_spine)
    local border  = SUIStyle.BADGE_BORDER_SZ
    local spine_w = not hide_spine and _SPINE_W or 0
    local max_img_w = item.width  - spine_w - border * 2
    local max_img_h = item.height - border * 2
    return border, spine_w, max_img_w, max_img_h
end

-- ── Cover assembly helper ─────────────────────────────────────────────────────

-- Wraps any pre-built content_widget with the spine, centres it in the mosaic
-- cell, and overlays the folder-name label and item-count badge.
-- cv_scale is derived from cover_h here so callers don't have to compute it.
-- Must be defined before buildQuadCover, which calls it.
function CoverWidgets.assembleCoverWidget(item, content_widget, size, border, spine_w, display)
    local spine       = spine_w > 0 and CoverWidgets.buildSpine(size.h) or nil
    local cover_group = spine
        and HorizontalGroup:new{ align = "center", spine, content_widget }
        or  HorizontalGroup:new{ align = "center", content_widget }

    local cover_w     = spine_w + size.w + border * 2
    local cover_h     = size.h  + border * 2
    local cover_dimen = Geom:new{ w = cover_w, h = cover_h }
    local cell_dimen  = Geom:new{ w = item.width, h = item.height }
    local cv_scale    = math.max(0.1, math.floor((cover_h / _BASE_COVER_H) * 10) / 10)

    local folder_name_widget = CoverWidgets.buildLabel(item, size.w - _LATERAL_PAD * 2,
        size, border, cv_scale, display, spine_w)
    local nbitems_widget = CoverWidgets.buildBadge(item.mandatory, cover_dimen, cv_scale, cell_dimen, display.badge)

    local overlap = OverlapGroup:new{ dimen = cover_dimen, cover_group }
    if folder_name_widget then overlap[#overlap + 1] = folder_name_widget end
    if nbitems_widget     then overlap[#overlap + 1] = nbitems_widget     end

    local x_center = math.floor((item.width  - cover_w) / 2)
    local y_center = math.floor((item.height - cover_h) / 2)
    overlap.overlap_offset = { x_center - math.floor(spine_w / 2), y_center }

    return OverlapGroup:new{ dimen = cell_dimen, overlap }
end

-- Mark the cell as processed, free the previous widget, and assign the new one.
function CoverWidgets.installWidget(item, widget)
    item._foldercover_processed = true
    if item._underline_container[1] then item._underline_container[1]:free() end
    item._underline_container[1] = widget
end

-- ── 2×2 quad cover ───────────────────────────────────────────────────────────

-- Pure 2×2 grid geometry: dimensions of the 4 quadrants (the 2nd/4th can
-- be 1px larger than the 1st/3rd when w-sep or h-sep is odd) and the
-- separator's thickness. Extracted so that anyone who needs to preload a cover
-- already at the exact size of each quadrant (e.g. Config.getCoverBB) can do so
-- without duplicating this calculation — see module_collections.lua ("Cover Style: Quad").
function CoverWidgets.computeQuadCellSizes(w, h)
    local sep = math.max(1, Screen:scaleBySize(1))
    local half_w  = math.floor((w - sep) / 2)
    local half_w2 = w - sep - half_w
    local half_h  = math.floor((h - sep) / 2)
    local half_h2 = h - sep - half_h
    return half_w, half_h, half_w2, half_h2, sep
end

-- Pure 2×2 cover collage: 4 images (or empty-fill placeholders) separated by
-- thin lines, wrapped in a bordered FrameContainer of exactly w×h. No spine,
-- no label, no badge, no dependency on a mosaic `item`/`display` — safe to
-- call from any context that just wants a quad-cover thumbnail of a given
-- size (e.g. module_collections.lua's "Cover Style: Quad").
--
-- img_list: up to 4 entries, each { file = <path> } or { data = <blitbuffer> }.
--           Missing/nil entries render as an empty (white) slot so the
--           separator lines stay visible instead of the grid collapsing.
-- Returns:
--   1. FrameContainer widget, sized w×h (including border).
--   2. cells: array of the 4 CenterContainer quadrants (each cells[i][1] is
--      the current ImageWidget/placeholder) — callers that need to swap a
--      cover in later (async cache poll) can assign cells[i][1] directly.
function CoverWidgets.buildQuadGrid(img_list, w, h, border)
    local half_w, half_h, half_w2, half_h2, sep = CoverWidgets.computeQuadCellSizes(w, h)

    local cells = {}
    for i = 1, 4 do
        local c  = img_list[i]
        local cw = (i == 1 or i == 3) and half_w or half_w2
        local ch = (i == 1 or i == 2) and half_h or half_h2
        if c then
            local img_opts = { width = cw, height = ch }
            if c.file  then img_opts.file  = c.file  end
            -- c.data is a bitmap owned by Config's cover cache (already
            -- pre-scaled to exactly cw×ch by Config.getCoverBB, so
            -- ImageWidget won't need to re-render it and will otherwise
            -- free the cache's own buffer on widget teardown — see
            -- module_collections.lua's getBookCover for the same guard).
            if c.data  then
                img_opts.image            = c.data
                img_opts.image_disposable = false
            end
            cells[i] = CenterContainer:new{
                dimen = Geom:new{ w = cw, h = ch },
                ImageWidget:new(img_opts),
            }
        else
            -- Empty slot: white fill keeps separator lines visible.
            -- A child widget is required so FrameContainer:getSize() doesn't crash.
            cells[i] = CenterContainer:new{
                dimen = Geom:new{ w = cw, h = ch },
                VerticalSpan:new{ width = 1 },
            }
        end
    end

    local sep_color = SUIStyle.COLOR.gray_soft
    local grid = FrameContainer:new{
        padding    = 0,
        bordersize = border,
        VerticalGroup:new{
            HorizontalGroup:new{
                cells[1],
                LineWidget:new{ background = sep_color, dimen = Geom:new{ w = sep, h = half_h } },
                cells[2],
            },
            LineWidget:new{ background = sep_color, dimen = Geom:new{ w = w, h = sep } },
            HorizontalGroup:new{
                cells[3],
                LineWidget:new{ background = sep_color, dimen = Geom:new{ w = sep, h = half_h2 } },
                cells[4],
            },
        },
    }
    return grid, cells
end

-- Returns the OverlapGroup widget for the 2×2 grid assembled into a mosaic
-- cell (spine + folder-name label + item-count badge), or nil when no covers
-- are available. Defined after assembleCoverWidget (which it calls).
function CoverWidgets.buildQuadCover(item, img_list, border, spine_w, max_img_w, max_img_h, display)
    local ratio = 2 / 3
    local img_w, img_h
    if max_img_w / max_img_h > ratio then
        img_h = max_img_h; img_w = math.floor(max_img_h * ratio)
    else
        img_w = max_img_w; img_h = math.floor(max_img_w / ratio)
    end

    local grid = CoverWidgets.buildQuadGrid(img_list, img_w, img_h, border)

    local size = Geom:new{ w = img_w, h = img_h }
    return CoverWidgets.assembleCoverWidget(item, grid, size, border, spine_w, display)
end

return CoverWidgets
