local SQLiteStore = require("miuread.sqlite_store")
local Json = require("miuread.json")
local U = require("miuread.util")
local lfs = require("libs/libkoreader-lfs")

local DownloadDatabase = {}

DownloadDatabase.PARTIAL_FILE = "download.sqlite3"
DownloadDatabase.RUNTIME_FILE = "download-runtime.sqlite3"

local function partial_path(root)
    return tostring(root or "") .. "/" .. DownloadDatabase.PARTIAL_FILE
end

local function runtime_path(value)
    if type(value) == "table" then
        return tostring(value.data_dir or "") .. "/" .. DownloadDatabase.RUNTIME_FILE
    end
    return tostring(value or "") .. "/" .. DownloadDatabase.RUNTIME_FILE
end

local function safe_id(value)
    return U.id_name(tostring(value or ""))
end

local function task_key(token, field)
    return "task:" .. safe_id(token) .. ":" .. tostring(field or "")
end

function DownloadDatabase.partial_path(root) return partial_path(root) end
function DownloadDatabase.runtime_path(value) return runtime_path(value) end

function DownloadDatabase.partial_exists(root)
    return lfs.attributes(partial_path(root), "mode") == "file"
end

function DownloadDatabase.load_manifest(root)
    return SQLiteStore.get_json_path(partial_path(root), "manifest", nil, true)
end

function DownloadDatabase.save_manifest(root, manifest)
    return SQLiteStore.set_json_path(partial_path(root), "manifest", manifest)
end

function DownloadDatabase.save_assets(root, chapter_uid, assets)
    return SQLiteStore.set_json_path(partial_path(root), "assets:" .. safe_id(chapter_uid), assets or {})
end

function DownloadDatabase.load_assets(root, chapter_uid)
    return SQLiteStore.get_json_path(partial_path(root), "assets:" .. safe_id(chapter_uid), nil, true)
end

function DownloadDatabase.delete_assets(root, chapter_uid)
    return SQLiteStore.delete_path(partial_path(root), "assets:" .. safe_id(chapter_uid))
end

function DownloadDatabase.save_annotation(root, chapter_uid, account_key, snapshot)
    local key = "annotation:" .. safe_id(chapter_uid) .. ":" .. safe_id(account_key)
    return SQLiteStore.set_json_path(partial_path(root), key, snapshot)
end

function DownloadDatabase.load_annotation(root, chapter_uid, account_key)
    local key = "annotation:" .. safe_id(chapter_uid) .. ":" .. safe_id(account_key)
    return SQLiteStore.get_json_path(partial_path(root), key, nil, true)
end

function DownloadDatabase.delete_annotation(root, chapter_uid, account_key)
    local key = "annotation:" .. safe_id(chapter_uid) .. ":" .. safe_id(account_key)
    return SQLiteStore.delete_path(partial_path(root), key)
end

function DownloadDatabase.set_download_state(store, value)
    return SQLiteStore.set_json_path(runtime_path(store), "download_state", value or {})
end

function DownloadDatabase.get_download_state(store)
    return SQLiteStore.get_json_path(runtime_path(store), "download_state", {}, true)
end

function DownloadDatabase.clear_download_state(store)
    return SQLiteStore.delete_path(runtime_path(store), "download_state")
end

function DownloadDatabase.set_download_queue(store, value)
    return SQLiteStore.set_json_path(runtime_path(store), "download_queue", value or {})
end

function DownloadDatabase.get_download_queue(store)
    return SQLiteStore.get_json_path(runtime_path(store), "download_queue", {}, true)
end

function DownloadDatabase.set_task_value(path, token, field, value)
    return SQLiteStore.set_json_path(path, task_key(token, field), value)
end

function DownloadDatabase.get_task_value(path, token, field, default)
    return SQLiteStore.get_json_path(path, task_key(token, field), default, true)
end

function DownloadDatabase.delete_task_value(path, token, field)
    return SQLiteStore.delete_path(path, task_key(token, field))
end

function DownloadDatabase.set_owner(path, value)
    return SQLiteStore.set_json_path(path, "task_owner", value or {})
end

function DownloadDatabase.get_owner(path)
    return SQLiteStore.get_json_path(path, "task_owner", nil, true)
end

function DownloadDatabase.clear_owner(path)
    return SQLiteStore.delete_path(path, "task_owner")
end

function DownloadDatabase.set_pause(path, token, reasons)
    local ordered = {}
    for reason, enabled in pairs(reasons or {}) do
        if enabled == true and tostring(reason or "") ~= "" then ordered[#ordered + 1] = tostring(reason) end
    end
    table.sort(ordered)
    if #ordered == 0 then return DownloadDatabase.delete_task_value(path, token, "pause") end
    return DownloadDatabase.set_task_value(path, token, "pause", {
        paused=true, reasons=ordered, updated_at=os.time(),
    })
end

function DownloadDatabase.get_pause(path, token)
    return DownloadDatabase.get_task_value(path, token, "pause", nil)
end

function DownloadDatabase.set_cancelled(path, token, cancelled)
    if cancelled ~= true then return DownloadDatabase.delete_task_value(path, token, "cancel") end
    return DownloadDatabase.set_task_value(path, token, "cancel", {cancelled=true, updated_at=os.time()})
end

function DownloadDatabase.is_cancelled(path, token)
    local value = DownloadDatabase.get_task_value(path, token, "cancel", nil)
    return type(value) == "table" and value.cancelled == true
end

function DownloadDatabase.clear_task(path, token)
    local fields = {"descriptor", "progress", "result", "recovery", "pause", "cancel", "migration_progress"}
    for _, field in ipairs(fields) do DownloadDatabase.delete_task_value(path, token, field) end
    return true
end

function DownloadDatabase.remove_partial(root)
    local path = partial_path(root)
    os.remove(path); os.remove(path .. "-wal"); os.remove(path .. "-shm")
end

local function read_legacy_json(path)
    local raw = U.read_file(path, true)
    if not raw then return nil end
    local ok, value = pcall(Json.decode, raw)
    return ok and type(value) == "table" and value or nil
end

function DownloadDatabase.migrate_legacy_partial(root)
    local manifest_path = tostring(root or "") .. "/manifest.json"
    local legacy_manifest = read_legacy_json(manifest_path)
    local existing_manifest = DownloadDatabase.load_manifest(root)
    local manifest = type(legacy_manifest) == "table" and legacy_manifest or existing_manifest
    if type(manifest) ~= "table" then
        return {migrated=false, existing=DownloadDatabase.partial_exists(root)}
    end

    local manifest_saved = type(existing_manifest) == "table"
    if type(legacy_manifest) == "table" then
        local saved, save_error = DownloadDatabase.save_manifest(root, legacy_manifest)
        if not saved then return nil, save_error end
        manifest_saved = true
    end

    local migrated_assets, migrated_annotations, remaining = 0, 0, 0
    for uid in pairs(type(manifest.chapters) == "table" and manifest.chapters or {}) do
        local chapter_dir = tostring(root) .. "/chapters/" .. U.id_name(uid)
        local assets_path = chapter_dir .. "/assets.json"
        local assets = read_legacy_json(assets_path)
        if type(assets) == "table" then
            local ok_assets = DownloadDatabase.save_assets(root, uid, assets)
            if ok_assets then
                os.remove(assets_path)
                migrated_assets = migrated_assets + 1
            else
                remaining = remaining + 1
            end
        end
        local annotation_dir = chapter_dir .. "/annotations"
        if lfs.attributes(annotation_dir, "mode") == "directory" then
            for name in lfs.dir(annotation_dir) do
                if name:match("%.json$") then
                    local path = annotation_dir .. "/" .. name
                    local snapshot = read_legacy_json(path)
                    local account_key = name:gsub("%.json$", "")
                    if type(snapshot) == "table" then
                        local ok_annotation = DownloadDatabase.save_annotation(root, uid, account_key, snapshot)
                        if ok_annotation then
                            os.remove(path)
                            migrated_annotations = migrated_annotations + 1
                        else
                            remaining = remaining + 1
                        end
                    else
                        remaining = remaining + 1
                    end
                end
            end
        end
    end
    if manifest_saved then os.remove(manifest_path) end
    return {
        migrated=type(legacy_manifest) == "table" or migrated_assets > 0 or migrated_annotations > 0,
        existing=type(existing_manifest) == "table",
        assets=migrated_assets, annotations=migrated_annotations, remaining=remaining,
    }
end

local function account_hash(value)
    local hash=5381
    value=tostring(value or "")
    for index=1,#value do hash=(hash*33+value:byte(index))%2147483647 end
    return string.format("a%08x",hash)
end

function DownloadDatabase.account_key(store)
    local auth=store and store:auth() or {}
    local account=type(auth.account)=="table" and auth.account or {}
    local vid=tostring(account.vid or "")
    return vid~="" and account_hash(vid) or "anonymous"
end

function DownloadDatabase.load_annotation_data(root, chapter_uid, account_key, annotations)
    local value = DownloadDatabase.load_annotation(root, chapter_uid, account_key)
    if type(value) ~= "table" or tostring(value.account_key or "") ~= tostring(account_key) then return nil end
    local restored = annotations:from_cache(value)
    if type(restored) == "table" then restored.saved_at = tonumber(value.saved_at or 0) or 0 end
    return restored
end

function DownloadDatabase.save_annotation_data(root, chapter_uid, account_key, annotations, data)
    local snapshot=annotations:to_cache(data)
    snapshot.account_key=tostring(account_key)
    snapshot.saved_at=os.time()
    return DownloadDatabase.save_annotation(root, chapter_uid, account_key, snapshot)
end

return DownloadDatabase
