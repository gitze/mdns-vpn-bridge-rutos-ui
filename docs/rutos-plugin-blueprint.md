# RutOS plugin blueprint: Tailscale, DDNS and OpenVPN

## Scope and evidence

- Reference platform: RUTX / RutOS `R_00.07.25.3`; SDK `00.07.26.1` is not assumed identical.
- Primary references: original feed packages `tailscale 1.96.5-r0`, `vuci-app-tailscale-api git-r0`, `vuci-app-tailscale-ui git-r0`.
- Secondary references: installed DDNS, OpenVPN, services-status API, API core, `rpcd` and its `rc` plugin.
- Method: feed SHA-256 checks, package inventory, JavaScript inspection, LuaJIT bytecode disassembly, native Ghidra 12.1.2 analysis and read-only device probes.
- Evidence identities: [rutos-plugin-evidence.json](rutos-plugin-evidence.json). Labels E1–E8 below refer to that ledger.
- No vendor source, bytecode, binary or decompiled implementation is included in this repository. This document describes independently observed contracts.
- No VPN/relay restart, configuration write, package installation or ACL reload was performed for this analysis.

## 1. Package and filesystem boundary [E1, E2]

| Package | Responsibilities | Declared dependencies |
|---|---|---|
| `tailscale` | Combined daemon/CLI, init service, UCI defaults/config, permission table, upgrade keep list | System/network prerequisites, including `libcap-bin` |
| `vuci-app-tailscale-api` | Lua backend, API route, browser-user API authorization, OS-user ubus authorization | `api-core`, `luajit`, `tailscale` |
| `vuci-app-tailscale-ui` | Menu entry and gzipped Vue bundle | `vuci-app-tailscale-api`, `vuci-ui-core` |

- Package separation does not itself create a privilege boundary; process identities and ACLs do.
- RutOS package destination: `/usr/local`; read-only factory packages remain under `/`.
- API payload paths: `usr/lib/lua/api/services/`, `usr/share/vuci/path.d/`, `usr/share/rpcd/acl.d/`, **and** `usr/share/acl.d/`.
- UI payload paths: `usr/share/vuci/menu.d/`, `www/assets/` for the vendor chunk. Our supported remote view uses `www/views/`; preserve the correct menu-to-asset contract rather than copying the vendor loader.
- Configuration/init/permission payload paths: `etc/config/`, `etc/init.d/`, `etc/permtab.d/`. Overlay `etc` resolves to the system `/etc`.
- Optional UI must not ship the relay init script or binary; generic post-install helpers can start any init scripts owned by that package.

## 2. Trust boundaries: four distinct actors [E2, E3, E6]

```text
Browser / authenticated WebUI user
  │ HTTP + session/CSRF; browser-user API ACL
  ▼
uhttpd / Lua API                           NOT root
  ├─ ConfigService → tracked UCI changes → config file permissions
  ├─ local CLI / daemon socket              still NOT root
  └─ vuci.util.ubus(object, method, args)
       │ OS-user ubus ACL for uhttpd
       ▼
rpcd parent                               user rpcd; SETUID/SETGID capabilities
  └─ per-plugin worker                    plugin-selected identity
       └─ rc plugin                       root identity in this firmware
            └─ /etc/init.d/<fixed service> <allowed action>
                 └─ procd                 root service supervisor
                      └─ tailscaled       user tailscale + network capabilities
```

- A browser administrator is not a root Linux process.
- `vuci.util.ubus` connects to ubus and calls the named object/method; it does not itself turn the Lua process into root.
- The persistent `rpcd` process is **not** root on this firmware. Its effective capability mask was `0xc0` (`SETGID`, `SETUID`).
- `rpcd` native worker dispatcher at analysis address `0x1446c` forks, loads the selected plugin descriptor, selects the worker user/groups and capabilities, then invokes that plugin's method.
- In `rc.so`, exported `rpc_plugin` is at ELF virtual address `0x3004`. Its user pointer at `+0x0c` is null. The observed dispatcher handles that case with root supplementary groups, `setgid(0)` and `setuid(0)`.
- The `rc.init` handler (Ghidra analysis address `0x113e8`) rejects service-name path traversal, allowlists actions, forks/executes `/etc/init.d/<name>` and waits for its exit status.
- Allowed native actions observed: `disable`, `enable`, `stop`, `start`, `restart`, `reload`, `activate`, `deactivate`. `enabled` is not an allowed action; a read-only probe returned Invalid argument.
- A successful init-script exit is not proof that a daemon has reached readiness or adopted the intended configuration. Read back runtime state.

## 3. Two ACL families, not one [E2, E3]

| File family | Principal | What it authorizes |
|---|---|---|
| `usr/share/rpcd/acl.d/<app>.json` | Authenticated WebUI/API session | HTTP API reads/writes/actions |
| `usr/share/acl.d/api_<app>.json` | Linux user `uhttpd` | Object/method calls on the ubus socket |

- Tailscale API-session group is `services/vpn/tailscale`; its read/write rules cover `/tailscale/*`.
- Additional root-service inspection found that factory `api_acl.json` already grants `uhttpd` `service.list,event`, `rc.init` and `file.exec`. An absent app-local ACL therefore does not prove denial on this firmware; assess the effective base/app policy before diagnosing permissions.
- Its independent OS ACL grants `uhttpd`: `service.list`, `service.event`, `rc.init`.
- A working HTTP GET or permitted POST does not grant `service.set` or the ability to execute an init script with root privileges.
- These ubus method grants are not service-name-specific. The backend must hard-code its service/config and must never accept arbitrary RPC objects, service names, actions or shell commands from a browser.
- `ubus call session reload_acls` refreshes session authorization; it is not a substitute for loading `/usr/share/acl.d` rules into **ubusd**.

## 4. Native frontend and REST contract [E4]

- Tailscale registers `/tailscale/{service_group}/{?sid}` to `services/tailscale`.
- Vendor UI uses native resource/controller/form components, the host HTTP client and shared collection/query state.
- Shared HTTP client adds `X-CSRF-PROTECTION: 1`; requests use same-origin `/api/...` URLs.

| Operation | Method and endpoint | Request/response contract |
|---|---|---|
| Read configuration | `GET /api/tailscale/config` | Response `data` is an array of config resources |
| Update configuration | `PUT /api/tailscale/config` | Body `{data: [resource]}`; array normalization is done by the shared entity client |
| Read status | `GET /api/tailscale/status` | Response `data` array; the UI selects its first element |
| Logout | `POST /api/tailscale/actions/logout` | Vendor action client sends no body |

- Resource updates go through the shared collection's update/transform/cache path. There is no separate frontend call to an apply/commit endpoint in the inspected Tailscale flow.
- Status refresh is scheduled at 5-second intervals.
- Do not mix contracts: a ConfigService resource PUT uses a **data array**; our current FunctionService actions use a **data object**. Tailscale's parameterless logout does not establish an envelope for unrelated actions.
- Authentication/CSRF/interceptors belong to the host HTTP layer, not a new independently initialized axios client.

## 5. Configuration path: ConfigService, not shell commands [E3, E5]

- Tailscale backend extends `api/ConfigService`, not `api/FunctionService`.
- It registers the `tailscale` config with general section `settings`; create/delete are disabled.
- Options, validation, required fields and sensitive auth-key metadata are declared in that service.
- `PUT_validate_section_hook` adds conditional validation. `PUT_before_commit_hook` performs service-specific transformations and dependency setup before the framework commit.
- The framework's table wrapper tracks staged changes. `PUT_commit` delegates to `general_commit`; that iterates UCI changes and delegates to the wrapper's commit path.
- Normal wrapper commit delegates to the native UCI wrapper; bulk/backup paths save/load rather than treating every operation as an immediate independent commit.
- The native UCI commit wrapper calls its cursor commit and emits `service.event` with type `config.change` and the changed package when applicable.
- Tailscale's procd service registers a reload trigger for `tailscale`. Its `reload_service` stops and starts through the init-service context.
- Native `uci commit` from an ad-hoc CLI does not execute this Lua wrapper's event-emission code. Do not assume it reproduces ConfigService Save & Apply.
- Avoid direct `uci:commit` inside arbitrary endpoint hooks: the vendor UCI wrapper explicitly warns that API Core should track and commit changes.
- A successful PUT alone is insufficient acceptance evidence; verify persisted values and the runtime state resulting from the reload trigger.

## 6. File permissions and daemon-local calls [E1, E3]

- Tailscale config permission table: owner/group `tailscale:tailscale`, mode `0660`.
- Installed `tailscale` group includes `uci` and `uhttpd`; DDNS and OpenVPN use the same pattern with their service groups.
- UCI write access comes from filesystem ownership/group membership and API policy, not from implicitly running every configuration update as root.
- Tailscale startup uses `procd_set_param user tailscale`.
- Combined CLI/daemon binary has `cap_net_admin,cap_net_raw+ep`, set by the package post-install script. Those are network privileges, not a generic root shell.
- Init-time CLI setup explicitly configures `--operator=uhttpd`. This is a separate **Tailscale LocalAPI authorization** decision, not an ubus ACL.
- Backend reads status from `/var/run/tailscale/` and can use HTTP over `tailscaled.sock` (`GET /localapi/v0/status`). The observed socket was world-readable/writable; directory permissions and Tailscale's own peer-credential/operation policy remain relevant.
- `vuci.util.file_exec` captures process results including `code` and `stdout`; it is **not** a generic privileged-execution facility. Its optional user switch can succeed only with the caller's actual authority.
- Logout calls the Tailscale CLI and checks its result, updates the service-owned logout marker, then requests `rc.init` restart. These are distinct authorization paths.
- Do not copy `--operator`, network capabilities or socket permissions into an unrelated daemon without an equivalent need and authorization model.

## 7. Installation lifecycle is part of the plugin [E1, E7]

Observed `/lib/functions.sh:default_postinst` behavior on this firmware:

| Package content detected | Helper behavior |
|---|---|
| `usr/share/acl.d/` | Sends SIGHUP to **ubusd**, loading OS-user ubus ACLs |
| `etc/permtab.d/` | Runs `/sbin/perm -a` |
| `etc/uci-defaults/` | Retains defaults for restoration and applies them |
| `etc/init.d/` | Enables when appropriate and starts each package-owned init service |
| After installation | Restores `/etc/config` permissions through `/sbin/perm /etc/config` |

- Vendor package maintainer scripts invoke the normal `default_postinst` lifecycle; copying only data files does not reproduce it.
- The inspected custom UI builder currently creates **only a control file**, without a `postinst` lifecycle. Adding an OS ACL data file alone therefore does not guarantee it is loaded.
- Design the UI package's maintainer lifecycle explicitly: load OS ACLs, use the platform permission mechanism where needed, handle cached API modules and refresh API-session ACLs through their distinct supported paths.
- Do not run `/sbin/perm -a`, signal ubusd or restart uhttpd merely as an investigative probe. They change system state.
- If new group membership is needed, existing worker credentials must be refreshed; changing `/etc/group` alone does not change a running process's supplemental groups.
- Keep installer operations idempotent and limited to app-owned paths. Do not clean shared overlay directories.

## 8. Cross-checks from other installed packages [E8]

| Reference | Confirmed observation | Lesson |
|---|---|---|
| DDNS | `api/ConfigService`; PUT/POST/DELETE before-commit hooks; config `ddns:ddns 0660`; group contains `uci,uhttpd` | Native schema/hooks and config-file access are reusable patterns, not Tailscale-only behavior |
| OpenVPN | `api/ConfigService`; commit hooks; API OS ACL permits `service.list,event` plus `system.info`; config `openvpn:openvpn 0660`; group contains `uci,uhttpd` | Ordinary configuration application does not require every API package to grant `rc.init` |
| OpenVPN daemon ACL | Separate Linux user `openvpn` has `rc.init` and daemon-specific network/IP-block/hotplug calls | API-user and daemon-user permissions are separate principals |
| Services status API | `api/FunctionService`; inspects service instances/running/PIDs and process state | FunctionService is a good read/status/action adapter, not a replacement for the configuration framework |

Additional root-running references: [netifd and crond comparison](rutos-root-services-comparison.md).
Both daemon root identities were verified live. netifd confirms the ConfigService/UCI/event
pattern for a root daemon; cron is a different, root-owned file-configuration model.
The comparison also qualifies the base-ACL assumptions above.

## 9. Blueprint for this independent mDNS UI project

Recommended target contract, **not a claim that migration is implemented**:

1. Keep relay binary, UCI defaults and procd script in the relay OS package.
2. Keep platform-specific Vue/Lua/menu/routes/ACLs and maintainer lifecycle here.
3. Use a ConfigService-backed config resource for `mdns-vpn-bridge`, section `main`; declare the editable schema, disallow create/delete, validate everything before writes.
4. Use native config PUT/commit/event/reload semantics. Do not maintain a parallel shell-based transaction engine for Save & Apply.
5. Keep a separately authorized restart action only if the UI needs it. Fix the service name and allowlisted action in the backend; use `vuci.util.ubus("rc", "init", ...)`, never direct init execution as `uhttpd`.
6. Match OS ACL grants to actual calls: native configuration path needs `service.event`; state readback needs `service.list`; explicit init actions need `rc.init`.
7. Establish configuration-file access through a declared permission/group policy. Do not solve write access by world-writable service config or by granting root to the WebUI.
8. Verify persisted configuration before reporting saved. Verify effective runtime config/readiness before reporting applied; distinguish saved-but-apply-failed from failed-to-save.
9. Persistently disabled means Save & Apply stops the daemon, and explicit Restart skips it. Restart success must not be reported for an unchanged process or failed command.
10. Keep units validation, host HTTP session behavior and native help/interface controls. Rebuild and inspect the **final package**, including control scripts and both ACL families.

## 10. Acceptance gates and remaining limits

- [x] Feed package identities and actual payloads checked.
- [x] Tailscale UI/config/status/action paths and envelopes checked in shared frontend code.
- [x] ConfigService/UCI/event path disassembled; native `rc` worker privilege switch and handler inspected with Ghidra.
- [x] OS identities/capabilities, config-group access and permission tables read on the device.
- [x] DDNS/OpenVPN/services-status patterns cross-checked on the installed firmware.
- [ ] Implement the mDNS configuration/lifecycle changes against this blueprint; the preceding partial repair is not accepted as finished.
- [ ] Exercise packaged installation/ACL loading without relying on the installed Tailscale package to supply permissions.
- [ ] User-authorized live Save & Apply, disable, enable and restart tests; verify UCI and process/readiness state independently.
- [ ] Verify runtime behavior after reboot or a different firmware version; neither was tested here.

No production Tailscale logout, restart or configuration mutation was used to infer behavior. Native pseudocode is an interpretation supported by the retained assembly/descriptor evidence, not original vendor source. A blueprint is not an implementation or a tested release.
