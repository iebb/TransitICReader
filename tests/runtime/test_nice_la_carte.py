"""La Carte (Lignes d'Azur): the iPhone reads it first, with the pre-2.5.0 Nice reader.

The record layouts are checked with invented bits only; no real card data is used.
"""
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from tools.paths import ROOT

DECODER = ROOT / "ios/CardBal/NFC/Decoders/CalypsoDecoder.swift"
READER = ROOT / "ios/CardBal/NFC/NFCTransitReader.swift"


class NiceLaCarteSourceTests(unittest.TestCase):
    def test_la_carte_is_read_before_other_decoders_and_before_reselecting(self):
        reader = READER.read_text()
        self.assertIn("CalypsoDecoder.isPreselected(cardTag)", reader)
        self.assertIn("decoders.insert(decoders.remove(at: index), at: 0)", reader)
        decoder = DECODER.read_text()
        decode = decoder[decoder.index("static func decode(tag: CardTag"):]
        self.assertLess(decode.index("NiceCalypsoReader.read("), decode.index("CalypsoProtocol.read("))
        self.assertIn('cardFamily: "Lignes d\'Azur card"', decoder)
        # Read-only: the Nice reader only selects the ticketing directory and reads records.
        nice = decoder[decoder.index("enum NiceCalypsoReader"):decoder.index("enum NiceRecords")]
        commands = set(re.findall(r"Data\(\[0x94, (0x[0-9A-F]{2})", nice))
        self.assertEqual(commands, {"0xA4", "0xB2"})

    def test_nice_ticket_titles_match_the_scan_screen(self):
        content = (ROOT / "ios/CardBal/ContentView.swift").read_text()
        titles = re.findall(r'"([^"]+)"', content[content.index("private let niceTicketFieldTitles"):content.index("let niceSuppressedFieldTitles")])
        decoder = DECODER.read_text()
        for title in ["Loaded Tickets", "Ticket", "Remaining Trips", "Ticket Status", "Valid Until"]:
            self.assertIn(title, titles)
            self.assertIn(f'ResultField(title: "{title}"', decoder)


@unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
class NiceRecordLayoutTests(unittest.TestCase):
    def test_invented_records(self):
        source = DECODER.read_text()
        records = source[source.index("/// Bit layouts of the Nice records"):]
        harness = r'''
import Foundation
enum KSX6924DateFormatting {
    static func formatRawDateForDisplay(_ date: Date, includeTime: Bool = true) -> String {
        let f = DateFormatter(); f.timeZone = TimeZone(identifier: "Europe/Paris"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
}
func pack(_ fields: [(Int, Int)]) -> Data {
    var bits: [UInt8] = []
    for (value, width) in fields { for i in (0..<width).reversed() { bits.append(UInt8((value >> i) & 1)) } }
    while bits.count % 8 != 0 { bits.append(0) }
    return Data(stride(from: 0, to: bits.count, by: 8).map { i in bits[i..<i+8].reduce(0) { ($0 << 1) | $1 } })
}
// Best contracts: two entries; the first points at slot 2 with tariff structure 0x46.
let best = NiceRecords.bestContracts(pack([(2,4), (0,7),(0x46,8),(0,4),(2,5), (0,7),(0x20,8),(0,4),(1,5)]))
precondition(best.count == 2 && best[0].pointer == 2 && best[0].structure == "46" && best[1].pointer == 1)
// Contract: bitmap (LSB first) with passenger class (bit 3) and validity (bit 4); validity has only an end date.
let contractBits: [(Int, Int)] = [(0b0011000,7), (5,8), (191,16), (123456,32), (1,8), (0b10,2), (10592,14)]
let contract = NiceRecords.contract(pack(contractBits + [(0, 40)]), best: best[0])!
precondition(contract.tariff == "191" && contract.serial == "123456")
precondition(contract.validUntil == "2026-01-01", contract.validUntil ?? "nil")
precondition(NiceRecords.label(contract).name == "N Voyage Multi")
// Event: day, minutes, bitmap with code (2) and route (11).
var bitmap = 0; bitmap |= 1 << 2; bitmap |= 1 << 11
let event = NiceRecords.event(pack([(10592,14), (20*60+15,11), (bitmap,28), (0x11,8), (7,8), (42,16), (0, 40)]))!
precondition(event.when == "2026-01-01 20:15", event.when)
precondition(event.route == "42")
precondition(NiceRecords.cardExpiry(pack([(0,45),(10592,14),(0,5)])) == "2026-01-01")
precondition(NiceRecords.grouped("1234567") == "1 234 567")
print("ok")
'''
        with tempfile.TemporaryDirectory() as tmp:
            program = Path(tmp) / "main.swift"
            program.write_text(harness + "\n" + records)
            binary = Path(tmp) / "nice"
            build = subprocess.run(["swiftc", str(program), "-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr + run.stdout)
            self.assertIn("ok", run.stdout)


if __name__ == "__main__":
    unittest.main()
