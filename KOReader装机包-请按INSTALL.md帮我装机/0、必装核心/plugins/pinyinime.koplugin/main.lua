local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = source:match("^(.*)/main%.lua$") or "plugins/pinyinime.koplugin"

local ConfirmBox = require("ui/widget/confirmbox")
local ffiUtil = require("ffi/util")
local InfoMessage = require("ui/widget/infomessage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local REGISTRY_KEY = "pinyinime.runtime_registry.v1"

local function canonicalPluginRoot(path)
    local canonical = ffiUtil.realpath(path)
    if canonical then
        return canonical
    end
    if path:sub(1, 1) ~= "/" then
        return lfs.currentdir() .. "/" .. path
    end
    return path
end

local Registry = package.loaded[REGISTRY_KEY]
if type(Registry) ~= "table" then
    Registry = {}
    package.loaded[REGISTRY_KEY] = Registry
end

local canonical_root = canonicalPluginRoot(root)
local registry_entry = Registry[canonical_root]
if not registry_entry then
    registry_entry = {
        candidates = {},
        runtime = dofile(root .. "/lib/runtime.lua"),
    }
    Registry[canonical_root] = registry_entry
end
local Runtime = registry_entry.runtime
local candidate = {
    load_root = root,
}
table.insert(registry_entry.candidates, candidate)

local ChinesePinyin = WidgetContainer:extend{
    name = "pinyinime",
    is_doc_only = false,
}
candidate.module = ChinesePinyin

local function selectOwner()
    if registry_entry.owner then
        return registry_entry.owner
    end

    for _, item in ipairs(registry_entry.candidates) do
        if item.module.name == "pinyinime" then
            registry_entry.owner = item
            break
        end
    end
    if not registry_entry.owner then
        for _, item in ipairs(registry_entry.candidates) do
            local name = item.module.name
            if type(name) == "string"
                    and name:sub(-9) ~= ".koplugin" then
                registry_entry.owner = item
                break
            end
        end
    end
    registry_entry.owner = registry_entry.owner
        or registry_entry.candidates[1]

    if #registry_entry.candidates > 1
            and not registry_entry.duplicate_logged then
        local discoveries = {}
        for _, item in ipairs(registry_entry.candidates) do
            discoveries[#discoveries + 1] = string.format(
                "%s@%s", tostring(item.module.name), item.load_root)
        end
        logger.info(
            "PinyinIME: duplicate discovery of one physical plugin root; "
                .. "using a single runtime:",
            table.concat(discoveries, ", "),
            "canonical root:", canonical_root,
            "owner:", tostring(registry_entry.owner.module.name))
        registry_entry.duplicate_logged = true
    end
    return registry_entry.owner
end

local function isOwner()
    return selectOwner() == candidate
end

function ChinesePinyin:init()
    if not isOwner() then
        return
    end
    local supported = Runtime:install(root)
    local install_failure = Runtime:consumeInstallFailureNotice()
    self.settings_file = Runtime.settings and Runtime.settings.settings_file or nil
    local menu = self.ui and self.ui.menu
    if supported and menu and type(menu.registerToMainMenu) == "function" then
        menu:registerToMainMenu(self)
    end
    if not supported and install_failure then
        UIManager:show(InfoMessage:new{
            text = _("拼音输入法在本次会话中已停用。")
                .. "\n\n" .. install_failure,
        })
    end
end

function ChinesePinyin:addToMainMenu(menu_items)
    if not isOwner() then
        return
    end
    menu_items.chinese_pinyin = {
        text = _("拼音输入法"),
        sorting_hint = "keyboard_layout",
        sub_item_table = {
            Runtime:buildInputSchemeMenuItem(),
            Runtime:buildPersonalizationMenuItem(),
            Runtime:buildPredictionMenuItem(),
            {
                text = _("高级设置"),
                sub_item_table = {
                    Runtime:buildLexiconModeMenuItem(),
                },
            },
            {
                text = _("运行状态与诊断"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{ text = Runtime:getStatusText() })
                end,
            },
            {
                text = _("清除个性化数据"),
                help_text = _("清除候选排序、个人后续词关联和当前会话学习数据。"),
                enabled_func = function()
                    return Runtime:hasPersonalizationData()
                end,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("确定清除所有个性化数据吗？这将删除候选排序和后续词联想学习记录，且无法恢复。"),
                        ok_text = _("清除"),
                        ok_callback = function()
                            if Runtime:clearPersonalization() then
                                UIManager:show(InfoMessage:new{
                                    text = _("个性化数据已清除。"),
                                })
                            end
                        end,
                    })
                end,
            },
            {
                text = "版本：" .. Runtime.plugin_version,
                help_text = "当前安装的拼音输入法插件版本。",
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = "拼音输入法\n版本：" .. Runtime.plugin_version,
                    })
                end,
            },
        },
    }
end

function ChinesePinyin:stopPlugin()
    if isOwner() then
        Runtime:uninstall()
    end
end

function ChinesePinyin:onExit()
    if isOwner() then
        Runtime:uninstall()
    end
end

return ChinesePinyin
