# Build one uploadable RutOS IPK from the API sources and compiled UI assets.
PYTHON ?= python3
UI := ../ui
OUTPUT ?= mdns-vpn-bridge-rutos-ui_0.3.1_cortexa7hf-neon-vfpv4.ipk

FIRMWARE ?= 00.07.25.3
BUNDLE := mdns-vpn-bridge-rutos-ui_0.3.1_RUTX_$(FIRMWARE).tar.gz

API_FILES := $(shell find ../api/files -type f)
CONTROL_FILES := $(wildcard control/postinst control/postrm control/prerm)

all: $(BUNDLE)

$(BUNDLE): $(OUTPUT) build_gui_bundle.py
	$(PYTHON) build_gui_bundle.py $(OUTPUT) $(BUNDLE) --firmware $(FIRMWARE)

$(OUTPUT): build_ipk.py $(API_FILES) $(CONTROL_FILES) $(UI)/src/views/services/MdnsVpnBridge.vue
	$(MAKE) -C $(UI) build
	$(PYTHON) build_ipk.py $(UI)/dest $(OUTPUT)

clean:
	rm -f $(OUTPUT) $(BUNDLE)

.PHONY: all clean
