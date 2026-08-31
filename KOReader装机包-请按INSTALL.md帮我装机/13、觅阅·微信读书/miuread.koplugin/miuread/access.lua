local U=require("miuread.util")

local Access={}
Access.__index=Access
local LOCK_SUFFIX=".miuread-locked"

local function ends_with(value,suffix)
    value=tostring(value or "")
    return suffix~="" and value:sub(-#suffix)==suffix
end

local function clear_access_fields(record)
    if type(record)~="table" then return end
    record.locked=nil
    record.lock_reason=nil
    record.locked_at=nil
    record.original_file=nil
    record.access_status=nil
    record.access_policy_version=nil
    record.ownership=nil
    record.ownership_source=nil
    record.access_ownership=nil
    record.access_ownership_source=nil
    record.account_vid=nil
    record.verified_at=nil
    record.valid_until=nil
    record.last_access_check=nil
end

local function restore_path(record)
    if type(record)~="table" then return nil,false end
    local path=tostring(record.file or "")
    local original=tostring(record.original_file or "")
    if original=="" and ends_with(path,LOCK_SUFFIX) then
        original=path:sub(1,#path-#LOCK_SUFFIX)
    end
    local changed=false
    if original~="" and path~="" and path~=original then
        if U.file_exists(original) then
            if U.file_exists(path) and ends_with(path,LOCK_SUFFIX) then os.remove(path) end
            record.file=original
            changed=true
        elseif U.file_exists(path) then
            local ok=os.rename(path,original)
            if ok then record.file=original; changed=true end
        end
    elseif path~="" and ends_with(path,LOCK_SUFFIX) then
        local target=path:sub(1,#path-#LOCK_SUFFIX)
        if U.file_exists(target) then
            if U.file_exists(path) then os.remove(path) end
            record.file=target
            changed=true
        elseif U.file_exists(path) then
            local ok=os.rename(path,target)
            if ok then record.file=target; changed=true end
        end
    end
    clear_access_fields(record)
    return tostring(record.file or original or path),changed
end

function Access:new(_library,_api,_reader,store)
    return setmetatable({store=store},self)
end

function Access:_save_book(book_id,book)
    if self.store and type(self.store.save_book)=="function" and type(book)=="table" then
        book.access=nil
        self.store:save_book(book_id,book)
        if type(self.store.clear_book_access)=="function" then self.store:clear_book_access(book_id) end
    end
end

function Access:unlock_book(book_id)
    local book=self.store and self.store:book(book_id) or nil
    if type(book)~="table" then return false end
    local changed=false
    local function visit(record)
        local _,restored=restore_path(record)
        changed=changed or restored
    end
    for _,record in pairs(book.variants or {}) do visit(record) end
    for _,row in pairs(book.chapters or {}) do
        for _,record in pairs(row or {}) do visit(record) end
    end
    book.access=nil
    self:_save_book(book_id,book)
    return changed
end

function Access:resolve_path(book_id,path)
    path=tostring(path or "")
    if path=="" then return nil end
    if U.file_exists(path) and not ends_with(path,LOCK_SUFFIX) then return path end

    if ends_with(path,LOCK_SUFFIX) or U.file_exists(path..LOCK_SUFFIX) then
        self:unlock_book(book_id)
        local target=ends_with(path,LOCK_SUFFIX) and path:sub(1,#path-#LOCK_SUFFIX) or path
        if U.file_exists(target) then return target end
    end

    local book=self.store and self.store:book(book_id) or nil
    if type(book)=="table" then
        local function find(record)
            if type(record)~="table" then return nil end
            local file=tostring(record.file or "")
            local original=tostring(record.original_file or "")
            if file==path or original==path
                or (ends_with(path,LOCK_SUFFIX) and original==path:sub(1,#path-#LOCK_SUFFIX)) then
                return restore_path(record)
            end
        end
        for _,record in pairs(book.variants or {}) do
            local resolved=find(record)
            if resolved and U.file_exists(resolved) then return resolved end
        end
        for _,row in pairs(book.chapters or {}) do
            for _,record in pairs(row or {}) do
                local resolved=find(record)
                if resolved and U.file_exists(resolved) then return resolved end
            end
        end
    end
    return U.file_exists(path) and path or nil
end

return Access
