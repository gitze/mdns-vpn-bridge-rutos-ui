-- Native PUT id-gate contract test.
--
-- This is NOT a mock. It loads the REAL firmware module `api/put_logic.lua`
-- (LuaJIT bytecode) and drives its `PUT_delegator` / `_PUT_validate_id` with a
-- mocked request context (mutating side effects stubbed). It proves the native
-- rule that made Save & Apply fail with HTTP 422 "'id' is required.":
--
--   * a PUT data element WITHOUT a string id  -> "'id' is required."
--   * a PUT data element WITH the server id    -> passes the id gate
--
-- It requires a LuaJIT whose bytecode format matches the target firmware
-- (the router's own /usr/bin/luajit is the canonical runner) and the native
-- Lua root that contains api/put_logic.lua. Run it via `make test-native`
-- with NATIVE_API_DIR (and optionally NATIVE_LUAJIT) set, e.g. against an
-- extracted firmware rootfs or over SSH against a router.
--
--   NATIVE_LUAJIT=/usr/bin/luajit NATIVE_API_DIR=/usr/lib/lua make test-native
--
-- Usage: <luajit> native_put_id_gate.lua <native-lua-root>
-- Exits 0 on pass or a clean skip; 1 on a real assertion failure.

local root = arg and arg[1]
if not root or root == "" then
	io.stderr:write("usage: luajit native_put_id_gate.lua <native-lua-root>\n")
	os.exit(2)
end

package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

-- Real code tables used by the validator to build its error messages.
pcall(require, "api/standard_codes")
pcall(require, "api/http_codes")

-- `api/put_logic` declares a `vuci.uci` dependency it does not use for the id
-- gate (vuci is a C module on the router). Provide an empty stand-in when the
-- full native runtime is unavailable so the real gate bytecode can still load.
local function ensure_stub(mod)
	if pcall(require, mod) then
		return
	end
	package.loaded[mod] = nil -- clear the failed-require sentinel
	package.preload[mod] = function() return {} end
end
ensure_stub("vuci")
ensure_stub("vuci.uci")

-- `api/api_utils` is used by the delegator only for the structural array/empty
-- checks; its helpers are colon methods `(self, t)` that rely on the router's C
-- `vuci`. On a full runtime the real module is used; in a partial environment
-- (extracted rootfs) supply faithful equivalents so the REAL id gate can still
-- be exercised.
local function ensure_api_utils()
	local ok, au = pcall(require, "api/api_utils")
	if ok and type(au) == "table"
		and pcall(au.is_array, au, { 1 }) and pcall(au.is_table_empty, au, {}) then
		return
	end
	package.loaded["api/api_utils"] = nil
	package.preload["api/api_utils"] = function()
		local M = {}
		function M.is_array(self, t)
			local n = 0
			for k in pairs(t) do
				if type(k) ~= "number" then return false end
				n = n + 1
			end
			for i = 1, n do
				if t[i] == nil then return false end
			end
			return n > 0
		end
		function M.is_table_empty(self, t) return next(t) == nil end
		return M
	end
end
ensure_api_utils()

local ok, put_logic = pcall(require, "api/put_logic")
if not ok then
	io.stderr:write("SKIP: cannot load native api/put_logic.lua from " .. root .. ": " .. tostring(put_logic) .. "\n")
	io.stderr:write("      (use a LuaJIT bytecode-compatible with the target firmware, e.g. the router's luajit)\n")
	os.exit(0)
end
if type(put_logic) ~= "table" or type(put_logic.PUT_delegator) ~= "function"
	or type(put_logic._PUT_validate_id) ~= "function" or type(put_logic._PUT_check_id) ~= "function" then
	io.stderr:write("FAIL: native api/put_logic.lua did not expose the expected id-gate functions\n")
	os.exit(1)
end

local function make_self(data, flags, single)
	local s
	s = {
		arguments = { data = data },
		flags = flags or {},
		sid = nil,
		_single = single,
		errors = {},
		add_critical_error = function(self, code, msg, field)
			self.errors[#self.errors + 1] = { code = code, msg = msg, field = field }
		end,
		array_error = function() end,
		PUT_section_logic = function() s.section_logic_called = true end,
		_PUT_check_id = put_logic._PUT_check_id,
		_PUT_validate_id = put_logic._PUT_validate_id,
	}
	return s
end

local failures = 0
local function check(cond, msg)
	if not cond then
		failures = failures + 1
		io.stderr:write("FAIL: " .. msg .. "\n")
	end
end

-- A general-section service request: no sid in the URL => the dispatcher sets
-- _single = false and there is no global_settings flag (this is the real path
-- for mdns-vpn-bridge, whose general_section is "main").
local function delegator(data)
	local s = make_self(data, {}, nil)
	pcall(put_logic.PUT_delegator, s)
	return s
end

local OLD = { { enabled = "1", lan_if = "br-lan", peer = "198.51.100.1", peerport = "53530",
	lan2peer = "all", peer2lan = "all", services = "", stats = "300s" } }
local NEW = { { id = "general", enabled = "1", lan_if = "br-lan", peer = "198.51.100.1", peerport = "53530",
	lan2peer = "all", peer2lan = "all", services = "", stats = "300s" } }

local old_s = delegator(OLD)
check(#old_s.errors == 1, "old payload (no id) must yield exactly one error")
check(old_s.errors[1] and old_s.errors[1].msg == "'id' is required.",
	"old payload must be rejected with \"'id' is required.\"")
check(old_s.errors[1] and old_s.errors[1].field == "id", "id error must be attributed to field 'id'")

local new_s = delegator(NEW)
check(#new_s.errors == 0, "new payload (id='general') must pass the id gate")
check(new_s.sid == "general", "resolved sid must be the server-returned id")

-- Direct gate behaviour.
local function validate(id)
	local s = make_self({}, {})
	pcall(put_logic._PUT_validate_id, s, id)
	return s
end
check(#validate("general").errors == 0, "_PUT_validate_id accepts a string id")
check(validate(nil).errors[1] and validate(nil).errors[1].msg == "'id' is required.",
	"_PUT_validate_id rejects a missing id")
check(validate("").errors[1] and validate("").errors[1].msg == "'id' is required.",
	"_PUT_validate_id rejects an empty id")
check(validate(123).errors[1] and validate(123).errors[1].msg:match("incorrect format"),
	"_PUT_validate_id rejects a non-string id")

-- The singular gate is the opposite rule and only applies to global_settings
-- (not to a general_section), which is why the fix is to SEND the id.
local sing = make_self({}, {})
sing.current_data_block = { id = "general" }
pcall(put_logic._PUT_check_id, sing)
check(sing.errors[1] and sing.errors[1].msg == "'id' is not accepted for a singular configuration request.",
	"singular gate rejects an id (proves general_section is not singular)")

if failures > 0 then
	io.stderr:write("native PUT id-gate: " .. failures .. " failure(s)\n")
	os.exit(1)
end
print("PASS: native PUT id-gate (real api/put_logic bytecode): no id -> 422 \"'id' is required.\"; server id -> passes")
