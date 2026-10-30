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
        names = ["decodeEdyHistory", "decodeNanacoHistory", "edyTransactionType", "nanacoTransactionType", "dateFromElapsedDays", "makeJSTDate"]
        methods=[]
        for name in names:
            method=re.search(r"^    private static func " + name + r"\(.*?^    }", source, re.M|re.S)
            self.assertIsNotNone(method,name)
            methods.append(method.group().replace("private static", "static",1))
        data = utils[utils.index("extension Data {"):utils.index("struct BERTLVNode")]
        offset = utils[utils.index("func octopusOffset("):utils.index("func formatFeliCaIDm(")]
        program = "import Foundation\n"+models+data+offset+"\nstruct Decoder {\n"+"\n".join(methods)+"\n}\n"+r'''
precondition(octopusOffset(for: Date(timeIntervalSince1970:1506787199)) == 350)
precondition(octopusOffset(for: Date(timeIntervalSince1970:1506787200)) == 500)
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
print("PASS cross-platform Japanese history vectors")
'''
        with tempfile.TemporaryDirectory(prefix="cardbal-parity-") as directory:
            path=Path(directory); main=path/"main.swift"; main.write_text(program)
            build=subprocess.run(["swiftc",str(main),str(ROOT/"ios/CardBal/NFC/Profiles/RyutoCardFormat.swift"),"-o",str(path/"test")],capture_output=True,text=True)
            self.assertEqual(build.returncode,0,build.stdout+build.stderr)
            result=subprocess.run([str(path/"test"),str(ROOT/"tests/runtime/fixtures/card-parity.json")],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn("PASS",result.stdout)
