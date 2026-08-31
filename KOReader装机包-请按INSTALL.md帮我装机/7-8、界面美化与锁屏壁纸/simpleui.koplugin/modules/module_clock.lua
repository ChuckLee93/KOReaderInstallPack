-- module_clock.lua — Simple UI
-- Clock module: clock always visible, with optional date and battery toggles.
-- Supports "digital", "word" and "analogue" clock styles.

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
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen          = Device.screen
local _ = require("infra/sui_i18n").translate

local UI           = require("infra/sui_core")
local UIManager    = require("ui/uimanager")
local SUIStyle     = require("features/sui_style")
local Config       = require("infra/sui_config")
local SUISettings = require("infra/sui_store")
local AAPaint      = require("infra/sui_aa_paint")
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
    if not t or not t.day then
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
    return string.format("%s, %s%d日", weekday, month, t.day)
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
-- Base clock size, as a percentage of inner_w (mirrors
-- GridRenderer.computeAutoFitCell's convention: 100% scale = fitted to
-- available width, not a fixed physical/point constant). Only the headline
-- elements (digital clock, word clock, and their row-height box) move to
-- this convention — date/battery keep using SUIStyle's shared type scale
-- (FS_SUBTITLE/FS_BODY), same as every other module, since they aren't
-- "the module's own size".
--
-- The percentages are derived once from the previous fixed constants
-- against a reference full-width single column, so existing single-column
-- Homescreen layouts keep the same default look; narrower columns
-- (multi-column Custom Screens, landscape spread) now shrink proportionally
-- instead of staying pinned to the old absolute size.
-- ---------------------------------------------------------------------------
local _REF_INNER_W  = Screen:getWidth() - UI.SIDE_PAD * 2 - PAD * 2
local _CLOCK_FS_PCT = _BASE_CLOCK_FS / _REF_INNER_W
local _WORD_FS_PCT  = _BASE_WORD_FS  / _REF_INNER_W
local _CLOCK_W_PCT  = _BASE_CLOCK_W  / _REF_INNER_W
local _CLOCK_FS_MIN = 10
local _WORD_FS_MIN  = 10

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
local STYLE_VALUES = { "digital", "word", "analogue" }

-- Reads a setting and validates it against a fixed list of allowed values,
-- falling back to `default` for unset or corrupted entries.
local function _readEnum(pfx, key, values, default)
    local v = SUISettings:readSetting(pfx .. key)
    for _, allowed in ipairs(values) do if allowed == v then return v end end
    return default
end

local function getAlignment(pfx)
    return _readEnum(pfx, SETTING_ALIGN, ALIGN_VALUES, "center")
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
    return _readEnum(pfx, SETTING_STYLE, STYLE_VALUES, "digital")
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

-- Reads a vertical-spacing setting as a clamped percentage, defaulting to
-- ELEM_GAP_DEF when unset or non-numeric.
local function _getGapPct(pfx, key)
    local n = tonumber(SUISettings:readSetting(pfx .. key))
    return n and _clampElemGap(n) or ELEM_GAP_DEF
end

local function getDateGapPct(pfx)
    return _getGapPct(pfx, SETTING_DATE_GAP)
end

local function getBattGapPct(pfx)
    return _getGapPct(pfx, SETTING_BATT_GAP)
end

-- Reads a boolean visibility setting, defaulting to ON (unset means true;
-- only an explicit `false` turns it off).
local function _isVisible(pfx, key)
    return SUISettings:readSetting(pfx .. key) ~= false
end

local function isClockEnabled(pfx)
    return _isVisible(pfx, SETTING_ON)
end

local function isDateEnabled(pfx)
    return _isVisible(pfx, SETTING_DATE)
end

local function isBattEnabled(pfx)
    return _isVisible(pfx, SETTING_BATTERY)
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
--
-- The tens-units separator in compound minute strings ("Twenty-One") is
-- itself a translatable string ("WORD_CLOCK_TENS_SEP") — "-" in English,
-- " e " in Portuguese ("Vinte e Um") — so no code changes are needed per
-- language.
-- ---------------------------------------------------------------------------

-- Translated word tables are built lazily on first use, not at module load,
-- so that _() resolves against the user's locale rather than whatever
-- locale is active before KOReader finishes initializing.
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
    -- Fallback depends on the script family: CJK and Cyrillic languages
    -- write tens+units directly with no separator ("二十一", "двадцатьодин");
    -- English needs an explicit "-" (kept here so untranslated English
    -- locales still read "Twenty-One"); languages that already provide a
    -- translation (bg " и", pt " e ", cs " ", etc.) override this default.
    local sep = _("WORD_CLOCK_TENS_SEP")
    if sep == "WORD_CLOCK_TENS_SEP" then
        -- KOReader stores "English" as locale "C" (the POSIX default — see
        -- frontend/ui/language.lua's getLangMenuTable); ICU-style codes
        -- like "en_GB" / "en_US" share the "en" prefix. Treat both as
        -- English so all three read "Twenty-One" by default.
        local lang   = G_reader_settings and G_reader_settings:readSetting("language") or ""
        local prefix = lang:match("^([a-zA-Z]+)") or ""
        sep = (prefix == "en" or lang == "C") and "-" or ""
    end
    _wc_sep_cache = sep
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

local function _buildWordClockWidget(text, face, inner_w, align)
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
-- Analogue clock face
-- ---------------------------------------------------------------------------
-- Drawn directly with the coverage-based anti-aliasing primitives in
-- infra/sui_aa_paint.lua (see that module's header for how the technique
-- works) instead of relying on any native rounded-shape drawing.
--
-- No rim: bare ticks + hands read cleanly on their own, and a ring is one
-- more shape whose stroke width would need to stay in proportion at every
-- face size for no real benefit. No centre hub — hands run a little past
-- the centre point instead. No second hand: the module only repaints on the
-- minute boundary (see M.scheduleRefresh below), so a second hand would
-- never actually move.
--
-- Always reads the time as a 12-hour face, independent of the "24-hour
-- clock" device setting the digital style honours — an analogue dial has no
-- 24-hour convention to switch to.
--
-- Composited over the target with UI.paintWithAlphaMask so it sits
-- transparently over a wallpaper, the same way UI.makeColoredText composites
-- coloured text — this drawing routine just fills the role that
-- TextWidget:paintTo plays there.

-- Draws the face into `bb` (assumed already white-filled, size diameter ×
-- diameter), in BLACK ink — UI.paintWithAlphaMask inverts and recolours it
-- afterwards.
local function _drawAnalogueFace(bb, diameter, hour, min)
    local cx, cy = diameter / 2, diameter / 2
    local r      = diameter / 2
    local x0, y0, x1, y1 = 0, 0, diameter - 1, diameter - 1

    -- Ticks: 12 marks inset from the edge, one every 30°, 0 = 12 o'clock,
    -- clockwise. The four quarter marks (12/3/6/9, i.e. i % 3 == 0) are
    -- longer and thicker.
    local tick_gap = diameter * 0.05
    for i = 0, 11 do
        local is_major = (i % 3 == 0)
        local tick_len = is_major and diameter * 0.09  or diameter * 0.045
        local tick_w   = is_major and diameter * 0.022 or diameter * 0.012
        local angle    = i * (math.pi / 6)
        local sn, co   = math.sin(angle), math.cos(angle)
        local outer    = r - tick_gap
        local inner    = outer - tick_len
        AAPaint.paintCapsule(bb, cx + inner * sn, cy - inner * co,
                                 cx + outer * sn, cy - outer * co,
                                 tick_w, x0, y0, x1, y1)
    end

    -- Hands: no centre hub, so each hand's stroke starts a little past the
    -- centre on the opposite side (tail) and runs out to its length.
    local tail = math.max(diameter * 0.04, 2)
    local function drawHand(angle, length, width)
        local sn, co = math.sin(angle), math.cos(angle)
        AAPaint.paintCapsule(bb, cx - tail * sn, cy + tail * co,
                                 cx + length * sn, cy - length * co,
                                 width, x0, y0, x1, y1)
    end
    local minute_angle = (min / 60) * (2 * math.pi)
    local hour_angle    = ((hour % 12) + min / 60) / 12 * (2 * math.pi)
    drawHand(hour_angle,   diameter * 0.28, diameter * 0.03)
    drawHand(minute_angle, diameter * 0.40, diameter * 0.022)
end

-- Builds a transparent-background widget of size diameter × diameter showing
-- the current time as an analogue face in `fg_color`. Mirrors the structure
-- of UI.makeColoredText (offscreen 8-bit buffer, painted in BLACK, composited
-- via UI.paintWithAlphaMask) — the only difference is the paint routine
-- draws clock-face primitives instead of rendering a TextWidget.
local function _buildAnalogueClockWidget(diameter, fg_color)
    if diameter < 2 then return nil end
    local t   = os.date("*t", os.time())
    local hour, min = t.hour, t.min

    local widget = WidgetContainer:new{}
    widget.dimen = Geom:new{ w = diameter, h = diameter }

    function widget:getSize()
        return self.dimen
    end

    function widget:paintTo(bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        local d = self.dimen.w
        if d <= 0 then return end

        if not self._tmp_bb or self._tmp_bb:getWidth() ~= d or self._tmp_bb:getHeight() ~= d then
            if self._tmp_bb then self._tmp_bb:free() end
            self._tmp_bb = Blitbuffer.new(d, d, Blitbuffer.TYPE_BB8)
        end

        local custom_paint_fn = function(_widget, tmp_bb)
            _drawAnalogueFace(tmp_bb, d, hour, min)
        end

        UI.paintWithAlphaMask(widget, bb, x, y, d, d, fg_color, custom_paint_fn, self._tmp_bb)
    end

    function widget:onCloseWidget() self:free() end

    function widget:free()
        if self._tmp_bb then
            self._tmp_bb:free()
            self._tmp_bb = nil
        end
    end

    return widget
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

-- landscape_factor (optional): scale multiplier; defaults to 1.
local function build(w, pfx, vspan_pool, landscape_factor)
    local lf    = landscape_factor or 1
    local scale = Config.getModuleScale("clock", pfx) * lf

    local inner_w = w - PAD * 2

    -- clock_w/clock_fs/word_fs are a percentage of inner_w (see
    -- _CLOCK_*_PCT above), using the RAW module scale (no `lf`): inner_w is
    -- already narrowed for landscape upstream (w = col_w in spread mode —
    -- see sui_screen_engine.lua), so applying `lf` again here would narrow
    -- twice — same convention as GridRenderer.build's `cs`. date/batt below
    -- keep the lf-scaled `scale`, since they're fixed-pixel elements from
    -- the shared type scale, not width-derived.
    local raw_scale  = Config.getModuleScaleRaw("clock", pfx)
    local clock_elem = Config.getElemScale("clock", "clock", pfx)
    local date_elem  = Config.getElemScale("clock", "date",  pfx)
    local batt_elem  = Config.getElemScale("clock", "batt",  pfx)

    local clock_w   = math.floor(inner_w * _CLOCK_W_PCT * raw_scale * clock_elem)
    local clock_fs  = math.max(_CLOCK_FS_MIN, math.floor(inner_w * _CLOCK_FS_PCT * raw_scale * clock_elem))
    local word_fs   = math.max(_WORD_FS_MIN,  math.floor(inner_w * _WORD_FS_PCT  * raw_scale * clock_elem))

    -- Scale remaining dimensions from base values (fixed-pixel, lf-scaled),
    -- each further scaled by its own element size on top of the module scale.
    local date_h        = math.max(8,  math.floor(_BASE_DATE_H    * scale * date_elem))
    local date_gap      = math.max(0,  math.floor(_BASE_DATE_GAP  * scale * getDateGapPct(pfx) / 100))
    local batt_gap      = math.max(0,  math.floor(_BASE_BATT_GAP  * scale * getBattGapPct(pfx) / 100))
    local date_fs       = math.max(8,  math.floor(_BASE_DATE_FS   * scale * date_elem))
    local batt_fs       = math.max(7,  math.floor(_BASE_BATT_FS   * scale * batt_elem))
    local batt_h        = math.max(7,  math.floor(_BASE_BATT_H    * scale * batt_elem))

    local bot_pad_extra = math.floor(_BASE_BOT_PAD_EXTRA * scale)

    local show_clock  = isClockEnabled(pfx)
    local show_date   = isDateEnabled(pfx)
    local show_batt   = isBattEnabled(pfx)
    local clock_style = getClockStyle(pfx)

    local sub_fg           = CLR_TEXT_SUB

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
            local wc_widget = _buildWordClockWidget(wc_text, face, inner_w, align)
            vg[#vg+1] = wc_widget
        elseif clock_style == "analogue" then
            -- Analogue face: square, sized to the same clock_w × 2 budget the
            -- word style uses (see getHeight below), capped to inner_w so a
            -- narrow column never clips it.
            local diameter = math.min(clock_w * 2, inner_w)
            local face_widget = _buildAnalogueClockWidget(diameter, SUIStyle.COLOR.text_primary)
            if face_widget then
                vg[#vg+1] = ContainerClass:new{
                    dimen = Geom:new{ w = inner_w, h = diameter },
                    face_widget,
                }
            end
        else
            -- Digital clock (original behaviour).
            vg[#vg+1] = ContainerClass:new{
                dimen = Geom:new{ w = inner_w, h = clock_w },
                wrapText(UI.makeColoredText{
                    text    = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")),
                    face    = Font:getFace(SUIStyle.FACE_REGULAR, clock_fs),
                    bold    = true,
                }),
            }
        end
    end

    if show_date then
        if #vg > 0 then vg[#vg+1] = _vspan(date_gap, vspan_pool) end
        vg[#vg+1] = ContainerClass:new{
            dimen = Geom:new{ w = inner_w, h = date_h },
            wrapText(UI.makeColoredText{
                text    = _localDate(),
                face    = Font:getFace(SUIStyle.FACE_REGULAR, date_fs),
                fgcolor = sub_fg,
            }),
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
        -- The module was removed from the layout: clear all visibility flags
        -- so a future re-add starts with clean defaults.
        SUISettings:saveSetting(pfx .. SETTING_ON,      false)
        SUISettings:saveSetting(pfx .. SETTING_DATE,    false)
        SUISettings:saveSetting(pfx .. SETTING_BATTERY, false)
    else
        -- The module is in the layout: only enable the clock itself.
        -- SETTING_DATE and SETTING_BATTERY are NOT touched — if they already exist,
        -- they respect the user's preference; if they are nil, isBattEnabled /
        -- isDateEnabled use their own defaults (ON for both).
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

local _timer         = nil   -- scheduled function reference (module-level singleton)
local _screen_widget = nil   -- weak reference to the live ScreenWidget (Homescreen or Custom Screen)

local function _tick()
    _timer = nil   -- timer has fired; clear before rescheduling

    -- Abort if the owning screen instance has changed or gone away.
    -- Uses ScreenEngine.getInstance(id), which is id-aware for any screen
    -- (built-in Homescreen or Custom Screen), rather than the legacy flat
    -- ScreenEngine._instance field, which is only ever populated for the
    -- built-in Homescreen (id == "hs") — checking against that field alone
    -- would make this guard always consider a Custom Screen's clock stale,
    -- since ScreenEngine._instance never points at a Custom Screen instance.
    local screen = _screen_widget
    if not screen then return end
    local ScreenEngine = package.loaded["engines/sui_screen_engine"]
    if not ScreenEngine or ScreenEngine.getInstance(screen._id) ~= screen then
        _screen_widget = nil
        return
    end

    -- Do not update while suspended — some platforms fire pending timers
    -- during the suspend transition before the scheduler pauses.
    -- Crucially: do NOT reschedule here. Rescheduling would create a new timer
    -- that onSuspend can no longer cancel (it already ran), causing a 60s loop
    -- that keeps firing throughout the entire suspend period.
    -- ScreenWidget:onResume calls ClockMod.scheduleRefresh() to restart the
    -- chain on wakeup — no action needed here.
    --
    -- Two complementary guards:
    -- • screen._suspended — set by ScreenWidget:onSuspend() when the Suspend
    --   event reaches the widget via broadcastEvent.
    -- • plugin._simpleui_suspended — set by SimpleUIPlugin:onSuspend(), which
    --   runs in the same broadcastEvent pass but may arrive before or after the
    --   widget handler depending on stack order. Checking both closes the race
    --   window where the UIManager has already dequeued this timer for execution
    --   in the current tick before either flag was set.
    local FM = package.loaded["apps/filemanager/filemanager"]
    local plugin = FM and FM.instance and FM.instance._simpleui_plugin
    if screen._suspended or (plugin and plugin._simpleui_suspended) or Device.screen_saver_mode then
        return
    end

    -- Do not update while a book is open — the screen is hidden anyway.
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then
        M.scheduleRefresh(screen)
        return
    end

    -- Fast path: swap only the clock widget in the body VerticalGroup.
    local body       = screen._clock_body_ref
    local idx        = screen._clock_body_idx
    local is_wrapped = screen._clock_is_wrapped
    local swapped    = false

    if body and idx and body[idx] and screen._navbar_container then
        local sw      = Screen:getWidth()
        local SIDE_PAD = require("infra/sui_core").SIDE_M()
        local inner_w  = screen._clock_inner_w or (sw - SIDE_PAD * 2)

        -- Pass the screen's landscape factor through explicitly so the
        -- surgical swap matches the size _updatePage would have built.
        local lf = screen._clock_landscape_factor

        local ok_w, new_widget = pcall(build, inner_w, screen._clock_pfx,
                                        screen._vspan_pool, lf)

        if ok_w and new_widget then
            if is_wrapped then
                -- The clock was wrapped in an InputContainer for hold-to-settings.
                -- Replace the inner slot [1] to keep the gesture handler alive.
                body[idx][1] = new_widget
            else
                body[idx] = new_widget
            end
            UIManager:setDirty(screen, "ui")
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
        if idx ~= nil and screen._navbar_container then
            local ok = pcall(function()
                screen:_updatePage(true)
                UIManager:setDirty(screen, "ui")
            end)
            if not ok then _screen_widget = nil; return end
        end
    end

    -- ---------------------------------------------------------------------------
    -- Topbar clock synchronisation.
    -- Both clocks schedule their next tick with 60-(os.time()%60)+1. Driving
    -- the topbar refresh from this same callback makes both chains read
    -- os.time() at the same moment, so they reschedule to the identical next
    -- minute boundary instead of drifting apart and showing different minutes.
    --
    -- `plugin` was resolved above for the suspend guard — reuse it here.
    -- ---------------------------------------------------------------------------
    if plugin and not plugin._simpleui_suspended then
        local Topbar = package.loaded["screens/sui_topbar"]
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

    M.scheduleRefresh(screen)
end

-- Schedule the next tick, aligned to the next minute boundary.
-- Safe to call repeatedly — cancels any pending timer first.
function M.scheduleRefresh(screen)
    if _timer then
        UIManager:unschedule(_timer)
        _timer = nil
    end
    _screen_widget = screen
    local secs = 60 - (os.time() % 60) + 1
    _timer = _tick
    UIManager:scheduleIn(secs, _timer)
end

-- Cancel any pending timer and release the screen reference.
-- Called from onSuspend and onCloseWidget.
function M.cancelRefresh()
    if _timer then
        UIManager:unschedule(_timer)
        _timer = nil
    end
    _screen_widget = nil
end

function M.build(w, ctx)
    -- Record swap coordinates on the owning screen widget so the tick can do
    -- a surgical replacement without rebuilding the entire page.  These fields
    -- are written here (inside build) because build() is called from within
    -- the module loop in _buildContent(), at which point the body index is
    -- not yet known to the screen. The screen sets _clock_body_idx
    -- immediately after build() returns (see sui_homescreen.lua).
    if ctx._screen_widget then
        ctx._screen_widget._clock_pfx      = ctx.pfx
        ctx._screen_widget._clock_inner_w  = w
    end
    return build(w, ctx.pfx, ctx.vspan_pool, ctx.landscape_factor)
end

function M.getHeight(ctx)
    local scale     = Config.getModuleScale("clock", ctx.pfx) * (ctx.landscape_factor or 1)

    -- clock_w mirrors build(): a percentage of inner_w, using the RAW
    -- module scale (no landscape_factor) since ctx.col_w is already
    -- narrowed for landscape — see the note in build(). getHeight has no
    -- real widget width to work with, so estimate one the same way
    -- module_quick_actions.lua does.
    -- Fallback here mirrors GridRenderer.getHeight's own fallback (a raw
    -- column-width estimate, not _REF_INNER_W above — that constant already
    -- has PAD*2 subtracted out, for calibrating the _*_PCT constants).
    local raw_scale        = Config.getModuleScaleRaw("clock", ctx.pfx)
    local clock_elem        = Config.getElemScale("clock", "clock", ctx.pfx)
    local date_elem         = Config.getElemScale("clock", "date",  ctx.pfx)
    local batt_elem         = Config.getElemScale("clock", "batt",  ctx.pfx)
    local w_estimate        = ctx.col_w or ctx.inner_w or (Screen:getWidth() - UI.SIDE_PAD * 2)
    local inner_w_estimate  = w_estimate - PAD * 2
    local clock_w   = math.floor(inner_w_estimate * _CLOCK_W_PCT * raw_scale * clock_elem)
    local date_h    = math.max(8, math.floor(_BASE_DATE_H   * scale * date_elem))
    local date_gap  = math.max(0, math.floor(_BASE_DATE_GAP * scale * getDateGapPct(ctx.pfx) / 100))
    local batt_gap  = math.max(0, math.floor(_BASE_BATT_GAP * scale * getBattGapPct(ctx.pfx) / 100))
    local batt_h    = math.max(7, math.floor(_BASE_BATT_H   * scale * batt_elem))

    local h_base      = PAD * 2 + PAD2
    local show_clock  = isClockEnabled(ctx.pfx)
    local show_date   = isDateEnabled(ctx.pfx)
    local show_batt   = isBattEnabled(ctx.pfx)

    -- Word and analogue styles both occupy approximately two digital-clock
    -- lines of height (word: two stacked text lines; analogue: a square
    -- face). Use 2 × clock_w as the budget so getHeight() stays stable
    -- regardless of whether font metrics are available at estimation time.
    local clock_h
    if show_clock and (getClockStyle(ctx.pfx) == "word" or getClockStyle(ctx.pfx) == "analogue") then
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


function M.getMenuItems(ctx_menu)
    local pfx     = ctx_menu.pfx
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._

    local function toggle(key, current)
        SUISettings:saveSetting(pfx .. key, not current)
        refresh()
    end

    -- Scale + per-element Size are grouped into a single "Size" submenu,
    -- mirroring sui_book_grid.lua's size_group pattern.
    local size_group = {}

    size_group[#size_group + 1] = Config.makeScaleItem{
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct("clock", pfx) end,
        set          = function(v) Config.setModuleScale(v, "clock", pfx) end,
        refresh      = refresh,
    }
    size_group[#size_group + 1] = Config.makeScaleItem{
        text_func    = function() return _lc("Clock Size") end,
        enabled_func = function() return isClockEnabled(pfx) end,
        title        = _lc("Clock Size"),
        info         = _lc("Scale for the clock face only.\n100% is the default size."),
        get          = function() return Config.getElemScalePct("clock", "clock", pfx) end,
        set          = function(v) Config.setElemScale(v, "clock", "clock", pfx) end,
        refresh      = refresh,
    }
    size_group[#size_group + 1] = Config.makeScaleItem{
        text_func    = function() return _lc("Date Size") end,
        enabled_func = function() return isDateEnabled(pfx) end,
        title        = _lc("Date Size"),
        info         = _lc("Scale for the date text only.\n100% is the default size."),
        get          = function() return Config.getElemScalePct("clock", "date", pfx) end,
        set          = function(v) Config.setElemScale(v, "clock", "date", pfx) end,
        refresh      = refresh,
    }
    size_group[#size_group + 1] = Config.makeScaleItem{
        text_func    = function() return _lc("Battery Size") end,
        enabled_func = function() return isBattEnabled(pfx) end,
        title        = _lc("Battery Size"),
        info         = _lc("Scale for the battery text only.\n100% is the default size."),
        get          = function() return Config.getElemScalePct("clock", "batt", pfx) end,
        set          = function(v) Config.setElemScale(v, "clock", "batt", pfx) end,
        refresh      = refresh,
    }

    return {
        {
            text_func      = function() return _lc("Visibility") end,
            sub_item_table = {
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
            },
        },
        {
            text_func      = function() return _lc("Size") end,
            sub_item_table = size_group,
        },
        {
            -- Clock Style submenu: Digital / Word / Analogue
            text_func  = function() return _lc("Clock Style") end,
            value_func = function()
                local style = getClockStyle(pfx)
                if style == "word" then return _lc("Word") end
                if style == "analogue" then return _lc("Analogue") end
                return _lc("Digital")
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
                {
                    text         = _lc("Analogue"),
                    radio        = true,
                    checked_func = function() return getClockStyle(pfx) == "analogue" end,
                    keep_menu_open = true,
                    callback     = function() setClockStyle(pfx, "analogue"); refresh() end,
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
            text_func      = function() return _lc("Spacing") end,
            sub_item_table = {
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
            },
        },
    }
end

return M
