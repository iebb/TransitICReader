"""Exercise the production Swift Snapper+ codec with invented station-free data."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.paths import ROOT


@unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
class SnapperPlusTests(unittest.TestCase):
    def test_identification_money_layouts_calendar_and_envelope(self):
        harness = r'''
import Foundation
func be(_ value: Int32) -> [UInt8] {
    let value = UInt32(bitPattern: value)
    return (0..<4).map { UInt8((value >> ((3 - $0) * 8)) & 255) }
}
func amount(_ type: UInt8 = 1, cost: Int32 = 325) -> Data {
    var data = Data(repeating: 0, count: 46)
    data[0] = type; data[1] = 0x2C
    data.replaceSubrange(2..<6, with: be(1575)); data.replaceSubrange(6..<10, with: be(42))
    data.replaceSubrange(10..<14, with: be(cost))
    data.replaceSubrange(14..<19, with: [1, 0x23, 0x45, 0x67, 0x80])
    data.replaceSubrange(26..<46, with: repeatElement(UInt8(255), count: 20))
    return data
}
func trip(_ timestamp: String = "20261030123045") -> Data {
    var data = Data(repeating: 0, count: 52)
    data[0] = 1; data[1] = 0x32; data[4] = 2; data[5] = 7; data[51] = 0x10
    let chars = Array(timestamp)
    for index in 0..<7 { data[13 + index] = UInt8(String(chars[index * 2...index * 2 + 1]), radix: 16)! }
    return data
}
let aid = SnapperPlusProtocol.applicationAID
var purse = Data(repeating: 0, count: 47); purse[3] = 2
let fci = Data([0x6F, 49, 0xB0, 47]) + purse
assert(SnapperPlusProtocol.purseIssuer(fci) == 2)
assert(SnapperPlusProtocol.purseIssuer(Data(fci.dropLast())) == nil)
assert(SnapperPlusProtocol.purseIssuer(fci + fci) == nil)
assert(SnapperPlusProtocol.purseIssuer(Data([0xB0, 4, 0, 0, 0, 2])) == nil)
assert(SnapperPlusProtocol.matches(applicationAID: aid, issuerID: 2, transactionRecords: [amount()]))
assert(!SnapperPlusProtocol.matches(applicationAID: aid, issuerID: 2, transactionRecords: []))
assert(!SnapperPlusProtocol.matches(applicationAID: aid, issuerID: 8, transactionRecords: [amount()]))
assert(!SnapperPlusProtocol.matches(applicationAID: "D4100000140001", issuerID: 2, transactionRecords: [amount()]))
var corrupt = amount(); corrupt[30] = 0
assert(!SnapperPlusProtocol.matches(applicationAID: aid, issuerID: 2, transactionRecords: [corrupt]))
assert(SnapperPlusProtocol.balanceMinor(Data(be(-1)), sw1: 0x90, sw2: 0) == -1)
assert(SnapperPlusProtocol.balanceMinor(Data(be(12345)), sw1: 0x90, sw2: 0) == 12345)
assert(SnapperPlusProtocol.balanceMinor(Data(be(12345)), sw1: 0x69, sw2: 0x82) == nil)
assert(SnapperPlusProtocol.balanceMinor(Data([0, 1]), sw1: 0x90, sw2: 0) == nil)
let paired = SnapperPlusProtocol.encodeHistory(transaction: amount(), trip: trip(), recordNumber: 3)!
let value = SnapperPlusProtocol.decodeHistory(paired)!
assert(value.recordNumber == 3 && value.amountMinor == -325 && value.balanceMinor == 1575 && value.counter == 42)
assert(value.transactionData == amount() && value.journeyID == 7 && value.sequence == 2 && value.isTapOn == true)
assert(value.operatorID == "012345678")
let formatter = ISO8601DateFormatter()
assert(value.timestamp == formatter.date(from: "2026-10-29T23:30:45Z"))
for bad: Data? in [nil, Data(trip().prefix(51)), trip("20260230123045"), trip("202610301A3045"), trip("20260405023000"), trip("20260927023000")] {
    let value = SnapperPlusProtocol.decodeHistory(SnapperPlusProtocol.encodeHistory(transaction: amount(), trip: bad, recordNumber: 1)!)!
    assert(value.amountMinor == -325 && value.timestamp == nil && value.isTapOn == nil)
}
let winter = SnapperPlusProtocol.decodeHistory(SnapperPlusProtocol.encodeHistory(transaction: amount(), trip: trip("20260701120000"), recordNumber: 1)!)!
assert(winter.timestamp == formatter.date(from: "2026-07-01T00:00:00Z"))
let topup = SnapperPlusProtocol.decodeHistory(SnapperPlusProtocol.encodeHistory(transaction: amount(2, cost: 500), trip: nil, recordNumber: 1)!)!
assert(topup.amountMinor == 500)
let reversal = SnapperPlusProtocol.decodeHistory(SnapperPlusProtocol.encodeHistory(transaction: amount(cost: -325), trip: nil, recordNumber: 1)!)!
assert(reversal.amountMinor == 325)
assert(SnapperPlusProtocol.decodeHistory(Data(paired.dropLast())) == nil)
assert(SnapperPlusProtocol.decodeHistory(paired + Data([0])) == nil)
var future = paired; future[3] = 2
assert(SnapperPlusProtocol.decodeHistory(future) == nil)
func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined() }
let oldAmount = hex(SnapperPlusProtocol.encodeHistory(transaction: amount(), trip: nil, recordNumber: 1)!)
let movedAmount = hex(SnapperPlusProtocol.encodeHistory(transaction: amount(), trip: nil, recordNumber: 2)!)
let movedPair = hex(SnapperPlusProtocol.encodeHistory(transaction: amount(), trip: trip(), recordNumber: 2)!)
let counterCollision = hex(SnapperPlusProtocol.encodeHistory(transaction: amount(cost: 999), trip: nil, recordNumber: 3)!)
assert(SnapperPlusProtocol.mergeHistory([movedAmount, oldAmount]) == [movedAmount])
assert(SnapperPlusProtocol.mergeHistory([movedPair, oldAmount]) == [movedPair])
assert(SnapperPlusProtocol.mergeHistory([movedAmount, movedPair]) == [movedPair])
assert(SnapperPlusProtocol.mergeHistory([oldAmount, movedPair]) == [movedPair])
assert(SnapperPlusProtocol.mergeHistory([movedPair, counterCollision, oldAmount]) == [movedPair, counterCollision])
assert(SnapperPlusProtocol.mergeHistory(["future-envelope", oldAmount, movedPair]) == ["future-envelope", movedPair])
let ambiguousBytes = trip("20260405023000")
let ambiguous = hex(SnapperPlusProtocol.encodeHistory(transaction: amount(), trip: ambiguousBytes, recordNumber: 1)!)
let ambiguousValue = SnapperPlusProtocol.decodeHistory(SnapperPlusProtocol.encodeHistory(transaction: amount(), trip: ambiguousBytes, recordNumber: 1)!)!
assert(ambiguousValue.timestamp == nil && ambiguousValue.tripData == ambiguousBytes)
assert(SnapperPlusProtocol.mergeHistory([oldAmount, ambiguous]) == [ambiguous])
assert(SnapperPlusProtocol.mergeHistory([ambiguous, movedPair]) == [movedPair])
var calls: [(Int, Int)] = []
let read = await SnapperPlusProtocol.read(applicationAID: aid, issuerID: 2, balance: (Data(be(12345)), 0x90, 0)) { number, sfi in
    calls.append((number, sfi))
    if sfi == 4 && number <= 2 { return (amount(), 0x90, 0) }
    if sfi == 3 && number == 2 { return (trip(), 0x90, 0) }
    return (Data(), 0x6A, 0x83)
}
assert(read?.history.count == 2)
assert(SnapperPlusProtocol.decodeHistory(read!.history[0])!.timestamp == nil)
assert(SnapperPlusProtocol.decodeHistory(read!.history[1])!.timestamp != nil)
assert(SnapperPlusProtocol.decodeHistory(read!.history[1])!.recordNumber == 2)
var guardedCalls = 0
let badBalance = await SnapperPlusProtocol.read(applicationAID: aid, issuerID: 2, balance: (Data(be(12345)), 0x69, 0x82)) { _, _ in
    guardedCalls += 1; return nil
}
assert(badBalance == nil && guardedCalls == 0)
let wrongIssuer = await SnapperPlusProtocol.read(applicationAID: aid, issuerID: 8, balance: (Data(be(12345)), 0x90, 0)) { _, _ in
    guardedCalls += 1; return nil
}
assert(wrongIssuer == nil && guardedCalls == 0)
print("Snapper+ synthetic protocol checks passed")
'''
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder) / "main.swift"
            main.write_text(harness)
            binary = Path(folder) / "checks"
            subprocess.run(["swiftc", str(ROOT / "ios/CardBal/NFC/Profiles/SnapperPlusProtocol.swift"), str(main), "-o", str(binary)], check=True, capture_output=True, text=True)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn("checks passed", result.stdout)
