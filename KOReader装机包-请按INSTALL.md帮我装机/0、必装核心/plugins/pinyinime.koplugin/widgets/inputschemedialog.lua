local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")

local InputSchemeDialog = ButtonDialog:extend{
    modal = true,
    stop_events_propagation = true,
}

function InputSchemeDialog:init()
    local current_scheme = self.get_current_scheme()
    self.buttons = {}
    for _, scheme in ipairs(self.schemes:list()) do
        local scheme_id = scheme.id
        self.buttons[#self.buttons + 1] = {
            {
                -- This dialog closes before applying a new scheme, so its
                -- selection marker only needs to reflect the opening state.
                -- Keeping it static is important: Button's checked_func path
                -- refreshes the button after its callback returns, which would
                -- repaint this already-closed row over the candidate bar.
                text = scheme.name
                    .. (current_scheme == scheme_id and Button.checkmark or ""),
                callback = function()
                    UIManager:close(self)
                    self.on_select(scheme_id)
                end,
            },
        }
    end
    self.title = "选择拼音方案"
    self.title_align = "center"
    self.rows_per_page = { 6, 5, 4 }
    ButtonDialog.init(self)
end

function InputSchemeDialog:onCloseWidget()
    if self.on_close then
        self.on_close(self)
    end
    ButtonDialog.onCloseWidget(self)
end

return InputSchemeDialog
