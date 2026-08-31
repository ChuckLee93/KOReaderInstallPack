local Json = require("miuread.json")
local ThoughtDatabase = require("miuread.thought_database")
local U = require("miuread.util")
local lfs = require("libs/libkoreader-lfs")

local Migration = {}
Migration.__index = Migration

function Migration:new(store)
    return setmetatable({store=store}, self)
end

local function file_signature(path)
    local attr = lfs.attributes(tostring(path or ""))
    if type(attr) ~= "table" then return "missing" end
    return tostring(attr.modification or 0) .. ":" .. tostring(attr.size or 0)
end

local function wants_annotations(context)
    context = type(context) == "table" and context or {}
    local record = type(context.record) == "table" and context.record or {}
    local variant = tostring(context.variant or record.variant or "")
    return record.annotation_requested == true or variant:find("notes", 1, true) ~= nil
end

local function source_files(store, book_id)
    local dir = store:book_dir(book_id) .. "/thoughts"
    local rows = {}
    if lfs.attributes(dir, "mode") ~= "directory" then return rows end
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." and name:match("%.json$") then
            local path = dir .. "/" .. name
            rows[#rows + 1] = {
                path=path,
                chapter_uid=name:gsub("%.json$", ""),
                signature=file_signature(path),
                size=tonumber((lfs.attributes(path) or {}).size or 0) or 0,
            }
        end
    end
    table.sort(rows, function(a, b) return a.path < b.path end)
    return rows
end

local function count_rows(groups)
    local group_count, comment_count, seen_ranges = 0, 0, {}
    for _, group in ipairs(type(groups) == "table" and groups or {}) do
        local range = tostring(type(group) == "table" and group.range or "")
        if range ~= "" and not seen_ranges[range] then
            local valid = 0
            for _, item in ipairs(group.texts or {}) do
                if type(item) == "table" and tostring(item.content or "") ~= "" then valid = valid + 1 end
            end
            if valid > 0 then
                seen_ranges[range] = true
                group_count = group_count + 1
                comment_count = comment_count + valid
            end
        end
    end
    return {groups=group_count, comments=comment_count}
end

function Migration:signature(context, files)
    context = type(context) == "table" and context or {}
    local book = type(context.book) == "table" and context.book or {}
    local id = tostring(book.book_id or book.bookId or context.book_id or "")
    files = type(files) == "table" and files or source_files(self.store, id)
    local parts = {id, tostring(context.variant or ""), tostring(#files)}
    for _, row in ipairs(files) do
        parts[#parts + 1] = tostring(row.chapter_uid or "") .. ":" .. tostring(row.signature or "")
    end
    return table.concat(parts, "|")
end

function Migration:inspect(context)
    context = type(context) == "table" and context or {}
    local book = type(context.book) == "table" and context.book or {}
    local id = tostring(book.book_id or book.bookId or context.book_id or "")
    local files = id ~= "" and source_files(self.store, id) or {}
    local report = {
        ok=true, book_id=id, title=tostring(book.title or context.title or "当前书籍"),
        signature=self:signature(context,files), issues={}, files=files, pending=0, migrated=0,
        total_bytes=0, database_exists=false,
    }
    if id == "" then return report end
    report.database_exists = ThoughtDatabase.exists(self.store, id)
    if #report.files == 0 and not report.database_exists and not wants_annotations(context) then return report end
    local records = report.database_exists and ThoughtDatabase.migration_records(self.store, id) or {}
    for _, row in ipairs(report.files) do
        report.total_bytes = report.total_bytes + row.size
        local record = records[row.path]
        local valid = record
            and tostring(record.source_signature or "") == tostring(row.signature)
            and record.chapter_present == true
            and record.actual_groups ~= nil and record.actual_comments ~= nil
            and tonumber(record.actual_groups or 0) == tonumber(record.groups or 0)
            and tonumber(record.actual_comments or 0) == tonumber(record.comments or 0)
        row.migration_record = valid and record or nil
        if valid then
            report.migrated = report.migrated + 1
        else
            report.pending = report.pending + 1
        end
    end
    if report.pending > 0 then
        report.issues[#report.issues + 1] = {
            code="thought_migration", title="想法与评论需要迁移",
            detail="检测到旧版 JSON 想法与评论数据，可转换为 SQLite。转换不会重新下载书籍。",
        }
    elseif #report.files > 0 and not report.database_exists then
        report.issues[#report.issues + 1] = {
            code="thought_migration", title="评论数据库需要建立",
            detail="检测到旧版评论数据，但尚未建立 SQLite 数据库。",
        }
    end
    if report.database_exists then
        local integrity = ThoughtDatabase.integrity(self.store, id)
        if integrity ~= true then
            report.issues[#report.issues + 1] = {
                code="database_rebuild", title="评论数据库需要修复",
                detail="评论数据库检查未通过，可从保留的旧 JSON 重新建立。",
            }
        end
    end
    return report
end

function Migration:migrate(context, report, options)
    context = type(context) == "table" and context or {}
    report = type(report) == "table" and report or self:inspect(context)
    options = type(options) == "table" and options or {}
    local result = {
        ok=true, cancelled=false, book_id=report.book_id, title=report.title,
        signature=report.signature, total=#(report.files or {}), processed=0,
        migrated=0, skipped=0, failed=0, groups=0, comments=0, failures={},
    }
    local force = options.force == true
    local progress = options.progress
    local cancelled = options.cancelled
    local rebuild=false
    for _,issue in ipairs(report.issues or {}) do
        if issue.code=="database_rebuild" then rebuild=true; break end
    end
    if rebuild and #(report.files or {}) == 0 then
        result.ok=false
        result.failed=1
        result.failures[1]={path=ThoughtDatabase.path(self.store,report.book_id),error="没有可用于重建的旧 JSON 备份"}
        return result
    end
    if rebuild then ThoughtDatabase.remove(self.store, report.book_id) end
    for index, row in ipairs(report.files or {}) do
        if cancelled and cancelled() then result.cancelled=true; result.ok=false; break end
        local existing = row.migration_record
        if not force and existing and tostring(existing.source_signature or "") == tostring(row.signature) then
            result.skipped = result.skipped + 1
        else
            local raw, read_error = U.read_file(row.path, true)
            local decoded_ok, groups = false, nil
            if raw then decoded_ok, groups = pcall(Json.decode, raw) end
            if not raw then
                result.failed=result.failed+1
                result.failures[#result.failures+1]={path=row.path,error=tostring(read_error or "无法读取")}
            elseif not decoded_ok or type(groups) ~= "table" then
                result.failed=result.failed+1
                result.failures[#result.failures+1]={path=row.path,error="JSON 损坏"}
                groups=nil
            end
            if type(groups) == "table" then
                local counts = count_rows(groups)
                local saved, save_error = ThoughtDatabase.migrate_chapter(
                    self.store, report.book_id, row.chapter_uid, groups,
                    row.path, row.signature, counts)
                if saved then
                    result.migrated=result.migrated+1
                    result.groups=result.groups+counts.groups
                    result.comments=result.comments+counts.comments
                else
                    result.failed=result.failed+1
                    result.failures[#result.failures+1]={path=row.path,error=tostring(save_error)}
                end
            end
        end
        result.processed=index
        if progress then
            progress({stage="migrate", current=index, total=result.total,
                chapter=row.chapter_uid, groups=result.groups, comments=result.comments,
                percent=result.total > 0 and index / result.total or 1})
        end
    end
    if result.failed > 0 then result.ok=false end
    if result.ok and not result.cancelled and options.archive_legacy == true then
        self:archive_legacy(report.book_id)
    end
    return result
end

function Migration:archive_legacy(book_id)
    local root = self.store:book_dir(book_id)
    local backup = root .. "/legacy-json-backup"
    U.mkdir(backup)
    local moved = 0
    for _, name in ipairs({"thoughts", "thought-index"}) do
        local source = root .. "/" .. name
        if lfs.attributes(source) then
            local target = backup .. "/" .. name
            U.remove_tree(target)
            if os.rename(source, target) then moved = moved + 1 end
        end
    end
    return moved
end

function Migration:remove_verified_legacy(book_id)
    local root = self.store:book_dir(book_id)
    local removed=false
    for _,path in ipairs({root.."/thoughts",root.."/thought-index",root.."/legacy-json-backup"}) do
        if lfs.attributes(path) then U.remove_tree(path); removed=true end
    end
    return removed
end

function Migration:contexts_from_library()
    local rows = {}
    for id, book in pairs(self.store:library() or {}) do
        if type(book) == "table" then
            local selected_variant, selected_record
            for variant, record in pairs(book.variants or {}) do
                if type(record) == "table" and not selected_record then
                    selected_variant, selected_record = variant, record
                end
                if type(record) == "table" and (record.annotation_requested == true
                    or tostring(variant):find("notes", 1, true)) then
                    selected_variant, selected_record = variant, record
                    break
                end
            end
            local has_legacy = #source_files(self.store, id) > 0
            local has_database = ThoughtDatabase.exists(self.store, id)
            if selected_record and (has_legacy or has_database
                or selected_record.annotation_requested == true
                or tostring(selected_variant or ""):find("notes", 1, true)) then
                rows[#rows + 1] = {
                    book={book_id=tostring(id), title=book.title}, book_id=tostring(id),
                    record={annotation_requested=selected_record.annotation_requested,
                        variant=selected_record.variant, file=selected_record.file},
                    variant=selected_variant, path=selected_record.file, title=book.title,
                }
            end
        end
    end
    table.sort(rows, function(a, b) return tostring(a.title or "") < tostring(b.title or "") end)
    return rows
end

function Migration:scan_downloaded()
    local result = {checked=0, affected=0, contexts={}}
    for _, context in ipairs(self:contexts_from_library()) do
        local report = self:inspect(context)
        result.checked=result.checked+1
        if #(report.issues or {}) > 0 then
            result.affected=result.affected+1
            result.contexts[#result.contexts+1]={context=context, report=report}
        end
    end
    return result
end

function Migration:repair(context, report, force)
    return self:migrate(context, report, {force=force==true, archive_legacy=false})
end

function Migration:repair_scan(scan)
    local result={checked=0,migrated=0,failed=0,details={}}
    for _,row in ipairs((scan and scan.contexts) or {}) do
        local migrated=self:migrate(row.context,row.report,{force=false,archive_legacy=false})
        result.checked=result.checked+1
        if migrated.ok then result.migrated=result.migrated+1 else result.failed=result.failed+1 end
        result.details[#result.details+1]=migrated
    end
    result.ok=result.failed==0
    return result
end

function Migration:remove_verified_legacy_downloaded()
    local removed=0
    for _,context in ipairs(self:contexts_from_library()) do
        local id=tostring((context.book or {}).book_id or context.book_id or "")
        local report=self:inspect(context)
        if id~="" and tonumber(report.pending or 0)==0 and #(report.issues or {})==0
            and ThoughtDatabase.exists(self.store,id) then
            if self:remove_verified_legacy(id) then removed=removed+1 end
        end
    end
    return removed
end

return Migration
