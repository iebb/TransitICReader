"""Exercise production Clipper readers, registry, wallet methods and USB adapter."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

from tools.paths import ROOT


def wallet_method(source, name):
    match = re.search(r"^    (?:private )?func " + name + r"\(.*?^    }", source, re.M | re.S)
    if not match:
        raise AssertionError(f"Missing production wallet method: {name}")
    return match.group().replace("private func", "func", 1)


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "Requires Swift on macOS")
class ClipperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="cardbal-clipper-")
        cls.addClassCleanup(cls.directory.cleanup)
        directory = Path(cls.directory.name)
        utils = (ROOT / "ios/CardBal/NFC/NFCUtils.swift").read_text()
        # Actual models, registry and wallet mutations; only unrelated codecs
        # and storage/UI are adapted. No access to the user's real wallet.
        models = "import Foundation\nimport os\n"
        models += utils[utils.index("public enum ICCardRegion"):utils.index("extension TransitTransaction {")]
        models += utils[utils.index("struct TransitCardSnapshot:"):utils.index("enum StatusKind")]
        models += utils[utils.index("extension Data {"):utils.index("struct BERTLVNode")]
        models += utils[utils.index("func formatCurrency("):utils.index("func formatUTF8OrHex")]
        applications = (ROOT / "ios/CardBal/Models/TransitApplications.swift").read_text()
        models += applications[applications.index("struct TransitApplicationRecord:"):applications.index("struct TransitApplication:")]
        models += applications[applications.index("enum TransitApplicationHistory {"):]
        store = (ROOT / "ios/CardBal/Models/CardWalletStore.swift").read_text()
        models += "\nextension ClipperTestWallet {\n"
        models += "\n".join(wallet_method(store, name) for name in ["mergeRawRecords", "deleteLocalRecord"])
        models += "\n}\n"
        content = (ROOT / "ios/CardBal/ContentView.swift").read_text()
        storage = re.search(r"^    var storageIdentifier: String \{.*?^    }", content, re.M | re.S)
        if not storage:
            raise AssertionError("Missing production storageIdentifier property")
        models += "\nextension TransitCardSnapshot {\n" + storage.group() + "\n}\n"
        source = directory / "Models.swift"
        source.write_text(models)
        cls.executable = directory / "clipper-tests"
        sources = [
            "ios/CardBal/NFC/CardTransport.swift",
            "ios/CardBal/NFC/DESFireReader.swift",
            "ios/CardBal/NFC/ExternalCardReader.swift",
            "ios/CardBal/NFC/Decoders/TransitCardDecoder.swift",
            "ios/CardBal/NFC/Decoders/ClipperDecoder.swift",
            "ios/CardBal/NFC/Decoders/ClipperUltralightDecoder.swift",
            "ios/CardBal/Helpers/ClipperTransitCatalog.swift",
            "ios/CardBal/Helpers/SingaporeTransitCatalog.swift",
            "ios/CardBal/NFC/Profiles/StoredValueProtocol.swift",
            "ios/CardBal/NFC/Profiles/AdditionalCardHistory.swift",
            "ios/CardBal/NFC/Profiles/CalypsoProtocol.swift",
            "ios/CardBal/NFC/Profiles/CEPASProtocol.swift",
            "ios/CardBal/NFC/Profiles/SnapperPlusProtocol.swift",
            "tests/runtime/fixtures/clipper_tests.swift",
        ]
        shutil.copyfile(ROOT / "data/stations/ClipperTransit.json", directory / "ClipperTransit.json")
        result = subprocess.run(
            ["swiftc", "-parse-as-library", str(source), *[str(ROOT / path) for path in sources],
             "-o", str(cls.executable)],
            capture_output=True, text=True, timeout=90,
        )
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def run_case(self, case):
        result = subprocess.run([str(self.executable), case], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: " + case, result.stdout)

    def test_public_mock_and_history_persistence(self):
        self.run_case("history")

    def test_wrapped_desfire_on_iso7816_and_mifare(self):
        self.run_case("transport")

    def test_ultralight_pages_sequence_and_hidden_events(self):
        self.run_case("ticket")

    def test_cancellation_and_transport_rejection(self):
        self.run_case("cancellation")

    def test_catalog_resolution(self):
        self.run_case("catalog")

    def test_legacy_envelopes_and_production_registry(self):
        self.run_case("registry")

    def test_production_wallet_group_deletion_and_reload(self):
        self.run_case("wallet")

    def test_production_external_ultralight_adapter(self):
        self.run_case("external")


class ClipperCatalogImportTests(unittest.TestCase):
    @staticmethod
    def importer():
        spec = importlib.util.spec_from_file_location(
            "clipper_catalog_importer", ROOT / "tools/stations/import_clipper_catalog.py"
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_pinned_catalog_metadata_and_output_path(self):
        importer = self.importer()
        catalog = json.loads((ROOT / "data/stations/ClipperTransit.json").read_text())
        self.assertEqual(importer.ROOT, ROOT)
        self.assertEqual(catalog["sourceRevision"], importer.REVISION)
        self.assertEqual(catalog["sourceSHA256"], importer.SOURCE_SHA256)
        self.assertEqual((len(catalog["stations"]), len(catalog["operators"]), len(catalog["lines"])),
                         (129, 25, 4))
        self.assertIn("same license terms as Metrodroid", catalog["notice"])
        self.assertEqual(catalog["stations"]["262152"]["name"], "Powell Street")

    def test_minimal_mdst_and_truncated_input(self):
        importer = self.importer()
        empty = b"MdST\0\0\0\1" + bytes(4) + bytes(1)
        converted = importer.convert(empty)
        self.assertEqual(converted["sourceSHA256"], hashlib.sha256(empty).hexdigest())
        self.assertEqual(converted["stations"], {})
        for data in (b"", empty[:-1], empty[:8] + b"\0\0\0\1" + bytes(1),
                     empty[:12] + b"\x80" * 10, empty[:12] + b"\x01\x0D"):
            with self.subTest(data=data):
                with self.assertRaises(ValueError):
                    importer.convert(data)


if __name__ == "__main__":
    unittest.main()
