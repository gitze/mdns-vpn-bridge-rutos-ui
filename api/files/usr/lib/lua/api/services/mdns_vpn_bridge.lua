-- RutOS API service for the mdns-vpn-bridge WebUI plugin.
--
--   GET  /api/mdns_vpn_bridge_f/config       UCI config resource (data array)
--   PUT  /api/mdns_vpn_bridge_f/config       {"data":[{...}]}   (general section; each element MUST carry the server-returned id)
--   GET  /api/mdns_vpn_bridge_f/status       relay state from the local status endpoint
--   GET  /api/mdns_vpn_bridge_f/interfaces   eligible LAN interfaces
--   POST /api/mdns_vpn_bridge_f/actions/restart   privileged rc.init restart
--
-- Configuration writes go through the native ConfigService path: tracked UCI
-- change -> framework commit -> service.event "config.change" -> procd reload
-- trigger of the relay init script. There is no shell-based transaction engine.
-- The explicit restart action uses the privileged rc RPC
-- (uhttpd -> rc.init -> rc plugin worker -> /etc/init.d/mdns-vpn-bridge), never
-- a direct init execution from the unprivileged HTTP worker.
--
-- The relay UCI layout (owned by the relay package) is:
--   config mdns-vpn-bridge 'main'
--     option enabled|lan_if|peer|peerport|lan2peer|peer2lan|services|stats|status_addr
-- Only the editable options are declared here; status_addr is left untouched.

local ConfigService = require("api/ConfigService")
local util = require("vuci.util")

-- Native standard error codes and HTTP status table (factory modules). The
-- framework exposes STD_CODES as a global after loading api/standard_codes;
-- api/http_codes returns the HTTP status table. Keep a defensive fallback so a
-- missing global cannot turn a real error into a Lua exception.
require("api/standard_codes")
local STD = (type(STD_CODES) == "table" and STD_CODES) or { CODE_ERROR = 999, INVALID_OPT = 103 }
local HSC = require("api/http_codes").status

local CONFIG = "mdns-vpn-bridge"
local SECTION = "main"
local STATUS_URL = "http://127.0.0.1:53531/_status"

local Bridge = ConfigService:new({
	create = false,
	delete = false,
	-- Single general section, matching the installed Tailscale/DDNS idiom.
	-- NOTE: a general section is NOT a "singular" request. The native PUT
	-- validator (api/put_logic `_PUT_validate_id`) still requires every element
	-- of the PUT data array to carry the resource id returned by GET /config
	-- (the general section resolves to id "general"). Omitting the id yields
	-- HTTP 422 "'id' is required.". The UI echoes the server-returned id.
	general_section = SECTION,
})

local Config = Bridge:section(CONFIG, CONFIG)

------------------------------------------------------------------- validators

local function is_ipv4(value)
	local a, b, c, d = value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then
		return false
	end
	for _, n in ipairs({ a, b, c, d }) do
		if tonumber(n) > 255 then
			return false
		end
	end
	return true
end

-- Boolean options use the native data-type helper (accepts "0"/"1").
local function validate_enabled(self, value)
	return self.dt:is_bool(value)
end

local function validate_lan_if(self, value)
	return value:match("^[%w%._%-]+$") ~= nil
end

-- Peer may be empty (relay refuses to start) or an IPv4 address.
local function validate_peer(self, value)
	return value == "" or is_ipv4(value)
end

local function validate_peerport(self, value)
	local n = tonumber(value)
	return n ~= nil and n == math.floor(n) and n >= 1 and n <= 65535
end

local function validate_filter(self, value)
	return value == "query" or value == "all"
end

local function validate_services(self, value)
	return value:match("^[%w_%,%-%._]*$") ~= nil
end

-- "0"/"0s" disable summaries; a nonzero interval must carry a unit (s, m or h).
-- The native option validator contract (SDK function_example) allows a second
-- return value: a message shown to the user for a rejected value.
local STATS_MESSAGE = "Stats interval requires a unit: use 300s, 5m or 1h; use 0 to disable summaries."
local function validate_stats(self, value)
	if value == "0" or value == "0s" or value:match("^%d+[smh]$") ~= nil then
		return true
	end
	return false, STATS_MESSAGE
end

local OPTIONS = {
	{ name = "enabled", maxlength = 1, validate = validate_enabled },
	{ name = "lan_if", maxlength = 64, validate = validate_lan_if },
	{ name = "peer", maxlength = 15, validate = validate_peer },
	{ name = "peerport", maxlength = 5, validate = validate_peerport },
	{ name = "lan2peer", maxlength = 8, validate = validate_filter },
	{ name = "peer2lan", maxlength = 8, validate = validate_filter },
	{ name = "services", maxlength = 128, validate = validate_services },
	{ name = "stats", maxlength = 16, validate = validate_stats },
}

for _, spec in ipairs(OPTIONS) do
	local opt = Config:option(spec.name)
	opt.maxlength = spec.maxlength
	opt.validate = spec.validate
end

------------------------------------------------------------ service helpers

-- PIDs of every running relay instance, "" when stopped, nil on read failure.
local function service_state()
	local reply = util.ubus("service", "list", { name = CONFIG })
	if type(reply) ~= "table" then
		return nil
	end
	local pids = {}
	for _, instance in pairs((reply[CONFIG] or {}).instances or {}) do
		if instance.running then
			if not instance.pid then
				return nil
			end
			pids[#pids + 1] = tostring(instance.pid)
		end
	end
	table.sort(pids)
	return table.concat(pids, ",")
end

-- Invoke a fixed, allow-listed action on the fixed service through rc.init.
--
-- util.ubus returns (data, status). rc.init returns NO data blob: the rpcd rc
-- plugin replies with an init-script exit status only, so the data slot is nil
-- and success is signalled by a nil/zero ubus status (verified on RutOS 7.25.3:
-- a rejected action yields (nil, 2)). Treating a non-table reply as failure (as
-- an earlier revision did) reports a false error for a restart that actually
-- ran, producing HTTP 422 with no message.
local function init_action(action)
	local reply, status = util.ubus("rc", "init", { name = CONFIG, action = action })
	if status ~= nil and tonumber(status) ~= 0 then
		return false, string.format("rc.init %s failed (ubus status %s)", action, tostring(status))
	end
	if type(reply) == "table" then
		local code = tonumber(reply.code or reply.result or reply.exit_code)
		if code ~= nil and code ~= 0 then
			return false, string.format("rc.init %s returned code %s", action, tostring(code))
		end
	end
	return true
end

local function sh(command)
	local f = io.popen(command)
	if not f then
		return ""
	end
	local out = f:read("*a") or ""
	f:close()
	return out
end

-- Emit a real, message-bearing error. ResponseError() alone defaults to a bare
-- HTTP 422 with a generic "incorrect request" body and no message (verified on
-- RutOS 7.25.3); add_critical_error carries the message, source and an explicit
-- HTTP status. It yields the response immediately, so callers must return
-- without building a second response.
local function fail(self, message, source)
	self:add_critical_error(STD.CODE_ERROR, message, source, HSC.INTERNAL_SERVER_ERROR)
end

----------------------------------------------------------------- GET routes

-- GET /api/mdns_vpn_bridge_f/status
function Bridge:GET_TYPE_status()
	local raw = sh("wget -q -T 2 -O - " .. STATUS_URL .. " 2>/dev/null")
	local running = raw:match('"peer_port"') ~= nil

	local function num(pattern)
		return raw:match(pattern) or ""
	end

	local uptime = num('"uptime_seconds":([%d%.]+)')
	local up_txt = "-"
	if uptime ~= "" then
		local secs = math.floor(tonumber(uptime) or 0)
		if secs < 60 then
			up_txt = string.format("%ds", secs)
		elseif secs < 3600 then
			up_txt = string.format("%dm%02ds", math.floor(secs / 60), secs % 60)
		else
			up_txt = string.format("%dh%02dm", math.floor(secs / 3600), math.floor(secs / 60) % 60)
		end
	end

	local function side(section)
		local p, b, d = raw:match('"' .. section .. '":{"packets":(%d+),"bytes":(%d+),"dropped":(%d+)}')
		if not p then
			return "-"
		end
		return string.format("%s packets / %s B (dropped %s)", p, b, d)
	end

	-- Native read of the committed UCI value through the config wrapper.
	local enabled = self:table_get(self.config, SECTION, "enabled")
	if enabled == nil or enabled == "" then
		enabled = "1"
	end

	return self:ResponseOK({
		running = running and "1" or "0",
		enabled = enabled,
		lan_if = num('"lan_if":"([^"]*)"'),
		lan_ip = num('"lan_ip":"([^"]*)"'),
		peer = num('"peer":"([^"]*)"'),
		peer_port = num('"peer_port":(%d+)'),
		lan2peer = num('"lan2peer":"([^"]*)"'),
		peer2lan = num('"peer2lan":"([^"]*)"'),
		uptime = up_txt,
		to_peer = side("to_peer"),
		to_lan = side("to_lan"),
	})
end

-- GET /api/mdns_vpn_bridge_f/interfaces
function Bridge:GET_TYPE_interfaces()
	local eligible = {}
	for line in sh("ip -o link show"):gmatch("[^\n]+") do
		local name, flags = line:match("^%d+:%s+([^:]+):%s+<([^>]+)>")
		if name and flags:find("MULTICAST", 1, true)
			and flags:find("BROADCAST", 1, true)
			and not flags:find("POINTOPOINT", 1, true) then
			eligible[name:match("^[^@]+") or name] = true
		end
	end
	local interfaces, seen = {}, {}
	for line in sh("ip -o -4 addr show"):gmatch("[^\n]+") do
		local name, address = line:match("^%d+:%s+(%S+)%s+inet%s+([%d%.]+)/")
		if name then
			name = name:match("^[^@]+") or name
		end
		if name and eligible[name] and not seen[name] then
			interfaces[#interfaces + 1] = { name = name, address = address }
			seen[name] = true
		end
	end
	table.sort(interfaces, function(a, b)
		return a.name < b.name
	end)
	return self:ResponseOK({ interfaces = interfaces })
end

------------------------------------------------------------------- actions

-- POST /api/mdns_vpn_bridge_f/actions/restart
function Bridge:RestartAction()
	local enabled = self:table_get(self.config, SECTION, "enabled") or "1"
	-- A restart must not enable a persistently disabled service.
	if enabled ~= "1" then
		return self:ResponseOK({ restarted = "0", enabled = "0" })
	end
	local before = service_state()
	if before == nil then
		fail(self, "Cannot read the relay service state.", "service")
		return
	end
	local ok, why = init_action("restart")
	if not ok then
		fail(self, "Service restart failed: " .. why, "service")
		return
	end
	-- rc.init only reports the init script exit status; confirm the process
	-- actually changed before reporting success.
	for _ = 1, 20 do
		local after = service_state()
		if after ~= nil and after ~= "" and after ~= before then
			return self:ResponseOK({ restarted = "1", enabled = "1" })
		end
		require("nixio").nanosleep(0, 500000000)
	end
	fail(self, "Service restart timed out; the relay did not restart.", "service")
	return
end

Bridge:action("restart", Bridge.RestartAction)

return Bridge
