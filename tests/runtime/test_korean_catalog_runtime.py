"""Run the production Swift readers against bundled Korean catalogs."""
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

from tools.paths import ROOT, PORTABLE_OUTPUT


@unittest.skipUnless(shutil.which("swiftc"), "Requires the Swift toolchain")
class KoreanCatalogRuntimeTests(unittest.TestCase):
    def run_catalog(self, main, resources, include_modes=False):
        source = (ROOT / "ios/CardBal/NFC/Profiles/KoreanTransitCatalog.swift").read_text()
        # The alias reader is Foundation-only; omit unrelated NFC timestamp types.
        start = source.index("enum KOTRISTransportClass:") if include_modes else source.index("struct KoreanStationAlias:")
        end = source.index("enum KoreanTransitOperatorFieldProfile:")
        catalog = "import Foundation\nimport SQLite3\n" + source[start:end]
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
                str(binary), str(resources),
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout

    def test_bundled_transport_modes_decode_with_the_production_swift_reader(self):
        name = "KOTRISTransportModes.json"
        self.assertEqual(
            (ROOT / "ios/CardBal/Resources" / name).read_bytes(),
            (PORTABLE_OUTPUT / name).read_bytes(),
            "The bundled catalog must match the shared platform build output",
        )
        main = r'''
import Foundation
enum KoreanTransitTimestampDecoder { static let recordLength = 52 }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try Data(contentsOf: root.appendingPathComponent("KOTRISTransportModes.json"))
let catalog = try KOTRISTransportModeCatalog(data: data)
precondition(catalog.source.rowCount == 319, "Preserve the official source row count")
precondition(catalog.modes.count == 327, "Keep all classified official and supplementary modes")
precondition(catalog.mode(for: 201)?.transportClass == .rail)
precondition(catalog.mode(for: 321)?.transportClass == .taxi)
for code in [736, 741] {
    precondition(catalog.mode(for: code)?.transportClass == .bus)
    precondition(catalog.mode(for: code)?.matchStatus == "station_catalog")
    precondition(catalog.mode(for: code)?.provenanceDisplayName == "Reviewed station catalog")
}
precondition(catalog.mode(forHexCode: " 00C9 ")?.code == 201)
precondition(catalog.mode(forCodeBytes: Data([0, 201]))?.code == 201)
precondition(catalog.mode(forCodeBytes: Data([201])) == nil)
var record = Data(count: 52)
record[10] = 201
precondition(catalog.mode(forKoreanTransitRecord: record)?.transportClass == .rail)
precondition(catalog.mode(forKoreanTransitRecord: record.dropLast()) == nil)
precondition(catalog.mode(for: 190) == nil, "An unclassified observed code is not an official mode")
precondition(catalog.mode(for: 65535) == nil)
var payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
var source = payload["source"] as! [String: Any]
source["rowCount"] = 318
payload["source"] = source
do {
    _ = try KOTRISTransportModeCatalog(data: JSONSerialization.data(withJSONObject: payload))
    preconditionFailure("Mismatched official row count unexpectedly loaded")
} catch let error as KOTRISTransportModeCatalogError {
    precondition(error == .rowCountMismatch(expected: 318, actual: 319))
}
print("Verified 327 bundled KOTRIS modes and the shared platform payload")
'''
        output = self.run_catalog(main, PORTABLE_OUTPUT, include_modes=True)
        self.assertIn("Verified 327 bundled KOTRIS modes", output)

    def test_sqlite_preserves_every_tsv_alias(self):
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
        output = self.run_catalog(main, PORTABLE_OUTPUT)
        self.assertIn("Verified", output)

    def test_catalog_size_is_data_driven_with_empty_and_duplicate_rejection(self):
        resources = PORTABLE_OUTPUT
        lines = (resources / "korean_stations.tsv").read_text().splitlines()
        self.assertGreaterEqual(len(lines), 3, "Need two reviewed aliases for fixtures")
        header, first, second = lines[:3]
        first_code = first.split("\t")[0]
        with tempfile.TemporaryDirectory(prefix="cardbal-korean-fixtures-") as directory:
            directory = Path(directory)
            for name, rows in {
                "one": [first], "two": [first, second],
                "empty": [], "duplicate": [first, first],
            }.items():
                (directory / f"{name}.tsv").write_text("\n".join([header, *rows]) + "\n")
            # Copy only the tables/rows used by the production reader, retaining
            # the reviewed JSON, coordinates and map-group identity unchanged.
            for name, code in [("one", first_code), ("empty", None), ("duplicate", first_code)]:
                with closing(sqlite3.connect(directory / f"{name}.sqlite", uri=True)) as database, database:
                    database.execute("ATTACH DATABASE ? AS bundled", (
                        (resources / "cardbal_transit.sqlite").as_uri() + "?mode=ro",
                    ))
                    database.execute("""
                        CREATE TABLE station_identifiers AS
                        SELECT * FROM bundled.station_identifiers
                        WHERE namespace = 'kr.ksx.location' AND code = ?
                    """, (code,))
                    database.execute("""
                        CREATE TABLE stations AS SELECT * FROM bundled.stations
                        WHERE id IN (SELECT station_id FROM station_identifiers)
                    """)
                    if name == "duplicate":
                        database.execute("INSERT INTO station_identifiers SELECT * FROM station_identifiers")
            main = r'''
import Foundation
let resources = URL(fileURLWithPath: CommandLine.arguments[1])
func tsv(_ name: String) throws -> KoreanStationAliasCatalog {
    try KoreanStationAliasCatalog(tsvURL: resources.appendingPathComponent(name + ".tsv"))
}
func sqlite(_ name: String) throws -> KoreanStationAliasCatalog {
    try KoreanStationAliasCatalog(databaseURL: resources.appendingPathComponent(name + ".sqlite"))
}
func expectError(_ expected: KoreanStationAliasCatalogError, _ load: () throws -> KoreanStationAliasCatalog) {
    do {
        _ = try load()
        preconditionFailure("Invalid catalog unexpectedly loaded")
    } catch let actual as KoreanStationAliasCatalogError {
        precondition(actual == expected, "Unexpected catalog error: \(actual)")
    } catch {
        preconditionFailure("Unexpected error: \(error)")
    }
}
let one = try tsv("one")
let two = try tsv("two")
precondition(one.locations.count == 1)
precondition(two.locations.count == 2)
let alias = one.locations[0]
precondition(two.location(for: alias.locationCode) == alias, "Small TSV lost its lookup")
let database = try sqlite("one")
precondition(database.locations == one.locations, "Small SQLite changed its alias")
expectError(.rowCountMismatch(expected: 1, actual: 0)) { try tsv("empty") }
expectError(.rowCountMismatch(expected: 1, actual: 0)) { try sqlite("empty") }
expectError(.duplicateLocationCode(alias.locationCode)) { try tsv("duplicate") }
expectError(.duplicateLocationCode(alias.locationCode)) { try sqlite("duplicate") }
print("Verified variable catalog sizes and invalid catalogs")
'''
            output = self.run_catalog(main, directory)
            self.assertIn("Verified variable catalog sizes", output)


if __name__ == "__main__":
    unittest.main()
