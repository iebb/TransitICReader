"""Run the production Swift SQLite reader against every reviewed Korean alias."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("swiftc"), "Requires the Swift toolchain")
class KoreanCatalogRuntimeTests(unittest.TestCase):
    def test_sqlite_preserves_every_tsv_alias(self):
        source = (ROOT / "CardBal/NFC/Profiles/KoreanTransitCatalog.swift").read_text()
        # The alias reader is Foundation-only; omit unrelated NFC timestamp types.
        start = source.index("struct KoreanStationAlias:")
        end = source.index("enum KoreanTransitOperatorFieldProfile:")
        catalog = "import Foundation\nimport SQLite3\n" + source[start:end]
        main = r'''
import Foundation
let resources = URL(fileURLWithPath: CommandLine.arguments[1])
let original = try KoreanStationAliasCatalog(tsvURL: resources.appendingPathComponent("korean_stations.tsv"))
let unified = try KoreanStationAliasCatalog(databaseURL: resources.appendingPathComponent("cardbal_transit.sqlite"))
let expected = original.locations.sorted { $0.locationCode < $1.locationCode }
let actual = unified.locations.sorted { $0.locationCode < $1.locationCode }
precondition(expected == actual, "SQLite changed the reviewed per-location names or coordinates")
for (before, after) in zip(expected, actual) {
    precondition(before.mapStationID == after.mapStationID, "Map grouping changed")
    precondition(before.allowedEventRawValues == after.allowedEventRawValues, "Entry/exit filtering changed")
}
print("Verified \(actual.count) Korean aliases")
'''
        with tempfile.TemporaryDirectory(prefix="cardbal-korean-catalog-") as directory:
            directory = Path(directory)
            (directory / "Catalog.swift").write_text(catalog)
            (directory / "main.swift").write_text(main)
            binary = directory / "catalog-test"
            result = subprocess.run([
                "swiftc", str(directory / "Catalog.swift"), str(directory / "main.swift"),
                "-o", str(binary),
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([
                str(binary), str(ROOT / "CardBal/Resources"),
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Verified", result.stdout)


if __name__ == "__main__":
    unittest.main()
