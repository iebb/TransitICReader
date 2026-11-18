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
var concession = purse(); concession.replaceSubrange(8..<10, with: [0x80, 0x08])
precondition(CEPASProtocol.parsePurse(concession)!.family == "Concession")
precondition(CEPASProtocol.parsePurse(concession)!.serial == "8008123456789012")
var unknown = purse(); unknown[8] = 0x50
let generic = CEPASProtocol.parsePurse(unknown)! // no brand is guessed from other CANs
precondition(generic.family == "CEPAS" && generic.serial == "5010123456789012" && generic.balanceMinor == -100)
unknown[8] = 0x81
precondition(CEPASProtocol.parsePurse(unknown)!.family == "CEPAS") // 81xx is outside 8000–8009
var malformed = purse(); malformed[10] = 0xA0
precondition(CEPASProtocol.parsePurse(malformed) == nil)
malformed = purse(); malformed[8] = 0x5A
precondition(CEPASProtocol.parsePurse(malformed) == nil) // invalid BCD in an unbranded CAN
for version: UInt8 in [0, 0xFF] {
    var bad = unknown; bad[0] = version
    precondition(CEPASProtocol.parsePurse(bad) == nil)
}
for invalid in [Data(unknown.prefix(62)), unknown + Data(repeating: 0, count: 200)] {
    precondition(CEPASProtocol.parsePurse(invalid) == nil)
}
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
    precondition(failed == nil && count == 17) // purse 3, then 0...15 without 3, each rejected
}
// A refused SELECT is retried once with Le, then GET PURSE 3 is tried once;
// the case-3 SELECT's file ID is never rewritten as Le.
var commands: [Data] = []
let refused = await CEPASProtocol.read { command in commands.append(command); return Data([0x6A, 0x82]) }
precondition(refused == nil)
precondition(commands.map(hex) == ["00A40000024000", "00A4000002400000", "9032030000"])
commands = []
let wrongLength = await CEPASProtocol.read { command in commands.append(command); return Data([0x6C, 63]) }
precondition(wrongLength == nil)
precondition(commands.map(hex) == ["00A40000024000", "00A4000002400000", "00A400000240003F", "9032030000", "903203003F"])
var count = 0
let loop = await CEPASProtocol.read { _ in count += 1; return Data([0x61, 1]) }
precondition(loop == nil && count == 48)
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

// SELECT fallback: case-3 refused, the Le form accepted.
var logs: [String] = []
commands = []
let withLe = await CEPASProtocol.read(exchange: { command in
    commands.append(command)
    switch hex(command) {
    case "00A40000024000": return Data([0x67, 0x00])
    case "00A4000002400000", "90320300010010": return ok(hex(command) == "90320300010010" ? record() : Data())
    case "9032030000": return ok(purse(history: 1))
    default: fatalError("unexpected command")
    }
}, log: { logs.append($0) })
precondition(withLe!.purseID == 3 && withLe!.historyComplete && withLe!.rawHistory.count == 1)
precondition(commands.map(hex) == ["00A40000024000", "00A4000002400000", "9032030000", "90320300010010"])
precondition(logs == ["select: status 6700, 0 bytes"])

// Both SELECTs refused: GET PURSE 3 is still tried once, with a warning.
logs = []
commands = []
let unselected = await CEPASProtocol.read(exchange: { command in
    commands.append(command)
    return hex(command) == "9032030000" ? ok(purse(history: 0)) : Data([0x6A, 0x82])
}, log: { logs.append($0) })
precondition(unselected!.balanceMinor == -100 && unselected!.purseID == 3)
precondition(commands.map(hex) == ["00A40000024000", "00A4000002400000", "9032030000"])
precondition(logs == ["select: status 6A82, 0 bytes", "select-le: status 6A82, 0 bytes",
                      "File 4000 not selected; trying purse 3 once", "Warning: purse read without selecting file 4000"])

// Purse 3 missing, purse 0 malformed, purse 1 valid: purse 1 and its history are used.
logs = []
commands = []
let other = await CEPASProtocol.read(exchange: { command in
    commands.append(command)
    switch hex(command) {
    case "00A40000024000": return ok(Data())
    case "9032030000": return Data([0x6A, 0x83])
    case "9032000000": return ok(Data(purse().prefix(40)))
    case "9032010000": return ok(purse(0x10, history: 1))
    case "90320100010010": return ok(record())
    default: fatalError("unexpected command")
    }
}, log: { logs.append($0) })
precondition(other!.purseID == 1 && other!.family == "EZ-Link" && other!.balanceMinor == -100)
precondition(other!.historyComplete && CEPASProtocol.decodeHistory(other!.rawHistory[0])!.amountMinor == -275)
precondition(commands.map(hex) == ["00A40000024000", "9032030000", "9032000000", "9032010000", "90320100010010"])
precondition(logs == ["purse 3: status 6A83, 0 bytes", "parse purse 0: length not 63..256, 40 bytes, L -",
                      "Warning: purse 3 unavailable, using purse 1"])

// Every slot fails a parse rule: unsupported, never a balance, and the log says why.
func rejected(_ id: UInt8) -> Data {
    var p = purse()
    switch id % 4 {
    case 0: p[0] = 0
    case 1: p[41] = 2
    case 2: p[12] = 0x3A
    default: p = Data(p.prefix(62))
    }
    return p
}
logs = []
count = 0
let none = await CEPASProtocol.read(exchange: { command in
    count += 1
    return hex(command) == "00A40000024000" ? ok(Data()) : ok(rejected(command[2]))
}, log: { logs.append($0) })
precondition(none == nil && count == 17)
for rule in ["version 00/FF", "63+L exceeds length, 63 bytes, L 02", "CAN not BCD", "length not 63..256, 62 bytes, L 00"] {
    precondition(logs.contains { $0.contains(rule) }, rule)
}
precondition(logs.last == "Unsupported: no valid purse in 16 tried")
precondition(!logs.joined().contains("1234567890")) // no CAN digits or payload in the log
// SELECT fallback with the only tried purse invalid stays unsupported too.
logs = []
commands = []
let unselectedInvalid = await CEPASProtocol.read(exchange: { command in
    commands.append(command)
    return hex(command) == "9032030000" ? ok(rejected(3)) : Data([0x6A, 0x82])
}, log: { logs.append($0) })
precondition(unselectedInvalid == nil && commands.count == 3)
precondition(logs.last == "Unsupported: no valid purse in 1 tried")

// A lost card or an unsupported command ends the purse search at once.
struct TagLost: Error {}
logs = []
count = 0
let lost = await CEPASProtocol.read(exchange: { command in
    count += 1
    if count == 1 { return ok(Data()) }
    throw TagLost()
}, log: { logs.append($0) })
precondition(lost == nil && count == 2)
precondition(logs == ["purse 3: no reply (TagLost)", "Unsupported: no valid purse (card connection lost: TagLost)"])
count = 0
let unsupported = await CEPASProtocol.read { _ in count += 1; return count == 1 ? ok(Data()) : Data([0x6D, 0]) }
precondition(unsupported == nil && count == 2)
// Endless chaining stops at the command limit.
logs = []
count = 0
let limited = await CEPASProtocol.read(exchange: { _ in
    count += 1
    return count == 1 ? ok(Data()) : Data([0x61, 1])
}, log: { logs.append($0) })
precondition(limited == nil && count == 65)
precondition(logs.last == "Unsupported: no valid purse (command limit reached)")

// History failures keep the purse and say where reading stopped.
logs = []
count = 0
let partial = await CEPASProtocol.read(exchange: { _ in
    count += 1
    return count == 1 ? ok(Data()) : count == 2 ? ok(purse(history: 2)) : Data([0x69, 0x82])
}, log: { logs.append($0) })
precondition(partial!.balanceMinor == -100 && !partial!.historyComplete)
precondition(logs == ["history 0: status 6982, 0 bytes", "Warning: history incomplete, 0 of 2 records"])
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
