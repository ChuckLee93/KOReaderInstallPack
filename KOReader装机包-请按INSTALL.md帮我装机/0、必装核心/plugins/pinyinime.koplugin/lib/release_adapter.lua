local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local util = require("util")

local Screen = Device.screen
local ReleaseAdapter = {}
local SCHEME_LABEL_SCALE = 0.7
local MIN_SCHEME_LABEL_SIZE = 8

local ProtectedKeyboardSurface = FrameContainer:extend{
    on_paint_error = nil,
}

function ProtectedKeyboardSurface:paintTo(bb, x, y)
    local ok, err = xpcall(function()
        FrameContainer.paintTo(self, bb, x, y)
    end, debug.traceback)
    if not ok and self.on_paint_error then
        pcall(self.on_paint_error, err)
    end
end

local function missingCapability(name)
    return false, "capability_missing: " .. name
end

function ReleaseAdapter.probe(runtime)
    local InputText = require("ui/widget/inputtext")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local VirtualKeyboard = require("ui/widget/virtualkeyboard")
    local layout = require("ui/data/keyboardlayouts/zh_CN_keyboard")
    local space_descriptor = layout.keys and layout.keys[5] and layout.keys[5][4]
    local punctuation_descriptor = layout.keys and layout.keys[3]
        and layout.keys[3][10] and layout.keys[3][10][2]

    local required_functions = {
        { "InputText.initTextBox", InputText.initTextBox },
        { "InputText.setText", InputText.setText },
        { "InputText.delAll", InputText.delAll },
        { "InputText.onCloseWidget", InputText.onCloseWidget },
        { "TextBoxWidget.init", TextBoxWidget.init },
        { "TextBoxWidget._renderText", TextBoxWidget._renderText },
        { "TextBoxWidget.getXtextHighlightRects", TextBoxWidget.getXtextHighlightRects },
        { "TextBoxWidget.getNonXtextHighlightRects", TextBoxWidget.getNonXtextHighlightRects },
        { "TextBoxWidget._updateLayout", TextBoxWidget._updateLayout },
        { "TextBoxWidget._getXYForCharPos", TextBoxWidget._getXYForCharPos },
        { "TextBoxWidget.free", TextBoxWidget.free },
        { "TextBoxWidget.moveCursorToCharPos", TextBoxWidget.moveCursorToCharPos },
        { "VirtualKeyboard.init", VirtualKeyboard.init },
        { "VirtualKeyboard.addKeys", VirtualKeyboard.addKeys },
        { "VirtualKeyboard._refresh", VirtualKeyboard._refresh },
        { "VirtualKeyboard.getKeyboardLayout", VirtualKeyboard.getKeyboardLayout },
        { "VirtualKeyboard.onCloseWidget", VirtualKeyboard.onCloseWidget },
        { "zh_CN_keyboard.wrapInputBox", layout.wrapInputBox },
        { "zh_CN_keyboard.genMenuItems", layout.genMenuItems },
        { "Device.screen.scaleBySize", Screen and Screen.scaleBySize },
        { "UIManager.setDirty", UIManager.setDirty },
        { "UIManager.widgetRepaint", UIManager.widgetRepaint },
        { "UIManager.scheduleIn", UIManager.scheduleIn },
        { "UIManager.unschedule", UIManager.unschedule },
        { "UIManager.nextTick", UIManager.nextTick },
        { "UIManager.forceRePaint", UIManager.forceRePaint },
        { "Geom.new", Geom.new },
        { "Font.getFace", Font.getFace },
        { "TextWidget.new", TextWidget.new },
        { "VerticalGroup.new", VerticalGroup.new },
    }
    for _, required in ipairs(required_functions) do
        if type(required[2]) ~= "function" then
            return missingCapability(required[1])
        end
    end
    if type(space_descriptor) ~= "table" then
        return missingCapability("zh_CN_keyboard.keys[5][4]")
    end
    if type(punctuation_descriptor) ~= "table" then
        return missingCapability("zh_CN_keyboard.keys[3][10][2]")
    end

    local hook_conflicts = {
        { "InputText.getPreeditText", InputText.getPreeditText },
        { "InputText.setPreeditText", InputText.setPreeditText },
        { "VirtualKeyboard._updateInputMethodCandidateBar",
            VirtualKeyboard._updateInputMethodCandidateBar },
        { "VirtualKeyboard._updateInputMethodSchemeKey",
            VirtualKeyboard._updateInputMethodSchemeKey },
        { "VirtualKeyboard._setInputMethodCandidatesExpanded",
            VirtualKeyboard._setInputMethodCandidatesExpanded },
    }
    for _, hook in ipairs(hook_conflicts) do
        if hook[2] ~= nil then
            return false, "hook_conflict: " .. hook[1]
        end
    end
    return true
end

local function installPreedit(runtime)
    local InputText = require("ui/widget/inputtext")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local pending_preedit

    runtime.legacy_inputtext = InputText
    runtime.legacy_textboxwidget = TextBoxWidget
    runtime.original_inputtext_init_textbox = InputText.initTextBox
    runtime.original_inputtext_set_text = InputText.setText
    runtime.original_textbox_init = TextBoxWidget.init
    runtime.original_textbox_render = TextBoxWidget._renderText

    runtime.wrapped_textbox_init = function(self)
        if pending_preedit then
            self.preedit_start_idx = pending_preedit.start_idx
            self.preedit_end_idx = pending_preedit.end_idx
            self.preedit_cursor_idx = pending_preedit.cursor_idx
        end
        return runtime.original_textbox_init(self)
    end
    TextBoxWidget.init = runtime.wrapped_textbox_init

    local function paintUnderline(self, start_row_idx, end_row_idx)
        if not self.preedit_start_idx or not self.preedit_end_idx then
            return
        end
        local lines = self.vertical_string_list
        if type(lines) ~= "table" or #lines == 0 or not self._bb then
            runtime:disableForSession("preedit underline surface is unavailable")
            return
        end
        start_row_idx = math.max(1, tonumber(start_row_idx) or 1)
        end_row_idx = math.min(#lines, tonumber(end_row_idx) or #lines)
        if start_row_idx > end_row_idx then
            runtime:disableForSession("preedit underline row range is invalid")
            return
        end
        local ok, err = xpcall(function()
            local rects
            if self.use_xtext then
                rects = self:getXtextHighlightRects(self.preedit_start_idx,
                    self.preedit_end_idx, start_row_idx, end_row_idx)
            else
                rects = self:getNonXtextHighlightRects(self.preedit_start_idx,
                    self.preedit_end_idx, start_row_idx, end_row_idx)
            end
            if type(rects) ~= "table" then
                error("highlight rectangle list is unavailable")
            end
            local linesize = Size.line.thick
            local baseline_offset = math.min(
                assert(self.line_height_px, "line height is unavailable") - linesize,
                assert(self.line_glyph_baseline, "line baseline is unavailable")
                    + Size.padding.tiny
            )
            for _, rect in ipairs(rects) do
                if type(rect) ~= "table" or type(rect.x) ~= "number"
                        or type(rect.y) ~= "number" or type(rect.w) ~= "number" then
                    error("invalid highlight rectangle")
                end
                self._bb:paintRect(rect.x, rect.y + baseline_offset,
                    rect.w, linesize, Blitbuffer.COLOR_BLACK)
            end
        end, debug.traceback)
        if not ok then
            runtime:disableForSession("preedit underline rendering failed: " .. tostring(err))
        end
    end

    runtime.wrapped_textbox_render = function(self, start_row_idx, end_row_idx)
        runtime.original_textbox_render(self, start_row_idx, end_row_idx)
        paintUnderline(self, start_row_idx, end_row_idx)
    end
    TextBoxWidget._renderText = runtime.wrapped_textbox_render

    local function innerTextWidget(inputtext)
        local widget = inputtext.text_widget
        return widget and (widget.text_widget or widget) or nil
    end

    local function freeFastPreedit(inputtext, restore_committed)
        local tail = inputtext._pinyinime_preedit_tail
        inputtext._pinyinime_preedit_tail = nil
        inputtext._pinyinime_fast_preedit = nil
        if tail and tail.free then
            pcall(tail.free, tail, true)
        end
        local widget = innerTextWidget(inputtext)
        if not restore_committed or not widget or not widget._bb then
            return
        end
        widget.preedit_start_idx = nil
        widget.preedit_end_idx = nil
        widget.preedit_cursor_idx = nil
        widget:free(false)
        widget:_updateLayout()
        if widget.editable then
            widget:moveCursorToCharPos(inputtext.charpos or 1)
        end
        if not inputtext.for_measurement_only then
            UIManager:setDirty(inputtext.parent, "ui", inputtext.dimen)
        end
    end
    runtime.free_legacy_fast_preedit = freeFastPreedit

    local function fastPreeditTail(inputtext, preedit_text)
        if inputtext._pinyinime_disable_fast_preedit
                or inputtext.text_type == "password"
                or inputtext.input_type == "number"
                or inputtext.do_select or inputtext.alignment ~= "left"
                or inputtext.para_direction_rtl
                or inputtext.auto_para_direction then
            return false
        end
        local committed = inputtext.charlist
        local logical_charpos = inputtext.charpos or (#committed + 1)
        if logical_charpos ~= #committed + 1 then
            return false
        end
        local widget = innerTextWidget(inputtext)
        local lines = widget and widget.vertical_string_list
        if not widget or not widget._bb or type(lines) ~= "table"
                or not widget.line_height_px then
            return false
        end

        local line_index = #lines
        local line = lines[line_index]
        if not line then
            line_index = 1
            line = { offset = 1 }
        end
        local virtual_line = widget.height == nil and 1
            or (widget.virtual_line_num or 1)
        if widget.height ~= nil then
            -- InputText's full re-init clamps a hard-page top line to the
            -- final full viewport (e.g., 251 -> 242 for ten visible lines).
            -- Mirror that constant-time adjustment so the first preedit does
            -- not leave blank rows above a tail cursor.
            local maximum_top = math.max(
                1, #lines - (widget.lines_per_page or 1) + 1)
            virtual_line = math.min(virtual_line, maximum_top)
            widget.virtual_line_num = virtual_line
            inputtext.top_line_num = virtual_line
        end
        local row = line_index - virtual_line + 1
        if row < 1 or row > (widget.lines_per_page or 1) then
            return false
        end

        local tail_chars = {}
        local line_offset = math.max(1, tonumber(line.offset) or 1)
        for index = line_offset, #committed do
            tail_chars[#tail_chars + 1] = committed[index]
        end
        local preedit_chars = util.splitToChars(preedit_text)
        if #preedit_chars > 64 then
            return false
        end
        local preedit_start = #tail_chars + 1
        for _, char in ipairs(preedit_chars) do
            tail_chars[#tail_chars + 1] = char
        end
        if #tail_chars == 0 or #tail_chars > 256 then
            return false
        end

        local tail = TextBoxWidget:new{
            text = table.concat(tail_chars),
            charlist = tail_chars,
            charpos = #tail_chars + 1,
            editable = true,
            face = widget.face,
            fgcolor = widget.fgcolor,
            bgcolor = widget.bgcolor,
            alignment = widget.alignment,
            justified = widget.justified,
            lang = widget.lang,
            para_direction_rtl = widget.para_direction_rtl,
            auto_para_direction = widget.auto_para_direction,
            alignment_strict = widget.alignment_strict,
            use_xtext = widget.use_xtext,
            width = widget.width,
            height = widget.line_height_px,
            preedit_start_idx = preedit_start,
            preedit_end_idx = #tail_chars,
            preedit_cursor_idx = #tail_chars + 1,
            for_measurement_only = true,
        }
        if #tail.vertical_string_list ~= 1 or tail.virtual_line_num ~= 1
                or not tail._bb then
            tail:free(true)
            return false
        end
        local cursor_x, cursor_y = tail:_getXYForCharPos(#tail_chars + 1)
        cursor_x = math.min(cursor_x,
            tail.width - tail.cursor_line.dimen.w)
        tail.cursor_line:paintTo(tail._bb, cursor_x, cursor_y)
        tail._pinyinime_cursor_x = cursor_x

        freeFastPreedit(inputtext, false)
        widget.preedit_start_idx = nil
        widget.preedit_end_idx = nil
        widget.preedit_cursor_idx = nil
        widget:free(false)
        widget:_updateLayout()
        local y = (row - 1) * widget.line_height_px
        widget._bb:blitFrom(tail._bb, 0, y, 0, 0,
            math.min(widget._bb:getWidth(), tail._bb:getWidth()),
            math.min(widget.line_height_px, tail._bb:getHeight()))
        inputtext._pinyinime_preedit_tail = tail
        inputtext._pinyinime_fast_preedit = true
        inputtext._preedit_start_idx = logical_charpos
        inputtext._preedit_end_idx = logical_charpos + #preedit_chars - 1
        inputtext._preedit_cursor_idx = logical_charpos + #preedit_chars
        local outer = inputtext.text_widget
        if outer and outer.text_widget == widget and outer.updateScrollBar then
            outer:updateScrollBar()
        end
        if not inputtext.for_measurement_only then
            -- Geometry is already final here. Passing it by value avoids
            -- enqueuing a refresh closure that keeps the whole InputText and
            -- VirtualKeyboard graph alive until a later repaint.
            UIManager:setDirty(inputtext.parent, "ui", inputtext.dimen)
        end
        return true
    end

    runtime.wrapped_inputtext_get_preedit = function(self)
        return self.preedit_text or ""
    end
    InputText.getPreeditText = runtime.wrapped_inputtext_get_preedit
    runtime.wrapped_inputtext_set_preedit = function(self, text)
        text = text or ""
        if self.text_type == "password" or self.input_type == "number" then
            text = ""
        end
        local normalized = text ~= "" and text or nil
        if self.preedit_text == normalized then
            return false
        end
        self.preedit_text = normalized
        if not normalized then
            self._preedit_start_idx = nil
            self._preedit_end_idx = nil
            self._preedit_cursor_idx = nil
        end
        if normalized and fastPreeditTail(self, normalized) then
            return true
        end
        freeFastPreedit(self,
            normalized == nil and not self._pinyinime_finalizing)
        if normalized == nil then
            return true
        end
        self:initTextBox(nil, nil, true)
        return true
    end
    InputText.setPreeditText = runtime.wrapped_inputtext_set_preedit

    runtime.wrapped_inputtext_init_textbox = function(self, text, char_added, display_only)
        freeFastPreedit(self, false)
        local preedit_text = self.preedit_text
        if not preedit_text or preedit_text == ""
                or self.text_type == "password" or self.input_type == "number" then
            return runtime.original_inputtext_init_textbox(self, text, char_added)
        end

        local committed_charlist = self.charlist
        local committed_text = text or table.concat(committed_charlist)
        local logical_charpos = self.charpos or (#committed_charlist + 1)
        local display_charlist = {}
        for i = 1, logical_charpos - 1 do
            display_charlist[#display_charlist + 1] = committed_charlist[i]
        end
        local start_idx = #display_charlist + 1
        for _, char in ipairs(util.splitToChars(preedit_text)) do
            display_charlist[#display_charlist + 1] = char
        end
        local end_idx = #display_charlist
        local cursor_idx = end_idx + 1
        for i = logical_charpos, #committed_charlist do
            display_charlist[#display_charlist + 1] = committed_charlist[i]
        end

        local edit_callback = self.edit_callback
        if display_only then
            self.edit_callback = nil
        end
        self.charlist = display_charlist
        self.charpos = cursor_idx
        pending_preedit = {
            start_idx = start_idx,
            end_idx = end_idx,
            cursor_idx = cursor_idx,
        }
        local ok, err = pcall(runtime.original_inputtext_init_textbox,
            self, table.concat(display_charlist), char_added)
        pending_preedit = nil
        self.charlist = committed_charlist
        self.charpos = logical_charpos
        self.text = committed_text
        self._preedit_start_idx = start_idx
        self._preedit_end_idx = end_idx
        self._preedit_cursor_idx = cursor_idx
        self.edit_callback = edit_callback
        if not ok then
            self.preedit_text = nil
            self._preedit_start_idx = nil
            self._preedit_end_idx = nil
            self._preedit_cursor_idx = nil
            runtime:disableForSession("preedit layout failed: " .. tostring(err), self.keyboard)
            pcall(runtime.original_inputtext_init_textbox, self, committed_text, char_added)
        end
    end
    InputText.initTextBox = runtime.wrapped_inputtext_init_textbox

    local function cancelAttachedEngine(inputtext)
        local item = runtime.legacy_active and runtime.legacy_active[inputtext]
        if item and item.engine then
            item.engine:cancel()
        end
    end

    runtime.wrapped_inputtext_set_text = function(self, text, keep_edited_state)
        cancelAttachedEngine(self)
        self.preedit_text = nil
        self._preedit_start_idx = nil
        self._preedit_end_idx = nil
        self._preedit_cursor_idx = nil
        return runtime.original_inputtext_set_text(self, text, keep_edited_state)
    end
    InputText.setText = runtime.wrapped_inputtext_set_text

    runtime.original_inputtext_del_all = InputText.delAll
    runtime.wrapped_inputtext_del_all = function(self, ...)
        cancelAttachedEngine(self)
        return runtime.original_inputtext_del_all(self, ...)
    end
    InputText.delAll = runtime.wrapped_inputtext_del_all
end

local function newEngine(runtime)
    if runtime.newInputMethod then
        return runtime:newInputMethod()
    end
    return runtime.PinyinIME:new{
        code_map = runtime.code_map,
        abbreviation_map = runtime.abbreviation_map,
        user_frequency = runtime.settings.user_frequency,
        get_learning_sequence = function()
            return runtime.settings:getLearningSequence()
        end,
        correction_full = runtime.correction_full,
        correction_shuangpin = runtime.correction_shuangpin,
        shuangpin_decoder = runtime.shuangpin_decoder,
        input_scheme = runtime.settings.getInputScheme
            and runtime.settings:getInputScheme() or "full",
        on_timing = runtime._profilingCallback
            and runtime:_profilingCallback() or nil,
        on_commit = function(code, candidate)
            runtime.settings:learn(code, candidate)
        end,
    }
end

local function updateLegacySpaceKey(keyboard, allow_repaint)
    local key = keyboard.input_method_scheme_key
    if not key or not keyboard.input_method then
        return false
    end
    allow_repaint = allow_repaint ~= false
    local label = keyboard.input_method:getInputSchemeLabel()
    if key.setAccessibilityLabel then
        key:setAccessibilityLabel(keyboard.input_method:getInputSchemeAccessibilityLabel())
    else
        key.accessibility_label = keyboard.input_method:getInputSchemeAccessibilityLabel()
    end
    if key.setAltLabel then
        if not allow_repaint then
            -- The layout descriptor already supplied this label while the key
            -- was being constructed. Avoid any helper that may repaint before
            -- the new key has acquired screen geometry.
            key.alt_label = label
            return true
        end
        return key:setAltLabel(label)
    end

    -- Supported releases do not expose the alt-label TextWidget. Their stable key tree is
    -- Frame -> Center -> OverlapGroup -> right WidgetContainer -> TextWidget.
    local center = key[1] and key[1][1]
    local overlap = center and center[1]
    local container = overlap and overlap[2]
    local widget = container and container[1]
    if widget and key.face and key.face.orig_font and key.face.orig_size then
        local label_size = math.max(MIN_SCHEME_LABEL_SIZE,
            math.floor(key.face.orig_size * SCHEME_LABEL_SCALE + 0.5))
        local replacement = TextWidget:new{
            text = label,
            face = Font:getFace(key.face.orig_font, label_size),
            bold = false,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            padding = 0,
        }
        container[1] = replacement
        key.alt_label = label
        if container.dimen then
            container.dimen.w = replacement:getSize().w
        end
        if widget.free then
            widget:free()
        end
        if allow_repaint and keyboard.visible and key.update_keyboard
                and key[1] and key[1].dimen then
            key:update_keyboard(false)
        end
        return true
    end
    return false
end

local function updateInstanceSpaceDescriptor(keyboard)
    local descriptor = keyboard._pinyinime_instance_keys
        and keyboard._pinyinime_instance_keys[5]
        and keyboard._pinyinime_instance_keys[5][4]
    if not descriptor or not keyboard.input_method then
        return false
    end
    local label = keyboard.input_method:getInputSchemeLabel()
    for layer = 1, 4 do
        local value = descriptor[layer]
        if type(value) == "table" then
            value.alt_label = label
        end
    end
    return true
end

local function installKeyboard(runtime)
    local InputText = require("ui/widget/inputtext")
    local VirtualKeyboard = require("ui/widget/virtualkeyboard")
    local layout = require("ui/data/keyboardlayouts/zh_CN_keyboard")
    local active = setmetatable({}, { __mode = "k" })
    runtime.legacy_active = active

    runtime.legacy_virtualkeyboard = VirtualKeyboard
    runtime.legacy_layout = layout
    runtime.original_virtualkeyboard_init = VirtualKeyboard.init
    runtime.original_virtualkeyboard_add_keys = VirtualKeyboard.addKeys
    runtime.original_virtualkeyboard_on_close_widget = VirtualKeyboard.onCloseWidget
    runtime.original_virtualkeyboard_update_candidate_bar = VirtualKeyboard._updateInputMethodCandidateBar
    runtime.original_virtualkeyboard_update_scheme_key = VirtualKeyboard._updateInputMethodSchemeKey
    runtime.original_virtualkeyboard_set_candidates_expanded =
        VirtualKeyboard._setInputMethodCandidatesExpanded
    runtime.original_inputtext_on_close_widget = InputText.onCloseWidget
    runtime.original_layout_wrap_input_box = layout.wrapInputBox
    runtime.original_layout_gen_menu_items = layout.genMenuItems

    local function copyRegion(dimen)
        return Geom:new{
            x = dimen.x,
            y = dimen.y,
            w = dimen.w,
            h = dimen.h,
        }
    end

    local function cancelKeyRefreshTask(keyboard)
        keyboard._ime_key_refresh_generation =
            (keyboard._ime_key_refresh_generation or 0) + 1
        if keyboard._ime_key_refresh_task then
            pcall(UIManager.unschedule, UIManager, keyboard._ime_key_refresh_task)
        end
        if keyboard._ime_key_refresh_action then
            pcall(UIManager.unschedule, UIManager, keyboard._ime_key_refresh_action)
        end
        keyboard._ime_key_refresh_task = nil
        keyboard._ime_key_refresh_action = nil
        keyboard._ime_pending_key_refreshes = nil
    end

    local function cancelStructuralRefreshTask(keyboard)
        keyboard._ime_structural_refresh_generation =
            (keyboard._ime_structural_refresh_generation or 0) + 1
        if keyboard._ime_structural_refresh_action then
            pcall(UIManager.unschedule, UIManager,
                keyboard._ime_structural_refresh_action)
        end
        keyboard._ime_structural_refresh_action = nil
    end

    local function cancelCandidateRestoreTask(keyboard)
        keyboard._ime_candidate_restore_generation =
            (keyboard._ime_candidate_restore_generation or 0) + 1
        if keyboard._ime_candidate_restore_action then
            pcall(UIManager.unschedule, UIManager,
                keyboard._ime_candidate_restore_action)
        end
        keyboard._ime_candidate_restore_action = nil
    end

    local function detachActiveInput(inputbox, mode, final_disposal)
        local item = active[inputbox]
        if not item then
            return false
        end

        if final_disposal then
            inputbox._pinyinime_finalizing = true
        end
        if final_disposal and runtime.free_legacy_fast_preedit then
            pcall(runtime.free_legacy_fast_preedit, inputbox, false)
        end

        local keyboard = item.keyboard
        local engine = item.engine
        if final_disposal and keyboard then
            cancelKeyRefreshTask(keyboard)
            cancelStructuralRefreshTask(keyboard)
            cancelCandidateRestoreTask(keyboard)
            if keyboard.input_method_candidates_expanded
                    and keyboard._setInputMethodCandidatesExpanded then
                pcall(keyboard._setInputMethodCandidatesExpanded, keyboard, false)
            end
            if keyboard.input_method_candidate_bar then
                pcall(keyboard.input_method_candidate_bar.discardBackground,
                    keyboard.input_method_candidate_bar)
            end
        end

        -- Remove registry ownership before invoking plugin code. Detach may
        -- synchronously notify the input box, and any failure must not leave a
        -- second strong ownership path behind.
        if active[inputbox] == item then
            active[inputbox] = nil
        end
        local detach = item.detach
        item.detach = nil
        if detach then
            pcall(detach, mode or "cancel")
        end
        if keyboard and keyboard.uwrap_func == item.detach_wrapper then
            keyboard.uwrap_func = nil
        end
        if keyboard and keyboard.input_method == engine then
            keyboard.input_method = nil
        end
        item.detach_wrapper = nil
        item.keyboard = nil
        item.engine = nil
        return true
    end
    runtime.detach_legacy_input = detachActiveInput

    runtime.wrapped_inputtext_on_close_widget = function(self, ...)
        -- InputText:onCloseWidget is final disposal. VirtualKeyboard's close
        -- event is also used for temporary hide/show and must remain attached.
        detachActiveInput(self, "cancel", true)
        return runtime.original_inputtext_on_close_widget(self, ...)
    end
    InputText.onCloseWidget = runtime.wrapped_inputtext_on_close_widget

    local function scheduleCandidateBackgroundRestore(keyboard, refresh_region,
            allow_active)
        cancelCandidateRestoreTask(keyboard)
        local generation = keyboard._ime_candidate_restore_generation
        local region = copyRegion(refresh_region)
        local action
        action = function()
            if keyboard._ime_candidate_restore_generation ~= generation
                    or keyboard._ime_candidate_restore_action ~= action then
                return
            end
            keyboard._ime_candidate_restore_action = nil
            local candidate_bar = keyboard.input_method_candidate_bar
            if not keyboard.visible or not candidate_bar
                    or (candidate_bar:isActive() and not allow_active) then
                return
            end
            UIManager:setDirty("all", "ui", region)
            UIManager:forceRePaint()
        end
        keyboard._ime_candidate_restore_action = action
        UIManager:nextTick(action)
    end

    local function normalizeKeyVisualStates(keyboard)
        for _, row in ipairs(keyboard.layout or {}) do
            for _, key in ipairs(row) do
                if key[1] then
                    key[1].inner_bordersize = 0
                end
            end
        end
    end

    local function detachKeyRefreshGuards(keyboard)
        cancelKeyRefreshTask(keyboard)
        for _, guard in ipairs(keyboard._ime_key_refresh_guards or {}) do
            if rawget(guard.key, "update_keyboard") == guard.wrapper then
                rawset(guard.key, "update_keyboard", guard.original_raw)
            end
        end
        keyboard._ime_key_refresh_guards = nil
    end

    local function repaintReleasedKeys(keyboard, generation)
        if keyboard._ime_key_refresh_generation ~= generation then
            return false
        end
        keyboard._ime_key_refresh_task = nil
        keyboard._ime_key_refresh_action = nil
        local pending = keyboard._ime_pending_key_refreshes or {}
        keyboard._ime_pending_key_refreshes = {}
        if not keyboard.visible or keyboard.input_method_candidates_expanded then
            return false
        end
        for key in pairs(pending) do
            local frame = key.keyboard == keyboard and key[1]
            local dimen = frame and frame.dimen
            if dimen and frame.inner_bordersize == 0 then
                UIManager:widgetRepaint(frame, dimen.x, dimen.y)
                UIManager:setDirty(nil, "[ui]", copyRegion(dimen))
            end
        end
        return true
    end

    local function scheduleReleasedKeyRepaint(keyboard, key)
        keyboard._ime_pending_key_refreshes =
            keyboard._ime_pending_key_refreshes or {}
        keyboard._ime_pending_key_refreshes[key] = true
        if keyboard._ime_key_refresh_task or keyboard._ime_key_refresh_action then
            return
        end
        local generation = keyboard._ime_key_refresh_generation or 0
        local action = function()
            local ok, err = xpcall(function()
                repaintReleasedKeys(keyboard, generation)
            end, debug.traceback)
            if not ok then
                runtime:disableForSession(
                    "keyboard key cleanup failed: " .. tostring(err), keyboard)
            end
        end
        keyboard._ime_key_refresh_action = action
        if type(UIManager.tickAfterNext) == "function" then
            keyboard._ime_key_refresh_task = UIManager:tickAfterNext(action)
        else
            keyboard._ime_key_refresh_task = action
            UIManager:scheduleIn(0, action)
        end
    end

    local function installKeyRefreshGuards(keyboard)
        detachKeyRefreshGuards(keyboard)
        keyboard._ime_key_refresh_generation =
            (keyboard._ime_key_refresh_generation or 0) + 1
        keyboard._ime_pending_key_refreshes = {}
        keyboard._ime_key_refresh_guards = {}
        for _, row in ipairs(keyboard.layout or {}) do
            for _, key in ipairs(row) do
                local original_raw = rawget(key, "update_keyboard")
                local original_update = key.update_keyboard
                if type(original_update) == "function" then
                    local wrapper
                    wrapper = function(key_instance, want_flash, want_a2)
                        local result = original_update(key_instance, want_flash, want_a2)
                        local frame = key_instance[1]
                        if want_a2 and key_instance.flash_keyboard
                                and frame and frame.inner_bordersize == 0 then
                            scheduleReleasedKeyRepaint(keyboard, key_instance)
                        end
                        return result
                    end
                    key.update_keyboard = wrapper
                    keyboard._ime_key_refresh_guards[#keyboard._ime_key_refresh_guards + 1] = {
                        key = key,
                        wrapper = wrapper,
                        original_raw = original_raw,
                    }
                end
            end
        end
    end

    local function prepareStructuralRefresh(keyboard)
        cancelStructuralRefreshTask(keyboard)
        cancelCandidateRestoreTask(keyboard)
        if keyboard.input_method_candidate_bar then
            keyboard.input_method_candidate_bar:requestBackgroundCapture()
        end
        detachKeyRefreshGuards(keyboard)
        normalizeKeyVisualStates(keyboard)
    end

    local function finishStructuralRefresh(keyboard)
        if not keyboard.visible or not keyboard.dimen then
            return
        end
        -- Queue the structural dirty region immediately, but defer the forced
        -- repaint until the current input callback has completely unwound.
        -- Candidate submission rebuilds InputText's TextBoxWidget in that same
        -- callback; repainting synchronously can otherwise reach its freed
        -- blitbuffer and disable the IME for the session.
        keyboard:_refresh(true)
        local generation = keyboard._ime_structural_refresh_generation or 0
        local action
        action = function()
            if keyboard._ime_structural_refresh_generation ~= generation
                    or keyboard._ime_structural_refresh_action ~= action then
                return
            end
            keyboard._ime_structural_refresh_action = nil
            if not keyboard.visible or not keyboard.dimen then
                return
            end
            UIManager:forceRePaint()
            if type(UIManager.waitForVSync) == "function" then
                UIManager:waitForVSync()
            end
        end
        keyboard._ime_structural_refresh_action = action
        UIManager:nextTick(action)
    end

    runtime.detach_legacy_key_refresh_guards = detachKeyRefreshGuards
    runtime.cancel_legacy_structural_refresh = cancelStructuralRefreshTask
    runtime.cancel_legacy_candidate_restore = cancelCandidateRestoreTask

    local function shallowCopy(source_table)
        local copy = {}
        for key, value in pairs(source_table or {}) do
            copy[key] = value
        end
        return copy
    end

    local function restoreInstanceKeys(keyboard)
        cancelCandidateRestoreTask(keyboard)
        if keyboard.input_method_candidate_bar then
            keyboard.input_method_candidate_bar:discardBackground()
        end
        if keyboard._pinyinime_instance_keys
                and keyboard.KEYS == keyboard._pinyinime_instance_keys then
            keyboard.KEYS = keyboard._pinyinime_base_keys
        end
        keyboard._pinyinime_base_keys = nil
        keyboard._pinyinime_instance_keys = nil
        keyboard._pinyinime_semicolon_mode = nil
    end

    local function addPopupValue(descriptor, value)
        for index = 2, #descriptor do
            if descriptor[index] == value then
                return
            end
        end
        descriptor[#descriptor + 1] = value
    end

    local function installInstanceKeys(keyboard)
        local base = keyboard.KEYS
        if keyboard._pinyinime_instance_keys
                and base == keyboard._pinyinime_instance_keys then
            base = keyboard._pinyinime_base_keys
        end
        if type(base) ~= "table" or type(base[3]) ~= "table"
                or type(base[5]) ~= "table" then
            error("Simplified Chinese keyboard rows are unavailable")
        end

        local keys = shallowCopy(base)
        local space_row = shallowCopy(base[5])
        local space_descriptor = shallowCopy(base[5][4])
        local scheme_label = keyboard.input_method:getInputSchemeLabel()
        for layer = 1, layout.max_layer or 4 do
            local value = base[5][4][layer]
            if type(value) == "table" then
                value = shallowCopy(value)
            elseif type(value) == "string" then
                value = { value }
            end
            if type(value) == "table" then
                value.alt_label = scheme_label
                space_descriptor[layer] = value
            end
        end
        space_row[4] = space_descriptor
        keys[5] = space_row

        local scheme = keyboard.input_method:getInputScheme()
        local semicolon_mode = runtime.InputSchemes.requiresSemicolon(scheme)
        if semicolon_mode then
            local punctuation_row = shallowCopy(base[3])
            local punctuation_key = shallowCopy(base[3][10])
            local original = base[3][10][2]
            local replacement = shallowCopy(original)
            replacement[1] = ";"
            replacement.label = "; ing"
            replacement.north = "，"
            replacement.alt_label = "，"
            replacement.south = ","
            for index = #replacement, 2, -1 do
                if replacement[index] == ";" or replacement[index] == "；" then
                    table.remove(replacement, index)
                end
            end
            addPopupValue(replacement, "；")
            punctuation_key[2] = replacement
            punctuation_row[10] = punctuation_key
            keys[3] = punctuation_row
        end

        keyboard._pinyinime_base_keys = base
        keyboard._pinyinime_instance_keys = keys
        keyboard._pinyinime_semicolon_mode = semicolon_mode
        keyboard.KEYS = keys
    end

    runtime.restore_legacy_instance_keys = restoreInstanceKeys

    -- The plugin owns its settings menu while active. Hiding the original
    -- layout items avoids exposing the built-in IME's ineffective candidate
    -- toggle and a duplicate input-scheme selector. Uninstall restores the
    -- unmodified layout function.
    runtime.wrapped_layout_gen_menu_items = function()
        return {}
    end
    layout.genMenuItems = runtime.wrapped_layout_gen_menu_items

    runtime.wrapped_layout_wrap_input_box = function(inputbox)
        if runtime.state ~= "active" then
            if runtime.original_layout_wrap_input_box then
                return runtime.original_layout_wrap_input_box(inputbox)
            end
            return
        end
        local item = active[inputbox]
        if item then
            local ok, detach = xpcall(function()
                return item.engine:attach(inputbox, function(state)
                    item.keyboard:_updateInputMethodCandidateBar(state)
                end)
            end, debug.traceback)
            if not ok then
                runtime:disableForSession("input box attachment failed: " .. tostring(detach),
                    item.keyboard)
                return runtime.original_layout_wrap_input_box
                    and runtime.original_layout_wrap_input_box(inputbox) or nil
            end
            item.detach = detach
            local detach_wrapper
            detach_wrapper = function(mode)
                if item.detach then
                    local active_detach = item.detach
                    item.detach = nil
                    local result = active_detach(mode)
                    if active[inputbox] == item then
                        active[inputbox] = nil
                    end
                    if item.keyboard
                            and item.keyboard.uwrap_func == detach_wrapper then
                        item.keyboard.uwrap_func = nil
                    end
                    if item.keyboard
                            and item.keyboard.input_method == item.engine then
                        item.keyboard.input_method = nil
                    end
                    return result
                end
            end
            item.detach_wrapper = detach_wrapper
            return detach_wrapper
        end
        if inputbox.input_type == "number" or inputbox.text_type == "password"
                or inputbox.is_password_type then
            return nil
        end
        if runtime.original_layout_wrap_input_box then
            return runtime.original_layout_wrap_input_box(inputbox)
        end
    end
    layout.wrapInputBox = runtime.wrapped_layout_wrap_input_box

    local function syncVisibleCandidateSlots(self)
        if self.input_method and self.input_method.setVisibleCandidateSlots
                and self.input_method_candidate_bar then
            self.input_method:setVisibleCandidateSlots(
                self.input_method_candidate_bar:getVisibleCandidateSlots())
        end
    end

    local function setCandidatesExpanded(self, expanded)
        expanded = expanded == true
        if not self.input_method or not self.input_method_keyboard_group
                or not self.input_method_keyboard_frame then
            if expanded then
                runtime:disableForSession("candidate panel container is unavailable", self)
            end
            return false
        end

        if expanded and self.input_method.expandLexiconCandidates then
            self.input_method:expandLexiconCandidates()
        end
        local candidates = self.input_method:getAllCandidates()
        if expanded and #candidates == 0 then
            return false
        end
        if self.input_method_candidates_expanded == expanded then
            if expanded and self.input_method_candidate_panel then
                local state = self.input_method:getState()
                self.input_method_candidate_panel:updateCandidates(
                    candidates, state.selected_index,
                    self.input_method:getAllCandidateMetadata())
            end
            return false
        end

        prepareStructuralRefresh(self)

        local old_panel = self.input_method_candidate_panel
        if expanded then
            local keyboard_size = self.input_method_keyboard_frame:getSize()
            self.input_method_candidate_panel = runtime.CandidatePanel:new{
                width = keyboard_size.w,
                height = keyboard_size.h,
                show_parent = self,
                candidates = candidates,
                metadata = self.input_method:getAllCandidateMetadata(),
                selected_index = self.input_method:getState().selected_index,
                on_candidate = function(index)
                    self.input_method:insertCandidate(index)
                    if self.input_method_candidates_expanded then
                        self:_setInputMethodCandidatesExpanded(false)
                    end
                end,
                on_close = function()
                    self:_setInputMethodCandidatesExpanded(false)
                end,
            }
            self.input_method_keyboard_group[2] = self.input_method_candidate_panel
        else
            self.input_method_candidate_panel = nil
            self.input_method_keyboard_group[2] = self.input_method_keyboard_frame
        end
        self.input_method_keyboard_group:resetLayout()
        self.input_method_candidates_expanded = expanded
        self.input_method_candidate_bar:setExpanded(expanded)
        syncVisibleCandidateSlots(self)

        if old_panel and old_panel ~= self.input_method_candidate_panel and old_panel.free then
            old_panel:free()
        end
        installKeyRefreshGuards(self)
        finishStructuralRefresh(self)
        return true
    end
    runtime.wrapped_keyboard_set_candidates_expanded = function(self, expanded)
        local ok, result = xpcall(function()
            return setCandidatesExpanded(self, expanded)
        end, debug.traceback)
        if not ok then
            runtime:disableForSession("candidate panel update failed: " .. tostring(result), self)
            return false
        end
        return result
    end
    VirtualKeyboard._setInputMethodCandidatesExpanded =
        runtime.wrapped_keyboard_set_candidates_expanded

    runtime.wrapped_keyboard_update_candidate_bar = function(self, state)
        local profiling_started = runtime.profiling_enabled and os.clock() or nil
        local ok, err = xpcall(function()
            if not self.input_method_candidate_bar then
                return
            end
            local candidate_bar = self.input_method_candidate_bar
            local pending_restore = self._ime_candidate_restore_action ~= nil
            local restore_background = candidate_bar:update(state)
            if candidate_bar:isActive() and pending_restore then
                cancelCandidateRestoreTask(self)
                -- The pixels still underneath the new active surface belong to
                -- the previous candidate view, so they must not become the next
                -- transparent background snapshot.
                candidate_bar:disablePendingBackgroundCapture()
            end
            syncVisibleCandidateSlots(self)
            if self.input_method_candidates_expanded then
                local candidates = self.input_method:getAllCandidates()
                if #candidates == 0 then
                    self:_setInputMethodCandidatesExpanded(false)
                elseif self.input_method_candidate_panel then
                    self.input_method_candidate_panel:updateCandidates(
                        candidates, state.selected_index,
                        self.input_method:getAllCandidateMetadata())
                end
            end
            if not self.visible then
                cancelCandidateRestoreTask(self)
                candidate_bar:requestBackgroundCapture()
            else
                local refresh_region = candidate_bar:getRefreshRegion()
                if refresh_region then
                    refresh_region = copyRegion(refresh_region)
                    local refresh_started = runtime.profiling_enabled
                        and os.clock() or nil
                    if restore_background then
                        if candidate_bar:restoreBackground(Screen.bb) then
                            UIManager:setDirty(nil, "ui", refresh_region)
                        else
                            scheduleCandidateBackgroundRestore(self, refresh_region)
                        end
                    elseif candidate_bar:isActive() then
                        UIManager:widgetRepaint(candidate_bar,
                            refresh_region.x, refresh_region.y)
                        UIManager:setDirty(nil, "ui", refresh_region)
                    end
                    if refresh_started then
                        runtime:_recordProfiling(
                            "refresh_region_submit", os.clock() - refresh_started)
                    end
                elseif candidate_bar:isActive() then
                    self:_refresh(false)
                elseif restore_background then
                    candidate_bar:discardBackground()
                end
            end
        end, debug.traceback)
        if profiling_started then
            runtime:_recordProfiling(
                "candidate_surface_update", os.clock() - profiling_started)
        end
        if not ok then
            runtime:disableForSession("candidate bar update failed: " .. tostring(err), self)
        end
    end
    VirtualKeyboard._updateInputMethodCandidateBar = runtime.wrapped_keyboard_update_candidate_bar

    runtime.wrapped_virtualkeyboard_on_close_widget = function(self, ...)
        cancelCandidateRestoreTask(self)
        if self.input_method_candidate_bar then
            self.input_method_candidate_bar:requestBackgroundCapture()
        end
        return runtime.original_virtualkeyboard_on_close_widget(self, ...)
    end
    VirtualKeyboard.onCloseWidget = runtime.wrapped_virtualkeyboard_on_close_widget

    runtime.wrapped_keyboard_update_scheme_key = function(self)
        local ok, result = xpcall(function()
            return updateLegacySpaceKey(self)
        end, debug.traceback)
        if not ok then
            runtime:disableForSession("input scheme label update failed: "
                .. tostring(result), self)
            return false
        end
        return result
    end
    VirtualKeyboard._updateInputMethodSchemeKey = runtime.wrapped_keyboard_update_scheme_key

    runtime.wrapped_virtualkeyboard_init = function(self)
        -- The stock initializer recomputes base keyboard height before addKeys.
        self._chinese_pinyin_bar_added = nil
        local lang = self:getKeyboardLayout()
        local allowed = lang == "zh_CN" and self.inputbox.input_type ~= "number"
            and self.inputbox.text_type ~= "password" and not self.inputbox.is_password_type
        if allowed then
            local ok, engine = xpcall(function()
                return newEngine(runtime)
            end, debug.traceback)
            if ok then
                self.input_method = engine
            else
                self.input_method = nil
                runtime:disableForSession("input method creation failed: " .. tostring(engine), self)
            end
            if self.input_method then
                active[self.inputbox] = { engine = self.input_method, keyboard = self }
            else
                active[self.inputbox] = nil
            end
        else
            self.input_method = nil
            active[self.inputbox] = nil
        end
        return runtime.original_virtualkeyboard_init(self)
    end
    VirtualKeyboard.init = runtime.wrapped_virtualkeyboard_init

    local function augmentKeyboard(self)
        if not self.input_method then
            self.input_method_candidate_bar = nil
            return
        end
        local space_key = self.layout and self.layout[5] and self.layout[5][4]
        if space_key then
            self.input_method_scheme_key = space_key
            space_key.hold_callback = function()
                space_key.ignore_key_release = true
                runtime:showInputSchemeDialog()
            end
            space_key.hold_cb_is_popup = true
            updateLegacySpaceKey(self, false)
        end
        local backspace_key = self.layout and self.layout[4] and self.layout[4][9]
        if backspace_key then
            local original_hold = backspace_key.hold_callback
            backspace_key.hold_callback = function()
                local ok, err = xpcall(function()
                    if self.input_method and self.input_method:isComposing() then
                        backspace_key.ignore_key_release = true
                        self.input_method:deleteLastUnit()
                    elseif original_hold then
                        original_hold()
                    end
                end, debug.traceback)
                if not ok then
                    runtime:disableForSession(
                        "held backspace failed: " .. tostring(err), self)
                end
            end
            backspace_key.hold_cb_is_popup = false
            backspace_key.accessibility_label =
                "退格，短按删除字母，拼音输入时长按删除上一个拼音单元"
            backspace_key.help_text = backspace_key.accessibility_label
        end

        self.candidate_bar_height = Screen:scaleBySize(48)
        self.input_method_bar_height = self.candidate_bar_height
        local candidate_bar_width = self.width - 2 * Size.border.default - 2 * self.padding
        self.input_method_candidate_bar = runtime.CandidateBar:new{
            width = candidate_bar_width,
            height = self.candidate_bar_height,
            page_size = self.input_method.page_size,
            on_timing = runtime._profilingCallback
                and runtime:_profilingCallback() or nil,
            on_candidate = function(slot) self.input_method:insertCandidateOnPage(slot) end,
            on_previous_page = function() self.input_method:previousPage() end,
            on_next_page = function() self.input_method:nextPage() end,
            on_toggle_expanded = function(expanded)
                self:_setInputMethodCandidatesExpanded(expanded)
            end,
        }
        self.input_method_candidate_bar:update(self.input_method:getState())
        syncVisibleCandidateSlots(self)

        local bottom_container = self[1]
        local keyboard_frame = bottom_container and bottom_container[1]
        if not keyboard_frame or not keyboard_frame.getSize then
            self.input_method = nil
            active[self.inputbox] = nil
            runtime:disableForSession("unsupported VirtualKeyboard container structure", self)
            return
        end

        local keyboard_group = VerticalGroup:new{ allow_mirroring = false }
        table.insert(keyboard_group, self.input_method_candidate_bar)
        table.insert(keyboard_group, keyboard_frame)
        local keyboard_surface = ProtectedKeyboardSurface:new{
            margin = 0,
            bordersize = 0,
            background = nil,
            radius = 0,
            padding = 0,
            allow_mirroring = false,
            on_paint_error = function(err)
                runtime:disableForSession("keyboard candidate rendering failed: "
                    .. tostring(err), self)
            end,
            keyboard_group,
        }
        bottom_container[1] = keyboard_surface
        self.height = self.height + self.input_method_bar_height
        keyboard_surface.dimen = keyboard_surface:getSize()
        self.dimen = keyboard_surface.dimen
        self.input_method_keyboard_group = keyboard_group
        self.input_method_keyboard_frame = keyboard_frame
        self.input_method_keyboard_surface = keyboard_surface
        self.input_method_candidates_expanded = false
        self._chinese_pinyin_bar_added = true
        installKeyRefreshGuards(self)
    end

    runtime.wrapped_virtualkeyboard_add_keys = function(self)
        local rebuild_visible_plugin_keyboard = self.visible
            and self._chinese_pinyin_bar_added == true
        if self.input_method or self._chinese_pinyin_bar_added
                or self._ime_key_refresh_guards then
            prepareStructuralRefresh(self)
        end
        if self.input_method_candidates_expanded and self.input_method_keyboard_group
                and self.input_method_keyboard_frame then
            local old_panel = self.input_method_candidate_panel
            self.input_method_keyboard_group[2] = self.input_method_keyboard_frame
            self.input_method_keyboard_group:resetLayout()
            self.input_method_candidate_panel = nil
            self.input_method_candidates_expanded = false
            if old_panel and old_panel.free then
                old_panel:free()
            end
        end
        if self._chinese_pinyin_bar_added then
            self.height = self.height - self.input_method_bar_height
            self._chinese_pinyin_bar_added = nil
        end
        self.input_method_candidate_panel = nil
        self.input_method_candidates_expanded = false
        self.input_method_keyboard_frame = nil
        self.input_method_keyboard_group = nil
        if self.input_method then
            installInstanceKeys(self)
        else
            restoreInstanceKeys(self)
        end
        runtime.original_virtualkeyboard_add_keys(self)
        local ok, err = xpcall(function()
            augmentKeyboard(self)
        end, debug.traceback)
        if not ok then
            self.input_method = nil
            self.input_method_candidate_bar = nil
            active[self.inputbox] = nil
            runtime:disableForSession("keyboard augmentation failed: " .. tostring(err), self)
        end
        if ok and rebuild_visible_plugin_keyboard then
            finishStructuralRefresh(self)
        end
    end
    VirtualKeyboard.addKeys = runtime.wrapped_virtualkeyboard_add_keys
end

function ReleaseAdapter.install(runtime)
    if not runtime.compatibility_probe_passed then
        local compatible, reason = ReleaseAdapter.probe(runtime)
        if not compatible then
            error(reason)
        end
    end
    installPreedit(runtime)
    installKeyboard(runtime)
    return true
end

function ReleaseAdapter.updateSchemeLabels(runtime)
    for _, item in pairs(runtime.legacy_active or {}) do
        local keyboard = item.keyboard
        if keyboard and keyboard.input_method then
            local desired_semicolon = runtime.InputSchemes.requiresSemicolon(
                keyboard.input_method:getInputScheme())
            if keyboard._pinyinime_semicolon_mode ~= nil
                    and keyboard._pinyinime_semicolon_mode ~= desired_semicolon then
                keyboard:addKeys()
            else
                updateInstanceSpaceDescriptor(keyboard)
                updateLegacySpaceKey(keyboard)
            end
        end
    end
end

function ReleaseAdapter.uninstall(runtime, detach_mode)
    detach_mode = detach_mode or "candidate"
    for inputbox, item in pairs(runtime.legacy_active or {}) do
        if runtime.free_legacy_fast_preedit then
            pcall(runtime.free_legacy_fast_preedit, inputbox, false)
        end
        if item.detach then
            local detach = item.detach
            item.detach = nil
            pcall(detach, detach_mode)
        elseif item.keyboard and item.keyboard.uwrap_func then
            local detach = item.keyboard.uwrap_func
            item.keyboard.uwrap_func = nil
            pcall(detach, detach_mode)
        end
        if item.keyboard and item.keyboard._setInputMethodCandidatesExpanded then
            pcall(item.keyboard._setInputMethodCandidatesExpanded, item.keyboard, false)
        end
        if item.keyboard then
            local keyboard = item.keyboard
            if runtime.detach_legacy_key_refresh_guards then
                pcall(runtime.detach_legacy_key_refresh_guards, keyboard)
            end
            if runtime.cancel_legacy_structural_refresh then
                pcall(runtime.cancel_legacy_structural_refresh, keyboard)
            end
            if runtime.cancel_legacy_candidate_restore then
                pcall(runtime.cancel_legacy_candidate_restore, keyboard)
            end
            if keyboard.input_method_candidate_bar then
                pcall(keyboard.input_method_candidate_bar.discardBackground,
                    keyboard.input_method_candidate_bar)
            end
            if runtime.restore_legacy_instance_keys then
                pcall(runtime.restore_legacy_instance_keys, keyboard)
            end
            keyboard.input_method = nil
            if keyboard._chinese_pinyin_bar_added and keyboard.input_method_bar_height then
                keyboard.height = keyboard.height - keyboard.input_method_bar_height
            end
            keyboard._chinese_pinyin_bar_added = nil
            -- Rebuild through the saved stock method while the wrappers still
            -- exist. This removes the candidate surface and any visible
            -- instance-only key descriptions without touching shared layouts.
            if runtime.original_virtualkeyboard_add_keys then
                pcall(runtime.original_virtualkeyboard_add_keys, keyboard)
            end
            keyboard.input_method_candidate_bar = nil
            keyboard.input_method_candidate_panel = nil
            keyboard.input_method_candidates_expanded = false
            keyboard.input_method_keyboard_group = nil
            keyboard.input_method_keyboard_frame = nil
            keyboard.input_method_keyboard_surface = nil
            keyboard.input_method_scheme_key = nil
            keyboard._ime_key_refresh_generation = nil
            keyboard._ime_pending_key_refreshes = nil
            keyboard._ime_key_refresh_task = nil
            keyboard._ime_key_refresh_action = nil
            keyboard._ime_key_refresh_guards = nil
            keyboard._ime_structural_refresh_action = nil
            keyboard._ime_structural_refresh_generation = nil
            keyboard._ime_candidate_restore_action = nil
            keyboard._ime_candidate_restore_generation = nil
            keyboard._pinyinime_base_keys = nil
            keyboard._pinyinime_instance_keys = nil
            keyboard._pinyinime_semicolon_mode = nil
            if keyboard.visible and keyboard._refresh then
                pcall(keyboard._refresh, keyboard, true)
            end
        end
    end
    if runtime.legacy_inputtext then
        if runtime.legacy_inputtext.initTextBox == runtime.wrapped_inputtext_init_textbox then
            runtime.legacy_inputtext.initTextBox = runtime.original_inputtext_init_textbox
        end
        if runtime.legacy_inputtext.setText == runtime.wrapped_inputtext_set_text then
            runtime.legacy_inputtext.setText = runtime.original_inputtext_set_text
        end
        if runtime.legacy_inputtext.delAll == runtime.wrapped_inputtext_del_all then
            runtime.legacy_inputtext.delAll = runtime.original_inputtext_del_all
        end
        if runtime.legacy_inputtext.onCloseWidget ==
                runtime.wrapped_inputtext_on_close_widget then
            runtime.legacy_inputtext.onCloseWidget =
                runtime.original_inputtext_on_close_widget
        end
        if runtime.legacy_inputtext.getPreeditText == runtime.wrapped_inputtext_get_preedit then
            runtime.legacy_inputtext.getPreeditText = nil
        end
        if runtime.legacy_inputtext.setPreeditText == runtime.wrapped_inputtext_set_preedit then
            runtime.legacy_inputtext.setPreeditText = nil
        end
    end
    if runtime.legacy_textboxwidget then
        if runtime.legacy_textboxwidget.init == runtime.wrapped_textbox_init then
            runtime.legacy_textboxwidget.init = runtime.original_textbox_init
        end
        if runtime.legacy_textboxwidget._renderText == runtime.wrapped_textbox_render then
            runtime.legacy_textboxwidget._renderText = runtime.original_textbox_render
        end
    end
    if runtime.legacy_virtualkeyboard then
        if runtime.legacy_virtualkeyboard.init == runtime.wrapped_virtualkeyboard_init then
            runtime.legacy_virtualkeyboard.init = runtime.original_virtualkeyboard_init
        end
        if runtime.legacy_virtualkeyboard.addKeys == runtime.wrapped_virtualkeyboard_add_keys then
            runtime.legacy_virtualkeyboard.addKeys = runtime.original_virtualkeyboard_add_keys
        end
        if runtime.legacy_virtualkeyboard.onCloseWidget ==
                runtime.wrapped_virtualkeyboard_on_close_widget then
            runtime.legacy_virtualkeyboard.onCloseWidget =
                runtime.original_virtualkeyboard_on_close_widget
        end
        if runtime.legacy_virtualkeyboard._updateInputMethodCandidateBar ==
                runtime.wrapped_keyboard_update_candidate_bar then
            runtime.legacy_virtualkeyboard._updateInputMethodCandidateBar =
                runtime.original_virtualkeyboard_update_candidate_bar
        end
        if runtime.legacy_virtualkeyboard._updateInputMethodSchemeKey ==
                runtime.wrapped_keyboard_update_scheme_key then
            runtime.legacy_virtualkeyboard._updateInputMethodSchemeKey =
                runtime.original_virtualkeyboard_update_scheme_key
        end
        if runtime.legacy_virtualkeyboard._setInputMethodCandidatesExpanded ==
                runtime.wrapped_keyboard_set_candidates_expanded then
            runtime.legacy_virtualkeyboard._setInputMethodCandidatesExpanded =
                runtime.original_virtualkeyboard_set_candidates_expanded
        end
    end
    if runtime.legacy_layout then
        if runtime.legacy_layout.wrapInputBox == runtime.wrapped_layout_wrap_input_box then
            runtime.legacy_layout.wrapInputBox = runtime.original_layout_wrap_input_box
        end
        if runtime.legacy_layout.genMenuItems == runtime.wrapped_layout_gen_menu_items then
            runtime.legacy_layout.genMenuItems = runtime.original_layout_gen_menu_items
        end
    end
    local adapter_state = {
        "cancel_legacy_candidate_restore",
        "cancel_legacy_structural_refresh",
        "detach_legacy_key_refresh_guards",
        "detach_legacy_input",
        "free_legacy_fast_preedit",
        "legacy_inputtext",
        "legacy_active",
        "legacy_layout",
        "legacy_textboxwidget",
        "legacy_virtualkeyboard",
        "original_inputtext_del_all",
        "original_inputtext_init_textbox",
        "original_inputtext_on_close_widget",
        "original_inputtext_set_text",
        "original_layout_gen_menu_items",
        "original_layout_wrap_input_box",
        "original_textbox_init",
        "original_textbox_render",
        "original_virtualkeyboard_add_keys",
        "original_virtualkeyboard_init",
        "original_virtualkeyboard_on_close_widget",
        "original_virtualkeyboard_set_candidates_expanded",
        "original_virtualkeyboard_update_candidate_bar",
        "original_virtualkeyboard_update_scheme_key",
        "restore_legacy_instance_keys",
        "wrapped_inputtext_del_all",
        "wrapped_inputtext_get_preedit",
        "wrapped_inputtext_init_textbox",
        "wrapped_inputtext_on_close_widget",
        "wrapped_inputtext_set_preedit",
        "wrapped_inputtext_set_text",
        "wrapped_keyboard_set_candidates_expanded",
        "wrapped_keyboard_update_candidate_bar",
        "wrapped_keyboard_update_scheme_key",
        "wrapped_layout_gen_menu_items",
        "wrapped_layout_wrap_input_box",
        "wrapped_textbox_init",
        "wrapped_textbox_render",
        "wrapped_virtualkeyboard_add_keys",
        "wrapped_virtualkeyboard_init",
        "wrapped_virtualkeyboard_on_close_widget",
    }
    for _, field in ipairs(adapter_state) do
        runtime[field] = nil
    end
end

return ReleaseAdapter
