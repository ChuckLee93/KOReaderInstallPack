--[[--
页脚品牌文案：按 koreader 设备标志识别品牌，型号可读时附具体型号。

标志/字段参照 koreader/frontend/device/*/device.lua：
  isKindle/isKobo/isPocketBook/isAndroid/isCervantes/isSonyPRSTUX/isRemarkable
  Device.model:Kindle_PaperWhite_5、Kobo_Libra2、reMarkable 2.0、PB515,
  Android 为 ro.product(常为 generic/sdk 等无意义值)。

@module koplugin.miuread.book_excerpt_card.device
--]]--

local Device = require("device")
local logger = require("logger")

local DEVICE_BRANDS = {
    isKindle = "Kindle",
    isKobo = "Kobo",
    isPocketBook = "PocketBook",
    isAndroid = "Android",
    isCervantes = "Cervantes",
    isSonyPRSTUX = "Sony",
    isRemarkable = "reMarkable",
}

-- 设备标志判断:兼容布尔字段与同名方法(koreader 全系的 yes/no 都是函数,
-- 如 isKindle = function() return true end;旧版才有布尔字段)。
-- 字段 true 或方法返回 true 才算命中;stub 中 isAndroid=function() return false
-- 这类同名方法不会被误判。
local function deviceFlagOn(flag)
    local v = Device[flag]
    if v == true then return true end
    if type(v) == "function" then
        local ok, res = pcall(v, Device)
        return ok and res == true
    end
    return false
end

-- 型号可读化:下划线转空格,驼峰/字母数字边界分词。
-- KindlePaperWhite5 -> Kindle PaperWhite 5;Kobo_Libra2 -> Kobo Libra 2;
-- reMarkable 2.0 已含空格不拆分(避免拆成 "re Markable")。
-- 专有名词(PaperWhite 等)整体加空格保护,不被驼峰规则拆开,无需占位符。
local MODEL_COMPOUND_WORDS = { "PaperWhite", "Oasis", "Scribe", "Voyage" }

local function prettyModel(model)
    local m = model:gsub("_", " ")
    -- 专有名词两侧加空格,使其与相邻词隔离(词内部保持连写)
    for _, w in ipairs(MODEL_COMPOUND_WORDS) do
        m = m:gsub(w, " " .. w .. " ")
    end
    -- 剩余驼峰边界分词(此时专有名词已被空格隔离,不会再被拆)
    if not m:find("%s") then
        m = m:gsub("([a-z0-9])([A-Z])", "%1 %2")
    end
    m = m:gsub("([A-Za-z])(%d)", "%1 %2")
    -- 清理多余空格
    m = m:gsub("%s+", " ")
    return m:match("^%s*(.-)%s*$") or m
end

local footer_brand_diag_done = false

local function footerBrandText()
    if not footer_brand_diag_done then
        footer_brand_diag_done = true
        -- 诊断:输出设备表结构/标志/型号,定位 Kindle 等设备上品牌未生效的原因
        local flags = {}
        for k, v in pairs(Device) do
            if type(k) == "string" and k:match("^is[A-Z]") then
                flags[#flags + 1] = k .. "=" .. tostring(v) .. "(" .. type(v) .. ")"
            end
        end
        table.sort(flags)
        logger.info("miuread: footer brand diag: device_type=", type(Device),
            " model=", tostring(Device.model), " (", type(Device.model), ")",
            " flags: ", table.concat(flags, " "))
        local ok_v, ver = pcall(require, "version")
        if ok_v and type(ver) == "table" then
            logger.info("miuread: footer brand diag: koreader ver=",
                tostring(ver.rev or ver.tag or "unknown"))
        end
    end
    local brand
    for flag, name in pairs(DEVICE_BRANDS) do
        if deviceFlagOn(flag) then
            brand = name
            break
        end
    end
    if not brand then
        -- SDL/dummy/未知设备:保持默认文案
        return "微信读书"
    end
    -- 型号含品牌名才显示(如 Kindle PaperWhite 5/Kobo Libra2/reMarkable 2.0),
    -- 避免 PB515/rk30sdk 这类不含品牌的型号
    local model = type(Device.model) == "string" and Device.model or ""
    if model ~= "" and model:lower():find(brand:lower(), 1, true) then
        brand = prettyModel(model)
    end
    return brand .. " · 微信读书"
end

return {
    footerBrandText = footerBrandText,
}
