"""Run Swift production public-record parsing against invented multi-network bytes."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from tools.paths import ROOT

@unittest.skipUnless(shutil.which('swiftc'), 'Requires Swift')
class CalypsoProtocolTests(unittest.TestCase):
    def test_network_contract_event_and_transport_parity(self):
        harness=r'''
import Foundation
func data(_ hex: String) -> Data {
    let chars=Array(hex); return Data(stride(from:0,to:chars.count,by:2).map { UInt8(String(chars[$0...$0+1]),radix:16)! })
}
func network(_ name: String) -> CalypsoProtocol.Network {
    switch name { case "intercode": return .intercode; case "navigo": return .navigo; case "opus": return .opus; case "mobib": return .mobib; case "ravKav": return .ravKav; default: return .generic }
}
let json=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
let environments=json["environments"] as! [String:String]
for (name,hex) in environments { assert(CalypsoProtocol.identify(data(hex)) == network(name), name) }
assert(CalypsoProtocol.identify(data(environments["intercode"]!)).family == "Calypso")
assert(CalypsoProtocol.identify(Data(repeating:0,count:29)) == .generic)
assert(CalypsoProtocol.identify(Data(data(environments["intercode"]!).prefix(28))) == .generic)
var absent=data(environments["navigo"]!); absent[1] &= 0xF7
assert(CalypsoProtocol.identify(absent) == .generic)
var future=data(environments["mobib"]!); future[0]=0xFC
assert(CalypsoProtocol.identify(future) == .generic)
func records(_ item: [String:Any]) -> [CalypsoProtocol.Record] {
    (item["records"] as! [[String:Any]]).map { CalypsoProtocol.Record(sfi:$0["sfi"] as! Int,number:$0["number"] as! Int,payload:data($0["payload"] as! String)) }
}
for item in json["contracts"] as! [[String:Any]] {
    let name=item["name"] as! String
    let contract=CalypsoProtocol.contracts(network:network(item["network"] as! String),records:records(item))
    assert(contract.count==1,name)
    let c=contract[0]
    assert(c.productCode == (item["product"] as? NSNumber)?.int64Value,name)
    assert(c.remainingTrips == (item["trips"] as? NSNumber)?.int64Value,name)
    assert(c.balanceMinor == (item["balance"] as? NSNumber)?.int64Value,name)
    assert(c.validFrom == item["start"] as? String,name)
    assert(c.validUntil == item["end"] as? String,name)
}
var validEnvelope: Data!
for item in json["histories"] as! [[String:Any]] {
    let name=item["name"] as! String; let net=network(item["network"] as! String)
    let envelope=CalypsoProtocol.encodeRecord(network:net,record:.init(sfi:8,number:1,payload:data(item["payload"] as! String)))!
    let event=CalypsoProtocol.parseHistory(envelope)
    if item["invalid"] as? Bool == true { assert(event==nil,name) }
    else {
        assert(event != nil,name)
        assert(Int64(event!.timestamp!.timeIntervalSince1970 * 1000) == (item["millis"] as! NSNumber).int64Value,name)
        assert(event!.amountMinor == (item["amount"] as? NSNumber)?.int64Value,name)
        assert(event!.eventCode == item["code"] as? Int,name)
        assert(event!.currency == net.currency,name)
        validEnvelope=envelope
    }
}
assert(CalypsoProtocol.parseHistory(Data(validEnvelope.dropLast())) == nil)
assert(CalypsoProtocol.parseHistory(validEnvelope + Data([0])) == nil)
var bad=validEnvelope!; bad[3]=2
assert(CalypsoProtocol.parseHistory(bad) == nil)
let eventPayload=data((json["histories"] as! [[String:Any]])[0]["payload"] as! String)
func hex(_ value:Data)->String { value.map { String(format:"%02X",$0) }.joined() }
let old=hex(CalypsoProtocol.encodeRecord(network:.navigo,record:.init(sfi:8,number:1,payload:eventPayload))!)
let moved=hex(CalypsoProtocol.encodeRecord(network:.navigo,record:.init(sfi:8,number:2,payload:eventPayload))!)
assert(CalypsoProtocol.mergeHistory([moved,old]) == [moved])
let first=hex(CalypsoProtocol.encodeRecord(network:.navigo,record:.init(sfi:9,number:1,payload:eventPayload))!)
let second=hex(CalypsoProtocol.encodeRecord(network:.navigo,record:.init(sfi:9,number:2,payload:eventPayload))!)
assert(CalypsoProtocol.mergeHistory([first,second]) == [first,second])
let zero=(json["contracts"] as! [[String:Any]]).first { $0["name"] as? String == "rav-zero" }!
var files: [String:Data]=[:]
for record in records(zero) { files["\(record.sfi)/\(record.number)"]=record.payload }
files["7/1"]=data(environments["ravKav"]!)
var commands: [Data]=[]; var retry=false
let read=await CalypsoProtocol.read { command in
    commands.append(command)
    if command[1]==0xA4 { return (Data(),command[2]==4 || command.count==7 ? 0x90:0x6A,command[2]==4 || command.count==7 ? 0:0x82) }
    if command[1]==0xB2 {
        let sfi=Int(command[3]>>3); let number=Int(command[2])
        if sfi==7 && !retry { retry=true; return (Data(),0x6C,0) }
        if let payload=files["\(sfi)/\(number)"] { return (payload,0x90,0) }
    }
    return (Data(),0x6A,0x82)
}
assert(read?.family=="Rav-Kav" && read?.balanceMinor==0 && read?.balanceText=="ILS 0.00")
assert(read?.hasDecodedData == true)
let ticket=(json["contracts"] as! [[String:Any]]).first { $0["name"] as? String == "generic-intercode-ticket" }!
var ticketFiles: [String:Data]=[:]
for record in records(ticket) { ticketFiles["\(record.sfi)/\(record.number)"]=record.payload }
ticketFiles["7/1"]=data(environments["intercode"]!)
let ticketResult=await CalypsoProtocol.read { command in
    if command[1]==0xA4 { return (Data(),0x90,0) }
    if command[1]==0xB2, let payload=ticketFiles["\(command[3]>>3)/\(command[2])"] { return (payload,0x90,0) }
    return (Data(),0x6A,0x82)
}
assert(ticketResult?.family=="Calypso" && ticketResult?.remainingTrips==3 && ticketResult?.hasDecodedData==true)
assert(ticketResult!.fields.contains { $0.1=="Product 191" })
assert(!ticketResult!.fields.contains { $0.1.contains("Nice") || $0.1.contains("Azur") || $0.1.contains("N Voyage") })
assert(read!.records.contains { $0.sfi==10 && $0.payload==Data(repeating:0,count:3) })
assert(commands.contains { $0[1]==0xB2 && $0[3]==0x3C && $0.last==0 })
assert(commands.allSatisfy { $0[1]==0xA4 || $0[1]==0xB2 })
let failed=await CalypsoProtocol.read { _ in (data(environments["navigo"]!),0x69,0x82) }
assert(failed==nil)
let empty=CalypsoProtocol.ReadResult(network:.opus,selectedAID:"315449432E494341",serial:"123",balanceMinor:nil,remainingTrips:nil,fields:[],records:[],contracts:[],rawHistories:[])
assert(!empty.hasDecodedData)
print("Calypso synthetic protocol checks passed")
'''
        with tempfile.TemporaryDirectory() as folder:
            main=Path(folder)/'main.swift';main.write_text(harness)
            binary=Path(folder)/'calypso'
            build=subprocess.run(['swiftc',str(ROOT/'ios/CardBal/NFC/Profiles/CalypsoProtocol.swift'),str(main),'-o',str(binary)],capture_output=True,text=True)
            self.assertEqual(build.returncode,0,build.stderr)
            result=subprocess.run([str(binary),str(ROOT/'tests/runtime/fixtures/calypso_synthetic.json')],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn('checks passed',result.stdout)
