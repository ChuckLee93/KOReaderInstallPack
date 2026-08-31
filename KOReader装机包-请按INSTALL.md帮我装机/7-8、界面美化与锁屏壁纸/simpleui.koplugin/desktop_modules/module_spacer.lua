-- module_spacer.lua — Simple UI
-- Módulo: Spacer Row (instâncias dinâmicas).
-- Bloco de espaço em branco para dar espaçamento extra entre módulos.
-- Expõe M.instanciable = true e M.makeInstance(id) para o registry.
-- A única definição configurável é o tamanho (via SpinWidget, em percentagem),
-- seguindo a mesma mecânica dos restantes módulos.

local Device       = require("device")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen       = Device.screen
local _            = require("sui_i18n").translate

local Config      = require("sui_config")
local SUISettings = require("sui_store")

-- Altura base do spacer a 100% de escala.
local _BASE_SPACER_H = Screen:scaleBySize(50)

-- Limites de escala próprios do spacer — mais largos que o SCALE_MAX global (200).
local _SCALE_MIN  = 10
local _SCALE_MAX  = 400
local _SCALE_STEP = 10
local _SCALE_DEF  = 100

local function _scaleKey(mod_id, pfx)
    return (pfx or "simpleui_hs_") .. mod_id .. "_scale"
end

local function _clampSpacerScale(n)
    return math.max(_SCALE_MIN, math.min(_SCALE_MAX, math.floor(n)))
end

local function _getScalePct(mod_id, pfx)
    local v = SUISettings:get(_scaleKey(mod_id, pfx))
    local n = tonumber(v)
    if not n then return _SCALE_DEF end
    return _clampSpacerScale(n)
end

local function _getScale(mod_id, pfx)
    return _getScalePct(mod_id, pfx) / 100
end

local function _setScale(pct, mod_id, pfx)
    SUISettings:set(_scaleKey(mod_id, pfx), _clampSpacerScale(pct))
end

-- ---------------------------------------------------------------------------
-- Slot factory — cria um descriptor de módulo por instância
-- ---------------------------------------------------------------------------
local function makeInstance(inst_id)
    local slot_suffix = inst_id

    local S = {}
    S.id             = inst_id
    S.name           = _("Spacer")
    S.label          = nil
    S.default_on     = false
    S.no_top_margin  = true  -- suprime o item "Top Margin" no menu de settings

    function S.isEnabled(pfx)
        return SUISettings:readSetting(pfx .. slot_suffix .. "_enabled") == true
    end

    function S.setEnabled(pfx, on)
        SUISettings:saveSetting(pfx .. slot_suffix .. "_enabled", on)
    end

    function S.build(w, ctx)
        if not S.isEnabled(ctx.pfx) then return nil end
        local h = math.max(2, math.floor(_BASE_SPACER_H * _getScale(S.id, ctx.pfx)))
        -- VerticalSpan usa o campo `width` como altura — é a convenção do KOReader.
        return VerticalSpan:new{ width = h }
    end

    function S.getHeight(ctx)
        return math.max(2, math.floor(_BASE_SPACER_H * _getScale(S.id, ctx.pfx)))
    end

    function S.getMenuItems(ctx_menu)
        local pfx     = ctx_menu.pfx
        local refresh = ctx_menu.refresh
        local _lc     = ctx_menu._ or _

        return {
            Config.makeScaleItem({
                text_func     = function() return _lc("Spacer Size") end,
                title         = _lc("Spacer Size"),
                info          = _lc("Height of the spacer.\n100% is the default size."),
                get           = function() return _getScalePct(S.id, pfx) end,
                set           = function(v) _setScale(v, S.id, pfx) end,
                refresh       = refresh,
                value_min     = _SCALE_MIN,
                value_max     = _SCALE_MAX,
                value_step    = _SCALE_STEP,
                default_value = _SCALE_DEF,
            }),
        }
    end

    return S
end

-- ---------------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------------
local M = {}
M.id            = "spacer_row"
M.name          = _("Spacer")
M.instanciable  = true
M.makeInstance  = makeInstance
M.instances_key = "simpleui_spacer_row_instances"

return M
