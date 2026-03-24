import SwiftUI
import CryptoKit
import SQLite3

struct SavedFaceAsset: Identifiable, Hashable {
    let fileName: String
    var id: String { fileName }
}

struct CardPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let fileName: String
}

class CardWalletStore: ObservableObject {
    @Published var cards: [SavedCardRecord] = []
    @Published var isSyncing: Bool = false
    @Published var syncProgress: Double = 0
    @Published var syncMessage: String?

    private var db: OpaquePointer?
    private let dbPath: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("CardBal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cards.sqlite").path
    }()

    private let userDefaultsKey = "savedTransitCards"
    private var saveTask: Task<Void, Never>?
    private var imageCache: [String: UIImage] = [:]

    init() {
        openDatabase()
        migrateIfNeeded()
        load()
    }

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("Error opening database at \(dbPath)")
            return
        }
        let createTable = "CREATE TABLE IF NOT EXISTS cards (id TEXT PRIMARY KEY, json_data TEXT);"
        if sqlite3_exec(db, createTable, nil, nil, nil) != SQLITE_OK {
            print("Error creating cards table")
        }
    }

    private func migrateIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let oldCards = try? JSONDecoder().decode([SavedCardRecord].self, from: data) else { return }
        
        for card in oldCards {
            saveCardToSQLite(card)
        }
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    private func saveCardToSQLite(_ card: SavedCardRecord) {
        let insert = "INSERT OR REPLACE INTO cards (id, json_data) VALUES (?, ?);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, insert, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (card.id as NSString).utf8String, -1, nil)
            if let data = try? JSONEncoder().encode(card), let json = String(data: data, encoding: .utf8) {
                sqlite3_bind_text(stmt, 2, (json as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) != SQLITE_DONE {
                    print("Error saving card \(card.id)")
                }
            }
        }
        sqlite3_finalize(stmt)
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
            // Preserve Physical S/N (17 chars) over Internal IDm (16 chars or nil)
            let existingSN = cards[index].realSerialNumber ?? ""
            let incomingSN = snapshot.realSerialNumber ?? ""
            
            if existingSN.count == 17 && incomingSN.count < 17 {
                // Keep the high-quality physical S/N
            } else if !incomingSN.isEmpty {
                cards[index].realSerialNumber = incomingSN
            }
            // else: keep what we have (e.g. if incoming is nil/empty)
            cards[index].enhancedFeliCaDecoded = false
            cards[index].rawTransactions = snapshot.rawTransactions
            cards[index].rawTransitHistory = snapshot.rawTransitHistory
            cards[index].issuingCity = snapshot.resultFields.first(where: { $0.title == "Issuing City" })?.value
            cards[index].cardTypeStr = snapshot.resultFields.first(where: { $0.title == "Card Type" })?.value
            cards[index].issueDateStr = snapshot.resultFields.first(where: { $0.title == "Issue Date" })?.value
            cards[index].expiryDateStr = snapshot.resultFields.first(where: { $0.title == "Expiry Date" })?.value
            autoApplyPresetIfMatching(id: id)
        } else {
            let record = SavedCardRecord(snapshot: snapshot)
            cards.insert(record, at: 0)
            autoApplyPresetIfMatching(id: id)
        }
        save()
    }

    private func autoApplyPresetIfMatching(id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        let card = cards[index]
        if card.faceImageFileName != nil { return }
        
        let family = card.cardFamily.lowercased()
        let sn = card.realSerialNumber?.uppercased() ?? ""
        NSLog("[CardWalletStoreDebug] Auto-applying preset: family=%@, sn=%@", family, sn)
        
        let allPresets = presets()
        // Try family name match
        if let match = allPresets.first(where: { family.contains($0.name.lowercased()) }) {
            applyPreset(match, to: id)
        } 
        // Try SN prefix match
        else {
            let jpPrefixes = ["JE": "Suica", "PB": "PASMO", "JW": "ICOCA", "FC": "Hayakaken", "JK": "SUGOCA", "TP": "Manaca", "KI": "Kitaca", "NI": "Nimoca", "TO": "TOICA"]
            for (prefix, brand) in jpPrefixes {
                if sn.hasPrefix(prefix) {
                    if let match = allPresets.first(where: { $0.name == brand }) {
                        applyPreset(match, to: id)
                        break
                    }
                }
            }
        }
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

    func setRealSerialNumber(_ sn: String, for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        let snUpper = sn.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        cards[index].realSerialNumber = snUpper
        
        let jpPrefixes = ["JE": "Suica", "PB": "PASMO", "JW": "ICOCA", "FC": "Hayakaken", "JK": "SUGOCA", "TP": "Manaca", "KI": "Kitaca", "NI": "Nimoca", "PI": "PiTaPa", "TO": "TOICA"]
        for (prefix, brand) in jpPrefixes {
            if snUpper.hasPrefix(prefix) {
                cards[index].cardFamily = brand
                break
            }
        }
        autoApplyPresetIfMatching(id: id)
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

    func setIsUsingImage(_ isUsing: Bool, for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].isUsingImage = isUsing
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
            cards[index].isUsingImage = true // Set to true when adding image
            applyAutoImageTextColors(to: &cards[index], image: image)
            save()
        } catch { return }
    }

    func applyFaceAsset(_ fileName: String, to id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }),
              let image = loadFaceImage(fileName: fileName) else { return }
        cards[index].faceImageFileName = fileName
        cards[index].isUsingImage = true // Set to true when applying asset
        applyAutoImageTextColors(to: &cards[index], image: image)
        save()
    }

    func removeFaceImage(for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].faceImageFileName = nil
        cards[index].isUsingImage = false
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

    func presets() -> [CardPreset] {
        return [
            CardPreset(id: "JE", name: "Suica", fileName: "suica"),
            CardPreset(id: "PB", name: "PASMO", fileName: "pasmo"),
            CardPreset(id: "JW", name: "ICOCA", fileName: "icoca"),
            CardPreset(id: "FC", name: "Hayakaken", fileName: "hayakaken"),
            CardPreset(id: "JK", name: "SUGOCA", fileName: "sugoca"),
            CardPreset(id: "TP", name: "Manaca", fileName: "manaca"),
            CardPreset(id: "Kitaca", name: "Kitaca", fileName: "kitaca"),
            CardPreset(id: "Nimoca", name: "Nimoca", fileName: "nimoca"),
            CardPreset(id: "TOICA", name: "TOICA", fileName: "toica")
        ]
    }

    func applyPreset(_ preset: CardPreset, to id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        
        // Use the asset name directly instead of copying to a JPEG file
        cards[index].faceImageFileName = preset.fileName
        cards[index].isUsingImage = true
        
        if let image = UIImage(named: preset.fileName) {
            applyAutoImageTextColors(to: &cards[index], image: image)
        }
        save()
    }

    func isFaceAssetUsed(_ fileName: String) -> Bool {
        cards.contains { $0.faceImageFileName == fileName }
    }

    func card(withID id: String) -> SavedCardRecord? {
        cards.first(where: { $0.id == id })
    }

    func loadFaceImage(fileName: String?) -> UIImage? {
        guard let fileName = fileName else { return nil }
        if let cached = imageCache[fileName] { return cached }
        
        // Try loading from Assets first (for presets)
        if let assetImage = UIImage(named: fileName) {
            imageCache[fileName] = assetImage
            return assetImage
        }
        
        // Try loading from local file (for custom photos)
        let fileURL = cardFaceFileURL(fileName: fileName)
        if let image = UIImage(contentsOfFile: fileURL.path) {
            imageCache[fileName] = image
            return image
        }
        return nil
    }

    func deleteFaceAsset(_ fileName: String) {
        imageCache.removeValue(forKey: fileName)
        try? FileManager.default.removeItem(at: cardFaceFileURL(fileName: fileName))
        objectWillChange.send()
        save()
    }

    func deleteUnusedFaceAssets() {
        let used = Set(cards.compactMap(\.faceImageFileName))
        for asset in faceAssets() where !used.contains(asset.fileName) {
            try? FileManager.default.removeItem(at: cardFaceFileURL(fileName: asset.fileName))
        }
        objectWillChange.send()
        save()
    }

    private var ubiquityDocumentsURL: URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents")
    }

    func backupToiCloud() {
        Task { @MainActor in
            isSyncing = true
            syncProgress = 0.1
            syncMessage = "Preparing backup..."
            
            print("[iCloud] Starting backup...")
            
            // 1. Sync card metadata to KVS
            guard let data = exportBackup() else { 
                print("[iCloud] Failed to export metadata")
                isSyncing = false
                return 
            }
            NSUbiquitousKeyValueStore.default.set(data, forKey: "icloud_card_backup")
            NSUbiquitousKeyValueStore.default.synchronize()
            syncProgress = 0.3
            syncMessage = "Metadata synced..."
            print("[iCloud] Card metadata synced to KVS")
            
            // 2. Backup DB and Images to Ubiquity Container
            if let remoteDir = ubiquityDocumentsURL {
                print("[iCloud] Ubiquity container URL: \(remoteDir.path)")
                syncMessage = "Uploading database..."
                do {
                    try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
                    let localDB = URL(fileURLWithPath: self.dbPath)
                    let remoteDB = remoteDir.appendingPathComponent("cards.sqlite")
                    if FileManager.default.fileExists(atPath: remoteDB.path) {
                        try FileManager.default.removeItem(at: remoteDB)
                    }
                    try FileManager.default.copyItem(at: localDB, to: remoteDB)
                    print("[iCloud] Database uploaded successfully")
                } catch {
                    print("[iCloud] Database upload failed: \(error)")
                }
                syncProgress = 0.6
                
                let assets = self.faceAssets()
                print("[iCloud] Found \(assets.count) images to upload")
                for (index, asset) in assets.enumerated() {
                    let local = self.cardFaceFileURL(fileName: asset.fileName)
                    let remote = remoteDir.appendingPathComponent(asset.fileName)
                    syncMessage = "Uploading images (\(index + 1)/\(assets.count))..."
                    do {
                        if !FileManager.default.fileExists(atPath: remote.path) {
                            try FileManager.default.copyItem(at: local, to: remote)
                            print("[iCloud] Uploaded image: \(asset.fileName)")
                        } else {
                            print("[iCloud] Image already exists in iCloud: \(asset.fileName)")
                        }
                    } catch {
                        print("[iCloud] Image upload failed for \(asset.fileName): \(error)")
                    }
                    syncProgress = 0.6 + (Double(index + 1) / Double(assets.count) * 0.4)
                }
            } else {
                print("[iCloud] Ubiquity container is NOT available. Check iCloud settings.")
                syncMessage = "Error: iCloud Unavailable"
            }
            
            syncMessage = "Backup complete"
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            isSyncing = false
            syncMessage = nil
        }
    }

    func restoreFromiCloud() {
        Task { @MainActor in
            isSyncing = true
            syncProgress = 0.1
            syncMessage = "Connecting to iCloud..."
            NSUbiquitousKeyValueStore.default.synchronize()
            
            // 1. Download and Merge SQLite DB
            if let remoteDir = ubiquityDocumentsURL {
                syncMessage = "Merging database..."
                let remoteDB = remoteDir.appendingPathComponent("cards.sqlite")
                if FileManager.default.fileExists(atPath: remoteDB.path) {
                    mergeSQLite(from: remoteDB)
                }
            }
            syncProgress = 0.5
            
            // 2. Download Images
            if let remoteDir = ubiquityDocumentsURL {
                try? ensureCardFaceDirectoryExists()
                let assets = (try? FileManager.default.contentsOfDirectory(atPath: remoteDir.path)) ?? []
                let jpgs = assets.filter { $0.hasSuffix(".jpg") }
                for (index, assetName) in jpgs.enumerated() {
                    syncMessage = "Downloading images (\(index + 1)/\(jpgs.count))..."
                    let local = cardFaceFileURL(fileName: assetName)
                    let remote = remoteDir.appendingPathComponent(assetName)
                    if !FileManager.default.fileExists(atPath: local.path) {
                        try? FileManager.default.copyItem(at: remote, to: local)
                    }
                    syncProgress = 0.5 + (Double(index + 1) / Double(jpgs.count) * 0.5)
                }
            }
            
            // 3. Finalize
            syncMessage = "Reloading..."
            load()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            isSyncing = false
            syncMessage = nil
        }
    }

    private func mergeSQLite(from sourceURL: URL) {
        // Strategy: Attach the incoming DB and insert/replace into local cards table
        let sourcePath = sourceURL.path
        let attachSQL = "ATTACH DATABASE '\(sourcePath)' AS incoming;"
        
        if sqlite3_exec(db, attachSQL, nil, nil, nil) == SQLITE_OK {
            // Merge records: INSERT OR REPLACE INTO cards SELECT * FROM incoming.cards
            let mergeSQL = "INSERT OR REPLACE INTO cards SELECT * FROM incoming.cards;"
            if sqlite3_exec(db, mergeSQL, nil, nil, nil) != SQLITE_OK {
                print("Error during SQLite merge")
            }
            sqlite3_exec(db, "DETACH DATABASE incoming;", nil, nil, nil)
        }
    }

    func exportBackup() -> Data? {
        let backup = CardBackupData(version: 1, cards: cards, faceAssets: [:])
        return try? JSONEncoder().encode(backup)
    }

    private func save(force: Bool = false) {
        saveTask?.cancel()
        let currentCards = cards
        let work = { [weak self] in
            guard let self = self else { return }
            for card in currentCards {
                self.saveCardToSQLite(card)
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
        let query = "SELECT json_data FROM cards;"
        var stmt: OpaquePointer?
        var loadedCards: [SavedCardRecord] = []
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let json = sqlite3_column_text(stmt, 0) {
                    let data = Data(String(cString: json).utf8)
                    if let card = try? JSONDecoder().decode(SavedCardRecord.self, from: data) {
                        loadedCards.append(card)
                    }
                }
            }
        }
        sqlite3_finalize(stmt)
        self.cards = loadedCards.sorted { 
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.scannedAt > $1.scannedAt
        }
    }

    func updateOrder() {
        for i in 0..<cards.count {
            cards[i].order = i
        }
        save()
    }

    func moveCard(from sourceID: String, to destinationID: String) {
        guard sourceID != destinationID,
              let sourceIndex = cards.firstIndex(where: { $0.id == sourceID }),
              let destinationIndex = cards.firstIndex(where: { $0.id == destinationID }) else { return }
        let movedCard = cards.remove(at: sourceIndex)
        cards.insert(movedCard, at: destinationIndex)
        updateOrder()
    }

    func moveCard(from sourceID: String, toIndex destinationIndex: Int) {
        guard let sourceIndex = cards.firstIndex(where: { $0.id == sourceID }) else { return }
        let clampedIndex = min(max(destinationIndex, 0), cards.count - 1)
        guard sourceIndex != clampedIndex else { return }
        let movedCard = cards.remove(at: sourceIndex)
        cards.insert(movedCard, at: clampedIndex)
        updateOrder()
    }

    func bringToFront(_ id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }), index != 0 else { return }
        let movedCard = cards.remove(at: index)
        cards.insert(movedCard, at: 0)
        updateOrder()
    }

    func moveCard(fromOffsets: IndexSet, toOffset: Int) {
        cards.move(fromOffsets: fromOffsets, toOffset: toOffset)
        updateOrder()
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
