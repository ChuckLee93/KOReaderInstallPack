local RELEASES = {
    {
        revision = "v2025.10",
        released_on = "2025-11-01",
        adapter = "release",
        adapter_name = "plugin-v2025.10",
        preedit_rects = "native",
    },
    {
        revision = "v2026.03",
        released_on = "2026-03-17",
        adapter = "release",
        adapter_name = "plugin-v2026.03",
        preedit_rects = "native",
    },
    {
        revision = "v2026.07",
        released_on = "2026-07-26",
        adapter = "release",
        adapter_name = "plugin-v2026.07",
        preedit_rects = "native",
    },
}

local MINIMUM_DYNAMIC_YEAR = 2025
local MINIMUM_DYNAMIC_MONTH = 10
local MINIMUM_DYNAMIC_RELEASE = "v2025.10"

-- Development builds retain the most recent release tag in git-describe.
-- Never infer compatibility from that tag: only commits whose UI contracts
-- were reviewed are admitted here.
local DEVELOPMENT_COMMITS = {
    ["2aa2907fa"] = "2aa2907faffaa384f09acc68a7d22b19c5aa56ed",
}

local RELEASE_BY_REVISION = {}
for _, release in ipairs(RELEASES) do
    RELEASE_BY_REVISION[release.revision] = release
end

local function copyProfile(profile)
    local copy = {}
    for key, value in pairs(profile) do
        copy[key] = value
    end
    return copy
end

local function getDevelopmentCommit(revision)
    local commit = revision:match("%-g(%x+)") or revision:match("^(%x+)$")
    if not commit then
        return nil
    end
    commit = commit:lower()
    for verified, full_commit in pairs(DEVELOPMENT_COMMITS) do
        if #commit >= #verified and full_commit:sub(1, #commit) == commit then
            return verified
        end
    end
end

local function validDateSuffix(suffix)
    local year, month, day = suffix:match(
        "^_(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    month = tonumber(month)
    day = tonumber(day)
    return year ~= nil and month >= 1 and month <= 12
        and day >= 1 and day <= 31
end

local function validDynamicSuffix(suffix)
    if suffix == "" then
        return true
    elseif suffix:sub(1, 1) == "_" then
        return validDateSuffix(suffix)
    end
    local distance, commit, date_suffix = suffix:match(
        "^%-(%d+)%-g(%x+)(.*)$")
    if not distance or #commit < 7 then
        return false
    end
    return date_suffix == "" or validDateSuffix(date_suffix)
end

local function parseRevision(revision)
    if type(revision) ~= "string" or revision == "" then
        return nil, "KOReader revision is missing"
    end

    local year, month, point, suffix = revision:match(
        "^v(%d%d%d%d)%.(%d%d)%.(%d+)(.*)$")
    if not year then
        year, month, suffix = revision:match(
            "^v(%d%d%d%d)%.(%d%d)(.*)$")
    end
    year = tonumber(year)
    month = tonumber(month)
    if not year or not month or month < 1 or month > 12 then
        return nil, "Unrecognized KOReader revision: " .. revision
    end
    if not validDynamicSuffix(suffix) then
        return nil, "Unrecognized KOReader revision: " .. revision
    end
    if year < MINIMUM_DYNAMIC_YEAR
            or year == MINIMUM_DYNAMIC_YEAR and month < MINIMUM_DYNAMIC_MONTH then
        return nil, "KOReader version is older than "
            .. MINIMUM_DYNAMIC_RELEASE .. ": " .. revision
    end
    return {
        year = year,
        month = month,
        point = point ~= "" and tonumber(point) or nil,
        base_release = string.format("v%04d.%02d", year, month),
    }
end

local Compatibility = {}

function Compatibility.resolve(revision)
    if type(revision) ~= "string" then
        return nil, "KOReader revision is missing"
    end

    local release = RELEASE_BY_REVISION[revision]
    if release then
        local profile = copyProfile(release)
        profile.release_tag = release.revision
        profile.admission = "verified_release"
        return profile
    end

    local development_commit = getDevelopmentCommit(revision)
    if development_commit then
        return {
            revision = revision,
            development_commit = development_commit,
            adapter = "release",
            adapter_name = "plugin-current",
            preedit_rects = "native",
            admission = "verified_commit",
        }
    end

    local parsed, reason = parseRevision(revision)
    if not parsed then
        return nil, reason
    end
    return {
        revision = revision,
        base_release = parsed.base_release,
        adapter = "release",
        adapter_name = "plugin-runtime-probe",
        preedit_rects = "native",
        admission = "runtime_probe",
    }
end

function Compatibility.listReleases()
    local releases = {}
    for index, release in ipairs(RELEASES) do
        releases[index] = copyProfile(release)
        releases[index].release_tag = release.revision
        releases[index].admission = "verified_release"
    end
    return releases
end

return Compatibility
