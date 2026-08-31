local Json = require("miuread.json")
local U = require("miuread.util")
local logger = require("logger")

local SQLiteStore = {}
local unpack_args = unpack or table.unpack
local function pack_results(...)
    return {n=select("#", ...), ...}
end

local function parent_dir(path)
    return tostring(path or ""):match("^(.*)/[^/]+$")
end

local function open_connection(path, read_only)
    path = tostring(path or "")
    if path == "" then error("SQLite 路径为空") end
    if not read_only then
        local parent = parent_dir(path)
        if parent and parent ~= "" then U.mkdir(parent) end
    end
    local SQ3 = require("lua-ljsqlite3/init")
    local conn = read_only and SQ3.open(path, "ro") or SQ3.open(path)
    conn:exec("PRAGMA busy_timeout=5000;")
    if not read_only then
        pcall(function() conn:exec("PRAGMA journal_mode=WAL;") end)
        conn:exec("PRAGMA synchronous=NORMAL;")
        conn:exec("PRAGMA foreign_keys=ON;")
    end
    return conn
end

local function initialize(conn)
    conn:exec([[
        CREATE TABLE IF NOT EXISTS kv (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at INTEGER NOT NULL DEFAULT 0
        );
    ]])
end

function SQLiteStore.open(path, read_only)
    local conn = open_connection(path, read_only == true)
    if read_only ~= true then initialize(conn) end
    return conn
end

function SQLiteStore.with_connection(path, read_only, callback)
    local conn = SQLiteStore.open(path, read_only)
    local packed = pack_results(xpcall(function() return callback(conn) end, debug.traceback))
    local close_ok, close_error = pcall(conn.close, conn)
    if not close_ok then logger.warn("[MiuRead][SQLite] close failed", tostring(close_error)) end
    if not packed[1] then error(packed[2]) end
    return unpack_args(packed, 2, packed.n)
end

function SQLiteStore.transaction(conn, callback)
    conn:exec("BEGIN IMMEDIATE;")
    local packed = pack_results(xpcall(function() return callback(conn) end, debug.traceback))
    if packed[1] then
        local ok, err = pcall(conn.exec, conn, "COMMIT;")
        if not ok then
            pcall(conn.exec, conn, "ROLLBACK;")
            error(err)
        end
        return unpack_args(packed, 2, packed.n)
    end
    pcall(conn.exec, conn, "ROLLBACK;")
    error(packed[2])
end

function SQLiteStore.get_text(conn, key)
    local statement = conn:prepare("SELECT value FROM kv WHERE key = ? LIMIT 1")
    local row = statement:bind(tostring(key or "")):step()
    statement:close()
    return row and row[1] or nil
end

function SQLiteStore.set_text(conn, key, value)
    local statement = conn:prepare([[
        INSERT OR REPLACE INTO kv(key, value, updated_at) VALUES(?, ?, ?)
    ]])
    statement:bind(tostring(key or ""), tostring(value or ""), os.time()):step()
    statement:close()
    return true
end

function SQLiteStore.delete(conn, key)
    local statement = conn:prepare("DELETE FROM kv WHERE key = ?")
    statement:bind(tostring(key or "")):step()
    statement:close()
    return true
end

function SQLiteStore.get_json(conn, key, default)
    local raw = SQLiteStore.get_text(conn, key)
    if raw == nil then return default end
    local ok, value = pcall(Json.decode, raw)
    if not ok then return default, tostring(value) end
    return value
end

function SQLiteStore.set_json(conn, key, value)
    local ok, encoded = pcall(Json.encode, value)
    if not ok then return nil, tostring(encoded) end
    SQLiteStore.set_text(conn, key, encoded)
    return true
end

function SQLiteStore.get_json_path(path, key, default, read_only)
    local ok, value, err = pcall(function()
        return SQLiteStore.with_connection(path, read_only == true, function(conn)
            return SQLiteStore.get_json(conn, key, default)
        end)
    end)
    if not ok then return default, tostring(value) end
    return value, err
end

function SQLiteStore.set_json_path(path, key, value)
    local ok, result, err = pcall(function()
        return SQLiteStore.with_connection(path, false, function(conn)
            return SQLiteStore.set_json(conn, key, value)
        end)
    end)
    if not ok then return nil, tostring(result) end
    return result, err
end

function SQLiteStore.delete_path(path, key)
    local ok, result = pcall(function()
        return SQLiteStore.with_connection(path, false, function(conn)
            return SQLiteStore.delete(conn, key)
        end)
    end)
    if not ok then return nil, tostring(result) end
    return result
end

function SQLiteStore.integrity_check(path)
    local ok, result = pcall(function()
        return SQLiteStore.with_connection(path, true, function(conn)
            local statement = conn:prepare("PRAGMA quick_check;")
            local row = statement:step()
            statement:close()
            return row and tostring(row[1] or "") == "ok"
        end)
    end)
    return ok and result == true, ok and nil or tostring(result)
end

return SQLiteStore
