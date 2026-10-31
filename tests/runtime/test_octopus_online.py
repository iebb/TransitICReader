"""Exercise production OCAP, HTTP, cache and offline scanning with invented cards."""
import http.server
import json
import plistlib
import shutil
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from tools.octopus_config import KEY, configured_value
from tools.paths import ROOT

FIXTURE = ROOT / "tests/runtime/fixtures/octopus-online.json"


class OctopusConfigTests(unittest.TestCase):
    def test_environment_and_ignored_local_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.dict("os.environ", {}, clear=True):
                self.assertEqual("", configured_value(root))
                (root / ".env").write_text(KEY + "=https://example.invalid/enquiry/\n")
                self.assertEqual("https://example.invalid/enquiry", configured_value(root))
                prepared = root / "ios/CardBal/Resources/OctopusEnquiryConfig.plist"
                prepared.parent.mkdir(parents=True)
                prepared.write_bytes(plistlib.dumps({KEY: "https://prepared.invalid/enquiry"}))
                self.assertEqual("https://example.invalid/enquiry", configured_value(root))
                (root / ".env").unlink()
                self.assertEqual("https://prepared.invalid/enquiry", configured_value(root))
            with patch.dict("os.environ", {KEY: ""}, clear=True):
                self.assertEqual("", configured_value(root))
            for value in ["http://example.invalid", "https://a:b@example.invalid", "https://example.invalid/?token=secret"]:
                with self.subTest(value=value), patch.dict("os.environ", {KEY: value}, clear=True):
                    with self.assertRaises(ValueError):
                        configured_value(root)

    def test_generated_plist_uses_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "config.plist"
            with patch.dict("os.environ", {KEY: "https://example.invalid/enquiry"}):
                subprocess.run(["python3", str(ROOT / "tools/octopus_config.py"), "--output", str(output)], check=True)
            self.assertEqual({KEY: "https://example.invalid/enquiry"}, plistlib.loads(output.read_bytes()))


@unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
class OctopusOnlineRuntimeTests(unittest.TestCase):
    def test_protocol_http_calibration_persistence_and_disabled_network(self):
        fixture = json.loads(FIXTURE.read_text())
        frames = [bytes.fromhex(value) for value in fixture["frames"]]
        requests = []
        sessions = {}
        protocol_errors = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                requests.append(self.path)
                if self.headers.get("Content-Type") != "application/ocap":
                    protocol_errors.append("Missing OCAP content type")
                if self.path.startswith("/error/"):
                    self.send_response(503)
                    self.end_headers()
                    return
                if self.path.startswith("/redirect/"):
                    self.send_response(302)
                    self.send_header("Location", "/must-not-follow")
                    self.end_headers()
                    return
                if self.path.startswith("/oversize/"):
                    self.send_response(200)
                    self.send_header("Content-Length", str(1_048_577))
                    self.end_headers()
                    return
                if self.path.endswith("/index.htm"):
                    if body:
                        protocol_errors.append("Greeting must be empty")
                    identifier = "invented-" + str(len(sessions))
                    sessions[identifier] = 0
                    data = ("JSESSIONID=" + (identifier + "/bad" if self.path.startswith("/bad-session/") else identifier)).encode()
                elif "/service.htm;jsessionid=" in self.path:
                    identifier = self.path.split(";jsessionid=")[1]
                    index = sessions[identifier]
                    sessions[identifier] += 1
                    if index == 0 and body.hex() != fixture["device_info"]:
                        protocol_errors.append("Incorrect device information frame")
                    if index > 0 and not (body.startswith(b"OCAP") and body[9:13] == b"RPLY"):
                        protocol_errors.append("Incorrect reply frame")
                    data = frames[index]
                else:
                    self.send_response(501)
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        stubs = r'''
import Foundation
struct RawDataField { let title: String; let value: String
    static func systemCodeRow(_ codes: [String]) -> Self { Self(title: "System Codes", value: codes.joined(separator: ",")) }
}
struct ResultField { let title: String; let value: String }
struct RawDataSection { let title: String; let fields: [RawDataField] }
struct TransitApplication { init(snapshot: TransitCardSnapshot) {} }
struct TransitCardSnapshot {
    let technology: String; let cardFamily: String; let identifierLabel: String; let identifierValue: String
    let rawIdentifierValue: String; let pmm: String?; let systemCode: String?; let selectedAID: String?
    let balanceText: String?; let balanceDetail: String?; let realSerialNumber: String?; let region: String?
    let resultFields: [ResultField]; let rawSections: [RawDataSection]
    let rawTransactions: [String]; let rawTransitHistory: [String]; let scannedAt: Date
    var applications: [TransitApplication]?
}
func formatCurrency(amount: Decimal, code: String, fractionDigits: Int) -> String { "\(code) \(amount)" }
func formatFeliCaIDm(_ idm: String) -> String { idm }
final class InventedCard: FeliCaCard {
    var currentIDm = Data(hexString: "0102030405060708")
    var raw: Int = 900
    var operations: [UInt8] = []
    var polled: [Data] = []
    var block: Data { Data([UInt8(raw >> 24 & 255), UInt8(raw >> 16 & 255), UInt8(raw >> 8 & 255), UInt8(raw & 255)]) + Data(repeating: 0, count: 12) }
    func polling(systemCode: Data, requestCode: FeliCaRequestCode, timeSlot: FeliCaTimeSlot) async throws -> (Data, Data) {
        polled.append(systemCode)
        return (Data(repeating: 0, count: 8), systemCode)
    }
    func requestSystemCode() async throws -> [Data] { [Data([0x80, 8])] }
    func readWithoutEncryption(serviceCodeList: [Data], blockList: [Data]) async throws -> (Int, Int, [Data]) { (0, 0, [block]) }
    func sendFeliCaCommand(commandPacket: Data) async throws -> Data {
        operations.append(commandPacket[0])
        return Data([commandPacket[0] + 1, 0])
    }
}
func rejects(_ operation: () async throws -> Void) async {
    do { try await operation(); fatalError("Invalid input accepted") } catch {}
}
'''
        harness = r'''
@main struct Run {
static func main() async throws {
    let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
    let deviceInfo = try OctopusOCAP.deviceInfo()
    let reply = try OctopusOCAP.reply(Data("abc".utf8))
    precondition(deviceInfo.hexString.lowercased() == fixture["device_info"] as! String)
    precondition(reply.hexString.lowercased() == fixture["reply_abc"] as! String)
    precondition(OctopusOCAP.checksum(Data(hexString: "123456")) == 0x97CC)
    let frame = Data(hexString: (fixture["frames"] as! [String])[0])
    for end in 0..<frame.count {
        do { _ = try OctopusOCAP.parse(frame.prefix(end)); fatalError("Truncated frame accepted") } catch {}
    }
    var corrupt = frame; corrupt[corrupt.count - 1] ^= 1
    do { _ = try OctopusOCAP.parse(corrupt); fatalError("Checksum accepted") } catch {}
    let combined = try OctopusOCAP.parse(frame + frame)
    precondition(combined.count == 2)
    let vm = OctopusEnquiryVM(inputs: [:], deadline: Date().addingTimeInterval(10)) { _ in fatalError("Unexpected card command") }
    let invalid = OctopusOCAP.Message(state: 2, instructions: [.init(type: 1, id: 0, opcode: 3, operands: [16, 0])], records: [:])
    await rejects { _ = try await vm.run(invalid) }
    let loop = OctopusOCAP.Message(state: 2, instructions: [.init(type: 1, id: 0, opcode: 0x12, operands: [0, 0, 0])], records: [:])
    await rejects { _ = try await vm.run(loop) }
    let fixtureFrames = fixture["frames"] as! [String]
    let update = try OctopusOCAP.parse(Data(hexString: fixtureFrames[6]))[0]
    let readOnly = OctopusEnquiryVM(inputs: [:], deadline: Date().addingTimeInterval(10)) { _ in fatalError("Card update reached the card") }
    _ = try await readOnly.run(update)
    precondition(readOnly.skippedCardUpdates == 1 && readOnly.cardOpcodes.isEmpty)
    let consented = OctopusEnquiryVM(inputs: [:], deadline: Date().addingTimeInterval(10), allowsCardUpdates: true) { Data([2, $0[0] + 1]) }
    _ = try await consented.run(update)
    precondition(consented.skippedCardUpdates == 0 && consented.cardOpcodes == [0x16])
    let read = try OctopusOCAP.parse(Data(hexString: fixtureFrames[5]))[0]
    let reader = OctopusEnquiryVM(inputs: [:], deadline: Date().addingTimeInterval(10)) { Data([2, $0[0] + 1]) }
    _ = try await reader.run(read)
    precondition(reader.skippedCardUpdates == 0 && reader.cardOpcodes == [0x14])
    // Core NFC cannot poll wildcard system codes; a server FFFF poll uses 8008.
    let wildcard = InventedCard()
    let polled = try await OctopusOnlineDecoder.exchange(Data([0, 0xFF, 0xFF, 1, 0]), card: wildcard, idm: wildcard.currentIDm)
    precondition(wildcard.polled == [Data([0x80, 0x08])] && polled.count == 20 && polled[0] == 20 && polled.suffix(2) == Data([0x80, 0x08]))
    let octopusPoll = InventedCard()
    let direct = try await OctopusOnlineDecoder.exchange(Data([0, 0x80, 0x08, 0, 0]), card: octopusPoll, idm: octopusPoll.currentIDm)
    precondition(octopusPoll.polled == [Data([0x80, 0x08])] && direct.count == 18 && direct[0] == 18)
    let otherSystem = InventedCard()
    await rejects { _ = try await OctopusOnlineDecoder.exchange(Data([0, 0x00, 0x03, 1, 0]), card: otherSystem, idm: otherSystem.currentIDm) }
    precondition(otherSystem.polled.isEmpty)
    let result = try JSONSerialization.data(withJSONObject: fixture["result"]!)
    let opcodes: Set<UInt8> = [0x10, 0x12, 0x14]
    let confirmed = OctopusCardMetadata.calibrated(result: result, rawValue: 900, opcodes: opcodes)!
    precondition(confirmed.offset == 350 && confirmed.cardNumber == "123456789" && confirmed.serviceStatus == "R30")
    precondition(OctopusCardMetadata.calibrated(result: result, rawValue: 1050, opcodes: opcodes)?.offset == 500)
    precondition(OctopusCardMetadata.calibrated(result: result, rawValue: 901, opcodes: opcodes) == nil)
    precondition(OctopusCardMetadata.calibrated(result: result, rawValue: 900, opcodes: []) == nil)
    let error = Data(#"{"cardDataVO":{"balance":0,"status":"R30"}}"#.utf8)
    precondition(OctopusCardMetadata.calibrated(result: error, rawValue: 350, opcodes: opcodes) == nil)
    let fractional = Data(#"{"cardDataVO":{"balance":54.99,"octopusNo":"123456789","status":"R30"}}"#.utf8)
    precondition(OctopusCardMetadata.calibrated(result: fractional, rawValue: 900, opcodes: opcodes) == nil)
    let overdraft = Data(#"{"cardDataVO":{"balance":-25,"octopusNo":"123456789","status":"R30"}}"#.utf8)
    precondition(OctopusCardMetadata.calibrated(result: overdraft, rawValue: 100, opcodes: opcodes)?.offset == 350)
    let suite = "cardbal-octopus-test-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = OctopusMetadataStore(defaults: defaults)
    store.save(confirmed, for: "010203040506abcd")
    precondition(OctopusMetadataStore(defaults: defaults).metadata(for: "010203040506ABCD") == confirmed)
    precondition(store.metadata(for: "010203040506ABCE") == nil)
    store.save(.init(cardNumber: "invalid", offset: 350, serviceStatus: ""), for: "010203040506ABCD")
    precondition(store.metadata(for: "010203040506abcd") == confirmed)
    precondition(OctopusEnquiryClient.validatedURL("http://example.invalid/enquiry") == nil)
    precondition(OctopusEnquiryClient.validatedURL("https://a:b@example.invalid/enquiry") == nil)
    precondition(OctopusEnquiryClient.validatedURL("https://example.invalid/enquiry?x=1") == nil)
    let server = CommandLine.arguments[2]
    let card = InventedCard()
    let client = OctopusEnquiryClient(baseURL: URL(string: server + "/success"))
    let snapshot = await OctopusOnlineDecoder.decode(card: card, block: card.block, pmm: Data(), scannedAt: Date(),
        store: store, onlineEnabled: true, allowsCardUpdates: false, client: client)
    precondition(snapshot.realSerialNumber == "123456789" && snapshot.balanceText == "HKD 55")
    precondition(snapshot.rawTransactions.isEmpty && card.operations.contains(0x14) && !card.operations.contains(0x16))
    precondition(snapshot.rawSections.flatMap(\.fields).contains { $0.title == "Skipped Card Updates" && $0.value == "1" })
    let updating = InventedCard()
    updating.currentIDm = Data(hexString: "B102030405060708")
    let updated = await OctopusOnlineDecoder.decode(card: updating, block: updating.block, pmm: Data(), scannedAt: Date(),
        store: store, onlineEnabled: true, allowsCardUpdates: true, client: OctopusEnquiryClient(baseURL: URL(string: server + "/success")))
    precondition(updated.realSerialNumber == "123456789" && updating.operations.contains(0x16))
    precondition(!updated.rawSections.flatMap(\.fields).contains { $0.title == "Skipped Card Updates" })
    let unconfigured = InventedCard()
    unconfigured.currentIDm = Data(hexString: "C102030405060708")
    let noEndpoint = await OctopusOnlineDecoder.decode(card: unconfigured, block: unconfigured.block, pmm: Data(), scannedAt: Date(),
        store: store, onlineEnabled: true, allowsCardUpdates: true, client: OctopusEnquiryClient(baseURL: nil))
    precondition(noEndpoint.balanceText == nil && noEndpoint.balanceDetail == nil && unconfigured.operations.isEmpty)
    precondition(!noEndpoint.rawSections.flatMap(\.fields).contains { $0.title == "Online Enquiry" })
    precondition(store.metadata(for: card.currentIDm.hexString)?.offset == 350)
    card.raw = 1000
    let offline = await OctopusOnlineDecoder.decode(card: card, block: card.block, pmm: Data(), scannedAt: Date(),
        store: OctopusMetadataStore(defaults: defaults), onlineEnabled: false)
    precondition(offline.balanceText == "HKD 65" && offline.realSerialNumber == "123456789")
    card.currentIDm = Data(hexString: "A102030405060708")
    let unknown = await OctopusOnlineDecoder.decode(card: card, block: card.block, pmm: Data(), scannedAt: Date(),
        store: store, onlineEnabled: false, client: OctopusEnquiryClient(baseURL: URL(string: server + "/must-not-contact")))
    precondition(unknown.balanceText == nil && unknown.realSerialNumber == nil)
    for mode in ["error", "redirect", "bad-session", "oversize"] {
        let client = OctopusEnquiryClient(baseURL: URL(string: server + "/" + mode))
        await rejects { _ = try await client.enquire { _ in fatalError("HTTP failure contacted card") } }
        client.close()
    }
    print("PASS Octopus OCAP, HTTP failures, calibration, persistence and disabled-network scans")
}
}
'''
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix="cardbal-octopus-") as directory:
                directory = Path(directory)
                utils = (ROOT / "ios/CardBal/NFC/NFCUtils.swift").read_text()
                data = utils[utils.index("extension Data {"):utils.index("struct BERTLVNode")]
                (directory / "Harness.swift").write_text(stubs + data + harness)
                binary = directory / "octopus-test"
                build = subprocess.run([
                    "swiftc", str(ROOT / "ios/CardBal/NFC/CardTransport.swift"),
                    str(ROOT / "ios/CardBal/NFC/ScanProgress.swift"),
                    str(ROOT / "ios/CardBal/NFC/Profiles/OctopusOnlineProtocol.swift"),
                    str(ROOT / "ios/CardBal/NFC/Decoders/OctopusOnlineDecoder.swift"),
                    str(directory / "Harness.swift"), "-o", str(binary),
                ], capture_output=True, text=True)
                self.assertEqual(0, build.returncode, build.stdout + build.stderr)
                run = subprocess.run([str(binary), str(FIXTURE), f"http://127.0.0.1:{server.server_port}"],
                                     capture_output=True, text=True, timeout=30)
                self.assertEqual(0, run.returncode, run.stdout + run.stderr)
                self.assertIn("PASS", run.stdout)
            self.assertEqual([], protocol_errors)
            # One read-only enquiry and one with card updates allowed.
            self.assertEqual(2 * len(frames), sum("/success/service.htm" in path for path in requests))
            self.assertFalse(any("must-not" in path for path in requests))
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
