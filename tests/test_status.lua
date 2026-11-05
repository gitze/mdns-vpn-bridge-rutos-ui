-- Isolated status parser test: mocks the local relay endpoint, no network.
local f = dofile((arg[0]:match('^(.*[/])') or '') .. 'support.lua')
local raw = [[
{"peer_port":53530,"lan_if":"br-lan","lan_ip":"192.0.2.2","peer":"100.64.0.1","lan2peer":"all","peer2lan":"query","uptime_seconds":3725,"to_peer":{"packets":10,"bytes":2048,"dropped":1},"to_lan":{"packets":7,"bytes":1024,"dropped":0}}
]]
io.popen = function(command)
	assert(command:find('_status', 1, true), 'unexpected command: ' .. command)
	return { read = function() return raw end, close = function() return true end }
end
local bridge = f.load(assert(arg[1]))
local s = bridge:GET_TYPE_status().data
assert(s.running == '1')
assert(s.lan_if == 'br-lan' and s.lan_ip == '192.0.2.2')
assert(s.peer == '100.64.0.1' and s.peer_port == '53530')
assert(s.lan2peer == 'all' and s.peer2lan == 'query')
assert(s.uptime == '1h02m', 'uptime: ' .. s.uptime)
assert(s.to_peer == '10 packets / 2048 B (dropped 1)')
assert(s.to_lan == '7 packets / 1024 B (dropped 0)')
assert(s.enabled == '1')

-- Stopped relay: empty body must not be reported as running.
io.popen = function() return { read = function() return '' end, close = function() return true end } end
local stopped = bridge:GET_TYPE_status().data
assert(stopped.running == '0' and stopped.uptime == '-' and stopped.to_peer == '-')
print('PASS: status parsing, uptime formatting, counters and stopped state')
