-- Isolated parser test: no network or system changes.
local f = dofile((arg[0]:match('^(.*[/])') or '') .. 'support.lua')
local output = {
	['ip -o link show'] = [[
1: lo: <LOOPBACK,UP> mtu 65536
2: zlan: <BROADCAST,MULTICAST,UP> mtu 1500
3: br-lan: <BROADCAST,MULTICAST,UP> mtu 1500
4: tailscale0: <POINTOPOINT,MULTICAST,UP> mtu 1280
5: empty: <BROADCAST,MULTICAST> mtu 1500
6: vlan10@eth0: <BROADCAST,MULTICAST,UP> mtu 1500
]],
	['ip -o -4 addr show'] = [[
1: lo    inet 127.0.0.1/8 scope host lo
2: zlan    inet 192.0.2.1/24 scope global zlan
3: br-lan    inet 192.0.2.2/24 scope global br-lan
3: br-lan    inet 192.0.2.3/24 scope global secondary br-lan
4: tailscale0    inet 100.64.0.1/32 scope global tailscale0
6: vlan10@eth0    inet 198.51.100.1/24 scope global vlan10
]],
}
io.popen = function(command)
	assert(output[command], 'unexpected command: ' .. command)
	return { read = function() return output[command] end, close = function() return true end }
end
local bridge = f.load(assert(arg[1]))
local result = bridge:GET_TYPE_interfaces().data.interfaces
assert(#result == 3)
assert(result[1].name == 'br-lan' and result[1].address == '192.0.2.2')
assert(result[2].name == 'vlan10')
assert(result[3].name == 'zlan')
output['ip -o -4 addr show'] = ''
assert(#bridge:GET_TYPE_interfaces().data.interfaces == 0)
print('PASS: interface filtering, sorting, deduplication, VLAN naming, empty list')
