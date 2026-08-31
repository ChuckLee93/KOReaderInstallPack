-- sui_heatmap_widgets.lua — Simple UI
-- Reading-heatmap widget builders: pure functions from data tables to
-- KOReader widgets. No DB access and no settings reads here — everything
-- comes in through arguments, so the exact same builders serve both the
-- homescreen card (modules/module_heatmap.lua) and the full-screen popup
-- (screens/sui_heatmap_popup.lua).
--
-- Two grids:
--   HW.buildRangeHeatmap(...)   calendar grid — one cell per day, weekday
--                                rows, columns are weeks, month-start
--                                labels along the top (GitHub-contribution-
--                                graph style)
--   HW.buildDayPartHeatmap(...) weekday x hour-of-day grid — which hours of
--                                the day reading actually happens in
--
-- Shading (both grids): each cell is compared against the busiest single
-- day/hour anywhere in the data passed in, and takes one of five levels —
-- HW.levelColor(0) for no reading, then 1-4 for increasing quarters of that
-- peak. Weeks always start on Monday — this plugin doesn't have a
-- configurable week-start setting, so this matches the Monday-start weeks
-- used elsewhere in Simple UI's own stats screens.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local SUIStyle        = require("features/sui_style")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local _ = require("infra/sui_i18n").translate

local HW = {}

-- ---------------------------------------------------------------------------
-- Shading
-- ---------------------------------------------------------------------------
local _LEVEL_GRAY  = { 0.16, 0.34, 0.52, 0.70, 0.90 }  -- index 1 = level 0 (none), unused — see HW.levelColor

-- Which of the 5 shading levels (0-4) `seconds` falls into, relative to
-- `max_seconds` (the busiest single day/hour in the data being shown).
function HW.classify(seconds, max_seconds)
    if not seconds or seconds <= 0 or not max_seconds or max_seconds <= 0 then return 0 end
    local ratio = seconds / max_seconds
    if ratio <= 0.25 then return 1 end
    if ratio <= 0.50 then return 2 end
    if ratio <= 0.75 then return 3 end
    return 4
end

-- Level 0 (no reading at all) is always pure white, regardless of the
-- gray scale used for levels 1-4 — an empty cell should read as blank,
-- not as a shade of activity.
function HW.levelColor(level)
    level = level or 0
    if level == 0 then return SUIStyle.COLOR.surface end
    return Blitbuffer.gray(_LEVEL_GRAY[level + 1] or _LEVEL_GRAY[1])
end

-- One heatmap square: a thin border-colored square with the level color
-- filled inside, built from two overlapping solid rectangles rather than a
-- bordered FrameContainer (a bordered frame's padding rounding tends to
-- leave a 1px gap at small cell sizes).
local function buildCell(cell_size, border, fill_color)
    local inner = math.max(1, cell_size - 2 * border)
    return OverlapGroup:new{
        dimen = Geom:new{ w = cell_size, h = cell_size },
        LineWidget:new{ dimen = Geom:new{ w = cell_size, h = cell_size }, background = SUIStyle.COLOR.gray_strong },
        CenterContainer:new{
            dimen = Geom:new{ w = cell_size, h = cell_size },
            LineWidget:new{ dimen = Geom:new{ w = inner, h = inner }, background = fill_color },
        },
    }
end

-- ---------------------------------------------------------------------------
-- Shared layout bits
-- ---------------------------------------------------------------------------
local MONTH_NAMES_SHORT = {
    _("Jan"), _("Feb"), _("Mar"), _("Apr"), _("May"), _("Jun"),
    _("Jul"), _("Aug"), _("Sep"), _("Oct"), _("Nov"), _("Dec"),
}

-- Mon/Wed/Fri row labels down the left side of both grids, three rows
-- apart (in-between rows unlabeled), same convention as GitHub's own
-- contribution graph. Row 1 is always Monday — see the file header note on
-- week start.
HW.WEEKDAY_LABELS = { [1] = _("Mon"), [3] = _("Wed"), [5] = _("Fri") }

-- Width of the fixed-width weekday-label column, sized to the widest of
-- the three weekday-row-label strings in the given font. Exported so
-- callers that only need to estimate a grid's height (without building it)
-- can reuse the exact same measurement build() will use.
function HW.getWeekdayLabelWidth(fonts)
    local w = 0
    for _, text in pairs(HW.WEEKDAY_LABELS) do
        local tw = TextWidget:new{ text = text, face = fonts.small }
        w = math.max(w, tw:getSize().w)
        tw:free()
    end
    return w
end

-- ---------------------------------------------------------------------------
-- Calendar grid (HW.buildRangeHeatmap)
-- ---------------------------------------------------------------------------
-- Lays [start_t, end_t] out into Monday-start week columns, padded at both
-- ends so every column has a full 7 days (leading/trailing days outside
-- the range are kept but marked in_range = false, rendered as blank
-- spacer cells rather than colored squares).
function HW.buildRangeGrid(daily_map, start_t, end_t)
    local start_wd     = tonumber(os.date("%w", start_t))  -- 0=Sun..6=Sat
    local start_offset = (start_wd + 6) % 7                -- days back to Monday
    local grid_start   = start_t - start_offset * 86400

    local end_wd     = tonumber(os.date("%w", end_t))
    local end_offset = (7 - end_wd) % 7                    -- days forward to Sunday
    local grid_end   = end_t + end_offset * 86400

    local total_days = math.floor((grid_end - grid_start) / 86400) + 1
    local num_cols    = math.ceil(total_days / 7)

    local start_str = os.date("%Y-%m-%d", start_t)
    local end_str   = os.date("%Y-%m-%d", end_t)

    local cols = {}
    local t = grid_start
    for col = 1, num_cols do
        local col_days = {}
        for row = 1, 7 do
            local dstr = os.date("%Y-%m-%d", t)
            local dt   = os.date("*t", t)
            local in_range = (dstr >= start_str and dstr <= end_str)
            col_days[row] = {
                in_range       = in_range,
                is_month_start = (in_range and dt.day == 1),
                month          = dt.month,
                year           = dt.year,
                seconds        = daily_map[dstr] or 0,
            }
            t = t + 86400
        end
        cols[col] = col_days
    end
    return cols, num_cols
end

-- Builds the month-start label row + the 7-row/num_cols-column calendar
-- grid for [start_t, end_t]. Returns the widget and the cell size actually
-- used (so a caller building a matching legend can reuse it).
--
-- opts.cell_size, when given, forces that exact cell size instead of
-- deriving one from max_width/num_cols — the weekday-label column still
-- sizes itself off `fonts`, but the grid squares themselves stay pinned to
-- the caller's chosen size regardless of what font is used for the
-- labels (see module_heatmap.lua, which renders its labels in a larger
-- font than before but wants its grid cells unchanged).
function HW.buildRangeHeatmap(daily_map, start_t, end_t, fonts, max_width, opts)
    local cols, num_cols = HW.buildRangeGrid(daily_map, start_t, end_t)

    local gap     = Screen:scaleBySize(2)
    local row_gap = Screen:scaleBySize(2)
    local border  = Size.line.thin

    local wd_label_w = HW.getWeekdayLabelWidth(fonts)
    local cell_size
    if opts and opts.cell_size then
        cell_size = opts.cell_size
    else
        local grid_width = max_width - wd_label_w - gap
        cell_size = math.floor((grid_width - (num_cols - 1) * gap) / num_cols)
        local min_cell = Screen:scaleBySize(8)
        if cell_size < min_cell then cell_size = min_cell end
    end

    local max_seconds = 0
    for _, col_days in ipairs(cols) do
        for _, d in ipairs(col_days) do
            if d.in_range and d.seconds > max_seconds then max_seconds = d.seconds end
        end
    end

    -- One label per calendar month, on the column where that month starts.
    -- The year is prefixed onto January so a range spanning a year
    -- boundary still shows it somewhere ("2026 Jan").
    local month_label_col = {}
    local last_month = nil
    for col = 1, num_cols do
        for _, d in ipairs(cols[col]) do
            if d.in_range and d.is_month_start and d.month ~= last_month then
                local text = MONTH_NAMES_SHORT[d.month]
                if d.month == 1 then text = tostring(d.year) .. " " .. text end
                month_label_col[col] = text
                last_month = d.month
                break
            end
        end
    end

    local sample = TextWidget:new{ text = "Xxx", face = fonts.small }
    local label_h = sample:getSize().h
    sample:free()

    local labels_row = HorizontalGroup:new{ align = "bottom" }
    table.insert(labels_row, HorizontalSpan:new{ width = wd_label_w + gap })
    for col = 1, num_cols do
        local text = month_label_col[col]
        if text then
            table.insert(labels_row, LeftContainer:new{
                dimen = Geom:new{ w = cell_size, h = label_h },
                TextWidget:new{ text = text, face = fonts.small, fgcolor = SUIStyle.COLOR.text_dim },
            })
        else
            table.insert(labels_row, HorizontalSpan:new{ width = cell_size })
        end
        if col < num_cols then table.insert(labels_row, HorizontalSpan:new{ width = gap }) end
    end

    -- Row widgets + row_gap spans are appended directly as top-level
    -- children of `widget` (not nested in their own VerticalGroup): a
    -- VerticalSpan nested two VerticalGroups deep can render with zero
    -- height on this widget set, so everything stays flat one level down.
    local widget = VerticalGroup:new{
        align = "left",
        labels_row,
        VerticalSpan:new{ height = Screen:scaleBySize(6) },
    }
    for row = 1, 7 do
        local row_group = HorizontalGroup:new{ align = "center" }
        local wd_text = HW.WEEKDAY_LABELS[row]
        if wd_text then
            table.insert(row_group, LeftContainer:new{
                dimen = Geom:new{ w = wd_label_w, h = cell_size },
                TextWidget:new{ text = wd_text, face = fonts.small, fgcolor = SUIStyle.COLOR.text_dim },
            })
        else
            table.insert(row_group, HorizontalSpan:new{ width = wd_label_w })
        end
        table.insert(row_group, HorizontalSpan:new{ width = gap })

        for col = 1, num_cols do
            local d = cols[col][row]
            if d.in_range then
                table.insert(row_group, buildCell(cell_size, border, HW.levelColor(HW.classify(d.seconds, max_seconds))))
            else
                table.insert(row_group, HorizontalSpan:new{ width = cell_size })
            end
            if col < num_cols then table.insert(row_group, HorizontalSpan:new{ width = gap }) end
        end
        table.insert(widget, row_group)
        if row < 7 then table.insert(widget, VerticalSpan:new{ width = row_gap }) end
    end

    return widget, cell_size
end

-- ---------------------------------------------------------------------------
-- Day-part grid (HW.buildDayPartHeatmap)
-- ---------------------------------------------------------------------------
-- Formats hour `h` (0-23) as a compact column label. is_12h mirrors
-- module_clock.lua's own G_reader_settings:isTrue("twelve_hour_clock")
-- read — passed in rather than read here, keeping this file free of
-- settings access.
local function formatHourLabel(h, is_12h)
    if is_12h then
        local h12 = h % 12
        if h12 == 0 then h12 = 12 end
        return tostring(h12) .. (h < 12 and "a" or "p")
    end
    return string.format("%02d", h)
end

-- Builds the hour-of-day label row + the 7-row/24-column grid: one column
-- per hour (0-23), one row per weekday (row 1 = Monday). weekday_hour_map
-- is { [1..7] = { [0..23] = seconds } } — see
-- HD.getWeekdayHourReadingData. Returns the widget and the cell size used.
--
-- opts.cell_size, when given, forces that exact cell size — see
-- HW.buildRangeHeatmap's own opts.cell_size for the rationale.
function HW.buildDayPartHeatmap(weekday_hour_map, fonts, max_width, is_12h, opts)
    local num_cols = 24
    local gap      = Screen:scaleBySize(2)
    local row_gap  = Screen:scaleBySize(2)
    local border   = Size.line.thin

    local wd_label_w = HW.getWeekdayLabelWidth(fonts)
    local cell_size
    if opts and opts.cell_size then
        cell_size = opts.cell_size
    else
        local grid_width = max_width - wd_label_w - gap
        cell_size = math.floor((grid_width - (num_cols - 1) * gap) / num_cols)
        local min_cell = Screen:scaleBySize(8)
        if cell_size < min_cell then cell_size = min_cell end
    end

    local max_seconds = 0
    for wd = 1, 7 do
        for h = 0, 23 do
            local secs = weekday_hour_map[wd] and weekday_hour_map[wd][h] or 0
            if secs > max_seconds then max_seconds = secs end
        end
    end

    -- Hour labels every 3 columns (00, 03, ... 21 in 24h format) — every
    -- column would be too dense to read at this cell size.
    local sample = TextWidget:new{ text = "00", face = fonts.small }
    local label_h = sample:getSize().h
    sample:free()

    local labels_row = HorizontalGroup:new{ align = "bottom" }
    table.insert(labels_row, HorizontalSpan:new{ width = wd_label_w + gap })
    for h = 0, num_cols - 1 do
        if h % 3 == 0 then
            table.insert(labels_row, LeftContainer:new{
                dimen = Geom:new{ w = cell_size, h = label_h },
                TextWidget:new{ text = formatHourLabel(h, is_12h), face = fonts.small, fgcolor = SUIStyle.COLOR.text_dim },
            })
        else
            table.insert(labels_row, HorizontalSpan:new{ width = cell_size })
        end
        if h < num_cols - 1 then table.insert(labels_row, HorizontalSpan:new{ width = gap }) end
    end

    local widget = VerticalGroup:new{
        align = "left",
        labels_row,
        VerticalSpan:new{ height = Screen:scaleBySize(6) },
    }
    for row = 1, 7 do
        local row_group = HorizontalGroup:new{ align = "center" }
        local wd_text = HW.WEEKDAY_LABELS[row]
        if wd_text then
            table.insert(row_group, LeftContainer:new{
                dimen = Geom:new{ w = wd_label_w, h = cell_size },
                TextWidget:new{ text = wd_text, face = fonts.small, fgcolor = SUIStyle.COLOR.text_dim },
            })
        else
            table.insert(row_group, HorizontalSpan:new{ width = wd_label_w })
        end
        table.insert(row_group, HorizontalSpan:new{ width = gap })

        for h = 0, num_cols - 1 do
            local secs = weekday_hour_map[row] and weekday_hour_map[row][h] or 0
            table.insert(row_group, buildCell(cell_size, border, HW.levelColor(HW.classify(secs, max_seconds))))
            if h < num_cols - 1 then table.insert(row_group, HorizontalSpan:new{ width = gap }) end
        end
        table.insert(widget, row_group)
        if row < 7 then table.insert(widget, VerticalSpan:new{ width = row_gap }) end
    end

    return widget, cell_size
end

-- ---------------------------------------------------------------------------
-- Legend
-- ---------------------------------------------------------------------------
-- "Less [ ][ ][ ][ ][ ] More" — five sample cells, one per shading level.
-- cell_size defaults to a fixed comfortable size for the full-screen
-- popup; callers with their own scaled cell size (the homescreen card, to
-- keep the legend in step with its own grid) can pass one in.
function HW.buildLegend(fonts, cell_size)
    local gap    = Screen:scaleBySize(3)
    local cell   = cell_size or Screen:scaleBySize(11)
    local border = Size.line.thin

    local row = HorizontalGroup:new{ align = "center" }
    table.insert(row, TextWidget:new{ text = _("Less"), face = fonts.small, fgcolor = SUIStyle.COLOR.text_dim })
    table.insert(row, HorizontalSpan:new{ width = gap * 2 })
    for level = 0, 4 do
        table.insert(row, buildCell(cell, border, HW.levelColor(level)))
        if level < 4 then table.insert(row, HorizontalSpan:new{ width = gap }) end
    end
    table.insert(row, HorizontalSpan:new{ width = gap * 2 })
    table.insert(row, TextWidget:new{ text = _("More"), face = fonts.small, fgcolor = SUIStyle.COLOR.text_dim })
    return row
end

return HW
