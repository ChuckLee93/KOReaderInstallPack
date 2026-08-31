-- sui_heatmap_popup.lua — Simple UI
-- Full-screen reading heatmap: the calendar grid and the day-part grid,
-- together, for a fixed-size block of weeks that can be paged back through
-- history. Opened by tapping the homescreen heatmap card
-- (modules/module_heatmap.lua) — this file has no homescreen ties of its
-- own, so it can be opened from anywhere (e.g. a future menu entry) too.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local _ = require("infra/sui_i18n").translate

local Config   = require("infra/sui_config")
local UI       = require("infra/sui_core")
local SUIStyle = require("features/sui_style")
local HD       = require("engines/sui_heatmap_data")
local HW       = require("engines/sui_heatmap_widgets")

-- Fixed block size for the full-screen view — independent of the
-- homescreen card's own "weeks shown" setting, which is sized to fit a
-- much narrower column.
local WEEKS_PER_BLOCK = 26

local M = {}
-- 修改：适用中文格式
local function fmtRange(start_t, end_t)
    return os.date("%y.%m.%d", start_t) .. "-" .. os.date("%m.%d", end_t)
end

-- Period selector — same construction as the reading-stats window's
-- month/year headers (StatsWindows' _smMonthHeader / _riYearHeader): a
-- bold label centred in an OverlapGroup, flanked by FACE_ICONS chevrons at
-- fixed offsets either side of the label's own width, so the whole thing
-- stays visually centred regardless of label length. Sized a step smaller
-- than those headers (FS_BODY instead of FS_SUBTITLE, a smaller chevron
-- multiplier) since this selector sits above two full grids rather than
-- being the main content of its own row. Disabled direction dims to the
-- same gray used there.
local function buildPeriodSelector(inner_w, range_text, can_go_older, can_go_newer, on_prev, on_next, SZ)
    local face      = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_BODY))
    local face_chev = Font:getFace(SUIStyle.FACE_ICONS, math.floor(SZ(SUIStyle.FS_TITLE * 1.3)))
    local CLR_BLACK = SUIStyle.COLOR.text_primary

    local gap   = SZ(Screen:scaleBySize(12))
    local btn_w = SZ(Screen:scaleBySize(44))

    local label = TextWidget:new{
        text    = range_text,
        face    = face,
        fgcolor = CLR_BLACK,
        bold    = true,
        padding = 0,
    }

    local lbl_w = label:getSize().w
    local lbl_h = label:getSize().h

    local function navBtn(glyph, enabled, cb)
        local tw = TextWidget:new{
            text    = glyph,
            face    = face_chev,
            fgcolor = enabled and CLR_BLACK or SUIStyle.COLOR.disabled,
            padding = 0,
        }
        local ic = InputContainer:new{
            dimen = Geom:new{ w = btn_w, h = lbl_h },
            CenterContainer:new{
                dimen = Geom:new{ w = btn_w, h = lbl_h },
                tw,
            }
        }
        if enabled then
            ic.ges_events = {
                Tap = { GestureRange:new{ ges = "tap",
                    range = function() return ic.dimen end } },
            }
            function ic:onTap() cb(); return true end
        end
        return ic
    end

    -- Same codepoints as the streak calendar's month header, so the two
    -- chevron pairs in the app render identically.
    local prev_btn = navBtn("\u{E840}", can_go_older, on_prev)
    local next_btn = navBtn("\u{E841}", can_go_newer, on_next)

    local center_x = math.floor(inner_w / 2)
    local half_lbl = math.floor(lbl_w / 2)

    prev_btn.overlap_offset = { center_x - half_lbl - gap - btn_w, 0 }
    label.overlap_offset    = { center_x - half_lbl, 0 }
    next_btn.overlap_offset = { center_x + half_lbl + gap, 0 }

    return OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = lbl_h },
        prev_btn,
        label,
        next_btn,
    }
end

--- Opens the heatmap popup. Reads fresh data on open and on every period
--- change — no ties to any homescreen ctx, so it always opens its own
--- short-lived DB connection (see sui_heatmap_data.lua).
function M.show()
    local SUIWindow = require("engines/sui_window")

    local blocks_back = 0
    local earliest_t  = HD.getEarliestStartTime()
    local is_12h      = G_reader_settings:isTrue("twelve_hour_clock")

    local function buildRoot(ctx)
        local inner_w = ctx.inner_w
        local fs       = ctx.SZ(SUIStyle.FS_CAPTION)
        local fonts    = { small = Font:getFace(SUIStyle.FACE_REGULAR, fs) }

        -- Section-label face — same FACE_REGULAR/FS_DETAIL/bold combination
        -- the reading-stats window uses for its "CALENDAR", "DAY STREAK",
        -- etc. headers, so "Time of day" reads as the same kind of label.
        local section_face = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_DETAIL))

        local start_t, end_t   = HD.getWeekBlockRange(WEEKS_PER_BLOCK, blocks_back)
        local daily_map, fatal1 = HD.getDailyReadingData(start_t, end_t)
        local wd_hour_map, fatal2 = HD.getWeekdayHourReadingData(start_t, end_t)

        local max_blocks_back = HD.maxBlocksBack(WEEKS_PER_BLOCK, earliest_t)
        local can_go_older = blocks_back < max_blocks_back
        local can_go_newer = blocks_back > 0

        local calendar_title = TextWidget:new{
            text    = _("CALENDAR"),
            face    = section_face,
            fgcolor = SUIStyle.COLOR.text_primary,
            bold    = true,
        }

        local header = buildPeriodSelector(
            inner_w, fmtRange(start_t, end_t), can_go_older, can_go_newer,
            function()
                if not can_go_older then return end
                blocks_back = blocks_back + 1
                ctx.repaint()
            end,
            function()
                if not can_go_newer then return end
                blocks_back = blocks_back - 1
                ctx.repaint()
            end,
            ctx.SZ
        )

        local range_widget = HW.buildRangeHeatmap(daily_map, start_t, end_t, fonts, inner_w)

        local day_part_title = TextWidget:new{
            text    = _("TIME OF DAY"),
            face    = section_face,
            fgcolor = SUIStyle.COLOR.text_primary,
            bold    = true,
        }
        local day_part_widget = HW.buildDayPartHeatmap(wd_hour_map, fonts, inner_w, is_12h)

        -- Shared shading scale for both grids above, so the legend sits at
        -- the bottom of the page rather than between them.
        local legend = HW.buildLegend(fonts)

        return {
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(16)) },
            calendar_title,
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(8)) },
            header,
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(16)) },
            range_widget,
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(22)) },
            day_part_title,
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(8)) },
            day_part_widget,
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(16)) },
            CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = legend:getSize().h }, legend },
        }
    end

    local win = SUIWindow:new{
        name          = "sui_win_heatmap",
        title         = _("Reading Heatmap"),
        height        = math.floor((select(2, UI.getPortraitDims())) * 23 / 30),
        position      = "bottom",
        navpager_mode = Config.isNavpagerEnabled(),
        screens       = { __root__ = buildRoot },
    }
    win:show()
end

return M
