import SwiftUI
import CryptoKit

struct SavedFaceAsset: Identifiable, Hashable {
    let fileName: String
    var id: String { fileName }
}

class CardWalletStore: ObservableObject {
    @Published var cards: [SavedCardRecord] = []

    private let userDefaultsKey = "savedTransitCards"
    private var saveTask: Task<Void, Never>?
    private var imageCache: [String: UIImage] = [:]

    init() {
        load()
    }

    func upsert(snapshot: TransitCardSnapshot) {
        let id = snapshot.storageIdentifier
        let cardFamily = snapshot.cardFamily
        let fields = snapshot.resultFields.map { SavedCardField($0) }

        if let index = cards.firstIndex(where: { $0.id == id }) {
            cards[index].balanceText = snapshot.balanceText
            cards[index].balanceDetail = snapshot.balanceDetail
            cards[index].resultFields = fields
            cards[index].scannedAt = snapshot.scannedAt
            cards[index].cardFamily = cardFamily
            cards[index].pmm = snapshot.pmm
            cards[index].systemCode = snapshot.systemCode
            cards[index].selectedAID = snapshot.selectedAID
            cards[index].realSerialNumber = snapshot.realSerialNumber
            cards[index].enhancedFeliCaDecoded = false
        } else {
            let record = SavedCardRecord(
                id: id,
                cardFamily: cardFamily,
                markerSymbolName: nil,
                markerColor: .white,
                markerOuterColor: .black,
                markerShape: .circle,
                customTitle: nil,
                customDisplaySerialNumber: nil,
                hideTitleOnImage: false,
                hideSerialNumber: false,
                imageFaceEnhancer: .mask,
                autoImageTextColors: true,
                autoTitleTextColor: nil,
                autoBalanceTextColor: nil,
                titleTextColorOverride: nil,
                balanceTextColorOverride: nil,
                technology: snapshot.technology,
                identifierLabel: snapshot.identifierLabel,
                rawIdentifierValue: snapshot.rawIdentifierValue,
                identifierValue: snapshot.identifierValue,
                pmm: snapshot.pmm,
                selectedAID: snapshot.selectedAID,
                systemCode: snapshot.systemCode,
                balanceText: snapshot.balanceText,
                balanceDetail: snapshot.balanceDetail,
                realSerialNumber: nil,
                enhancedFeliCaDecoded: false,
                resultFields: fields,
                scannedAt: snapshot.scannedAt,
                color: defaultColor(for: cardFamily),
                design: .classic,
                faceImageFileName: nil
            )
            cards.insert(record, at: 0)
        }
        save()
    }

    func setCustomTitle(_ title: String, for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].customTitle = title
        save()
    }

    func setCustomDisplaySerialNumber(_ sn: String, for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].customDisplaySerialNumber = sn
        save()
    }

    func setHideTitleOnImage(_ hide: Bool, for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].hideTitleOnImage = hide
        save()
    }

    func setHideSerialNumber(_ hide: Bool, for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].hideSerialNumber = hide
        save()
    }

    func setMarkerSymbolName(_ symbol: String?, for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].markerSymbolName = symbol
        save()
    }

    func setMarkerColor(_ color: Color, for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].markerColor = SavedCardColor(color: color)
        save()
    }

    func setMarkerOuterColor(_ color: Color, for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].markerOuterColor = SavedCardColor(color: color)
        save()
    }

    func setMarkerShape(_ shape: SavedCardMarkerShape, for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].markerShape = shape
        save()
    }

    func setColor(_ color: Color, for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].color = SavedCardColor(color: color)
        save()
    }

    func setDesign(_ design: SavedCardDesign, for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].design = design
        save()
    }

    func setImageFaceEnhancer(_ enhancer: ImageFaceEnhancer, for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].imageFaceEnhancer = enhancer
        save()
    }

    func setTitleTextColorOverride(_ color: Color, for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].titleTextColorOverride = SavedCardColor(color: color)
        save()
    }

    func setBalanceTextColorOverride(_ color: Color, for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].balanceTextColorOverride = SavedCardColor(color: color)
        save()
    }

    func setFaceImage(_ image: UIImage, for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }),
              let jpegData = image.jpegData(compressionQuality: 0.9) else { return }

        do {
            try ensureCardFaceDirectoryExists()
            let fileName: String
            if let existingFileName = existingFaceAssetFileName(forJPEGData: jpegData) {
                fileName = existingFileName
            } else {
                fileName = "\(UUID().uuidString).jpg"
                try jpegData.write(to: cardFaceFileURL(fileName: fileName), options: .atomic)
            }
            cards[index].faceImageFileName = fileName
            applyAutoImageTextColors(to: &cards[index], image: image)
            save()
        } catch { return }
    }

    func removeFaceImage(for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].faceImageFileName = nil
        cards[index].autoTitleTextColor = nil
        cards[index].autoBalanceTextColor = nil
        save()
    }

    func deleteCard(_ id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards.remove(at: index)
        save()
    }

    func faceAssets() -> [SavedFaceAsset] {
        let directory = cardFaceDirectoryURL
        guard let fileNames = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return deduplicatedFaceFileNames(fileNames)
            .filter { $0.lowercased().hasSuffix(".jpg") || $0.lowercased().hasSuffix(".jpeg") || $0.lowercased().hasSuffix(".png") }
            .sorted().map { SavedFaceAsset(fileName: $0) }
    }

    func isFaceAssetUsed(_ fileName: String) -> Bool {
        cards.contains { $0.faceImageFileName == fileName }
    }

    func card(withID id: String) -> SavedCardRecord? {
        cards.first(where: { $0.id == id })
    }

    func moveCard(from sourceID: String, to destinationID: String) {
        guard sourceID != destinationID,
              let sourceIndex = cards.firstIndex(where: { $0.id == sourceID }),
              let destinationIndex = cards.firstIndex(where: { $0.id == destinationID }) else { return }
        let movedCard = cards.remove(at: sourceIndex)
        cards.insert(movedCard, at: destinationIndex)
        save()
    }

    func moveCard(from sourceID: String, toIndex destinationIndex: Int) {
        guard let sourceIndex = cards.firstIndex(where: { $0.id == sourceID }) else { return }
        let clampedIndex = min(max(destinationIndex, 0), cards.count - 1)
        guard sourceIndex != clampedIndex else { return }
        let movedCard = cards.remove(at: sourceIndex)
        cards.insert(movedCard, at: clampedIndex)
        save()
    }

    func bringToFront(_ id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }), index != 0 else { return }
        let movedCard = cards.remove(at: index)
        cards.insert(movedCard, at: 0)
        save()
    }

    func applyFaceAsset(_ fileName: String, to id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].faceImageFileName = fileName
        if let image = loadFaceImage(fileName: fileName) {
            applyAutoImageTextColors(to: &cards[index], image: image)
        }
        save()
    }

    func loadFaceImage(fileName: String?) -> UIImage? {
        guard let fileName else { return nil }
        if let cached = imageCache[fileName] { return cached }
        if let image = UIImage(contentsOfFile: cardFaceFileURL(fileName: fileName).path) {
            imageCache[fileName] = image
            return image
        }
        return nil
    }

    func deleteFaceAsset(_ fileName: String) {
        imageCache.removeValue(forKey: fileName)
        try? FileManager.default.removeItem(at: cardFaceFileURL(fileName: fileName))
        save()
    }

    func deleteUnusedFaceAssets() {
        let used = Set(cards.compactMap(\.faceImageFileName))
        for asset in faceAssets() where !used.contains(asset.fileName) {
            try? FileManager.default.removeItem(at: cardFaceFileURL(fileName: asset.fileName))
        }
        save()
    }

    func backupToiCloud() {
        guard let data = exportBackup() else { return }
        NSUbiquitousKeyValueStore.default.set(data, forKey: "icloud_card_backup")
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    func restoreFromiCloud() {
        NSUbiquitousKeyValueStore.default.synchronize()
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: "icloud_card_backup") else { return }
        importBackup(from: data)
    }

    func exportBackup() -> Data? {
        var faceAssets: [String: Data] = [:]
        for face in self.faceAssets() {
            if let data = try? Data(contentsOf: cardFaceFileURL(fileName: face.fileName)) {
                faceAssets[face.fileName] = data
            }
        }
        let backup = CardBackupData(version: 1, cards: cards, faceAssets: faceAssets)
        return try? JSONEncoder().encode(backup)
    }

    func importBackup(from data: Data) {
        guard let backup = try? JSONDecoder().decode(CardBackupData.self, from: data) else { return }
        try? ensureCardFaceDirectoryExists()
        for (fileName, fileData) in backup.faceAssets {
            let fileURL = cardFaceFileURL(fileName: fileName)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try? fileData.write(to: fileURL)
            }
            imageCache.removeValue(forKey: fileName)
        }
        self.cards = backup.cards
        save(force: true)
    }

    private func save(force: Bool = false) {
        saveTask?.cancel()
        let currentCards = cards
        let work = {
            if let data = try? JSONEncoder().encode(currentCards) {
                UserDefaults.standard.set(data, forKey: self.userDefaultsKey)
            }
        }
        if force { work(); return }
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            work()
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let cards = try? JSONDecoder().decode([SavedCardRecord].self, from: data) else { return }
        self.cards = cards
    }

    private func ensureCardFaceDirectoryExists() throws {
        try FileManager.default.createDirectory(at: cardFaceDirectoryURL, withIntermediateDirectories: true)
    }

    private var cardFaceDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("CardBal/CardFaces", isDirectory: true)
    }

    private func cardFaceFileURL(fileName: String) -> URL {
        cardFaceDirectoryURL.appendingPathComponent(fileName)
    }

    private func defaultColor(for cardFamily: String) -> SavedCardColor {
        switch cardFamily {
        case "Transit IC": return SavedCardColor(red: 0.11, green: 0.53, blue: 0.76)
        case "Octopus": return SavedCardColor(red: 0.80, green: 0.16, blue: 0.16)
        case "T-money": return SavedCardColor(red: 0.12, green: 0.61, blue: 0.49)
        case "EZL / Cashbee": return SavedCardColor(red: 0.94, green: 0.58, blue: 0.18)
        case "Lignes d'Azur card": return SavedCardColor(red: 0.05, green: 0.36, blue: 0.73)
        default: return SavedCardColor(red: 0.24, green: 0.27, blue: 0.35)
        }
    }

    private func applyAutoImageTextColors(to card: inout SavedCardRecord, image: UIImage) {
        card.autoTitleTextColor = bestReadableTextColor(for: image, region: CGRect(x: 0.04, y: 0.04, width: 0.42, height: 0.28))
        card.autoBalanceTextColor = bestReadableTextColor(for: image, region: CGRect(x: 0.56, y: 0.04, width: 0.4, height: 0.28))
    }

    private func bestReadableTextColor(for image: UIImage, region: CGRect) -> SavedCardColor {
        guard let sampled = sampledColors(in: image, region: region) else { return .white }
        let palette: [SavedCardColor] = [.white, .black, SavedCardColor(red: 0.95, green: 0.93, blue: 0.84), SavedCardColor(red: 0.12, green: 0.18, blue: 0.28)]
        return palette.max { contrastScore(for: $0, against: sampled) < contrastScore(for: $1, against: sampled) } ?? .white
    }

    private func sampledColors(in image: UIImage, region: CGRect) -> [SavedCardColor]? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        let cropRect = CGRect(x: region.origin.x * CGFloat(width), y: region.origin.y * CGFloat(height), width: region.width * CGFloat(width), height: region.height * CGFloat(height)).integral
        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
        let ciImage = CIImage(cgImage: cropped)
        let context = CIContext()
        var bitmap = [UInt8](repeating: 0, count: 16 * 16 * 4)
        context.render(ciImage, toBitmap: &bitmap, rowBytes: 64, bounds: CGRect(x: 0, y: 0, width: 16, height: 16), format: .RGBA8, colorSpace: nil)
        var colors: [SavedCardColor] = []
        for i in stride(from: 0, to: bitmap.count, by: 4) {
            colors.append(SavedCardColor(red: Double(bitmap[i])/255, green: Double(bitmap[i+1])/255, blue: Double(bitmap[i+2])/255))
        }
        return colors
    }

    private func contrastScore(for text: SavedCardColor, against backgrounds: [SavedCardColor]) -> Double {
        backgrounds.map { contrastRatio(text: text, background: $0) }.reduce(0, +) / Double(backgrounds.count)
    }

    private func contrastRatio(text: SavedCardColor, background: SavedCardColor) -> Double {
        let l1 = text.relativeLuminance + 0.05
        let l2 = background.relativeLuminance + 0.05
        return max(l1, l2) / min(l1, l2)
    }

    private func existingFaceAssetFileName(forJPEGData data: Data) -> String? {
        let targetHash = sha256Hex(for: data)
        for asset in faceAssets() {
            if let d = try? Data(contentsOf: cardFaceFileURL(fileName: asset.fileName)), sha256Hex(for: d) == targetHash { return asset.fileName }
        }
        return nil
    }

    private func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func deduplicatedFaceFileNames(_ fileNames: [String]) -> [String] {
        var canonicals: [String: String] = [:]
        var result: [String] = []
        for name in fileNames.sorted() {
            if let d = try? Data(contentsOf: cardFaceFileURL(fileName: name)) {
                let h = sha256Hex(for: d)
                if canonicals[h] == nil { canonicals[h] = name; result.append(name) }
            }
        }
        return result
    }
}

struct CardBackupData: Codable {
    let version: Int
    let cards: [SavedCardRecord]
    let faceAssets: [String: Data]
}
