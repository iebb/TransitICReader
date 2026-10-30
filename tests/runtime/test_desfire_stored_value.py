"""Production Swift DESFire readers/parsers against invented shared vectors."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from tools.paths import ROOT


@unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
class DesfireStoredValueTests(unittest.TestCase):
    def test_wire_guards_and_all_five_layout_variants(self):
        main = r'''
import Foundation
struct Document: Decodable { let vectors: [Vector] }
struct Vector: Decodable {
    let name: String; let tag: UInt8; let files: [String: String]; let recordSizes: [String: Int]; let expected: Expected
}
struct Expected: Decodable {
    let family: String; let currency: String; let balance: Int64; let serial: String
    let histories: Int; let passes: Int; let date: Double; let amount: Int64?
}
func bytes(_ value: String) -> Data {
    let chars = Array(value)
    return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! })
}
func expectFailure(_ action: () async throws -> Void) async {
    do { try await action(); preconditionFailure("Invalid response accepted") }
    catch is DesfireReadError {}
    catch { preconditionFailure("Unexpected error type") }
}
@main struct Tests {
 static func main() async throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let document = try JSONDecoder().decode(Document.self, from: data)
    for vector in document.vectors {
        let files = Dictionary(uniqueKeysWithValues: vector.files.map { (UInt8($0.key)!, bytes($0.value)) })
        let sizes = Dictionary(uniqueKeysWithValues: vector.recordSizes.map { (UInt8($0.key)!, $0.value) })
        let card = StoredValueProtocol.parseFiles(tag: vector.tag, files: files, recordSizes: sizes)!
        let expected = vector.expected
        precondition(card.family == expected.family && card.currencyCode == expected.currency, vector.name)
        precondition(card.balanceMinor == expected.balance && card.serial == expected.serial, vector.name)
        let history = StoredValueProtocol.parseHistories(card.rawTransactions, expectedFamily: expected.family)
        precondition(history.count == expected.histories, "History count: \(vector.name) \(history.count)")
        precondition(card.passes.count == expected.passes, "Pass count: \(vector.name)")
        precondition(history.contains { $0.dateEpochSeconds == expected.date && $0.amountMinor == expected.amount }, vector.name)
        if [2,3,4].contains(vector.tag) {
            precondition(history.filter { $0.kind == "reload" }.allSatisfy { $0.balanceMinor == nil })
            var changedPurse = files[2]!; changedPurse[0] ^= 1
            let repeatedSummary = StoredValueProtocol.envelope(tag: vector.tag, kind: 2, index: 0, data: changedPurse)
            precondition(StoredValueProtocol.parseHistories(card.rawTransactions + [repeatedSummary]).count == history.count)
        }
        precondition(StoredValueProtocol.parseHistories(card.rawTransactions, expectedFamily: "Other").isEmpty)
        if vector.tag == 1 { precondition(history[0].amountMinor == nil && history[0].balanceMinor == -125) }
        for raw in card.rawTransactions {
            precondition(StoredValueProtocol.parseHistory(raw + "00") == nil)
            precondition(StoredValueProtocol.parseHistory("00" + raw) == nil)
            precondition(StoredValueProtocol.parseHistory(String(raw.dropLast(2))) == nil)
        }
    }
    precondition(StoredValueProtocol.parseFiles(tag: 1, files: [7: Data(repeating: 0, count: 15)]) == nil)
    precondition(StoredValueProtocol.parseFiles(tag: 5, files: [8: Data([0,1,2,3,4])]) == nil, "ID-only support")
    precondition(StoredValueProtocol.parseHistory("not hex") == nil)
    precondition(StoredValueProtocol.localTime(year: 2023, day: 84, minute: 210, zone: "Europe/Helsinki") == nil)
    precondition(StoredValueProtocol.localTime(year: 2023, day: 301, minute: 210, zone: "Europe/Helsinki") == nil)
    precondition(StoredValueProtocol.localTime(year: 1997, day: 1, minute: 1440, zone: "Europe/Helsinki") == nil)
    for mode in [DesfireReadSession.WireMode.native, .wrapped] {
        var commands: [Data] = []
        let session = DesfireReadSession(mode: mode) { request in
            commands.append(request)
            let more = commands.count == 1
            return mode == .native ? Data(more ? [0xAF,1,2] : [0,3]) : Data(more ? [1,2,0x91,0xAF] : [3,0x91,0])
        }
        let result = try await session.command(0xBD, Data([1]))
        precondition(result == Data([1,2,3]))
        precondition(commands[1] == (mode == .native ? Data([0xAF]) : Data([0x90,0xAF,0,0,0])))
    }
    var selections: [Data] = []
    let selection = DesfireReadSession(mode: .wrapped) { selections.append($0); return Data([0x91,0]) }
    try await selection.selectApplication(0x534531)
    precondition(selections[0] == Data([0x90,0x5A,0,0,3,0x31,0x45,0x53,0]))
    try await selection.selectApplication(0xEF2014)
    precondition(selections[1] == Data([0x90,0x5A,0,0,3,0x14,0x20,0xEF,0]))
    await expectFailure { _ = try await selection.command(0x3D, Data([1,2])) }
    precondition(selections.count == 2, "Write reached transport")
    for invalid in [Data(), Data([0x91]), Data([0x90,0]), Data([1,0x91,0x9D])] {
        let session = DesfireReadSession(mode: .wrapped) { _ in invalid }
        await expectFailure { _ = try await session.command(0x60) }
    }
    var chained = 0
    let endless = DesfireReadSession(mode: .wrapped) { _ in chained += 1; return Data([0x91,0xAF]) }
    await expectFailure { _ = try await endless.command(0x60) }
    precondition(chained == 64)
    var calls = 0
    let records = DesfireReadSession(mode: .wrapped) { request in
        calls += 1
        if request[1] == 0xF5 { return Data([4,0,0xEE,0xEE,12,0,0,2,0,0,2,0,0,0x91,0]) }
        precondition(request[1] == 0xBB)
        return Data(repeating: 0, count: 24) + Data([0x91,0])
    }
    let read = try await records.readFile(4)
    precondition(read.recordSize == 12 && read.data.count == 24 && calls == 2)
    for setting in [Data([0,3,0,0,16,0,0]), Data([4,0,0,0,12,0,0,1,0,0,2,0,0]), Data([0,0,0,0,1,0,1])] {
        let guarded = DesfireReadSession(mode: .wrapped) { request in
            precondition(request[1] == 0xF5, "Invalid file triggered data read")
            return setting + Data([0x91,0])
        }
        await expectFailure { _ = try await guarded.readFile(1) }
    }
    var selectedOnly = 0
    let unknown = try await StoredValueProtocol.readFirst(mode: .wrapped) { request in
        if request[1] == 0x5A { selectedOnly += 1; return Data([0x91,0]) }
        return Data([0x91,0xF0])
    }
    precondition(unknown == nil && selectedOnly == 5, "AID-only card accepted")
    print("Verified five synthetic DESFire layouts, shared envelopes, timezones and guarded read transport")
 }
}
'''
        with tempfile.TemporaryDirectory(prefix="cardbal-desfire-tests-") as directory:
            directory = Path(directory)
            runner = directory / "Runner.swift"
            runner.write_text(main)
            executable = directory / "desfire-tests"
            result = subprocess.run([
                "swiftc", "-parse-as-library", str(ROOT / "ios/CardBal/NFC/Profiles/StoredValueProtocol.swift"),
                str(runner), "-o", str(executable),
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(executable), str(ROOT / "tests/runtime/fixtures/desfire_vectors.json")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Verified five synthetic", result.stdout)


if __name__ == "__main__":
    unittest.main()
