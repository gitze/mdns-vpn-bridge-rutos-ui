# Root-running RutOS services: netifd and crond

## Scope

- Platform: live RUTX / RutOS 7.25.3, same device as the Tailscale investigation.
- Exactly two additional runtime services: `netifd` (`network`) and `crond` (`cron`).
- Root identity verified from `/proc/<pid>/status`: all four UIDs are 0 for both daemons; matched against procd's service instance PID and command.
- Read-only inspection: process metadata, API bytecode, route/ACL declarations, permission metadata, init scripts and `test -w` as `uhttpd`.
- No live network/cron reload, start/stop, configuration change or cron job execution.
- Network configuration contents and cron job command contents were not read or copied.

## Comparison

| Property | Tailscale reference | netifd / network | crond / cron |
|---|---|---|---|
| Observed daemon identity | `tailscale` with network capabilities | **root** | **root** |
| Configuration | UCI `tailscale` | UCI `network` | Files under `/etc/crontabs`; UCI `system` supplies `cronloglevel` |
| Native config API | ConfigService | **ConfigService**, `api/network/interfaces.lua` | No dedicated general-crontab config endpoint found in the inspected API/routes |
| API route | `/tailscale/{service_group}/{?sid}` | `/interfaces/{service_group}/{?sid}` | Not established for arbitrary cron jobs |
| Config file access | Service group includes `uhttpd` | Config group `network` includes `uhttpd` | `/etc/crontabs` and its `root` file **not writable** by `uhttpd` |
| Apply mechanism established statically | Native UCI event and service reload trigger; explicit rc action for logout | Native UCI event, network/wireless reload triggers, root init reload invokes `network.reload` | Init constructs daemon args and registers job files with procd; **no config reload trigger in the inspected init script** |
| Direct unprivileged init required? | No | No | Not demonstrated or granted merely by having an API admin session |

## 1. netifd: root daemon, unprivileged configuration frontend

- `/usr/lib/lua/api/network/interfaces.lua` imports `api/ConfigService` and registers UCI config `network`, section type `interface`.
- Router API path declaration maps `/interfaces/{service_group}/{?sid}` to `network/interfaces`.
- HTTP session permissions in `usr/share/rpcd/acl.d/network.json` authorize interface config/action operations for the relevant LAN/WAN groups.
- Current API module includes a mobile extension. Its before-commit hooks delegate to the base implementation and add mobile-specific work; the inspected `PUT_after_commit_hook` is the empty framework default. Do not describe all modem-specific side effects as fully traced.
- The shared ConfigService/UCI commit path emits `config.change`, as established in the main blueprint.
- `/etc/init.d/network` starts `/sbin/netifd` through procd without a service-user override. Runtime UID 0 was independently verified.
- It registers reload triggers for **network and wireless**.
- Its root-side `reload_service` performs platform checks and calls `ubus network.reload`; restart is a separate, more disruptive path.
- Therefore changing interface configuration does not require granting root to the WebUI. The native event/reload boundary reaches the root-side service context.

### File access is independent of daemon UID

- Declared permtab target: `/etc/config/network network:network 0660`.
- Actual file at observation: owner `gsm`, group `network`, mode `0660`.
- `uhttpd` and `uci` are members of group `network`.
- A non-mutating `test -w /etc/config/network` under `uhttpd` succeeded.
- The live owner differed from the declared target; record both, rather than assuming the daemon identity determines file ownership.
- No actual network configuration write was used to test the permissions.

## 2. crond: root scheduler with a different configuration model

- `/etc/init.d/cron` starts `/usr/sbin/crond` through procd without a service-user override. Runtime UID 0 was independently verified.
- Observed process arguments: foreground mode, configuration directory `/etc/crontabs`, log level 5.
- Startup obtains `system.@system[0].cronloglevel`, validates it as an unsigned integer, and passes it as the daemon log level.
- Startup registers each existing `/etc/crontabs/*` file with `procd_set_param file` and enables respawn.
- This registration is not evidence that every edit is automatically watched/reloaded. The inspected `service_triggers` registers validation only, **not** `procd_add_reload_trigger system`.
- `/etc/crontabs` was `root:root 0755`; `/etc/crontabs/root` was `root:root 0644`.
- `test -w` under `uhttpd` failed for both. Browser administrator privileges do not turn these files into writable API configuration.
- A bounded scan of installed API Lua artifacts and route declarations found no dedicated general-crontab/cronloglevel config endpoint. This is not proof that no indirect scheduler exists anywhere in the firmware.
- A separate installed FOTA integration references a `rut_fota.set_crontab` RPC and owns a dedicated cron-file permission declaration. That is a service-specific interface, **not** evidence of an unrestricted cron editor for `uhttpd`.
- The UID of the scheduler does not establish the UID of every scheduled command; child-job identities were not investigated or exercised.

### Consequence

- Cron is not a second example of a ConfigService-backed arbitrary-job editor.
- It demonstrates the opposite security boundary: a root daemon can read root-owned configuration that the WebUI cannot directly modify.
- Do not infer a generic rule “Teltonika root services expose shell writes from uhttpd”. The inspected paths do not support that claim.

## 3. Important correction: existing base ubus permissions

- Installed `/usr/share/acl.d/api_acl.json` already grants Linux user `uhttpd` the methods `service.list`, `service.event`, `rc.init` and `file.exec`, among others.
- Tailscale's app-specific OS ACL repeats some of those permissions. Missing an app-local ACL does **not** by itself prove that the same calls are denied on this firmware: effective access also includes base and other installed rules.
- The WireGuard API additionally grants `uhttpd` `network.reload` and `network.interface.up/down`; those are method-specific grants, not a root shell.
- This refines the earlier blueprint: the mDNS defect must not be diagnosed simply as “no extra ACL”. The observed direct shell init call bypasses the privileged RPC path regardless of these existing grants.
- A portable plugin must declare its intended dependencies/permissions and lifecycle, but should not add broader grants merely because a method is used. Inspect the effective firmware policy first.
- Both HTTP session authorization and Linux-user ubus authorization still apply; they remain distinct.

## 4. Result for the mDNS UI

- **netifd is the closer reference:** a root daemon with ordinary UCI configuration and native ConfigService/event/procd application.
- Root runtime identity is no reason to keep shell-based configuration mutations or to make the WebUI root.
- Use the native UCI configuration path and the relay's procd reload trigger; an explicit restart action can use `rc.init` with a fixed service name.
- Verify permissions, persistent UCI and resulting runtime state independently. Avoid reimplementing the full network service's mobile/VLAN machinery.
- Cron's file-based job model should **not** replace the relay's existing UCI model.
- This comparison changes no implementation or package and is not a live Save & Apply acceptance test.

## Evidence and reproducibility

| Installed artifact | SHA-256 |
|---|---|
| `/usr/lib/lua/api/network/interfaces.lua` | `54b4cc7e23abe5079f6afcecdd235ed0bfe678f6a6bb44eaf2e91b318069f8f7` |
| `/etc/init.d/network` | `63f5b19ef97579c2cf682d96bd8995ad06dce3e0b55e92f1c3bd8a63bc2846cf` |
| `/etc/init.d/cron` | `05c3a465864edfb040d10d02310af9198169200b25debf0cb324060bd8f48637` |

- Read-only sources: `/proc/<pid>/status`, `ubus service.list` for fixed names `network`/`cron`, `/usr/share/vuci/path.d/network.json`, `/usr/share/rpcd/acl.d/network.json`, `/usr/share/acl.d/api_acl.json`, `/usr/share/acl.d/api_wireguard.json`, `/etc/permtab.d/network`, `/etc/group`, file metadata and non-mutating `test -w`.
- LuaJIT disassembly confirms: ConfigService import/section registration; selected before/after-commit hooks including the mobile extension.
- No vendor code or actual network/cron configuration contents are reproduced here.
- Shared native privilege evidence and package-lifecycle analysis: [main blueprint](rutos-plugin-blueprint.md), [evidence ledger](rutos-plugin-evidence.json).
