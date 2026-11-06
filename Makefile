# mdns-vpn-bridge-rutos-ui
.PHONY: all build test test-native clean

all: build

build:
	$(MAKE) -C packaging

# One GUI upload; projects and installed packages remain separate.
RELAY_VERSION ?= 0.5.1
RELAY_IPK ?=
BUNDLE_OUTPUT ?= dist/mdns-vpn-bridge-complete_$(RELAY_VERSION)_RUTX_00.07.25.3.tar.gz
.PHONY: bundle
bundle: build
	@test -n "$(RELAY_IPK)" || { printf 'Set RELAY_IPK to the tested relay IPK path\n'; exit 1; }
	python3 packaging/build_combined_bundle.py packaging/mdns-vpn-bridge-rutos-ui_0.5.1_cortexa7hf-neon-vfpv4.ipk "$(RELAY_IPK)" "$(BUNDLE_OUTPUT)"

test:
	$(LUA) tests/test_actions.lua api/files/usr/lib/lua/api/services/mdns_vpn_bridge.lua
	$(LUA) tests/test_edge_cases.lua api/files/usr/lib/lua/api/services/mdns_vpn_bridge.lua
	$(LUA) tests/test_interfaces.lua api/files/usr/lib/lua/api/services/mdns_vpn_bridge.lua
	$(LUA) tests/test_status.lua api/files/usr/lib/lua/api/services/mdns_vpn_bridge.lua
	node tests/test_frontend.mjs
	python3 tests/test_packaging.py
	$(MAKE) test-native

# Real-firmware PUT id-gate contract test. Loads the native api/put_logic.lua
# (LuaJIT bytecode) with a mocked request context. Needs a bytecode-compatible
# LuaJIT (the router's own luajit) and the firmware Lua root. Self-skips when
# NATIVE_LUAJIT / NATIVE_API_DIR are not set.
#   NATIVE_LUAJIT=/usr/bin/luajit NATIVE_API_DIR=/usr/lib/lua make test-native
test-native:
	@if [ -n "$(NATIVE_LUAJIT)" ] && [ -n "$(NATIVE_API_DIR)" ] && [ -f "$(NATIVE_API_DIR)/api/put_logic.lua" ]; then \
		echo "running native PUT id-gate test ($(NATIVE_LUAJIT), $(NATIVE_API_DIR))"; \
		"$(NATIVE_LUAJIT)" tests/native_put_id_gate.lua "$(NATIVE_API_DIR)"; \
	else \
		echo "SKIP native PUT id-gate test (set NATIVE_LUAJIT and NATIVE_API_DIR to a firmware Lua root)"; \
	fi

clean:
	$(MAKE) -C packaging clean
	$(MAKE) -C ui clean

LUA ?= lua
NATIVE_LUAJIT ?= $(shell command -v luajit 2>/dev/null)
NATIVE_API_DIR ?=
