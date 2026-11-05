-- Isolated fixture: mocks api/ConfigService and vuci.util and records the
-- declared schema. It never touches UCI, RPC, init scripts or the network.
--
-- The ubus mock mirrors the real RutOS 7.25.3 reply shapes:
--   * service list  -> (table, nil)
--   * rc init       -> (nil, status): NO data blob; a nil/zero ubus status is
--                      success, a non-zero status is failure. This is the shape
--                      that the false-HTTP-422 restart bug mishandled.
local f = {}

local function fresh_config()
	return {
		enabled = "1", lan_if = "br-lan", peer = "100.64.0.1", peerport = "53530",
		lan2peer = "all", peer2lan = "all", services = "", stats = "300s",
	}
end

function f.reset()
	f.config = fresh_config()
	f.pid, f.rpcs, f.sleeps = 11, {}, 0
	f.rpc_fail, f.rpc_code, f.no_change, f.state_fail = false, nil, false, false
end
f.reset()

-- Minimal data-type helper matching the native option `dt` surface.
local DT = { is_bool = function(_, value) return value == "0" or value == "1" end }

local ConfigService = {}
ConfigService.__index = ConfigService

function ConfigService:new(opts)
	return setmetatable({ _opts = opts or {}, options = {}, actions = {} }, ConfigService)
end

function ConfigService:section(config, section_type)
	local s = { config = config, section_type = section_type, options = {}, primary = false }
	s.dt = DT
	function s:make_primary() s.primary = true end
	function s:option(name)
		local o = { name = name, dt = DT }
		s.options[name] = o
		return o
	end
	self.config = config
	self.section_obj = s
	return s
end

function ConfigService:action(name, handler)
	self.actions[name] = handler
	return { option = function() return {} end }
end

function ConfigService:ResponseOK(data) return { success = true, data = data } end
function ConfigService:ResponseError() return { success = false, errors = self._errors } end
-- Native add_critical_error(code, message, source, http_status) yields the
-- response; record it so isolated tests can assert the surfaced error.
function ConfigService:add_critical_error(code, message, source, http_status)
	self.last_error = { code = code, message = message, source = source, http_status = http_status }
end
function ConfigService:add_error(code, message, source) self._errors = { code = code, message = message, source = source } end
function ConfigService:table_get(config, sid, opt) return f.config[opt] end

package.preload["api/ConfigService"] = function() return ConfigService end

-- Native standard codes / HTTP status table used by the service for its
-- message-bearing errors (mirrors the factory modules' shapes).
package.preload["api/standard_codes"] = function()
	STD_CODES = { OK = 0, CODE_ERROR = 999, INVALID_OPT = 103, INCORRECT_REQUEST = 122 }
	return true
end
package.preload["api/http_codes"] = function()
	return { status = { INTERNAL_SERVER_ERROR = 500, UNPROCESSABLE_ENTITY = 422, BAD_REQUEST = 400 } }
end


package.preload["vuci.util"] = function()
	return {
		ubus = function(object, method, args)
			assert(args and args.name == "mdns-vpn-bridge", "wrong RPC service")
			if object == "service" then
				assert(method == "list", "unexpected service method")
				if f.state_fail then return nil, 6 end
				return { ["mdns-vpn-bridge"] = { instances = f.pid
					and { instance1 = { running = true, pid = f.pid } } or {} } }
			end
			assert(object == "rc" and method == "init", "unexpected RPC object")
			f.rpcs[#f.rpcs + 1] = args.action
			if f.rpc_fail then return nil, 6 end
			if f.rpc_code then return { code = f.rpc_code } end
			if not f.no_change then f.pid = (f.pid or 0) + 1 end
			-- rc.init returns no data blob on success (real firmware).
			return nil
		end,
	}
end

package.preload["nixio"] = function()
	return { nanosleep = function() f.sleeps = f.sleeps + 1 end }
end

function f.load(path)
	f.bridge = dofile(path)
	return f.bridge
end

return f
