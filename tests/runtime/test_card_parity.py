"""Shared invented-byte vectors run through production Swift and Android codecs."""
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from tools.paths import ROOT


@unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
class CardParityTests(unittest.TestCase):
    def test_japanese_history_vectors_and_invalid_records(self):
        utils = (ROOT / "ios/CardBal/NFC/NFCUtils.swift").read_text()
        models = utils[utils.index("struct ResultField:"):utils.index("struct TransactionDecoderRegistry")]
        source = (ROOT / "ios/CardBal/NFC/Decoders/JapaneseICDecoder.swift").read_text()
        names = ["decodeEdyHistory", "decodeNanacoHistory", "decodeWAONHistory", "edyTransactionType", "nanacoTransactionType",
                 "waonTransactionType", "readMSBPackedBits", "dateFromElapsedDays", "makeJSTDate"]
        methods=[]
        for name in names:
            method=re.search(r"^    private static func " + name + r"\(.*?^    }", source, re.M|re.S)
            self.assertIsNotNone(method,name)
            methods.append(method.group().replace("private static", "static",1))
        # Raw-detail rows name types independently of the decoder.
        for name in ["nanacoTransactionTypeName", "waonTransactionTypeName"]:
            method=re.search(r"^    private func " + name + r"\(.*?^    }", utils, re.M|re.S)
            self.assertIsNotNone(method,name)
            methods.append(method.group().replace("private func", "static func",1))
        data = utils[utils.index("extension Data {"):utils.index("struct BERTLVNode")]
        offset = utils[utils.index("func formatUTF8OrHex("):utils.index("func defaultFractionDigits(")]
        program = "import Foundation\n"+models+data+offset+"\nstruct Decoder {\n"+"\n".join(methods)+"\n}\n"+r'''
let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String:[String:Any]]
for (family,row) in fixture {
    let raw=row["raw"] as! String
    let block=Data(hexString:raw)
    if family == "ryuto" {
        let record=RyutoCardFormat.decode(block)!
        precondition(record.amount == row["amount"] as! Int && record.balance == row["balance"] as! Int)
        precondition(ISO8601DateFormatter().string(from:record.date) == row["date"] as! String)
    } else {
        let tx=family == "edy" ? Decoder.decodeEdyHistory(block:block)! : Decoder.decodeNanacoHistory(block:block)!
        precondition(tx.amount == Decimal(row["amount"] as! Int) && tx.balanceAfter == Decimal(row["balance"] as! Int))
        precondition(ISO8601DateFormatter().string(from:tx.date!) == row["date"] as! String)
        precondition(family != "edy" || tx.category == .topUp)
    }
}
var invalid = Data(hexString:fixture["ryuto"]!["raw"] as! String)
invalid[0]=0x34; invalid[1]=0x5F
precondition(RyutoCardFormat.decode(invalid) == nil)
precondition(RyutoCardFormat.decode(Data(repeating:0,count:15)) == nil)
precondition(Decoder.decodeEdyHistory(block:Data(repeating:0,count:15)) == nil)
// Retail type tables: list label, category and amount source, plus the raw-detail
// name. Named WAON operations stay uncategorized and keep max(usage, charge).
func waonRecord(_ type: UInt8, usage: UInt32, charge: UInt32) -> Data {
    var record = Data(repeating: 0, count: 32)
    record[13] = 7; record[17] = type
    let fields: [(UInt32, Int)] = [(21, 5), (10, 4), (30, 5), (12, 5), (34, 6), (1200, 18), (usage, 18), (charge, 17)]
    var offset = 0
    for (value, width) in fields {
        for i in 0..<width where (value >> UInt32(width - 1 - i)) & 1 == 1 {
            record[18 + (offset + i) / 8] |= UInt8(0x80 >> ((offset + i) % 8))
        }
        offset += width
    }
    return record
}
let waonNamed: [UInt8: String] = [0x08: "Return", 0x18: "Point Download", 0x28: "Refund", 0x1C: "Auto Charge",
                                  0x20: "Auto Charge", 0x30: "Auto Charge", 0x3C: "Move to New Card", 0x7C: "Point Exchange"]
for (type, label) in waonNamed {
    for (usage, charge) in [(UInt32(300), UInt32(500)), (UInt32(700), UInt32(200))] {
        let tx=Decoder.decodeWAONHistory(block:waonRecord(type, usage:usage, charge:charge))!
        precondition(tx.type == label && tx.category == .unknown && tx.amount == Decimal(max(usage, charge)))
        precondition(tx.balanceAfter == 1200 && tx.recordNumber == 7)
    }
    precondition(Decoder.waonTransactionTypeName(type) == label)
}
let waonPayment=Decoder.decodeWAONHistory(block:waonRecord(0x04, usage:300, charge:500))!
precondition(waonPayment.type == "Payment" && waonPayment.category == .payment && waonPayment.amount == 300)
precondition(ISO8601DateFormatter().string(from:waonPayment.date!) == "2026-10-30T03:34:00Z")
for type: UInt8 in [0x0C, 0x10] {
    let tx=Decoder.decodeWAONHistory(block:waonRecord(type, usage:300, charge:500))!
    precondition(tx.type == "Top-up" && tx.category == .topUp && tx.amount == 500)
}
let waonOther=Decoder.decodeWAONHistory(block:waonRecord(0x99, usage:300, charge:500))!
precondition(waonOther.type == "Transaction 99" && waonOther.category == .unknown && waonOther.amount == 500)
precondition(Decoder.waonTransactionTypeName(0x99) == "0x99")
let nanacoTypes: [UInt8: (String, TransactionCategory)] = [0x47: ("Payment", .payment), 0x5C: ("Top-up", .topUp),
    0x6F: ("Top-up", .topUp), 0x70: ("Top-up", .topUp), 0x83: ("Points Redemption", .topUp), 0x35: ("Transfer", .adjustment)]
for (type, expected) in nanacoTypes {
    var block=Data(hexString:fixture["nanaco"]!["raw"] as! String)
    block[0]=type
    let tx=Decoder.decodeNanacoHistory(block:block)!
    precondition(tx.type == expected.0 && tx.category == expected.1 && tx.amount == Decimal(fixture["nanaco"]!["amount"] as! Int))
    precondition(Decoder.nanacoTransactionTypeName(type) == expected.0)
}
precondition(Decoder.nanacoTransactionType(0x99) == ("Transaction 99", .unknown))
precondition(Decoder.nanacoTransactionTypeName(0x99) == "0x99")
print("PASS cross-platform Japanese history vectors")
'''
        with tempfile.TemporaryDirectory(prefix="cardbal-parity-") as directory:
            path=Path(directory); main=path/"main.swift"; main.write_text(program)
            build=subprocess.run(["swiftc",str(main),str(ROOT/"ios/CardBal/NFC/Profiles/RyutoCardFormat.swift"),"-o",str(path/"test")],capture_output=True,text=True)
            self.assertEqual(build.returncode,0,build.stdout+build.stderr)
            result=subprocess.run([str(path/"test"),str(ROOT/"tests/runtime/fixtures/card-parity.json")],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn("PASS",result.stdout)
