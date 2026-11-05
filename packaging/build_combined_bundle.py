#!/usr/bin/env python3
"""Build one RutOS GUI upload containing the separate UI and relay IPKs."""
import argparse
import gzip
import hashlib
import io
import pathlib
import tarfile
import tempfile

from build_gui_bundle import build
from build_ipk import ARCH, archive


def control_from_ipk(data):
    if not data.startswith(b"!<arch>\n"):
        raise ValueError("expected ar-format relay IPK")
    offset = 8
    while offset < len(data):
        header = data[offset:offset + 60]
        if len(header) != 60 or header[58:60] != b"`\n":
            raise ValueError("invalid ar header")
        size = int(header[48:58])
        payload = data[offset + 60:offset + 60 + size]
        if len(payload) != size:
            raise ValueError("truncated ar member")
        if header[:16].decode().strip().rstrip("/") == "control.tar.gz":
            with tarfile.open(fileobj=io.BytesIO(payload)) as tar:
                member = tar.extractfile("./control")
                if member is None:
                    raise ValueError("missing control file")
                return member.read().decode()
        offset += 60 + size + size % 2
    raise ValueError("missing relay control")


def combined(ui_ipk, relay_ipk, output, firmware):
    data = relay_ipk.read_bytes()
    control = control_from_ipk(data)
    fields = dict(line.split(": ", 1) for line in control.splitlines() if ": " in line and not line.startswith(" "))
    for key, expected in {"Package": "mdns-vpn-bridge", "Architecture": ARCH,
                          "Firmware": "RUTX_R_" + firmware}.items():
        if fields.get(key) != expected:
            raise ValueError(f"relay {key} must be {expected}")
    if ui_ipk.name == relay_ipk.name:
        raise ValueError("IPK filenames must differ")
    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory) / "ui.tar.gz"
        build(ui_ipk, base, firmware)
        with tarfile.open(base) as tar:
            members = {}
            for member in tar.getmembers():
                if member.isfile():
                    source = tar.extractfile(member)
                    if source is None:
                        raise ValueError("missing bundle member")
                    members[member.name.removeprefix("./")] = (source.read(), 0o644)
    index = gzip.decompress(members["Packages.gz"][0]).decode()
    index += (control.rstrip() + f"\nFilename: {relay_ipk.name}\nSize: {len(data)}\n"
              f"MD5Sum: {hashlib.md5(data).hexdigest()}\n"
              f"SHA256sum: {hashlib.sha256(data).hexdigest()}\n\n")
    members[relay_ipk.name] = (data, 0o644)
    members["Packages.gz"] = (gzip.compress(index.encode(), mtime=0), 0o644)
    main = members["main"][0].decode().replace(
        "tlt_name: mDNS VPN Bridge WebUI", "tlt_name: mDNS VPN Bridge + WebUI")
    members["main"] = (main.encode(), 0o644)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(archive(members))
    print(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ui_ipk", type=pathlib.Path)
    parser.add_argument("relay_ipk", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--firmware", default="00.07.25.3")
    args = parser.parse_args()
    combined(args.ui_ipk, args.relay_ipk, args.output, args.firmware)
