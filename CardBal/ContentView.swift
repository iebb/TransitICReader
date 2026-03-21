import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit

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
    }
}

private struct ScanHomeView: View {
    @ObservedObject var reader: NFCTransitReader
    @ObservedObject var cardStore: CardWalletStore
    @State private var didAutoStartScan = false
    @State private var existingScannedCardID: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Transit IC Card Reader", systemImage: "wave.3.right.circle.fill")
                            .font(.title3.weight(.semibold))
                            .symbolRenderingMode(.hierarchical)

                        Text("Scan physical transit cards such as Suica, ICOCA, Octopus, T-money, and EZL/Cashbee. The app shows parsed balance data and the raw NFC payloads used to derive it.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }

                Section("Result") {
                    if let snapshot = reader.latestSnapshot {
                        KeyValueRow(title: "Card Family", value: snapshot.cardFamily)
                        ForEach(primaryResultFields(for: snapshot)) { field in
                            KeyValueRow(title: field.title, value: field.value)
                        }
                        if let balanceText = snapshot.balanceText {
                            KeyValueRow(title: "Balance", value: balanceText)
                        }
                        KeyValueRow(title: "Scanned", value: snapshot.scannedAt.formatted(date: .abbreviated, time: .standard))
                    } else {
                        Text("No card scanned yet.")
                            .foregroundStyle(.secondary)
                    }
                }

                if let snapshot = reader.latestSnapshot,
                   existingScannedCardID == snapshot.storageIdentifier,
                   let savedCard = cardStore.card(withID: snapshot.storageIdentifier) {
                    Section("Saved Card") {
                        WalletCardView(
                            card: savedCard,
                            isExpanded: true,
                            cardHeight: (UIScreen.main.bounds.width - 32) / (85.6 / 53.98),
                            visiblePartHeight: (UIScreen.main.bounds.width - 32) / (85.6 / 53.98),
                            onVisibleTap: {},
                            showDetails: {}
                        )
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                }

                if let snapshot = reader.latestSnapshot,
                   let balanceDetail = snapshot.balanceDetail {
                    Section(snapshot.balanceText == nil ? "Explanation" : "Balance Explanation") {
                        Text(balanceDetail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 2)
                    }
                }

                if let snapshot = reader.latestSnapshot,
                   snapshot.cardFamily == "Lignes d'Azur card",
                   !niceTicketFields(from: snapshot).isEmpty {
                    Section("Tickets") {
                        NiceTicketSummaryCard(snapshot: snapshot)
                        ForEach(niceTicketFields(from: snapshot)) { field in
                            KeyValueRow(title: field.title, value: field.value)
                        }
                    }
                }

                if let snapshot = reader.latestSnapshot {
                    Section("Tech") {
                        KeyValueRow(title: "Technology", value: snapshot.technology)
                        KeyValueRow(title: snapshot.identifierLabel, value: snapshot.identifierValue)
                        if let systemCode = snapshot.systemCode {
                            KeyValueRow(title: "System Code", value: systemCode)
                        }
                        if let selectedAID = snapshot.selectedAID {
                            KeyValueRow(title: "AID", value: selectedAID)
                        }
                    }
                }

                if let snapshot = reader.latestSnapshot, !snapshot.rawSections.isEmpty {
                    Section("Raw Data") {
                        ForEach(sortedRawSections(snapshot.rawSections)) { section in
                            DisclosureGroup(section.title) {
                                ForEach(section.fields) { field in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(field.title)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(field.value)
                                            .font(.system(.footnote, design: .monospaced))
                                            .textSelection(.enabled)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                }

                Section("Status") {
                    Label(reader.statusMessage, systemImage: reader.statusSymbol)
                        .foregroundStyle(reader.statusColor)
                }

                Section("Notes") {
                    Text("This app reads physical NFC cards only. It cannot inspect transit cards stored inside Apple Wallet on the same iPhone.")
                    Text("Supported balance decoders currently include Japanese transit FeliCa cards, Octopus, and KS X 6924 cards such as T-money and EZL/Cashbee.")
                    Text("The raw-data section exposes the payloads and parsing math so you can verify the decoded balance against the actual NFC response.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("IC Reader")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        reader.beginScanning()
                    } label: {
                        Label(
                            reader.isScanning ? "Scanning" : "Scan Card",
                            systemImage: reader.isScanning ? "dot.radiowaves.right" : "wave.3.right"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .disabled(reader.isScanning)
                    .accessibilityLabel(reader.isScanning ? "Scanning" : "Scan Card")
                }
            }
            .onChange(of: reader.latestSnapshot?.id) {
                if let snapshot = reader.latestSnapshot {
                    existingScannedCardID = cardStore.card(withID: snapshot.storageIdentifier) == nil ? nil : snapshot.storageIdentifier
                    cardStore.upsert(snapshot: snapshot)
                }
            }
            .onAppear {
#if DEBUG
                guard !didAutoStartScan else { return }
                didAutoStartScan = true
                reader.beginScanning()
#endif
            }
        }
    }
}

private func primaryResultFields(for snapshot: TransitCardSnapshot) -> [ResultField] {
    guard snapshot.cardFamily == "Lignes d'Azur card" else {
        return snapshot.resultFields
    }

    let ticketTitles = Set(niceTicketFieldTitles)
    return snapshot.resultFields.filter { !ticketTitles.contains($0.title) }
}

private func niceTicketFields(from snapshot: TransitCardSnapshot) -> [ResultField] {
    guard snapshot.cardFamily == "Lignes d'Azur card" else { return [] }
    let ticketTitles = Set(niceTicketFieldTitles)
    return snapshot.resultFields.filter { ticketTitles.contains($0.title) }
}

private let niceTicketFieldTitles = [
    "Loaded Tickets",
    "Ticket",
    "Ticket Family",
    "Contract Serial Number",
    "Product Code",
    "Sold At",
    "Remaining Trips",
    "Valid Until",
    "Last Ticket Event",
    "Route",
    "Ticket Status"
]

private func sortedRawSections(_ sections: [RawDataSection]) -> [RawDataSection] {
    sections.sorted { lhs, rhs in
        let leftKey = rawSectionSortKey(lhs.title)
        let rightKey = rawSectionSortKey(rhs.title)
        if leftKey.group != rightKey.group {
            return leftKey.group < rightKey.group
        }
        return leftKey.title.localizedStandardCompare(rightKey.title) == .orderedAscending
    }
}

private func rawSectionSortKey(_ title: String) -> (group: Int, title: String) {
    if title == "Tag" { return (0, title) }
    if title == "Select Application APDU" { return (1, title) }
    if title == "Secure Calypso Session" { return (2, title) }
    if title.hasPrefix("GET DATA") { return (3, title) }
    if title.hasPrefix("Environment Record")
        || title.hasPrefix("Best Contracts")
        || title.hasPrefix("Best Contract Decode")
        || title.hasPrefix("Contract Summary Record")
        || title.hasPrefix("Ticket Detail Record")
        || title.hasPrefix("Event Record")
        || title.hasPrefix("Supplemental Record")
        || title.hasPrefix("Unknown Record") {
        return (4, title)
    }
    if title == "Ticket Decode" { return (5, title) }
    if title == "Event Decode" { return (6, title) }
    if title == "Card Validity Decode" { return (7, title) }
    if title == "Card Number Decode" { return (8, title) }
    return (9, title)
}

private struct NiceTicketSummaryCard: View {
    let snapshot: TransitCardSnapshot

    var body: some View {
        let ticket = value(for: "Ticket")
        let remainingTrips = value(for: "Remaining Trips")
        let validUntil = value(for: "Card Valid Until") ?? value(for: "Valid Until")

        if ticket != nil || remainingTrips != nil || validUntil != nil {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ticket")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let ticket {
                    Text(ticket)
                        .font(.title3.weight(.semibold))
                }

                HStack(spacing: 12) {
                    if let remainingTrips {
                        ticketMetric(title: "Remaining", value: remainingTrips)
                    }
                    if let validUntil {
                        ticketMetric(title: "Valid Until", value: validUntil)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func value(for title: String) -> String? {
        snapshot.resultFields.first(where: { $0.title == title })?.value
    }

    @ViewBuilder
    private func ticketMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct KeyValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

struct SavedCardField: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let value: String

    init(title: String, value: String) {
        self.id = "\(title)|\(value)"
        self.title = title
        self.value = value
    }

    init(_ field: ResultField) {
        self.init(title: field.title, value: field.value)
    }
}

struct SavedCardColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    var darkerColor: Color {
        Color(
            red: max(red * 0.58, 0.04),
            green: max(green * 0.58, 0.04),
            blue: max(blue * 0.58, 0.04)
        )
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(color: Color) {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            self.red = Double(red)
            self.green = Double(green)
            self.blue = Double(blue)
        } else {
            self.red = 0.19
            self.green = 0.38
            self.blue = 0.73
        }
    }

    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: 1)
    }

    var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }

        let r = channel(red)
        let g = channel(green)
        let b = channel(blue)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    static let white = SavedCardColor(red: 1, green: 1, blue: 1)
    static let black = SavedCardColor(red: 0, green: 0, blue: 0)
}

enum SavedCardDesign: String, Codable, CaseIterable, Identifiable {
    case classic
    case sunrise
    case metro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic:
            return "Classic"
        case .sunrise:
            return "Sunrise"
        case .metro:
            return "Metro"
        }
    }
}

enum ImageFaceEnhancer: String, Codable, CaseIterable, Identifiable {
    case mask
    case border
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mask:
            return "Mask"
        case .border:
            return "Text Border/Shadow"
        case .none:
            return "None"
        }
    }
}

private struct SavedCardMarker: Identifiable, Hashable {
    let symbolName: String

    var id: String { symbolName }

    var title: String {
        switch symbolName {
        case "none":
            return "None"
        case "star.fill":
            return "Star"
        case "heart.fill":
            return "Heart"
        case "flag.fill":
            return "Flag"
        case "bolt.fill":
            return "Bolt"
        case "bookmark.fill":
            return "Bookmark"
        case "tram.fill":
            return "Tram"
        case "bus.fill":
            return "Bus"
        case "ferry.fill":
            return "Ferry"
        case "leaf.fill":
            return "Leaf"
        default:
            return symbolName
        }
    }

    var effectiveSystemName: String? {
        symbolName == "none" ? nil : symbolName
    }
}

private let savedCardMarkers: [SavedCardMarker] = [
    SavedCardMarker(symbolName: "none"),
    SavedCardMarker(symbolName: "star.fill"),
    SavedCardMarker(symbolName: "heart.fill"),
    SavedCardMarker(symbolName: "flag.fill"),
    SavedCardMarker(symbolName: "bolt.fill"),
    SavedCardMarker(symbolName: "bookmark.fill"),
    SavedCardMarker(symbolName: "tram.fill"),
    SavedCardMarker(symbolName: "bus.fill"),
    SavedCardMarker(symbolName: "ferry.fill"),
    SavedCardMarker(symbolName: "leaf.fill")
]

enum SavedCardMarkerShape: String, Codable, CaseIterable, Identifiable {
    case circle
    case square
    case triangle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .circle:
            return "Circle"
        case .square:
            return "Square"
        case .triangle:
            return "Triangle"
        }
    }
}

private enum SavedCardMarkerToken: String, CaseIterable, Identifiable {
    case none = "none"
    case star = "sf:star.fill"
    case heart = "sf:heart.fill"
    case flag = "sf:flag.fill"
    case bolt = "sf:bolt.fill"
    case bookmark = "sf:bookmark.fill"
    case tram = "sf:tram.fill"
    case bus = "sf:bus.fill"
    case ferry = "sf:ferry.fill"
    case train = "sf:train.side.front.car"
    case car = "sf:car.fill"
    case airplane = "sf:airplane"
    case bicycle = "sf:bicycle"
    case flame = "sf:flame.fill"
    case gift = "sf:gift.fill"
    case moon = "sf:moon.fill"
    case sun = "sf:sun.max.fill"
    case paw = "sf:pawprint.fill"
    case leaf = "sf:leaf.fill"
    case location = "sf:mappin.circle.fill"
    case music = "sf:music.note"
    case bag = "sf:bag.fill"
    case house = "sf:house.fill"
    case work = "sf:briefcase.fill"
    case coffee = "sf:cup.and.saucer.fill"
    case food = "sf:fork.knife"
    case camera = "sf:camera.fill"
    case ticket = "sf:ticket.fill"
    case shield = "sf:shield.fill"
    case a = "txt:A"
    case b = "txt:B"
    case c = "txt:C"
    case d = "txt:D"
    case e = "txt:E"
    case f = "txt:F"
    case g = "txt:G"
    case h = "txt:H"
    case i = "txt:I"
    case j = "txt:J"
    case k = "txt:K"
    case l = "txt:L"
    case m = "txt:M"
    case n = "txt:N"
    case o = "txt:O"
    case p = "txt:P"
    case q = "txt:Q"
    case r = "txt:R"
    case s = "txt:S"
    case t = "txt:T"
    case u = "txt:U"
    case v = "txt:V"
    case w = "txt:W"
    case x = "txt:X"
    case y = "txt:Y"
    case z = "txt:Z"
    case one = "txt:1"
    case two = "txt:2"
    case three = "txt:3"
    case four = "txt:4"
    case five = "txt:5"
    case six = "txt:6"
    case seven = "txt:7"
    case eight = "txt:8"
    case nine = "txt:9"
    case zero = "txt:0"

    var id: String { rawValue }

    var token: String { rawValue }
}

struct SavedCardRecord: Codable, Hashable, Identifiable {
    let id: String
    var cardFamily: String
    var markerSymbolName: String?
    var markerColor: SavedCardColor
    var markerOuterColor: SavedCardColor
    var markerShape: SavedCardMarkerShape
    var customTitle: String?
    var customDisplaySerialNumber: String?
    var hideTitleOnImage: Bool
    var hideSerialNumber: Bool
    var imageFaceEnhancer: ImageFaceEnhancer
    var autoImageTextColors: Bool
    var autoTitleTextColor: SavedCardColor?
    var autoBalanceTextColor: SavedCardColor?
    var titleTextColorOverride: SavedCardColor?
    var balanceTextColorOverride: SavedCardColor?
    var technology: String
    var identifierLabel: String
    var rawIdentifierValue: String
    var identifierValue: String
    var selectedAID: String?
    var systemCode: String?
    var balanceText: String?
    var balanceDetail: String?
    var resultFields: [SavedCardField]
    var scannedAt: Date
    var color: SavedCardColor
    var design: SavedCardDesign
    var faceImageFileName: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case cardFamily
        case markerSymbolName
        case markerColor
        case markerOuterColor
        case markerShape
        case customTitle
        case customDisplaySerialNumber
        case hideTitleOnImage
        case hideSerialNumber
        case imageFaceEnhancer
        case autoImageTextColors
        case autoTitleTextColor
        case autoBalanceTextColor
        case titleTextColorOverride
        case balanceTextColorOverride
        case technology
        case identifierLabel
        case rawIdentifierValue
        case identifierValue
        case selectedAID
        case systemCode
        case balanceText
        case balanceDetail
        case resultFields
        case scannedAt
        case color
        case design
        case faceImageFileName
    }

    init(
        id: String,
        cardFamily: String,
        markerSymbolName: String?,
        markerColor: SavedCardColor,
        markerOuterColor: SavedCardColor,
        markerShape: SavedCardMarkerShape,
        customTitle: String?,
        customDisplaySerialNumber: String?,
        hideTitleOnImage: Bool,
        hideSerialNumber: Bool,
        imageFaceEnhancer: ImageFaceEnhancer,
        autoImageTextColors: Bool,
        autoTitleTextColor: SavedCardColor?,
        autoBalanceTextColor: SavedCardColor?,
        titleTextColorOverride: SavedCardColor?,
        balanceTextColorOverride: SavedCardColor?,
        technology: String,
        identifierLabel: String,
        rawIdentifierValue: String,
        identifierValue: String,
        selectedAID: String?,
        systemCode: String?,
        balanceText: String?,
        balanceDetail: String?,
        resultFields: [SavedCardField],
        scannedAt: Date,
        color: SavedCardColor,
        design: SavedCardDesign,
        faceImageFileName: String?
    ) {
        self.id = id
        self.cardFamily = cardFamily
        self.markerSymbolName = markerSymbolName
        self.markerColor = markerColor
        self.markerOuterColor = markerOuterColor
        self.markerShape = markerShape
        self.customTitle = customTitle
        self.customDisplaySerialNumber = customDisplaySerialNumber
        self.hideTitleOnImage = hideTitleOnImage
        self.hideSerialNumber = hideSerialNumber
        self.imageFaceEnhancer = imageFaceEnhancer
        self.autoImageTextColors = autoImageTextColors
        self.autoTitleTextColor = autoTitleTextColor
        self.autoBalanceTextColor = autoBalanceTextColor
        self.titleTextColorOverride = titleTextColorOverride
        self.balanceTextColorOverride = balanceTextColorOverride
        self.technology = technology
        self.identifierLabel = identifierLabel
        self.rawIdentifierValue = rawIdentifierValue
        self.identifierValue = identifierValue
        self.selectedAID = selectedAID
        self.systemCode = systemCode
        self.balanceText = balanceText
        self.balanceDetail = balanceDetail
        self.resultFields = resultFields
        self.scannedAt = scannedAt
        self.color = color
        self.design = design
        self.faceImageFileName = faceImageFileName
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
        selectedAID = try container.decodeIfPresent(String.self, forKey: .selectedAID)
        systemCode = try container.decodeIfPresent(String.self, forKey: .systemCode)
        balanceText = try container.decodeIfPresent(String.self, forKey: .balanceText)
        balanceDetail = try container.decodeIfPresent(String.self, forKey: .balanceDetail)
        resultFields = try container.decode([SavedCardField].self, forKey: .resultFields)
        scannedAt = try container.decode(Date.self, forKey: .scannedAt)
        color = try container.decode(SavedCardColor.self, forKey: .color)
        design = try container.decodeIfPresent(SavedCardDesign.self, forKey: .design) ?? .classic
        faceImageFileName = try container.decodeIfPresent(String.self, forKey: .faceImageFileName)
    }

    var brand: String {
        cardFamily
    }

    var markerSystemName: String? {
        guard let markerSymbolName, markerSymbolName.hasPrefix("sf:") else { return nil }
        return String(markerSymbolName.dropFirst(3))
    }

    var markerText: String? {
        guard let markerSymbolName, markerSymbolName.hasPrefix("txt:") else { return nil }
        return String(markerSymbolName.dropFirst(4))
    }
    
    var displayTitle: String {
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? cardFamily : trimmed
    }

    var visibleBalance: String {
        if let balanceText, !balanceText.isEmpty {
            return balanceText
        }
        if let remainingTrips = fieldValue("Remaining Trips") {
            return "\(remainingTrips) trips"
        }
        return "No balance"
    }

    var cardNumber: String? {
        fieldValue("Card Number")
    }

    var displayedSerialNumber: String {
        let trimmed = customDisplaySerialNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
        return cardNumber ?? identifierValue
    }

    func fieldValue(_ title: String) -> String? {
        resultFields.first(where: { $0.title == title })?.value
    }
}

private struct CardDetailRoute: Identifiable {
    let id: String
}

struct SavedFaceAsset: Identifiable, Hashable {
    let fileName: String

    var id: String { fileName }
}

@MainActor
final class CardWalletStore: ObservableObject {
    @Published private(set) var cards: [SavedCardRecord] = []

    private let userDefaultsKey = "saved_transit_cards_v1"

    init() {
        load()
        deduplicateFaceAssets()
    }

    func upsert(snapshot: TransitCardSnapshot) {
        let id = snapshot.storageIdentifier
        let existingCard = cards.first(where: { $0.id == id })
        let existingColor = existingCard?.color ?? defaultColor(for: snapshot.cardFamily)
        let existingDesign = existingCard?.design ?? .classic
        let existingFaceImageFileName = existingCard?.faceImageFileName
        let existingCustomTitle = existingCard?.customTitle
        let record = SavedCardRecord(
            id: id,
            cardFamily: snapshot.cardFamily,
            markerSymbolName: existingCard?.markerSymbolName,
            markerColor: existingCard?.markerColor ?? SavedCardColor(red: 1, green: 1, blue: 1),
            markerOuterColor: existingCard?.markerOuterColor ?? SavedCardColor(red: 0.18, green: 0.22, blue: 0.32),
            markerShape: existingCard?.markerShape ?? .circle,
            customTitle: existingCustomTitle,
            customDisplaySerialNumber: existingCard?.customDisplaySerialNumber,
            hideTitleOnImage: existingCard?.hideTitleOnImage ?? false,
            hideSerialNumber: existingCard?.hideSerialNumber ?? false,
            imageFaceEnhancer: existingCard?.imageFaceEnhancer ?? .mask,
            autoImageTextColors: existingCard?.autoImageTextColors ?? true,
            autoTitleTextColor: existingCard?.autoTitleTextColor,
            autoBalanceTextColor: existingCard?.autoBalanceTextColor,
            titleTextColorOverride: existingCard?.titleTextColorOverride,
            balanceTextColorOverride: existingCard?.balanceTextColorOverride,
            technology: snapshot.technology,
            identifierLabel: snapshot.identifierLabel,
            rawIdentifierValue: snapshot.rawIdentifierValue,
            identifierValue: snapshot.identifierValue,
            selectedAID: snapshot.selectedAID,
            systemCode: snapshot.systemCode,
            balanceText: snapshot.balanceText,
            balanceDetail: snapshot.balanceDetail,
            resultFields: snapshot.resultFields.map(SavedCardField.init),
            scannedAt: snapshot.scannedAt,
            color: existingColor,
            design: existingDesign,
            faceImageFileName: existingFaceImageFileName
        )

        if let index = cards.firstIndex(where: { $0.id == id }) {
            cards[index] = record
        } else {
            cards.insert(record, at: 0)
        }
        save()
    }

    func setMarkerSymbolName(_ symbolName: String?, for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = symbolName?.trimmingCharacters(in: .whitespacesAndNewlines)
        cards[index].markerSymbolName = (trimmed?.isEmpty == false) ? trimmed : nil
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
    
    func setCustomTitle(_ title: String, for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        cards[index].customTitle = trimmed.isEmpty ? nil : trimmed
        save()
    }

    func setCustomDisplaySerialNumber(_ serialNumber: String, for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        cards[index].customDisplaySerialNumber = trimmed.isEmpty ? nil : trimmed
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

    func setImageFaceEnhancer(_ enhancer: ImageFaceEnhancer, for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].imageFaceEnhancer = enhancer
        save()
    }

    func setAutoImageTextColors(_ enabled: Bool, for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].autoImageTextColors = enabled
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
        } catch {
            return
        }
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

    func isFaceAssetUsed(_ fileName: String) -> Bool {
        cards.contains { $0.faceImageFileName == fileName }
    }

    func deleteFaceAsset(_ fileName: String) {
        guard !isFaceAssetUsed(fileName) else { return }
        do {
            try FileManager.default.removeItem(at: cardFaceFileURL(fileName: fileName))
        } catch {
            return
        }
        save()
    }

    func deleteUnusedFaceAssets() {
        let used = Set(cards.compactMap(\.faceImageFileName))
        for asset in faceAssets() where !used.contains(asset.fileName) {
            try? FileManager.default.removeItem(at: cardFaceFileURL(fileName: asset.fileName))
        }
        save()
    }

    func applyAppearance(from sourceID: String, to destinationID: String) {
        guard let sourceIndex = cards.firstIndex(where: { $0.id == sourceID }),
              let destinationIndex = cards.firstIndex(where: { $0.id == destinationID }) else {
            return
        }

        cards[destinationIndex].color = cards[sourceIndex].color
        cards[destinationIndex].design = cards[sourceIndex].design
        cards[destinationIndex].imageFaceEnhancer = cards[sourceIndex].imageFaceEnhancer

        cards[destinationIndex].faceImageFileName = cards[sourceIndex].faceImageFileName
        cards[destinationIndex].autoImageTextColors = cards[sourceIndex].autoImageTextColors
        cards[destinationIndex].autoTitleTextColor = cards[sourceIndex].autoTitleTextColor
        cards[destinationIndex].autoBalanceTextColor = cards[sourceIndex].autoBalanceTextColor
        cards[destinationIndex].titleTextColorOverride = cards[sourceIndex].titleTextColorOverride
        cards[destinationIndex].balanceTextColorOverride = cards[sourceIndex].balanceTextColorOverride
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
        return UIImage(contentsOfFile: cardFaceFileURL(fileName: fileName).path)
    }

    func faceAssets() -> [SavedFaceAsset] {
        let directory = cardFaceDirectoryURL
        guard let fileNames = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }

        return deduplicatedFaceFileNames(fileNames)
            .filter { $0.lowercased().hasSuffix(".jpg") || $0.lowercased().hasSuffix(".jpeg") || $0.lowercased().hasSuffix(".png") }
            .sorted()
            .map { SavedFaceAsset(fileName: $0) }
    }

    func card(withID id: String) -> SavedCardRecord? {
        cards.first(where: { $0.id == id })
    }

    func moveCard(from sourceID: String, to destinationID: String) {
        guard sourceID != destinationID,
              let sourceIndex = cards.firstIndex(where: { $0.id == sourceID }),
              let destinationIndex = cards.firstIndex(where: { $0.id == destinationID }) else {
            return
        }

        let movedCard = cards.remove(at: sourceIndex)
        let targetIndex = sourceIndex < destinationIndex ? destinationIndex : destinationIndex
        cards.insert(movedCard, at: targetIndex)
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
        moveCard(from: id, toIndex: 0)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(cards) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let cards = try? JSONDecoder().decode([SavedCardRecord].self, from: data) else {
            return
        }
        self.cards = cards
    }

    private func ensureCardFaceDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: cardFaceDirectoryURL,
            withIntermediateDirectories: true
        )
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
        case "Transit IC":
            return SavedCardColor(red: 0.11, green: 0.53, blue: 0.76)
        case "Octopus":
            return SavedCardColor(red: 0.80, green: 0.16, blue: 0.16)
        case "T-money":
            return SavedCardColor(red: 0.12, green: 0.61, blue: 0.49)
        case "EZL / Cashbee":
            return SavedCardColor(red: 0.94, green: 0.58, blue: 0.18)
        case "Lignes d'Azur card":
            return SavedCardColor(red: 0.05, green: 0.36, blue: 0.73)
        default:
            return SavedCardColor(red: 0.24, green: 0.27, blue: 0.35)
        }
    }

    private func applyAutoImageTextColors(to card: inout SavedCardRecord, image: UIImage) {
        card.autoTitleTextColor = bestReadableTextColor(for: image, region: CGRect(x: 0.04, y: 0.04, width: 0.42, height: 0.28))
        card.autoBalanceTextColor = bestReadableTextColor(for: image, region: CGRect(x: 0.56, y: 0.04, width: 0.4, height: 0.28))
    }

    private func bestReadableTextColor(for image: UIImage, region: CGRect) -> SavedCardColor {
        guard let sampledPixels = sampledColors(in: image, region: region) else {
            return .white
        }

        let candidates = candidateTextColors(from: sampledPixels)

        return candidates.max { lhs, rhs in
            contrastScore(for: lhs, against: sampledPixels) < contrastScore(for: rhs, against: sampledPixels)
        } ?? .white
    }

    private func sampledColors(in image: UIImage, region: CGRect) -> [SavedCardColor]? {
        guard let cgImage = image.cgImage else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let cropRect = CGRect(
            x: max(0, min(CGFloat(width - 1), region.origin.x * CGFloat(width))),
            y: max(0, min(CGFloat(height - 1), region.origin.y * CGFloat(height))),
            width: max(1, min(CGFloat(width), region.width * CGFloat(width))),
            height: max(1, min(CGFloat(height), region.height * CGFloat(height)))
        ).integral

        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }

        let ciImage = CIImage(cgImage: cropped)
        let targetWidth = 24
        let targetHeight = 16
        let scaleX = CGFloat(targetWidth) / ciImage.extent.width
        let scaleY = CGFloat(targetHeight) / ciImage.extent.height
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        var bitmap = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
        let ciContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        ciContext.render(
            scaledImage,
            toBitmap: &bitmap,
            rowBytes: targetWidth * 4,
            bounds: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            format: .RGBA8,
            colorSpace: nil
        )

        var colors: [SavedCardColor] = []
        colors.reserveCapacity(targetWidth * targetHeight)
        for index in stride(from: 0, to: bitmap.count, by: 4) {
            colors.append(
                SavedCardColor(
                    red: Double(bitmap[index]) / 255,
                    green: Double(bitmap[index + 1]) / 255,
                    blue: Double(bitmap[index + 2]) / 255
                )
            )
        }
        return colors
    }

    private func contrastRatio(text: SavedCardColor, background: SavedCardColor) -> Double {
        let l1 = text.relativeLuminance
        let l2 = background.relativeLuminance
        let light = max(l1, l2)
        let dark = min(l1, l2)
        return (light + 0.05) / (dark + 0.05)
    }

    private func contrastScore(for text: SavedCardColor, against backgrounds: [SavedCardColor]) -> Double {
        let contrasts = backgrounds.map { contrastRatio(text: text, background: $0) }
        let minimum = contrasts.min() ?? 0
        let average = contrasts.reduce(0, +) / Double(max(contrasts.count, 1))
        return minimum * 0.7 + average * 0.3
    }

    private func candidateTextColors(from backgrounds: [SavedCardColor]) -> [SavedCardColor] {
        let average = averageColor(from: backgrounds)
        let averageUIColor = average.uiColor
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        if !averageUIColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) {
            hue = 0.6
            saturation = 0.4
            brightness = 0.5
        }

        let complementaryHue = (hue + 0.5).truncatingRemainder(dividingBy: 1)
        let analogousHueA = (hue + 0.42).truncatingRemainder(dividingBy: 1)
        let analogousHueB = (hue + 0.58).truncatingRemainder(dividingBy: 1)

        let palette: [SavedCardColor] = [
            .white,
            .black,
            SavedCardColor(color: Color(uiColor: UIColor(hue: complementaryHue, saturation: max(0.22, saturation * 0.75), brightness: 0.98, alpha: 1))),
            SavedCardColor(color: Color(uiColor: UIColor(hue: complementaryHue, saturation: max(0.28, saturation * 0.92), brightness: 0.18, alpha: 1))),
            SavedCardColor(color: Color(uiColor: UIColor(hue: analogousHueA, saturation: 0.22, brightness: 0.96, alpha: 1))),
            SavedCardColor(color: Color(uiColor: UIColor(hue: analogousHueB, saturation: 0.24, brightness: 0.2, alpha: 1))),
            SavedCardColor(red: 0.95, green: 0.93, blue: 0.84),
            SavedCardColor(red: 0.12, green: 0.18, blue: 0.28)
        ]

        return deduplicatedColors(palette)
    }

    private func averageColor(from colors: [SavedCardColor]) -> SavedCardColor {
        guard !colors.isEmpty else { return .white }
        let count = Double(colors.count)
        return SavedCardColor(
            red: colors.map(\.red).reduce(0, +) / count,
            green: colors.map(\.green).reduce(0, +) / count,
            blue: colors.map(\.blue).reduce(0, +) / count
        )
    }

    private func deduplicatedColors(_ colors: [SavedCardColor]) -> [SavedCardColor] {
        var seen = Set<String>()
        return colors.filter { color in
            let key = "\(Int(color.red * 255))-\(Int(color.green * 255))-\(Int(color.blue * 255))"
            return seen.insert(key).inserted
        }
    }

    private func existingFaceAssetFileName(forJPEGData data: Data) -> String? {
        let targetHash = sha256Hex(for: data)
        for asset in faceAssets() {
            let fileURL = cardFaceFileURL(fileName: asset.fileName)
            guard let existingData = try? Data(contentsOf: fileURL) else { continue }
            if sha256Hex(for: existingData) == targetHash {
                return asset.fileName
            }
        }
        return nil
    }

    private func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func deduplicatedFaceFileNames(_ fileNames: [String]) -> [String] {
        var canonicalByHash: [String: String] = [:]
        var deduplicated: [String] = []

        for fileName in fileNames.sorted() {
            let fileURL = cardFaceFileURL(fileName: fileName)
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            let hash = sha256Hex(for: data)
            if canonicalByHash[hash] == nil {
                canonicalByHash[hash] = fileName
                deduplicated.append(fileName)
            }
        }

        return deduplicated
    }

    private func deduplicateFaceAssets() {
        let allFileNames = allFaceAssetFileNames()
        guard !allFileNames.isEmpty else { return }

        var canonicalByHash: [String: String] = [:]
        var duplicateMap: [String: String] = [:]

        for fileName in allFileNames.sorted() {
            let fileURL = cardFaceFileURL(fileName: fileName)
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            let hash = sha256Hex(for: data)
            if let canonical = canonicalByHash[hash] {
                duplicateMap[fileName] = canonical
            } else {
                canonicalByHash[hash] = fileName
            }
        }

        guard !duplicateMap.isEmpty else { return }

        for index in cards.indices {
            if let fileName = cards[index].faceImageFileName,
               let canonical = duplicateMap[fileName] {
                cards[index].faceImageFileName = canonical
            }
        }

        for duplicate in duplicateMap.keys {
            try? FileManager.default.removeItem(at: cardFaceFileURL(fileName: duplicate))
        }

        save()
    }

    private func allFaceAssetFileNames() -> [String] {
        let directory = cardFaceDirectoryURL
        guard let fileNames = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return fileNames.filter {
            $0.lowercased().hasSuffix(".jpg") || $0.lowercased().hasSuffix(".jpeg") || $0.lowercased().hasSuffix(".png")
        }
    }
}

struct CardsView: View {
    @ObservedObject var store: CardWalletStore
    @State private var draggedCardID: String?
    @State private var detailRoute: CardDetailRoute?
    @State private var previewCardID: String?

    private let stackedSpacing: CGFloat = 58
    private let expandedStackGap: CGFloat = 12
    private let cardAspectRatio: CGFloat = 85.6 / 53.98

    var body: some View {
        NavigationStack {
            Group {
                if store.cards.isEmpty {
                    ContentUnavailableView(
                        "No Cards Yet",
                        systemImage: "wallet.bifold",
                        description: Text("Scan a physical card once and it will appear here.")
                    )
                } else {
                    GeometryReader { proxy in
                        let cardWidth = max(proxy.size.width - 40, 1)
                        let cardHeight = cardWidth / cardAspectRatio

                        ScrollView {
                            ZStack(alignment: .top) {
                                ForEach(Array(store.cards.enumerated().reversed()), id: \.element.id) { index, card in
                                    WalletCardView(
                                        card: card,
                                        isExpanded: previewCardID == card.id,
                                        cardHeight: cardHeight,
                                        visiblePartHeight: visibleTapHeight(for: index, cardHeight: cardHeight),
                                        onVisibleTap: {
                                            if previewCardID == card.id {
                                                previewCardID = nil
                                            } else {
                                                store.bringToFront(card.id)
                                                previewCardID = card.id
                                            }
                                        },
                                        showDetails: { detailRoute = CardDetailRoute(id: card.id) }
                                    )
                                    .padding(.horizontal, 20)
                                    .offset(y: cardOffset(for: index, cardID: card.id, cardHeight: cardHeight))
                                    .zIndex(zIndex(for: index, cardID: card.id))
                                    .onDrag {
                                        previewCardID = nil
                                        draggedCardID = card.id
                                        return NSItemProvider(object: card.id as NSString)
                                    }
                                    .onDrop(
                                        of: [UTType.plainText],
                                        delegate: CardReorderDropDelegate(
                                            destinationID: card.id,
                                            store: store,
                                            draggedCardID: $draggedCardID
                                        )
                                    )
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: stackHeight(cardHeight: cardHeight), alignment: .top)
                            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: store.cards)
                            .animation(.spring(response: 0.22, dampingFraction: 0.9), value: draggedCardID)
                            .padding(.bottom, proxy.safeAreaInsets.bottom + 88)
                        }
                    }
                    .background(Color(uiColor: .systemGroupedBackground))
                }
            }
            .navigationTitle("Cards")
            .sheet(item: $detailRoute) { route in
                NavigationStack {
                    SavedCardDetailView(cardID: route.id, store: store)
                }
            }
        }
    }

    private func stackHeight(cardHeight: CGFloat) -> CGFloat {
        if previewCardID == nil {
            return CGFloat(max(store.cards.count - 1, 0)) * stackedSpacing + cardHeight
        }
        return cardHeight + expandedStackGap + CGFloat(max(store.cards.count - 1, 0)) * stackedSpacing
    }

    private func cardOffset(for index: Int, cardID: String, cardHeight: CGFloat) -> CGFloat {
        let baseOffset: CGFloat
        if previewCardID == nil {
            baseOffset = CGFloat(index) * stackedSpacing
        } else if index == 0 {
            baseOffset = 0
        } else {
            baseOffset = cardHeight + expandedStackGap + CGFloat(index - 1) * stackedSpacing
        }
        return baseOffset
    }

    private func zIndex(for index: Int, cardID: String) -> Double {
        if draggedCardID == cardID {
            return 1000
        }
        return Double(index)
    }

    private func visibleTapHeight(for index: Int, cardHeight: CGFloat) -> CGFloat {
        if previewCardID == nil {
            return index == 0 ? cardHeight : stackedSpacing
        }
        return index == 0 ? min(cardHeight * 0.3, 76) : stackedSpacing
    }

}

private struct WalletCardView: View {
    private let cardCornerRadius: CGFloat = 22
    let card: SavedCardRecord
    let isExpanded: Bool
    let cardHeight: CGFloat
    let visiblePartHeight: CGFloat
    let onVisibleTap: () -> Void
    let showDetails: () -> Void
    
    private var faceImage: UIImage? {
        card.faceImageFileName.flatMap(loadCardFaceImage)
    }
    
    private var isPhotoFace: Bool {
        faceImage != nil
    }

    private var shouldShowTitle: Bool {
        !(isPhotoFace && card.hideTitleOnImage)
    }

    private var shouldShowSerialNumber: Bool {
        !card.hideSerialNumber
    }
    
    private var titleTextColor: Color { .white }
    private var balanceTextColor: Color { .white }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .fill(cardBackground)

                if let faceImage {
                    Image(uiImage: faceImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                }

                if isPhotoFace && card.imageFaceEnhancer == .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.52), location: 0),
                            .init(color: .black.opacity(0.24), location: 0.18),
                            .init(color: .black.opacity(0.08), location: 0.34),
                            .init(color: .clear, location: 0.54)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                    .allowsHitTesting(false)
                }

                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)

                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                if card.markerSystemName != nil || card.markerText != nil {
                                    markerBadge
                                }
                                borderedCardText(
                                    shouldShowTitle ? card.displayTitle : "",
                                    font: .title3.weight(.semibold),
                                    foregroundColor: titleTextColor
                                )
                            }
                            if shouldShowSerialNumber {
                                borderedCardText(
                                    card.displayedSerialNumber,
                                    font: .caption.weight(.medium),
                                    foregroundColor: titleTextColor,
                                    lineLimit: 1,
                                    minimumScaleFactor: 0.75
                                )
                            }
                        }

                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            borderedCardText(
                                card.visibleBalance,
                                font: .system(size: 28, weight: .bold, design: .rounded),
                                foregroundColor: balanceTextColor,
                                minimumScaleFactor: 0.75
                            )
                        }
                    }

                    Spacer()

                    HStack(alignment: .bottom) {
                        if isExpanded {
                            VStack(alignment: .leading, spacing: 4) {
                                borderedCardText(
                                    "Last Scanned",
                                    font: .caption,
                                    foregroundColor: titleTextColor.opacity(0.86)
                                )
                                borderedCardText(
                                    card.scannedAt.formatted(date: .abbreviated, time: .omitted),
                                    font: .subheadline.weight(.medium),
                                    foregroundColor: titleTextColor
                                )
                            }
                        }

                        Spacer()

                        Button(action: showDetails) {
                            Image(systemName: "chevron.right")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(titleTextColor)
                                .frame(width: 40, height: 40)
                                .background((isPhotoFace ? Color.black.opacity(0.22) : Color.white.opacity(0.14)), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show Details")
                    }
                }
                .padding(.top, 11)
                .padding(.leading, 18)
                .padding(.trailing, 18)
                .padding(.bottom, 18)

                Rectangle()
                    .fill(Color.clear)
                    .frame(height: visiblePartHeight)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onVisibleTap)
            }
        }
        .frame(height: cardHeight)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }

    @ViewBuilder
    private var markerBadge: some View {
        ZStack {
            markerBackground(color: card.markerOuterColor.color, size: 28)
            markerBackground(color: card.markerColor.color, size: 22)

            if let markerSystemName = card.markerSystemName {
                Image(systemName: markerSystemName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            } else if let markerText = card.markerText {
                Text(markerText)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 28, height: 28)
    }

    @ViewBuilder
    private func markerBackground(color: Color, size: CGFloat) -> some View {
        switch card.markerShape {
        case .circle:
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        case .square:
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(color)
                .frame(width: size, height: size)
        case .triangle:
            Triangle()
                .fill(color)
                .frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private func borderedCardText(
        _ text: String,
        font: Font,
        foregroundColor: Color,
        lineLimit: Int? = nil,
        minimumScaleFactor: CGFloat? = nil
    ) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(foregroundColor)
            .lineLimit(lineLimit)
            .minimumScaleFactor(minimumScaleFactor ?? 1)
            .shadow(
                color: isPhotoFace && card.imageFaceEnhancer == .border ? .black.opacity(0.8) : .clear,
                radius: isPhotoFace && card.imageFaceEnhancer == .border ? 4 : 0,
                x: 0,
                y: 1.5
            )
    }

    private var cardBackground: AnyShapeStyle {
        switch card.design {
        case .classic:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        card.color.color,
                        card.color.darkerColor,
                        Color.black
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .sunrise:
            return AnyShapeStyle(
                LinearGradient(
                    stops: [
                        .init(color: card.color.color, location: 0.0),
                        .init(color: card.color.color.opacity(0.92), location: 0.28),
                        .init(color: Color.orange.opacity(0.9), location: 0.72),
                        .init(color: card.color.darkerColor, location: 1.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .metro:
            return AnyShapeStyle(
                LinearGradient(
                    stops: [
                        .init(color: card.color.darkerColor, location: 0.0),
                        .init(color: card.color.darkerColor, location: 0.46),
                        .init(color: card.color.color, location: 0.46),
                        .init(color: card.color.color, location: 0.64),
                        .init(color: Color.black, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct SettingsView: View {
    @ObservedObject var store: CardWalletStore

    var body: some View {
        NavigationStack {
            List {
                Section("Card Faces") {
                    NavigationLink {
                        CardFaceLibraryView(store: store)
                    } label: {
                        HStack {
                            Label("Manage Card Faces", systemImage: "photo.stack")
                            Spacer()
                            Text("\(store.faceAssets().count)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !unusedAssets.isEmpty {
                        Button(role: .destructive) {
                            store.deleteUnusedFaceAssets()
                        } label: {
                            Label("Delete Unused Faces", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var unusedAssets: [SavedFaceAsset] {
        store.faceAssets().filter { !store.isFaceAssetUsed($0.fileName) }
    }
}

private struct CardFaceLibraryView: View {
    @ObservedObject var store: CardWalletStore

    var body: some View {
        List {
            if store.faceAssets().isEmpty {
                ContentUnavailableView(
                    "No Saved Faces",
                    systemImage: "photo.stack",
                    description: Text("Saved card images will appear here.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section("Saved Faces") {
                    ForEach(store.faceAssets()) { asset in
                        HStack(spacing: 12) {
                            facePreview(fileName: asset.fileName)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.isFaceAssetUsed(asset.fileName) ? "In Use" : "Unused")
                                Text(asset.fileName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if !store.isFaceAssetUsed(asset.fileName) {
                                Button(role: .destructive) {
                                    store.deleteFaceAsset(asset.fileName)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Card Faces")
    }

    @ViewBuilder
    private func facePreview(fileName: String) -> some View {
        if let faceImage = store.loadFaceImage(fileName: fileName) {
            Image(uiImage: faceImage)
                .resizable()
                .scaledToFill()
                .frame(width: 60, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
                .frame(width: 60, height: 38)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
        }
    }
}

private struct SavedCardDetailView: View {
    private enum AppearanceMode: String, CaseIterable, Identifiable {
        case image = "Image"
        case colors = "Colors"

        var id: String { rawValue }
    }

    let cardID: String
    @ObservedObject var store: CardWalletStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isShowingCamera = false
    @State private var pendingFaceImage: UIImage?
    @State private var appearanceMode: AppearanceMode = .colors
    @State private var isShowingReuseDesignSheet = false
    @State private var isShowingMarkerSheet = false

    var body: some View {
        Group {
            if let card = store.card(withID: cardID) {
                List {
                    Section {
                        WalletCardView(
                            card: card,
                            isExpanded: true,
                            cardHeight: (UIScreen.main.bounds.width - 32) / (85.6 / 53.98),
                            visiblePartHeight: 92,
                            onVisibleTap: {},
                            showDetails: {}
                        )
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowBackground(Color.clear)
                    }

                    Section("Title") {
                        Button {
                            isShowingMarkerSheet = true
                        } label: {
                            HStack(spacing: 12) {
                                MarkerPreviewBadge(card: card)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Icon")
                                        .foregroundStyle(.primary)
                                    Text(card.markerSymbolName == nil ? "None" : "Edit icon, shape, and colors")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)

                        TextField(
                            "Card Title",
                            text: Binding(
                                get: { card.customTitle ?? card.cardFamily },
                                set: { store.setCustomTitle($0, for: card.id) }
                            )
                        )

                        TextField(
                            "Displayed Serial Number",
                            text: Binding(
                                get: { card.customDisplaySerialNumber ?? card.cardNumber ?? card.identifierValue },
                                set: { store.setCustomDisplaySerialNumber($0, for: card.id) }
                            )
                        )
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()

                        if card.faceImageFileName != nil {
                            Toggle(
                                "Hide Title On Image Card",
                                isOn: Binding(
                                    get: { card.hideTitleOnImage },
                                    set: { store.setHideTitleOnImage($0, for: card.id) }
                                )
                            )
                        }

                        Toggle(
                            "Hide Serial Number",
                            isOn: Binding(
                                get: { card.hideSerialNumber },
                                set: { store.setHideSerialNumber($0, for: card.id) }
                            )
                        )
                    }

                    Section("Appearance") {
                        Picker(
                            "Card Design",
                            selection: Binding(
                                get: { appearanceMode },
                                set: { mode in
                                    appearanceMode = mode
                                    if mode == .colors {
                                        store.removeFaceImage(for: card.id)
                                    }
                                }
                            )
                        ) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        if appearanceMode == .image {
                            HStack(spacing: 12) {
                                Text("Card Image")
                                Spacer()
                                
                                if let faceImage = store.loadFaceImage(fileName: card.faceImageFileName) {
                                    Image(uiImage: faceImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 36, height: 36)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                } else {
                                    Image(systemName: "photo")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 36, height: 36)
                                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                            }

                            if card.faceImageFileName != nil {
                                Picker(
                                    "Image Enhancer",
                                    selection: Binding(
                                        get: { card.imageFaceEnhancer },
                                        set: { store.setImageFaceEnhancer($0, for: card.id) }
                                    )
                                ) {
                                    ForEach(ImageFaceEnhancer.allCases) { enhancer in
                                        Text(enhancer.title).tag(enhancer)
                                    }
                                }
                            }
                            
                            PhotosPicker(
                                selection: $selectedPhotoItem,
                                matching: .images,
                                photoLibrary: .shared()
                            ) {
                                Label("Choose From Gallery", systemImage: "photo")
                            }

                            if !reusableFaceAssets(excluding: card).isEmpty {
                                Button {
                                    isShowingReuseDesignSheet = true
                                } label: {
                                    HStack {
                                        Label("Reuse Saved Image", systemImage: "photo.on.rectangle.angled")
                                        Spacer()
                                        Text("\(reusableFaceAssets(excluding: card).count)")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                Button {
                                    isShowingCamera = true
                                } label: {
                                    Label("Take Photo", systemImage: "camera")
                                }
                            }

                        } else {
                            ColorPicker(
                                "Card Color",
                                selection: Binding(
                                    get: { card.color.color },
                                    set: { store.setColor($0, for: card.id) }
                                ),
                                supportsOpacity: false
                            )

                            Picker(
                                "Design",
                                selection: Binding(
                                    get: { card.design },
                                    set: { store.setDesign($0, for: card.id) }
                                )
                            ) {
                                ForEach(SavedCardDesign.allCases) { design in
                                    Text(design.title).tag(design)
                                }
                            }
                        }

                    }

                    Section("Card") {
                        KeyValueRow(title: "Brand", value: card.brand)
                        if let cardNumber = card.cardNumber {
                            KeyValueRow(title: "Card Number", value: cardNumber)
                        }
                        if let customDisplaySerialNumber = card.customDisplaySerialNumber,
                           !customDisplaySerialNumber.isEmpty {
                            KeyValueRow(title: "Displayed Serial", value: customDisplaySerialNumber)
                        }
                        KeyValueRow(title: card.identifierLabel, value: card.identifierValue)
                        KeyValueRow(title: "Technology", value: card.technology)
                        if let systemCode = card.systemCode {
                            KeyValueRow(title: "System Code", value: systemCode)
                        }
                        if let selectedAID = card.selectedAID {
                            KeyValueRow(title: "AID", value: selectedAID)
                        }
                        KeyValueRow(title: "Last Scanned", value: card.scannedAt.formatted(date: .abbreviated, time: .shortened))
                    }

                    if !card.resultFields.isEmpty {
                        Section("Latest Data") {
                            ForEach(card.resultFields) { field in
                                KeyValueRow(title: field.title, value: field.value)
                            }
                            if let balanceText = card.balanceText {
                                KeyValueRow(title: "Balance", value: balanceText)
                            }
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            store.deleteCard(card.id)
                            dismiss()
                        } label: {
                            Label("Delete Card", systemImage: "trash")
                        }
                    }
                }
                .navigationTitle(card.displayTitle)
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    appearanceMode = card.faceImageFileName == nil ? .colors : .image
                }
                .onChange(of: card.faceImageFileName) {
                    appearanceMode = card.faceImageFileName == nil ? .colors : .image
                }
                .onChange(of: selectedPhotoItem) {
                    guard let selectedPhotoItem else { return }
                    Task {
                        if let data = try? await selectedPhotoItem.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            await MainActor.run {
                                pendingFaceImage = image
                            }
                        }
                        await MainActor.run {
                            self.selectedPhotoItem = nil
                        }
                    }
                }
                .sheet(isPresented: $isShowingCamera) {
                    CameraPicker { image in
                        if let image {
                            pendingFaceImage = image
                        }
                    }
                }
                .sheet(item: Binding(
                    get: {
                        pendingFaceImage.map(EditableFaceImage.init)
                    },
                    set: { newValue in
                        pendingFaceImage = newValue?.image
                    }
                )) { editable in
                    FaceImageEditorSheet(
                        image: editable.image,
                        onCancel: {
                            pendingFaceImage = nil
                        },
                        onSave: { renderedImage in
                            store.setFaceImage(renderedImage, for: card.id)
                            pendingFaceImage = nil
                        }
                    )
                }
                .sheet(isPresented: $isShowingReuseDesignSheet) {
                    SavedFaceAssetPickerSheet(
                        store: store,
                        excludingFileName: card.faceImageFileName,
                        onSelect: { fileName in
                            appearanceMode = .image
                            store.applyFaceAsset(fileName, to: card.id)
                            isShowingReuseDesignSheet = false
                        }
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
                .sheet(isPresented: $isShowingMarkerSheet) {
                    MarkerEditorSheet(cardID: card.id, store: store)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            } else {
                ContentUnavailableView("Card Not Found", systemImage: "exclamationmark.circle")
            }
        }
    }

    private func reusableFaceAssets(excluding card: SavedCardRecord) -> [SavedFaceAsset] {
        store.faceAssets().filter { $0.fileName != card.faceImageFileName }
    }

    @ViewBuilder
    private func faceAssetPreview(fileName: String?) -> some View {
        if let faceImage = store.loadFaceImage(fileName: fileName) {
            Image(uiImage: faceImage)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "swatchpalette")
                        .foregroundStyle(.secondary)
                }
        }
    }
}

private struct MarkerPreviewBadge: View {
    let card: SavedCardRecord

    var body: some View {
        ZStack {
            shape(color: card.markerOuterColor.color, size: 30)
            shape(color: card.markerColor.color, size: 24)
            if let markerSystemName = card.markerSystemName {
                Image(systemName: markerSystemName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            } else if let markerText = card.markerText {
                Text(markerText)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "nosign")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 30, height: 30)
    }

    @ViewBuilder
    private func shape(color: Color, size: CGFloat) -> some View {
        switch card.markerShape {
        case .circle:
            Circle().fill(color).frame(width: size, height: size)
        case .square:
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(color).frame(width: size, height: size)
        case .triangle:
            Triangle().fill(color).frame(width: size, height: size)
        }
    }
}

private struct MarkerEditorSheet: View {
    let cardID: String
    @ObservedObject var store: CardWalletStore
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.adaptive(minimum: 56, maximum: 72), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            if let card = store.card(withID: cardID) {
                List {
                    Section {
                        HStack {
                            Spacer()
                            MarkerPreviewBadge(card: card)
                                .scaleEffect(1.8)
                                .padding(.vertical, 18)
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }

                    Section("Shape") {
                        Picker(
                            "Shape",
                            selection: Binding(
                                get: { card.markerShape },
                                set: { store.setMarkerShape($0, for: card.id) }
                            )
                        ) {
                            ForEach(SavedCardMarkerShape.allCases) { shape in
                                Text(shape.title).tag(shape)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Section("Colors") {
                        ColorPicker(
                            "Inner Color",
                            selection: Binding(
                                get: { card.markerColor.color },
                                set: { store.setMarkerColor($0, for: card.id) }
                            ),
                            supportsOpacity: false
                        )

                        ColorPicker(
                            "Outer Color",
                            selection: Binding(
                                get: { card.markerOuterColor.color },
                                set: { store.setMarkerOuterColor($0, for: card.id) }
                            ),
                            supportsOpacity: false
                        )
                    }

                    Section("Icon") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(SavedCardMarkerToken.allCases) { token in
                                    Button {
                                        store.setMarkerSymbolName(token == .none ? nil : token.token, for: card.id)
                                    } label: {
                                        markerTokenCell(token: token, card: card)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }
                .navigationTitle("Card Icon")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            } else {
                ContentUnavailableView("Card Not Found", systemImage: "exclamationmark.circle")
            }
        }
    }

    @ViewBuilder
    private func markerTokenCell(token: SavedCardMarkerToken, card: SavedCardRecord) -> some View {
        let isSelected = (card.markerSymbolName ?? "none") == token.token || (token == .none && card.markerSymbolName == nil)
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)

            ZStack {
                markerShape(card.markerShape, color: card.markerOuterColor.color, size: 34)
                markerShape(card.markerShape, color: card.markerColor.color, size: 27)
                markerTokenContent(token)
            }
        }
        .frame(width: 60, height: 60)
    }

    @ViewBuilder
    private func markerShape(_ shape: SavedCardMarkerShape, color: Color, size: CGFloat) -> some View {
        switch shape {
        case .circle:
            Circle().fill(color).frame(width: size, height: size)
        case .square:
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(color).frame(width: size, height: size)
        case .triangle:
            Triangle().fill(color).frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private func markerTokenContent(_ token: SavedCardMarkerToken) -> some View {
        switch token {
        case .none:
            Image(systemName: "nosign")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.secondary)
        default:
            let raw = token.token
            if raw.hasPrefix("sf:") {
                Image(systemName: String(raw.dropFirst(3)))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Text(String(raw.dropFirst(4)))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
    }
}

private struct SavedFaceAssetPickerSheet: View {
    let store: CardWalletStore
    let excludingFileName: String?
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.adaptive(minimum: 108, maximum: 140), spacing: 12)
    ]

    private var assets: [SavedFaceAsset] {
        store.faceAssets().filter { $0.fileName != excludingFileName }
    }

    var body: some View {
        NavigationStack {
            Group {
                if assets.isEmpty {
                    ContentUnavailableView(
                        "No Saved Images",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Add a card image first, then you can reuse it here.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(assets) { asset in
                                Button {
                                    onSelect(asset.fileName)
                                } label: {
                                    VStack(alignment: .leading, spacing: 0) {
                                        faceAssetCellPreview(fileName: asset.fileName)
                                            .frame(maxWidth: .infinity)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Reuse Design")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func faceAssetCellPreview(fileName: String) -> some View {
        if let faceImage = store.loadFaceImage(fileName: fileName) {
            Image(uiImage: faceImage)
                .resizable()
                .scaledToFill()
                .aspectRatio(85.6 / 53.98, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
                .aspectRatio(85.6 / 53.98, contentMode: .fit)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
        }
    }
}

private struct CardReorderDropDelegate: DropDelegate {
    let destinationID: String
    let store: CardWalletStore
    @Binding var draggedCardID: String?

    func dropEntered(info: DropInfo) {
        guard let draggedCardID, draggedCardID != destinationID else { return }
        store.moveCard(from: draggedCardID, to: destinationID)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedCardID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private struct EditableFaceImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct FaceImageEditorSheet: View {
    let image: UIImage
    let onCancel: () -> Void
    let onSave: (UIImage) -> Void

    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var brightness: Double = -0.04
    @State private var contrast: Double = 1.14
    @State private var rotationQuarterTurns: Int = 0

    private let cardAspectRatio: CGFloat = 85.6 / 53.98
    private let ciContext = CIContext()

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let cardWidth = min(proxy.size.width - 32, 360)
                let cardHeight = cardWidth / cardAspectRatio
                let canvasHeight = cardHeight + 120

                VStack(spacing: 20) {
                    Spacer(minLength: 0)

                    ZStack {
                        Color.black.opacity(0.92)

                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: cardWidth, height: cardHeight)
                            .scaleEffect(scale)
                            .offset(offset)
                            .gesture(imageGesture)

                        cropMask(cardWidth: cardWidth, cardHeight: cardHeight)

                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.78), lineWidth: 1.5)
                            .frame(width: cardWidth, height: cardHeight)

                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 8)
                            .frame(width: cardWidth, height: cardHeight)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: canvasHeight)
                    .clipped()

                    Text("Move, zoom, and rotate the image. The visible card window is the saved crop.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button {
                            rotate(by: -1)
                        } label: {
                            Label("Rotate Left", systemImage: "rotate.left")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            rotate(by: 1)
                        } label: {
                            Label("Rotate Right", systemImage: "rotate.right")
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    VStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Brightness")
                                Spacer()
                                Text(brightness.formatted(.number.precision(.fractionLength(2))))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $brightness, in: -0.4...0.25)
                        }
                        
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Contrast")
                                Spacer()
                                Text(contrast.formatted(.number.precision(.fractionLength(2))))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $contrast, in: 0.7...1.6)
                        }
                    }
                    .font(.footnote)

                    Button("Reset") {
                        offset = .zero
                        committedOffset = .zero
                        scale = 1
                        committedScale = 1
                        brightness = -0.04
                        contrast = 1.14
                        rotationQuarterTurns = 0
                    }
                    .buttonStyle(.bordered)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
                .background(Color(uiColor: .systemBackground))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Use Image") {
                            onSave(renderedCardFace(width: cardWidth, height: cardHeight))
                        }
                    }
                }
            }
            .navigationTitle("Edit Card Face")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private var adjustedImage: UIImage {
        adjustedImage(from: image)
    }

    private var previewImage: UIImage {
        rotatedImage(from: adjustedImage, quarterTurns: rotationQuarterTurns)
    }

    private var imageGesture: some Gesture {
        SimultaneousGesture(
            DragGesture()
                .onChanged { value in
                    offset = CGSize(
                        width: committedOffset.width + value.translation.width,
                        height: committedOffset.height + value.translation.height
                    )
                }
                .onEnded { _ in
                    committedOffset = offset
                },
            MagnificationGesture()
                .onChanged { value in
                    scale = min(max(committedScale * value, 1), 4)
                }
                .onEnded { _ in
                    committedScale = scale
                }
        )
    }

    @ViewBuilder
    private func cropMask(cardWidth: CGFloat, cardHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.5))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .frame(width: cardWidth, height: cardHeight)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .allowsHitTesting(false)
    }

    private func rotate(by delta: Int) {
        rotationQuarterTurns = (rotationQuarterTurns + delta).modulo(4)
    }

    private func renderedCardFace(width: CGFloat, height: CGFloat) -> UIImage {
        let targetSize = CGSize(width: 1712, height: 1080)
        let scaleX = targetSize.width / width
        let scaleY = targetSize.height / height
        let processedImage = previewImage
        let imageSize = processedImage.size
        let fillScale = max(targetSize.width / imageSize.width, targetSize.height / imageSize.height)
        let baseSize = CGSize(width: imageSize.width * fillScale, height: imageSize.height * fillScale)
        let baseOrigin = CGPoint(
            x: (targetSize.width - baseSize.width) / 2,
            y: (targetSize.height - baseSize.height) / 2
        )
        let renderer = UIGraphicsImageRenderer(size: targetSize)

        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))

            let drawRect = CGRect(
                x: baseOrigin.x + offset.width * scaleX - ((baseSize.width * scale) - baseSize.width) / 2,
                y: baseOrigin.y + offset.height * scaleY - ((baseSize.height * scale) - baseSize.height) / 2,
                width: baseSize.width * scale,
                height: baseSize.height * scale
            )
            processedImage.draw(in: drawRect)
        }
    }
    
    private func adjustedImage(from image: UIImage) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }
        let filter = CIFilter.colorControls()
        filter.inputImage = ciImage
        filter.brightness = Float(brightness)
        filter.contrast = Float(contrast)
        filter.saturation = 1.0
        
        guard let outputImage = filter.outputImage,
              let cgImage = ciContext.createCGImage(outputImage, from: outputImage.extent) else {
            return image
        }
        
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    private func rotatedImage(from image: UIImage, quarterTurns: Int) -> UIImage {
        let normalizedTurns = quarterTurns.modulo(4)
        guard normalizedTurns != 0, let cgImage = image.cgImage else { return image }

        let angle = CGFloat(normalizedTurns) * (.pi / 2)
        let rotatedSize: CGSize
        switch normalizedTurns {
        case 1, 3:
            rotatedSize = CGSize(width: image.size.height, height: image.size.width)
        default:
            rotatedSize = image.size
        }

        let renderer = UIGraphicsImageRenderer(size: rotatedSize)
        return renderer.image { context in
            let cgContext = context.cgContext
            cgContext.translateBy(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
            cgContext.rotate(by: angle)
            cgContext.scaleBy(x: 1, y: -1)
            cgContext.draw(
                cgImage,
                in: CGRect(
                    x: -image.size.width / 2,
                    y: -image.size.height / 2,
                    width: image.size.width,
                    height: image.size.height
                )
            )
        }
    }
}

private extension Int {
    func modulo(_ base: Int) -> Int {
        let remainder = self % base
        return remainder >= 0 ? remainder : remainder + base
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    let onImagePicked: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImagePicked: (UIImage?) -> Void

        init(onImagePicked: @escaping (UIImage?) -> Void) {
            self.onImagePicked = onImagePicked
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            onImagePicked(nil)
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = info[.originalImage] as? UIImage
            picker.dismiss(animated: true)
            onImagePicked(image)
        }
    }
}

private func loadCardFaceImage(fileName: String) -> UIImage? {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let url = base.appendingPathComponent("CardBal/CardFaces", isDirectory: true)
        .appendingPathComponent(fileName)
    return UIImage(contentsOfFile: url.path)
}

private extension TransitCardSnapshot {
    var storageIdentifier: String {
        "\(technology)|\(rawIdentifierValue)"
    }
}

#Preview {
    ContentView()
}
