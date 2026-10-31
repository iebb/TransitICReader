"""Exercise the independent Swift CEPAS codec with invented bytes, never captures."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from tools.paths import ROOT


@unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
class CEPASProtocolTests(unittest.TestCase):
    def test_wire_status_money_history_and_file_selection(self):
        program = r'''
import Foundation
func purse(_ prefix: UInt8 = 0x11, history: Int = 3) -> Data {
    var p = Data(repeating: 0, count: 63)
    p[0] = 2; p[1] = 1; p[2] = 0xFF; p[3] = 0xFF; p[4] = 0x9C
    p.replaceSubrange(8..<16, with: [prefix, prefix == 0x11 ? 0x10 : 0x00, 0x12, 0x34, 0x56, 0x78, 0x90, 0x12])
    p[24] = 0x20; p[25] = 0x10; p[26] = 0x10; p[27] = 0x20
    p[40] = UInt8(history)
    return p
}
func record(_ type: UInt8 = 0x30, amount: Int32 = -275, seconds: UInt32 = 1_000_000_000) -> Data {
    var p = Data(repeating: 0, count: 16)
    p[0] = type
    let unsigned = UInt32(bitPattern: amount)
    p[1] = UInt8((unsigned >> 16) & 255); p[2] = UInt8((unsigned >> 8) & 255); p[3] = UInt8(unsigned & 255)
    for i in 0..<4 { p[4 + i] = UInt8((seconds >> ((3-i)*8)) & 255) }
    p.replaceSubrange(8..<16, with: Array("ABC-DEF ".utf8))
    return p
}
func ok(_ p: Data) -> Data { p + Data([0x90, 0]) }
func hex(_ p: Data) -> String { p.map { String(format: "%02X", $0) }.joined() }
let parsed = CEPASProtocol.parsePurse(purse())!
precondition(Date(timeIntervalSince1970: TimeInterval(CEPASProtocol.epoch)) == ISO8601DateFormatter().date(from: "1994-12-31T16:00:00Z"))
precondition(parsed.family == "NETS FlashPay" && parsed.serial == "1110123456789012")
precondition(parsed.balanceMinor == -100 && parsed.historyCount == 3 && parsed.version == 2)
precondition(CEPASProtocol.parsePurse(purse(0x10))!.family == "EZ-Link")
for invalid in [Data(), Data(purse().prefix(62)), purse() + Data(repeating: 0, count: 200)] {
    precondition(CEPASProtocol.parsePurse(invalid) == nil)
}
var unknown = purse(); unknown[8] = 0x80
precondition(CEPASProtocol.parsePurse(unknown) == nil) // account-based CANs aren't inferred
var malformed = purse(); malformed[10] = 0xA0
precondition(CEPASProtocol.parsePurse(malformed) == nil)
malformed = purse(); malformed[41] = 1
precondition(CEPASProtocol.parsePurse(malformed) == nil) // issuer data/options truncated
let raw = CEPASProtocol.encodeHistory(record())!
precondition(raw.count == 21)
let tx = CEPASProtocol.decodeHistory(raw)!
precondition(tx.amountMinor == -275 && tx.kind == .train && tx.type == "MRT")
precondition(tx.userData == "ABC-DEF" && tx.hasMonetaryAmount)
precondition(tx.timestamp == Date(timeIntervalSince1970: 1_788_889_600))
precondition(CEPASProtocol.decodeHistory(CEPASProtocol.encodeHistory(record(3, amount: 1000))!)!.kind == .topUp)
precondition(CEPASProtocol.decodeHistory(CEPASProtocol.encodeHistory(record(0x76, amount: 275))!)!.amountMinor == 275)
precondition(!CEPASProtocol.decodeHistory(CEPASProtocol.encodeHistory(record(0xF0))!)!.hasMonetaryAmount)
precondition(CEPASProtocol.decodeHistory(CEPASProtocol.encodeHistory(record(0xAA))!)!.kind == .unknown)
precondition(CEPASProtocol.decodeHistory(CEPASProtocol.encodeHistory(record(seconds: 0x80000000))!)!.timestamp!.timeIntervalSince1970 == 2_936_373_248)
precondition(CEPASProtocol.decodeHistory(CEPASProtocol.encodeHistory(record(seconds: 0))!)!.timestamp == nil)
precondition(CEPASProtocol.decodeHistory(Data(raw.dropLast())) == nil)
precondition(CEPASProtocol.decodeHistory(raw + Data([0])) == nil)
var future = raw; future[3] = 2
precondition(CEPASProtocol.decodeHistory(future) == nil)
precondition(CEPASProtocol.encodeHistory(Data(repeating: 0, count: 16)) == nil)
precondition(CEPASProtocol.encodeHistory(Data(repeating: 255, count: 16)) == nil)
var calls: [Data] = []
var selected = false
let card = await CEPASProtocol.read { command in
    calls.append(command)
    switch hex(command) {
    case "00A40000024000": selected = true; return ok(Data())
    case "9032030000": return selected ? ok(purse()) : Data([0x6A, 0x82])
    case "90320300010030": return ok(record() + record(0x31, amount: -125))
    case "90320300010210": return ok(record(0x75, amount: 1000))
    default: fatalError("unexpected command")
    }
}
precondition(card!.historyComplete && card!.rawHistory.count == 3)
precondition(calls.map(hex) == ["00A40000024000", "9032030000", "90320300010030", "90320300010210"])
let saved = try JSONDecoder().decode([Data].self, from: JSONEncoder().encode(card!.rawHistory))
precondition(CEPASProtocol.decodeHistory(saved[0])!.amountMinor == -275)
var lengthCommands: [Data] = []
let corrected = await CEPASProtocol.read { command in
    lengthCommands.append(command)
    if lengthCommands.count == 1 { return ok(Data()) }
    return lengthCommands.count == 2 ? Data([0x6C, 63]) : ok(purse(history: 0))
}
precondition(corrected!.historyComplete && lengthCommands.count == 3 && lengthCommands[2].last == 63)
var chains: [Data] = []
let chained = await CEPASProtocol.read { command in
    chains.append(command)
    if chains.count == 1 { return ok(Data()) }
    return chains.count == 2 ? purse(history: 0).prefix(20) + Data([0x61, 43]) : ok(Data(purse(history: 0).dropFirst(20)))
}
precondition(chained != nil && chains[2] == Data([0, 0xC0, 0, 0, 43]))
for response in [Data(), Data([0x90]), Data([0x91, 0]), Data([0x90, 1]), ok(Data(purse().prefix(5))), purse() + Data([0x69, 0x82])] {
    var count = 0
    let failed = await CEPASProtocol.read { _ in count += 1; return count == 1 ? ok(Data()) : response }
    precondition(failed == nil && count == 2)
}
for status in [Data([0x6A, 0x82]), Data([0x6C, 63])] {
    var commands: [Data] = []
    let rejected = await CEPASProtocol.read { command in commands.append(command); return status }
    precondition(rejected == nil && commands == [CEPASProtocol.selectFileCommand()])
}
var count = 0
let loop = await CEPASProtocol.read { _ in count += 1; return Data([0x61, 1]) }
precondition(loop == nil && count == 16)
count = 0
let failedHistory = await CEPASProtocol.read { _ in
    count += 1
    if count == 1 { return ok(Data()) }
    return count == 2 ? ok(purse()) : Data([0x69, 0x82])
}
precondition(failedHistory!.balanceMinor == -100 && !failedHistory!.historyComplete && failedHistory!.rawHistory.isEmpty)
count = 0
let malformedHistory = await CEPASProtocol.read { _ in
    count += 1
    if count == 1 { return ok(Data()) }
    return count == 2 ? ok(purse()) : ok(Data(repeating: 1, count: 17))
}
precondition(malformedHistory!.rawHistory.isEmpty && !malformedHistory!.historyComplete)
var pages: [String] = []
let paged = await CEPASProtocol.read { command in
    pages.append(hex(command))
    switch pages.count {
    case 1: return ok(Data())
    case 2: return ok(purse(history: 17))
    case 3: return ok((0..<15).reduce(Data()) { bytes, _ in bytes + record() })
    case 4: return ok(record() + record())
    default: fatalError("unexpected page")
    }
}
precondition(paged!.historyComplete && paged!.rawHistory.count == 17)
precondition(pages.suffix(2) == ["903203000100F0", "90320300010F20"])
count = 0
let oversized = await CEPASProtocol.read { _ in
    count += 1
    if count == 1 { return ok(Data()) }
    return count == 2 ? ok(purse(history: 1)) : ok(record() + record())
}
precondition(oversized!.balanceMinor == -100 && !oversized!.historyComplete && oversized!.rawHistory.isEmpty)
precondition(CEPASProtocol.issuerTimeZone == "Asia/Singapore")
print("PASS CEPAS independent protocol")
'''
        with tempfile.TemporaryDirectory(prefix="cardbal-cepas-synthetic-") as directory:
            main = Path(directory) / "main.swift"
            main.write_text(program)
            binary = Path(directory) / "cepas-test"
            build = subprocess.run(["swiftc", str(ROOT / "ios/CardBal/NFC/Profiles/CEPASProtocol.swift"), str(main), "-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS CEPAS", result.stdout)


if __name__ == "__main__":
    unittest.main()
