# RutOS packaging and verification

## Package boundary

- Package: `mdns-vpn-bridge-rutos-ui`; dependency: `mdns-vpn-bridge >= 0.2.0`.
- Replaces/conflicts with the former `mdns-vpn-bridge-admin` package.
- Owns Vue assets, the Lua ConfigService, route, menu, both ACL families and the
  permission-table rule for the relay config.
- Does not own the relay binary, UCI defaults or procd init script; those remain
  in the relay project's RutOS package.
- No sibling source checkout is required to build. Runtime integration uses the
  relay's local status endpoint, UCI configuration and init service.

## Build contract

- `make` builds the UI and combines `api/files/` and `ui/files/` into an IPK.
- Version: 0.5.0, delivered together with relay 0.5.0 through the complete bundle; display name `mDNS VPN Bridge WebUI` in control/main/feed, package identity unchanged. Release version bump only; same functional fixes as 0.2.10. Earlier tested installed version: 0.2.6 (0.2.9 was installed on the reference router for read-only inspection).
- Architecture: `cortexa7hf-neon-vfpv4`; target firmware: `RUTX_R_00.07.25.3`.
- GUI upload format: gzip tar archive containing `main`, one IPK and `Packages.gz`.
- `main` fields are case-sensitive; use the full firmware identifier.
- Feed index includes filename, size, MD5 and SHA-256. A raw IPK is not a GUI upload bundle.
- IPK control includes `Package`, `AppName` and `tlt_name`; the installed-package GUI uses `tlt_name`.
- The IPK `control.tar.gz` carries the native maintainer lifecycle
  (`postinst`, `postrm`, `prerm`), not a control-only control archive. `postinst`
  runs `default_postinst` (loads `usr/share/acl.d` into ubusd, applies
  `etc/permtab.d`, starts package-owned init scripts, restores `/etc/config`
  permissions) and then refreshes API-session ACLs and the WebUI routes. This
  mirrors the installed Tailscale API/UI packages.
- Builders live in `packaging/`. `ui/Makefile` and `api/Makefile` install their
  individual payloads for staging; the combined builder is the supported
  distribution path. The UI compile step rewrites the menu `view` with `perl`
  for portability (BSD/macOS `sed` rejects the required backreference).

## Installed paths

RutOS uses `dest root /usr/local` and an overlay document root.

| IPK member | Installed location |
|---|---|
| `usr/lib/lua/api/services/mdns_vpn_bridge.lua` | `/usr/local/usr/lib/lua/api/services/mdns_vpn_bridge.lua` |
| `usr/share/vuci/path.d/` | `/usr/local/usr/share/vuci/path.d/` |
| `usr/share/vuci/menu.d/` | `/usr/local/usr/share/vuci/menu.d/` |
| `usr/share/rpcd/acl.d/` | `/usr/local/usr/share/rpcd/acl.d/` (API-session ACL) |
| `usr/share/acl.d/` | `/usr/local/usr/share/acl.d/` (uhttpd ubus ACL) |
| `etc/permtab.d/` | `/etc/permtab.d/` (via `/usr/local/etc -> /etc`) |
| `www/views/services/` | `/usr/local/www/views/services/` |

- Remote view imports do not automatically load sibling CSS. The current view uses host components/styles, without custom CSS.
- The route uses `/{service_group}/{?sid}`; the service is an `api/ConfigService`
  with a single general section (`mdns-vpn-bridge` config, `main` section).
- Normalized API paths end with `/`; ACL rules use `/mdns_vpn_bridge_f/<endpoint>/*`.
- Config read/write use the native data-array envelope (`GET`/`PUT /config`,
  body `{data:[{...}]}`); every PUT element MUST carry the resource `id` that
  `GET /config` returned. The native `api/put_logic` validator
  (`_PUT_validate_id`) rejects an element without a string id with HTTP 422
  `'id' is required.`; a general section is not a "singular" request and does
  not exempt the id. The restart action uses `{data:{}}`.
- Changing loaded Lua handlers requires an approved WebUI backend restart. Refreshing the browser alone does not reload server modules. Reload ACLs via `ubus call session reload_acls`.
- Restart only the WebUI when loading UI changes; do not interrupt the relay or VPN for this.

## Privilege and permission model

- Session ACL (`usr/share/rpcd/acl.d/mdns-vpn-bridge.json`): reads status/config/interfaces, writes config and actions.
- OS-user ubus ACL (`usr/share/acl.d/api_mdns_vpn_bridge.json`): grants `uhttpd`
  `service.list` (status readback), `service.event` (the config-change event
  emitted on commit) and `rc.init` (the restart action). The factory
  `api_acl.json` already grants `uhttpd` `service.list,event`, `rc.init` and
  `file.exec`; this rule keeps the app's needs explicit rather than relying on
  the base policy.
- Permission table (`etc/permtab.d/mdns-vpn-bridge`): `/etc/config/mdns-vpn-bridge`
  `root:uhttpd 660`. The WebUI worker runs as `uhttpd:uhttpd`; the group grant
  lets ConfigService/UCI write the relay config without a root WebUI or a
  world-writable file. The native Tailscale pattern uses a service group with
  `uci`/`uhttpd`; this package reuses the existing `uhttpd` group because the
  relay package does not create one.

## Verification gates

1. `make test`: isolated Lua schema/validator/status/interface tests, mocked
   JavaScript requests, and the native PUT id-gate test (real `api/put_logic`
   bytecode; self-skips unless `NATIVE_LUAJIT`/`NATIVE_API_DIR` point at a
   firmware Lua root). The id-gate test needs a LuaJIT whose bytecode format
   matches the target (the router's own `luajit`). Two ways to run it:
   - On the router (read-only): `ssh root@<router> 'luajit - /usr/lib/lua' < tests/native_put_id_gate.lua`
   - Locally against an extracted rootfs, using an FR1 (non-GC64) LuaJIT built
     for Linux i386: `docker run --rm --platform linux/386 -v $PWD/tests:/t:ro
     -v <rootfs>/usr/lib/lua:/native:ro i386/debian:bookworm bash -c
     '<build LuaJIT 2.1 with -DLUAJIT_DISABLE_GC64> && ./src/luajit /t/native_put_id_gate.lua /native'`.
   - Latest run (0.5.0 prep): the isolated test passed against the extracted
     RutOS 7.25.3 rootfs `api/put_logic.lua` bytecode; the router itself was not
     reachable, so the SSH variant was not exercised.
2. `make`: compile native Vue components and build the final IPK/bundle.
3. Unpack the final bundle, verify feed checksums, control fields, maintainer
   scripts and modes, payload paths, source bytes and menu asset reference.
4. Router-side no-action package checks, without installation or touching the GUI's upload staging directory.
5. After user installation and an approved backend reload, verify authenticated status/config/interface responses, visible native selection and help text. (Historical pass for 0.3.1: user acceptance confirmed the installed WebUI and native controls.)
6. With explicit authorization, verify persistent UCI and actual process changes after Save & Apply/restart. A success response alone is not proof. (Historical pass for 0.3.1: stats 300s→60s persisted and survived a browser reload; explicit Restart confirmed. Reverse-path large-MTU behaviour and a production peer-address migration test remain unexercised.)

## Known state

- Installed 0.2.6: authenticated read endpoints, native layout, LAN-interface selection and English help are verified on RutOS 7.25.3.
- 0.2.8 replaced the FunctionService shell-write action with a native
  ConfigService config resource and added the native maintainer lifecycle and a
  permission-table rule.
- 0.2.9 fixed the 0.2.8 Save & Apply failure (HTTP 422 `'id' is required.`).
  The native PUT validator requires the server-returned resource id on every
  data element; the 0.2.8 view omitted it. The id requirement is verified
  against the firmware bytecode by `tests/native_put_id_gate.lua`.
- 0.2.10 fixes the enabled **Restart service** false failure and improves error
  feedback:
  - `vuci.util.ubus("rc","init",…)` returns `(nil, status)`; rc.init carries no
    data blob. The old `type(reply) ~= "table"` check reported every restart as
    failed and returned a bare HTTP 422 with no message even though the relay had
    restarted. `init_action` now reads the ubus status (success is a nil/zero
    status) and honours an optional data `code`. Verified on the live router with
    `rc.init`/`service.list` mocked: success → HTTP 200, failure → HTTP 500.
  - Failures use `add_critical_error(STD_CODES.CODE_ERROR, message, source,
    HTTP_STATUS_CODES.INTERNAL_SERVER_ERROR)`. `add_error` + `ResponseError()`
    produced a message-less HTTP 422 (`code 122`, `source "Request"`).
  - The view rejects a bare stats value (e.g. `300`) client-side without a PUT,
    shows concrete guidance, and parses the real RutOS error entries
    (`error`/`message`, `source`/`field`, nested envelopes) without dumping
    arbitrary objects. `validate_stats` returns the native second-value message.
- Production Save & Apply / restart is **verified by user acceptance** (historical, relay
  0.4.1 + UI 0.3.1): stats 300s → 60s was saved, persisted in UCI and retained
  after a browser reload; the baseline was restored and retained; explicit
  Restart succeeded. A read-only follow-up confirmed UCI stats=5m, the relay
  running 0.4.1 with fresh uptime, bidirectional traffic and zero errors. The
  agent did not drive an authenticated browser session; the earlier isolated
  evidence (native contracts against firmware bytecode with the mutation
  boundary mocked) remains as supporting detail. Reverse-path large-MTU
  behaviour and a production peer-address migration test were not exercised.
- `tests/test_actions.lua` covers the declared schema, the validator's native
  second-return message and the restart success path; `tests/test_edge_cases.lua`
  covers the duration boundary, the nil-data rc reply regression and the
  restart failure/disabled handling (HTTP 500 with message); `tests/test_status.lua`
  and `tests/test_interfaces.lua` cover the read parsers; `tests/test_frontend.mjs`
  covers the config data-array envelope, client-side stats validation and the
  native error surface.
- The isolated tests mock `api/ConfigService`, shell/HTTP operations and cannot
  prove production permissions or successful reload/startup.
- The extraction changes no router files or running services.

## Safe upgrade checks

- Validate firmware, architecture, required package and free space before installation.
- Check `opkg --noaction install <ipk>` against the existing installation.
- Keep GUI upload staging owned by the router's `opkg` user. Root-created staging files can prevent a later GUI upload from replacing old payloads.
- A firmware update may wipe the overlay; reinstall the UI and relay packages separately.
