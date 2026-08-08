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
    @Published private(set) var mapDataRevision: Int = 0

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
    private var automaticCloudSyncTask: Task<Void, Never>?
    private var iCloudChangeObserver: NSObjectProtocol?
    private var isApplyingCloudSync = false
    private var imageCache: [String: UIImage] = [:]

    private let iCloudBackupKey = "icloud_card_backup"
    private let iCloudBackupUpdatedAtKey = "icloud_card_backup_updated_at"
    private let localDataUpdatedAtKey = "cardbal_local_data_updated_at"
    private let lastAppliedCloudUpdateKey = "cardbal_last_applied_cloud_update_at"
    private let lastUploadedCloudUpdateKey = "cardbal_last_uploaded_cloud_update_at"

    init() {
        openDatabase()
        migrateIfNeeded()
        load()
        startAutomaticiCloudSync()
    }

    deinit {
        automaticCloudSyncTask?.cancel()
        if let iCloudChangeObserver {
            NotificationCenter.default.removeObserver(iCloudChangeObserver)
        }
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
            cards[index].rawTransactions = mergeRawRecords(
                existing: cards[index].rawTransactions,
                incoming: snapshot.rawTransactions,
                family: cardFamily,
                technology: snapshot.technology,
                kind: .transactions
            )
            cards[index].rawTransitHistory = mergeRawRecords(
                existing: cards[index].rawTransitHistory,
                incoming: snapshot.rawTransitHistory,
                family: cardFamily,
                technology: snapshot.technology,
                kind: .transit
            )
            cards[index].region = snapshot.region
                ?? snapshot.resultFields.first(where: { $0.title == "Brand" })?.value
                ?? snapshot.resultFields.first(where: { $0.title == "Region" })?.value
                ?? cards[index].region
            cards[index].issuingCity = snapshot.resultFields.first(where: { $0.title == "Issuing City" })?.value
            cards[index].cardTypeStr = snapshot.resultFields.first(where: { $0.title == "Card Type" })?.value
            cards[index].issueDateStr = snapshot.resultFields.first(where: { $0.title == "Issue Date" })?.value
            cards[index].expiryDateStr = snapshot.resultFields.first(where: { $0.title == "Expiry Date" })?.value
            autoApplyPresetIfMatching(id: id)
            markMapDataChanged()
        } else {
            let record = SavedCardRecord(snapshot: snapshot)
            cards.insert(record, at: 0)
            autoApplyPresetIfMatching(id: id)
            markMapDataChanged()
        }
        save()
    }

    private func mergeRawRecords(existing: [String], incoming: [String], family: String, technology: String, kind: RawHistoryKind) -> [String] {
        let existing = existing.filter(SavedCardRecord.rawRecordHasContent)
        let incoming = incoming.filter(SavedCardRecord.rawRecordHasContent)
        guard !existing.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return existing }

        struct IndexedRawRecord {
            let raw: String
            let transaction: TransitTransaction?
            let sourcePriority: Int
            let sourceIndex: Int

            var dedupeKey: String {
                if let recordNumber = transaction?.recordNumber {
                    return "record:\(recordNumber)"
                }
                return "raw:\(raw)"
            }
        }

        let mergedCandidates =
            existing.enumerated().map {
                IndexedRawRecord(
                    raw: $0.element,
                    transaction: TransactionDecoderRegistry.decode(raw: $0.element, family: family, technology: technology, context: existing, at: $0.offset, kind: kind),
                    sourcePriority: 1,
                    sourceIndex: $0.offset
                )
            } +
            incoming.enumerated().map {
                IndexedRawRecord(
                    raw: $0.element,
                    transaction: TransactionDecoderRegistry.decode(raw: $0.element, family: family, technology: technology, context: incoming, at: $0.offset, kind: kind),
                    sourcePriority: 0,
                    sourceIndex: $0.offset
                )
            }

        var deduped: [String: IndexedRawRecord] = [:]
        for candidate in mergedCandidates {
            let key = candidate.dedupeKey
            if let existingCandidate = deduped[key] {
                if candidate.sourcePriority < existingCandidate.sourcePriority {
                    deduped[key] = candidate
                }
            } else {
                deduped[key] = candidate
            }
        }

        return deduped.values.sorted { lhs, rhs in
            switch (lhs.transaction?.date, rhs.transaction?.date) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return leftDate > rightDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let leftRecord = lhs.transaction?.recordNumber ?? Int.min
                let rightRecord = rhs.transaction?.recordNumber ?? Int.min
                if leftRecord != rightRecord {
                    return leftRecord > rightRecord
                }
                if lhs.sourcePriority != rhs.sourcePriority {
                    return lhs.sourcePriority < rhs.sourcePriority
                }
                return lhs.sourceIndex < rhs.sourceIndex
            }
        }.map(\.raw)
    }

    func deleteLocalRecord(cardID: String, kind: RawHistoryKind, rawData: String) {
        // Defer the mutation to the next run loop tick so SwiftUI's swipe-to-delete
        // animation can complete before the @Published change triggers a re-render.
        DispatchQueue.main.async { [self] in
            guard let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
            switch kind {
            case .transactions:
                if let i = cards[index].rawTransactions.firstIndex(of: rawData) {
                    cards[index].rawTransactions.remove(at: i)
                }
            case .transit:
                if let i = cards[index].rawTransitHistory.firstIndex(of: rawData) {
                    cards[index].rawTransitHistory.remove(at: i)
                }
            }
            markMapDataChanged()
            save()
        }
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
        // Fallback for Climate Card to its dedicated preset
        else if family.contains("climate") {
            if let match = allPresets.first(where: { $0.id == "CLIMATE" }) {
                applyPreset(match, to: id)
            }
        }
        // Nice / Lignes d'Azur cards use La Carte as their default face.
        else if family.contains("lignes d'azur") || family.contains("nice") {
            if let match = allPresets.first(where: { $0.id == "LA_CARTE" }) {
                applyPreset(match, to: id)
            }
        }
        // Try SN prefix match
        else {
            let jpPrefixes = ["JE": "Suica", "PB": "PASMO", "JW": "ICOCA", "FC": "Hayakaken", "JK": "SUGOCA", "TP": "Manaca", "JH": "Kitaca", "NR": "Nimoca", "JC": "TOICA"]
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
        
        let jpPrefixes = ["JE": "Suica", "PB": "PASMO", "JW": "ICOCA", "FC": "Hayakaken", "JK": "SUGOCA", "TP": "Manaca", "KI": "Kitaca", "NI": "Nimoca", "NR": "Nimoca", "TO": "TOICA"]
        for (prefix, brand) in jpPrefixes {
            if snUpper.hasPrefix(prefix) {
                cards[index].cardFamily = brand
                break
            }
        }
        
        // Ensure auto-preset application triggers if not already using an image
        if cards[index].faceImageFileName == nil {
            autoApplyPresetIfMatching(id: id)
        }
        markMapDataChanged()
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
            applyAutoMarkerColor(to: &cards[index], image: image)
            save()
        } catch { return }
    }

    func applyFaceAsset(_ fileName: String, to id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }),
              let image = loadFaceImage(fileName: fileName) else { return }
        cards[index].faceImageFileName = fileName
        cards[index].isUsingImage = true // Set to true when applying asset
        applyAutoImageTextColors(to: &cards[index], image: image)
        applyAutoMarkerColor(to: &cards[index], image: image)
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
        markMapDataChanged()
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
            CardPreset(id: "TOICA", name: "TOICA", fileName: "toica"),
            CardPreset(id: "EDY", name: "Edy", fileName: "edy"),
            CardPreset(id: "WAON", name: "WAON", fileName: "waon"),
            CardPreset(id: "NANACO", name: "nanaco", fileName: "nanaco"),
            CardPreset(id: "EZL", name: "EZL / Cashbee", fileName: "ezl"),
            CardPreset(id: "CLIMATE", name: "Climate Card", fileName: "climate-card"),
            CardPreset(id: "LA_CARTE", name: "La Carte", fileName: "la-carte"),
            CardPreset(id: "LA_CARTE_BLUE", name: "La Carte Blue", fileName: "la-carte-blue"),
            CardPreset(id: "TM", name: "T-money", fileName: "tmoney")
        ]
    }

    func applyPreset(_ preset: CardPreset, to id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }

        // Use the asset name directly instead of copying to a JPEG file
        cards[index].faceImageFileName = preset.fileName
        cards[index].isUsingImage = true

        if let image = UIImage(named: preset.fileName) {
            applyAutoImageTextColors(to: &cards[index], image: image)
            applyAutoMarkerColor(to: &cards[index], image: image)
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
        FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.ad.neko.cardbal")?.appendingPathComponent("Documents")
    }

    func backupToiCloud() {
        Task { @MainActor in
            await runiCloudBackup(showProgress: true)
        }
    }

    func restoreFromiCloud() {
        Task { @MainActor in
            let changed = await runiCloudRestore(showProgress: true, force: true)
            if changed {
                scheduleAutomaticiCloudBackup(delay: 1_000_000_000)
            }
        }
    }

    private func startAutomaticiCloudSync() {
        iCloudChangeObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let changed = await self.runiCloudRestore(showProgress: false, force: false)
                if changed {
                    self.scheduleAutomaticiCloudBackup(delay: 1_000_000_000)
                }
            }
        }

        NSUbiquitousKeyValueStore.default.synchronize()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 750_000_000)
            let changed = await runiCloudRestore(showProgress: false, force: cards.isEmpty)
            if changed || !cards.isEmpty {
                scheduleAutomaticiCloudBackup(delay: 2_000_000_000)
            }
        }
    }

    private func scheduleAutomaticiCloudBackup(delay: UInt64 = 3_000_000_000) {
        guard !isApplyingCloudSync else { return }
        automaticCloudSyncTask?.cancel()
        automaticCloudSyncTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await runiCloudBackup(showProgress: false)
        }
    }

    @MainActor
    private func runiCloudBackup(showProgress: Bool) async {
        save(force: true, scheduleCloudSync: false)
        guard let data = exportBackup(includeFaceAssets: false) else {
            print("[iCloud] Failed to export metadata")
            return
        }

        if showProgress {
            isSyncing = true
            syncProgress = 0.1
            syncMessage = "Preparing backup..."
        }

        print("[iCloud] Starting backup...")
        let cloudUpdatedAt = Date().timeIntervalSince1970
        let store = NSUbiquitousKeyValueStore.default
        store.set(data, forKey: iCloudBackupKey)
        store.set(cloudUpdatedAt, forKey: iCloudBackupUpdatedAtKey)
        store.synchronize()
        UserDefaults.standard.set(cloudUpdatedAt, forKey: lastAppliedCloudUpdateKey)
        UserDefaults.standard.set(cloudUpdatedAt, forKey: lastUploadedCloudUpdateKey)

        if showProgress {
            syncProgress = 0.3
            syncMessage = "Metadata synced..."
        }
        print("[iCloud] Card metadata synced to KVS")

        if let remoteDir = ubiquityDocumentsURL {
            print("[iCloud] Ubiquity container URL: \(remoteDir.path)")
            if showProgress { syncMessage = "Uploading database..." }
            do {
                try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
                let localDB = URL(fileURLWithPath: dbPath)
                let remoteDB = remoteDir.appendingPathComponent("cards.sqlite")
                if FileManager.default.fileExists(atPath: remoteDB.path) {
                    try FileManager.default.removeItem(at: remoteDB)
                }
                try FileManager.default.copyItem(at: localDB, to: remoteDB)
                print("[iCloud] Database uploaded successfully")
            } catch {
                print("[iCloud] Database upload failed: \(error)")
            }
            if showProgress { syncProgress = 0.6 }

            let assets = faceAssets()
            print("[iCloud] Found \(assets.count) images to upload")
            for (index, asset) in assets.enumerated() {
                let local = cardFaceFileURL(fileName: asset.fileName)
                let remote = remoteDir.appendingPathComponent(asset.fileName)
                if showProgress { syncMessage = "Uploading images (\(index + 1)/\(assets.count))..." }
                do {
                    if FileManager.default.fileExists(atPath: remote.path) {
                        try FileManager.default.removeItem(at: remote)
                    }
                    try FileManager.default.copyItem(at: local, to: remote)
                    print("[iCloud] Uploaded image: \(asset.fileName)")
                } catch {
                    print("[iCloud] Image upload failed for \(asset.fileName): \(error)")
                }
                if showProgress, !assets.isEmpty {
                    syncProgress = 0.6 + (Double(index + 1) / Double(assets.count) * 0.4)
                }
            }
        } else {
            print("[iCloud] Ubiquity container is NOT available. Check iCloud settings.")
            if showProgress { syncMessage = "Error: iCloud Unavailable" }
        }

        if showProgress {
            syncMessage = "Backup complete"
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            isSyncing = false
            syncMessage = nil
        }
    }

    @MainActor
    @discardableResult
    private func runiCloudRestore(showProgress: Bool, force: Bool) async -> Bool {
        if showProgress {
            isSyncing = true
            syncProgress = 0.1
            syncMessage = "Connecting to iCloud..."
        }

        let store = NSUbiquitousKeyValueStore.default
        store.synchronize()
        let cloudUpdatedAt = store.double(forKey: iCloudBackupUpdatedAtKey)
        let shouldApplyCloud = shouldApplyCloudData(cloudUpdatedAt: cloudUpdatedAt, force: force)
        var changed = false

        isApplyingCloudSync = true
        defer {
            isApplyingCloudSync = false
            if showProgress {
                Task { @MainActor in
                    syncMessage = changed ? "Restore complete" : "Already up to date"
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    isSyncing = false
                    syncMessage = nil
                }
            }
        }

        if shouldApplyCloud, let remoteDir = ubiquityDocumentsURL {
            if showProgress { syncMessage = "Merging database..." }
            let remoteDB = remoteDir.appendingPathComponent("cards.sqlite")
            if FileManager.default.fileExists(atPath: remoteDB.path) {
                changed = mergeSQLite(from: remoteDB) || changed
            }
            if showProgress { syncProgress = 0.4 }
        }

        if shouldApplyCloud, let data = store.data(forKey: iCloudBackupKey) {
            changed = mergeBackupData(data, includeAssets: true) || changed
            if showProgress { syncProgress = 0.6 }
        }

        if let remoteDir = ubiquityDocumentsURL {
            changed = downloadRemoteFaceAssets(from: remoteDir, showProgress: showProgress) || changed
        }

        if changed {
            load()
        }
        if cloudUpdatedAt > 0, shouldApplyCloud {
            UserDefaults.standard.set(cloudUpdatedAt, forKey: lastAppliedCloudUpdateKey)
        }

        return changed
    }

    private func shouldApplyCloudData(cloudUpdatedAt: TimeInterval, force: Bool) -> Bool {
        if force || cards.isEmpty { return true }
        guard cloudUpdatedAt > 0 else { return false }
        let localUpdatedAt = UserDefaults.standard.double(forKey: localDataUpdatedAtKey)
        let lastApplied = UserDefaults.standard.double(forKey: lastAppliedCloudUpdateKey)
        let newestKnownLocal = max(localUpdatedAt, lastApplied)
        return cloudUpdatedAt > newestKnownLocal
    }

    private func mergeSQLite(from sourceURL: URL) -> Bool {
        var sourceDB: OpaquePointer?
        guard sqlite3_open(sourceURL.path, &sourceDB) == SQLITE_OK else {
            print("[iCloud] Could not open incoming SQLite backup")
            return false
        }
        defer { sqlite3_close(sourceDB) }

        let query = "SELECT json_data FROM cards;"
        var stmt: OpaquePointer?
        var changed = false
        if sqlite3_prepare_v2(sourceDB, query, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let json = sqlite3_column_text(stmt, 0) {
                    let data = Data(String(cString: json).utf8)
                    if let card = try? JSONDecoder().decode(SavedCardRecord.self, from: data) {
                        changed = mergeIncomingCard(card) || changed
                    }
                }
            }
        } else {
            print("[iCloud] Incoming SQLite backup has no cards table")
        }
        sqlite3_finalize(stmt)
        return changed
    }

    private func mergeBackupData(_ data: Data, includeAssets: Bool) -> Bool {
        guard let backup = try? CardBackupData.decoder.decode(CardBackupData.self, from: data) else {
            print("[iCloud] Could not decode iCloud backup data")
            return false
        }

        var changed = false
        for card in backup.cards {
            changed = mergeIncomingCard(card) || changed
        }

        if includeAssets, !backup.faceAssets.isEmpty {
            do {
                try ensureCardFaceDirectoryExists()
                for (fileName, imageData) in backup.faceAssets {
                    let local = cardFaceFileURL(fileName: fileName)
                    if !FileManager.default.fileExists(atPath: local.path) {
                        try imageData.write(to: local, options: [.atomic])
                        changed = true
                    }
                }
            } catch {
                print("[iCloud] Could not import iCloud face assets: \(error)")
            }
        }

        return changed
    }

    private func mergeIncomingCard(_ incoming: SavedCardRecord) -> Bool {
        guard let index = cards.firstIndex(where: { $0.id == incoming.id }) else {
            cards.append(incoming)
            saveCardToSQLite(incoming)
            return true
        }

        let local = cards[index]
        let merged = mergedCard(local: local, incoming: incoming)
        guard merged != local else { return false }
        cards[index] = merged
        saveCardToSQLite(merged)
        return true
    }

    private func mergedCard(local: SavedCardRecord, incoming: SavedCardRecord) -> SavedCardRecord {
        var merged = incoming.scannedAt > local.scannedAt ? incoming : local
        let other = incoming.scannedAt > local.scannedAt ? local : incoming

        merged.rawTransactions = mergeRawRecords(
            existing: local.rawTransactions,
            incoming: incoming.rawTransactions,
            family: merged.cardFamily,
            technology: merged.technology,
            kind: .transactions
        )
        merged.rawTransitHistory = mergeRawRecords(
            existing: local.rawTransitHistory,
            incoming: incoming.rawTransitHistory,
            family: merged.cardFamily,
            technology: merged.technology,
            kind: .transit
        )

        if merged.faceImageFileName == nil {
            merged.faceImageFileName = other.faceImageFileName
            merged.isUsingImage = other.isUsingImage
        }
        if merged.customTitle == nil { merged.customTitle = other.customTitle }
        if merged.customDisplaySerialNumber == nil { merged.customDisplaySerialNumber = other.customDisplaySerialNumber }
        if merged.realSerialNumber == nil { merged.realSerialNumber = other.realSerialNumber }
        if merged.balanceText == nil { merged.balanceText = other.balanceText }
        if merged.balanceDetail == nil { merged.balanceDetail = other.balanceDetail }
        return merged
    }

    private func downloadRemoteFaceAssets(from remoteDir: URL, showProgress: Bool) -> Bool {
        do {
            try ensureCardFaceDirectoryExists()
            let assets = try FileManager.default.contentsOfDirectory(atPath: remoteDir.path)
            let images = assets.filter {
                let lower = $0.lowercased()
                return lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png")
            }
            var changed = false
            for (index, assetName) in images.enumerated() {
                if showProgress {
                    syncMessage = "Downloading images (\(index + 1)/\(images.count))..."
                }
                let local = cardFaceFileURL(fileName: assetName)
                let remote = remoteDir.appendingPathComponent(assetName)
                if !FileManager.default.fileExists(atPath: local.path) {
                    try FileManager.default.copyItem(at: remote, to: local)
                    changed = true
                }
                if showProgress, !images.isEmpty {
                    syncProgress = 0.6 + (Double(index + 1) / Double(images.count) * 0.4)
                }
            }
            return changed
        } catch {
            print("[iCloud] Image download failed: \(error)")
            return false
        }
    }

    @discardableResult
    func importBackup(_ data: Data) throws -> CardBackupImportResult {
        let backup = try CardBackupData.decoder.decode(CardBackupData.self, from: data)
        var byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        var replaced = 0

        for card in backup.cards {
            if byID[card.id] != nil { replaced += 1 }
            byID[card.id] = card
            saveCardToSQLite(card)
        }

        if !backup.faceAssets.isEmpty {
            try ensureCardFaceDirectoryExists()
            for (fileName, imageData) in backup.faceAssets {
                try imageData.write(to: cardFaceFileURL(fileName: fileName), options: [.atomic])
            }
        }

        cards = byID.values.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.scannedAt > $1.scannedAt
        }
        markMapDataChanged()
        scheduleAutomaticiCloudBackup(delay: 1_000_000_000)
        return CardBackupImportResult(imported: backup.cards.count, replaced: replaced)
    }

    func exportBackup() -> Data? {
        exportBackup(includeFaceAssets: true)
    }

    private func exportBackup(includeFaceAssets: Bool) -> Data? {
        let usedFaceNames = Set(cards.compactMap(\.faceImageFileName))
        var exportedFaceAssets: [String: Data] = [:]
        if includeFaceAssets {
            for asset in faceAssets() where usedFaceNames.contains(asset.fileName) {
                if let data = try? Data(contentsOf: cardFaceFileURL(fileName: asset.fileName)) {
                    exportedFaceAssets[asset.fileName] = data
                }
            }
        }
        let backup = CardBackupData(version: 1, cards: cards, faceAssets: exportedFaceAssets)
        return try? CardBackupData.encoder.encode(backup)
    }

    private func save(force: Bool = false, scheduleCloudSync: Bool = true) {
        saveTask?.cancel()
        let currentCards = cards
        let work = { [weak self] in
            guard let self = self else { return }
            for card in currentCards {
                self.saveCardToSQLite(card)
            }
        }
        if scheduleCloudSync && !isApplyingCloudSync {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: localDataUpdatedAtKey)
            scheduleAutomaticiCloudBackup()
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
        markMapDataChanged()
    }

    private func markMapDataChanged() {
        mapDataRevision &+= 1
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
        case "U-Money": return SavedCardColor(red: 0.12, green: 0.43, blue: 0.78)
        case "EZL / Cashbee": return SavedCardColor(red: 0.94, green: 0.58, blue: 0.18)
        case "Lignes d'Azur card": return SavedCardColor(red: 0.05, green: 0.36, blue: 0.73)
        default: return SavedCardColor(red: 0.24, green: 0.27, blue: 0.35)
        }
    }

    private func applyAutoImageTextColors(to card: inout SavedCardRecord, image: UIImage) {
        card.autoTitleTextColor = bestReadableTextColor(for: image, region: CGRect(x: 0.04, y: 0.04, width: 0.42, height: 0.28))
        card.autoBalanceTextColor = bestReadableTextColor(for: image, region: CGRect(x: 0.56, y: 0.04, width: 0.4, height: 0.28))
    }

    /// Extracts the most vivid "signature" color from the image — skipping whites, silvers, grays, and blacks.
    private func applyAutoMarkerColor(to card: inout SavedCardRecord, image: UIImage) {
        guard let sampled = sampledColors(in: image, region: CGRect(x: 0, y: 0, width: 1, height: 1)) else { return }

        // Bucket colors by top 4 bits of each channel for clustering
        var buckets: [[Int]: (count: Int, rSum: Double, gSum: Double, bSum: Double)] = [:]
        for c in sampled {
            let key = [Int(c.red * 15), Int(c.green * 15), Int(c.blue * 15)]
            let existing = buckets[key] ?? (0, 0, 0, 0)
            buckets[key] = (existing.count + 1, existing.rSum + c.red, existing.gSum + c.green, existing.bSum + c.blue)
        }

        struct ColorCandidate {
            let r, g, b, saturation: Double
            let count: Int
            /// Score: prioritize vivid colors (high saturation) that also appear frequently
            var score: Double { saturation * Double(count) }
        }

        var candidates: [ColorCandidate] = []
        for bucket in buckets.values {
            let r = bucket.rSum / Double(bucket.count)
            let g = bucket.gSum / Double(bucket.count)
            let b = bucket.bSum / Double(bucket.count)
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let sat = maxC > 0 ? (maxC - minC) / maxC : 0

            // Reject white → silver (bright and desaturated)
            if lum > 0.65 && sat < 0.20 { continue }
            // Reject dark grey → black (dim and desaturated)
            if lum < 0.20 && sat < 0.25 { continue }
            // Reject mid grays (desaturated neutrals)
            if sat < 0.15 { continue }

            candidates.append(ColorCandidate(r: r, g: g, b: b, saturation: sat, count: bucket.count))
        }

        // Pick the candidate with the highest score (saturation × frequency)
        guard let best = candidates.max(by: { $0.score < $1.score }) else { return }
        card.markerColor = SavedCardColor(red: best.r, green: best.g, blue: best.b)
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

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601WithFractionalSeconds.string(from: date))
        }
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                if let date = iso8601WithFractionalSeconds.date(from: string) ?? iso8601.date(from: string) {
                    return date
                }
            }
            if let value = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: value)
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported CardBal date value")
        }
        return decoder
    }

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

struct CardBackupImportResult {
    let imported: Int
    let replaced: Int
}
