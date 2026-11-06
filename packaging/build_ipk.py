#!/usr/bin/env python3
"""Bundle the RutOS API, ACLs and compiled remote Vue view into one uploadable IPK.

The control archive carries the native maintainer lifecycle (postinst/postrm/
prerm) so installation loads OS-user ubus ACLs, applies the permission table and
refreshes API-session ACLs. A control-only IPK misses that lifecycle.
"""

import argparse
import gzip
import io
import json
import pathlib
import tarfile

HERE = pathlib.Path(__file__).resolve().parent
PROJECT_ROOT = HERE.parent
CONTROL_DIR = HERE / "control"
VERSION = "0.5.1"
ARCH = "cortexa7hf-neon-vfpv4"
MAINTAINER_SCRIPTS = ("postinst", "postrm", "prerm")


def archive(members):
    """members: {name: (bytes, mode)} -> deterministic gzipped tar bytes."""
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.GNU_FORMAT) as tar:
        for name, (data, mode) in sorted(members.items()):
            info = tarfile.TarInfo("./" + name)
            info.size = len(data)
            info.mode = mode
            info.mtime = 0
            info.uid = info.gid = 0
            tar.addfile(info, io.BytesIO(data))
    # mtime=0 keeps the gzip header stable so the IPK/bundle hash is reproducible.
    return gzip.compress(buffer.getvalue(), mtime=0)


def build(assets, output):
    members = {}
    for root in (PROJECT_ROOT / "api" / "files", PROJECT_ROOT / "ui" / "files"):
        for path in root.rglob("*"):
            if path.is_file() and not path.name.startswith("."):
                members[str(path.relative_to(root))] = path.read_bytes()
    menu_key = "usr/share/vuci/menu.d/mdnsvpnbridge.json"
    js_files = list(assets.glob("services/MdnsVpnBridge_*.js.gz"))
    if len(js_files) != 1:
        raise ValueError("expected exactly one compiled MdnsVpnBridge JS asset")
    menu = json.loads(members[menu_key])
    menu["services/mdns-vpn-bridge"]["view"] = "services/" + js_files[0].name.removesuffix(".js.gz")
    members[menu_key] = (json.dumps(menu, separators=(",", ":")) + "\n").encode()
    for path in assets.rglob("*"):
        if path.is_file() and not path.name.startswith("."):
            members["www/views/" + str(path.relative_to(assets))] = path.read_bytes()
    needed = {
        "usr/lib/lua/api/services/mdns_vpn_bridge.lua",
        "usr/share/vuci/path.d/mdns-vpn-bridge.json",
        "usr/share/rpcd/acl.d/mdns-vpn-bridge.json",
        "usr/share/acl.d/api_mdns_vpn_bridge.json",
        "etc/permtab.d/mdns-vpn-bridge",
        menu_key,
        "www/views/services/" + js_files[0].name,
    }
    missing = needed - members.keys()
    if missing:
        raise ValueError(f"missing package files: {missing}")
    control = (f"Package: mdns-vpn-bridge-rutos-ui\nVersion: {VERSION}\n"
               f"Architecture: {ARCH}\nDepends: mdns-vpn-bridge (>= 0.5.1)\n"
               "Conflicts: mdns-vpn-bridge-admin\nReplaces: mdns-vpn-bridge-admin\n"
               "Firmware: RUTX_R_00.07.25.3\nRouter: RUTX\nAppName: mdns-vpn-bridge-rutos-ui\n"
               "tlt_name: mDNS VPN Bridge WebUI\n"
               f"Installed-Size: {sum(len(data) for data in members.values())}\n"
               "Maintainer: mdns-vpn-bridge contributors\nSection: net\n"
               "Description: mDNS VPN Bridge admin page (RutOS WebUI API and remote view)\n")
    control_members = {"control": (control.encode(), 0o644)}
    for script in MAINTAINER_SCRIPTS:
        path = CONTROL_DIR / script
        if path.is_file():
            control_members[script] = (path.read_bytes(), 0o755)
    output.parent.mkdir(parents=True, exist_ok=True)
    data_members = {name: (data, 0o644) for name, data in members.items()}
    parts = {"debian-binary": b"2.0\n", "control.tar.gz": archive(control_members),
             "data.tar.gz": archive(data_members)}
    with output.open("wb") as out:
        out.write(b"!<arch>\n")
        for name, data in parts.items():
            label = name.ljust(16)
            header = f"{label}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(data):<10}`\n"
            out.write(header.encode("ascii"))
            out.write(data)
            if len(data) % 2:
                out.write(b"\n")
    print(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("assets", type=pathlib.Path, help="compiled UI dest/ directory")
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    build(args.assets, args.output.resolve())
