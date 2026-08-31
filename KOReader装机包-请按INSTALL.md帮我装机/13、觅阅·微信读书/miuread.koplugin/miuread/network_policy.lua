local Config = require("miuread.config")
local U = require("miuread.util")
local logger = require("logger")

local NetworkPolicy = {}
NetworkPolicy.__index = NetworkPolicy

local function normalize_mode(value)
    return tostring(value or "auto") == "ipv4" and "ipv4" or "auto"
end

local function median(values)
    local sorted = {}
    for i, value in ipairs(values or {}) do sorted[i] = tonumber(value) or 0 end
    table.sort(sorted)
    local count = #sorted
    if count == 0 then return nil end
    if count % 2 == 1 then return sorted[(count + 1) / 2] end
    return (sorted[count / 2] + sorted[count / 2 + 1]) / 2
end

function NetworkPolicy:new(options)
    options = options or {}
    return setmetatable({
        mode = normalize_mode(options.mode),
        mode_path = tostring(options.mode_path or ""),
        samples = {},
        observed = 0,
        ignored = 0,
        probe_attempted = false,
        suggestion_sent = false,
    }, self)
end

function NetworkPolicy:ipv4_available(socket_module)
    return type(socket_module) == "table" and type(socket_module.tcp4) == "function"
end

function NetworkPolicy:_read_control_marker()
    if self.mode_path == "" then return nil, false end
    local raw = U.read_file(self.mode_path, true)
    if not raw then return nil, false end
    local value = tostring(raw):match("^%s*([%w_%-]+)")
    if not value then return nil, false end
    return normalize_mode(value), value == "auto_silent"
end

function NetworkPolicy:current_mode()
    local marked,silent = self:_read_control_marker()
    if marked then self.mode = marked end
    self.suggestion_suppressed = silent == true
    return self.mode
end

function NetworkPolicy:set_mode(mode)
    self.mode = normalize_mode(mode)
    return self.mode
end

function NetworkPolicy:should_force_ipv4()
    return self:current_mode() == "ipv4"
end

function NetworkPolicy:observe(delay_seconds)
    if self:current_mode() ~= "auto" or self.suggestion_suppressed or self.probe_attempted then return nil end
    local delay = tonumber(delay_seconds)
    if not delay or delay < 0 then return nil end

    self.observed = self.observed + 1
    local ignore_count = math.max(0, tonumber(Config.DOWNLOAD_NETWORK_IGNORE_INITIAL_REQUESTS) or 1)
    if self.ignored < ignore_count then
        self.ignored = self.ignored + 1
        return nil
    end

    local window = math.max(2, tonumber(Config.DOWNLOAD_NETWORK_SAMPLE_WINDOW) or 4)
    self.samples[#self.samples + 1] = delay
    while #self.samples > window do table.remove(self.samples, 1) end
    if #self.samples < window then return nil end

    local threshold = tonumber(Config.DOWNLOAD_NETWORK_SLOW_RESPONSE_SECONDS) or 3
    local required = math.max(1, tonumber(Config.DOWNLOAD_NETWORK_SLOW_REQUIRED) or 3)
    local slow = 0
    for _, value in ipairs(self.samples) do
        if tonumber(value) and value > threshold then slow = slow + 1 end
    end
    if slow < required then return nil end

    self.probe_attempted = true
    local baseline = median(self.samples) or 0
    logger.info("[MiuRead][NetworkPolicy] slow download path detected",
        "slow=", tostring(slow), "window=", tostring(#self.samples),
        "baseline=", string.format("%.3f", baseline))
    return {
        baseline = baseline,
        slow_count = slow,
        samples = self.samples,
    }
end

function NetworkPolicy:probe_is_promising(auto_seconds, ipv4_seconds)
    local auto = tonumber(auto_seconds)
    local ipv4 = tonumber(ipv4_seconds)
    if not auto or not ipv4 or auto <= 0 or ipv4 < 0 then return false end
    local minimum_auto = tonumber(Config.DOWNLOAD_NETWORK_PROBE_AUTO_MIN_SECONDS) or 2
    local ratio = tonumber(Config.DOWNLOAD_NETWORK_IPV4_MAX_RATIO) or 0.50
    local minimum_gain = tonumber(Config.DOWNLOAD_NETWORK_IPV4_MIN_GAIN_SECONDS) or 1
    return auto >= minimum_auto
        and ipv4 <= auto * ratio
        and (auto - ipv4) >= minimum_gain
end

function NetworkPolicy:confirm_probes(auto_values, ipv4_values)
    if type(auto_values) ~= "table" or type(ipv4_values) ~= "table"
        or #auto_values < 2 or #ipv4_values < 2 then return nil end
    for index = 1, 2 do
        if not self:probe_is_promising(auto_values[index], ipv4_values[index]) then return nil end
    end
    local auto = median(auto_values)
    local ipv4 = median(ipv4_values)
    if not auto or not ipv4 or not self:probe_is_promising(auto, ipv4) then return nil end
    if self.suggestion_sent then return nil end
    self.suggestion_sent = true
    local gain = auto - ipv4
    logger.info("[MiuRead][NetworkPolicy] IPv4 confirmed faster",
        "auto=", string.format("%.3f", auto),
        "ipv4=", string.format("%.3f", ipv4),
        "gain=", string.format("%.3f", gain))
    return {
        auto_seconds = auto,
        ipv4_seconds = ipv4,
        gain_seconds = gain,
        ratio = auto > 0 and (ipv4 / auto) or 1,
    }
end

NetworkPolicy.normalize_mode = normalize_mode

return NetworkPolicy
