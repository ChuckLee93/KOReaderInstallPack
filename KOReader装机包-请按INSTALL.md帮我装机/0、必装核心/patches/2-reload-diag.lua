--[[
    2-reload-diag.lua

    [ReloadDiag] diagnostic probe (same family as [RestartDiag]/[RestartDiag2]):
    log a WARN traceback whenever ReaderUI:reloadDocument() or
    ReaderUI:switchDocument() is invoked, so crash.log records WHO triggered
    the same-book reader rebuild (each rebuild freezes the UI ~5-7s).

    Read-only instrumentation: wraps the class methods, logs, then calls the
    original. No behavior change. Remove this file to uninstall.
--]]
pcall(function()
    local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok_rui or type(ReaderUI) ~= "table" then
        require("logger").warn("[ReloadDiag] failed:", "ReaderUI not loadable")
        return
    end
    if ReaderUI._reload_diag_applied then return end
    ReaderUI._reload_diag_applied = true

    local logger = require("logger")

    local orig_reload = ReaderUI.reloadDocument
    if type(orig_reload) == "function" then
        function ReaderUI:reloadDocument(after_close_callback, seamless, after_open_callback)
            pcall(function()
                logger.warn("[ReloadDiag] reloadDocument called; caller traceback:\n"
                    .. debug.traceback())
            end)
            return orig_reload(self, after_close_callback, seamless, after_open_callback)
        end
    end

    local orig_switch = ReaderUI.switchDocument
    if type(orig_switch) == "function" then
        function ReaderUI:switchDocument(path)
            pcall(function()
                logger.warn("[ReloadDiag] switchDocument called; path=", tostring(path),
                    "caller traceback:\n" .. debug.traceback())
            end)
            return orig_switch(self, path)
        end
    end

    logger.info("[ReloadDiag] probe installed (reloadDocument/switchDocument wrapped)")
end)
