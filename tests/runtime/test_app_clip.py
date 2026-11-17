"""App Clip invocation safety and packaging contract; Swift runs only on macOS."""
from pathlib import Path
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AppClipTests(unittest.TestCase):
    def test_clip_metadata_and_deployment(self):
        info = plistlib.loads((ROOT / 'ios/CardBalClip/Info.plist').read_bytes())
        entitlements = plistlib.loads((ROOT / 'ios/CardBalClip/CardBalClip.entitlements').read_bytes())
        self.assertEqual(entitlements, {
            'com.apple.developer.parent-application-identifiers': ['$(AppIdentifierPrefix)ad.neko.cardbal'],
            'com.apple.developer.nfc.readersession.formats': ['TAG'],
        })
        full = plistlib.loads((ROOT / 'ios/CardBal/Info.plist').read_bytes())
        aid = 'com.apple.developer.nfc.readersession.iso7816.select-identifiers'
        self.assertEqual(info[aid], full[aid])
        self.assertNotIn('8008', info['com.apple.developer.nfc.readersession.felica.systemcodes'])
        self.assertNotIn('NSCameraUsageDescription', info)
        self.assertNotIn('NSUbiquitousContainers', info)
        self.assertTrue(info['NFCReaderUsageDescription'])
        self.assertFalse(any(info['NSAppClip'].values()))
        manifest = (ROOT / 'airbuild.yaml').read_text()
        self.assertIn('id: ad.neko.cardbal.Clip\n      app_clip_of: ad.neko.cardbal', manifest)

    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'Swift SDK tests run on remote macOS')
    def test_untrusted_invocations(self):
        # Production parser compiled unchanged, with real Foundation URL parsing.
        harness = r'''
import Foundation
@main struct InvocationTests {
    @MainActor static func main() {
        let base = "https://appclip.apple.com/id?p=ad.neko.cardbal.Clip"
        let accepted = [base, base + "&unknown=1", base + "&scan=1&scan=2&balance=999&card=abc", base + "#scan"]
        for value in accepted { precondition(ClipInvocation(URL(string: value)!) != nil, value) }
        let rejected = ["https://appclip.apple.com/id", base + "&p=ad.neko.cardbal.Clip", base + "&p=evil",
            "http://appclip.apple.com/id?p=ad.neko.cardbal.Clip", "https://evil.example/id?p=ad.neko.cardbal.Clip",
            "https://appclip.apple.com.evil.example/id?p=ad.neko.cardbal.Clip", "https://appclip.apple.com:443/id?p=ad.neko.cardbal.Clip",
            "https://user@appclip.apple.com/id?p=ad.neko.cardbal.Clip", "https://appclip.apple.com/other?p=ad.neko.cardbal.Clip"]
        for value in rejected { precondition(ClipInvocation(URL(string: value)!) == nil, value) }
        precondition(ClipInvocation(URL(string: base)!) == ClipInvocation(URL(string: base)!))
        let absent: URL? = nil
        precondition(absent.flatMap(ClipInvocation.init) == nil)
        let route = QuickScanRoute()
        for value in accepted + rejected {
            route.isPresented = false
            route.receive(URL(string: value))
            precondition(route.isPresented, "A delivered invocation must use explicit Scan: " + value)
        }
        route.receive(nil)
        precondition(route.isPresented, "Missing invocation URL must stay usable")
        print("Invocation safety: default, unknown, absent, duplicate, hostile values passed")
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'InvocationTests.swift').write_text(harness)
            # Only the production navigation controller; no NFC/UI substitutes.
            route_source = (ROOT / 'ios/CardBal/Views/QuickScanView.swift').read_text().split('struct QuickScanView: View')[0]
            (path / 'QuickScanRoute.swift').write_text(route_source)
            executable = path / 'invocation-tests'
            subprocess.run(['swiftc', str(ROOT / 'ios/CardBal/Helpers/ClipInvocation.swift'),
                            str(path / 'QuickScanRoute.swift'), str(path / 'InvocationTests.swift'), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)


    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'Swift SDK tests run on remote macOS')
    def test_external_scan_retirement_and_amount_visibility(self):
        from tests.runtime.test_dual_applications import method
        source = (ROOT / 'ios/CardBal/NFC/NFCTransitReader.swift').read_text()
        start = method(source, 'startScanning').split('        #endif')[0] + '\n    }'
        start = start.replace('        #if !APPCLIP\n', '')
        cancel = method(source, 'cancelScanning')
        cancel = re.sub(r'        #if canImport\(CoreNFC\).*?        #endif', '', cancel, flags=re.S)
        cancel = cancel.replace('        #if !APPCLIP\n', '').replace('        #endif\n', '')
        cancel_external = method(source, 'cancelExternalScan')
        view = (ROOT / 'ios/CardBal/Views/QuickScanView.swift').read_text()
        predicate = re.search(r'if (transaction.amountKnown[^\n]+) \{', view).group(1)
        # Compile the production rescan action too; its unavailable branch must
        # clear both real and demo results before returning.
        scan = method(view, 'scan')
        harness = r'''
import Foundation
struct Snapshot { let cardFamily: String }
struct CardPollingOption: OptionSet {
    let rawValue: Int
    static let iso18092 = Self(rawValue: 1), iso14443 = Self(rawValue: 2), iso15693 = Self(rawValue: 4)
}
enum StatusKind { case idle, error, success }
enum NFCTestError: Error { case unsupportedCard }
struct DebugLog {
    static let shared = Self()
    func log(_ category: String, _ value: String) {}
    static func describe(_ error: Error) -> String { "error" }
}
@MainActor final class ScanProgress {
    @TaskLocal static var current: ScanProgress?
    init(_ callback: @escaping (String) -> Void) {}
    func finish() {}
}
@MainActor final class ExternalReader {
    var pending: [CheckedContinuation<Snapshot, Error>] = []
    func scan(readerName: String?, options: CardPollingOption) async throws -> Snapshot {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
}
@MainActor final class Reader {
    var isScanning = false
    var usesExternalReader = true
    var externalScanID: UUID?
    var externalScanTask: Task<Void, Never>?
    let externalReader = ExternalReader()
    var selectedExternalReaderName: String?
    var latestSnapshot: Snapshot?
    var status = ""
    var isNFCAvailable = true
    func updateStatus(_ text: String, kind: StatusKind) { status = text }
    func clearResult() { latestSnapshot = nil }
    START
    CANCEL
    CANCEL_EXTERNAL
}
@MainActor final class ScanView {
    let reader = Reader()
    var previewMessage: String?
    var isDemo = true
    var demoSnapshot: Snapshot? = Snapshot(cardFamily: "Demo A")
    var showsUnavailable = false
    SCAN
}
struct Transaction { let amountKnown: Bool; let hasUnresolvedKoreanTransitFare: Bool; let amount: Decimal }
func showsAmount(_ transaction: Transaction) -> Bool { PREDICATE }
@main struct Tests {
    @MainActor static func main() async throws {
        precondition(!showsAmount(Transaction(amountKnown: true, hasUnresolvedKoreanTransitFare: true, amount: 0)), "Unresolved KSX fare must not display zero")
        precondition(showsAmount(Transaction(amountKnown: true, hasUnresolvedKoreanTransitFare: false, amount: 0)), "Confirmed free fare must remain visible")
        precondition(!showsAmount(Transaction(amountKnown: false, hasUnresolvedKoreanTransitFare: false, amount: 0)))
        let view = ScanView()
        view.reader.latestSnapshot = Snapshot(cardFamily: "A")
        view.reader.isNFCAvailable = false
        view.scan()
        precondition(view.reader.latestSnapshot == nil && view.demoSnapshot == nil && !view.isDemo && view.showsUnavailable, "Unavailable rescan retained A")
        let reader = Reader()
        reader.startScanning()
        try await Task.sleep(for: .milliseconds(20))
        let old = reader.externalReader.pending.removeFirst()
        let oldTask = reader.externalScanTask!
        reader.cancelScanning()
        precondition(oldTask.isCancelled && reader.externalScanTask == nil && reader.externalScanID == nil && !reader.isScanning, "Invocation did not retire external reader")
        reader.startScanning()
        try await Task.sleep(for: .milliseconds(20))
        let currentID = reader.externalScanID
        let current = reader.externalReader.pending.removeFirst()
        old.resume(returning: Snapshot(cardFamily: "A"))
        await oldTask.value
        precondition(reader.latestSnapshot == nil && reader.isScanning && reader.externalScanID == currentID && reader.externalScanTask != nil, "Old external completion published or reset new scan")
        current.resume(returning: Snapshot(cardFamily: "B"))
        await reader.externalScanTask?.value
        precondition(reader.latestSnapshot?.cardFamily == "B" && !reader.isScanning)
        print("External retirement, late completion, result clearing, unknown and confirmed-zero fares passed")
    }
}
'''
        for key, value in [('START', start), ('CANCEL_EXTERNAL', cancel_external), ('CANCEL', cancel), ('SCAN', scan), ('PREDICATE', predicate)]:
            harness = harness.replace(key, value)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            swift = path / 'regressions.swift'
            swift.write_text(harness)
            executable = path / 'regressions'
            subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)
