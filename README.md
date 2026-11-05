# mdns-vpn-bridge-rutos-ui

Optional Teltonika RutOS WebUI for [mdns-vpn-bridge](https://github.com/gitze/mdns-vpn-bridge).

## Package names

| Installed package | RutOS display name | Role |
|---|---|---|
| `mdns-vpn-bridge` | mDNS VPN Bridge | Relay binary/service |
| `mdns-vpn-bridge-rutos-ui` | mDNS VPN Bridge WebUI | Optional configuration/status UI; depends on relay |

- Default delivery: one complete RutOS upload bundle containing relay 0.4.1 and UI 0.3.1. Source repositories and installed package identities stay separate.
- UI 0.3.1 changes the display name only; identifiers, API and dependency remain unchanged.

## Scope

- This project owns the Vue UI, Lua API adapter, menu/ACL files, package builders and tests.
- The platform-independent relay and its OS packages belong to the separate `mdns-vpn-bridge` project.
- The UI IPK declares `mdns-vpn-bridge >= 0.2.0`; the complete delivery bundle includes both IPKs. Neither installs a VPN.
- Works with a reachable remote relay over Tailscale, WireGuard or another suitable unicast VPN; the UI itself is RutOS-specific.
- The relay core is shared with the platform-independent Linux package; the current relay counterpart is 0.4.0. Only the WebUI is RutOS-specific.

## Layout

| Directory | Contents |
|---|---|
| `ui/` | Native RutOS Vue view and UI build |
| `api/` | Lua ConfigService, API routes, both ACL families and the permission table |
| `packaging/` | Combined IPK, native maintainer scripts and GUI upload bundle builders |
| `tests/` | Isolated Lua and JavaScript regression tests |
| `docs/` | Packaging contracts and current verification limits |

## Build and test

Requirements: Python 3.9+, Node.js 18+, npm, Make, Lua 5.1+ or LuaJIT for tests.
No sibling checkout of the relay is required.

```sh
make test
make bundle RELAY_IPK=/absolute/path/mdns-vpn-bridge_0.4.1_cortexa7hf-neon-vfpv4.ipk
```

Upload `dist/mdns-vpn-bridge-complete_0.4.1_RUTX_00.07.25.3.tar.gz` once through RutOS package management. It includes both packages. See [combined bundle](docs/combined-bundle.md).
Standalone component artifacts in `packaging/` are for explicit component-only use, not the default delivery.

Changing loaded Lua modules requires an approved WebUI backend restart and ACL
reload after installation; browser refresh alone is insufficient. Do not restart
the relay, VPN or networking merely to load a UI update.

## API contract

The API service (`api/files/usr/lib/lua/api/services/mdns_vpn_bridge.lua`) is a
native `api/ConfigService` that also exposes read-only status and one explicit
action:

| Operation | Method and endpoint |
|---|---|
| Read configuration | `GET /api/mdns_vpn_bridge_f/config` — response `data` is an array of resources |
| Update configuration | `PUT /api/mdns_vpn_bridge_f/config` — body `{data:[resource]}`; each resource must carry the `id` returned by `GET` |
| Read status | `GET /api/mdns_vpn_bridge_f/status` |
| List LAN interfaces | `GET /api/mdns_vpn_bridge_f/interfaces` |
| Restart relay | `POST /api/mdns_vpn_bridge_f/actions/restart` — body `{data:{}}` |

Configuration writes go through the native path: tracked UCI change → framework
commit → `service.event` `config.change` → the relay's procd reload trigger.
There is no shell-based transaction engine for Save & Apply. The restart action
uses the privileged `rc.init` RPC (`uhttpd` → `rc` plugin worker →
`/etc/init.d/mdns-vpn-bridge`), never a direct init execution.

## Status

- Installed release 0.2.6: native layout, authenticated status/config/interface reads, interface selection and English tooltips verified on RutOS 7.25.3.
- User confirmed successful installation of complete bundle: relay 0.4.1 + UI 0.3.1. User-guided live acceptance passed: manual Refresh, stats 300s -> 60s saved and retained after browser reload, baseline restored and retained, explicit Restart successful. Read-only router follow-up confirmed UCI stats=5m, running relay 0.4.1, fresh uptime, bidirectional traffic and errors=0.
- Open UI enhancement: status/traffic refresh is manual; no automatic polling.
- Not claimed / not exercised: reverse-path large-MTU behaviour and a production peer-address migration test.
- Historical 0.3.0: same functional fixes as 0.2.10; version bump bypasses the inspected RutOS GUI comparator, which incorrectly rejects 0.2.10 as older than installed 0.2.9.
- Changes since 0.2.9: fixes the enabled **Restart service**
  failure and improves configuration/validation error feedback.
  - Restart root cause: `vuci.util.ubus("rc","init",…)` returns `(nil, status)` —
    the `rc` plugin replies with an init-script exit status and **no data blob**.
    The old `type(reply) ~= "table"` check therefore treated every restart as
    failed and returned a bare HTTP 422 with no message, even though the relay
    had actually restarted. `init_action` now reads the ubus status (success is a
    nil/zero status) and honours an optional data `code`.
  - Failure responses use `add_critical_error(STD_CODES.CODE_ERROR, message,
    source, HTTP_STATUS_CODES.INTERNAL_SERVER_ERROR)`. `add_error` +
    `ResponseError()` produced a message-less HTTP 422 (`code 122`,
    `source "Request"`), which is what the user saw as `HTTP 422.` with no detail.
  - The view pre-validates the stats interval (rejecting a bare number such as
    `300` without sending a PUT, with concrete guidance) and parses the real
    RutOS error entries (`error`/`message`, `source`/`field`, nested envelopes)
    without exposing arbitrary objects. `validate_stats` returns the native
    second-value user message.
- 0.2.8–0.2.10 configuration moved from a FunctionService shell-write action to a
  native `ConfigService` (`GET`/`PUT /config`, data-array envelope, single
  general section); restart is the only explicit action and uses `rc.init` with
  PID verification; the IPK carries the native maintainer lifecycle
  (`postinst`/`postrm`/`prerm`) and a `permtab` rule granting the unprivileged
  WebUI worker write access to the relay config without a root WebUI or a
  world-writable file.
- Earlier verification was isolated: native contracts against firmware bytecode with mutation mocked (`tests/native_put_id_gate.lua` and intercepted `rc.init`). This is supplemented by the user-guided production acceptance above; no agent-driven authenticated browser test is claimed.
- Regression tests mock system/HTTP operations. They do not establish production
  write permissions or successful reload/start behaviour.
- Project extraction does not deploy, stop or change any running service.

See [packaging and verification](docs/packaging.md).

Native integration reference: [RutOS plugin blueprint](docs/rutos-plugin-blueprint.md)
(Tailscale, DDNS, OpenVPN; configuration, privilege boundaries, both ACL families
and package lifecycle), supplemented by the
[root-running netifd/crond comparison](docs/rutos-root-services-comparison.md).

## Origin and license

Extracted from `mdns-vpn-bridge/packaging/rutos/{ui,api,admin}` including pending
uncommitted changes. Original tracked history remains in the relay repository;
this is a separate local Git repository; local versioning does not publish it.
No proprietary Teltonika package code is included. [MIT](LICENSE).
