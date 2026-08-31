local HorizontalSpan = require("ui/widget/horizontalspan")
local Menu = require("ui/widget/menu")
local Size = require("ui/size")

-- A keyboard-sized, embedded Menu. It deliberately uses one full-width item
-- per candidate and flexible row heights so long phrases can wrap instead of
-- competing for horizontal space in the compact candidate bar.
local InputMethodCandidatePanel = Menu:extend{
    no_title = true,
    is_borderless = true,
    is_popout = false,
    is_enable_shortcut = false,
    items_font_size = 22,
    -- The IME caps composition at 64 characters. Let every character wrap if
    -- necessary rather than asking Menu to ellipsize an expanded candidate.
    items_max_lines = 64,
    items_padding = Size.padding.small,
    on_candidate = nil,
    on_close = nil,
}

local function makeItemTable(candidates, selected_index, metadata)
    candidates = candidates or {}
    metadata = metadata or {}
    local items = {}
    for index, candidate in ipairs(candidates) do
        local kind = (metadata[index] or {}).kind or "normal"
        local selected_label = index == selected_index and "，当前选中" or ""
        local label
        if kind == "correction" then
            label = "纠错候选 " .. tostring(index) .. selected_label .. "，共 "
                .. tostring(#candidates) .. " 项：" .. candidate .. "，点击提交"
        elseif kind == "fallback" then
            label = "原文候选 " .. tostring(index) .. selected_label .. "，共 "
                .. tostring(#candidates) .. " 项：" .. candidate .. "，点击提交"
        elseif kind == "prediction" then
            label = "联想候选 " .. tostring(index) .. selected_label .. "，共 "
                .. tostring(#candidates) .. " 项：" .. candidate .. "，点击提交"
        else
            label = "普通候选 " .. tostring(index) .. selected_label .. "，共 "
                .. tostring(#candidates) .. " 项：" .. candidate .. "，点击提交"
        end
        items[index] = {
            text = tostring(index) .. "  " .. candidate,
            candidate_text = candidate,
            candidate_index = index,
            help_text = label,
        }
    end
    if selected_index and selected_index > 0 then
        items.current = selected_index
    end
    return items
end

function InputMethodCandidatePanel:init()
    self.item_table = makeItemTable(self.candidates, self.selected_index, self.metadata)
    self.itemnumber = self.selected_index and self.selected_index > 0
        and self.selected_index or nil
    Menu.init(self)
    self:_useCompactPageFooter()
end

function InputMethodCandidatePanel:_recalculateDimen(no_recalculate_dimen)
    local function calculateWithoutFooter()
        local page_return_arrow, page_info_text = self.page_return_arrow, self.page_info_text
        self.page_return_arrow, self.page_info_text = nil, nil
        Menu._recalculateDimen(self, no_recalculate_dimen)
        self.page_return_arrow, self.page_info_text = page_return_arrow, page_info_text
    end
    if self._candidate_footer_mode == nil then
        calculateWithoutFooter()
        self._candidate_footer_mode = self.page_num <= 1 and "hidden" or "shown"
        if self._candidate_footer_mode == "shown" then
            Menu._recalculateDimen(self, false)
        end
    elseif self._candidate_footer_mode == "hidden" then
        calculateWithoutFooter()
    else
        Menu._recalculateDimen(self, no_recalculate_dimen)
    end
end

function InputMethodCandidatePanel:_useCompactPageFooter()
    if self._compact_footer_ready then
        return
    end
    self._compact_footer_ready = true

    -- Menu normally offers first/previous/goto/next/last. Inside the keyboard
    -- region, previous/page/next is easier to scan and matches the compact bar.
    for index = #self.page_info, 1, -1 do
        table.remove(self.page_info, index)
    end
    self.page_info[#self.page_info + 1] = self.page_info_left_chev
    self.page_info[#self.page_info + 1] = HorizontalSpan:new{
        width = Size.span.horizontal_default,
    }
    self.page_info[#self.page_info + 1] = self.page_info_text
    self.page_info[#self.page_info + 1] = HorizontalSpan:new{
        width = Size.span.horizontal_default,
    }
    self.page_info[#self.page_info + 1] = self.page_info_right_chev
    self.page_info:resetLayout()

    self.page_info_text.hold_input = nil
    self.page_info_text.tap_input = nil
    self.page_info_text:disableWithoutDimming()
end

function InputMethodCandidatePanel:updatePageInfo(select_number)
    Menu.updatePageInfo(self, select_number)
    self.page_info_first_chev:hide()
    self.page_info_last_chev:hide()
    if self.page_num <= 1 then
        self.page_info_left_chev:hide()
        self.page_info_right_chev:hide()
        self.page_info_text:setText("")
        self.page_info_text.accessibility_label = nil
    else
        self.page_info_left_chev:show()
        self.page_info_right_chev:show()
        self.page_info_text:setText(tostring(self.page) .. " / " .. tostring(self.page_num))
        self.page_info_text.accessibility_label = "第 " .. tostring(self.page)
            .. " 页，共 " .. tostring(self.page_num) .. " 页"
        self.page_info_text.help_text = self.page_info_text.accessibility_label
        self.page_info_text:disableWithoutDimming()
    end
    self.page_info:resetLayout()
end

function InputMethodCandidatePanel:updateItems(select_number, no_recalculate_dimen)
    Menu.updateItems(self, select_number, no_recalculate_dimen)
    for _, item_widget in ipairs(self.item_group) do
        if item_widget.entry and item_widget.entry.help_text then
            item_widget.accessibility_label = item_widget.entry.help_text
            item_widget.help_text = item_widget.entry.help_text
            item_widget[1].inner_bordersize =
                item_widget.entry.candidate_index == self.selected_index
                and Size.line.thick or 0
        end
    end
end

function InputMethodCandidatePanel:updateCandidates(candidates, selected_index, metadata)
    self.candidates = candidates or {}
    self.selected_index = selected_index or 0
    self.metadata = metadata or {}
    self._candidate_footer_mode = nil
    local items = makeItemTable(self.candidates, self.selected_index, self.metadata)
    -- Flexible-height pages depend on the new item measurements, so recalculate
    -- them first and only then resolve the absolute selection to a page.
    self:switchItemTable(nil, items)
    if self.selected_index > 0 then
        self:onGotoPage(self:getPageNumber(self.selected_index))
    end
end

function InputMethodCandidatePanel:onMenuChoice(item)
    if item and item.candidate_index and self.on_candidate then
        self.on_candidate(item.candidate_index)
    end
    return true
end

function InputMethodCandidatePanel:onClose()
    if self.on_close then
        self.on_close()
    end
    return true
end

function InputMethodCandidatePanel:onCloseAllMenus()
    return self:onClose()
end

return InputMethodCandidatePanel
