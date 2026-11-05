"""Package identity and display-name regression (no router access)."""
import gzip
import hashlib
import io
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "packaging"))
import importlib

build_gui_bundle = importlib.import_module("build_gui_bundle")
build_ipk = importlib.import_module("build_ipk")


def member_bytes(archive, name):
    member = archive.extractfile(name)
    assert member is not None, name
    return member.read()


def control_text(data):
    offset = 8
    while offset < len(data):
        header = data[offset:offset + 60]
        size = int(header[48:58])
        if header[:16].decode().strip().rstrip("/") == "control.tar.gz":
            with tarfile.open(fileobj=io.BytesIO(data[offset + 60:offset + 60 + size])) as archive:
                return member_bytes(archive, "./control").decode()
        offset += 60 + size + size % 2
    raise AssertionError("missing control")


class PackageIdentityTest(unittest.TestCase):
    def test_webui_name_consistent_without_renaming_package(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            assets = root / "assets"
            (assets / "services").mkdir(parents=True)
            (assets / "services/MdnsVpnBridge_test.js.gz").write_bytes(gzip.compress(b"export default {}"))
            ipk = root / "webui.ipk"
            bundle = root / "webui.tar.gz"
            build_ipk.build(assets, ipk)
            build_gui_bundle.build(ipk, bundle, "00.07.25.3")
            control = control_text(ipk.read_bytes())
            with tarfile.open(bundle) as archive:
                main = member_bytes(archive, "./main").decode()
                feed = gzip.decompress(member_bytes(archive, "./Packages.gz")).decode()
            for metadata in (control, main, feed):
                self.assertIn("Package: mdns-vpn-bridge-rutos-ui\n", metadata)
                self.assertIn("AppName: mdns-vpn-bridge-rutos-ui\n", metadata)
                self.assertIn("tlt_name: mDNS VPN Bridge WebUI\n", metadata)
                self.assertIn("Version: 0.5.0\n", metadata)
            self.assertIn("Depends: mdns-vpn-bridge (>= 0.5.0)\n", control)
            self.assertIn(hashlib.sha256(ipk.read_bytes()).hexdigest(), feed)


if __name__ == "__main__":
    unittest.main()
