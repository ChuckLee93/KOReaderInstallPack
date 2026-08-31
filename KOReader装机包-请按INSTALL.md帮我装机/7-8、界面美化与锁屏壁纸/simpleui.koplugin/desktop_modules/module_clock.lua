-- module_clock.lua — Simple UI
-- Clock module: clock always visible, with optional date and battery toggles.
-- Supports "digital" (default) and "word" clock styles.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local datetime        = require("datetime")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local RightContainer  = require("ui/widget/container/rightcontainer")
local Screen          = Device.screen
local _ = require("sui_i18n").translate

local UI           = require("sui_core")
local UIManager    = require("ui/uimanager")
local SUIStyle     = require("sui_style")
local Config       = require("sui_config")
local SUISettings = require("sui_store")
local PAD          = UI.PAD
local PAD2         = UI.PAD2
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

-- ---------------------------------------------------------------------------
-- Translated date string
-- os.date("%A, %d %B") always returns English on most eReader locales.
-- We use os.date("*t") for the numeric indices and look up translated names.
-- ---------------------------------------------------------------------------

-- _WEEKDAYS and _MONTHS are intentionally NOT built at module-load time so
-- that _() is called after the user's locale has been applied. They are built
-- on the first _localDate() call and reused from that point on — the locale
-- never changes within a running KOReader session, so caching is safe.
local _weekdays = nil
local _months   = nil

local function _localDate()
    -- Pass os.time() explicitly: os.date("*t") without argument can return
    -- nil in LuaJIT on some platforms (macOS emulator) when timezone handling
    -- fails. os.date("*t", os.time()) is always safe.
    local now = os.time()
    local t   = os.date("*t", now)
    if not t or not t.mday then
        -- Fallback via the datetime module's locale-aware formatter.
        return datetime.secondsToDate(now, true)
    end
    -- Build translation tables on first call only; never recreated afterwards.
    if not _weekdays then
        _weekdays = {
            _("Sunday"), _("Monday"), _("Tuesday"), _("Wednesday"),
            _("Thursday"), _("Friday"), _("Saturday"),
        }
        _months = {
            _("January"), _("February"), _("March"),     _("April"),
            _("May"),     _("June"),     _("July"),       _("August"),
            _("September"), _("October"), _("November"),  _("December"),
        }
    end
    local weekday = _weekdays[t.wday] or os.date("%A", now)
    local month   = _months[t.month]  or os.date("%B", now)
    return string.format("%s, %d %s", weekday, t.mday, month)
end

-- ---------------------------------------------------------------------------
-- Pixel constants — base values at 100% scale; scaled at render time.
-- ---------------------------------------------------------------------------

local _BASE_CLOCK_W       = Screen:scaleBySize(70)
local _BASE_CLOCK_FS      = 75  -- display clock — intentionally oversized, not part of type scale
local _BASE_DATE_H        = Screen:scaleBySize(17)
local _BASE_DATE_GAP      = Screen:scaleBySize(19)
local _BASE_DATE_FS       = SUIStyle.FS_SUBTITLE  -- 20: date text
local _BASE_BATT_FS       = SUIStyle.FS_BODY      -- 18: battery text
local _BASE_BATT_H        = Screen:scaleBySize(15)
local _BASE_BATT_GAP      = Screen:scaleBySize(19)
local _BASE_BOT_PAD_EXTRA = Screen:scaleBySize(4)

-- Word clock: font size for the hour line (minutes line inherits same size).
-- Smaller than the digital clock because two lines need to fit in the same
-- vertical budget (_BASE_CLOCK_W × 2, one line each).
local _BASE_WORD_FS       = 50  -- intentionally oversized; scaled at render time

-- ---------------------------------------------------------------------------
-- Settings keys
-- ---------------------------------------------------------------------------

local SETTING_ON        = "clock_enabled"    -- pfx .. "clock_enabled"
local SETTING_DATE      = "clock_date"       -- pfx .. "clock_date"      (default ON)
local SETTING_BATTERY   = "clock_battery"    -- pfx .. "clock_battery"   (default ON)
local SETTING_DATE_GAP  = "clock_date_gap"   -- pfx .. "clock_date_gap"  (integer %, default 100)
local SETTING_BATT_GAP  = "clock_batt_gap"   -- pfx .. "clock_batt_gap"  (integer %, default 100)
local SETTING_ALIGN     = "clock_align"      -- pfx .. "clock_align"     (default "center")
local SETTING_STYLE     = "clock_style"      -- pfx .. "clock_style"     ("digital"|"word", default "digital")

local ALIGN_VALUES = { "left", "center", "right" }
local STYLE_VALUES = { "digital", "word" }

local function getAlignment(pfx)
    local v = SUISettings:readSetting(pfx .. SETTING_ALIGN)
    for _, a in ipairs(ALIGN_VALUES) do if a == v then return v end end
    return "center"  -- default
end

local function setAlignment(pfx, val)
    SUISettings:saveSetting(pfx .. SETTING_ALIGN, val)
end

local function alignLabel(align, _lc)
    if align == "left"  then return _lc("Left")  end
    if align == "right" then return _lc("Right") end
    return _lc("Center")
end

local function getClockStyle(pfx)
    local v = SUISettings:readSetting(pfx .. SETTING_STYLE)
    for _, s in ipairs(STYLE_VALUES) do if s == v then return v end end
    return "digital"  -- default
end

local function setClockStyle(pfx, val)
    SUISettings:saveSetting(pfx .. SETTING_STYLE, val)
end

local ELEM_GAP_MIN  = 0
local ELEM_GAP_MAX  = 300
local ELEM_GAP_STEP = 10
local ELEM_GAP_DEF  = 100

local function _clampElemGap(n)
    return math.max(ELEM_GAP_MIN, math.min(ELEM_GAP_MAX, math.floor(n)))
end

local function getDateGapPct(pfx)
    local v = SUISettings:readSetting(pfx .. SETTING_DATE_GAP)
    local n = tonumber(v)
    return n and _clampElemGap(n) or ELEM_GAP_DEF
end

local function getBattGapPct(pfx)
    local v = SUISettings:readSetting(pfx .. SETTING_BATT_GAP)
    local n = tonumber(v)
    return n and _clampElemGap(n) or ELEM_GAP_DEF
end

local function isClockEnabled(pfx)
    local v = SUISettings:readSetting(pfx .. SETTING_ON)
    return v ~= false   -- default ON
end

local function isDateEnabled(pfx)
    local v = SUISettings:readSetting(pfx .. SETTING_DATE)
    return v ~= false   -- default ON
end

local function isBattEnabled(pfx)
    local v = SUISettings:readSetting(pfx .. SETTING_BATTERY)
    return v ~= false   -- default ON
end

-- ---------------------------------------------------------------------------
-- Word clock — numeric time-to-words conversion
-- ---------------------------------------------------------------------------
--
-- Converts a (hour, minute) pair to two lines of spelled-out numbers.
-- Examples (12-hour mode, English defaults):
--   12:00  → "Twelve\nO'Clock"
--   12:05  → "Twelve\nOh Five"
--   12:15  → "Twelve\nFifteen"
--   12:30  → "Twelve\nThirty"
--   12:50  → "Twelve\nFifty"
--   12:21  → "Twelve\nTwenty-One"
--
-- Every word is individually wrapped in _() so translators get atomic
-- units.  The tens-units separator is also a translatable string
-- ("WORD_CLOCK_TENS_SEP") — it is "-" in English but " e " in Portuguese,
-- allowing correct "Vinte e Um" vs "Twenty-One" without any code changes.
--
-- For 24-hour mode the hour table is extended to 0–23.  Hours 13–23 use the
-- same words as 1–11 for simplicity (e.g. 14:00 → "Fourteen\nO'Clock"),
-- which matches how people actually say 24h times in most languages.
-- ---------------------------------------------------------------------------

-- Units 1–19 (used for hours 1–12 / 13–19 and for minute values 1–19).
-- Each string is a standalone translatable token.
local _WORD_UNITS = {
    [1]  = _("One"),
    [2]  = _("Two"),
    [3]  = _("Three"),
    [4]  = _("Four"),
    [5]  = _("Five"),
    [6]  = _("Six"),
    [7]  = _("Seven"),
    [8]  = _("Eight"),
    [9]  = _("Nine"),
    [10] = _("Ten"),
    [11] = _("Eleven"),
    [12] = _("Twelve"),
    [13] = _("Thirteen"),
    [14] = _("Fourteen"),
    [15] = _("Fifteen"),
    [16] = _("Sixteen"),
    [17] = _("Seventeen"),
    [18] = _("Eighteen"),
    [19] = _("Nineteen"),
}

-- Exact tens for minutes 20, 30, 40, 50.
local _WORD_TENS = {
    [2] = _("Twenty"),
    [3] = _("Thirty"),
    [4] = _("Forty"),
    [5] = _("Fifty"),
}

-- Hour zero (midnight/noon special case — used in 24h mode for hour 0).
local _WORD_MIDNIGHT = _("Midnight")
local _WORD_NOON     = _("Noon")

-- Special minute tokens.
local _WORD_OCLOCK = _("O'Clock")
local _WORD_OH     = _("Oh")        -- prefix for minutes 1–9 ("Oh Five")

-- Separator between tens and units in compound minute strings.
-- Translators replace this with the appropriate connector for their language:
--   English  → "-"       → "Twenty-One"
--   Portuguese → " e "   → "Vinte e Um"
--   French   → "-"       → "Vingt-et-Un" (handled differently, but "-" works)
local _WORD_TENS_SEP = _("WORD_CLOCK_TENS_SEP")

-- Cached translated tables are rebuilt once per session (locale is fixed).
-- We rebuild lazily on first call rather than at module load to guarantee
-- that _() has already resolved the user's locale.
local _wc_units_cache = nil
local _wc_tens_cache  = nil
local _wc_sep_cache   = nil

local function _wcCache()
    if _wc_units_cache then return end
    _wc_units_cache = {
        [1]  = _("One"),        [2]  = _("Two"),       [3]  = _("Three"),
        [4]  = _("Four"),       [5]  = _("Five"),      [6]  = _("Six"),
        [7]  = _("Seven"),      [8]  = _("Eight"),     [9]  = _("Nine"),
        [10] = _("Ten"),        [11] = _("Eleven"),    [12] = _("Twelve"),
        [13] = _("Thirteen"),   [14] = _("Fourteen"),  [15] = _("Fifteen"),
        [16] = _("Sixteen"),    [17] = _("Seventeen"), [18] = _("Eighteen"),
        [19] = _("Nineteen"),
    }
    _wc_tens_cache = {
        [2] = _("Twenty"), [3] = _("Thirty"),
        [4] = _("Forty"),  [5] = _("Fifty"),
    }
    -- Fallback to "-" if the translator left WORD_CLOCK_TENS_SEP untranslated.
    local sep = _("WORD_CLOCK_TENS_SEP")
    _wc_sep_cache = (sep == "WORD_CLOCK_TENS_SEP") and "-" or sep
end

-- Converts a minute value [0..59] to its word representation.
-- Returns the translated minute string, or nil for :00 (caller adds O'Clock).
local function _minToWords(min)
    if min == 0 then return nil end
    _wcCache()
    if min < 10 then
        -- "Oh Five", "Oh Nine"
        return _("Oh") .. " " .. _wc_units_cache[min]
    elseif min < 20 then
        -- "Ten" … "Nineteen" — direct lookup
        return _wc_units_cache[min]
    else
        local tens  = math.floor(min / 10)
        local units = min % 10
        if units == 0 then
            return _wc_tens_cache[tens]
        else
            return _wc_tens_cache[tens] .. _wc_sep_cache .. _wc_units_cache[units]
        end
    end
end

-- Converts hour + minute to a two-line word-clock string.
-- @param hour      number   0–23
-- @param min       number   0–59
-- @param is_12h    boolean  true = 12-hour display
-- @return          string   e.g. "Twelve\nFifty" or "Twelve\nO'Clock"
local function timeToWords(hour, min, is_12h)
    _wcCache()

    local h
    if is_12h then
        h = hour % 12
        if h == 0 then h = 12 end
    else
        -- 24h: use 0–23 but map 0 to Midnight for readability.
        h = hour
    end

    local hour_str
    if h == 0 then
        hour_str = _("Midnight")
    elseif h == 12 and not is_12h then
        -- In 24h mode, noon is special.
        hour_str = _("Noon")
    elseif _wc_units_cache[h] then
        hour_str = _wc_units_cache[h]
    else
        -- Hours 20–23 in 24h mode — compose from tens+units.
        local tens  = math.floor(h / 10)
        local units = h % 10
        if units == 0 then
            hour_str = _wc_tens_cache[tens] or tostring(h)
        else
            hour_str = (_wc_tens_cache[tens] or "") .. _wc_sep_cache .. (_wc_units_cache[units] or tostring(units))
        end
    end

    local min_str = _minToWords(min)
    if min_str then
        return hour_str .. "\n" .. min_str
    else
        return hour_str .. "\n" .. _("O'Clock")
    end
end

-- ---------------------------------------------------------------------------
-- Word clock widget builder
--
-- Returns a VerticalGroup containing two TextBoxWidget lines (hour + minutes)
-- so that each line can be centred/aligned independently within inner_w.
-- Using two separate widgets (rather than one multi-line TextBoxWidget) gives
-- us reliable height control on e-ink devices, where multi-line TextBoxWidget
-- getSize() sometimes reports incorrect heights before the first paint.
-- ---------------------------------------------------------------------------

local function _buildWordClockWidget(text, face, inner_w, align, theme_fg)
    -- Split the "Hour\nMinutes" string into two parts.
    local nl = text:find("\n")
    local line1 = nl and text:sub(1, nl - 1) or text
    local line2 = nl and text:sub(nl + 1)    or ""

    local ContainerClass = CenterContainer
    if align == "left"  then ContainerClass = LeftContainer  end
    if align == "right" then ContainerClass = RightContainer end

    -- Measure a single line height once.
    local probe = TextWidget:new{ text = line1, face = face, bold = true }
    local line_h = probe:getSize().h
    probe:free()

    local function makeLine(txt)
        local wgt = UI.makeColoredText{
            text    = txt,
            face    = face,
            bold    = true,
            fgcolor = theme_fg,
        }
        if not wgt.dimen then wgt.dimen = wgt:getSize() end
        return ContainerClass:new{
            dimen = Geom:new{ w = inner_w, h = line_h },
            wgt,
        }
    end

    local vg = VerticalGroup:new{ align = align }
    vg[1] = makeLine(line1)
    if line2 ~= "" then
        vg[2] = VerticalSpan:new{ width = math.floor(line_h * 0.10) }
        vg[3] = makeLine(line2)
    end
    return vg
end

-- ---------------------------------------------------------------------------
-- Battery helpers
-- ---------------------------------------------------------------------------

-- Returns battery level clamped to [0,100] and charging flag.
local function _battInfo()
    local pwr = Device:getPowerDevice()
    if not pwr then return nil, false end
    local lvl, charging = nil, false
    if pwr.getCapacity then
        local ok, v = pcall(pwr.getCapacity, pwr)
        if ok and type(v) == "number" then
            lvl = v < 0 and 0 or v > 100 and 100 or v
        end
    end
    if pwr.isCharging then
        local ok, v = pcall(pwr.isCharging, pwr); if ok then charging = v end
    end
    return lvl, charging
end

-- lvl is always a number in [0,100] or nil (normalised by _battInfo).
-- Battery always uses CLR_TEXT_SUB — same subdued grey as date and author text.

-- Builds the battery display string.
-- Uses ▰/▱ (filled/empty blocks) matching module_header.lua visual style.
-- Charging replaces the first block with ⚡.
local function _battText(lvl, charging)
    if type(lvl) ~= "number" then return "N/A" end
    local bars
    if     lvl >= 90 then bars = "▰▰▰▰"
    elseif lvl >= 60 then bars = "▰▰▰▱"
    elseif lvl >= 40 then bars = "▰▰▱▱"
    elseif lvl >= 20 then bars = "▰▱▱▱"
    else                  bars = "▱▱▱▱" end
    local icon = charging and ("⚡" .. bars:sub(4)) or bars
    return string.format("%s %d%%", icon, lvl)
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

local function _vspan(px, pool)
    if pool then
        if not pool[px] then pool[px] = VerticalSpan:new{ width = px } end
        return pool[px]
    end
    return VerticalSpan:new{ width = px }
end

local function build(w, pfx, vspan_pool)
    local scale     = Config.getModuleScale("clock", pfx)

    -- Scale all dimensions from base values.
    local clock_w       = math.floor(_BASE_CLOCK_W       * scale)
    local clock_fs      = math.max(10, math.floor(_BASE_CLOCK_FS  * scale))
    local word_fs       = math.max(10, math.floor(_BASE_WORD_FS   * scale))
    local date_h        = math.max(8,  math.floor(_BASE_DATE_H    * scale))
    local date_gap      = math.max(0,  math.floor(_BASE_DATE_GAP  * scale * getDateGapPct(pfx) / 100))
    local batt_gap      = math.max(0,  math.floor(_BASE_BATT_GAP  * scale * getBattGapPct(pfx) / 100))
    local date_fs       = math.max(8,  math.floor(_BASE_DATE_FS   * scale))
    local batt_fs       = math.max(7,  math.floor(_BASE_BATT_FS   * scale))
    local batt_h        = math.max(7,  math.floor(_BASE_BATT_H    * scale))

    local bot_pad_extra = math.floor(_BASE_BOT_PAD_EXTRA * scale)

    local show_clock  = isClockEnabled(pfx)
    local show_date   = isDateEnabled(pfx)
    local show_batt   = isBattEnabled(pfx)
    local clock_style = getClockStyle(pfx)
    local inner_w     = w - PAD * 2

    -- Theme: when fg is set, use it for sub-text; otherwise fall back to CLR_TEXT_SUB.
    local theme_fg         = SUIStyle.getThemeColor("fg")
    local theme_secondary  = SUIStyle.getThemeColor("text_secondary")
    local sub_fg           = theme_secondary or theme_fg or CLR_TEXT_SUB

    local align = getAlignment(pfx)
    local ContainerClass = CenterContainer
    if align == "left" then ContainerClass = LeftContainer
    elseif align == "right" then ContainerClass = RightContainer end

    local vg = VerticalGroup:new{ align = align }

    local function wrapText(wgt)
        if not wgt.dimen then wgt.dimen = wgt:getSize() end
        return wgt
    end

    -- Clock
    if show_clock then
        if clock_style == "word" then
            -- Word clock: two lines of text, each sized word_fs.
            local is_12h = G_reader_settings:isTrue("twelve_hour_clock")
            local t      = os.date("*t", os.time())
            local wc_text = timeToWords(t.hour, t.min, is_12h)
            local face    = Font:getFace(SUIStyle.FACE_REGULAR, word_fs)
            -- Two lines × line_h each; use clock_w × 2 as the container budget.
            local wc_widget = _buildWordClockWidget(wc_text, face, inner_w, align, theme_fg)
            vg[#vg+1] = wc_widget
        else
            -- Digital clock (original behaviour).
            vg[#vg+1] = ContainerClass:new{
                dimen = Geom:new{ w = inner_w, h = clock_w },
                wrapText(UI.makeColoredText{
                    text    = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")),
                    face    = Font:getFace(SUIStyle.FACE_REGULAR, clock_fs),
                    bold    = true,
                    fgcolor = theme_fg,   -- nil → KOReader default (black); honours theme palette
                }),
            }
        end
    end

    if show_date then
        vg[#vg+1] = _vspan(date_gap, vspan_pool)
        vg[#vg+1] = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = date_h },
            TextWidget:new{
                -- text    = os.date("%A, %d %B"),
                text    = os.date("星期%w"):gsub("星期0", "星期日"):gsub("星期1", "星期一"):gsub("星期2", "星期二"):gsub("星期3", "星期三"):gsub("星期4", "星期四"):gsub("星期5", "星期五"):gsub("星期6", "星期六") .. "，" .. os.date("%m月%d日"),
                face    = Font:getFace("smallinfofont", date_fs),
                fgcolor = CLR_TEXT_SUB,
            },
        }
    end

    if show_batt then
        if #vg > 0 then vg[#vg+1] = _vspan(batt_gap, vspan_pool) end
        local lvl, charging = _battInfo()
        vg[#vg+1] = ContainerClass:new{
            dimen = Geom:new{ w = inner_w, h = batt_h },
            wrapText(UI.makeColoredText{
                text    = _battText(lvl, charging),
                face    = Font:getFace(SUIStyle.FACE_REGULAR, batt_fs),
                fgcolor = sub_fg,
            }),
        }
    end

    if #vg == 0 then return nil end

    return FrameContainer:new{
        bordersize     = 0,
        padding        = PAD,
        padding_bottom = PAD2 + bot_pad_extra,
        vg,
    }
end

-- ---------------------------------------------------------------------------
-- Module API
-- ---------------------------------------------------------------------------

local M = {}

M.id         = "clock"
M.name       = _("Clock")
M.label      = nil
M.default_on = true

function M.isEnabled(pfx)
    return isClockEnabled(pfx) or isDateEnabled(pfx) or isBattEnabled(pfx)
end

function M.setEnabled(pfx, on)
    if not on then
        -- O módulo foi removido do layout: apaga todas as flags de visibilidade
        -- para que um re-add futuro comece com defaults limpos.
        SUISettings:saveSetting(pfx .. SETTING_ON,      false)
        SUISettings:saveSetting(pfx .. SETTING_DATE,    false)
        SUISettings:saveSetting(pfx .. SETTING_BATTERY, false)
    else
        -- O módulo está no layout: apenas activa o clock em si.
        -- SETTING_DATE e SETTING_BATTERY NÃO são tocados — se já existem,
        -- respeitam a preferência do utilizador; se são nil, isBattEnabled /
        -- isDateEnabled usam os seus próprios defaults (ON para ambos).
        SUISettings:saveSetting(pfx .. SETTING_ON, true)
    end
end

M.getCountLabel = nil

-- ---------------------------------------------------------------------------
-- Surgical clock tick — rebuilds only the clock widget inside the body
-- VerticalGroup, without triggering a full homescreen rebuild.
--
-- The homescreen records _clock_body_ref, _clock_body_idx, and
-- _clock_is_wrapped during _buildContent() (see below).  The tick reads
-- those fields to do a targeted swap, then marks only the navbar container
-- dirty.  Falls back to a full _refresh() if the index was not recorded.
-- ---------------------------------------------------------------------------

local _timer     = nil   -- scheduled function reference (module-level singleton)
local _hs_widget = nil   -- weak reference to the live HomescreenWidget

local function _tick()
    _timer = nil   -- timer has fired; clear before rescheduling

    -- Abort if the homescreen instance has changed or gone away.
    local hs = _hs_widget
    if not hs then return end
    local HS = package.loaded["sui_homescreen"]
    if not HS or HS._instance ~= hs then _hs_widget = nil; return end

    -- Do not update while suspended — some platforms fire pending timers
    -- during the suspend transition before the scheduler pauses.
    -- Crucially: do NOT reschedule here. Rescheduling would create a new timer
    -- that onSuspend can no longer cancel (it already ran), causing a 60s loop
    -- that keeps firing throughout the entire suspend period.
    -- HomescreenWidget:onResume calls ClockMod.scheduleRefresh() to restart the
    -- chain on wakeup — no action needed here.
    --
    -- Two complementary guards:
    -- • hs._suspended — set by HomescreenWidget:onSuspend() when the Suspend
    --   event reaches the widget via broadcastEvent.
    -- • plugin._simpleui_suspended — set by SimpleUIPlugin:onSuspend(), which
    --   runs in the same broadcastEvent pass but may arrive before or after the
    --   widget handler depending on stack order. Checking both closes the race
    --   window where the UIManager has already dequeued this timer for execution
    --   in the current tick before either flag was set.
    local FM = package.loaded["apps/filemanager/filemanager"]
    local plugin = FM and FM.instance and FM.instance._simpleui_plugin
    if hs._suspended or (plugin and plugin._simpleui_suspended) or Device.screen_saver_mode then
        return
    end

    -- Do not update while a book is open — the homescreen is hidden anyway.
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then
        M.scheduleRefresh(hs)
        return
    end

    -- Fast path: swap only the clock widget in the body VerticalGroup.
    local body       = hs._clock_body_ref
    local idx        = hs._clock_body_idx
    local is_wrapped = hs._clock_is_wrapped
    local swapped    = false

    if body and idx and body[idx] and hs._navbar_container then
        local sw      = Screen:getWidth()
        local SIDE_PAD = require("sui_core").SIDE_M()
        local inner_w  = hs._clock_inner_w or (sw - SIDE_PAD * 2)

        -- In landscape mode the homescreen applies a scale reduction factor to
        -- all modules.  Replicate it here so the surgical swap produces a widget
        -- at the same size as the one built during _updatePage.
        local lf = hs._clock_landscape_factor
        local _orig_getModuleScale, _orig_getLabelScale, _orig_getThumbScale
        if lf then
            _orig_getModuleScale = Config.getModuleScale
            _orig_getLabelScale  = Config.getLabelScale
            _orig_getThumbScale  = Config.getThumbScale
            Config.getModuleScale = function(mod_id, pfx)
                return _orig_getModuleScale(mod_id, pfx) * lf
            end
            Config.getLabelScale = function()
                return _orig_getLabelScale() * lf
            end
            Config.getThumbScale = function(mod_id, pfx)
                return _orig_getThumbScale(mod_id, pfx) * lf
            end
        end

        local ok_w, new_widget = pcall(build, inner_w, hs._clock_pfx,
                                        hs._vspan_pool)

        if lf then
            Config.getModuleScale = _orig_getModuleScale
            Config.getLabelScale  = _orig_getLabelScale
            Config.getThumbScale  = _orig_getThumbScale
        end

        if ok_w and new_widget then
            if is_wrapped then
                -- The clock was wrapped in an InputContainer for hold-to-settings.
                -- Replace the inner slot [1] to keep the gesture handler alive.
                body[idx][1] = new_widget
            else
                body[idx] = new_widget
            end
            UIManager:setDirty(hs, "ui")
            swapped = true
        end
    end

    if not swapped then
        -- Slow-path fallback — only triggered when the clock module is on the
        -- current page but build() failed (e.g. transient font-cache miss).
        -- idx == nil means clock is simply not on the current page: nothing to
        -- repaint, so skip the rebuild entirely.
        -- Use _updatePage(true) directly — same as the original _clockTick:
        -- immediate, keeps book/stats caches intact, no unnecessary DB roundtrips.
        if idx ~= nil and hs._navbar_container then
            local ok = pcall(function()
                hs:_updatePage(true)
                UIManager:setDirty(hs, "ui")
            end)
            if not ok then _hs_widget = nil; return end
        end
    end

    -- ---------------------------------------------------------------------------
    -- Topbar clock synchronisation.
    -- Both clocks use the formula 60-(os.time()%60)+1 to schedule their next tick.
    -- If they start from different moments (e.g. topbar restarted by a frontlight
    -- event mid-minute) they phase-drift and show different minutes.
    --
    -- Fix: drive the topbar refresh from this same callback, so both clocks read
    -- os.time() at the same moment and calculate the same next-tick delay.
    -- After this call, both chains reschedule to the identical next boundary.
    --
    -- `plugin` was resolved above for the suspend guard — reuse it here.
    -- ---------------------------------------------------------------------------
    if plugin and not plugin._simpleui_suspended then
        local Topbar = package.loaded["sui_topbar"]
        if Topbar then
            -- Cancel the topbar's own pending timer before refreshing — without
            -- this, the topbar would fire again on its old schedule in addition
            -- to the reschedule at the end of Topbar.refresh().
            if plugin._topbar_timer then
                UIManager:unschedule(plugin._topbar_timer)
                plugin._topbar_timer = nil
            end
            pcall(Topbar.refresh, Topbar, plugin)
        end
    end

    M.scheduleRefresh(hs)
end

-- Schedule the next tick, aligned to the next minute boundary.
-- Safe to call repeatedly — cancels any pending timer first.
function M.scheduleRefresh(hs)
    if _timer then
        UIManager:unschedule(_timer)
        _timer = nil
    end
    _hs_widget = hs
    local secs = 60 - (os.time() % 60) + 1
    _timer = _tick
    UIManager:scheduleIn(secs, _timer)
end

-- Cancel any pending timer and release the homescreen reference.
-- Called from onSuspend and onCloseWidget.
function M.cancelRefresh()
    if _timer then
        UIManager:unschedule(_timer)
        _timer = nil
    end
    _hs_widget = nil
end

function M.build(w, ctx)
    -- Record swap coordinates on the homescreen widget so the tick can do a
    -- surgical replacement without rebuilding the entire page.  These fields
    -- are written here (inside build) because build() is called from within
    -- the module loop in _buildContent(), at which point the body index is
    -- not yet known to the homescreen.  The homescreen sets _clock_body_idx
    -- immediately after build() returns (see sui_homescreen.lua).
    if ctx._hs_widget then
        ctx._hs_widget._clock_pfx      = ctx.pfx
        ctx._hs_widget._clock_inner_w  = w
    end
    return build(w, ctx.pfx, ctx.vspan_pool)
end

function M.getHeight(ctx)
    local scale     = Config.getModuleScale("clock", ctx.pfx)
    local clock_w   = math.floor(_BASE_CLOCK_W   * scale)
    local date_h    = math.max(8, math.floor(_BASE_DATE_H   * scale))
    local date_gap  = math.max(0, math.floor(_BASE_DATE_GAP * scale * getDateGapPct(ctx.pfx) / 100))
    local batt_gap  = math.max(0, math.floor(_BASE_BATT_GAP * scale * getBattGapPct(ctx.pfx) / 100))
    local batt_h    = math.max(7, math.floor(_BASE_BATT_H   * scale))

    local h_base      = PAD * 2 + PAD2
    local show_clock  = isClockEnabled(ctx.pfx)
    local show_date   = isDateEnabled(ctx.pfx)
    local show_batt   = isBattEnabled(ctx.pfx)

    -- Word clock occupies approximately two digital-clock lines.
    -- Use 2 × clock_w as the budget so getHeight() stays stable regardless of
    -- whether font metrics are available at estimation time.
    local clock_h
    if show_clock and getClockStyle(ctx.pfx) == "word" then
        clock_h = clock_w * 2
    else
        clock_h = clock_w
    end

    local h = h_base
    if show_clock then h = h + clock_h end
    if show_date  then
        h = h + date_h
        if show_clock then h = h + date_gap end
    end
    if show_batt  then
        h = h + batt_h
        if show_clock or show_date then h = h + batt_gap end
    end
    return h
end


local function _makeScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct("clock", pfx) end,
        set          = function(v) Config.setModuleScale(v, "clock", pfx) end,
        refresh      = ctx_menu.refresh,
    })
end

function M.getMenuItems(ctx_menu)
    local pfx     = ctx_menu.pfx
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._

    local function toggle(key, current)
        SUISettings:saveSetting(pfx .. key, not current)
        refresh()
    end

    return {
        {
            text           = _lc("Show Clock"),
            checked_func   = function() return isClockEnabled(pfx) end,
            keep_menu_open = true,
            callback       = function() toggle(SETTING_ON, isClockEnabled(pfx)) end,
        },
        {
            text           = _lc("Show Date"),
            checked_func   = function() return isDateEnabled(pfx) end,
            keep_menu_open = true,
            callback       = function() toggle(SETTING_DATE, isDateEnabled(pfx)) end,
        },
        {
            text           = _lc("Show Battery"),
            checked_func   = function() return isBattEnabled(pfx) end,
            keep_menu_open = true,
            callback       = function() toggle(SETTING_BATTERY, isBattEnabled(pfx)) end,
        },
        _makeScaleItem(ctx_menu),
        {
            -- Clock Style submenu: Digital / Word
            text_func  = function() return _lc("Clock Style") end,
            value_func = function()
                return getClockStyle(pfx) == "word" and _lc("Word") or _lc("Digital")
            end,
            sub_item_table = {
                {
                    text         = _lc("Digital") .. "  (12:50)",
                    radio        = true,
                    checked_func = function() return getClockStyle(pfx) == "digital" end,
                    keep_menu_open = true,
                    callback     = function() setClockStyle(pfx, "digital"); refresh() end,
                },
                {
                    text         = _lc("Word") .. "  (Twelve Fifty)",
                    radio        = true,
                    checked_func = function() return getClockStyle(pfx) == "word" end,
                    keep_menu_open = true,
                    callback     = function() setClockStyle(pfx, "word"); refresh() end,
                },
            },
        },
        {
            text_func  = function() return _lc("Alignment") end,
            value_func = function() return alignLabel(getAlignment(pfx), _lc) end,
            separator      = true,
            sub_item_table = {
                {
                    text           = _lc("Left"),
                    radio          = true,
                    checked_func   = function() return getAlignment(pfx) == "left" end,
                    keep_menu_open = true,
                    callback       = function() setAlignment(pfx, "left"); refresh() end,
                },
                {
                    text           = _lc("Center"),
                    radio          = true,
                    checked_func   = function() return getAlignment(pfx) == "center" end,
                    keep_menu_open = true,
                    callback       = function() setAlignment(pfx, "center"); refresh() end,
                },
                {
                    text           = _lc("Right"),
                    radio          = true,
                    checked_func   = function() return getAlignment(pfx) == "right" end,
                    keep_menu_open = true,
                    callback       = function() setAlignment(pfx, "right"); refresh() end,
                },
            },
        },
        {
            text_func      = function() return _lc("Date Spacing") end,
            value_func     = function() return getDateGapPct(pfx) .. "%" end,
            enabled_func   = function() return isDateEnabled(pfx) end,
            keep_menu_open = true,
            callback       = function()
                local SpinWidget = require("ui/widget/spinwidget")
                local UIManager_ = require("ui/uimanager")
                UIManager_:show(SpinWidget:new{
                    title_text    = _lc("Date Spacing"),
                    info_text     = _lc("Vertical space between the clock and the date.\n100% is the default spacing."),
                    value         = getDateGapPct(pfx),
                    value_min     = ELEM_GAP_MIN,
                    value_max     = ELEM_GAP_MAX,
                    value_step    = ELEM_GAP_STEP,
                    unit          = "%",
                    ok_text       = _lc("Apply"),
                    cancel_text   = _lc("Cancel"),
                    default_value = ELEM_GAP_DEF,
                    callback      = function(spin)
                        SUISettings:saveSetting(pfx .. SETTING_DATE_GAP, _clampElemGap(spin.value))
                        refresh()
                    end,
                })
            end,
        },
        {
            text_func      = function() return _lc("Battery Spacing") end,
            value_func     = function() return getBattGapPct(pfx) .. "%" end,
            enabled_func   = function() return isBattEnabled(pfx) end,
            keep_menu_open = true,
            callback       = function()
                local SpinWidget = require("ui/widget/spinwidget")
                local UIManager_ = require("ui/uimanager")
                UIManager_:show(SpinWidget:new{
                    title_text    = _lc("Battery Spacing"),
                    info_text     = _lc("Vertical space between the date (or clock) and the battery.\n100% is the default spacing."),
                    value         = getBattGapPct(pfx),
                    value_min     = ELEM_GAP_MIN,
                    value_max     = ELEM_GAP_MAX,
                    value_step    = ELEM_GAP_STEP,
                    unit          = "%",
                    ok_text       = _lc("Apply"),
                    cancel_text   = _lc("Cancel"),
                    default_value = ELEM_GAP_DEF,
                    callback      = function(spin)
                        SUISettings:saveSetting(pfx .. SETTING_BATT_GAP, _clampElemGap(spin.value))
                        refresh()
                    end,
                })
            end,
        },
    }
end

return M
