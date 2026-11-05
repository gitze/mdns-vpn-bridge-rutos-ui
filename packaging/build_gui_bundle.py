#!/usr/bin/env python3
"""Wrap an IPK in the metadata archive expected by RutOS GUI upload."""
import argparse
import gzip
import hashlib
import io
import pathlib
import tarfile
from build_ipk import archive, VERSION, ARCH


def build(ipk, output, firmware):
    name = "mdns-vpn-bridge-rutos-ui"
    metadata = (
        f"Package: {name}\nVersion: {VERSION}\nRouter: RUTX\nipk_file: {ipk.name}\n"
        f"Architecture: {ARCH}\nFirmware: RUTX_R_{firmware}\nAppName: mdns-vpn-bridge-rutos-ui\n"
        "tlt_name: mDNS VPN Bridge WebUI\n"
        "Description: mDNS VPN Bridge admin page and API\n"
    )
    data = ipk.read_bytes()
    if data[:8] != b"!<arch>\n":
        raise ValueError("expected ar-format IPK")
    offset = 8
    control = None
    while offset < len(data):
        header = data[offset:offset + 60]
        size = int(header[48:58])
        name = header[:16].decode().strip().rstrip("/")
        payload = data[offset + 60:offset + 60 + size]
        if name == "control.tar.gz":
            with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as tar:
                control = tar.extractfile("./control").read().decode()
        offset += 60 + size + size % 2
    if control is None:
        raise ValueError("missing control archive")
    index = (control.rstrip() + f"\nFilename: {ipk.name}\nSize: {len(data)}\n"
             f"MD5Sum: {hashlib.md5(data).hexdigest()}\n"
             f"SHA256sum: {hashlib.sha256(data).hexdigest()}\n\n")
    output.write_bytes(archive({"main": (metadata.encode(), 0o644),
                                ipk.name: (data, 0o644),
                                "Packages.gz": (gzip.compress(index.encode(), mtime=0), 0o644)}))
    print(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipk", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--firmware", required=True, help="RutOS version suffix, e.g. 00.07.25.3")
    args = parser.parse_args()
    build(args.ipk, args.output, args.firmware)
