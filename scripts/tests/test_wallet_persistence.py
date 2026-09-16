"""Execute production wallet persistence/merge methods against real SQLite.

The small model/UI adapters keep this regression runnable with macOS Swift,
without an iCloud account or a physical NFC reader.
"""
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STORE = ROOT / "CardBal/Models/CardWalletStore.swift"


def method(source, name):
    match = re.search(r"^    (?:private )?func " + name + r"\(.*?^    }", source, re.M | re.S)
    if not match:
        raise AssertionError(f"Missing production method: {name}")
    return match.group().replace("private func", "func", 1)


@unittest.skipUnless(shutil.which("swiftc"), "Requires the Swift toolchain")
class WalletPersistenceTests(unittest.TestCase):
    def test_sqlite_and_cloud_deletion_regressions(self):
        source = STORE.read_text()
        methods = "\n".join(method(source, name) for name in [
            "openDatabase", "saveCardToSQLite", "readDeletedCards", "mergeDeletions",
            "deleteCard", "shouldApplyCloudData", "mergeSQLite", "mergeBackupData",
            "mergeIncomingCard", "save", "load",
        ])
        # Isolate test defaults from all real app preferences.
        methods = methods.replace("UserDefaults.standard", "defaults")
        backup = source[source.index("struct CardBackupData:"):source.index("struct CardBackupImportResult")]
        harness = r'''
import Foundation
import SQLite3
struct SavedCardRecord: Codable, Equatable {
    let id: String
    var scannedAt: Date
    var order = 0
}
final class Wallet {
    var db: OpaquePointer?
    let dbPath: String
    var cards: [SavedCardRecord] = []
    var deletedCards: [String: Date] = [:]
    var syncMessage: String?
    var isApplyingCloudSync = false
    let localDataUpdatedAtKey = "local"
    let lastAppliedCloudUpdateKey = "applied"
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    init(_ path: String) { dbPath = path; openDatabase(); load() }
    deinit { sqlite3_close(db) }
    func markMapDataChanged() {}
    func scheduleAutomaticiCloudBackup() {}
    func mergedCard(local: SavedCardRecord, incoming: SavedCardRecord) -> SavedCardRecord {
        incoming.scannedAt > local.scannedAt ? incoming : local
    }
    func ensureCardFaceDirectoryExists() throws {}
    func cardFaceFileURL(fileName: String) -> URL { fatalError("No image IO in persistence tests") }
''' + methods + "\n}\n" + backup + r'''
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
func wallet(_ name: String) -> Wallet { Wallet(directory.appendingPathComponent(name).path) }
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
let old = SavedCardRecord(id: "卡片-'A", scannedAt: Date(timeIntervalSince1970: 100))
let other = SavedCardRecord(id: "B", scannedAt: Date(timeIntervalSince1970: 200))
let first = wallet("local.sqlite")
first.cards = [old, other]
check(first.save(), "Initial save failed")
let stale = wallet("stale.sqlite")
stale.cards = first.cards
check(stale.save(), "Stale fixture save failed")
first.deleteCard(old.id)
let reopened = wallet("local.sqlite")
check(reopened.cards == [other], "Deleted card returned after reopening SQLite")
check(reopened.deletedCards[old.id] != nil, "Deletion marker was not persisted")
check(!reopened.mergeSQLite(from: URL(fileURLWithPath: stale.dbPath)), "Stale SQLite resurrected card")
check(reopened.cards == [other], "Stale restore changed wallet")
reopened.deleteCard(other.id)
let empty = wallet("local.sqlite")
check(empty.cards.isEmpty, "Last card returned after reopening SQLite")
check(!empty.shouldApplyCloudData(cloudUpdatedAt: 0, force: false), "Empty deleted wallet forced legacy restore")
check(wallet("new.sqlite").shouldApplyCloudData(cloudUpdatedAt: 0, force: false), "New install cannot restore")
let oldBackup = CardBackupData(version: 1, cards: [old, other], faceAssets: [:])
let oldData = try CardBackupData.encoder.encode(oldBackup)
check(!empty.mergeBackupData(oldData, includeAssets: false), "Legacy JSON resurrected cards")
check(empty.shouldApplyCloudData(cloudUpdatedAt: 0, force: true), "Explicit restore should be available")
check(!empty.mergeBackupData(oldData, includeAssets: false), "Forced restore bypassed deletion markers")
let backup = CardBackupData(version: 2, cards: [], faceAssets: [:], deletedCards: empty.deletedCards)
let encoded = try CardBackupData.encoder.encode(backup)
let decoded = try CardBackupData.decoder.decode(CardBackupData.self, from: encoded)
check(decoded.deletedCards?.count == 2, "Deletion markers missing in backup round trip")
let peer = wallet("peer.sqlite")
peer.cards = [old, other]
check(peer.save(), "Peer fixture failed")
check(peer.mergeBackupData(encoded, includeAssets: false), "Cloud deletion did not apply to peer")
check(peer.save(scheduleCloudSync: false), "Peer save failed")
check(wallet("peer.sqlite").cards.isEmpty, "Cloud deletion did not persist on peer")
let rescanned = SavedCardRecord(id: old.id, scannedAt: Date().addingTimeInterval(10))
check(peer.mergeIncomingCard(rescanned), "Intentional new scan cannot restore card")
check(peer.save(), "Rescan save failed")
check(!peer.mergeBackupData(encoded, includeAssets: false), "Old deletion removed a new scan")
check(wallet("peer.sqlite").cards == [rescanned], "Rescan did not survive relaunch")
let rollback = wallet("rollback.sqlite")
rollback.cards = [old, other]
check(rollback.save(), "Rollback fixture failed")
sqlite3_exec(rollback.db, "CREATE TRIGGER reject_insert BEFORE INSERT ON cards BEGIN SELECT RAISE(ABORT, 'test failure'); END;", nil, nil, nil)
rollback.cards = [other]
check(!rollback.save(), "Write failure was reported as success")
check(rollback.syncMessage != nil, "Write failure was not surfaced")
check(wallet("rollback.sqlite").cards == [other, old], "Failed save destroyed the previous wallet")
print("PASS: deletion/relaunch, empty wallet, stale SQLite/JSON, legacy backup, cloud deletion, rescan, transaction rollback")
'''
        with tempfile.TemporaryDirectory(prefix="cardbal-persistence-") as temporary:
            path = Path(temporary)
            swift = path / "main.swift"
            binary = path / "wallet-tests"
            swift.write_text(harness)
            build = subprocess.run(["swiftc", str(swift), "-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(binary), temporary], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS:", result.stdout)

    def test_scan_on_launch_respects_saved_preference(self):
        source = (ROOT / "CardBal/ContentView.swift").read_text()
        home = source[source.index("struct ScanHomeView:"):source.index("private func bestDisplayCard")]
        self.assertIn('@AppStorage("scanOnLaunch") private var scanOnLaunch = true', home)
        launch = home[home.index(".onAppear {"):]
        self.assertRegex(launch, r"guard scanOnLaunch else \{ return \}.*?", )
        self.assertLess(launch.index("guard scanOnLaunch"), launch.index("reader.startScanning()"))


if __name__ == "__main__":
    unittest.main()
