"""Public sample contracts, private-export transforms and production Swift import."""
import copy
import json
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools.paths import ROOT
from tools.samples import launch, prepare


class DevelopmentSampleTests(unittest.TestCase):
    def test_collections_and_artwork_exclusion(self):
        owner = launch.wallet("owner")
        self.assertEqual(len(owner["cards"]), 48)
        self.assertEqual(sum(len(c[k]) for c in owner["cards"] for k in ("rawTransactions", "rawTransitHistory")), 513)
        self.assertEqual(launch.wallet("mock"), prepare.mock_wallet())
        combined = launch.wallet("all")
        self.assertEqual(len(combined["cards"]), 51)
        for card in combined["cards"]:
            self.assertTrue(card["id"].startswith("sample:"))
            self.assertFalse(card.get("isUsingImage"))
            self.assertNotIn("faceImageFileName", card)
            for key in ("rawTransactions", "rawTransitHistory"):
                self.assertTrue(all(re.fullmatch(r"(?:[0-9A-F]{2})+", raw) for raw in card[key]))
        self.assertEqual(combined["faceAssets"], {})
        self.assertEqual({p.suffix for p in launch.DATA.iterdir()}, {".md", ".json"})

    def source(self):
        card = prepare.base_card(1, "nanaco", "FeliCa", "input")
        card.update(rawTransactions=["4700000127000030390355F50F000000"],
                    rawIdentifierValue="DEADBEEF12345678", identifierValue="DEAD BEEF 1234 5678",
                    realSerialNumber="7600123456789012", faceImageFileName="private-art.png",
                    customTitle="Private name", customDisplaySerialNumber="Private card",
                    issueDateStr="2026-10-31", scannedAt="2026-10-31T23:59:59Z",
                    resultFields=[{"title": "nanaco Number", "value": "7600123456789012", "id": "original-id"}])
        return {"version": 2, "cards": [card], "faceAssets": {"private-art.png": "private bytes"}}

    def test_anonymization_preserves_money_and_encoded_clock(self):
        source = self.source()
        result = prepare.owner_wallet(source, shift_days=-364)
        card = result["cards"][0]
        self.assertEqual(card["scannedAt"], "2025-11-01T23:59:59Z")
        self.assertEqual(card["issueDateStr"], "2025-11-01")
        self.assertEqual(card["rawIdentifierValue"], card["identifierValue"])
        self.assertEqual(card["realSerialNumber"], card["resultFields"][0]["value"])
        self.assertNotIn("DEADBEEF", json.dumps(result))
        self.assertNotIn("7600123456789012", json.dumps(result))
        self.assertNotIn("Private", json.dumps(result))
        self.assertNotIn("private-art", json.dumps(result))
        old = bytes.fromhex(source["cards"][0]["rawTransactions"][0])
        new = bytes.fromhex(card["rawTransactions"][0])
        self.assertEqual(old[:9], new[:9])  # Event, fare and balance.
        clock = int.from_bytes(new[9:13], "big")
        self.assertEqual((2000 + (clock >> 21), (clock >> 17) & 15, (clock >> 12) & 31), (2025, 11, 1))
        self.assertEqual(len(new), len(old))
        self.assertEqual(result["faceAssets"], {})
        self.assertEqual(source, self.source(), "Do not mutate the private input")

    def test_unknown_layouts_fields_and_families_fail(self):
        for change in [dict(cardFamily="Unreviewed"), dict(rawTransactions=["00" * 15]),
                       dict(resultFields=[{"title": "Holder Name", "value": "Private"}])]:
            source = self.source()
            source["cards"][0].update(change)
            with self.assertRaises(ValueError):
                prepare.owner_wallet(source, shift_days=-364)

    def test_old_decoded_backups_recover_raw_records(self):
        source = self.source()
        source["cards"][0]["transactions"] = [{"rawData": source["cards"][0].pop("rawTransactions")[0]}]
        output = prepare.owner_wallet(source, shift_days=-364)
        self.assertEqual(len(output["cards"][0]["rawTransactions"]), 1)
        self.assertNotIn("transactions", output["cards"][0])

    def test_counter_replacements_keep_unknown_date_history_in_order(self):
        card = prepare.base_card(1, "NAMANE", "ISO7816", "input")
        records = []
        for counter in [9003, 9002, 9001]:
            raw = bytearray(27)
            raw[0] = 1
            raw[6:10] = counter.to_bytes(4, "big")
            records.append(raw.hex())
        card["rawTransactions"] = records
        result = prepare.owner_wallet({"cards": [card]}, shift_days=-364)["cards"][0]
        self.assertEqual([int.from_bytes(bytes.fromhex(raw)[6:10], "big") for raw in result["rawTransactions"]], [3, 2, 1])

    def test_distinct_octopus_records_with_equal_balances_do_not_collapse(self):
        card = prepare.base_card(1, "Octopus", "FeliCa", "input")
        first = bytearray(16)
        first[0] = 17
        first[10:14] = (250).to_bytes(4, "big")
        second = bytearray(first)
        second[0] = 18
        card["rawTransactions"] = [first.hex(), second.hex(), first.hex()]
        result = prepare.owner_wallet({"cards": [card]}, shift_days=-364)["cards"][0]["rawTransactions"]
        self.assertEqual(len(set(result)), 2)
        self.assertEqual(result[0], result[2])
        self.assertTrue(all(bytes.fromhex(raw)[10:14] == first[10:14] for raw in result))

    def test_launcher_rejects_artwork_and_duplicate_ids(self):
        for mutation in (lambda x: x.update(faceAssets={"photo": "bytes"}),
                         lambda x: x["cards"][0].update(faceImageFileName="private.png"),
                         lambda x: x["cards"].append(copy.deepcopy(x["cards"][0]))):
            with tempfile.TemporaryDirectory() as temporary:
                data = prepare.mock_wallet()
                mutation(data)
                Path(temporary, "mock-wallet.json").write_text(json.dumps(data))
                with patch.object(launch, "DATA", Path(temporary)), self.assertRaises(ValueError):
                    launch.wallet("mock")

    def test_android_launcher_refuses_physical_device_before_writing(self):
        with patch.object(launch, "run", return_value="0") as run:
            with self.assertRaises(ValueError):
                launch.launch_android("physical-serial", "ad.neko.cardbal.android", prepare.mock_wallet())
            self.assertEqual(run.call_count, 1)

    def test_ios_launcher_only_copies_json_and_passes_sample_environment(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(launch, "run", side_effect=[temporary, b""]) as run, patch.object(launch.subprocess, "run"):
                launch.launch_ios("test-simulator", "ad.neko.cardbal", prepare.mock_wallet())
            path = Path(temporary, "Library/Application Support/CardBal/development/sample-wallet.json")
            self.assertEqual(json.loads(path.read_text()), prepare.mock_wallet())
            self.assertEqual(run.call_args.kwargs["env"]["SIMCTL_CHILD_CARDBAL_SAMPLE_BACKUP"], str(path))
            self.assertFalse(Path(temporary, "Library/Application Support/CardBal/cards.sqlite").exists())


@unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
class SwiftDevelopmentSampleTests(unittest.TestCase):
    def test_production_backup_model_and_retail_decoders(self):
        saved = (ROOT / "ios/CardBal/Models/SavedCardRecord.swift").read_text()
        store = (ROOT / "ios/CardBal/Models/CardWalletStore.swift").read_text()
        utils = (ROOT / "ios/CardBal/NFC/NFCUtils.swift").read_text()
        japanese = (ROOT / "ios/CardBal/NFC/Decoders/JapaneseICDecoder.swift").read_text()
        # Keep the production Codable fields, initializer and backup codec.
        # Platform color rendering and UI-only computed properties are omitted.
        model = saved[saved.index("struct SavedCardRecord:"):saved.index("    var transactions:")]
        for name in ["rawRecordHasContent", "normalizedHex"]:
            model += re.search(r"    (?:private )?static func " + name + r"\(.*?^    }", saved, re.M | re.S).group() + "\n"
        model += "}\n"
        fields = saved[saved.index("struct SavedCardField:"):saved.index("struct SavedCardColor:")]
        backup = store[store.index("struct CardBackupData:"):store.index("struct CardBackupImportResult")]
        data = utils[utils.index("extension Data {"):utils.index("struct BERTLVNode")]
        transaction = utils[utils.index("struct ResultField:"):utils.index("struct TransactionDecoderRegistry")]
        names = ["decodeEdyHistory", "decodeNanacoHistory", "decodeWAONHistory", "edyTransactionType",
                 "nanacoTransactionType", "waonTransactionType", "readMSBPackedBits", "dateFromElapsedDays", "makeJSTDate"]
        methods = "\n".join(re.search(r"    private static func " + name + r"\(.*?^    }", japanese, re.M | re.S).group()
                            .replace("private static", "static", 1) for name in names)
        adapters = '''
import Foundation
struct SavedCardColor: Codable, Hashable { var red: Double; var green: Double; var blue: Double }
enum SavedCardDesign: String, Codable { case classic, sunrise }
enum ImageFaceEnhancer: String, Codable { case mask, border, none }
enum SavedCardMarkerShape: String, Codable { case circle, square }
struct TransitApplication: Codable, Hashable {}
func formatUTF8OrHex(_ data: Data) -> String { data.hexString }
'''
        main = r'''
let root = URL(fileURLWithPath: CommandLine.arguments[1])
var total = 0
var retail = 0
for (name, count) in [("owner-wallet", 48), ("mock-wallet", 3)] {
    let input = try Data(contentsOf: root.appendingPathComponent("data/development/\(name).json"))
    let wallet = try CardBackupData.decoder.decode(CardBackupData.self, from: input)
    precondition(wallet.cards.count == count && wallet.faceAssets.isEmpty)
    let again = try CardBackupData.decoder.decode(CardBackupData.self, from: CardBackupData.encoder.encode(wallet))
    precondition(wallet.cards == again.cards)
    for card in wallet.cards {
        precondition(card.faceImageFileName == nil && card.isUsingImage != true)
        total += 1
        if name != "owner-wallet" { continue }
        for raw in card.rawTransactions {
            let tx: TransitTransaction?
            switch card.cardFamily {
            case "WAON": tx = RecordDecoder.decodeWAONHistory(block: Data(hexString: raw))
            case "nanaco": tx = RecordDecoder.decodeNanacoHistory(block: Data(hexString: raw))
            case "Rakuten Edy": tx = RecordDecoder.decodeEdyHistory(block: Data(hexString: raw))
            default: continue
            }
            precondition(tx != nil && tx!.date != nil && tx!.balanceAfter != nil)
            retail += 1
        }
    }
}
precondition(total == 51 && retail == 13)
print("PASS: 51 production backup cards; 13 retail capture histories")
'''
        with tempfile.TemporaryDirectory(prefix="cardbal-samples-") as temporary:
            directory = Path(temporary)
            source = directory / "main.swift"
            source.write_text(adapters + transaction + fields + model + backup + data + "\nstruct RecordDecoder {\n" + methods + "\n}\n" + main)
            binary = directory / "test"
            build = subprocess.run(["swiftc", str(source), "-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(binary), str(ROOT)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS:", result.stdout)


if __name__ == "__main__":
    unittest.main()
