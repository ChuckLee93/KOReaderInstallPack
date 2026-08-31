-- sui_book_hold_dialog.lua — Simple UI
--
-- Shared "book actions" dialog for any module that shows book covers
-- (Coverdeck, Currently Reading, TBR, Recent, New Books, Collections,
-- Featured Collection, ...). It mirrors the ButtonDialog that KOReader's
-- own FileManager opens on long-press of a file
-- (apps/filemanager/filemanager.lua → file_chooser:showFileDialog), but:
--
--   • only ever deals with a single BOOK file (never folders), so every
--     row that only makes sense for folders or for multi-file management
--     is dropped: Paste, Select, Rename, Delete, Cut, Copy, "Set as HOME
--     folder", folder shortcuts;
--   • is a stand-alone widget, not tied to a FileChooser/file_dialog
--     instance, so it takes plain callbacks (on_close / refresh) instead
--     of closing over `self.file_dialog` and `fc:refreshPath()`.
--
-- Everything else (status row, reset, add to collection, convert, export
-- highlights, bookmark browser, book information/cover/description, and
-- any row registered by other code via FileManager:addFileDialogButtons,
-- e.g. sui_tbr's "Add to To Be Read") is reused as-is from KOReader/
-- SimpleUI, so behaviour and translations stay in sync with the FM
-- dialog automatically.
--
-- Public API
-- ----------
--   BookHoldDialog.show(file, opts)
--     file              -- absolute path to the book file (required)
--     opts.on_close      function?  -- called after the dialog is closed
--                                       (any reason: button pressed or
--                                       backdrop tap)
--     opts.refresh_fn     function?  -- called after an action that may
--                                       have changed book state (status,
--                                       reset, collections, ...). Callers
--                                       typically pass their own module
--                                       refresh/repaint here — there is no
--                                       FileChooser to refresh outside FM.
--     opts.navigate_fn     function?  -- called (instead of refresh_fn)
--                                       after a row registered under an id
--                                       listed in opts.navigate_row_ids —
--                                       i.e. one that navigates elsewhere in
--                                       FileManager rather than just
--                                       changing state. FM.instance may
--                                       exist without being the visible
--                                       widget (e.g. this dialog opened from
--                                       a screen drawn on top of it), so the
--                                       navigation needs help becoming
--                                       visible — callers typically pass
--                                       whatever closes/dismisses their own
--                                       screen here.
--     opts.navigate_row_ids table?    -- { [row_id] = true }, matching the
--                                       id each row_func was registered
--                                       under via FileManager:
--                                       addFileDialogButtons(row_id, ...).
--                                       Rows not listed use refresh_fn as
--                                       normal.
--     opts.title          string?    -- defaults to the book's title (from
--                                       metadata, via module_books_shared's
--                                       SH.getBookData), falling back to the
--                                       filename when no metadata is available.
--     opts.extra_rows      function? (file) -> { row, ... }
--                                       -- caller-specific rows appended
--                                       at the end (e.g. "Remove from this
--                                       list"), same {button,button} row
--                                       format as ButtonDialog.
--     opts.open_settings_fn function?  -- when given, an extra "Open module
--                                       settings" row is appended that
--                                       closes this dialog and calls it.
--                                       Lets callers wire this back to
--                                       whatever opens the module's own
--                                       settings screen (see
--                                       sui_homescreen.lua's
--                                       _openModuleSettingsFor). The label is
--                                       always the fixed "Open module
--                                       settings" string, regardless of which
--                                       module the hold originated from.
--     opts.reveal_fn      function?  -- called after a row that hands off to
--                                       a native FM sub-screen (Collections,
--                                       Book information) finishes and closes
--                                       that sub-screen. Those sub-screens are
--                                       shown by KOReader's own code, on top
--                                       of whatever is currently topmost —
--                                       normally that's the caller's screen
--                                       (e.g. the homescreen), so closing them
--                                       should already reveal it again, but in
--                                       practice the caller's screen can end
--                                       up buried under FileManager instead.
--                                       opts.reveal_fn lets the caller force
--                                       itself back on top when that happens
--                                       (e.g. closing and re-showing itself).
--                                       Best-effort: only wired up when the
--                                       relevant sub-screen's widget can
--                                       actually be found, so this degrades
--                                       gracefully to the native behaviour
--                                       when it can't.
--
--   Returns the ButtonDialog instance (already shown).
-- ---------------------------------------------------------------------------

local UIManager        = require("ui/uimanager")
local ButtonDialog      = require("ui/widget/buttondialog")
local BD                = require("ui/bidi")
local DocumentRegistry   = require("document/documentregistry")
local BookList           = require("ui/widget/booklist")
local filemanagerutil    = require("apps/filemanager/filemanagerutil")
local SH                 = require("modules/module_books_shared")
local _ = require("infra/sui_i18n").translate

local M = {}

-- Row ids (as registered via FileManager:addFileDialogButtons) that this
-- dialog deliberately omits, even though they'd otherwise be picked up by
-- the generic "rows registered by other code" loop below. "coverbrowser_1"
-- is CoverBrowser's own "Ignore cover" / "Ignore metadata" row
-- (plugins/coverbrowser.koplugin/main.lua) — a per-book cover-display
-- override that doesn't apply to this dialog's homescreen cover modules,
-- so it's dropped here rather than in coverbrowser.koplugin itself.
--
-- "coverbrowser_2" ("Refresh cached book information") is NOT listed here:
-- it's handled specially in the loop below, where "Delete" is substituted
-- in its place instead of simply being dropped. See DELETE_ROW_ID.
local EXCLUDED_ROW_IDS = {
    coverbrowser_1 = true,
}

-- The native row id that "Delete" replaces in-place. Kept as a named
-- constant since it's checked in two places below (the substitution itself,
-- and the end-of-function fallback for when that row never showed up).
local DELETE_ROW_ID = "coverbrowser_2"

-- Best-effort access to the running FileManager instance. On SimpleUI's
-- homescreen this is normally available (the homescreen is drawn inside
-- FileManager's own screen), but callers may invoke this dialog from
-- contexts where it isn't — every use below is guarded, so the dialog
-- degrades gracefully (those rows are simply omitted) rather than erroring.
local function _getFileManager()
    local ok, FM = pcall(require, "apps/filemanager/filemanager")
    if ok and FM and FM.instance then return FM.instance end
    return nil
end

-- Builds the "Delete" row. Reuses FileManager:showDeleteFileDialog/
-- deleteFile as-is (same confirmation copy, same sdr/ReadHistory/
-- ReadCollection cleanup as the native FM long-press dialog) instead of
-- reimplementing file deletion here — neither method touches
-- file_manager.file_dialog or anything else FM-instance-shaped, so it's
-- safe to call from this stand-alone dialog. Only ever called when a live
-- FileManager instance is available, since that's where those methods live.
local function _buildDeleteRow(file, file_manager, dialog, refresh_callback)
    return {
        {
            text     = _("Delete"),
            callback = function()
                UIManager:close(dialog)
                file_manager:showDeleteFileDialog(file, refresh_callback)
            end,
        },
    }
end

-- Keeps the Homescreen alive (merely covered, never closed) for whichever
-- fullscreen widget the very next UIManager:show() call displays.
--
-- Without this, opening "Collections…" or "Book information" from here lets
-- SimpleUI's UIManager.show patch run its normal rule: force-close any
-- "homescreen"-named widget the moment a different fullscreen widget appears
-- on top of it (see infra/sui_patches.lua, patchUIManagerShow — the rule
-- exists for the general case of a module opening a real sub-screen). When
-- the native Collections/Book-info screen later closes on its own, UIManager
-- reveals whatever is genuinely left underneath in the window stack — with
-- the Homescreen already closed, that is the bare FileManager, not us —
-- producing a visible flash of the FM before opts.reveal_fn/refresh_fn puts
-- the Homescreen back on top a moment later (two full-screen e-ink refreshes
-- back to back). Tagging the widget with _sui_keep_homescreen — an existing,
-- already-supported escape hatch in that same patch — skips the force-close
-- instead, so the Homescreen stays alive underneath the whole time. Its own
-- native close then reveals the Homescreen directly, in one clean refresh,
-- with nothing in between left to flash.
--
-- One-shot: wraps UIManager.show only long enough to tag the single widget
-- the very next call shows, then restores the previous (already-patched)
-- UIManager.show so nothing else is affected. Also self-restores on the next
-- tick regardless, in case the caller's action fails, or turns out not to
-- call UIManager:show at all (e.g. a disabled button) — so the interception
-- can never leak onto some later, unrelated widget.
local function _keepHomescreenAliveForNextShow()
    local prev_show = UIManager.show
    local restored = false
    local function restore()
        if not restored then
            restored = true
            UIManager.show = prev_show
        end
    end
    UIManager.show = function(um_self, widget, ...)
        restore()
        if widget then widget._sui_keep_homescreen = true end
        return prev_show(um_self, widget, ...)
    end
    UIManager:nextTick(restore)
end

function M.show(file, opts)
    opts = opts or {}
    local dialog

    local function close_dialog_callback()
        UIManager:close(dialog)
    end
    local function refresh_callback()
        if opts.refresh_fn then opts.refresh_fn() end
    end
    local function close_dialog_refresh_callback()
        UIManager:close(dialog)
        if opts.refresh_fn then opts.refresh_fn() end
    end

    local file_manager   = _getFileManager()
    local has_provider    = DocumentRegistry:hasProvider(file)
    local been_opened      = BookList.hasBookBeenOpened(file)
    local doc_settings_or_file = file
    local book_props

    local buttons = {}
    -- Set true once "Delete" has been inserted in place of DELETE_ROW_ID
    -- (see the file_dialog_added_buttons loop below). Guards the fallback
    -- placement further down so Delete never appears twice, and is still
    -- offered even when DELETE_ROW_ID never showed up (e.g. CoverBrowser
    -- disabled).
    local delete_row_inserted = false

    if has_provider or been_opened then
        if been_opened then
            doc_settings_or_file = BookList.getDocSettings(file)
        end
        book_props = file_manager and file_manager.coverbrowser
            and file_manager.coverbrowser:getBookInfo(file)
        if been_opened and not book_props then
            local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
            local props = doc_settings_or_file:readSetting("doc_props")
            book_props = FileManagerBookInfo.extendProps(props, file)
            book_props.has_cover = true -- "Book cover" enabled; existence unknown here
        end

        buttons[#buttons + 1] = filemanagerutil.genStatusButtonsRow(doc_settings_or_file, close_dialog_refresh_callback)
        -- No manual separator here: ButtonTable already inserts one between
        -- every pair of rows in `buttons` (ButtonTable:addVerticalSeparator,
        -- called whenever i < row_cnt). Adding our own `{}` row on top of
        -- that produced an empty row sandwiched between two automatic
        -- separators — i.e. a visible double line.
        local collections_btn = file_manager and file_manager.collections
            and file_manager.collections:genAddToCollectionButton(file, close_dialog_callback, refresh_callback)
            or nil
        -- "Collections…" opens a native FM sub-screen (FileManagerCollection's
        -- checkmark list) on top of whatever is currently shown. That should
        -- already reveal the caller's screen (e.g. the homescreen) once
        -- closed, but in practice it can resurface FileManager's native
        -- browser instead — so, when the caller gave us opts.reveal_fn, hook
        -- into the list widget's own close_callback (grabbed right after the
        -- native code creates and shows it) to force the caller back on top.
        -- Best-effort: if the internal field ever changes name upstream,
        -- this silently degrades to the native behaviour instead of erroring.
        if collections_btn and opts.reveal_fn then
            local orig_callback = collections_btn.callback
            -- Hook close_callback on coll_list, chaining onto any replacement
            -- instance instead of firing reveal_fn on the first close.
            --
            -- The native collections screen can close-and-recreate its own
            -- coll_list Menu internally (e.g. moving between the checklist
            -- and a specific collection's book list) without the user ever
            -- being "done". A one-shot hook fires on that internal close too,
            -- calling reveal_fn() early: it closes/reopens the Homescreen on
            -- top of the freshly-created replacement coll_list, which is left
            -- behind, un-closed, in the window stack — invisible until the
            -- FM is later revealed. Deferring the check to the next tick lets
            -- us see whether file_manager.collections.coll_list now points
            -- at a different (replacement) widget: if so, this was an
            -- internal transition — re-hook onto the new instance instead of
            -- revealing the caller.
            --
            -- A third case also has to be handled: Menu:onMenuSelect (ui/
            -- widget/menu.lua) calls close_callback() after *every* leaf-item
            -- tap, not just on an actual close — including each tap on a
            -- collection checkbox while multi-selecting. FileManagerCollection's
            -- own close_callback already no-ops that case (it only closes when
            -- force_close is set or selected_collections is nil), leaving
            -- file_manager.collections.coll_list pointing at the very same,
            -- still-open widget. Without checking for that, every checkbox tap
            -- looked identical to "no replacement created" and revealed the
            -- caller mid-selection, burying the still-open coll_list. So a
            -- close is only treated as the user finishing when the native
            -- code actually dropped the reference (new_coll_list is nil); the
            -- same-instance case is a no-op we simply ignore and keep waiting
            -- on this same hook.
            local function hookCollListClose(coll_list)
                if not coll_list then return end
                local orig_close = coll_list.close_callback
                coll_list.close_callback = function(...)
                    if orig_close then orig_close(...) end
                    UIManager:nextTick(function()
                        local new_coll_list = file_manager.collections
                            and file_manager.collections.coll_list
                        if new_coll_list == coll_list then
                            -- Native guard no-op'd (e.g. a checkbox tap while
                            -- multi-selecting) — still open, nothing to do.
                            return
                        end
                        if new_coll_list then
                            hookCollListClose(new_coll_list)
                            return
                        end
                        -- The Homescreen was kept alive underneath (see
                        -- _keepHomescreenAliveForNextShow below) and has
                        -- just been naturally revealed by the native close
                        -- above — it only needs its content refreshed to
                        -- reflect any collection change, not a full
                        -- close+rebuild. Fall back to reveal_fn for safety
                        -- if the caller didn't give us a refresh_fn.
                        if opts.refresh_fn then
                            opts.refresh_fn()
                        else
                            opts.reveal_fn()
                        end
                    end)
                end
            end
            collections_btn.callback = function(...)
                _keepHomescreenAliveForNextShow()
                orig_callback(...)
                hookCollListClose(file_manager.collections.coll_list)
            end
        end
        buttons[#buttons + 1] = {
            filemanagerutil.genResetSettingsButton(doc_settings_or_file, close_dialog_refresh_callback),
            collections_btn,
        }
    end

    local ok_conv, FileManagerConverter = pcall(require, "apps/filemanager/filemanagerconverter")
    if ok_conv and FileManagerConverter and FileManagerConverter:isSupported(file) then
        buttons[#buttons + 1] = {
            FileManagerConverter:genConvertButton(file, close_dialog_callback, refresh_callback),
        }
    end

    if been_opened then
        local annotations = doc_settings_or_file:readSetting("annotations")
        if annotations and #annotations > 0 and file_manager and file_manager.collections then
            buttons[#buttons + 1] = {
                file_manager.collections:genExportHighlightsButton({ [file] = true }, close_dialog_callback),
                file_manager.collections:genBookmarkBrowserButton({ [file] = true }, close_dialog_callback),
            }
        end
    end

    local book_info_btn = filemanagerutil.genBookInformationButton(doc_settings_or_file, book_props, close_dialog_callback)
    -- "Book information" shows a native FM/ReaderUI KeyValuePage on top of
    -- whatever is currently shown, same reveal concern as "Collections…"
    -- above — hook opts.reveal_fn onto the kvp_widget's own close_callback,
    -- grabbed right after ui.bookinfo:show() creates and shows it.
    if book_info_btn and opts.reveal_fn then
        local orig_callback = book_info_btn.callback
        book_info_btn.callback = function(...)
            _keepHomescreenAliveForNextShow()
            orig_callback(...)
            local ok_ui, ui = pcall(function()
                return require("apps/reader/readerui").instance or require("apps/filemanager/filemanager").instance
            end)
            local kvp = ok_ui and ui and ui.bookinfo and ui.bookinfo.kvp_widget
            if kvp then
                local orig_close = kvp.close_callback
                kvp.close_callback = function(...)
                    if orig_close then orig_close(...) end
                    -- Same reasoning as the Collections hook above: the
                    -- Homescreen was kept alive and just got naturally
                    -- revealed by this close, so a refresh is enough.
                    if opts.refresh_fn then
                        opts.refresh_fn()
                    else
                        opts.reveal_fn()
                    end
                end
            end
        end
    end
    buttons[#buttons + 1] = {
        {
            text = _("Open with…"),
            enabled = has_provider,
            callback = function()
                UIManager:close(dialog)
                local fm = file_manager or _getFileManager()
                if fm then fm:showOpenWithDialog(file) end
            end,
        },
        book_info_btn,
    }
    if has_provider then
        buttons[#buttons + 1] = {
            filemanagerutil.genBookCoverButton(file, book_props, close_dialog_callback),
            filemanagerutil.genBookDescriptionButton(file, book_props, close_dialog_callback),
        }
    end

    -- Rows registered by other SimpleUI code (or third-party plugins) via
    -- FileManager:addFileDialogButtons — e.g. sui_tbr's "Add to To Be Read"
    -- or sui_library_browse's "More by <Author>". Keeps this dialog in sync
    -- with whatever the real FM dialog shows, without duplicating that
    -- registration logic here.
    --
    -- Passing a 4th arg (close_cb) is what makes these rows actually work
    -- here: row_funcs registered via FM.instance:addFileDialogButtons only
    -- take (file, is_file, book_props) from the *native* FM dialog, and
    -- their default close/refresh behaviour is hardcoded to close
    -- FM.instance.file_chooser.file_dialog — which isn't the dialog we're
    -- showing, so tapping them looked like nothing happened. main.lua's
    -- sui_tbr / sui_browse_author / sui_book_stats registrations now accept
    -- this optional close_cb (falling back to the old FM-specific behaviour
    -- when called from the real FM dialog, where close_cb is nil), so we
    -- supply our own here.
    --
    -- Two kinds of rows need two different close_cbs:
    --   • State-changing (TBR toggle, status, ...): just close this dialog
    --     and refresh the caller in place (opts.refresh_fn).
    --   • Navigating (e.g. "More by <Author>", which repaints FM.instance.
    --     file_chooser to a virtual author leaf): FM.instance may exist but
    --     not be the visible widget — the caller's own screen (homescreen)
    --     is still on top of it, so the navigation happens invisibly
    --     "underneath". These need opts.navigate_fn, which the caller wires
    --     to whatever actually reveals that navigation (e.g. closing the
    --     homescreen so the just-updated FM becomes visible). Which rows
    --     need this is caller knowledge, passed via opts.navigate_row_ids
    --     = { [row_id] = true }, matched against the id each row_func was
    --     registered under (FileManager:addFileDialogButtons(id, ...)).
    if file_manager and file_manager.file_dialog_added_buttons ~= nil then
        local function close_and_refresh()
            close_dialog_callback()
            if opts.refresh_fn then opts.refresh_fn() end
        end
        local function close_and_navigate()
            close_dialog_callback()
            if opts.navigate_fn then
                opts.navigate_fn()
            elseif opts.refresh_fn then
                opts.refresh_fn()
            end
        end
        -- FileManager:addFileDialogButtons stores an `index` table mapping
        -- row_id -> position in the array part; invert it so each row_func
        -- (only reachable by position via ipairs) can be matched back to
        -- the id it was registered under.
        local id_by_pos = {}
        local reg_index = file_manager.file_dialog_added_buttons.index
        if reg_index then
            for row_id, pos in pairs(reg_index) do id_by_pos[pos] = row_id end
        end
        for i, row_func in ipairs(file_manager.file_dialog_added_buttons) do
            local row_id = id_by_pos[i]
            if row_id == DELETE_ROW_ID then
                -- Substitute "Delete" for the native "Refresh cached book
                -- information" row, in the exact position that row would
                -- have occupied, instead of appending Delete at the end of
                -- the dialog. row_func is deliberately never called here —
                -- its own callback (plugins/coverbrowser.koplugin/main.lua)
                -- purges BookInfoManager's cache and then unconditionally
                -- reaches for the *real* FileManager's file_dialog to close/
                -- repaint, which is normally nil outside the real FM (e.g.
                -- held from the Homescreen here) — not something we need to
                -- preserve since the row itself is being replaced wholesale.
                buttons[#buttons + 1] = _buildDeleteRow(file, file_manager, dialog, refresh_callback)
                delete_row_inserted = true
            elseif not (row_id and EXCLUDED_ROW_IDS[row_id]) then
                local is_nav   = opts.navigate_row_ids and row_id and opts.navigate_row_ids[row_id]
                local close_cb = is_nav and close_and_navigate or close_and_refresh
                local ok_row, row = pcall(row_func, file, true, book_props, close_cb)
                if ok_row and row ~= nil then
                    buttons[#buttons + 1] = row
                end
            end
        end
    end

    if opts.extra_rows then
        local ok_extra, extra = pcall(opts.extra_rows, file)
        if ok_extra and extra then
            for _, row in ipairs(extra) do
                buttons[#buttons + 1] = row
            end
        end
    end

    -- Fallback placement for "Delete": normally already inserted above, in
    -- place of DELETE_ROW_ID ("Refresh cached book information"). This only
    -- fires when that row never showed up in the first place — e.g.
    -- CoverBrowser is disabled, or `file_manager` was nil so the whole
    -- file_dialog_added_buttons loop was skipped — so the action is still
    -- reachable rather than silently missing. Degrades to "row omitted"
    -- when no FileManager instance is available at all, same as the other
    -- FM-backed rows above.
    if file_manager and not delete_row_inserted then
        buttons[#buttons + 1] = _buildDeleteRow(file, file_manager, dialog, refresh_callback)
    end

    -- "Open module settings" — lets the person reach the module's own
    -- settings screen from inside the book dialog, since choosing
    -- "book_dialog" as the long-press action (Config.getCoverHoldMode)
    -- otherwise means module settings are no longer one hold away. Only
    -- shown when the caller supplied a way to open them (sui_homescreen.lua
    -- passes this whenever the hold originated from a known module). Label
    -- is always this same fixed string — it deliberately does not adapt to
    -- which module the hold originated from.
    if opts.open_settings_fn then
        -- No manual separator here either — see the comment above the
        -- Reset/Collections row; ButtonTable already draws one between
        -- consecutive rows automatically.
        buttons[#buttons + 1] = {
            {
                text     = _("Open module settings"),
                callback = function()
                    UIManager:close(dialog)
                    opts.open_settings_fn()
                end,
            },
        }
    end

    -- Book title (from metadata) instead of the raw filename — same lookup
    -- (DocSettings doc_props, then BookInfoManager, then filename) used
    -- everywhere else in the plugin a book's title is shown (Currently
    -- Reading, book rows, ...), so the dialog title matches what the person
    -- already sees elsewhere for this book. pcall-guarded: a lookup failure
    -- (e.g. a corrupt sidecar) must never prevent the dialog itself from
    -- opening — falls back to the filename in that case.
    local default_title = BD.filename(file:match("([^/]+)$") or file)
    local ok_title, book_title = pcall(SH.getBookData, file)
    if ok_title and book_title and book_title.title and book_title.title ~= "" then
        default_title = book_title.title
    end

    dialog = ButtonDialog:new{
        title       = opts.title or default_title,
        title_align = "center",
        buttons     = buttons,
        dismissable = true,
    }
    -- ButtonDialog doesn't take an on_close, but every button above closes
    -- the dialog explicitly (via close_dialog_callback / close_dialog_
    -- refresh_callback), and dismissable=true lets the backdrop tap close
    -- it too. Wrap onCloseWidget so opts.on_close fires in both cases.
    if opts.on_close then
        local orig_onCloseWidget = dialog.onCloseWidget
        dialog.onCloseWidget = function(self)
            if orig_onCloseWidget then orig_onCloseWidget(self) end
            opts.on_close()
        end
    end

    UIManager:show(dialog)
    return dialog
end

return M
