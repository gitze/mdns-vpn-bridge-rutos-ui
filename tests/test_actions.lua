-- Isolated config-schema and restart tests. No UCI, RPC or network changes.
local f = dofile((arg[0]:match('^(.*[/])') or '') .. 'support.lua')
local bridge = f.load(assert(arg[1], 'provide Lua service path'))

-- The service must be a ConfigService with a primary section and declared options.
local section = bridge.section_obj
assert(section, 'no section declared')
assert(section.config == 'mdns-vpn-bridge', 'wrong UCI config name')
assert(bridge._opts.general_section == 'main', 'general section not declared')
assert(bridge.actions.restart, 'restart action not registered')

local names = {}
for name in pairs(section.options) do names[#names + 1] = name end
table.sort(names)
assert(table.concat(names, ',') == 'enabled,lan2peer,lan_if,peer,peer2lan,peerport,services,stats',
	'declared options: ' .. table.concat(names, ','))

local function valid(name, value)
	local opt = section.options[name]
	return opt.validate(opt, value)
end

-- enabled: native boolean type ("0"/"1").
assert(valid('enabled', '0') and valid('enabled', '1'))
assert(not valid('enabled', 'yes') and not valid('enabled', '2'))

-- lan_if: UCI name characters only.
assert(valid('lan_if', 'br-lan') and valid('lan_if', 'vlan10') and valid('lan_if', 'eth0.1'))
assert(not valid('lan_if', 'br lan') and not valid('lan_if', 'a/b'))

-- peer: empty or IPv4.
assert(valid('peer', '') and valid('peer', '100.64.0.1'))
assert(not valid('peer', '256.0.0.1') and not valid('peer', 'host') and not valid('peer', '1.2.3'))

-- peerport: integer 1..65535.
assert(valid('peerport', '1') and valid('peerport', '53530') and valid('peerport', '65535'))
assert(not valid('peerport', '0') and not valid('peerport', '65536') and not valid('peerport', 'abc'))

-- filters.
assert(valid('lan2peer', 'query') and valid('peer2lan', 'all'))
assert(not valid('lan2peer', 'some') and not valid('peer2lan', 'ALL'))

-- services: optional comma list.
assert(valid('services', '') and valid('services', '_http,_esphomelib,_ipp'))
assert(not valid('services', 'a b') and not valid('services', 'a/b'))

-- stats: "0"/"0s" or a unit-qualified duration.
assert(valid('stats', '0') and valid('stats', '0s') and valid('stats', '300s'))
assert(valid('stats', '5m') and valid('stats', '1h'))
assert(not valid('stats', '3000') and not valid('stats', 'x') and not valid('stats', '5'))
assert(not valid('stats', ''))

-- The native option validator contract (SDK function_example) allows a second
-- return value: the message shown to the user for a rejected value.
local stats = section.options.stats
local ok_stats, stats_msg = stats.validate(stats, '3000')
assert(ok_stats == false, 'bare nonzero duration accepted')
assert(type(stats_msg) == 'string' and stats_msg:match('requires a unit'),
	'stats validator must return the native user-facing message')
assert(stats.validate(stats, '300s') == true, 'valid duration rejected')
assert(stats.validate(stats, '0') == true and stats.validate(stats, '0s') == true)

-- Restart goes through rc.init and verifies the process actually changed. The
-- mock replies (nil, nil) for rc.init success, matching the real firmware shape.
f.reset()
local ok = bridge:RestartAction()
assert(ok.success and ok.data.restarted == '1' and ok.data.enabled == '1')
assert(#f.rpcs == 1 and f.rpcs[1] == 'restart', 'restart RPC not issued once')
assert(f.pid ~= 11, 'process id not verified')

-- A persistently disabled service is not restarted and issues no RPC.
f.reset()
f.config.enabled = '0'
local skipped = bridge:RestartAction()
assert(skipped.success and skipped.data.restarted == '0' and skipped.data.enabled == '0')
assert(#f.rpcs == 0 and f.pid == 11, 'disabled service was restarted')

print('PASS: ConfigService schema/validators and privileged rc.init restart with PID verification')
