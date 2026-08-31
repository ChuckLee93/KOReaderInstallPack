local U = require("miuread.util")

local Plan = {}

local function uid(chapter)
    return tostring(chapter and (chapter.chapterUid or chapter.uid) or "")
end

local function chapter_positions(chapters)
    local out={}
    for index,chapter in ipairs(chapters or {}) do
        local key=uid(chapter)
        if key~="" then out[key]=index end
    end
    return out
end

local function existing_bounds(all,record)
    if type(record)~="table" or type(record.chapter_map)~="table" then return nil,nil,{} end
    local positions=chapter_positions(all)
    local first,last,missing=nil,nil,{}
    for _,chapter in ipairs(record.chapter_map) do
        if chapter.structural~=true then
            local key=tostring(chapter.uid or chapter.chapter_uid or "")
            local position=positions[key]
            if position then
                first=not first and position or math.min(first,position)
                last=not last and position or math.max(last,position)
            elseif key~="" then
                missing[#missing+1]=key
            end
        end
    end
    if not first then first=tonumber(record.range_start_index) end
    if not last then last=tonumber(record.range_end_index) end
    return first,last,missing
end

function Plan.select(all,opt,existing_range)
    opt=opt or {}
    local selected={}
    if opt.chapter_uid then
        for _,chapter in ipairs(all or {}) do
            if uid(chapter)==tostring(opt.chapter_uid) then selected[1]=chapter; break end
        end
    elseif opt.range_start_index and opt.range_end_index then
        local first=math.max(1,tonumber(opt.range_start_index) or 1)
        local last=math.min(#all,tonumber(opt.range_end_index) or first)
        if last<first then first,last=last,first end
        local old_first,old_last,missing=existing_bounds(all,existing_range)
        if old_first then first=math.max(1,math.min(first,old_first)) end
        if old_last then last=math.min(#all,math.max(last,old_last)) end
        for index,chapter in ipairs(all or {}) do
            if index>=first and index<=last then selected[#selected+1]=chapter end
        end
        opt.range_start_index=first
        opt.range_end_index=last
        opt.range_start_title=all[first] and all[first].title or opt.range_start_title
        opt.range_end_title=all[last] and all[last].title or opt.range_end_title
        opt.previous_chapter_map=type(existing_range)=="table" and U.copy(existing_range.chapter_map or {}) or nil
        opt.missing_previous_chapter_uids=#missing>0 and missing or nil
    else
        for index,chapter in ipairs(all or {}) do
            if not opt.limit or index<=tonumber(opt.limit) then selected[#selected+1]=chapter end
        end
    end
    local ids={}
    for _,chapter in ipairs(selected) do ids[#ids+1]=uid(chapter) end
    opt.target_chapter_uids=ids
    return selected
end

return Plan
