"""Exercise published-face selection and bundle migration using production Swift."""
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.paths import ROOT


@unittest.skipUnless(shutil.which("swiftc"), "Requires the Swift toolchain")
class RemoteCardFaceTests(unittest.TestCase):
    def test_photo_import_failure_and_saved_photo_selection(self):
        source = (ROOT / "ios/CardBal/Models/CardWalletStore.swift").read_text()
        methods = "\n".join(
            re.search(rf"^    func {name}\(.*?^    }}", source, re.M | re.S).group()
            for name in ("setFaceImage", "applyFaceAsset", "setIsUsingImage")
        )
        harness = r'''
import Foundation
struct UIImage {
    let data: Data?
    func jpegData(compressionQuality: Double) -> Data? { data }
}
struct SavedCardRecord {
    let id: String
    var faceImageFileName: String?
    var isUsingImage: Bool?
}
enum StorageError: Error { case unavailable }
final class Store {
    let directory: URL
    var failWrites = false
    var saves = 0
    var cards = [SavedCardRecord(id: "card", faceImageFileName: "remote.jp.suica.default.png",
                                isUsingImage: true)]
    init(_ directory: URL) { self.directory = directory }
    func ensureCardFaceDirectoryExists() throws {
        if failWrites { throw StorageError.unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func cardFaceFileURL(fileName: String) -> URL { directory.appendingPathComponent(fileName) }
    func existingFaceAssetFileName(forJPEGData data: Data) -> String? {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).first {
            (try? Data(contentsOf: cardFaceFileURL(fileName: $0))) == data
        }
    }
    func loadFaceImage(fileName: String) -> UIImage? {
        guard let data = try? Data(contentsOf: cardFaceFileURL(fileName: fileName)) else { return nil }
        return UIImage(data: data)
    }
    func applyAutoImageTextColors(to card: inout SavedCardRecord, image: UIImage) {}
    func applyAutoMarkerColor(to card: inout SavedCardRecord, image: UIImage) {}
    func save() { saves += 1 }
''' + methods + r'''
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let store = Store(directory)
let original = store.cards[0].faceImageFileName
precondition(!store.setFaceImage(UIImage(data: nil), for: "card"))
precondition(store.cards[0].faceImageFileName == original && store.saves == 0)
store.failWrites = true
precondition(!store.setFaceImage(UIImage(data: Data([1,2,3])), for: "card"))
precondition(store.cards[0].faceImageFileName == original && store.saves == 0)
store.failWrites = false
let photo = UIImage(data: Data([1,2,3]))
precondition(store.setFaceImage(photo, for: "card"))
let imported = store.cards[0].faceImageFileName!
precondition(imported.hasSuffix(".jpg") && store.cards[0].isUsingImage == true)
let importedData = try Data(contentsOf: directory.appendingPathComponent(imported))
precondition(importedData == photo.data)
precondition(store.setFaceImage(photo, for: "card"))
precondition(store.cards[0].faceImageFileName == imported, "Duplicate imports must reuse saved photos")
store.setIsUsingImage(false, for: "card")
precondition(store.cards[0].isUsingImage == false && store.cards[0].faceImageFileName == imported)
store.applyFaceAsset("missing.jpg", to: "card")
precondition(store.cards[0].isUsingImage == false, "Missing photos must not replace the choice")
store.applyFaceAsset(imported, to: "card")
precondition(store.cards[0].isUsingImage == true && store.cards[0].faceImageFileName == imported)
print("PASS: photo bytes, deduplication, write failures, color mode and saved photo selection")
'''
        with tempfile.TemporaryDirectory(prefix="cardbal-photo-import-") as temporary:
            directory = Path(temporary)
            swift = directory / "main.swift"
            binary = directory / "photo-test"
            swift.write_text(harness)
            compiled = subprocess.run(["swiftc", str(swift), "-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary), str(directory / "CardFaces")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS:", result.stdout)

    def test_picker_prioritizes_physical_card_and_city(self):
        source = (ROOT / "ios/CardBal/Models/RemoteCardFaceCatalog.swift").read_text()
        manifest = source[:source.index("final class RemoteCardFaceCatalog:")]
        manifest = manifest.replace("import CryptoKit\n", "").replace("import UIKit\n", "")
        harness = r'''
import Foundation
struct TransitApplication {
    var cityCode: String?
    var serialNumber: String? = nil
    var isTUnion = false
    var isCityUnion = false
}
struct SavedCardRecord {
    var cardFamily: String
    var realSerialNumber: String? = nil
    var applications: [TransitApplication]? = nil
    var faceImageFileName: String? = nil
    var isUsingImage: Bool? = nil
}
''' + manifest + r'''
let json = """
{"schemaVersion":2,"cards":[
 {"id":"jp/suica","name":{"en":"Suica"},"city":{"en":"Shanghai"},
  "match":{"families":["suica"]},
  "designs":[{"id":"default","file":"suica.png","sha256":"aa","bytes":1}]},
 {"id":"cn/2901","name":{"en":"Shanghai visitor"},"city":{"zh":"上海","en":" Shanghai "},
  "match":{"cityCodes":["2901"]},
  "designs":[{"id":"default","file":"visitor.png","sha256":"bb","bytes":1}]},
 {"id":"cn/1000","name":{"en":"Beijing"},"city":{"en":"Beijing"},
  "match":{"cityCodes":["1000"]},
  "designs":[{"id":"default","file":"beijing.png","sha256":"cc","bytes":1}]},
 {"id":"cn/2900","name":{"en":"Shanghai"},"city":{"en":"Shanghai","zh":"上海"},
  "match":{"cityCodes":["2900"],"cityUnionCodes":["2000"]},
  "designs":[{"id":"default","file":"shanghai.png","sha256":"dd","bytes":1},
             {"id":"skyline","file":"skyline.png","sha256":"ee","bytes":1}]}
]}
"""
let catalog = try JSONDecoder().decode(RemoteFaceManifest.self, from: Data(json.utf8))
let physical = SavedCardRecord(cardFamily: "T-Union",
    applications: [TransitApplication(cityCode: "2900", isTUnion: true)],
    faceImageFileName: "remote.jp.suica.default.png")
let matched = catalog.match(physical.remoteFaceMatchInput)
precondition(matched?.id == "cn/2900", "Selected artwork changed the physical card match")
let ordered = catalog.pickerEntries(matching: matched)
precondition(ordered.map(\.token) == [
    "remote.cn.2900.default.png", "remote.cn.2900.skyline.png",
    "remote.cn.2901.default.png", "remote.jp.suica.default.png", "remote.cn.1000.default.png"
], "Exact type and same-city designs must precede unrelated artwork")
precondition(ordered.filter { catalog.isPickerMatch($0.card, matching: matched) }.count == 3)
precondition(catalog.pickerEntries(matching: nil) == catalog.entries,
             "Unknown cards must preserve catalog order")
let legacy = SavedCardRecord(cardFamily: "City Union",
    applications: [TransitApplication(cityCode: "2000", isCityUnion: true)])
precondition(catalog.pickerEntries(matching: catalog.match(legacy.remoteFaceMatchInput)).first?.card.id == "cn/2900")
let suica = SavedCardRecord(cardFamily: "Suica", faceImageFileName: "remote.cn.1000.default.png")
precondition(catalog.pickerEntries(matching: catalog.match(suica.remoteFaceMatchInput)).first?.card.id == "jp/suica")
precondition(catalog.faceToken(for: physical) == physical.faceImageFileName,
             "Reordering must not replace an explicit design")
var colorOnly = physical
colorOnly.isUsingImage = false
precondition(catalog.faceToken(for: colorOnly) == nil)
print("PASS: exact card, same city, country boundary, legacy city and explicit choices")
'''
        with tempfile.TemporaryDirectory(prefix="cardbal-face-picker-") as temporary:
            directory = Path(temporary)
            swift = directory / "main.swift"
            binary = directory / "face-picker-test"
            swift.write_text(harness)
            compiled = subprocess.run(["swiftc", str(swift), "-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS:", result.stdout)

    def test_default_selection_and_legacy_wallet_migration(self):
        source = (ROOT / "ios/CardBal/Models/RemoteCardFaceCatalog.swift").read_text()
        manifest = source[:source.index("final class RemoteCardFaceCatalog:")]
        manifest = manifest.replace("import CryptoKit\n", "").replace("import UIKit\n", "")
        store = (ROOT / "ios/CardBal/Models/CardWalletStore.swift").read_text()
        resolve = re.search(
            r"^    private func resolveRemoteFaceSelections\(.*?^    }", store, re.M | re.S
        ).group().replace("private func", "func", 1)
        harness = r'''
import Foundation
struct TransitApplication {
    var cityCode: String?
    var serialNumber: String?
    var isTUnion = false
    var isCityUnion = false
}
struct SavedCardRecord {
    var cardFamily: String
    var realSerialNumber: String? = nil
    var applications: [TransitApplication]? = nil
    var faceImageFileName: String? = nil
    var isUsingImage: Bool? = nil
    var autoTitleTextColor: String? = nil
    var autoBalanceTextColor: String? = nil
}
''' + manifest + r'''
let json = """
{"schemaVersion":2,"cards":[
  {"id":"jp/suica","name":{"en":"Suica"},"match":{"families":["suica"],"serialPrefixes":["JE"]},
   "designs":[{"id":"default","bundledAsset":"suica","file":"faces/jp/suica/default.png","sha256":"aa","bytes":1}]},
  {"id":"kr/tmoney","name":{"en":"T-money"},"match":{"families":["t-money","tmoney"]},
   "designs":[{"id":"ryan","name":{"en":"Little Friends Ryan"},"file":"faces/kr/tmoney/ryan.png","sha256":"bb","bytes":1},
              {"id":"default","bundledAsset":"tmoney","file":"faces/kr/tmoney/default.png","sha256":"cc","bytes":1}]},
  {"id":"sg/ezlink","name":{"en":"EZ-Link"},"match":{"families":["ez-link","ezlink"]},
   "designs":[{"id":"default","bundledAsset":"ezlink","file":"faces/sg/ezlink/default.png","sha256":"dd","bytes":1}]},
  {"id":"kr/ezl","name":{"en":"EZL"},"match":{"families":["ezl","cashbee"]},
   "designs":[{"id":"default","bundledAsset":"ezl","file":"faces/kr/ezl/default.png","sha256":"ee","bytes":1}]}
]}
"""
let catalog = try JSONDecoder().decode(RemoteFaceManifest.self, from: Data(json.utf8))
struct TestCatalog { var manifest: RemoteFaceManifest? }
final class Wallet {
    var cards: [SavedCardRecord]
    let remoteFaces: TestCatalog
    init(_ cards: [SavedCardRecord], manifest: RemoteFaceManifest?) {
        self.cards = cards
        remoteFaces = TestCatalog(manifest: manifest)
    }
    func loadFaceImage(fileName: String?) -> String? { nil }
    func applyAutoImageTextColors(to card: inout SavedCardRecord, image: String) {}
    func applyAutoMarkerColor(to card: inout SavedCardRecord, image: String) {}
''' + resolve + r'''
}
let suica = SavedCardRecord(cardFamily: "Suica")
precondition(catalog.faceToken(for: suica) == "remote.jp.suica.default.png")
precondition(catalog.faceToken(for: SavedCardRecord(cardFamily: "T-money")) == "remote.kr.tmoney.default.png",
             "Default depends on design order")
precondition(catalog.faceToken(for: SavedCardRecord(cardFamily: "EZLink")) == "remote.sg.ezlink.default.png")
let old = SavedCardRecord(cardFamily: "Hayakaken", faceImageFileName: "hayakaken")
let selected = SavedCardRecord(cardFamily: "Suica", faceImageFileName: "la-carte-blue")
let photo = SavedCardRecord(cardFamily: "Suica", faceImageFileName: "photo.jpg", isUsingImage: true)
let alternate = SavedCardRecord(cardFamily: "T-money", faceImageFileName: "remote.kr.tmoney.ryan.png")
let disabled = SavedCardRecord(cardFamily: "Suica", faceImageFileName: "suica", isUsingImage: false)
let color = SavedCardRecord(cardFamily: "Suica", isUsingImage: false)
let wallet = Wallet([suica, old, selected, photo, alternate, disabled, color], manifest: catalog)
precondition(wallet.resolveRemoteFaceSelections())
precondition(wallet.cards.map(\.faceImageFileName) == [
    "remote.jp.suica.default.png", "remote.jp.hayakaken.default.png",
    "remote.fr.la-carte.blue.png", "photo.jpg", "remote.kr.tmoney.ryan.png", "suica", nil,
])
precondition(wallet.cards[5].isUsingImage == false && wallet.cards[6].isUsingImage == false)
precondition(!wallet.resolveRemoteFaceSelections(), "Migration is not idempotent")
let offline = Wallet([old, selected, photo, disabled], manifest: nil)
precondition(offline.resolveRemoteFaceSelections())
precondition(offline.cards[0].faceImageFileName == "remote.jp.hayakaken.default.png")
precondition(offline.cards[1].faceImageFileName == "remote.fr.la-carte.blue.png")
precondition(offline.cards[2].faceImageFileName == "photo.jpg")
precondition(offline.cards[3].isUsingImage == false)
for asset in ["suica", "pasmo", "icoca", "tmoney", "ezl"] {
    precondition(RemoteFaceManifest.offlineAsset(for: RemoteFaceManifest.publishedToken(for: asset)!) == asset)
}
precondition(RemoteFaceManifest.offlineAsset(for: "remote.kr.tmoney.ryan.png") == nil)
precondition(RemoteFaceManifest.offlineAsset(for: "remote.jp.hayakaken.default.png") == nil)
let picker = catalog.pickerEntries(matching: catalog.match(suica.remoteFaceMatchInput))
precondition(picker.count == catalog.entries.count, "Bundled defaults missing from remote picker")
precondition(picker.first?.token == "remote.jp.suica.default.png")
print("PASS: remote defaults, legacy names, offline migration, photos, alternates, color choices and picker")
'''
        with tempfile.TemporaryDirectory(prefix="cardbal-remote-faces-") as temporary:
            directory = Path(temporary)
            swift = directory / "main.swift"
            binary = directory / "remote-faces-test"
            swift.write_text(harness)
            compiled = subprocess.run(["swiftc", str(swift), "-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS:", result.stdout)
