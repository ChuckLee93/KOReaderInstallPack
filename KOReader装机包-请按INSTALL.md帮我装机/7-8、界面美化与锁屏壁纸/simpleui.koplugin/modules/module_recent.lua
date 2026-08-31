-- module_recent.lua — Simple UI
-- "Cover row" module for Recent Books, built on top of
-- GridRenderer.makeModule (engines/sui_book_grid.lua). Not instantiable.
--
-- Split from module_book_rows.lua (which held Recent Books + New Books + TBR
-- in a single file) — see moduleregistry.lua for the require_mod.

local _ = require("infra/sui_i18n").translate

local SUISettings  = require("infra/sui_store")
local GridRenderer = require("engines/sui_book_grid")

local recent_module = GridRenderer.makeModule{
    id          = "recent",
    name        = _("Recent Books"),
    label       = _("Recent Books"),
    default_on  = false,
    is_book_mod = true,   -- suppresses empty-state when active
    max_items   = 5,
    -- Lets the user pick 4 or 5 visible covers (see GridRenderer.makeModule's
    -- doc comment). ctx.recent_fps is prefetched with max_recent=15 (see
    -- sui_screen_engine.lua), well above either choice, so no change
    -- needed there.
    cols_choice = true,

    getFileList = function(ctx) return ctx.recent_fps end,

    -- Excludes finished books, unless "Show finished books" is
    -- enabled (module's own setting, independent from the recency logic
    -- that produced ctx.recent_fps).
    filterItem = function(fp, ctx)
        local pfx = ctx.pfx or ""
        if SUISettings:readSetting(pfx .. "recent_show_finished") == true then return true end
        local pd  = ctx.prefetched and ctx.prefetched[fp]
        local pct = pd and pd.percent or 0
        local is_done = (pct >= 1.0) or
                        (type(pd) == "table" and type(pd.summary) == "table"
                         and pd.summary.status == "complete")
        return not is_done
    end,

    progress_style = { default = "bar_text" },

    -- Off by default (unchanged look for existing users) — see
    -- GridRenderer.applyBadges' doc comment. All three available for the
    -- user to turn on, same as Flat Library/Featured Collection.
    badges = { pages = "off", series = "off", new = "off" },

    extra_settings = {
        { key = "show_finished", label = _("Show finished books"), default = false },
    },

    reset = function() GridRenderer.reset() end,
}

return recent_module
