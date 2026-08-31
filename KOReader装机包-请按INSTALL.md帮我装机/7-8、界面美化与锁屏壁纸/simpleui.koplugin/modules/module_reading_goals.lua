-- Reading Goals module: annual and daily progress bars with tap-to-set dialogs.
-- Supports two layouts: Default (bar + detail on separate lines) and Compact (single inline row).

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local _ = require("infra/sui_i18n").translate
local N_ = require("infra/sui_i18n").ngettext
local logger          = require("logger")
local Config          = require("infra/sui_config")

local UI           = require("infra/sui_core")
local SUISettings  = require("infra/sui_store")
local SUIStyle     = require("features/sui_style")
local PAD          = UI.PAD
local PAD2         = UI.PAD2
local LABEL_H      = UI.LABEL_H
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

-- Colours

-- Default layout base dimensions (scaled at render time via _scaledDims)
local _BASE_ROW_FS  = SUIStyle.FS_BODY     -- 18: row text
local _BASE_SUB_FS  = SUIStyle.FS_DETAIL   -- 15: sub text
local _BASE_ROW_H   = Screen:scaleBySize(16)
local _BASE_SUB_H   = Screen:scaleBySize(16)
local _BASE_SUB_GAP = Screen:scaleBySize(2)
local _BASE_ROW_GAP = Screen:scaleBySize(18)
local _BASE_BAR_H   = Screen:scaleBySize(8)
local _BASE_LBL_W   = Screen:scaleBySize(44)
local _BASE_COL_GAP = Screen:scaleBySize(8)
local _BASE_BOT_PAD = Screen:scaleBySize(18)

-- Compact layout reuses the same _BASE_* constants as the default layout —
-- _compactDims(scale) just applies them at a different scale. Callers
-- already multiply scale by ctx.landscape_factor before it reaches here.

-- Rounds a fraction to a whole percentage. Mirrors SH.pctStr from
-- module_books_shared; duplicated here to avoid loading that module just
-- for formatting.
local function _pctStr(pct)
    return string.format("%.0f%%", (pct or 0) * 100)
end

local function _compactDims(scale)
    scale = scale or 1.0
    local row_fs = math.max(7, math.floor(_BASE_ROW_FS * scale))
    local sub_fs = math.max(6, math.floor(_BASE_SUB_FS * scale))
    return {
        row_fs   = row_fs,
        sub_fs   = sub_fs,
        face_row = Font:getFace(SUIStyle.FACE_REGULAR, row_fs),
        face_sub = Font:getFace(SUIStyle.FACE_REGULAR,         sub_fs),
        row_h    = math.max(8, math.floor(_BASE_ROW_H   * scale)),
        row_gap  = math.max(4, math.floor(_BASE_ROW_GAP * scale)),
        bar_h    = math.max(1, math.floor(_BASE_BAR_H   * scale)),
        lbl_w    = math.max(20, math.floor(_BASE_LBL_W  * scale)),
        col_gap  = math.max(2, math.floor(_BASE_COL_GAP * scale)),
    }
end

local function _getYearStr()  return os.date("%Y") end
-- 修改：适用中文格式
local function _getMonthStr()
    local chinese_months = {
        "1月", "2月", "3月", "4月", "5月", "6月",
        "7月", "8月", "9月", "10月", "11月", "12月"
    }
    local month_num = tonumber(os.date("%m"))
    return chinese_months[month_num] or os.date("%m") .. "月"
end

-- Settings keys
local SHOW_ANNUAL  = "simpleui_reading_goals_show_annual"
local SHOW_MONTHLY = "simpleui_reading_goals_show_monthly"
local SHOW_DAILY   = "simpleui_reading_goals_show_daily"
local LAYOUT_KEY   = "simpleui_reading_goals_layout"  -- "default" | "compact"

local function isCompact()    return SUISettings:readSetting(LAYOUT_KEY) == "compact" end
local function showAnnual()   return SUISettings:readSetting(SHOW_ANNUAL) ~= false end
local function showMonthly()  return SUISettings:readSetting(SHOW_MONTHLY) ~= false end
local function showDaily()    return SUISettings:readSetting(SHOW_DAILY)  ~= false end

local function getAnnualGoal()      return tonumber(SUISettings:readSetting("simpleui_reading_goal")) or 0 end
local function getAnnualPhysical()  return tonumber(SUISettings:readSetting("simpleui_reading_goal_physical")) or 0 end
local function getMonthlyGoalSecs() return tonumber(SUISettings:readSetting("simpleui_monthly_reading_goal_secs")) or 0 end
local function getDailyGoalSecs()   return tonumber(SUISettings:readSetting("simpleui_daily_reading_goal_secs")) or 0 end

local function _getElemOrder(pfx)
    local saved = SUISettings:readSetting((pfx or "simpleui_hs_") .. "reading_goals_elem_order")
    if type(saved) ~= "table" or #saved == 0 then return { "annual", "monthly", "daily" } end
    local seen, result = {}, {}
    for _, v in ipairs(saved) do
        if (v == "annual" or v == "monthly" or v == "daily") and not seen[v] then
            seen[v] = true
            result[#result+1] = v
        end
    end
    -- append any element not yet in saved (forwards-compat: "monthly" appears
    -- in a fresh install but not in settings written by an older version)
    for _, v in ipairs({"annual", "monthly", "daily"}) do
        if not seen[v] then result[#result+1] = v end
    end
    return result
end

-- Formats seconds as "Xh Ym" / "Xh" / "Ym"
local function formatDuration(secs)
    secs = math.floor(secs or 0)
    if secs <= 0 then return "0m" end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 and m > 0 then return string.format("%dh %dm", h, m)
    elseif h > 0        then return string.format("%dh", h)
    else                     return string.format("%dm", m) end
end

-- Stats cache and per-module fetch logic have been moved to
-- modules/module_stats_provider.lua (SP). The provider runs one
-- consolidated DB query covering today, 7-day avg, year total, and all-time
-- total, plus a single sidecar scan for books_year + books_total together.
-- build() reads ctx.stats.* — no DB or cache logic here.

-- _lbl_w_cache is kept here because it depends on font size, not on stats data.
-- Declared before _invalidateLblCache so the upvalue is properly in scope.
-- Cleared by M.invalidateCache() and M.reset(); the font-size key is the real
-- invalidation guard — a different font_size produces a different key so stale
-- entries from a previous scale are simply never hit.
local _lbl_w_cache = {}
local function _invalidateLblCache()
    _lbl_w_cache = {}
end


-- Computes all layout metrics for the default layout at the given scale factor.
-- Pre-resolves font faces so buildGoalRow doesn't call Font:getFace on every render.
local function _scaledDims(scale)
    scale = scale or 1.0
    local row_h   = math.max(8,  math.floor(_BASE_ROW_H   * scale))
    local sub_h   = math.max(8,  math.floor(_BASE_SUB_H   * scale))
    local sub_gap = math.max(1,  math.floor(_BASE_SUB_GAP * scale))
    local bot_pad = math.max(4,  math.floor(_BASE_BOT_PAD * scale))
    local row_fs  = math.max(7,  math.floor(_BASE_ROW_FS  * scale))
    local sub_fs  = math.max(6,  math.floor(_BASE_SUB_FS  * scale))
    return {
        row_fs     = row_fs,
        sub_fs     = sub_fs,
        face_row   = Font:getFace(SUIStyle.FACE_REGULAR, row_fs),
        face_sub   = Font:getFace(SUIStyle.FACE_REGULAR,         sub_fs),
        row_h      = row_h,
        sub_h      = sub_h,
        sub_gap    = sub_gap,
        row_gap    = math.max(4,  math.floor(_BASE_ROW_GAP * scale)),
        bar_h      = math.max(1,  math.floor(_BASE_BAR_H   * scale)),
        lbl_w      = math.max(20, math.floor(_BASE_LBL_W   * scale)),
        col_gap    = math.max(2,  math.floor(_BASE_COL_GAP * scale)),
        bot_pad    = bot_pad,
        pct_w      = math.max(16, math.floor(Screen:scaleBySize(32) * scale)),
        min_bar_w  = math.max(20, math.floor(Screen:scaleBySize(40) * scale)),
        goal_row_h = row_h + sub_gap + sub_h + bot_pad,
    }
end

-- Returns total pixel height for n compact rows including inter-row gap.
-- Accepts a dims table from _compactDims() so it uses current screen geometry.
local function _compactRowsHeight(n, cd)
    return n * cd.row_h + (n == 2 and cd.row_gap or 0)
end

-- Measures the rendered width of each active label using the given face and
-- returns the smallest lbl_w that fits all of them, with a minimum floor.
-- Called once per M.build so both rows share the same column width.
local function _measureLblW(labels, face, floor_w)
    local max_w = 0
    local fs    = face.size  -- integer; unique per font/size combination
    for _, lbl in ipairs(labels) do
        local key    = tostring(lbl) .. "|" .. fs
        local cached = _lbl_w_cache[key]
        if not cached then
            local tw = TextWidget:new{ text = lbl, face = face, bold = true }
            cached   = tw:getSize().w
            tw:free()
            _lbl_w_cache[key] = cached
        end
        if cached > max_w then max_w = cached end
    end
    return math.max(max_w, floor_w)
end

local function _buildInnerCompact(inner_w, lbl_w, pct_w, label_str, pct, pct_str, detail_str, cd, clr_sub, clr_blk)
    local LeftContainer  = require("ui/widget/container/leftcontainer")
    local RightContainer = require("ui/widget/container/rightcontainer")

    local ROW_H          = cd.row_h
    local LBL_BAR_GAP    = cd.col_gap
    local BAR_PCT_GAP    = cd.col_gap
    local PCT_DETAIL_GAP = cd.col_gap
    -- right_w must be at least pct_w + gap + a minimum detail column.
    local MIN_DETAIL_W = Screen:scaleBySize(32)
    local right_w = math.max(
        math.floor(inner_w * 0.28),
        pct_w + PCT_DETAIL_GAP + MIN_DETAIL_W)
    local available = inner_w - lbl_w - LBL_BAR_GAP - BAR_PCT_GAP - right_w
    if available < Screen:scaleBySize(40) then
        -- lbl_w grew — shrink right_w before the bar goes below minimum
        available = Screen:scaleBySize(40)
        right_w = math.max(0, inner_w - lbl_w - LBL_BAR_GAP - BAR_PCT_GAP - available)
    end
    local bar_w    = available
    local PCT_W    = pct_w
    local DETAIL_W = math.max(0, right_w - PCT_W - PCT_DETAIL_GAP)

    local function vcenter_left(child, col_w)
        return LeftContainer:new{ dimen = Geom:new{ w = col_w, h = ROW_H }, child }
    end
    local function vcenter_right(child, col_w)
        return RightContainer:new{ dimen = Geom:new{ w = col_w, h = ROW_H }, child }
    end

    local eff_blk = clr_blk or SUIStyle.COLOR.text_primary
    return HorizontalGroup:new{
        align = "center",
        vcenter_left(UI.makeColoredText{
            text    = label_str,
            face    = cd.face_row,
            bold    = true,
            fgcolor = eff_blk,
            width   = lbl_w,
        }, lbl_w),
        HorizontalSpan:new{ width = LBL_BAR_GAP },
        vcenter_left(UI.progressBar(bar_w, pct, cd.bar_h), bar_w),
        HorizontalSpan:new{ width = BAR_PCT_GAP },
        vcenter_left(UI.makeColoredText{
            text    = pct_str,
            face    = cd.face_row,
            bold    = true,
            fgcolor = eff_blk,
            width   = PCT_W,
        }, PCT_W),
        HorizontalSpan:new{ width = PCT_DETAIL_GAP },
        vcenter_right(UI.makeColoredText{
            text      = detail_str,
            face      = cd.face_sub,
            fgcolor   = clr_sub or CLR_TEXT_SUB,
            width     = DETAIL_W,
            alignment = "right",
        }, DETAIL_W),
    }
end

-- Wraps a frame in a tappable InputContainer that fires on_tap when the row
-- is tapped anywhere within its bounds. Returns the frame unchanged when
-- on_tap is nil (rows without a settings dialog, e.g. read-only summaries).
local function _wrapTappable(frame, w, h, on_tap)
    if not on_tap then return frame end
    local tappable = InputContainer:new{
        dimen   = Geom:new{ w = w, h = h },
        [1]     = frame,
        _on_tap = on_tap,
    }
    tappable.ges_events = {
        TapGoalRow = {
            GestureRange:new{ ges = "tap", range = function() return tappable.dimen end },
        },
    }
    function tappable:onTapGoalRow()
        if self._on_tap then self._on_tap() end
        return true
    end
    return tappable
end

-- Builds a single inline row: Label [bar] XX%  detail
-- Used by the Compact layout. All elements are horizontally laid out and vertically centred.
-- lbl_w is pre-computed by _measureLblW so both rows share the same column width.
local function buildCompactGoalRow(inner_w, lbl_w, pct_w, label_str, pct, pct_str, detail_str, on_tap, cd, clr_sub, clr_blk)
    local row = _buildInnerCompact(inner_w, lbl_w, pct_w, label_str, pct, pct_str, detail_str, cd, clr_sub, clr_blk)

    local frame = FrameContainer:new{
        bordersize = 0, padding = 0,
        dimen      = Geom:new{ w = inner_w, h = cd.row_h },
        row,
    }
    local update_fn = function(new_pct, new_pct_str, new_detail_str)
        frame[1] = _buildInnerCompact(inner_w, lbl_w, pct_w, label_str, new_pct, new_pct_str, new_detail_str, cd, clr_sub, clr_blk)
    end

    return _wrapTappable(frame, inner_w, cd.row_h, on_tap), update_fn
end

local function _buildInnerDefault(inner_w, label_str, pct, pct_str, detail_str, d, clr_sub_eff, clr_blk_eff)
    local PCT_W       = d.pct_w
    local LBL_BAR_GAP = d.col_gap
    local BAR_PCT_GAP = d.col_gap
    local available   = inner_w - d.lbl_w - LBL_BAR_GAP - BAR_PCT_GAP - PCT_W
    if available < d.min_bar_w then
        available = d.min_bar_w
        PCT_W = math.max(0, inner_w - d.lbl_w - LBL_BAR_GAP - BAR_PCT_GAP - available)
    end
    local bar_w = available
    return VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "center",
            UI.makeColoredText{
                text    = label_str,
                face    = d.face_row,
                bold    = true,
                fgcolor = clr_blk_eff,
                width   = d.lbl_w,
            },
            HorizontalSpan:new{ width = LBL_BAR_GAP },
        UI.progressBar(bar_w, pct, d.bar_h),
            HorizontalSpan:new{ width = BAR_PCT_GAP },
            UI.makeColoredText{
                text      = pct_str,
                face      = d.face_row,
                bold      = true,
                fgcolor   = clr_blk_eff,
                width     = PCT_W,
                alignment = "right",
            },
        },
        VerticalSpan:new{ width = d.sub_gap },
        UI.makeColoredText{
            text    = detail_str,
            face    = d.face_sub,
            fgcolor = clr_sub_eff,
            width   = inner_w,
        },
    }
end

-- Builds a two-line goal row: label + bar + pct on the first line, detail text below.
-- Used by the Default layout. Accepts a pre-computed dims table from _scaledDims.
local function buildGoalRow(inner_w, label_str, pct, pct_str, detail_str, on_tap, d, clr_sub_eff, clr_blk_eff)
    clr_sub_eff = clr_sub_eff or CLR_TEXT_SUB
    clr_blk_eff = clr_blk_eff or SUIStyle.COLOR.text_primary
    local block = _buildInnerDefault(inner_w, label_str, pct, pct_str, detail_str, d, clr_sub_eff, clr_blk_eff)

    local frame = FrameContainer:new{
        bordersize     = 0,
        padding        = 0,
        padding_bottom = d.bot_pad,
        block,
    }
    local update_fn = function(new_pct, new_pct_str, new_detail_str)
        frame[1] = _buildInnerDefault(inner_w, label_str, new_pct, new_pct_str, new_detail_str, d, clr_sub_eff, clr_blk_eff)
    end

    return _wrapTappable(frame, inner_w, d.goal_row_h, on_tap), update_fn
end

-- Triggers a homescreen refresh after a goal change.
-- Invalidates StatsProvider so _buildCtx re-fetches with updated ctx.stats.
local function _refreshHS()
    local SP = package.loaded["modules/module_stats_provider"]
    if SP then SP.invalidate() end
    local HS = package.loaded["screens/sui_homescreen"]
    if HS then HS.refresh(false) end
end

-- Shows a SpinWidget bound to a settings key, refreshing the homescreen and
-- calling on_confirm after save. Shared by all four goal-setting dialogs
-- below — only the copy, value range, and settings key differ between them.
local function _showGoalSpinDialog(opts, on_confirm)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text  = opts.title_text,
        info_text   = opts.info_text,
        value       = opts.value,
        value_min   = opts.value_min or 0,
        value_max   = opts.value_max,
        value_step  = opts.value_step or 1,
        ok_text     = _("Save"), cancel_text = _("Cancel"),
        callback    = function(spin)
            SUISettings:saveSetting(opts.setting_key, math.floor(spin.value) * (opts.value_multiplier or 1))
            _refreshHS()
            if on_confirm then on_confirm() end
        end,
    })
end

-- Dialog: set the number of books to read this year
local function showAnnualGoalDialog(on_confirm)
    local g = getAnnualGoal()
    _showGoalSpinDialog({
        title_text  = _("Annual Reading Goal"),
        info_text   = string.format(_("Books to read in %s:"), _getYearStr()),
        value       = g > 0 and g or 12,
        value_max   = 365,
        setting_key = "simpleui_reading_goal",
    }, on_confirm)
end

-- Dialog: set the count of physical books read this year
local function showAnnualPhysicalDialog(on_confirm)
    _showGoalSpinDialog({
        title_text  = string.format(_("Physical Books — %s"), _getYearStr()),
        info_text   = _("Physical books read this year:"),
        value       = getAnnualPhysical(),
        value_max   = 365,
        setting_key = "simpleui_reading_goal_physical",
    }, on_confirm)
end

-- Dialog: set the monthly reading goal in hours
local function showMonthlySettingsDialog(on_confirm)
    _showGoalSpinDialog({
        title_text       = _("Monthly Reading Goal"),
        info_text        = _("Hours per month:"),
        value            = math.floor(getMonthlyGoalSecs() / 3600),
        value_max        = 350,
        setting_key      = "simpleui_monthly_reading_goal_secs",
        value_multiplier = 3600,
    }, on_confirm)
end

-- Dialog: set the daily reading goal in minutes
local function showDailySettingsDialog(on_confirm)
    _showGoalSpinDialog({
        title_text       = _("Daily Reading Goal"),
        info_text        = _("Minutes per day:"),
        value            = math.floor(getDailyGoalSecs() / 60),
        value_max        = 720,
        value_step       = 5,
        setting_key      = "simpleui_daily_reading_goal_secs",
        value_multiplier = 60,
    }, on_confirm)
end

-- Formats a percentage/detail pair, falling back to a plain-text version if
-- string.format raises (e.g. a translated plural form with mismatched
-- placeholders) so a bad translation degrades gracefully instead of crashing
-- the row.
local function _safeDetail(context_label, fmt_fn, fallback_fn)
    local ok, res = pcall(fmt_fn)
    if ok then return res end
    logger.warn("simpleui reading_goals " .. context_label .. " format error: " .. tostring(res))
    return fallback_fn()
end

-- Returns pct, pct_str for a value against a goal; pct is 100% (empty label)
-- when no goal is set, since there's nothing to measure progress against.
local function _goalPct(value, goal)
    if goal <= 0 then return 1.0, "" end
    local pct = value / goal
    return pct, _pctStr(pct)
end

-- Returns pct, pct_str, detail for the annual goal row
local function _annualData(books_read)
    local goal = getAnnualGoal()
    local read = books_read + getAnnualPhysical()
    local pct, pct_str = _goalPct(read, goal)
    logger.dbg("simpleui reading_goals: annual bar — goal=", goal,
        "books_read=", books_read, "physical=", getAnnualPhysical(),
        "read=", read, "pct=", pct, "pct_str=", pct_str)
    local detail_text = _safeDetail("annual",
        function()
            if goal > 0 then
                return string.format(N_("%d/%d book", "%d/%d books", goal), read, goal)
            else
                return string.format(N_("%d book", "%d books", read), read)
            end
        end,
        function()
            return (goal > 0) and (read .. "/" .. goal .. " books") or (read .. " books")
        end)
    return pct, pct_str, detail_text
end

-- Returns pct, pct_str, detail for the monthly goal row
local function _monthlyData(month_secs)
    local goal_secs = getMonthlyGoalSecs()
    local pct, pct_str = _goalPct(month_secs, goal_secs)
    local detail_text = _safeDetail("monthly",
        function()
            if goal_secs <= 0 then
                return string.format(_("%s read"), formatDuration(month_secs))
            else
                return string.format("%s/%s", formatDuration(month_secs), formatDuration(goal_secs))
            end
        end,
        function()
            return (goal_secs <= 0)
                and (formatDuration(month_secs) .. " read")
                or  (formatDuration(month_secs) .. "/" .. formatDuration(goal_secs))
        end)
    return pct, pct_str, detail_text
end

-- Returns pct, pct_str, detail for the daily goal row
local function _dailyData(today_secs)
    local goal_secs = getDailyGoalSecs()
    local pct, pct_str = _goalPct(today_secs, goal_secs)
    local detail_text = _safeDetail("daily",
        function()
            if goal_secs <= 0 then
                return string.format(_("%s read"), formatDuration(today_secs))
            else
                return string.format("%s/%s", formatDuration(today_secs), formatDuration(goal_secs))
            end
        end,
        function()
            return (goal_secs <= 0)
                and (formatDuration(today_secs) .. " read")
                or  (formatDuration(today_secs) .. "/" .. formatDuration(goal_secs))
        end)
    return pct, pct_str, detail_text
end

-- Module API
local M = {}

M.id          = "reading_goals"
M.name        = _("Reading Goals")
M.label       = _("Reading Goals")
M.enabled_key = "reading_goals_enabled"
M.default_on  = true

M.showAnnualGoalDialog      = showAnnualGoalDialog
M.showAnnualPhysicalDialog  = showAnnualPhysicalDialog
M.showMonthlySettingsDialog = showMonthlySettingsDialog
M.showDailySettingsDialog   = showDailySettingsDialog

-- Delegate cache invalidation to StatsProvider (shared with reading_stats).
function M.invalidateCache()
    local SP = package.loaded["modules/module_stats_provider"]
    if SP then SP.invalidate() end
    _invalidateLblCache()
end

-- Called on plugin reset (hot update). Clears label width cache too since
-- font metrics may change after a restart.
function M.reset()
    local SP = package.loaded["modules/module_stats_provider"]
    if SP then SP.invalidate() end
    _invalidateLblCache()
end

-- Builds the widget. Branches on layout mode: compact (single inline row) or default (two lines).
function M.build(w, ctx)
    Config.applyLabelToggle(M, _("Reading Goals"))
    local show_ann = showAnnual()
    local show_mon = showMonthly()
    local show_day = showDaily()
    if not show_ann and not show_mon and not show_day then return nil end

    local ok, res = pcall(function()
    local scale = Config.getModuleScale("reading_goals", ctx.pfx) * (ctx.landscape_factor or 1)
    -- Frame border / solid background — same optional box every other
    -- homescreen module offers (module_currently.lua, module_heatmap.lua):
    -- a border, a filled background, or both, each adding PAD to every edge.
    -- Computed up front so inner_w below already reserves room for the
    -- border, keeping the box's real outer width equal to `w`.
    local box = SUIStyle.computeBox(
        SUISettings:isTrue(ctx.pfx .. "reading_goals_show_frame"),
        SUISettings:isTrue(ctx.pfx .. "reading_goals_solid_bg"),
        scale, PAD)
    local inner_w = w - box.inset_h
    -- Stats pre-fetched by StatsProvider and passed via ctx.stats.
    local sp         = ctx.stats or {}
    local books_read = sp.books_year  or 0
    local year_secs  = sp.year_secs   or 0
    local month_secs = sp.month_secs  or 0
    local today_secs = sp.today_secs  or 0
    if sp.db_conn_fatal and ctx then ctx.db_conn_fatal = true end
    local rows_children = { align = "left" }
    local compact = isCompact()

    local rg_update_funcs = {}
    local CLR_TEXT_BLK_EFF = SUIStyle.COLOR.text_primary
    local CLR_TEXT_SUB_EFF = CLR_TEXT_SUB

    if compact then
        -- scale already includes ctx.landscape_factor.
        local cd = _compactDims(scale)
        -- Capture year/month strings once — avoids repeated os.date calls.
        local year_str  = _getYearStr()
        local month_str = _getMonthStr()
        -- Pre-compute data for all active rows so we can measure pct_w across
        -- all of them and use the same column width (prevents overlap at 100%+).
        local ann_pct, ann_pct_str, ann_detail
        local mon_pct, mon_pct_str, mon_detail
        local day_pct, day_pct_str, day_detail
        if show_ann then ann_pct, ann_pct_str, ann_detail = _annualData(books_read) end
        if show_mon then mon_pct, mon_pct_str, mon_detail = _monthlyData(month_secs) end
        if show_day then day_pct, day_pct_str, day_detail = _dailyData(today_secs) end
        -- Measure pct column width across all active rows.
        local pct_strs = {}
        if show_ann and ann_pct_str ~= "" then pct_strs[#pct_strs+1] = ann_pct_str end
        if show_mon and mon_pct_str ~= "" then pct_strs[#pct_strs+1] = mon_pct_str end
        if show_day and day_pct_str ~= "" then pct_strs[#pct_strs+1] = day_pct_str end
        local pct_w = _measureLblW(pct_strs, cd.face_row, Screen:scaleBySize(28))
        local rendered_count = 0
        for _i, k in ipairs(_getElemOrder(ctx.pfx)) do
            if k == "annual" and show_ann then
                if rendered_count > 0 then rows_children[#rows_children+1] = VerticalSpan:new{ width = cd.row_gap } end
                local lbl_w = _measureLblW({ year_str }, cd.face_row, cd.lbl_w)
                cd.lbl_w = lbl_w
                local row_widget, row_update_fn = buildCompactGoalRow(
                    inner_w, lbl_w, pct_w, year_str, ann_pct, ann_pct_str, ann_detail,
                    function()
                        local ok, SW = pcall(require, "screens/sui_stats_windows")
                        if ok and SW and SW.showFinishedBooksDialog then
                            if SW.showLoadingNotice then SW.showLoadingNotice() end
                            SW.showFinishedBooksDialog()
                        end
                    end, cd, CLR_TEXT_SUB_EFF, CLR_TEXT_BLK_EFF)
                rows_children[#rows_children+1] = row_widget
                table.insert(rg_update_funcs, { cat = "books", fn = function(books_r, _today_s, _month_s)
                    local n_pct, n_str, n_det = _annualData(books_r)
                    row_update_fn(n_pct, n_str, n_det)
                end })
                rendered_count = rendered_count + 1
            elseif k == "monthly" and show_mon then
                if rendered_count > 0 then rows_children[#rows_children+1] = VerticalSpan:new{ width = cd.row_gap } end
                local lbl_w = _measureLblW({ month_str }, cd.face_row, cd.lbl_w)
                cd.lbl_w = lbl_w
                local row_widget, row_update_fn = buildCompactGoalRow(
                    inner_w, lbl_w, pct_w, month_str, mon_pct, mon_pct_str, mon_detail,
                    function() showMonthlySettingsDialog() end, cd, CLR_TEXT_SUB_EFF, CLR_TEXT_BLK_EFF)
                rows_children[#rows_children+1] = row_widget
                table.insert(rg_update_funcs, { cat = "timeseries", fn = function(_books_r, _today_s, month_s)
                    local n_pct, n_str, n_det = _monthlyData(month_s)
                    row_update_fn(n_pct, n_str, n_det)
                end })
                rendered_count = rendered_count + 1
            elseif k == "daily" and show_day then
                if rendered_count > 0 then rows_children[#rows_children+1] = VerticalSpan:new{ width = cd.row_gap } end
                local lbl_w = _measureLblW({ _("Today") }, cd.face_row, cd.lbl_w)
                local row_widget, row_update_fn = buildCompactGoalRow(
                    inner_w, lbl_w, pct_w, _("Today"), day_pct, day_pct_str, day_detail,
                    function() showDailySettingsDialog() end, cd, CLR_TEXT_SUB_EFF, CLR_TEXT_BLK_EFF)
                rows_children[#rows_children+1] = row_widget
                table.insert(rg_update_funcs, { cat = "timeseries", fn = function(_books_r, today_s, _month_s)
                    local n_pct, n_str, n_det = _dailyData(today_s)
                    row_update_fn(n_pct, n_str, n_det)
                end })
                rendered_count = rendered_count + 1
            end
        end
    else
        local d        = _scaledDims(scale)
        -- Capture year/month strings once — avoids repeated os.date calls.
        local year_str  = _getYearStr()
        local month_str = _getMonthStr()
        local rendered_count = 0
        for _i, k in ipairs(_getElemOrder(ctx.pfx)) do
            if k == "annual" and show_ann then
                if rendered_count > 0 then rows_children[#rows_children+1] = VerticalSpan:new{ width = d.row_gap } end
                local pct, pct_str, detail = _annualData(books_read)
                local ann_lbl_w = _measureLblW({ year_str }, d.face_row, d.lbl_w)
                d.lbl_w = ann_lbl_w
                local row_widget, row_update_fn = buildGoalRow(
                    inner_w, year_str, pct, pct_str, detail,
                    function()
                        local ok, SW = pcall(require, "screens/sui_stats_windows")
                        if ok and SW and SW.showFinishedBooksDialog then
                            if SW.showLoadingNotice then SW.showLoadingNotice() end
                            SW.showFinishedBooksDialog()
                        end
                    end, d, CLR_TEXT_SUB_EFF, CLR_TEXT_BLK_EFF)
                rows_children[#rows_children+1] = row_widget
                table.insert(rg_update_funcs, { cat = "books", fn = function(books_r, _today_s, _month_s)
                    local n_pct, n_str, n_det = _annualData(books_r)
                    row_update_fn(n_pct, n_str, n_det)
                end })
                rendered_count = rendered_count + 1
            elseif k == "monthly" and show_mon then
                if rendered_count > 0 then rows_children[#rows_children+1] = VerticalSpan:new{ width = d.row_gap } end
                local pct, pct_str, detail = _monthlyData(month_secs)
                local mon_lbl_w = _measureLblW({ month_str }, d.face_row, d.lbl_w)
                d.lbl_w = mon_lbl_w
                local row_widget, row_update_fn = buildGoalRow(
                    inner_w, month_str, pct, pct_str, detail,
                    function() showMonthlySettingsDialog() end, d, CLR_TEXT_SUB_EFF, CLR_TEXT_BLK_EFF)
                rows_children[#rows_children+1] = row_widget
                table.insert(rg_update_funcs, { cat = "timeseries", fn = function(_books_r, _today_s, month_s)
                    local n_pct, n_str, n_det = _monthlyData(month_s)
                    row_update_fn(n_pct, n_str, n_det)
                end })
                rendered_count = rendered_count + 1
            elseif k == "daily" and show_day then
                if rendered_count > 0 then rows_children[#rows_children+1] = VerticalSpan:new{ width = d.row_gap } end
                local pct, pct_str, detail = _dailyData(today_secs)
                local day_lbl_w = _measureLblW({ _("Today") }, d.face_row, d.lbl_w)
                d.lbl_w = day_lbl_w
                local row_widget, row_update_fn = buildGoalRow(
                    inner_w, _("Today"), pct, pct_str, detail,
                    function() showDailySettingsDialog() end, d, CLR_TEXT_SUB_EFF, CLR_TEXT_BLK_EFF)
                rows_children[#rows_children+1] = row_widget
                table.insert(rg_update_funcs, { cat = "timeseries", fn = function(_books_r, today_s, _month_s)
                    local n_pct, n_str, n_det = _dailyData(today_s)
                    row_update_fn(n_pct, n_str, n_det)
                end })
                rendered_count = rendered_count + 1
            end
        end
    end

    local final_frame = SUIStyle.wrapBox(VerticalGroup:new(rows_children), box)
    final_frame._rg_update_funcs = rg_update_funcs
    return final_frame
    end)
    
    if not ok then
        logger.warn("simpleui reading_goals build error: " .. tostring(res))
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = require("device").screen:scaleBySize(60) },
            UI.makeColoredText{
                text = _("Error in Reading Goals: check crash.log"),
                face = Font:getFace(SUIStyle.FACE_REGULAR, 15),
                fgcolor = SUIStyle.COLOR.text_primary,
                width = w - PAD * 2,
                alignment = "center",
            }
        }
    end
    return res
end

function M.updateStats(widget, ctx)
    if not widget or not widget._rg_update_funcs then return false end
    local sp = ctx.stats or {}
    -- _changed: skip rows whose underlying data did not change this cycle.
    -- Absent when SP.invalidate() did a full reset — treat all as changed.
    local changed = sp._changed
    local books_read = sp.books_year  or 0
    local today_secs = sp.today_secs  or 0
    local month_secs = sp.month_secs  or 0
    local any_updated = false
    for _, entry in ipairs(widget._rg_update_funcs) do
        if changed and entry.cat and changed[entry.cat] == false then
            -- This row's data was preserved from cache — skip rebuild.
            goto continue
        end
        entry.fn(books_read, today_secs, month_secs)
        any_updated = true
        ::continue::
    end
    return any_updated
end

-- Returns the pixel height of the module including the section label
function M.getHeight(_ctx)
    local n = (showAnnual() and 1 or 0) + (showMonthly() and 1 or 0) + (showDaily() and 1 or 0)
    if n == 0 then return 0 end
    local pfx = _ctx and _ctx.pfx or ""
    local lf = (_ctx and _ctx.landscape_factor) or (UI.isLandscape() and UI.getLandscapeFactor() or 1)
    local label_h = require("infra/sui_config").getScaledLabelH()
    local h = 0
    if isCompact() then
        h = _compactRowsHeight(n, _compactDims(Config.getModuleScale("reading_goals", pfx) * lf))
    else
        local d = _scaledDims(Config.getModuleScale("reading_goals", pfx) * lf)
        h = n * d.goal_row_h + (n == 2 and d.row_gap or 0)
    end
    if SUISettings:isTrue(pfx .. "reading_goals_show_frame") or SUISettings:isTrue(pfx .. "reading_goals_solid_bg") then
        h = h + PAD * 2
    end
    -- Mirrors build()'s wrapped FrameContainer: bordersize is drawn outside
    -- the padding, so the border itself (not just the padding) grows the
    -- real widget by border_sz * 2 pixels whenever the frame is on.
    if SUISettings:isTrue(pfx .. "reading_goals_show_frame") then
        h = h + SUIStyle.BORDER_SZ * 2
    end
    return label_h + h
end

-- Builds the scale menu item for the settings menu
local function _makeScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct("reading_goals", pfx) end,
        set          = function(v) Config.setModuleScale(v, "reading_goals", pfx) end,
        refresh      = ctx_menu.refresh,
    })
end

-- Returns the settings menu items for this module
function M.getMenuItems(ctx_menu)
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._
    local N_lc    = ctx_menu.N_
    local scale_item = _makeScaleItem(ctx_menu)
    return {
        {
            text = _lc("Goals"),
            sub_item_table = {
                {
                    text         = _lc("Annual Goal"),
                    checked_func = function() return showAnnual() end,
                    keep_menu_open = true,
                    callback = function()
                        SUISettings:saveSetting(SHOW_ANNUAL, not showAnnual())
                        refresh()
                    end,
                },
                {
                    text_func = function()
                        local g = getAnnualGoal()
                        return g > 0
                            and string.format(N_lc("  Set Goal  (%d book in %s)", "  Set Goal  (%d books in %s)", g), g, _getYearStr())
                            or  string.format(_lc("  Set Goal  (%s)"), _getYearStr())
                    end,
                    keep_menu_open = true,
                    callback = function() showAnnualGoalDialog(refresh) end,
                },

                {
                    text         = _lc("Monthly Goal"),
                    checked_func = function() return showMonthly() end,
                    keep_menu_open = true,
                    callback = function()
                        SUISettings:saveSetting(SHOW_MONTHLY, not showMonthly())
                        refresh()
                    end,
                },
                {
                    text_func = function()
                        local secs = getMonthlyGoalSecs()
                        local h    = math.floor(secs / 3600)
                        if secs <= 0 then return _lc("  Set Goal  (disabled)")
                        else              return string.format(_lc("  Set Goal  (%d hr/month)"), h) end
                    end,
                    keep_menu_open = true,
                    callback = function() showMonthlySettingsDialog(refresh) end,
                },

                {
                    text         = _lc("Daily Goal"),
                    checked_func = function() return showDaily() end,
                    keep_menu_open = true,
                    callback = function()
                        SUISettings:saveSetting(SHOW_DAILY, not showDaily())
                        refresh()
                    end,
                },
                {
                    text_func = function()
                        local secs = getDailyGoalSecs()
                        local m    = math.floor(secs / 60)
                        if secs <= 0 then return _lc("  Set Goal  (disabled)")
                        else              return string.format(_lc("  Set Goal  (%d min/day)"), m) end
                    end,
                    keep_menu_open = true,
                    callback = function() showDailySettingsDialog(refresh) end,
                },
            },
            sui_build = ctx_menu.is_sui and function(ctx, _item)
                local SUIWindow = require("engines/sui_window")
                return SUIWindow.ListRow{
                    title        = _lc("Goals"),
                    subtitle     = function()
                        local names = {}
                        for _, k in ipairs(_getElemOrder(ctx_menu.pfx)) do
                            if k == "annual"  and showAnnual()   then names[#names + 1] = _lc("Annual Goal")  end
                            if k == "monthly" and showMonthly()  then names[#names + 1] = _lc("Monthly Goal") end
                            if k == "daily"   and showDaily()    then names[#names + 1] = _lc("Daily Goal")   end
                        end
                        return #names > 0 and table.concat(names, "  ·  ") or _lc("No items selected.")
                    end,
                    inner_w      = ctx.inner_w,
                    show_chevron = true,
                    on_tap       = function()
                        ctx.push("arrange", {
                            title = _lc("Goals"),
                            empty_text = _lc("No items selected."),
                            footer_text = _lc("Add Item"),
                            footer_enabled = function()
                                return not showAnnual() or not showMonthly() or not showDaily()
                            end,
                            footer_action = function(ctx2)
                                local picker_items = {}
                                -- Helper: enable a goal kind and append it to the stored order.
                                local function _enable(key, flag_key, label)
                                    picker_items[#picker_items + 1] = {
                                        text   = label,
                                        on_tap = function(picker_ctx)
                                            SUISettings:saveSetting(flag_key, true)
                                            local order     = _getElemOrder(ctx_menu.pfx)
                                            local new_order = {}
                                            for _, k in ipairs(order) do
                                                if k ~= key then new_order[#new_order+1] = k end
                                            end
                                            new_order[#new_order+1] = key
                                            SUISettings:saveSetting(ctx_menu.pfx .. "reading_goals_elem_order", new_order)
                                            refresh()
                                            picker_ctx.pop()
                                            ctx2.repaint()
                                        end
                                    }
                                end
                                if not showAnnual()  then _enable("annual",  SHOW_ANNUAL,  _lc("Annual Goal"))  end
                                if not showMonthly() then _enable("monthly", SHOW_MONTHLY, _lc("Monthly Goal")) end
                                if not showDaily()   then _enable("daily",   SHOW_DAILY,   _lc("Daily Goal"))   end
                                ctx2.push("item_picker", {
                                    title = _lc("Add Item"),
                                    items = picker_items,
                                })
                            end,
                            items_func = function()
                                local sort_items = {}
                                for _, k in ipairs(_getElemOrder(ctx_menu.pfx)) do
                                    if k == "annual" and showAnnual() then
                                        local g = getAnnualGoal()
                                        local subtitle = g > 0
                                            and string.format(N_lc("%d book in %s", "%d books in %s", g), g, _getYearStr())
                                            or  _lc("Not set")
                                        sort_items[#sort_items+1] = {
                                            text       = _lc("Annual Goal"),
                                            subtitle   = subtitle,
                                            orig_item  = "annual",
                                            more_items = {
                                                { text = _lc("Set Goal"), icon = "edit",
                                                  on_tap = function() showAnnualGoalDialog(function() refresh() end) end },
                                            },
                                        }
                                    elseif k == "monthly" and showMonthly() then
                                        local secs = getMonthlyGoalSecs()
                                        local h    = math.floor(secs / 3600)
                                        local subtitle = secs > 0
                                            and string.format(_lc("%d hr/month"), h)
                                            or  _lc("Not set")
                                        sort_items[#sort_items+1] = {
                                            text       = _lc("Monthly Goal"),
                                            subtitle   = subtitle,
                                            orig_item  = "monthly",
                                            more_items = {
                                                { text = _lc("Set Goal"), icon = "edit",
                                                  on_tap = function() showMonthlySettingsDialog(function() refresh() end) end },
                                            },
                                        }
                                    elseif k == "daily" and showDaily() then
                                        local secs = getDailyGoalSecs()
                                        local m    = math.floor(secs / 60)
                                        local subtitle = secs > 0
                                            and string.format(_lc("%d min/day"), m)
                                            or  _lc("Not set")
                                        sort_items[#sort_items+1] = {
                                            text       = _lc("Daily Goal"),
                                            subtitle   = subtitle,
                                            orig_item  = "daily",
                                            more_items = {
                                                { text = _lc("Set Goal"), icon = "edit",
                                                  on_tap = function() showDailySettingsDialog(function() refresh() end) end },
                                            },
                                        }
                                    end
                                end
                                return sort_items
                            end,
                            on_delete = function(item)
                                local flag = item.orig_item == "annual"  and SHOW_ANNUAL
                                          or item.orig_item == "monthly" and SHOW_MONTHLY
                                          or SHOW_DAILY
                                SUISettings:saveSetting(flag, false)
                                refresh()
                            end,
                            on_change = function(items_to_save)
                                local new_order  = {}
                                local active_set = {}
                                for _, it in ipairs(items_to_save) do
                                    new_order[#new_order + 1] = it.orig_item
                                    active_set[it.orig_item]  = true
                                end
                                -- Append inactive elements so their saved position is preserved
                                -- (they'll be filtered by showXxx() guards in _getElemOrder).
                                for _, k in ipairs(_getElemOrder(ctx_menu.pfx)) do
                                    if not active_set[k] then new_order[#new_order + 1] = k end
                                end
                                SUISettings:saveSetting(ctx_menu.pfx .. "reading_goals_elem_order", new_order)
                                refresh()
                            end
                        })
                    end
                }
            end or nil,
        },
        scale_item,
        {
            text_func = function()
                local p = getAnnualPhysical()
                return p > 0
                    and string.format(N_lc("Manually Tracked Books  (%d in %s)", "Manually Tracked Books  (%d in %s)", p), p, _getYearStr())
                    or  string.format(_lc("Manually Tracked Books  (%s)"), _getYearStr())
            end,
            keep_menu_open = true,
            callback = function() showAnnualPhysicalDialog(refresh) end,
            sui_build = ctx_menu.is_sui and function(ctx, _item)
                local SUIWindow = require("engines/sui_window")
                local p = getAnnualPhysical()
                local right = p > 0
                    and string.format(N_lc("%d in %s", "%d in %s", p), p, _getYearStr())
                    or  _getYearStr()
                return SUIWindow.ListRow{
                    inner_w     = ctx.inner_w,
                    title       = _lc("Manually Tracked Books"),
                    right_value = right,
                    separator   = true,
                    on_tap      = function() showAnnualPhysicalDialog(refresh) end,
                }
            end or nil,
        },
        {
            text_func      = function() return _lc("Appearance") end,
            sub_item_table = {
                { text = _lc("Layout"),
                  sub_item_table = {
                      { text         = _lc("Default"),
                        radio        = true,
                        checked_func = function() return not isCompact() end,
                        keep_menu_open = true,
                        callback = function()
                            SUISettings:saveSetting(LAYOUT_KEY, "default")
                            refresh()
                        end },
                      { text         = _lc("Compact"),
                        radio        = true,
                        checked_func = function() return isCompact() end,
                        keep_menu_open = true,
                        callback = function()
                            SUISettings:saveSetting(LAYOUT_KEY, "compact")
                            refresh()
                        end },
                  },
                },
                Config.makeLabelToggleItem("reading_goals", _("Reading Goals"), refresh, _lc),
                {
                    text           = _lc("Frame"),
                    checked_func   = function() return SUISettings:isTrue(ctx_menu.pfx .. "reading_goals_show_frame") end,
                    keep_menu_open = true,
                    callback       = function()
                        SUISettings:saveSetting(ctx_menu.pfx .. "reading_goals_show_frame", not SUISettings:isTrue(ctx_menu.pfx .. "reading_goals_show_frame"))
                        refresh()
                    end,
                },
                {
                    text           = _lc("Solid Background"),
                    checked_func   = function() return SUISettings:isTrue(ctx_menu.pfx .. "reading_goals_solid_bg") end,
                    keep_menu_open = true,
                    callback       = function()
                        SUISettings:saveSetting(ctx_menu.pfx .. "reading_goals_solid_bg", not SUISettings:isTrue(ctx_menu.pfx .. "reading_goals_solid_bg"))
                        refresh()
                    end,
                },
            },
        },
        {
            text           = _lc("Update Stats Now"),
            separator      = true,
            keep_menu_open = true,
            callback       = function()
                local SP = package.loaded["modules/module_stats_provider"]
                if SP and SP.invalidate then SP.invalidate() end
                local SH = package.loaded["modules/module_books_shared"]
                if SH and SH.invalidateSidecarCache then SH.invalidateSidecarCache() end
                local MC = package.loaded["modules/module_currently"]
                if MC and MC.invalidateCache then MC.invalidateCache() end
                local MCD = package.loaded["modules/module_coverdeck"]
                if MCD and MCD.invalidateCache then MCD.invalidateCache() end
                
                -- Invalidate and repaint every known screen (built-in
                -- Homescreen plus any Custom Screen touched this session),
                -- not just the Homescreen — this module may be placed on a
                -- Custom Screen, whose own _cached_books_state/_cfg_cache
                -- would otherwise stay stale after "Update Stats Now" (see
                -- ScreenEngine.knownScreenIds).
                local ScreenEngine = package.loaded["engines/sui_screen_engine"]
                if ScreenEngine then
                    for _, sid in ipairs(ScreenEngine.knownScreenIds()) do
                        ScreenEngine.setCachedBooksState(sid, nil)
                        ScreenEngine.setCfgCache(sid, nil)
                        ScreenEngine.refreshScreen(sid, false)
                    end
                end
                if ctx_menu and type(ctx_menu.refresh) == "function" then ctx_menu.refresh() elseif refresh then refresh() end
                local InfoMessage = ctx_menu and ctx_menu.InfoMessage or require("ui/widget/infomessage")
                local UIM = ctx_menu and ctx_menu.UIManager or require("ui/uimanager")
                UIM:show(InfoMessage:new{ text = _lc("Stats updated successfully."), timeout = 2 })
            end,
        },
    }
end

return M