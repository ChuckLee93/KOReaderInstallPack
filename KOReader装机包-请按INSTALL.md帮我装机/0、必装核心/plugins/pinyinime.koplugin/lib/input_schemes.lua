local InputSchemes = {}

local ordered = {
    {
        id = "full",
        name = "全拼",
        is_shuangpin = false,
        requires_semicolon = false,
    },
    {
        id = "sogou",
        name = "搜狗双拼",
        is_shuangpin = true,
        requires_semicolon = true,
        alphabet = "abcdefghijklmnopqrstuvwxyz;",
        data_file = "data/shuangpin_sogou_microsoft.lua",
    },
    {
        id = "pinyin_jiajia",
        name = "拼音加加双拼",
        is_shuangpin = true,
        requires_semicolon = false,
        alphabet = "abcdefghijklmnopqrstuvwxyz",
        data_file = "data/shuangpin_pinyin_jiajia.lua",
    },
    {
        id = "microsoft",
        name = "微软双拼",
        is_shuangpin = true,
        requires_semicolon = true,
        alphabet = "abcdefghijklmnopqrstuvwxyz;",
        data_file = "data/shuangpin_sogou_microsoft.lua",
    },
    {
        id = "flypy",
        name = "小鹤双拼",
        is_shuangpin = true,
        requires_semicolon = false,
        alphabet = "abcdefghijklmnopqrstuvwxyz",
        data_file = "data/shuangpin_flypy.lua",
    },
    {
        id = "common",
        name = "自然码双拼",
        is_shuangpin = true,
        requires_semicolon = false,
        alphabet = "abcdefghijklmnopqrstuvwxyz",
        data_file = "data/shuangpin_common.lua",
    },
}

local by_id = {}
for _, scheme in ipairs(ordered) do
    local allowed = {}
    for character in (scheme.alphabet or "abcdefghijklmnopqrstuvwxyz"):gmatch(".") do
        allowed[character] = true
    end
    scheme.allowed_characters = allowed
    by_id[scheme.id] = scheme
end

function InputSchemes.list()
    return ordered
end

function InputSchemes.get(id)
    return by_id[id]
end

function InputSchemes.normalize(id)
    return by_id[id] and id or "full"
end

function InputSchemes.normalizeShuangpin(id)
    local scheme = by_id[id]
    return scheme and scheme.is_shuangpin and id or "flypy"
end

function InputSchemes.isShuangpin(id)
    local scheme = by_id[id]
    return scheme and scheme.is_shuangpin == true or false
end

function InputSchemes.requiresSemicolon(id)
    local scheme = by_id[id]
    return scheme and scheme.requires_semicolon == true or false
end

function InputSchemes.isAllowedCharacter(id, character)
    local scheme = by_id[id]
    return scheme and scheme.allowed_characters[character] == true or false
end

function InputSchemes.getName(id)
    local scheme = by_id[InputSchemes.normalize(id)]
    return scheme.name
end

return InputSchemes
