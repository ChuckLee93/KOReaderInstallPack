-- sui_group_actions.lua — Simple UI
-- Shared "cover picker" and "create collection" dialogs for anything that
-- is conceptually a group of books the user can enter: a plain folder, an
-- in-folder series group, or a virtual author/series/tag leaf.
--
-- Previously each of those three had its own near-identical copy of this
-- UI (sui_foldercovers._openFolderCoverPicker / _openSeriesGroupCoverPicker,
-- sui_browsemeta._openVirtualCoverPicker, etc). Callers now just supply the
-- list of books and an override key; the dialog logic lives here once.
--
-- Public API
-- ----------
--   GroupActions.openCoverPicker(args)
--     args.title          -- dialog title, defaults to "Folder cover"
--     args.override_key   -- string key used with sui_cover_overrides
--     args.items          -- { {path=fullpath, title=display_title}, ... }
--     args.menu           -- the FileChooser/menu widget to invalidate after a change
--     args.empty_message  -- shown instead of the picker when items is empty
--
--   GroupActions.createCollection(args)
--     args.suggested_name -- pre-filled name (may be "")
--     args.paths          -- { fullpath, ... } of every book to add
--     args.empty_message  -- shown instead of the dialog when paths is empty

local _ = require("infra/sui_i18n").translate
local CoverOverrides = require("features/library/sui_cover_overrides")

local GroupActions = {}

function GroupActions.openCoverPicker(args)
    local UIManager    = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage  = require("ui/widget/infomessage")

    local items = args.items or {}
    if #items == 0 then
        UIManager:show(InfoMessage:new{
            text = args.empty_message or _("No books found."),
            timeout = 2,
        })
        return
    end

    local override_key = args.override_key
    local menu          = args.menu
    local cur_override  = CoverOverrides.get(override_key)

    local picker
    local buttons = {}

    buttons[#buttons + 1] = {{
        text = (not cur_override and "\u{2713} " or "  ") .. _("Auto (first book)"),
        callback = function()
            UIManager:close(picker)
            CoverOverrides.clear(override_key)
            CoverOverrides.invalidateGridItem(menu, override_key)
        end,
    }}

    for _, item in ipairs(items) do
        local fp    = item.path
        local title = (item.title and item.title ~= "") and item.title
            or (fp:match("([^/]+)%.[^%.]+$") or fp)
        buttons[#buttons + 1] = {{
            text = ((cur_override == fp) and "\u{2713} " or "  ") .. title,
            callback = function()
                UIManager:close(picker)
                CoverOverrides.set(override_key, fp)
                CoverOverrides.invalidateGridItem(menu, override_key)
            end,
        }}
    end

    buttons[#buttons + 1] = {{
        text = _("Cancel"),
        callback = function() UIManager:close(picker) end,
    }}

    picker = ButtonDialog:new{
        title = args.title or _("Folder cover"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(picker)
end

function GroupActions.createCollection(args)
    local UIManager   = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local InputDialog = require("ui/widget/inputdialog")
    local T           = require("ffi/util").template

    local paths = args.paths or {}
    if #paths == 0 then
        UIManager:show(InfoMessage:new{
            text = args.empty_message or _("No books found."),
            timeout = 2,
        })
        return
    end

    local RC = require("readcollection")
    local input_dialog
    input_dialog = InputDialog:new{
        title   = _("New collection name"),
        input   = args.suggested_name or "",
        buttons = {{
            {
                text = _("Cancel"),
                id   = "close",
                callback = function() UIManager:close(input_dialog) end,
            },
            {
                text = _("Create"),
                callback = function()
                    local name = input_dialog:getInputText()
                    if name == "" then return end
                    UIManager:close(input_dialog)

                    if RC.coll[name] then
                        UIManager:show(InfoMessage:new{
                            text = T(_("Collection already exists: %1"), name),
                        })
                        return
                    end

                    RC:addCollection(name)
                    local count = 0
                    for _, fp in ipairs(paths) do
                        if not RC.coll[name][fp] then
                            RC:addItem(fp, name)
                            count = count + 1
                        end
                    end
                    RC:write({ [name] = true })

                    UIManager:show(InfoMessage:new{
                        text    = T(_("Collection \"%1\" created with %2 books."), name, count),
                        timeout = 3,
                    })
                end,
            },
        }},
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

return GroupActions
