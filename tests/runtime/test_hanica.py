"""Hanica balance-layout detection and history decoding, using invented bytes only."""
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.paths import ROOT

FIXTURE = ROOT / "tests/runtime/fixtures/hanica-layouts.json"


@unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
class HanicaRuntimeTests(unittest.TestCase):
    def test_layout_detection_dates_history_and_profile(self):
        utils = (ROOT / "ios/CardBal/NFC/NFCUtils.swift").read_text()
        models = utils[utils.index("struct ResultField:"):utils.index("struct TransactionDecoderRegistry")]
        data = utils[utils.index("extension Data {"):utils.index("struct BERTLVNode")]
        formatting = utils[utils.index("func formatCurrency("):utils.index("func formatFeliCaIDm(")]
        source = (ROOT / "ios/CardBal/NFC/Decoders/JapaneseICDecoder.swift").read_text()
        method = re.search(r"^    private static func decodeHanicaHistory\(.*?^    }", source, re.M | re.S)
        self.assertIsNotNone(method)
        decoder = "struct Decoder {\n" + method.group().replace("private static", "static", 1) + "\n}\n"
        main = r'''
let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
let iso = ISO8601DateFormatter()
for case let row as [String: Any] in fixture["cases"] as! [Any] {
    let name = row["name"] as! String
    let raw = row["blocks"] as! [String]
    let blocks = raw.map { Data(hexString: $0) }
    let layout = HanicaCardFormat.detectLayout(blocks)
    let expected = row["layout"] as? String
    precondition(layout?.name == expected, "\(name): layout \(layout?.name ?? "nil")")
    let confirmed = HanicaCardFormat.confirmedBalance(blocks)
    precondition(confirmed?.balance == row["balance"] as? Int, "\(name): balance")
    for index in blocks.indices {
        let value = HanicaCardFormat.value(at: index, in: blocks, layout: layout)
        let tx = Decoder.decodeHanicaHistory(block: blocks[index], context: blocks, index: index)!
        precondition(tx.rawData == raw[index], "\(name): raw data kept")
        if expected == nil {
            precondition(value == nil && !tx.amountKnown && tx.balanceAfter == nil && tx.amount == 0, "\(name): unconfirmed amounts shown")
        } else {
            let amount = (row["amounts"] as! [Int])[index], balance = (row["balances"] as! [Int])[index]
            let topUp = (row["topUps"] as! [Bool])[index]
            precondition(value?.amount == amount && value?.balance == balance && value?.isTopUp == topUp, "\(name): value \(index)")
            precondition(tx.amountKnown && tx.amount == Decimal(amount) && tx.balanceAfter == Decimal(balance), "\(name): transaction \(index)")
            precondition(tx.category == (topUp ? .topUp : .bus) && tx.type == (topUp ? "Top-up" : "Bus"), "\(name): category \(index)")
        }
    }
    // Saved history decoded without its neighbours never invents a balance.
    let lone = Decoder.decodeHanicaHistory(block: blocks[0], context: [], index: 0)!
    precondition(!lone.amountKnown && lone.balanceAfter == nil, "\(name): lone record")
}
let record = fixture["record"] as! [String: Any]
let block = Data(hexString: record["raw"] as! String)
let decoded = HanicaCardFormat.decode(block)!
precondition(iso.string(from: decoded.boardingDate!) == record["boarding"] as! String)
precondition(iso.string(from: decoded.date!) == record["date"] as! String)
precondition(decoded.boardingStop == record["boardingStop"] as! String && decoded.alightingStop == record["alightingStop"] as! String)
precondition(Int(decoded.typeCode) == record["type"] as! Int && decoded.hasValidDates)
let ride = Decoder.decodeHanicaHistory(block: block, context: [block], index: 0)!
precondition(ride.date == decoded.date && ride.time == "08:32" && ride.category == .bus)
precondition(ride.location == "Bus stop 1201 → 1234" && ride.entryStation == "Bus stop 1201" && ride.exitStation == "Bus stop 1234")
let undated = HanicaCardFormat.decode(Data(hexString: fixture["undated"] as! String))!
precondition(undated.date == nil && !undated.hasValidDates)
precondition(Decoder.decodeHanicaHistory(block: Data(hexString: fixture["undated"] as! String), context: [], index: 0)!.date == nil)
for bad in [Data(repeating: 0, count: 16), Data(repeating: 1, count: 15), Data(repeating: 1, count: 17)] {
    precondition(HanicaCardFormat.decode(bad) == nil && !HanicaCardFormat.isLogBlock(bad))
    precondition(Decoder.decodeHanicaHistory(block: bad, context: [bad], index: 0) == nil)
}
precondition(HanicaCardFormat.detectLayout([]) == nil && HanicaCardFormat.confirmedBalance([]) == nil)
let profile = FeliCaProfile.matching(candidates: ["84a1"])!
precondition(profile.displayName == "Hanica" && profile.systemCode == "84A1" && profile.serviceCode == "898F")
precondition(profile.serviceCodeLittleEndian == Data([0x8F, 0x89]) && HanicaCardFormat.service == Data([0x8F, 0x89]))
precondition(profile.detectedBrand(using: ["84A1"]) == "Hanica")
precondition(profile.parseBalance(block, Date()) == nil)
print("PASS Hanica layouts, dates, history and profile")
'''
        program = "import Foundation\n" + models + data + formatting + decoder + main
        with tempfile.TemporaryDirectory(prefix="cardbal-hanica-") as directory:
            path = Path(directory)
            (path / "main.swift").write_text(program)
            sources = [ROOT / "ios/CardBal/NFC/Profiles" / name for name in
                       ["HanicaCardFormat.swift", "RyutoCardFormat.swift", "KMTCardFormat.swift", "FeliCaProfiles.swift"]]
            build = subprocess.run(["swiftc", str(path / "main.swift"), *map(str, sources), "-o", str(path / "test")],
                                   capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(path / "test"), str(FIXTURE)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS", result.stdout)


class HanicaDeclarationTests(unittest.TestCase):
    def test_iphone_declares_the_hanica_system(self):
        with (ROOT / "ios/CardBal/Info.plist").open("rb") as handle:
            codes = plistlib.load(handle)["com.apple.developer.nfc.readersession.felica.systemcodes"]
        self.assertIn("84A1", codes)
        self.assertEqual(len(codes), len(set(codes)))

    def test_hanica_format_is_built_into_the_app(self):
        project = (ROOT / "CardBal.xcodeproj/project.pbxproj").read_text()
        self.assertIn("HanicaCardFormat.swift in Sources", project)
        self.assertIn("path = HanicaCardFormat.swift;", project)


if __name__ == "__main__":
    unittest.main()
