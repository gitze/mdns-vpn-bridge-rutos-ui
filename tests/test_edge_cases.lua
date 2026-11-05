-- Isolated duration-boundary and restart-failure regressions.
local f = dofile((arg[0]:match('^(.*[/])') or '') .. 'support.lua')
local bridge = f.load(assert(arg[1]))
local stats = bridge.section_obj.options.stats

-- Bare nonzero duration must be rejected; "0"/"0s" and unit-qualified values
-- accepted. The validator returns the native second value (user message).
assert(not stats.validate(stats, '3000'), 'bare nonzero duration accepted')
local _, msg = stats.validate(stats, '3000')
assert(type(msg) == 'string' and msg:match('requires a unit'), 'missing native message')
for _, value in ipairs({ '0', '0s', '3000s', '5m', '1h' }) do
	assert(stats.validate(stats, value), 'valid duration rejected: ' .. value)
end

-- Regression: the real firmware rc.init reply carries NO data blob, only a ubus
-- status. A nil-data success must be reported as success, not a false HTTP 422.
f.reset()
local ok = bridge:RestartAction()
assert(ok and ok.success and ok.data.restarted == '1' and ok.data.enabled == '1',
	'nil-data rc.init success misreported as failure')
assert(bridge.last_error == nil, 'success must not record an error')

-- Restart failure paths must not report success and must surface a real,
-- message-bearing HTTP 500 error (not a bare 422 with no message).
for _, fault in ipairs({ 'rpc_fail', 'no_change', 'state_fail' }) do
	f.reset(); f[fault] = true
	bridge.last_error = nil
	local r = bridge:RestartAction()
	assert(r == nil, fault .. ' returned a success response')
	assert(bridge.last_error and bridge.last_error.http_status == 500,
		fault .. ' must surface an HTTP 500 error')
	assert(type(bridge.last_error.message) == 'string' and #bridge.last_error.message > 0,
		fault .. ' must carry a non-empty message')
end
f.reset(); f.rpc_code = 1
bridge.last_error = nil
assert(bridge:RestartAction() == nil, 'RPC error result ignored')
assert(bridge.last_error and bridge.last_error.http_status == 500, 'RPC error not surfaced')

-- Disabled restart issues no RPC.
f.reset(); f.config.enabled = '0'
local skipped = bridge:RestartAction()
assert(skipped.success and skipped.data.restarted == '0' and #f.rpcs == 0)

print('PASS: duration units/zero, native validator message and restart success/failure/disabled handling')
