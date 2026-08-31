-- sui_onboarding.lua — Simple UI
-- Onboarding window shown on first run.

local Device          = require("device")
local Geom            = require("ui/geometry")
local UIManager       = require("ui/uimanager")
local _               = require("sui_i18n").translate
local Font            = require("ui/font")
local Blitbuffer      = require("ffi/blitbuffer")
local TextWidget      = require("ui/widget/textwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local LineWidget      = require("ui/widget/linewidget")
local ImageWidget     = require("ui/widget/imagewidget")

local SUI         = require("sui_window")
local SUIStyle    = require("sui_style")
local SUISettings = require("sui_store")
local SUIPresets  = require("sui_presets")
local Config      = require("sui_config")

-- Landscape-aware scaling for this file's screens comes from ctx.SZ(n),
-- handed to every screen builder by SUIWindow itself (single source of
-- truth, see sui_window.lua) — no local wrapper needed here anymore.
local Screen      = Device.screen

local Onboarding = {}

function Onboarding.show(on_finish)
    local st = {
        selected_preset = SUISettings:get("simpleui_hs_active_preset") or "builtin_at_a_glance"
    }

    local win

    -- ---------------------------------------------------------------------------
    -- Screen 1: Welcome header + subtitle only
    -- ---------------------------------------------------------------------------
    local function buildWelcomeHeader(ctx)
        local iw = ctx.inner_w
        local rows = {}

        table.insert(rows, VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(30)) })
        table.insert(rows, FrameContainer:new{
            bordersize = 0, padding = 0,
            padding_left = ctx.SZ(Screen:scaleBySize(20)), padding_right = ctx.SZ(Screen:scaleBySize(20)),
            VerticalGroup:new{
                align = "left",
                TextWidget:new{
                    text    = _("Choose your initial layout"),
                    face    = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_TITLE)),
                    bold    = true,
                    fgcolor = SUIStyle.getThemeColor("fg") or Blitbuffer.COLOR_BLACK,
                },
                VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(4)) },
                TextBoxWidget:new{
                    text      = _("Start with a ready-made layout. You can change everything later."),
                    face      = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_BODY)),
                    width     = iw - ctx.SZ(Screen:scaleBySize(40)),
                    alignment = "left",
                    fgcolor   = SUIStyle.getThemeColor("text_secondary") or Blitbuffer.COLOR_DARK_GRAY,
                },
            },
        })

        return rows
    end

    -- ---------------------------------------------------------------------------
    -- Screen 2: Preset list
    -- ---------------------------------------------------------------------------
    local function buildPresetList(ctx)
        local iw = ctx.inner_w
        local rows = {}
        local builtins = SUIPresets.getBuiltinPresets and SUIPresets.getBuiltinPresets() or {}

        table.insert(rows, VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(30)) })

        local preset_rows_args = { align = "left" }
        for _, bp in ipairs(builtins) do
            table.insert(preset_rows_args, SUI.ListRow{
                title    = bp.name,
                subtitle = bp.desc,
                inner_w  = iw - ctx.SZ(Screen:scaleBySize(40)),
                radio    = true,
                checked  = (st.selected_preset == bp.id),
                on_tap   = function()
                    st.selected_preset = bp.id
                    if SUIPresets.applyBuiltin then SUIPresets.applyBuiltin(st.selected_preset) end
                    SUISettings:set("simpleui_hs_active_preset", st.selected_preset)
                    local ok, HS = pcall(require, "sui_homescreen")
                    if ok and HS and HS.rebuildLayout then HS.rebuildLayout() end
                    ctx.repaint()
                end,
            })
        end
        table.insert(rows, FrameContainer:new{
            bordersize    = 0, padding = 0,
            padding_left  = ctx.SZ(Screen:scaleBySize(20)),
            padding_right = ctx.SZ(Screen:scaleBySize(20)),
            VerticalGroup:new(preset_rows_args),
        })

        return rows
    end

    -- ---------------------------------------------------------------------------
    -- Screen 3: Tips header + subtitle only
    -- ---------------------------------------------------------------------------
    local function buildTipsHeader(ctx)
        local iw = ctx.inner_w
        local rows = {}

        table.insert(rows, VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(30)) })
        table.insert(rows, FrameContainer:new{
            bordersize = 0, padding = 0,
            padding_left = ctx.SZ(Screen:scaleBySize(20)), padding_right = ctx.SZ(Screen:scaleBySize(20)),
            VerticalGroup:new{
                align = "left",
                TextWidget:new{
                    text    = _("Make it yours"),
                    face    = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_TITLE)),
                    bold    = true,
                    fgcolor = SUIStyle.getThemeColor("fg") or Blitbuffer.COLOR_BLACK,
                },
                VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(4)) },
                TextBoxWidget:new{
                    text      = _("Simple UI is designed to be simple and flexible. Here are a few tips to get the most out of it."),
                    face      = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_BODY)),
                    width     = iw - ctx.SZ(Screen:scaleBySize(40)),
                    alignment = "left",
                    fgcolor   = SUIStyle.getThemeColor("text_secondary") or Blitbuffer.COLOR_DARK_GRAY,
                },
            },
        })

        return rows
    end

    -- ---------------------------------------------------------------------------
    -- Screen 4: Tips list — subtitle uses TextBoxWidget for full wrap (no truncation)
    -- Visual style mirrors ListRow: FS_BODY bold title, FS_CAPTION subtitle,
    -- with a LineWidget separator between items (not after the last one).
    -- ---------------------------------------------------------------------------
    local function buildTipsList(ctx)
        local iw      = ctx.inner_w
        local text_w  = iw - ctx.SZ(Screen:scaleBySize(40))
        local vpad    = ctx.SZ(Screen:scaleBySize(16))
        local rows    = {}

        table.insert(rows, VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(30)) })

        local tips = {
            {
                title = _("Long press to customize"),
                desc  = _("Press and hold any element on the screen (like modules or bars) to quickly customize its settings."),
            },
            {
                title = _("Customize even more"),
                desc  = _("Go to Settings > Home Screen to edit your layout whenever you want."),
            },
            {
                title = _("Set your reading goal"),
                desc  = _("If you selected the Momentum Preset, long press the Reading Goal module to choose and set your reading goals."),
            },
            {
                title = _("Custom wallpapers and icons"),
                desc  = _("Place your files in koreader/settings/simpleui/sui_wallpapers or sui_icons."),
            },
        }

        local Size      = require("ui/size")
        local fg        = SUIStyle.getThemeColor("fg")             or Blitbuffer.COLOR_BLACK
        local fg_sub    = SUIStyle.getThemeColor("text_secondary") or Blitbuffer.COLOR_DARK_GRAY
        local sep_color = SUIStyle.getThemeColor("separator")      or Blitbuffer.COLOR_LIGHT_GRAY

        local tip_vg = VerticalGroup:new{ align = "left" }

        for i, tip in ipairs(tips) do
            -- Tip content: bold title + wrapping subtitle
            local tip_content = FrameContainer:new{
                bordersize     = 0, padding = 0,
                padding_top    = vpad,
                padding_bottom = vpad,
                VerticalGroup:new{
                    align = "left",
                    TextWidget:new{
                        text    = tip.title,
                        face    = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_BODY)),
                        bold    = true,
                        fgcolor = fg,
                    },
                    VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(4)) },
                    TextBoxWidget:new{
                        text      = tip.desc,
                        face      = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_CAPTION)),
                        width     = text_w,
                        alignment = "left",
                        fgcolor   = fg_sub,
                    },
                },
            }
            table.insert(tip_vg, tip_content)

            -- Separator between items, not after the last one
            if i < #tips then
                table.insert(tip_vg, LineWidget:new{
                    dimen      = Geom:new{ w = text_w, h = Size.line.thin },
                    background = sep_color,
                })
            end
        end

        table.insert(rows, FrameContainer:new{
            bordersize    = 0, padding = 0,
            padding_left  = ctx.SZ(Screen:scaleBySize(20)),
            padding_right = ctx.SZ(Screen:scaleBySize(20)),
            tip_vg,
        })

        return rows
    end

    win = SUI:new{
        name          = "sui_win_onboarding",
        height        = math.floor(Screen:getHeight() * 0.75),
        screen_titles = {
            __root__    = _("Welcome to Simple UI"),
            presets     = _("Welcome to Simple UI"),
            tips_header = _("Quick Tips"),
            tips        = _("Quick Tips"),
        },
        screens = {
            __root__    = buildWelcomeHeader,
            presets     = buildPresetList,
            tips_header = buildTipsHeader,
            tips        = buildTipsList,
        },
        position = "bottom",
        on_close = function()
            SUISettings:set("simpleui_onboarding_done", true)
            G_reader_settings:saveSetting("start_with", "homescreen_simpleui")
            if on_finish then on_finish() end
        end,
        screen_footers = {
            __root__ = function(ctx)
                return SUI.CenteredButtonFooter(ctx, {
                    text   = _("Continue"),
                    on_tap = function() ctx.push("presets") end,
                })
            end,
            presets = function(ctx)
                return SUI.CenteredButtonFooter(ctx, {
                    text   = _("Continue"),
                    on_tap = function() ctx.push("tips_header") end,
                })
            end,
            tips_header = function(ctx)
                return SUI.CenteredButtonFooter(ctx, {
                    text   = _("Continue"),
                    on_tap = function() ctx.push("tips") end,
                })
            end,
            tips = function(ctx)
                return SUI.CenteredButtonFooter(ctx, {
                    text   = _("Start using Simple UI"),
                    on_tap = function()
                        if SUIPresets.applyBuiltin then SUIPresets.applyBuiltin(st.selected_preset) end
                        SUISettings:set("simpleui_hs_active_preset", st.selected_preset)
                        G_reader_settings:saveSetting("start_with", "homescreen_simpleui")
                        if win.close then win:close() else UIManager:close(win) end
                    end,
                })
            end,
        },
    }
    win:show()
end

return Onboarding
