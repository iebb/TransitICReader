"""Exercise production external-reader transports and CEPAS parsing with synthetic replies."""
import shutil
import sys
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.paths import ROOT


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "Requires Swift and CryptoTokenKit on macOS")
class ExternalReaderTests(unittest.TestCase):
    def test_protocols_and_purse_parser(self):
        sources = [
            "ios/CardBal/NFC/CardTransport.swift",
            "ios/CardBal/NFC/ScanProgress.swift",
            "ios/CardBal/NFC/ExternalCardReader.swift",
            "ios/CardBal/NFC/Decoders/TransitCardDecoder.swift",
            "ios/CardBal/NFC/Profiles/CEPASProtocol.swift",
            "ios/CardBal/NFC/Decoders/CEPASDecoder.swift",
            "tests/runtime/fixtures/external_reader_tests.swift",
        ]
        with tempfile.TemporaryDirectory(prefix="cardbal-external-test-") as directory:
            executable = str(Path(directory) / "test")
            result = subprocess.run(
                ["swiftc", "-parse-as-library", *[str(ROOT / source) for source in sources], "-o", executable],
                capture_output=True, text=True, timeout=90,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([executable], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS:", result.stdout)


if __name__ == "__main__":
    unittest.main()
