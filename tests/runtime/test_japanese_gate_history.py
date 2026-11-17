"""Japanese IC history shows only gate events and records with a real date, through production Swift."""
import json
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.paths import ROOT

FIXTURE = ROOT / "tests/runtime/fixtures/nimoca-gate-history.json"
MAIN_HISTORY = ROOT / "tests/runtime/fixtures/japanese-main-history.json"


@unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
class JapaneseGateHistoryTests(unittest.TestCase):
    def test_nimoca_history_and_samples_hide_undated_and_unknown_records(self):
        utils = (ROOT / "ios/CardBal/NFC/NFCUtils.swift").read_text()
        models = utils[utils.index("struct ResultField:"):utils.index("struct TransactionDecoderRegistry")]
        data = utils[utils.index("extension Data {"):utils.index("struct BERTLVNode")]
        formatting = utils[utils.index("func formatCurrency("):utils.index("func formatFeliCaIDm(")]
        source = (ROOT / "ios/CardBal/NFC/Decoders/JapaneseICDecoder.swift").read_text()
        # Every record decoder of the production type, from decodeTransaction to its end.
        members = source[source.index("    static func decodeTransaction("):source.index("\n}\n\n// MARK: - Profiles")]
        self.assertIsNotNone(re.search(r"private static func packedFeliCaDate\(", members))
        # The keys the 090F rows decode to are the app's English labels for them.
        strings = (ROOT / "ios/CardBal/Resources/en.lproj/Localizable.strings").read_text()
        for row in json.loads(MAIN_HISTORY.read_text())["rows"]:
            self.assertIn(f'"{row["type"]}" = "{row["label"]}";', strings)
        stubs = r'''
enum ICCardBrand {
    case edy, waon, nanaco, okica, octopus, other
    static func from(family: String) -> ICCardBrand {
        let family = family.lowercased()
        for (name, brand) in [("edy", ICCardBrand.edy), ("waon", .waon), ("nanaco", .nanaco), ("okica", .okica), ("octopus", .octopus)]
            where family.contains(name) { return brand }
        return .other
    }
}
struct Localizer { static func localize(_ key: String) -> String { key } }
final class BusResolver { static let shared = BusResolver(); func resolve(_ code: Int) -> String? { nil } }
/// The app's JPStationCodes.csv, read from the repository instead of the app bundle.
final class StationResolver {
    static let shared = StationResolver()
    private var stationMap: [String: String] = [:]
    private init() {
        let text = try! String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)
        for line in text.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: ",")
            if parts.count >= 2 { stationMap[parts[0].uppercased()] = parts[1] }
        }
    }
    func resolve(_ code: Int) -> String? { stationMap[String(format: "%05X", code)] }
}
'''
        main = r'''
func json(_ path: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
}
func day(_ date: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
}
let fixture = json(CommandLine.arguments[1])
let transit = (fixture["transit"] as! [String]).map { Data(hexString: $0) }
let transactions = (fixture["transactions"] as! [String]).map { Data(hexString: $0) }
let decoded = transit.indices.map {
    Decoder.decodeTransaction(block: transit[$0], context: transit, index: $0, family: "Nimoca", kind: .transit, relatedContext: transactions)
}
// The 10CB block (the last entry station, E915, then zeros) was "Transit Activity (15)" on 1999/11/30.
precondition(decoded[3] == nil, "10CB record shown")
let rows = fixture["rows"] as! [[String: Any]]
precondition(decoded.compactMap { $0 }.count == rows.count)
for (tx, row) in zip(decoded, rows) {
    let tx = tx!
    precondition(tx.type == row["type"] as! String && tx.amount == Decimal(row["amount"] as! Int), "\(row)")
    precondition(day(tx.date!) == row["date"] as! String && tx.time == row["time"] as? String, "\(row)")
    precondition((tx.type == "Entry" ? tx.entryStation : tx.exitStation) == row["station"] as? String, "\(row)")
}
let uses = transactions.indices.map {
    Decoder.decodeTransaction(block: transactions[$0], context: transactions, index: $0, family: "Nimoca")
}
precondition(uses[0]?.date != nil && uses[1]?.date != nil && uses[2] == nil, "uninitialised 090F block shown")

// The gate filter leaves 090F main history alone: a purchase, a bus ride and a top-up keep their type and amount.
let mainHistory = json(CommandLine.arguments[4])
let mainBlocks = (mainHistory["blocks"] as! [String]).map { Data(hexString: $0) }
let mainRows = mainHistory["rows"] as! [[String: Any]]
for family in mainHistory["families"] as! [String] {
    for (index, row) in mainRows.enumerated() {
        let tx = Decoder.decodeTransaction(block: mainBlocks[index], context: mainBlocks, index: index, family: family)
        precondition(tx != nil, "\(family) 090F row hidden: \(row)")
        let label = "\(family) \(row)"
        precondition(Int(mainBlocks[index][1]) == row["process"] as! Int, label)
        precondition(tx!.type == row["type"] as! String && tx!.category.rawValue == row["category"] as! String, "\(label): \(tx!.type)")
        precondition(tx!.amount == Decimal(row["amount"] as! Int) && tx!.balanceAfter == Decimal(row["balance"] as! Int), label)
        precondition(day(tx!.date!) == row["date"] as! String && tx!.time == row["time"] as? String, label)
    }
}

// Known events stay hidden without a real day; time alone is dropped when it is not one.
func gate(_ hex: String) -> TransitTransaction? {
    Decoder.decodeTransaction(block: Data(hexString: hex), context: [], index: 0, family: "Nimoca", kind: .transit)
}
precondition(gate("A000E915000000000909000000000000") == nil)
precondition(gate("A000E915000033A00909000000000000") == nil)  // 2025-13-00
precondition(gate("2000E91F0000325E0923040100000000") == nil)  // 2025-02-30
precondition(gate("4000E91F000033890923040100000000") == nil)  // undocumented event
let noTime = gate("2000E91F000033892599040100000000")!
precondition(noTime.time == nil && day(noTime.date!) == "2025-12-09")
precondition(Calendar.current.component(.hour, from: noTime.date!) == 0)

// Sample wallets: only each card's 10CB block and one uninitialised 090F block are hidden.
let japanese: Set<String> = ["Suica", "Japan Transit IC", "Manaca", "Nimoca", "SUGOCA", "Hayakaken", "ICOCA"]
var shown = 0, hidden: [String] = [], hiddenUses: [String] = []
for card in json(CommandLine.arguments[2])["cards"] as! [[String: Any]] {
    guard card["technology"] as? String == "FeliCa", let family = card["cardFamily"] as? String, japanese.contains(family) else { continue }
    let history = (card["rawTransitHistory"] as! [String]).filter { $0.contains { $0 != "0" } }
    let records = (card["rawTransactions"] as! [String]).filter { $0.contains { $0 != "0" } }
    let related = records.map { Data(hexString: $0) }
    for (index, hex) in history.enumerated() {
        let block = Data(hexString: hex)
        if let tx = Decoder.decodeTransaction(block: block, context: history.map { Data(hexString: $0) }, index: index,
                                              family: family, kind: .transit, relatedContext: related) {
            precondition(["Entry", "Exit", "Discount Entry"].contains(tx.type) && tx.date != nil, hex)
            shown += 1
        } else {
            precondition(block[2...].allSatisfy { $0 == 0 }, "gate record hidden: \(hex)")
            hidden.append(hex)
        }
    }
    for (index, hex) in records.enumerated() {
        if let tx = Decoder.decodeTransaction(block: Data(hexString: hex), context: related, index: index, family: family) {
            precondition((2000...2127).contains(Calendar.current.component(.year, from: tx.date!)), hex)
        } else {
            hiddenUses.append(hex)
        }
    }
}
precondition(shown == 17 && hidden.count == 6, "shown \(shown), hidden \(hidden)")
precondition(hiddenUses == ["00000000000000002300001F0000161D"], "\(hiddenUses)")
print("PASS Japanese gate history: 3 Nimoca rows, 17 sample gate records and 090F purchase, bus and top-up rows kept")
'''
        program = ("import Foundation\n" + models + data + formatting + stubs
                   + "struct Decoder {\n" + members + "\n}\n" + main)
        with tempfile.TemporaryDirectory(prefix="cardbal-gate-") as directory:
            path = Path(directory)
            (path / "main.swift").write_text(program)
            sources = [ROOT / "ios/CardBal/NFC/Profiles" / name for name in
                       ["HanicaCardFormat.swift", "RyutoCardFormat.swift", "KMTCardFormat.swift", "FeliCaProfiles.swift"]]
            build = subprocess.run(["swiftc", str(path / "main.swift"), *map(str, sources), "-o", str(path / "test")],
                                   capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(path / "test"), str(FIXTURE), str(ROOT / "data/development/owner-wallet.json"),
                                     str(ROOT / "ios/CardBal/Resources/JPStationCodes.csv"), str(MAIN_HISTORY)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
