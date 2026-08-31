local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")

local Screen = Device.screen
local candidate_face = Font:getFace("cfont", 22)
local candidate_slot_face = Font:getFace("cfont", 15)
local text_width_cache = {}
local text_width_cache_order = {}
local MAX_TEXT_WIDTH_CACHE = 256

local function measureText(text, face, bold)
    local face_key = face == candidate_face and "candidate"
        or face == candidate_slot_face and "slot" or tostring(face)
    local key = face_key .. "\0" .. (bold and "1" or "0") .. "\0" .. text
    local cached = text_width_cache[key]
    if cached then
        return cached
    end
    local widget = TextWidget:new{
        text = text,
        face = face,
        bold = bold == true,
    }
    local width = widget:getSize().w
    widget:free()
    text_width_cache[key] = width
    text_width_cache_order[#text_width_cache_order + 1] = key
    if #text_width_cache_order > MAX_TEXT_WIDTH_CACHE then
        local evicted = table.remove(text_width_cache_order, 1)
        text_width_cache[evicted] = nil
    end
    return width
end

local CandidateCell = InputContainer:extend{
    width = nil,
    height = nil,
    slot = nil,
    callback = nil,
}

function CandidateCell:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.slot_widget = TextWidget:new{
        text = tostring(self.slot),
        face = candidate_slot_face,
        bold = false,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        padding = 0,
    }
    local slot_width = self.slot_widget:getSize().w
    self.slot_gap = Size.span.horizontal_small
    self.text_widget = TextWidget:new{
        text = self.text,
        face = candidate_face,
        bold = self.selected == true,
        max_width = math.max(1,
            self.width - 2 * Size.padding.small - slot_width - self.slot_gap),
        truncate_with_ellipsis = true,
    }
    self.content_group = HorizontalGroup:new{
        allow_mirroring = false,
        self.slot_widget,
        HorizontalSpan:new{ width = self.slot_gap },
        self.text_widget,
    }
    self.frame = FrameContainer:new{
        width = self.width,
        height = self.height,
        margin = 0,
        bordersize = 0,
        inner_bordersize = self.selected and Size.line.thick or 0,
        padding = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            self.content_group,
        },
    }
    self[1] = self.frame
    self.help_text = self.accessibility_label
    self.ges_events = {
        TapCandidate = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            },
        },
    }
end

function CandidateCell:onTapCandidate()
    if not self.text or not self.callback then
        return false
    end
    self.callback(self.slot)
    return true
end

function CandidateCell:isTruncated()
    return self.text_widget:isTruncated()
end

local ActionCell = InputContainer:extend{
    width = nil,
    height = nil,
    callback = nil,
}

function ActionCell:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local content
    if self.icon then
        self.icon_widget = IconWidget:new{
            icon = self.icon,
            rotation_angle = self.icon_rotation_angle or 0,
            width = self.icon_size,
            height = self.icon_size,
        }
        content = self.icon_widget
    else
        self.text_widget = TextWidget:new{
            text = self.text,
            face = candidate_face,
            bold = true,
            max_width = math.max(1, self.width - 2 * Size.padding.small),
            truncate_with_ellipsis = true,
        }
        content = self.text_widget
    end
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        content,
    }
    self.help_text = self.accessibility_label
    self.ges_events = {
        TapAction = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            },
        },
    }
end

function ActionCell:onTapAction()
    if not self.callback then
        return false
    end
    self.callback()
    return true
end

-- Kept as a narrow API compatibility alias for callers that used the old icon
-- button.
function ActionCell:onTapNavigation()
    return self:onTapAction()
end

local InputMethodCandidateBar = InputContainer:extend{
    width = nil,
    height = nil,
    page_size = 5,
    on_candidate = nil,
    on_toggle_expanded = nil,
}

function InputMethodCandidateBar:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.candidate_gap = Size.span.horizontal_small
    self.minimum_target_width = math.max(self.height, Screen:scaleBySize(48))
    self.action_width = self.minimum_target_width
    self.more_icon_size = Screen:scaleBySize(24)
    self.expanded = false
    self.expand_available = false
    self.candidate_cells = {}
    self.visible_candidate_slots = {}
    self.timing_stats = {}
    self.idle_view = HorizontalSpan:new{ width = self.width }
    self[1] = self.idle_view
    self:update{}
end

function InputMethodCandidateBar:_recordTiming(name, started)
    if not started then
        return
    end
    local elapsed = (self.timing_clock or os.clock)() - started
    local item = self.timing_stats[name]
    if not item then
        item = { count = 0, total = 0, maximum = 0 }
        self.timing_stats[name] = item
    end
    item.count = item.count + 1
    item.total = item.total + elapsed
    item.maximum = math.max(item.maximum, elapsed)
    pcall(self.on_timing, name, elapsed)
end

function InputMethodCandidateBar:getTimingStats(reset)
    local result = {}
    for name, item in pairs(self.timing_stats) do
        result[name] = {
            count = item.count,
            total_ms = item.total * 1000,
            maximum_ms = item.maximum * 1000,
        }
    end
    if reset then
        self.timing_stats = {}
    end
    return result
end

function InputMethodCandidateBar:_replaceActiveView(view)
    if self.active_view and self.active_view ~= view and self.active_view.free then
        self.active_view:free()
    end
    self.active_view = view
    self[1] = view or self.idle_view
end

function InputMethodCandidateBar:_makeAction(text, accessibility_label, callback)
    local width = math.max(
        self.action_width,
        measureText(text, candidate_face, true) + 2 * Size.padding.small
    )
    width = math.min(self.width, width)
    return ActionCell:new{
        width = width,
        height = self.height,
        text = text,
        accessibility_label = accessibility_label,
        callback = callback,
    }
end

function InputMethodCandidateBar:_makeIconAction(icon, rotation, accessibility_label, callback)
    return ActionCell:new{
        width = self.action_width,
        height = self.height,
        icon = icon,
        icon_size = self.more_icon_size,
        icon_rotation_angle = rotation,
        accessibility_label = accessibility_label,
        callback = callback,
    }
end

function InputMethodCandidateBar:_candidateDisplayText(slot, candidate)
    return tostring(slot) .. " " .. candidate
end

function InputMethodCandidateBar:_makeCandidateCell(slot, candidate, kind,
        selected, width, display_text)
    return CandidateCell:new{
        width = width,
        height = self.height,
        slot = slot,
        text = candidate,
        kind = kind,
        display_text = display_text,
        selected = selected,
        accessibility_label = self:_candidateAccessibilityLabel(
            slot, candidate, kind, selected),
        callback = function(candidate_slot)
            if (self.state.candidates or {})[candidate_slot] and self.on_candidate then
                self.on_candidate(candidate_slot)
            end
        end,
    }
end

function InputMethodCandidateBar:_candidateAccessibilityLabel(slot, candidate, kind, selected)
    local type_label = "普通候选"
    if kind == "correction" then
        type_label = "纠错候选"
    elseif kind == "fallback" then
        type_label = "原文候选"
    elseif kind == "prediction" then
        type_label = "联想候选"
    end
    local page = self.state.page or 1
    local absolute_index = (page - 1) * self.page_size + slot
    local total = self.state.candidate_count or #(self.state.candidates or {})
    local selected_label = selected and "，当前选中" or ""
    return "数字 " .. tostring(slot) .. selected_label .. "，" .. type_label .. " "
        .. tostring(absolute_index) .. "，共 " .. tostring(total) .. " 项："
        .. candidate .. "，点击提交"
end

function InputMethodCandidateBar:_naturalCandidateWidths(candidates)
    local widths = {}
    local display_texts = {}
    for slot, candidate in ipairs(candidates) do
        local display_text = self:_candidateDisplayText(slot, candidate)
        display_texts[slot] = display_text
        widths[slot] = math.max(
            self.minimum_target_width,
            measureText(tostring(slot), candidate_slot_face, false)
                + Size.span.horizontal_small
                + measureText(candidate, candidate_face, self.state.selected_slot == slot)
                + 2 * Size.padding.small
        )
    end
    return widths, display_texts
end

-- Return one contiguous, content-sized candidate window containing the current
-- selection. All cells are complete unless the first visible candidate cannot
-- fit the whole available width by itself.
function InputMethodCandidateBar:_fitCandidateSlots(widths, available_width)
    local count = math.min(#widths, self.page_size)
    if count == 0 or available_width <= 0 then
        return {}, {}, false
    end

    local selected_slot = self.state.selected_slot or 0
    if selected_slot < 1 or selected_slot > count then
        selected_slot = 1
    end
    local start_slot = selected_slot
    local used = widths[selected_slot]
    if used <= available_width then
        for slot = selected_slot - 1, 1, -1 do
            local proposed = widths[slot] + self.candidate_gap + used
            if proposed > available_width then
                break
            end
            start_slot = slot
            used = proposed
        end
    end

    local slots = {}
    local cell_widths = {}
    used = 0
    local first_truncated = false
    for slot = start_slot, count do
        local gap = #slots > 0 and self.candidate_gap or 0
        if #slots == 0 then
            local width = math.min(widths[slot], available_width)
            if width <= 0 then
                break
            end
            slots[#slots + 1] = slot
            cell_widths[#cell_widths + 1] = width
            used = width
            first_truncated = widths[slot] > width
        elseif used + gap + widths[slot] <= available_width then
            slots[#slots + 1] = slot
            cell_widths[#cell_widths + 1] = widths[slot]
            used = used + gap + widths[slot]
        else
            break
        end
    end
    return slots, cell_widths, first_truncated
end

function InputMethodCandidateBar:_buildExpandedHeader(total)
    self._compact_layout = nil
    self._candidate_view_positions = nil
    self.status_label = nil
    self.title_text = "全部候选 · " .. tostring(total)
    local collapse_button = self:_makeAction(
        "收起", "收起候选并返回键盘",
        function()
            if self.on_toggle_expanded then
                self.on_toggle_expanded(false)
            end
        end
    )
    local title_width = math.max(1, self.width - collapse_button.width)
    local title_widget = TextWidget:new{
        text = self.title_text,
        face = candidate_face,
        bold = true,
        max_width = math.max(1, title_width - 2 * Size.padding.small),
        truncate_with_ellipsis = true,
    }
    local title = CenterContainer:new{
        dimen = Geom:new{ w = title_width, h = self.height },
        title_widget,
    }
    local view = HorizontalGroup:new{ allow_mirroring = false }
    view[#view + 1] = title
    view[#view + 1] = collapse_button
    self.collapse_button = collapse_button
    self.more_button = collapse_button
    self.expand_button = collapse_button
    self.candidate_cells = {}
    self.visible_candidate_slots = {}
    return view
end

function InputMethodCandidateBar:_buildCompactView(candidates, kinds, fallback_candidate, prediction_mode)
    self.status_label = nil
    self.title_text = nil
    local widths, display_texts = self:_naturalCandidateWidths(candidates)
    local initial_available = self.width
    local initial_slots, _, initially_truncated = self:_fitCandidateSlots(widths, initial_available)
    local total = self.state.candidate_count or #candidates
    local needs_more = self.state.has_previous_page == true
        or self.state.has_next_page == true
        or total > #candidates
        or #initial_slots < #candidates
        or initially_truncated

    local more_button
    local action_gap = 0
    local available_width = initial_available
    if needs_more then
        more_button = self:_makeIconAction(
            "chevron.up", 180, "展开全部候选，共 " .. tostring(total) .. " 项",
            function()
                if self.on_toggle_expanded then
                    self.on_toggle_expanded(true)
                end
            end
        )
        action_gap = self.candidate_gap
        available_width = math.max(1,
            initial_available - more_button.width - action_gap)
    end

    local slots, cell_widths, truncated = self:_fitCandidateSlots(widths, available_width)
    if #slots < #candidates or truncated then
        needs_more = true
    end
    -- Reserving the action can itself hide a candidate. This branch handles
    -- the rare exact-fit case that did not require the action initially.
    if needs_more and not more_button then
        more_button = self:_makeIconAction(
            "chevron.up", 180, "展开全部候选，共 " .. tostring(total) .. " 项",
            function()
                if self.on_toggle_expanded then
                    self.on_toggle_expanded(true)
                end
            end
        )
        action_gap = self.candidate_gap
        available_width = math.max(1,
            initial_available - more_button.width - action_gap)
        slots, cell_widths = self:_fitCandidateSlots(widths, available_width)
    end

    local view = HorizontalGroup:new{ allow_mirroring = false }
    local candidate_cells = {}
    local visible_slots = {}
    local candidate_view_positions = {}
    local occupied = 0
    for index, slot in ipairs(slots) do
        if index > 1 then
            view[#view + 1] = HorizontalSpan:new{ width = self.candidate_gap }
            occupied = occupied + self.candidate_gap
        end
        local candidate = candidates[slot]
        local kind = kinds[slot] or (fallback_candidate and slot == 1 and "fallback")
            or (prediction_mode and "prediction") or "normal"
        local selected = self.state.selected_slot == slot
        local cell = self:_makeCandidateCell(slot, candidate, kind, selected,
            cell_widths[index], display_texts[slot])
        candidate_cells[#candidate_cells + 1] = cell
        visible_slots[#visible_slots + 1] = slot
        view[#view + 1] = cell
        candidate_view_positions[#candidate_view_positions + 1] = #view
        occupied = occupied + cell_widths[index]
    end
    if more_button then
        local filler_width = self.width - occupied - action_gap - more_button.width
        if filler_width > 0 then
            view[#view + 1] = HorizontalSpan:new{ width = filler_width }
        end
        if action_gap > 0 then
            view[#view + 1] = HorizontalSpan:new{ width = action_gap }
        end
        view[#view + 1] = more_button
    elseif occupied < self.width then
        view[#view + 1] = HorizontalSpan:new{ width = self.width - occupied }
    end

    self.candidate_cells = candidate_cells
    self.visible_candidate_slots = visible_slots
    self._candidate_view_positions = candidate_view_positions
    self._compact_layout = {
        slots = slots,
        cell_widths = cell_widths,
        has_more = more_button ~= nil,
    }
    self.more_button = more_button
    self.expand_button = more_button
    self.collapse_button = nil
    self.expand_available = more_button ~= nil
    return view
end

local function sameCompactLayout(previous, slots, widths, has_more)
    if not previous or previous.has_more ~= has_more
            or #previous.slots ~= #slots or #previous.cell_widths ~= #widths then
        return false
    end
    for index = 1, #slots do
        if previous.slots[index] ~= slots[index]
                or previous.cell_widths[index] ~= widths[index] then
            return false
        end
    end
    return true
end

-- Reuse the compact HorizontalGroup and every unchanged candidate cell when
-- adaptive layout produces the same slots and widths. Chinese candidates of
-- equal character length commonly share widths, so this avoids rebuilding the
-- whole bar on the majority of composition updates while preserving the
-- existing adaptive layout and selected-bold rendering.
function InputMethodCandidateBar:_updateCompactViewInPlace(candidates, kinds,
        fallback_candidate, prediction_mode)
    if not self.active_view or not self._compact_layout then
        return false
    end
    local widths, display_texts = self:_naturalCandidateWidths(candidates)
    local initial_slots, _, initially_truncated = self:_fitCandidateSlots(
        widths, self.width)
    local total = self.state.candidate_count or #candidates
    local needs_more = self.state.has_previous_page == true
        or self.state.has_next_page == true
        or total > #candidates
        or #initial_slots < #candidates
        or initially_truncated
    local available_width = self.width
    if needs_more then
        available_width = math.max(1,
            available_width - self.action_width - self.candidate_gap)
    end
    local slots, cell_widths, truncated = self:_fitCandidateSlots(
        widths, available_width)
    if (#slots < #candidates or truncated) and not needs_more then
        needs_more = true
        available_width = math.max(1,
            self.width - self.action_width - self.candidate_gap)
        slots, cell_widths = self:_fitCandidateSlots(widths, available_width)
    end
    if not sameCompactLayout(self._compact_layout, slots, cell_widths, needs_more) then
        return false
    end

    for index, slot in ipairs(slots) do
        local candidate = candidates[slot]
        local kind = kinds[slot] or (fallback_candidate and slot == 1 and "fallback")
            or (prediction_mode and "prediction") or "normal"
        local selected = self.state.selected_slot == slot
        local cell = self.candidate_cells[index]
        local accessibility_label = self:_candidateAccessibilityLabel(
            slot, candidate, kind, selected)
        if not cell or cell.text ~= candidate or cell.kind ~= kind
                or cell.selected ~= selected then
            local replacement = self:_makeCandidateCell(slot, candidate, kind,
                selected, cell_widths[index], display_texts[slot])
            local position = self._candidate_view_positions[index]
            self.active_view[position] = replacement
            self.candidate_cells[index] = replacement
            if cell and cell.free then
                cell:free()
            end
        else
            cell.accessibility_label = accessibility_label
            cell.help_text = accessibility_label
        end
    end
    if self.more_button then
        local label = "展开全部候选，共 " .. tostring(total) .. " 项"
        self.more_button.accessibility_label = label
        self.more_button.help_text = label
    end
    return true
end

function InputMethodCandidateBar:setExpanded(expanded)
    expanded = expanded == true
    if self.expanded == expanded then
        return false
    end
    self.expanded = expanded
    self:update(self.state)
    return true
end

function InputMethodCandidateBar:getVisibleCandidateSlots()
    local slots = {}
    for index, slot in ipairs(self.visible_candidate_slots or {}) do
        slots[index] = slot
    end
    return slots
end

function InputMethodCandidateBar:discardBackground()
    if self._background_bb then
        self._background_bb:free()
    end
    self._background_bb = nil
    self._background_meta = nil
end

function InputMethodCandidateBar:disablePendingBackgroundCapture()
    self._capture_background_on_next_paint = nil
    self:discardBackground()
end

function InputMethodCandidateBar:requestBackgroundCapture()
    self:discardBackground()
    self._capture_background_on_next_paint = self:isActive() and true or nil
end

function InputMethodCandidateBar:_captureBackground(bb, x, y)
    -- A transparent idle widget cannot erase pixels already written to the
    -- framebuffer. Preserve the exact underlay before drawing the active bar.
    self:discardBackground()
    local captured
    local ok = pcall(function()
        local background = Blitbuffer.new(self.width, self.height, bb:getType())
        self._background_bb = background
        background:blitFrom(bb, 0, 0, x, y, self.width, self.height)
        self._background_meta = {
            target = bb,
            x = x,
            y = y,
            w = self.width,
            h = self.height,
            buffer_type = bb:getType(),
            rotation = bb:getRotation(),
            inverse = bb:getInverse(),
        }
        captured = true
    end)
    if not ok then
        self:discardBackground()
    end
    self._capture_background_on_next_paint = nil
    return captured == true
end

function InputMethodCandidateBar:restoreBackground(bb)
    local background = self._background_bb
    local meta = self._background_meta
    local restored
    if background and meta then
        local ok = pcall(function()
            if meta.target ~= bb
                    or meta.x ~= self.dimen.x or meta.y ~= self.dimen.y
                    or meta.w ~= self.width or meta.h ~= self.height
                    or meta.buffer_type ~= bb:getType()
                    or meta.rotation ~= bb:getRotation()
                    or meta.inverse ~= bb:getInverse() then
                return
            end
            bb:blitFrom(background, meta.x, meta.y, 0, 0, meta.w, meta.h)
            restored = true
        end)
        if not ok then
            restored = nil
        end
    end
    self:discardBackground()
    self._active_surface_painted = nil
    return restored == true
end

function InputMethodCandidateBar:update(state)
    local timing_started = self.on_timing and (self.timing_clock or os.clock)() or nil
    local was_active = self:isActive()
    local active_surface_painted = self._active_surface_painted == true
    self.state = state or {}
    local code = self.state.code or ""
    local candidates = self.state.candidates or {}
    local kinds = self.state.candidate_kinds or {}
    local prediction_mode = self.state.candidate_mode == "prediction"

    if (code == "" and not prediction_mode) or #candidates == 0 then
        self.view_mode = "idle"
        self.expand_available = false
        self.expanded = false
        self._active = false
        self.candidate_cells = {}
        self.visible_candidate_slots = {}
        self.more_button = nil
        self.expand_button = nil
        self.collapse_button = nil
        self.status_label = nil
        self.title_text = nil
        self:_replaceActiveView(nil)
        self._compact_layout = nil
        self._candidate_view_positions = nil
        self:_recordTiming("candidate_bar_update", timing_started)
        return was_active and active_surface_painted
    end

    local fallback_candidate = self.state.fallback_candidate == true
    self.view_mode = self.expanded and "expanded"
        or prediction_mode and "prediction"
        or fallback_candidate and "composing_fallback"
        or (self.state.correction_candidate and "composing_correction")
        or "composing_candidates"
    if not was_active then
        self:discardBackground()
        self._capture_background_on_next_paint = true
        self._active_surface_painted = nil
    end
    self._active = true
    local view
    if self.expanded then
        self.expand_available = true
        view = self:_buildExpandedHeader(self.state.candidate_count or #candidates)
    elseif self:_updateCompactViewInPlace(
            candidates, kinds, fallback_candidate, prediction_mode) then
        self:_recordTiming("candidate_bar_update", timing_started)
        return false
    else
        view = self:_buildCompactView(candidates, kinds, fallback_candidate, prediction_mode)
    end
    self:_replaceActiveView(view)
    self:_recordTiming("candidate_bar_update", timing_started)
    return false
end

function InputMethodCandidateBar:isActive()
    return self._active == true
end

function InputMethodCandidateBar:paintTo(bb, x, y)
    self._painted = true
    self.dimen.x = x
    self.dimen.y = y
    if self:isActive() then
        if self._capture_background_on_next_paint then
            self:_captureBackground(bb, x, y)
        end
        bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
        InputContainer.paintTo(self, bb, x, y)
        -- Keep the separator continuous even when the selected cell's inner
        -- outline begins at the left edge of the bar.
        bb:paintRect(x, y, self.width, Size.line.thin, Blitbuffer.COLOR_DARK_GRAY)
        self._active_surface_painted = true
    end
    -- Idle deliberately paints nothing: the fixed height is layout-only.
end

function InputMethodCandidateBar:getRefreshRegion()
    if not self._painted then
        return nil
    end
    return Geom:new{
        x = self.dimen.x,
        y = self.dimen.y,
        w = self.dimen.w,
        h = self.dimen.h,
    }
end

function InputMethodCandidateBar:free(full)
    self:discardBackground()
    if self.active_view and self.active_view.free then
        self.active_view:free(full)
    end
    if self.idle_view and self.idle_view.free then
        self.idle_view:free(full)
    end
end

return InputMethodCandidateBar
