local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureBridge = require("miuread.gesture_bridge")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Screen = Device.screen

local MigrationProgress = InputContainer:extend{
    title="评论数据迁移",
    _miuread_transient=true,
    on_cancel=nil,
}

function MigrationProgress:handleEvent(event)
    return GestureBridge.handle(InputContainer, self, event)
end

function MigrationProgress:init()
    self.dimen = Screen:getSize()
    self.cancelled = false
    local frame_width = math.floor(Screen:getWidth() * 0.82)
    local frame_height = math.floor(Screen:getHeight() * 0.52)
    local content_width = frame_width - Size.padding.large * 2
    local content_height = frame_height - Size.padding.large * 2
    local group = VerticalGroup:new{align="center"}

    self.title_widget = TextBoxWidget:new{
        text=self.title, face=Font:getFace("ffont", 22), bold=true,
        width=content_width, height=math.floor(content_height * 0.16),
        height_adjust=false, height_overflow_show_ellipsis=true, alignment="center",
    }
    group[#group + 1] = self.title_widget
    group[#group + 1] = VerticalSpan:new{width=Size.padding.large}

    self.progress = ProgressWidget:new{
        width=content_width, height=Screen:scaleBySize(20), percentage=0,
        fillcolor=Blitbuffer.COLOR_BLACK, padding=Size.padding.small, margin=Size.margin.tiny,
    }
    group[#group + 1] = self.progress
    group[#group + 1] = VerticalSpan:new{width=Size.padding.small}

    self.percent_widget = TextBoxWidget:new{
        text="0%", face=Font:getFace("cfont", 19), width=content_width,
        height=math.floor(content_height * 0.08), height_adjust=false, alignment="center",
    }
    group[#group + 1] = self.percent_widget
    group[#group + 1] = VerticalSpan:new{width=Size.padding.large}

    self.status_widget = TextBoxWidget:new{
        text="正在准备迁移……", face=Font:getFace("cfont", 18), width=content_width,
        height=math.floor(content_height * 0.42), height_adjust=false,
        height_overflow_show_ellipsis=true, alignment="center",
    }
    group[#group + 1] = self.status_widget
    group[#group + 1] = VerticalSpan:new{width=Size.padding.large}

    self.buttons = ButtonTable:new{
        width=content_width, show_parent=self, zero_sep=true,
        buttons={{{text="停止迁移", callback=function()
            if self.cancelled then return end
            self.cancelled=true
            self.status_widget:setText("正在安全停止……")
            self:_redraw()
            if self.on_cancel then self.on_cancel() end
        end}}},
    }
    group[#group + 1] = self.buttons

    local fixed_area = CenterContainer:new{
        dimen=Geom:new{x=0, y=0, w=content_width, h=content_height}, group,
    }
    self.frame = FrameContainer:new{
        background=Blitbuffer.COLOR_WHITE, bordersize=Size.border.window,
        radius=Size.radius.window, padding=Size.padding.large, fixed_area,
    }
    self[1] = CenterContainer:new{dimen=self.dimen, self.frame}
end

function MigrationProgress:_redraw()
    local target = (self.frame and self.frame.dimen) or self.dimen
    UIManager:setDirty(self, function() return "fast", target end)
end

function MigrationProgress:set_state(state)
    state = state or {}
    local current = tonumber(state.current) or 0
    local total = tonumber(state.total) or 0
    local percent = tonumber(state.percent) or (total > 0 and current / total or 0)
    if percent > 1 then percent = percent / 100 end
    percent = math.max(0, math.min(1, percent))
    local rows = {}
    if total > 0 then rows[#rows + 1] = "章节 " .. tostring(current) .. " / " .. tostring(total) end
    if tostring(state.chapter or "") ~= "" then rows[#rows + 1] = "当前：" .. tostring(state.chapter) end
    rows[#rows + 1] = "已迁移想法组 " .. tostring(state.groups or 0)
        .. "　评论 " .. tostring(state.comments or 0) .. " 条"
    local percent_text = tostring(math.floor(percent * 100 + .5)) .. "%"
    local status_text = table.concat(rows, "\n")
    local signature = percent_text .. "\n" .. status_text
    if signature == self._last_signature then return end
    self._last_signature = signature
    self.progress:setPercentage(percent)
    self.percent_widget:setText(percent_text)
    self.status_widget:setText(status_text)
    self:_redraw()
end

function MigrationProgress:show() UIManager:show(self, "ui") end
function MigrationProgress:close() UIManager:close(self, "ui") end

return MigrationProgress
