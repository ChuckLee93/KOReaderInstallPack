--[[--
EPUB 内部链接修复与校验。

用于处理微信读书原始路径在觅阅重新打包后失效的问题，例如：
OEBPS/Text/zz009.html#w80 -> #w80
或 -> chapter-0012.xhtml#w80。

本模块只处理 <a href="...">，外部链接和觅阅评论协议保持不变。
--]]--

local M = {}

local function decode_entities(value)
    value = tostring(value or "")
    return value:gsub("&amp;", "&"):gsub("&#38;", "&")
end

local function encode_href(value)
    return tostring(value or ""):gsub("&", "&amp;"):gsub('"', "&quot;")
end

local function url_decode(value)
    return tostring(value or ""):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
end

local function normalize_path(path)
    path = url_decode(decode_entities(path)):gsub("\\", "/")
    path = path:gsub("^file://", "")
    path = path:gsub("^/+", "")
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif part ~= "." and part ~= "" then
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "/")
end

local function dirname(path)
    return tostring(path or ""):match("^(.*)/[^/]*$") or ""
end

local function split_href(href)
    href = decode_entities(href):match("^%s*(.-)%s*$") or ""
    local before_fragment, fragment = href:match("^(.-)#(.*)$")
    if before_fragment == nil then before_fragment = href end
    local path, query = before_fragment:match("^(.-)(%?.*)$")
    if path == nil then path, query = before_fragment, "" end
    return path or "", url_decode(fragment or ""), query or "", fragment ~= nil
end

local function is_external(href)
    local lower = tostring(href or ""):lower():match("^%s*(.-)%s*$") or ""
    if lower:match("^[%a][%w+%.%-]*:") then return true end
    if lower:find("//", 1, true) == 1 then return true end
    return false
end

local function is_custom_fragment(fragment)
    local lower = tostring(fragment or ""):lower()
    return lower:find("miuthought-", 1, true) == 1
        or lower:find("wrthought-", 1, true) == 1
        or lower:find("miuread-", 1, true) == 1
end

local function get_attr(tag, name)
    tag = tostring(tag or "")
    local wanted = tostring(name or ""):lower()
    for key, value in tag:gmatch('([%w:_%-]+)%s*=%s*"([^"]*)"') do
        if key:lower() == wanted then return value end
    end
    for key, value in tag:gmatch("([%w:_%-]+)%s*=%s*'([^']*)'") do
        if key:lower() == wanted then return value end
    end
end

local function remove_href_attr(attrs)
    local name="[hH][rR][eE][fF]"
    local out,count=tostring(attrs or ""):gsub("%s+"..name..'%s*=%s*"[^"]*"',"",1)
    if count==0 then out=out:gsub("%s+"..name.."%s*=%s*'[^']*'","",1) end
    return out
end

local function strip_tags(html)
    local text = tostring(html or ""):gsub("<[^>]+>", " ")
    text = text:gsub("&nbsp;", " "):gsub("&#160;", " ")
    text = text:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
    return text:gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
end

local function marker_text(inner)
    local compact = strip_tags(inner):gsub("%s+", "")
    if compact:match("^%[[%d一二三四五六七八九十百千]+%]$")
        or compact:match("^〔[%d一二三四五六七八九十百千]+〕$")
        or compact:match("^【[%d一二三四五六七八九十百千]+】$")
        or compact:match("^（[%d一二三四五六七八九十百千]+）$")
        or compact:match("^[%d一二三四五六七八九十百千]+$")
        or compact:match("^[%*†‡※]+$") then
        return true
    end
    return false
end

local function looks_critical(attrs, href, fragment, inner)
    local lower_fragment = tostring(fragment or ""):lower()
    local class = tostring(get_attr(attrs, "class") or ""):lower()
    local role = tostring(get_attr(attrs, "role") or ""):lower()
    local epub_type = tostring(get_attr(attrs, "epub:type") or ""):lower()
    local lower_href = tostring(href or ""):lower()
    if class:find("footnote", 1, true) or class:find("noteref", 1, true)
        or class:find("fn-ref", 1, true) or role:find("doc-noteref", 1, true)
        or epub_type:find("noteref", 1, true) then return true end
    if lower_fragment:match("^[wrn][_%-%d]*%d+$")
        or lower_fragment:match("^ref[_%-]?%d+$")
        or lower_fragment:match("^back[_%-]?%d+$")
        or lower_fragment:match("^fn[_%-]?%d+$")
        or lower_fragment:match("^note[_%-]?%d+$")
        or lower_fragment:match("^foot[_%-]?%d+$") then return true end
    if marker_text(inner) and fragment ~= "" then return true end
    if lower_href:find("oebps/", 1, true) == 1 and fragment ~= "" then return true end
    return false
end

local function collect_ids(html)
    local ids = {}
    for tag in tostring(html or ""):gmatch("<[^>]+>") do
        local id = get_attr(tag, "id") or get_attr(tag, "name")
        if id and id ~= "" then ids[id] = true end
    end
    return ids
end

local function relative_path(from_path, to_path)
    if from_path == to_path then return "" end
    local from_dir = dirname(from_path)
    local from_parts, to_parts = {}, {}
    for part in from_dir:gmatch("[^/]+") do from_parts[#from_parts + 1] = part end
    for part in tostring(to_path or ""):gmatch("[^/]+") do to_parts[#to_parts + 1] = part end
    local common = 0
    while from_parts[common + 1] and to_parts[common + 1]
        and from_parts[common + 1] == to_parts[common + 1] do
        common = common + 1
    end
    local out = {}
    for _ = common + 1, #from_parts do out[#out + 1] = ".." end
    for index = common + 1, #to_parts do out[#out + 1] = to_parts[index] end
    return table.concat(out, "/")
end

local function package_path(current_path, href_path)
    href_path = tostring(href_path or "")
    if href_path == "" then return current_path end
    local lower = href_path:lower():gsub("\\", "/"):gsub("^/+", "")
    if lower:find("oebps/", 1, true) == 1
        or lower:find("meta-inf/", 1, true) == 1 then
        return normalize_path(href_path)
    end
    return normalize_path((dirname(current_path) ~= "" and dirname(current_path) .. "/" or "") .. href_path)
end

-- Collect the original target file together with all fragments pointing to it.
-- A group of consecutive fragments is much more reliable than guessing from a
-- single w80-style anchor when the regenerated EPUB no longer contains the
-- original zz009.html filename.
local function collect_target_hints(html, current_path, targets)
    targets = targets or {}
    for attrs, inner in tostring(html or ""):gmatch("<[aA]([^>]*)>(.-)</[aA]%s*>") do
        local href = get_attr(attrs, "href")
        if href and href ~= "" and not is_external(href) then
            local href_path, fragment, _, had_fragment = split_href(href)
            if had_fragment and fragment ~= "" and href_path ~= ""
                and not is_custom_fragment(fragment) then
                local target_path = package_path(current_path, href_path)
                local item = targets[target_path]
                if not item then
                    item = {fragments = {}, refs = 0, critical = false}
                    targets[target_path] = item
                end
                item.fragments[fragment] = true
                item.refs = item.refs + 1
                if looks_critical(attrs, href, fragment, inner) then item.critical = true end
            end
        end
    end
    return targets
end

local function id_exists_case(ids, fragment)
    if ids[fragment] then return true end
    local wanted = tostring(fragment or ""):lower()
    local match = false
    for id in pairs(ids or {}) do
        if tostring(id):lower() == wanted then
            if match then return false end
            match = true
        end
    end
    return match == true
end

local function infer_aliases(files, files_lower, targets)
    local aliases, aliases_lower, alias_stats = {}, {}, {resolved = 0, ambiguous = 0, missing = 0}
    for legacy_path, hint in pairs(targets or {}) do
        if not files[legacy_path] and not files_lower[legacy_path:lower()] then
            local best_path, best_score, tied = nil, 0, false
            for candidate_path, doc in pairs(files or {}) do
                local score = 0
                for fragment in pairs(hint.fragments or {}) do
                    if id_exists_case(doc.ids or {}, fragment) then score = score + 1 end
                end
                if score > best_score then
                    best_path, best_score, tied = candidate_path, score, false
                elseif score > 0 and score == best_score then
                    tied = true
                end
            end
            if best_path and best_score > 0 and not tied then
                aliases[legacy_path] = best_path
                aliases_lower[legacy_path:lower()] = best_path
                alias_stats.resolved = alias_stats.resolved + 1
            elseif tied then
                alias_stats.ambiguous = alias_stats.ambiguous + 1
            else
                alias_stats.missing = alias_stats.missing + 1
            end
        end
    end
    return aliases, aliases_lower, alias_stats
end

local function build_index(documents)
    local files, files_lower, anchors, anchors_lower, targets = {}, {}, {}, {}, {}
    for _, doc in ipairs(documents or {}) do
        local path = normalize_path(doc.path)
        doc.path = path
        doc.ids = collect_ids(doc.html)
        files[path] = doc
        files_lower[path:lower()] = path
        for id in pairs(doc.ids) do
            anchors[id] = anchors[id] or {}
            anchors[id][#anchors[id] + 1] = path
            local lower = id:lower()
            anchors_lower[lower] = anchors_lower[lower] or {}
            anchors_lower[lower][#anchors_lower[lower] + 1] = {path = path, id = id}
        end
    end
    for _, doc in ipairs(documents or {}) do
        collect_target_hints(doc.html, doc.path, targets)
    end
    local aliases, aliases_lower, alias_stats = infer_aliases(files, files_lower, targets)
    return files, files_lower, anchors, anchors_lower, aliases, aliases_lower, alias_stats
end

local function choose_anchor(current_path, fragment, anchors, anchors_lower)
    local exact = anchors[fragment] or {}
    for _, path in ipairs(exact) do
        if path == current_path then return path, fragment, "current" end
    end
    if #exact == 1 then return exact[1], fragment, "unique" end
    if #exact > 1 then return nil, nil, "ambiguous" end
    local lower = anchors_lower[tostring(fragment or ""):lower()] or {}
    for _, item in ipairs(lower) do
        if item.path == current_path then return item.path, item.id, "current-case" end
    end
    if #lower == 1 then return lower[1].path, lower[1].id, "unique-case" end
    if #lower > 1 then return nil, nil, "ambiguous-case" end
    return nil, nil, "missing-anchor"
end

local function resolve_link(current_path, href, attrs, inner, index)
    if href == "" or href == "#" or is_external(href) then
        return href, "ignored", false
    end
    local href_path, fragment, query, had_fragment = split_href(href)
    if is_custom_fragment(fragment) then return href, "custom", false end
    local critical = looks_critical(attrs, href, fragment, inner)
    local target_path = package_path(current_path, href_path)
    local canonical = index.files[target_path] and target_path
        or index.files_lower[target_path:lower()]
        or index.aliases[target_path]
        or index.aliases_lower[target_path:lower()]

    if canonical then
        if not had_fragment or fragment == "" then
            local rel = relative_path(current_path, canonical)
            local rewritten = rel .. query .. (had_fragment and "#" or "")
            return rewritten, rewritten ~= href and "canonical-file" or "valid", critical
        end
        local target_doc = index.files[canonical]
        if target_doc and target_doc.ids[fragment] then
            local rel = relative_path(current_path, canonical)
            local rewritten = (rel ~= "" and rel or "") .. query .. "#" .. fragment
            if rel == "" then rewritten = query .. "#" .. fragment end
            return rewritten, rewritten ~= href and "canonical" or "valid", critical
        end
        local lower_match
        if target_doc then
            for id in pairs(target_doc.ids) do
                if id:lower() == fragment:lower() then
                    if lower_match then lower_match = false; break end
                    lower_match = id
                end
            end
        end
        if lower_match then
            local rel = relative_path(current_path, canonical)
            local rewritten = (rel ~= "" and rel or "") .. query .. "#" .. lower_match
            if rel == "" then rewritten = query .. "#" .. lower_match end
            return rewritten, "canonical-case", critical
        end
    end

    if had_fragment and fragment ~= "" and href_path == "" then
        -- A fragment-only URL is scoped to the current XHTML document. Looking
        -- for the same id in other chapters can turn legal repeated footnote
        -- ids (for example wt_1) into a false package-wide ambiguity.
        return href, "missing-anchor", critical
    end

    if had_fragment and fragment ~= "" then
        local target, actual_fragment, reason = choose_anchor(current_path, fragment, index.anchors, index.anchors_lower)
        if target then
            local rel = relative_path(current_path, target)
            local rewritten = (rel ~= "" and rel or "") .. query .. "#" .. actual_fragment
            if rel == "" then rewritten = query .. "#" .. actual_fragment end
            return rewritten, reason, critical
        end
        return href, reason, critical
    end

    return href, canonical and "valid" or "missing-file", critical
end

local function rewrite_href_values(html, callback)
    local changed = false
    local function replace_double(prefix, value)
        local new_value = callback(value)
        if new_value ~= value then changed = true end
        return prefix .. '"' .. encode_href(new_value) .. '"'
    end
    local function replace_single(prefix, value)
        local new_value = callback(value)
        if new_value ~= value then changed = true end
        return prefix .. "'" .. tostring(new_value or ""):gsub("&", "&amp;"):gsub("'", "&apos;") .. "'"
    end
    html = tostring(html or ""):gsub('(<[aA][^>]-[hH][rR][eE][fF]%s*=%s*)"([^"]*)"', replace_double)
    html = html:gsub("(<[aA][^>]-[hH][rR][eE][fF]%s*=%s*)'([^']*)'", replace_single)
    return html, changed
end

function M.rewrite_documents(documents, options)
    options = options or {}
    local files, files_lower, anchors, anchors_lower, aliases, aliases_lower, alias_stats = build_index(documents)
    local index = {
        files = files, files_lower = files_lower, anchors = anchors, anchors_lower = anchors_lower,
        aliases = aliases, aliases_lower = aliases_lower,
    }
    local stats = {
        links = 0, rewritten = 0, valid = 0, ignored = 0, files_changed = 0,
        unresolved = 0, unresolved_critical = 0, unresolved_other = 0, dropped = 0,
        samples = {}, reasons = {}, aliases = alias_stats or {resolved = 0, ambiguous = 0, missing = 0},
    }

    for _, doc in ipairs(documents or {}) do
        local current_path = doc.path
        local raw = tostring(doc.html or "")
        local rewritten, changed = rewrite_href_values(raw, function(href)
            stats.links = stats.links + 1
            local new_href, reason, critical = resolve_link(current_path, decode_entities(href), "", "", index)
            stats.reasons[reason] = (stats.reasons[reason] or 0) + 1
            if reason == "ignored" or reason == "custom" then
                stats.ignored = stats.ignored + 1
            elseif reason == "missing-anchor" or reason == "missing-file"
                or reason == "ambiguous" or reason == "ambiguous-case" then
                stats.unresolved = stats.unresolved + 1
                if critical then stats.unresolved_critical = stats.unresolved_critical + 1
                else stats.unresolved_other = stats.unresolved_other + 1 end
                if #stats.samples < (tonumber(options.sample_limit) or 20) then
                    stats.samples[#stats.samples + 1] = current_path .. " -> " .. tostring(href) .. "（" .. reason .. "）"
                end
            else
                stats.valid = stats.valid + 1
                if new_href ~= decode_entities(href) then stats.rewritten = stats.rewritten + 1 end
            end
            return new_href
        end)
        doc.html = rewritten
        doc.changed = changed
    end
    return stats
end

-- Opening-tag aware variant used when numeric link text/class information is
-- needed to decide whether an unresolved link is fatal.
function M.rewrite_documents_strict(documents, options)
    options = options or {}
    local files, files_lower, anchors, anchors_lower, aliases, aliases_lower, alias_stats = build_index(documents)
    local index = {
        files = files, files_lower = files_lower, anchors = anchors, anchors_lower = anchors_lower,
        aliases = aliases, aliases_lower = aliases_lower,
    }
    local stats = {
        links = 0, rewritten = 0, valid = 0, ignored = 0,
        unresolved = 0, unresolved_critical = 0, unresolved_other = 0, dropped = 0,
        samples = {}, reasons = {}, aliases = alias_stats or {resolved = 0, ambiguous = 0, missing = 0},
    }

    local function process_tag(current_path, attrs, inner)
        local href = get_attr(attrs, "href")
        if not href then return "<a" .. attrs .. ">" .. inner .. "</a>" end
        stats.links = stats.links + 1
        local new_href, reason, critical = resolve_link(current_path, href, attrs, inner, index)
        stats.reasons[reason] = (stats.reasons[reason] or 0) + 1
        if reason == "ignored" or reason == "custom" then
            stats.ignored = stats.ignored + 1
        elseif reason == "missing-anchor" or reason == "missing-file"
            or reason == "ambiguous" or reason == "ambiguous-case" then
            stats.unresolved = stats.unresolved + 1
            if critical then stats.unresolved_critical = stats.unresolved_critical + 1
            else stats.unresolved_other = stats.unresolved_other + 1 end
            if #stats.samples < (tonumber(options.sample_limit) or 20) then
                stats.samples[#stats.samples + 1] = current_path .. " -> " .. tostring(href) .. "（" .. reason .. "）"
            end
        else
            stats.valid = stats.valid + 1
            if new_href ~= decode_entities(href) then stats.rewritten = stats.rewritten + 1 end
        end
        if (reason=="missing-anchor" or reason=="missing-file" or reason=="ambiguous" or reason=="ambiguous-case") and options.neutralize_unresolved==true then
            stats.dropped=(tonumber(stats.dropped) or 0)+1
            return "<a" .. remove_href_attr(attrs) .. ">" .. inner .. "</a>"
        end
        local escaped_old = tostring(href):gsub("([^%w])", "%%%1")
        local attr_name = "[hH][rR][eE][fF]"
        local new_attrs, count = attrs:gsub('(' .. attr_name .. '%s*=%s*)"' .. escaped_old .. '"', function(prefix)
            return prefix .. '"' .. encode_href(new_href) .. '"'
        end, 1)
        if count == 0 then
            new_attrs = attrs:gsub("(" .. attr_name .. "%s*=%s*)'" .. escaped_old .. "'", function(prefix)
                return prefix .. "'" .. tostring(new_href):gsub("&", "&amp;"):gsub("'", "&apos;") .. "'"
            end, 1)
        end
        return "<a" .. new_attrs .. ">" .. inner .. "</a>"
    end

    for _, doc in ipairs(documents or {}) do
        local raw = tostring(doc.html or "")
        local rewritten = raw:gsub("<[aA]([^>]*)>(.-)</[aA]%s*>", function(attrs, inner)
            return process_tag(doc.path, attrs, inner)
        end)
        doc.changed = rewritten ~= raw
        doc.html = rewritten
    end
    return stats
end

local function default_read_file(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local data = file:read("*a")
    file:close()
    return data
end

local function default_write_file(path, data)
    local file, err = io.open(path, "wb")
    if not file then return nil, err end
    local ok, write_err = file:write(data)
    file:close()
    if not ok then return nil, write_err end
    return true
end

local function build_file_index(entries, options)
    options = options or {}
    local read_file = options.read_file or default_read_file
    local files, files_lower, anchors, anchors_lower, targets = {}, {}, {}, {}, {}
    for _, entry in ipairs(entries or {}) do
        local path = normalize_path(entry.path)
        local raw, read_error = read_file(entry.full or entry.file or entry.source_path)
        if type(raw) ~= "string" then
            return nil, "无法读取内部链接索引文件：" .. tostring(read_error or path)
        end
        local doc = {path = path, ids = collect_ids(raw), entry = entry}
        files[path] = doc
        files_lower[path:lower()] = path
        for id in pairs(doc.ids) do
            anchors[id] = anchors[id] or {}
            anchors[id][#anchors[id] + 1] = path
            local lower = id:lower()
            anchors_lower[lower] = anchors_lower[lower] or {}
            anchors_lower[lower][#anchors_lower[lower] + 1] = {path = path, id = id}
        end
        collect_target_hints(raw, path, targets)
        raw = nil
        collectgarbage("step", 100)
    end
    local aliases, aliases_lower, alias_stats = infer_aliases(files, files_lower, targets)
    return {
        files = files, files_lower = files_lower, anchors = anchors, anchors_lower = anchors_lower,
        aliases = aliases, aliases_lower = aliases_lower, alias_stats = alias_stats,
    }
end

local function new_stats(alias_stats)
    return {
        links = 0, rewritten = 0, valid = 0, ignored = 0, files_changed = 0,
        unresolved = 0, unresolved_critical = 0, unresolved_other = 0, dropped = 0,
        samples = {}, reasons = {}, aliases = alias_stats or {resolved = 0, ambiguous = 0, missing = 0},
    }
end

local function unresolved_reason(reason)
    return reason == "missing-anchor" or reason == "missing-file"
        or reason == "ambiguous" or reason == "ambiguous-case"
end

local function rewrite_html_strict(raw, current_path, index, stats, options)
    options = options or {}
    local sample_limit = tonumber(options.sample_limit) or 20
    local rewritten = tostring(raw or ""):gsub("<[aA]([^>]*)>(.-)</[aA]%s*>", function(attrs, inner)
        local href = get_attr(attrs, "href")
        if not href then return "<a" .. attrs .. ">" .. inner .. "</a>" end
        stats.links = stats.links + 1
        local new_href, reason, critical = resolve_link(current_path, href, attrs, inner, index)
        stats.reasons[reason] = (stats.reasons[reason] or 0) + 1
        if reason == "ignored" or reason == "custom" then
            stats.ignored = stats.ignored + 1
        elseif unresolved_reason(reason) then
            stats.unresolved = stats.unresolved + 1
            if critical then stats.unresolved_critical = stats.unresolved_critical + 1
            else stats.unresolved_other = stats.unresolved_other + 1 end
            if #stats.samples < sample_limit then
                stats.samples[#stats.samples + 1] = current_path .. " -> " .. tostring(href) .. "（" .. reason .. "）"
            end
        else
            stats.valid = stats.valid + 1
            if new_href ~= decode_entities(href) then stats.rewritten = stats.rewritten + 1 end
        end
        if unresolved_reason(reason) and options.neutralize_unresolved==true then
            stats.dropped=(tonumber(stats.dropped) or 0)+1
            return "<a" .. remove_href_attr(attrs) .. ">" .. inner .. "</a>"
        end
        local escaped_old = tostring(href):gsub("([^%w])", "%%%1")
        local attr_name = "[hH][rR][eE][fF]"
        local new_attrs, count = attrs:gsub('(' .. attr_name .. '%s*=%s*)"' .. escaped_old .. '"', function(prefix)
            return prefix .. '"' .. encode_href(new_href) .. '"'
        end, 1)
        if count == 0 then
            new_attrs = attrs:gsub("(" .. attr_name .. "%s*=%s*)'" .. escaped_old .. "'", function(prefix)
                return prefix .. "'" .. tostring(new_href):gsub("&", "&amp;"):gsub("'", "&apos;") .. "'"
            end, 1)
        end
        return "<a" .. new_attrs .. ">" .. inner .. "</a>"
    end)
    return rewritten, rewritten ~= raw
end

local function cleanup_temps(entries)
    for _, entry in ipairs(entries or {}) do
        if entry._miu_link_temp then
            os.remove(entry._miu_link_temp)
            entry._miu_link_temp = nil
        end
    end
end

-- Low-memory, transactional link repair for files already stored on disk.
-- The index contains only paths and anchors; each XHTML file is read, rewritten
-- and released independently. Originals are replaced only after every critical
-- link has been resolved and the second validation pass succeeds.
function M.rewrite_files_strict(entries, options)
    options = options or {}
    local read_file = options.read_file or default_read_file
    local write_file = options.write_file or default_write_file
    local index, index_error = build_file_index(entries, options)
    if not index then return nil, index_error end
    local stats = new_stats(index.alias_stats)

    for _, entry in ipairs(entries or {}) do
        local source = entry.full or entry.file or entry.source_path
        local raw, read_error = read_file(source)
        if type(raw) ~= "string" then cleanup_temps(entries); return nil, tostring(read_error or source) end
        local current_path = normalize_path(entry.path)
        local rewritten, changed = rewrite_html_strict(raw, current_path, index, stats, options)
        if changed then
            stats.files_changed = stats.files_changed + 1
            local temp = source .. ".miuread-linkfix"
            os.remove(temp)
            local ok, write_error = write_file(temp, rewritten)
            if not ok then cleanup_temps(entries); return nil, tostring(write_error or temp) end
            entry._miu_link_temp = temp
        end
        raw, rewritten = nil, nil
        collectgarbage("step", 200)
    end

    if tonumber(stats.unresolved_critical or 0) > 0 and options.neutralize_unresolved~=true then
        cleanup_temps(entries)
        return stats, "仍有 " .. tostring(stats.unresolved_critical) .. " 个关键内部链接无效"
    end

    local verify_stats = new_stats(index.alias_stats)
    for _, entry in ipairs(entries or {}) do
        local source = entry._miu_link_temp or entry.full or entry.file or entry.source_path
        local raw, read_error = read_file(source)
        if type(raw) ~= "string" then cleanup_temps(entries); return nil, tostring(read_error or source) end
        local _, changed = rewrite_html_strict(raw, normalize_path(entry.path), index, verify_stats, options)
        raw = nil
        if changed or tonumber(verify_stats.unresolved_critical or 0) > 0 then
            cleanup_temps(entries)
            return stats, changed and "仍有可修复但尚未稳定写入的内部链接"
                or ("仍有 " .. tostring(verify_stats.unresolved_critical) .. " 个关键内部链接无效")
        end
        collectgarbage("step", 100)
    end

    for _, entry in ipairs(entries or {}) do
        local temp = entry._miu_link_temp
        if temp then
            local target = entry.full or entry.file or entry.source_path
            local backup = target .. ".miuread-linkbak"
            os.remove(backup)
            local backed = os.rename(target, backup)
            if not backed then cleanup_temps(entries); return nil, "无法保护内部链接源文件：" .. tostring(target) end
            local installed, install_error = os.rename(temp, target)
            if not installed then
                os.rename(backup, target)
                cleanup_temps(entries)
                return nil, "无法安装内部链接修复文件：" .. tostring(install_error or target)
            end
            os.remove(backup)
            entry._miu_link_temp = nil
        end
    end
    return stats, nil, verify_stats
end

function M.validate_documents(documents, options)
    options = options or {}
    local copies = {}
    for index, doc in ipairs(documents or {}) do
        copies[index] = {path = doc.path, html = doc.html}
    end
    local stats = M.rewrite_documents_strict(copies, options)
    if stats.rewritten > 0 then
        return nil, "仍有可修复但尚未改写的内部链接", stats
    end
    if stats.unresolved_critical > 0 then
        return nil, "仍有 " .. tostring(stats.unresolved_critical) .. " 个关键内部链接无效", stats
    end
    return true, nil, stats
end

M.normalize_path = normalize_path
M.relative_path = relative_path
M.collect_ids = collect_ids
M.is_custom_fragment = is_custom_fragment
M.collect_target_hints = collect_target_hints
M.infer_aliases = infer_aliases

return M
