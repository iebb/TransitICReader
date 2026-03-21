import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit

// MARK: - App Entry

struct ContentView: View {
    @StateObject private var reader = NFCTransitReader()
    @StateObject private var cardStore = CardWalletStore()

    var body: some View {
        TabView {
            ScanHomeView(reader: reader, cardStore: cardStore)
                .tabItem {
                    Label("Scan", systemImage: "dot.radiowaves.left.and.right")
                }

            CardsView(store: cardStore)
                .tabItem {
                    Label("Cards", systemImage: "wallet.bifold")
                }

            SettingsView(store: cardStore)
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .tint(Color.accentColor)
        .onAppear {
            reader.isEnhancedFeliCaDecodingEnabled = cardStore.enhancedFeliCaDecodingEnabled
            reader.checkIfCardAlreadyEnhanced = { idm in
                cardStore.cards.first(where: { $0.id == idm })?.enhancedFeliCaDecoded ?? false
            }
        }
        .onChange(of: cardStore.enhancedFeliCaDecodingEnabled) { newValue in
            reader.isEnhancedFeliCaDecodingEnabled = newValue
        }
    }
}

// MARK: - ScanHomeView

private struct ScanHomeView: View {
    @ObservedObject var reader: NFCTransitReader
    @ObservedObject var cardStore: CardWalletStore
    @AppStorage("show_scan_home_help_v4") private var showHelp = true

    var body: some View {
        NavigationStack {
            List {
                if showHelp {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("Transit IC Card Reader", systemImage: "wave.3.right.circle.fill")
                                    .font(.title3.weight(.semibold))
                                    .symbolRenderingMode(.hierarchical)
                                
                                Spacer()
                                
                                Button {
                                    withAnimation { showHelp = false }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                        .font(.title3)
                                }
                                .buttonStyle(.plain)
                            }

                            Text("Scan physical transit cards such as Suica, ICOCA, Octopus, T-money, and EZL/Cashbee. The app shows parsed balance data and raw NFC payloads.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }

                Section("Result") {
                    if let snapshot = reader.latestSnapshot {
                        KeyValueRow(title: "Card Type", value: snapshot.cardFamily)
                        if let balance = snapshot.balanceText {
                            KeyValueRow(title: "Balance", value: balance)
                        }
                        if let realSN = snapshot.realSerialNumber {
                            KeyValueRow(title: "Real Serial", value: realSN)
                        }
                        KeyValueRow(title: "Scanned", value: snapshot.scannedAt.formatted(date: .abbreviated, time: .standard))
                    } else {
                        Text("No card scanned yet.")
                            .foregroundStyle(.secondary)
                    }
                }

                if let snapshot = reader.latestSnapshot {
                    Section {
                        Button {
                            cardStore.upsert(snapshot: snapshot)
                        } label: {
                            Label("Save to Wallet", systemImage: "plus.circle.fill")
                        }
                    }
                }
            }
            .navigationTitle("Scan Card")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { reader.beginScanning() }) {
                        Label("Start Scan", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.headline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    .disabled(reader.isScanning)
                }
            }
        }
    }
}

// MARK: - CardsView

private struct CardsView: View {
    @ObservedObject var store: CardWalletStore

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 20) {
                    ForEach(store.cards) { card in
                        NavigationLink {
                            SavedCardDetailView(card: card, store: store)
                        } label: {
                            WalletCardView(card: card, isExpanded: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Wallet")
        }
    }
}

// MARK: - Components

struct KeyValueRow: View {
    let title, value: String
    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }.font(.subheadline)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = rect.width * 0.16
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.midX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.midX, y: rect.minY), radius: r)
        path.closeSubpath()
        return path
    }
}

struct WalletCardView: View {
    let card: SavedCardRecord
    var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                markerBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.customTitle ?? card.cardFamily)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(card.displayedSerialNumber)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(card.balance)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
            }
            
            if !isExpanded {
                HStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("LAST SCANNED")
                            .font(.system(size: 8, weight: .black))
                            .foregroundStyle(.secondary)
                        Text(card.scannedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }
        }
        .padding()
        .background(card.color.color.gradient.opacity(0.15))
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(card.color.color.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var markerBadge: some View {
        ZStack {
            markerBackground(size: 40)
            if let markerSystemName = card.markerSymbolName {
                Image(systemName: markerSystemName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder
    private func markerBackground(size: CGFloat) -> some View {
        Group {
            switch card.markerShape {
            case .circle:
                Circle().fill(card.markerColor.color)
            case .square:
                RoundedRectangle(cornerRadius: size * 0.2).fill(card.markerColor.color)
            case .triangle:
                Triangle().fill(card.markerColor.color)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - SettingsView

private struct SettingsView: View {
    @ObservedObject var store: CardWalletStore

    var body: some View {
        NavigationStack {
            List {
                Section("Card Faces") {
                    NavigationLink {
                        CardFaceLibraryView(store: store)
                    } label: {
                        Label("Manage Card Faces", systemImage: "photo.stack")
                    }
                }
                
                Section("Experimental") {
                    Toggle("Enhanced FeliCa Decoding", isOn: $store.enhancedFeliCaDecodingEnabled)
                    Text("Attempt to retrieve the real serial number for Japanese transit cards (Suica/PASMO) using an external crypto server. Runs once per card.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Data Management") {
                    Button {
                        store.backupToiCloud()
                    } label: {
                        Label("Backup to iCloud", systemImage: "cloud.and.arrow.up")
                    }
                    
                    Button {
                        store.restoreFromiCloud()
                    } label: {
                        Label("Restore from iCloud", systemImage: "cloud.and.arrow.down")
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

// MARK: - Detail & Library Views (Re-implemented)

private struct CardFaceLibraryView: View {
    @ObservedObject var store: CardWalletStore
    
    var body: some View {
        List {
            let assets = store.faceAssets()
            if assets.isEmpty {
                ContentUnavailableView("No Face Assets", systemImage: "photo.on.rectangle")
            } else {
                ForEach(assets) { asset in
                    HStack {
                        if let img = store.loadFaceImage(fileName: asset.fileName) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 80, height: 50)
                                .cornerRadius(8)
                        }
                        VStack(alignment: .leading) {
                            Text(asset.fileName).font(.caption).foregroundStyle(.secondary)
                            if store.isFaceAssetUsed(asset.fileName) {
                                Text("In Use").font(.caption2).padding(4).background(Color.green.opacity(0.1)).cornerRadius(4)
                            }
                        }
                        Spacer()
                        if !store.isFaceAssetUsed(asset.fileName) {
                            Button(role: .destructive) { store.deleteFaceAsset(asset.fileName) } label: { Image(systemName: "trash") }
                        }
                    }
                }
            }
        }
        .navigationTitle("Face Library")
    }
}

private struct SavedCardDetailView: View {
    let card: SavedCardRecord
    @ObservedObject var store: CardWalletStore
    @State private var customTitle: String = ""
    @Environment(\.dismiss) var dismiss

    var body: some View {
        List {
            Section("Settings") {
                TextField("Custom Title", text: $customTitle)
                    .onAppear { customTitle = card.customTitle ?? "" }
                    .onChange(of: customTitle) { newValue in
                        store.setCustomTitle(newValue, for: card.id)
                    }
            }
            
            Section("Info") {
                KeyValueRow(title: "ID", value: card.id)
                KeyValueRow(title: "Family", value: card.cardFamily)
                KeyValueRow(title: "Technology", value: card.technology)
                if let pmm = card.pmm { KeyValueRow(title: "PMm", value: pmm) }
                if let realSN = card.realSerialNumber { KeyValueRow(title: "Real SN", value: realSN) }
            }
            
            Section {
                Button(role: .destructive) {
                    if let index = store.cards.firstIndex(where: { $0.id == card.id }) {
                        store.delete(at: IndexSet(integer: index))
                        dismiss()
                    }
                } label: {
                    Label("Delete Card", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Card Detail")
    }
}

// MARK: - Models (Restored)

enum SavedCardMarkerShape: String, Codable, CaseIterable, Identifiable {
    case circle = "Circle", square = "Square", triangle = "Triangle"
    var id: String { rawValue }
}

struct SavedCardColor: Codable, Hashable {
    var red, green, blue: Double
    var opacity: Double = 1.0
    var color: Color { Color(red: red, green: green, blue: blue, opacity: opacity) }
    init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
    init(color: Color) {
        if let comps = color.cgColor?.components, comps.count >= 3 {
            red = Double(comps[0]); green = Double(comps[1]); blue = Double(comps[2])
            opacity = comps.count >= 4 ? Double(comps[3]) : 1.0
        } else { red = 0; green = 0; blue = 0; opacity = 1.0 }
    }
    
    enum CodingKeys: String, CodingKey { case red, green, blue, opacity }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        red = try container.decode(Double.self, forKey: .red)
        green = try container.decode(Double.self, forKey: .green)
        blue = try container.decode(Double.self, forKey: .blue)
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
    }
}

enum ImageFaceEnhancer: String, Codable, CaseIterable, Identifiable {
    case none = "None", mask = "Glass Mask", border = "Subtle Border"
    var id: String { rawValue }
}

enum SavedCardDesign: String, Codable, CaseIterable, Identifiable {
    case classic = "Classic", sunrise = "Sunrise", metro = "Metro"
    var id: String { rawValue }
}

struct SavedCardField: Codable, Hashable, Identifiable {
    let id = UUID(), title, value: String
    init(_ result: ResultField) { self.title = result.title; self.value = result.value }
}

struct SavedCardRecord: Codable, Hashable, Identifiable {
    let id: String
    var cardFamily: String
    var markerSymbolName: String?
    var markerColor: SavedCardColor
    var markerOuterColor: SavedCardColor
    var markerShape: SavedCardMarkerShape
    var customTitle, customDisplaySerialNumber: String?
    var hideTitleOnImage, hideSerialNumber: Bool
    var imageFaceEnhancer: ImageFaceEnhancer
    var autoImageTextColors: Bool
    var autoTitleTextColor, autoBalanceTextColor, titleTextColorOverride, balanceTextColorOverride: SavedCardColor?
    var technology, identifierLabel, rawIdentifierValue, identifierValue: String
    var pmm, selectedAID, systemCode, balanceText, balanceDetail, realSerialNumber: String?
    var enhancedFeliCaDecoded: Bool
    var resultFields: [SavedCardField]
    var scannedAt: Date
    var color: SavedCardColor
    var design: SavedCardDesign
    var faceImageFileName: String?

    var balance: String { balanceText ?? balanceDetail ?? "No balance" }
    var displayedSerialNumber: String { customDisplaySerialNumber ?? realSerialNumber ?? identifierValue }

    init(id: String, cardFamily: String, markerSymbolName: String?, markerColor: SavedCardColor, markerOuterColor: SavedCardColor, markerShape: SavedCardMarkerShape, customTitle: String?, customDisplaySerialNumber: String?, hideTitleOnImage: Bool, hideSerialNumber: Bool, imageFaceEnhancer: ImageFaceEnhancer, autoImageTextColors: Bool, autoTitleTextColor: SavedCardColor?, autoBalanceTextColor: SavedCardColor?, titleTextColorOverride: SavedCardColor?, balanceTextColorOverride: SavedCardColor?, technology: String, identifierLabel: String, rawIdentifierValue: String, identifierValue: String, pmm: String?, selectedAID: String?, systemCode: String?, balanceText: String?, balanceDetail: String?, realSerialNumber: String?, enhancedFeliCaDecoded: Bool, resultFields: [SavedCardField], scannedAt: Date, color: SavedCardColor, design: SavedCardDesign, faceImageFileName: String?) {
        self.id = id; self.cardFamily = cardFamily; self.markerSymbolName = markerSymbolName; self.markerColor = markerColor; self.markerOuterColor = markerOuterColor; self.markerShape = markerShape; self.customTitle = customTitle; self.customDisplaySerialNumber = customDisplaySerialNumber; self.hideTitleOnImage = hideTitleOnImage; self.hideSerialNumber = hideSerialNumber; self.imageFaceEnhancer = imageFaceEnhancer; self.autoImageTextColors = autoImageTextColors; self.autoTitleTextColor = autoTitleTextColor; self.autoBalanceTextColor = autoBalanceTextColor; self.titleTextColorOverride = titleTextColorOverride; self.balanceTextColorOverride = balanceTextColorOverride; self.technology = technology; self.identifierLabel = identifierLabel; self.rawIdentifierValue = rawIdentifierValue; self.identifierValue = identifierValue; self.pmm = pmm; self.selectedAID = selectedAID; self.systemCode = systemCode; self.balanceText = balanceText; self.balanceDetail = balanceDetail; self.realSerialNumber = realSerialNumber; self.enhancedFeliCaDecoded = enhancedFeliCaDecoded; self.resultFields = resultFields; self.scannedAt = scannedAt; self.color = color; self.design = design; self.faceImageFileName = faceImageFileName
    }

    private enum CodingKeys: String, CodingKey {
        case id, cardFamily, markerSymbolName, markerColor, markerOuterColor, markerShape
        case customTitle, customDisplaySerialNumber, hideTitleOnImage, hideSerialNumber
        case imageFaceEnhancer, autoImageTextColors, autoTitleTextColor, autoBalanceTextColor
        case titleTextColorOverride, balanceTextColorOverride, technology, identifierLabel
        case rawIdentifierValue, identifierValue, pmm, selectedAID, systemCode, balanceText, balanceDetail
        case realSerialNumber, enhancedFeliCaDecoded, resultFields, scannedAt, color, design, faceImageFileName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        cardFamily = try container.decode(String.self, forKey: .cardFamily)
        markerSymbolName = try container.decodeIfPresent(String.self, forKey: .markerSymbolName)
        markerColor = try container.decodeIfPresent(SavedCardColor.self, forKey: .markerColor) ?? SavedCardColor(red: 1, green: 1, blue: 1)
        markerOuterColor = try container.decodeIfPresent(SavedCardColor.self, forKey: .markerOuterColor) ?? SavedCardColor(red: 0.18, green: 0.22, blue: 0.32)
        markerShape = try container.decodeIfPresent(SavedCardMarkerShape.self, forKey: .markerShape) ?? .circle
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        customDisplaySerialNumber = try container.decodeIfPresent(String.self, forKey: .customDisplaySerialNumber)
        hideTitleOnImage = try container.decodeIfPresent(Bool.self, forKey: .hideTitleOnImage) ?? false
        hideSerialNumber = try container.decodeIfPresent(Bool.self, forKey: .hideSerialNumber) ?? false
        imageFaceEnhancer = try container.decodeIfPresent(ImageFaceEnhancer.self, forKey: .imageFaceEnhancer) ?? .mask
        autoImageTextColors = try container.decodeIfPresent(Bool.self, forKey: .autoImageTextColors) ?? true
        autoTitleTextColor = try container.decodeIfPresent(SavedCardColor.self, forKey: .autoTitleTextColor)
        autoBalanceTextColor = try container.decodeIfPresent(SavedCardColor.self, forKey: .autoBalanceTextColor)
        titleTextColorOverride = try container.decodeIfPresent(SavedCardColor.self, forKey: .titleTextColorOverride)
        balanceTextColorOverride = try container.decodeIfPresent(SavedCardColor.self, forKey: .balanceTextColorOverride)
        technology = try container.decode(String.self, forKey: .technology)
        identifierLabel = try container.decode(String.self, forKey: .identifierLabel)
        identifierValue = try container.decode(String.self, forKey: .identifierValue)
        rawIdentifierValue = try container.decodeIfPresent(String.self, forKey: .rawIdentifierValue) ?? identifierValue
        pmm = try container.decodeIfPresent(String.self, forKey: .pmm)
        selectedAID = try container.decodeIfPresent(String.self, forKey: .selectedAID)
        systemCode = try container.decodeIfPresent(String.self, forKey: .systemCode)
        balanceText = try container.decodeIfPresent(String.self, forKey: .balanceText)
        balanceDetail = try container.decodeIfPresent(String.self, forKey: .balanceDetail)
        realSerialNumber = try container.decodeIfPresent(String.self, forKey: .realSerialNumber)
        enhancedFeliCaDecoded = try container.decodeIfPresent(Bool.self, forKey: .enhancedFeliCaDecoded) ?? false
        resultFields = try container.decode([SavedCardField].self, forKey: .resultFields)
        scannedAt = try container.decode(Date.self, forKey: .scannedAt)
        color = try container.decode(SavedCardColor.self, forKey: .color)
        design = try container.decodeIfPresent(SavedCardDesign.self, forKey: .design) ?? .classic
        faceImageFileName = try container.decodeIfPresent(String.self, forKey: .faceImageFileName)
    }
}

struct SavedFaceAsset: Identifiable, Hashable {
    let fileName: String
    var id: String { fileName }
}

// MARK: - Store (Restored)

@MainActor
final class CardWalletStore: ObservableObject {
    @Published private(set) var cards: [SavedCardRecord] = []
    @Published var enhancedFeliCaDecodingEnabled: Bool {
        didSet { UserDefaults.standard.set(enhancedFeliCaDecodingEnabled, forKey: "enhanced_felica_decoding_enabled") }
    }
    private let userDefaultsKey = "saved_transit_cards"

    init() {
        self.enhancedFeliCaDecodingEnabled = UserDefaults.standard.bool(forKey: "enhanced_felica_decoding_enabled")
        load()
    }

    func upsert(snapshot: TransitCardSnapshot) {
        let id = snapshot.storageIdentifier
        let existing = cards.first(where: { $0.id == id })
        let record = SavedCardRecord(
            id: id,
            cardFamily: snapshot.cardFamily,
            markerSymbolName: existing?.markerSymbolName,
            markerColor: existing?.markerColor ?? SavedCardColor(red: 1, green: 1, blue: 1),
            markerOuterColor: existing?.markerOuterColor ?? SavedCardColor(red: 0.18, green: 0.22, blue: 0.32),
            markerShape: existing?.markerShape ?? .circle,
            customTitle: existing?.customTitle,
            customDisplaySerialNumber: existing?.customDisplaySerialNumber,
            hideTitleOnImage: existing?.hideTitleOnImage ?? false,
            hideSerialNumber: existing?.hideSerialNumber ?? false,
            imageFaceEnhancer: existing?.imageFaceEnhancer ?? .mask,
            autoImageTextColors: existing?.autoImageTextColors ?? true,
            autoTitleTextColor: existing?.autoTitleTextColor,
            autoBalanceTextColor: existing?.autoBalanceTextColor,
            titleTextColorOverride: existing?.titleTextColorOverride,
            balanceTextColorOverride: existing?.balanceTextColorOverride,
            technology: snapshot.technology,
            identifierLabel: snapshot.identifierLabel,
            rawIdentifierValue: snapshot.rawIdentifierValue,
            identifierValue: snapshot.identifierValue,
            pmm: snapshot.pmm,
            selectedAID: snapshot.selectedAID,
            systemCode: snapshot.systemCode,
            balanceText: snapshot.balanceText,
            balanceDetail: snapshot.balanceDetail,
            realSerialNumber: snapshot.realSerialNumber ?? existing?.realSerialNumber,
            enhancedFeliCaDecoded: (snapshot.realSerialNumber != nil) || (existing?.enhancedFeliCaDecoded ?? false),
            resultFields: snapshot.resultFields.map(SavedCardField.init),
            scannedAt: snapshot.scannedAt,
            color: existing?.color ?? SavedCardColor(red: 0.3, green: 0.34, blue: 0.42),
            design: existing?.design ?? .classic,
            faceImageFileName: existing?.faceImageFileName
        )
        if let idx = cards.firstIndex(where: { $0.id == id }) { cards[idx] = record } else { cards.insert(record, at: 0) }
        save()
    }

    func save() {
        if let data = try? JSONEncoder().encode(cards) { UserDefaults.standard.set(data, forKey: userDefaultsKey) }
    }

    func load() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let list = try? JSONDecoder().decode([SavedCardRecord].self, from: data) { cards = list }
    }

    func delete(at offsets: IndexSet) { cards.remove(atOffsets: offsets); save() }
    func setCustomTitle(_ title: String?, for id: String) {
        if let idx = cards.firstIndex(where: { $0.id == id }) { cards[idx].customTitle = title; save() }
    }
    func backupToiCloud() {
        if let data = try? JSONEncoder().encode(cards) {
            NSUbiquitousKeyValueStore.default.set(data, forKey: "icloud_card_backup")
            NSUbiquitousKeyValueStore.default.synchronize()
        }
    }
    func restoreFromiCloud() {
        NSUbiquitousKeyValueStore.default.synchronize()
        if let data = NSUbiquitousKeyValueStore.default.data(forKey: "icloud_card_backup") {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
            load()
        }
    }
    func faceAssets() -> [SavedFaceAsset] { [] } // Simplified placeholder
    func loadFaceImage(fileName: String) -> UIImage? { nil }
    func deleteFaceAsset(_ fileName: String) {}
    func isFaceAssetUsed(_ fileName: String) -> Bool { false }
}
