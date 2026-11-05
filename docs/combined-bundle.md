# Combined RutOS bundle

- Deliver one GUI-uploadable archive containing two separate packages: relay 0.5.0 and WebUI 0.5.0.
- Keep source projects and installed package identities separate; bundle composition belongs to this UI project.
- Artifact: `dist/mdns-vpn-bridge-complete_0.5.0_RUTX_00.07.25.3.tar.gz`.
- Build: `make bundle RELAY_IPK=/absolute/path/mdns-vpn-bridge_0.5.0_cortexa7hf-neon-vfpv4.ipk`. The complete bundle is built once the relay 0.5.0 IPK is available; its SHA256 is recorded at that point.
- Archive: `main`, both IPKs, `Packages.gz` with both package stanzas and hashes.
- Main package is the UI (version 0.5.0); its dependency selects the included relay when missing. Both packages are 0.5.0.
- Existing relay satisfies the dependency; installing the missing UI does not require forcing a relay reinstall.
- UI 0.5.0 is a release version bump only; no functional or source change.
- Fresh UI build and Lua/frontend/packaging tests passed. The isolated native PUT id-gate test also passed against the real firmware `api/put_logic.lua` bytecode (extracted RutOS 7.25.3 rootfs loaded with an FR1 non-GC64 i386 LuaJIT). No 0.5.0 live acceptance has been performed.

## Historical: 0.4.1 bundle

- Artifact: `dist/mdns-vpn-bridge-complete_0.4.1_RUTX_00.07.25.3.tar.gz`.
- SHA256: `65d8f232280802d601c1e011fed03843cc1f123664de8a53f9564b3138c75cde`.
- Archive: `main`, both IPKs, `Packages.gz` with both package stanzas and hashes.
- Main package was the UI (version 0.3.1); the archive name 0.4.1 denoted the relay release.
- Bundle repeated byte-identically; both control records, relay identity, dependency, hashes, firmware-mismatch rejection and malformed-IPK rejection checked.
- Native router opkg `--noaction` accepted UI installation with the existing relay. Separate scratch destination/status without either package selected relay 0.4.1 followed by UI 0.3.1. Actual router package state/service unchanged.
- The user installed this bundle through the RutOS package management UI and confirmed the WebUI renders; the live acceptance (Save & Apply, persistence, restart) is recorded in the README. No publication was performed.
