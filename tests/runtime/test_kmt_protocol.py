"""Run independent KMT field/status handling using invented bytes only."""
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from tools.paths import ROOT


@unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
class KMTFormatRuntimeTests(unittest.TestCase):
    def test_balance_profile_identifier_status_and_system_selection(self):
        helper = ROOT / "ios/CardBal/NFC/Profiles/KMTCardFormat.swift"
        profiles = (ROOT / "ios/CardBal/NFC/Profiles/FeliCaProfiles.swift").read_text().replace("import CoreNFC\n", "")
        stubs = r'''
import Foundation
struct RawDataField { let title: String; let value: String }
struct ParsedBalance { let formatted: String; let detail: String; let rawFields: [RawDataField] }
func formatCurrency(amount: Decimal, code: String, fractionDigits: Int = 0) -> String {
    "\(code)/\(fractionDigits)/\(amount)"
}
func octopusOffset(for: Date) -> Int { 350 }
extension Data {
    func bigEndianInt(start: Int, length: Int) -> Int {
        self[start..<(start + length)].reduce(0) { ($0 << 8) | Int($1) }
    }
}
'''
        main = r'''
import Foundation
let system = Data([0x90, 0xB7])
var bytes = [UInt8](repeating: 0, count: 16)
bytes[0] = 4; bytes[1] = 3; bytes[2] = 2; bytes[3] = 1
bytes[7] = 0x80
bytes[13] = 1; bytes[14] = 2; bytes[15] = 3
let block = Data(bytes)
let parsed = KMTCardFormat.parseBalance(block)!
precondition(parsed.amountIDR == 0x01020304)
precondition(parsed.lastTransactionAmountIDR == 0x80000000)
precondition(parsed.transactionCounter == 0x010203)
let high = KMTCardFormat.parseBalance(Data(repeating: 0xFF, count: 16))!
precondition(high.amountIDR == 4_294_967_295)
precondition(high.lastTransactionAmountIDR == 4_294_967_295)
precondition(high.transactionCounter == 16_777_215)
precondition(KMTCardFormat.parseBalance(Data(repeating: 0, count: 16))!.amountIDR == 0)
for size in [0, 3, 15, 17, 32] {
    precondition(KMTCardFormat.parseBalance(Data(repeating: 0, count: size)) == nil)
}
precondition(KMTCardFormat.isSelectedSystem(system))
for other in [nil, Data(), Data([0, 3]), Data([0xB7, 0x90]), system + Data([0])] {
    precondition(!KMTCardFormat.isSelectedSystem(other))
    precondition(KMTCardFormat.validatedRead(selectedSystem: other, status1: 0, status2: 0, blocks: [block]) == nil)
}
precondition(KMTCardFormat.validatedRead(selectedSystem: system, status1: 0, status2: 0, blocks: [block]) == block)
precondition(KMTCardFormat.validatedRead(selectedSystem: system, status1: 1, status2: 0, blocks: [block]) == nil)
precondition(KMTCardFormat.validatedRead(selectedSystem: system, status1: 0, status2: 1, blocks: [block]) == nil)
for blocks in [[], [block, block], [Data(repeating: 0, count: 15)], [Data(repeating: 0, count: 17)]] {
    precondition(KMTCardFormat.validatedRead(selectedSystem: system, status1: 0, status2: 0, blocks: blocks) == nil)
}
let identifier = Data("KMT-TEST-0001".utf8) + Data(repeating: 0, count: 3)
precondition(identifier.count == 16)
precondition(KMTCardFormat.identifier(identifier) == "KMT-TEST-0001")
precondition(KMTCardFormat.identifier(Data(repeating: 0, count: 16)) == nil)
precondition(KMTCardFormat.identifier(Data(repeating: 0xFF, count: 16)) == nil)
precondition(KMTCardFormat.identifier(identifier + Data([0])) == nil)
var invalidIdentifier = identifier; invalidIdentifier[2] = 1
precondition(KMTCardFormat.identifier(invalidIdentifier) == nil)
precondition(!KMTCardFormat.isHistoryBlock(Data(repeating: 0, count: 16)))
var undatedRecord = Data(repeating: 0, count: 16); undatedRecord[4] = 1
precondition(KMTCardFormat.isHistoryBlock(undatedRecord))
precondition(!KMTCardFormat.isHistoryBlock(undatedRecord + Data([0])))
let profile = FeliCaProfile.matching(candidates: ["0003", "90b7"])!
precondition(profile.systemCode == "90B7")
precondition(profile.displayName == "KMT")
precondition(profile.serviceCode == "1017")
precondition(profile.serviceCodeLittleEndian == Data([0x17, 0x10]))
precondition(KMTCardFormat.identifierService == Data([0x0B, 0x30]))
precondition(KMTCardFormat.historyService == Data([0x0F, 0x20]))
precondition(profile.detectedBrand(using: ["8008", "90B7"], realSN: "JE-SYNTHETIC") == "KMT")
precondition(profile.parseBalance(Data(repeating: 0xFF, count: 16), Date())!.formatted == "IDR/0/4294967295")
precondition(profile.parseBalance(Data(repeating: 0, count: 15), Date()) == nil)
precondition(KMTCardFormat.matchesFamily("KMT"))
precondition(KMTCardFormat.matchesFamily(" Kartu Multi Trip "))
precondition(!KMTCardFormat.matchesFamily("Japan Transit IC"))
print("Verified KMT unsigned IDR, selection, statuses, identifiers and raw history")
'''
        with tempfile.TemporaryDirectory(prefix="cardbal-kmt-synthetic-") as directory:
            directory = Path(directory)
            (directory / "Profiles.swift").write_text(profiles)
            (directory / "Stubs.swift").write_text(stubs)
            (directory / "main.swift").write_text(main)
            executable = directory / "kmt-tests"
            build = subprocess.run([
                "swiftc", str(helper), str(directory / "Stubs.swift"),
                str(directory / "Profiles.swift"), str(directory / "main.swift"),
                "-o", str(executable),
            ], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Verified KMT", result.stdout)

    def test_iphone_declares_the_kmt_system(self):
        with (ROOT / "ios/CardBal/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        self.assertIn("90B7", info["com.apple.developer.nfc.readersession.felica.systemcodes"])


if __name__ == "__main__":
    unittest.main()
