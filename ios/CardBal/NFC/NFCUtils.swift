import Foundation
import os
import SwiftUI

public enum ICCardRegion: String, Codable, CaseIterable {
    case japan, korea, mongolia, hongkong, macau, china, singapore, usa, newZealand, indonesia, europe, other
    public var currencyCode: String {
        switch self {
        case .japan: return "JPY"
        case .korea: return "KRW"
        case .mongolia: return "MNT"
        case .hongkong: return "HKD"
        case .macau: return "MOP"
        case .china: return "CNY"
        case .singapore: return "SGD"
        case .newZealand: return "NZD"
        case .indonesia: return "IDR"
        default: return "USD"
        }
    }
}

public enum ICCardBrand: String, Codable, CaseIterable, Identifiable {
    public var id: String { rawValue }
    case suica, pasmo, icoca, manaca, sugoca, hayakaken, kitaca, nimoca, toica, pitapa, okica
    case edy, waon, nanaco
    case japaneseFeliCa
    case tmoney, umoney, ezl, namane, climateCard, moiba, kCash
    case octopus
    case ezlink, netsFlashPay
    case clipper, macauPass
    case tUnion, tianfuTong
    case snapperPlus, kmt
    case other
    public var region: ICCardRegion {
        switch self {
        case .suica, .pasmo, .icoca, .manaca, .sugoca, .hayakaken, .kitaca, .nimoca, .toica, .pitapa, .okica, .edy, .waon, .nanaco, .japaneseFeliCa: return .japan
        case .tmoney, .ezl, .namane, .climateCard, .moiba, .kCash: return .korea
        case .umoney: return .mongolia
        case .octopus: return .hongkong
        case .ezlink, .netsFlashPay: return .singapore
        case .clipper: return .usa
        case .macauPass: return .macau
        case .tUnion, .tianfuTong: return .china
        case .snapperPlus: return .newZealand
        case .kmt: return .indonesia
        case .other: return .other
        }
    }
    
    public enum DecoderType {
        case japanIC, ksx6924, namane, octopus, tUnion, snapperPlus, kmt, other
    }

    public var decoderType: DecoderType {
        switch self {
        case .suica, .pasmo, .icoca, .manaca, .sugoca, .hayakaken, .kitaca, .nimoca, .toica, .pitapa, .okica, .edy, .waon, .nanaco, .japaneseFeliCa: return .japanIC
        case .tmoney, .umoney, .ezl, .climateCard, .moiba, .kCash: return .ksx6924
        case .namane: return .namane
        case .octopus: return .octopus
        case .tUnion: return .tUnion
        case .snapperPlus: return .snapperPlus
        case .kmt: return .kmt
        default: return .other
        }
    }

    public var isKorean: Bool { region == .korea }
    public var isJapan: Bool { region == .japan }

    /// Family labels returned by `FeliCaProfile.detectedBrand` for Japanese
    /// cards that do not have a dedicated `ICCardBrand` case.
    private static let japaneseFeliCaFamilies: Set<String> = [
        "ayuca", "ci-ca", "desuca / ic e-card", "ex-ic", "fcf",
        "felica lite", "hanica", "hareca", "himawari bus", "ica",
        "iruca", "itappy", "kitami bus / luluca", "kumamoto ic",
        "nagasaki smart", "nicepass", "nicopa", "noruca",
        "ntasu t-card", "ohmi railway bus", "paspy", "passca / ecomyca",
        "quicpay", "randen", "rapica", "ryuto", "sapica",
        "univ coop"
    ]

    public static func from(family: String) -> ICCardBrand {
        let f = family.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Exact mappings for sanitized names
        let exactMap: [String: ICCardBrand] = [
            "suica": .suica, "pasmo": .pasmo, "icoca": .icoca, "manaca": .manaca,
            "sugoca": .sugoca, "hayakaken": .hayakaken, "kitaca": .kitaca, "nimoca": .nimoca,
            "toica": .toica, "pitapa": .pitapa, "t-money": .tmoney, "tmoney": .tmoney,
            "u-money": .umoney, "umoney": .umoney,
            "ezl": .ezl, "cashbee": .ezl, "namane": .namane, "climate card": .climateCard,
            "moiba": .moiba, "k-cash": .kCash, "kcash": .kCash, "octopus": .octopus,
            "rakuten edy": .edy, "edy": .edy, "waon": .waon, "nanaco": .nanaco,
            "okica": .okica,
            "snapper+": .snapperPlus, "snapper plus": .snapperPlus,
            "kmt": .kmt, "kartu multi trip": .kmt,
            "t-union": .tUnion, "china t-union": .tUnion, "city union": .tUnion,
            "天府通": .tianfuTong, "tianfu tong": .tianfuTong, "tianfutong": .tianfuTong
        ]
        
        if f.hasPrefix("ez-link") || f.hasPrefix("ezlink") || f.hasPrefix("cepas") { return .ezlink }
        if f == "nets flashpay" { return .netsFlashPay }
        if f == "clipper" || f == "clipper ticket" { return .clipper }
        if ["macau pass", "macaupass", "macau-pass", "澳门通", "澳門通"].contains(f) { return .macauPass }
        if let directMatch = exactMap[f] { return directMatch }
        if japaneseFeliCaFamilies.contains(f) { return .japaneseFeliCa }
        
        // Brand-specific prefixes/patterns if exact match fails
        if f.hasPrefix("suica") { return .suica }
        if f.hasPrefix("pasmo") { return .pasmo }
        if f.hasPrefix("icoca") { return .icoca }
        if f.hasPrefix("u-money") || f.hasPrefix("umoney") { return .umoney }
        if f.hasPrefix("t-money") { return .tmoney }
        if f.hasPrefix("ezl") { return .ezl }
        if f.hasPrefix("cashbee") { return .ezl }
        if f.hasPrefix("namane") { return .namane }
        if f.hasPrefix("climate") { return .climateCard }
        if f.hasPrefix("octopus") { return .octopus }
        if f.hasPrefix("rakuten edy") || f == "edy" { return .edy }
        if f.hasPrefix("waon") { return .waon }
        if f.hasPrefix("nanaco") { return .nanaco }
        if f.hasPrefix("okica") { return .okica }
        if f.hasPrefix("t-union") || f.hasPrefix("china") || f.contains("city union") { return .tUnion }
        
        // Generic Fallbacks
        if f.hasSuffix("transit ic") || f.hasSuffix("feli") || f.hasSuffix("japan") { return .suica }
        
        return .other
    }
}

/// Availability follows owned card applications, independently of trip history.
enum WalletCountryVisibility {
    static func countryCodes(cardFamilies: [String]) -> Set<String> {
        Set(cardFamilies.compactMap { family in
            switch ICCardBrand.from(family: family).region {
            case .japan: return "JP"
            case .korea: return "KR"
            case .mongolia: return "MN"
            case .hongkong, .macau, .china: return "CN"
            case .singapore: return "SG"
            default: return nil
            }
        })
    }
}

enum DeveloperModePreferences {
    static let enabledKey = "developerModeEnabled"
}

// MARK: - Models

struct ResultField: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let value: String
}

struct RawDataSection: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let fields: [RawDataField]
}

struct RawDataField: Identifiable, Codable, Hashable, Equatable {
    var id: String { title + value }
    let title: String
    let value: String
    
    static func systemCodeRow(_ codes: [String]) -> RawDataField {
        RawDataField(title: "System Codes", value: codes.joined(separator: ", "))
    }
}

struct ParsedBalance: Hashable {
    let formatted: String
    let detail: String
    let rawFields: [RawDataField]
}

enum TransactionCategory: String, Codable {
    case topUp
    case tapOn
    case tapOff
    case payment
    case purchase
    case adjustment
    case refund
    case bus
    case busOn
    case busOff
    case train
    case ferry
    case trainOn
    case trainOff
    case unknown
}

struct TransitTransaction: Identifiable, Hashable, Codable {
    let id: UUID
    let date: Date?
    let time: String?
    let amount: Decimal
    let terminalID: String?
    let recordNumber: Int?
    let ntsam: Int?
    let type: String
    let category: TransactionCategory
    let balanceAfter: Decimal?
    let location: String?
    let entryStation: String?
    let exitStation: String?
    let entryStationCode: String?
    let exitStationCode: String?
    let regionCode: Int?
    let rawData: String?
    let distance: Double?
    var sourceApplicationID: String? = nil
    var sourceCardFamily: String? = nil
    var currencyCode: String? = nil
    var issuerTimeZone: String? = nil
    var amountIsSigned: Bool = false
    var amountKnown: Bool = true
    var sourceRecordIDs: [String]? = nil

    /// Stable identity derived from content, not the random UUID. Used by ForEach to avoid
    /// UICollectionView crashes when the transactions array is recomputed after deletion.
    var stableID: String {
        (sourceApplicationID.map { $0 + "|" } ?? "") + (rawData ?? "\(date?.timeIntervalSince1970 ?? 0)|\(amount)|\(type)|\(recordNumber ?? -1)")
    }
    
    init(date: Date?, time: String? = nil, amount: Decimal, terminalID: String?, type: String, category: TransactionCategory = .unknown, balanceAfter: Decimal? = nil, location: String? = nil, entryStation: String? = nil, exitStation: String? = nil, entryStationCode: String? = nil, exitStationCode: String? = nil, regionCode: Int? = nil, rawData: String? = nil, recordNumber: Int? = nil, ntsam: Int? = nil, distance: Double? = nil) {
        self.id = UUID()
        self.date = date
        self.time = time
        self.amount = amount
        self.terminalID = terminalID
        self.recordNumber = recordNumber
        self.ntsam = ntsam
        self.type = type
        self.category = category
        self.balanceAfter = balanceAfter
        self.location = location
        self.entryStation = entryStation
        self.exitStation = exitStation
        self.entryStationCode = entryStationCode
        self.exitStationCode = exitStationCode
        self.regionCode = regionCode
        self.rawData = rawData
        self.distance = distance
    }
}

// MARK: - Decode on Demand Registry
enum RawHistoryKind {
    case transactions
    case transit
}

struct TransactionDecoderRegistry {
    static func decode(raw: String, family: String, technology: String, context: [String], at index: Int, kind: RawHistoryKind = .transactions, relatedContext: [String] = []) -> TransitTransaction? {
        let data = Data(hexString: raw)
        
        // Skip empty/all-zeros block check
        if data.allSatisfy({ $0 == 0x00 }) && !raw.isEmpty { return nil }

        if ICCardBrand.from(family: family) == .clipper {
            if technology == "MIFARE Ultralight" { return ClipperUltralightDecoder.decodeTransaction(data) }
            if data.count == 33 {
                return ClipperDecoder.decodeTransaction(data, context: context.map { Data(hexString: $0) }, index: index)
            }
        }
        if AdditionalCardHistory.handles(family) {
            return kind == .transactions ? AdditionalCardHistory.decode(raw: raw, family: family, context: context) : nil
        }
        let contextData = context.compactMap { Data(hexString: $0) }
        let relatedContextData = relatedContext.compactMap { Data(hexString: $0) }

        let brand = ICCardBrand.from(family: family)
        if brand == .macauPass {
            return technology == "ISO7816" && kind == .transactions
                ? MacauPassDecoder.decodeTransaction(data) : nil
        }
        if brand == .tianfuTong {
            return technology == "ISO7816" && kind == .transactions
                ? TianfuTongDecoder.decodeRecord(data: data, index: index) : nil
        }
        // These families have their own layouts. Their records must never be
        // interpreted as Japanese station codes or Korean transaction files.
        if brand == .kmt { return nil }
        if brand == .snapperPlus {
            guard technology == "ISO7816", kind == .transactions,
                  let record = SnapperPlusProtocol.decodeHistory(data) else { return nil }
            let category: TransactionCategory = record.transactionType == 2 ? .topUp
                : record.isTapOn.map { $0 ? .tapOn : .tapOff } ?? .payment
            let type = record.transactionType == 2 ? "Top-up"
                : record.isTapOn.map { $0 ? "Tap-on" : "Tap-off" } ?? "Transit payment"
            let time = record.timestamp.map { date in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(identifier: "Pacific/Auckland")
                formatter.dateFormat = "HH:mm:ss"
                return formatter.string(from: date)
            }
            var transaction = TransitTransaction(
                date: record.timestamp, time: time, amount: Decimal(record.amountMinor) / 100,
                terminalID: record.operatorID, type: type, category: category,
                balanceAfter: Decimal(record.balanceMinor) / 100, rawData: raw,
                recordNumber: Int(record.counter)
            )
            transaction.currencyCode = "NZD"
            return transaction
        }
        
        if technology == "FeliCa" {
            return JapaneseICDecoder.decodeTransaction(block: data, context: contextData, index: index, family: family, kind: kind, relatedContext: relatedContextData)
        } else if technology == "ISO7816" {
            // KS X 6924 (T-money-compatible T-money/U-Money/EZL/NAMANE)
            let brand = ICCardBrand.from(family: family)
            if family.localizedCaseInsensitiveContains("City Union"), data.count == 23 {
                return CityUnionDecoder.decodeTransitRecord(data: data, index: index)
            } else if brand == .tUnion && data.count >= 48 {
                return TUnionDecoder.decodeTravelRecord(data: data, index: index)
            } else if data.count == 52 {
                return KSX6924Decoder.parseTransitHistory(data, sfi: 3, recordIndex: index + 1, brand: brand, logger: os.Logger(subsystem: "ad.neko.cardbal", category: "KSX6924"))
            } else if data.count == 23 {
                return TUnionDecoder.decodePBOC(data: data, index: index, resolveTUnionTerminals: brand == .tUnion)
            } else {
                let isNAMANE = brand == .namane
                if isNAMANE && data.count == 14 {
                    return NAMANEDecoder.parseNAMANELog(data, sfi: 14, recordIndex: index + 1, isNAMANE: true, logger: os.Logger(subsystem: "ad.neko.cardbal", category: "NAMANE"))
                }
                return KSX6924Decoder.parseSingleTransaction(data, sfi: 4, recordIndex: index + 1, brand: brand, logger: os.Logger(subsystem: "ad.neko.cardbal", category: "KSX6924"))
            }
        }
        return nil
    }
}

extension TransitTransaction {
    var hasUnresolvedKoreanTransitFare: Bool {
        guard let rawData else {
            return false
        }
        let data = Data(hexString: rawData)
        guard data.count == KoreanTransitTimestampDecoder.recordLength else { return false }
        return KoreanTransitHistoryFareLayout.decode(data)?.variant == .unresolved
    }

    var iconInfo: (name: String, color: Color) {
        switch self.category {
        case .topUp: return ("arrow.down.left.circle.fill", .green)
        case .tapOn, .busOn: return ("bus.fill", .blue)
        case .tapOff, .busOff: return ("bus", .indigo)
        case .trainOn: return ("tram.fill", .blue)
        case .trainOff: return ("tram", .indigo)
        case .train: return ("tram.fill", .blue)
        case .ferry: return ("ferry.fill", .blue)
        case .purchase: return ("cart.fill", .orange)
        case .adjustment: return ("hammer.fill", .brown)
        case .refund: return ("arrow.uturn.left.circle.fill", .red)
        case .bus: return ("bus.fill", .cyan)
        case .payment: return ("creditcard.fill", .accentColor)
        case .unknown: return ("creditcard.fill", .accentColor)
        }
    }
}

struct TransitCardSnapshot: Identifiable {
    let id = UUID()
    let technology: String
    let cardFamily: String
    let identifierLabel: String
    let identifierValue: String
    let rawIdentifierValue: String
    let pmm: String?
    let systemCode: String?
    let selectedAID: String?
    let balanceText: String?
    let balanceDetail: String?
    let realSerialNumber: String?
    let region: String?
    let resultFields: [ResultField]
    let rawSections: [RawDataSection]
    let rawTransactions: [String]
    let rawTransitHistory: [String]
    
    var transactions: [TransitTransaction] {
        if let applications { return TransitApplicationHistory.decode(applications, kind: .transactions) }
        return rawTransactions.enumerated().compactMap { idx, hex in
            TransactionDecoderRegistry.decode(raw: hex, family: cardFamily, technology: technology, context: rawTransactions, at: idx, kind: .transactions)
        }
    }
    
    var transitHistory: [TransitTransaction] {
        if let applications { return TransitApplicationHistory.decode(applications, kind: .transit) }
        return rawTransitHistory.enumerated().compactMap { idx, hex in
            TransactionDecoderRegistry.decode(raw: hex, family: cardFamily, technology: technology, context: rawTransitHistory, at: idx, kind: .transit, relatedContext: rawTransactions)
        }
    }

    var unifiedRecentTransactions: [TransitTransaction] {
        sortTransactionsByRecency(transactions)
    }
    
    let scannedAt: Date
    var applications: [TransitApplication]? = nil
    
    var brand: ICCardBrand {
        ICCardBrand.from(family: cardFamily)
    }
}

func sortTransactionsByRecency(_ transactions: [TransitTransaction]) -> [TransitTransaction] {
    transactions.sorted { t1, t2 in
        switch (t1.date, t2.date) {
        case let (d1?, d2?) where d1 != d2:
            return d1 > d2
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            if let r1 = t1.recordNumber, let r2 = t2.recordNumber, r1 != r2 {
                return r1 > r2
            }
            return t1.id.uuidString > t2.id.uuidString
        }
    }
}

enum StatusKind {
    case idle
    case success
    case error
}

enum NFCTestError: Error {
    case unsupportedCard
}

enum NFCISO7816AccessPolicy {
    static let exactAIDs: Set<String> = [
        "A0000004520001", "D4100000030001", "D4100000140001", "D410000029000001", "D4100000300001", "D4106509900020", "A00000000386980701", "A000000632010105"
    ]

    static let ksx6924AllowedPrefixes: [String] = [
        "D410000003",
        "D410000014",
        "D410000029",
        "D410000030",
        "D410650990"
    ]

    static func isAllowed(aid: String) -> Bool {
        let normalized = aid.uppercased()
        return exactAIDs.contains(normalized)
            || ksx6924AllowedPrefixes.contains { normalized.hasPrefix($0) }
            || CalypsoCardProfile.supportedPrefixes.contains { normalized.hasPrefix($0) }
    }
}

// NFCTransitReader moved to NFC/NFCTransitReader.swift

// MARK: - Helpers & Extensions

// Helpers moved to end of file

struct TransitTransactionRow: View {
    let tx: TransitTransaction
    let cardFamily: String?
    let reportCard: SavedCardRecord?
    @State private var showingDetails = false

    init(tx: TransitTransaction, cardFamily: String?, reportCard: SavedCardRecord? = nil) {
        self.tx = tx
        self.cardFamily = cardFamily
        self.reportCard = reportCard
    }

    private var brand: ICCardBrand {
        ICCardBrand.from(family: tx.sourceCardFamily ?? cardFamily ?? "")
    }
    
    var body: some View {
        Button {
            showingDetails = true
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: iconMapping.name)
                    .font(.title2)
                    .frame(width: 30)
                    .foregroundStyle(iconMapping.color)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(Localizer.localize(tx.type))
                        .font(.headline)
                    HStack(spacing: 4) {
                        let isRecordOnly = tx.time?.contains("Record #") ?? false
                        let resolution = CardDateFormatting.resolution(forTimeText: tx.time)

                        if let date = tx.date, date.timeIntervalSince1970 > 86400 {
                            Text(CardDateFormatting.formatDisplayDateTime(date, brand: brand, resolution: resolution, issuerTimeZone: tx.issuerTimeZone))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else if let time = tx.time, !isRecordOnly {
                            Text(Localizer.localize(time)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let locationLine = displayLocationLine {
                        Text(locationLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let term = tx.terminalID, term != tx.type {
                        Text(Localizer.localize(term)).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    if !tx.amountKnown {
                        Text("Fare unavailable").font(.headline).foregroundStyle(.secondary)
                    } else if tx.amount != 0 {
                        let isTopUp = (brand == .snapperPlus || tx.amountIsSigned) ? tx.amount > 0 : (tx.category == .topUp || tx.category == .refund)
                        
                        Text((isTopUp ? "+" : "-") + 
                             formatCurrency(amount: abs(tx.amount), code: currencyCode, fractionDigits: currencyFractionDigits))
                            .font(.headline.monospacedDigit().bold())
                            .foregroundStyle(isTopUp ? .green : .primary)
                    } else if brand.isKorean && tx.hasUnresolvedKoreanTransitFare {
                        Text("Fare unknown")
                            .font(.headline.bold())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No Charge")
                            .font(.headline.monospacedDigit().bold())
                            .foregroundStyle(.secondary)
                    }
                    
                    if let bal = tx.balanceAfter {
                        Text(formatCurrency(amount: bal, code: currencyCode, fractionDigits: currencyFractionDigits))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingDetails) {
            TransactionDetailView(tx: tx, cardFamily: cardFamily, reportCard: reportCard)
        }
    }
    
    private var iconMapping: (name: String, color: Color) {
        tx.iconInfo
    }
    
    private var displayLocationLine: String? {
        if brand == .tUnion {
            return tx.location ?? tx.entryStation ?? tx.exitStation
        }

        if let loc = tx.location {
            let isTimeDuplicate = tx.time != nil && loc.contains(":") && loc.count <= 8 && tx.time!.contains(loc)
            return isTimeDuplicate ? nil : loc
        }

        return nil
    }

    private var currencyCode: String {
        tx.currencyCode ?? brand.region.currencyCode
    }

    private var currencyFractionDigits: Int {
        defaultFractionDigits(for: currencyCode)
    }
}

struct TransactionDetailView: View {
    let tx: TransitTransaction
    let cardFamily: String?
    let reportCard: SavedCardRecord?
    @Environment(\.dismiss) var dismiss

    init(tx: TransitTransaction, cardFamily: String?, reportCard: SavedCardRecord? = nil) {
        self.tx = tx
        self.cardFamily = cardFamily
        self.reportCard = reportCard
    }

    private var reportStationCode: String? {
        let codes = [tx.entryStationCode, tx.exitStationCode]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Set(codes).count == 1 ? codes.first : nil
    }
    
    private var brand: ICCardBrand {
        ICCardBrand.from(family: tx.sourceCardFamily ?? cardFamily ?? "")
    }
    
    private var tUnionDetails: TUnionTransactionRecordDetails? {
        guard brand == .tUnion, let raw = tx.rawData else { return nil }
        return TUnionTransactionRecordDetails(raw: raw, isCityUnion: (tx.sourceCardFamily ?? cardFamily ?? "").contains("City Union"))
    }

    private var tUnionTravelDetails: TUnionTravelRecordDetails? {
        guard brand == .tUnion, let raw = tx.rawData else { return nil }
        return TUnionTravelRecordDetails(raw: raw)
    }

    private var isKSX6924Card: Bool {
        switch brand.decoderType {
        case .ksx6924, .namane:
            return true
        default:
            return false
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Transaction Summary") {
                    if let family = tx.sourceCardFamily {
                        KeyValueRow(title: "Card Family", value: family)
                    }
                    let isKorean = brand.isKorean
                    let isJapan = brand.isJapan
                    let isNAMANE = brand == .namane
                    
                    LabeledContent {
                        Text(Localizer.localize(tx.type))
                    } label: {
                        HStack {
                            Text("Type")
                        }
                    }
                    
                    if let term = tx.terminalID, !isKorean, !isKSX6924Card {
                        LabeledContent {
                            Text(Localizer.localize(term))
                        } label: {
                            HStack {
                                Text("Terminal")
                            }
                        }
                    }
                    let isRecordOnly = tx.time?.contains("Record #") ?? false
                    
                    if let date = tx.date, !isNAMANE, !isRecordOnly {
                        LabeledContent {
                            Text(CardDateFormatting.formatDisplayDate(date, brand: brand, issuerTimeZone: tx.issuerTimeZone))
                        } label: {
                            HStack {
                                Text("Date")
                            }
                        }
                    }
                    let resolution = CardDateFormatting.resolution(forTimeText: tx.time)
                    let displayTime = tx.date.flatMap { date -> String? in
                        resolution == .date ? nil : CardDateFormatting.formatDisplayTime(date, brand: brand, resolution: resolution, issuerTimeZone: tx.issuerTimeZone)
                    } ?? tx.time
                    let hasDisplayTime = displayTime?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "n/a"
                    if !isNAMANE, !isRecordOnly, hasDisplayTime, let displayTime {
                        LabeledContent {
                            Text(Localizer.localize(displayTime))
                        } label: {
                            HStack {
                                Text("Time")
                            }
                        }
                    }
                    if let amount = tx.amount != 0 ? tx.amount : nil {
                        LabeledContent {
                            let isTopUp = (brand == .snapperPlus || tx.amountIsSigned) ? tx.amount > 0 : (tx.category == .topUp || tx.category == .refund)
                            let signedAmount = (isTopUp ? "+" : "-") + 
                                               formatCurrency(amount: abs(amount), code: currencyCode, fractionDigits: currencyFractionDigits)
                            Text(signedAmount)
                        } label: {
                            HStack {
                                Text("Amount")
                            }
                        }
                    } else if isKorean, tx.hasUnresolvedKoreanTransitFare {
                        LabeledContent {
                            Text("Fare unknown")
                                .foregroundStyle(.secondary)
                        } label: {
                            HStack {
                                Text("Amount")
                            }
                        }
                    }

                    if let balance = tx.balanceAfter {
                        LabeledContent {
                            Text(formatCurrency(amount: balance, code: currencyCode, fractionDigits: currencyFractionDigits))
                        } label: {
                            HStack {
                                Text("Balance After")
                            }
                        }
                    }

                    if let travelDetails = tUnionTravelDetails {
                        LabeledContent {
                            Text(travelDetails.cityDisplay)
                        } label: {
                            HStack {
                                Text("City")
                            }
                        }
                        LabeledContent {
                            Text(travelDetails.stationDisplay)
                        } label: {
                            HStack {
                                Text("Station")
                            }
                        }
                    } else if let entry = tx.entryStation, tx.category != .purchase {
                         LabeledContent {
                             HStack(spacing: 4) {
                                 Text(entry)
                                 if let code = tx.entryStationCode {
                                     Text("[\(code)]").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.tertiary)
                                 }
                             }
                         } label: {
                             HStack(spacing: 6) {
                                 Text(Localizer.localize(tx.category == .bus ? "Operator" : "Entry"))
                             }
                         }
                    }
                    if tUnionTravelDetails == nil, let exit = tx.exitStation, tx.category != .purchase {
                         LabeledContent {
                             HStack(spacing: 4) {
                                 Text(exit)
                                 if let code = tx.exitStationCode {
                                     Text("[\(code)]").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.tertiary)
                                 }
                             }
                         } label: {
                             HStack(spacing: 6) {
                                 Text(Localizer.localize(tx.category == .bus ? "Station" : "Exit"))
                             }
                         }
                    }
                    
                    if tUnionTravelDetails == nil, let loc = tx.location, !isNAMANE {
                         let isTimeOnly = loc.range(of: "^\\d{2}:\\d{2}:\\d{2}$", options: .regularExpression) != nil
                         if !isJapan || !isTimeOnly {
                             LabeledContent("Location", value: loc)
                         }
                    }

                    if let details = tUnionDetails {
                        LabeledContent {
                            Text("\(details.sequence)")
                        } label: {
                            HStack {
                                Text("Sequence")
                            }
                        }
                        LabeledContent {
                            Text(details.overdraftLimitHex)
                        } label: {
                            HStack {
                                Text("Overdraft Limit")
                            }
                        }
                        LabeledContent {
                            Text(details.cityDisplay)
                        } label: {
                            HStack {
                                Text("Terminal City")
                            }
                        }
                    }

                    if isKSX6924Card {
                        let is52 = (tx.rawData?.count ?? 0) >= 104
                        
                        if let dist = tx.distance {
                            LabeledContent {
                                Text(String(format: "%.1f km", dist))
                            } label: {
                                HStack {
                                    Text("Distance")
                                }
                            }
                        }
                        
                        if let tid = tx.terminalID {
                            LabeledContent {
                                Text(tid)
                            } label: {
                                HStack {
                                    Text(Localizer.localize(is52 ? "Location Code" : "Terminal (IDSAM)"))
                                }
                            }
                        }
                        if let ntsam = tx.ntsam, !is52 {
                            LabeledContent {
                                Text("\(ntsam)")
                            } label: {
                                HStack {
                                    Text("NTSAM")
                                }
                            }
                        }
                        if let ntep = tx.recordNumber {
                            LabeledContent {
                                Text("\(ntep)")
                            } label: {
                                HStack {
                                    Text(Localizer.localize(is52 ? "Record Order" : "Record (NTEP)"))
                                }
                            }
                        }
                    }
                }
                
                if let reportCard {
                    Section {
                        NavigationLink {
                            StationReportView(card: reportCard, stationCode: reportStationCode)
                        } label: {
                            Label("Report or Correct a Station", systemImage: "mappin.and.ellipse")
                        }
                    } footer: {
                        Text("Check any prefilled code before submitting. Station details appear on the public request list; card and device IDs stay private.")
                    }
                }

                if let raw = tx.rawData {
                    Section("Raw Transaction Record") {
                        CardRawDataHighlightView(raw: raw, tx: tx, cardFamily: tx.sourceCardFamily ?? cardFamily ?? "")
                        
                        let f = (tx.sourceCardFamily ?? cardFamily ?? "").lowercased()
                        if brand == .snapperPlus {
                             Text("Snapper+ records retain the original SFI 4 transaction and its optional SFI 3 companion. Station names are unavailable for these records.")
                                 .font(.caption).foregroundStyle(.secondary)
                        } else if brand == .waon {
                             WAONRawBreakdownView(raw: raw, tx: tx)
                        } else if brand == .nanaco {
                             NanacoRawBreakdownView(raw: raw, tx: tx)
                        } else if brand == .edy {
                             EdyRawBreakdownView(raw: raw, tx: tx)
                        } else if f.contains("japan") || f.contains("suica") || f.contains("pasmo") || f.contains("icoca") || f.contains("hayakaken") || f.contains("sugoca") || f.contains("kitaca") || f.contains("nimoca") || f.contains("toica") {
                             if tx.category == .trainOn || tx.category == .trainOff || tx.type.contains("Transit Activity") || tx.type == "Entry" || tx.type == "Exit" || tx.type == "Discount Entry" {
                                 FeliCaTransitRawBreakdownView(raw: raw, tx: tx)
                             } else {
                                 SuicaRawBreakdownView(raw: raw, tx: tx)
                             }
                        } else if brand == .tUnion {
                             TUnionRawBreakdownView(raw: raw, tx: tx)
                        } else if isKSX6924Card {
                             KoreanRawBreakdownView(raw: raw, brand: brand)
                        }
                    }
                }
            }
            .navigationTitle("Transaction Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
    
    private var currencyCode: String {
        tx.currencyCode ?? ICCardBrand.from(family: tx.sourceCardFamily ?? cardFamily ?? "").region.currencyCode
    }

    private var currencyFractionDigits: Int {
        defaultFractionDigits(for: currencyCode)
    }

}

struct KoreanRawBreakdownView: View {
    let raw: String
    let brand: ICCardBrand
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let data = Data(hexString: raw)
            if data.count >= 52 {
                // T-Money Transit Record (52 bytes)
                let record = data.count == 52 ? data : data.subdata(in: 0..<52)
                let fareLayout = KoreanTransitHistoryFareLayout.decode(record)
                let timestamp = KoreanTransitTimestampDecoder.decode(record, brand: brand)
                let recType = record.subdata(in: 0..<2).hexString
                let tripState = record[2]
                let tripStateDisplay = tripState == 0x00
                    ? NSLocalizedString("korean_event_boarding", comment: "Korean transit boarding event")
                    : tripState == 0x01
                        ? NSLocalizedString("korean_event_alighting", comment: "Korean transit alighting event")
                        : NSLocalizedString("korean_event_flagged", comment: "Korean transit unknown flagged event")
                let timestampDisplay = timestamp.map {
                    String(format: "%04d-%02d-%02d %02d:%02d:%02d", $0.year, $0.month, $0.day, $0.hour, $0.minute, $0.second)
                } ?? NSLocalizedString("Unresolved", comment: "A raw value could not be decoded")
                let distM = record.bigEndianInt(start: 19, length: 2)
                let selectedAmount = fareLayout?.selectedAmount.map {
                    formatCurrency(amount: Decimal($0), code: brand.region.currencyCode)
                }
                    ?? NSLocalizedString("Fare unknown", comment: "Korean transit fare could not be resolved")
                let stationToken = record.subdata(in: 5..<9).hexString.uppercased()
                let transportModeHex = record.subdata(in: 9..<11).hexString.uppercased()
                let transportModeCode = record.bigEndianInt(start: 9, length: 2)
                let transportMode = brand.isKorean
                    ? KOTRISTransportModeCatalog.bundled?.mode(for: transportModeCode)
                    : nil
                let locationCode = stationToken + transportModeHex
                let stationAlias = brand.isKorean
                    ? KoreanStationAliasCatalog.bundled?.location(
                        for: locationCode,
                        eventRaw: Int(tripState)
                    )
                    : nil
                let transportModeDisplay = transportMode.map {
                    "\($0.nameKo) · \($0.transportClass.displayName)"
                } ?? NSLocalizedString("Unmapped", comment: "No data-source match")

                Group {
                    DetailRawRow(title: "Record Type", value: recType, hex: "")
                    DetailRawRow(title: "Trip State", value: tripStateDisplay, hex: String(format: "0x%02X", tripState), color: .red)
                    DetailRawRow(title: "Timestamp", value: timestampDisplay, hex: record.subdata(in: 11..<18).hexString, color: .brown)
                    DetailRawRow(title: "Distance", value: "\(distM) m (\(Double(distM)/1000.0) km)", hex: record.subdata(in: 19..<21).hexString, color: .indigo)
                    DetailRawRow(title: "Fare", value: selectedAmount, hex: fareLayout?.selectedAmountHex ?? "", color: .orange)
                    DetailRawRow(title: "Station", value: stationAlias?.localizedDisplayName ?? stationToken, hex: stationToken, color: .cyan)
                    DetailRawRow(title: "Transport Mode", value: transportModeDisplay, hex: "\(transportModeHex) · \(transportModeCode)", color: .teal)
                }
            } else if data.count >= 33 {
                let type = data[0]
                let balance = data.bigEndianInt(start: 2, length: 4)
                let ntep = data.bigEndianInt(start: 6, length: 4)
                let fare = data.bigEndianInt(start: 10, length: 4)
                let idsam = data.subdata(in: 14..<22).hexString
                let ntsam = data.bigEndianInt(start: 22, length: 4)
                let bcdTime = data.subdata(in: 26..<33).hexString
                let logType = type == 0x02 ? "Top-up" : (fare == 0 ? "Entry" : "Payment / Trip")
                let currencyCode = brand.region.currencyCode
                
                Group {
                    DetailRawRow(title: "Log Type", value: logType, hex: String(format: "0x%02X", type), color: .red)
                    DetailRawRow(title: "Record Subtype", value: String(format: "0x%02X", data[1]), hex: "", color: .purple)
                    DetailRawRow(title: "New Balance", value: formatCurrency(amount: Decimal(balance), code: currencyCode), hex: data.subdata(in: 2..<6).hexString, color: .green)
                    DetailRawRow(title: "NTEP (Tx Number)", value: "\(ntep)", hex: data.subdata(in: 6..<10).hexString, color: .blue)
                    DetailRawRow(title: "Amount", value: formatCurrency(amount: Decimal(fare), code: currencyCode), hex: data.subdata(in: 10..<14).hexString, color: .orange)
                    DetailRawRow(title: "IDSAM (Terminal)", value: idsam, hex: "", color: .cyan)
                    DetailRawRow(title: "NTSAM (Terminal Count)", value: "\(ntsam)", hex: data.subdata(in: 22..<26).hexString, color: .indigo)
                    DetailRawRow(title: "BCD Timestamp", value: formatBCDDate(bcdTime), hex: bcdTime, color: .brown)
                    if data.count > 33 {
                        DetailRawRow(title: "Trailing Data", value: data.subdata(in: 33..<data.count).hexString, hex: "", color: .gray)
                    }
                }
            } else if data.count >= 18 {
                let cost = data.bigEndianInt(start: 10, length: 4)
                let balance = data.bigEndianInt(start: 14, length: 4)
                DetailRawRow(title: "Journey Cost", value: "₩\(cost)", hex: data.subdata(in: 10..<14).hexString, color: .orange)
                DetailRawRow(title: "Balance After", value: "₩\(balance)", hex: data.subdata(in: 14..<18).hexString, color: .green)
                if data.count >= 24 {
                    let km = Int(data[22]) * 256 + Int(data[23])
                    DetailRawRow(title: "Distance", value: "\(km) km", hex: data.subdata(in: 22..<24).hexString, color: .indigo)
                }
            }
        }
        .padding(.top, 4)
    }

    private func formatBCDDate(_ bcd: String) -> String {
        guard bcd.count >= 12 else { return bcd }
        if bcd.allSatisfy({ $0 == "0" }) {
            return "Not recorded"
        }
        return "\(bcd.prefix(4))-\(bcd.dropFirst(4).prefix(2))-\(bcd.dropFirst(6).prefix(2)) \(bcd.dropFirst(8).prefix(2)):\(bcd.dropFirst(10).prefix(2)):\(bcd.suffix(2))"
    }
}

struct TUnionRawBreakdownView: View {
    let raw: String
    let tx: TransitTransaction
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let details = TUnionTransactionRecordDetails(raw: raw, isCityUnion: tx.sourceCardFamily?.contains("City Union") == true) {
                let data = Data(hexString: raw)
                DetailRawRow(title: "Sequence", value: "\(details.sequence)", hex: data.subdata(in: 0..<2).hexString, color: .blue)
                DetailRawRow(title: "Overdraft Limit", value: details.overdraftLimitHex, hex: data.subdata(in: 2..<5).hexString, color: .purple)
                DetailRawRow(title: "Amount", value: details.signedAmountText, hex: data.subdata(in: 5..<9).hexString, color: .orange)
                DetailRawRow(title: "Transaction Type", value: details.typeDescription, hex: String(format: "%02X", details.typeByte), color: tx.iconInfo.color)
                DetailRawRow(title: "Terminal ID", value: details.terminalID, hex: data.subdata(in: 10..<16).hexString, color: .cyan)
                DetailRawRow(title: "Terminal City", value: details.cityDisplay, hex: details.cityID, color: .cyan)
                DetailRawRow(title: "Date", value: details.dateText, hex: data.subdata(in: 16..<20).hexString, color: .green)
                DetailRawRow(title: "Time", value: details.timeText, hex: data.subdata(in: 20..<23).hexString, color: .brown)
                Text("Transaction record file `SFI 0x18`, circular record, length `0x17`. The amount field stores the unsigned value in fen; the transaction type determines whether it is a debit or top-up. The first 2 terminal bytes identify the city.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let details = TUnionTravelRecordDetails(raw: raw) {
                let data = Data(hexString: raw)
                DetailRawRow(title: "Transaction Type", value: details.typeDescription, hex: String(format: "%02X", details.typeByte), color: .red)
                DetailRawRow(title: "Terminal ID", value: details.terminalID, hex: data.subdata(in: 1..<9).hexString, color: .cyan)
                DetailRawRow(title: "Sub Type", value: String(format: "0x%02X", details.subType), hex: data.subdata(in: 9..<10).hexString, color: .purple)
                DetailRawRow(title: "Station", value: details.stationDisplay, hex: data.subdata(in: 10..<17).hexString, color: .green)
                DetailRawRow(title: "Amount", value: details.signedAmountText, hex: data.subdata(in: 17..<21).hexString, color: .orange)
                DetailRawRow(title: "Balance After", value: details.balanceText, hex: data.subdata(in: 21..<25).hexString, color: .mint)
                DetailRawRow(title: "Timestamp", value: details.dateTimeText, hex: data.subdata(in: 25..<32).hexString, color: .brown)
                DetailRawRow(title: "City", value: details.cityDisplay, hex: data.subdata(in: 32..<34).hexString, color: .teal)
                Text("Transit activity record file `SFI 0x1E`, circular record, length `0x30`. Transit type and amount use separate colors here to distinguish travel category from fare value.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }
}

struct SuicaRawBreakdownView: View {
    let raw: String
    var tx: TransitTransaction? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let data = Data(hexString: raw)
            if data.count >= 16 {
                let console = data[0]
                let process = data[1]
                let payType = data[2]
                let ioType = data[3]
                
                let regionFull = Int(data[15])
                let r1 = (regionFull >> 6) & 0x03
                
                Group {
                    DetailRawRow(title: "Terminal", value: japaneseTerminal(console), hex: String(format: "0x%02X", console), color: .red)
                    DetailRawRow(title: "TX Type", value: japaneseProcess(process), hex: String(format: "0x%02X", process), color: tx?.iconInfo.color ?? .orange)
                    DetailRawRow(title: "Payment Type", value: paymentType(payType), hex: String(format: "0x%02X", payType), color: .purple)
                    DetailRawRow(title: "Entry/Exit", value: ioTypeStatus(ioType), hex: String(format: "0x%02X", ioType), color: .pink)
                }
                
                let rawDate = Int(data[4]) << 8 | Int(data[5])
                let dateStr = String(format: "%02d-%02d-%02d", (rawDate >> 9) & 0x7F, (rawDate >> 5) & 0x0F, rawDate & 0x1F)
                DetailRawRow(title: "Processing Date", value: "20\(dateStr)", hex: data.subdata(in: 4..<6).hexString, color: .orange)
                
                if console == 199 || console == 200 || process == 70 || process == 198 || process == 203 {
                    let timeData = Int(data[6]) << 8 | Int(data[7])
                    let hour = (timeData >> 11) & 0x1F
                    let minute = (timeData >> 5) & 0x3F
                    let second = (timeData & 0x1F) * 2
                    let timeStr = String(format: "%02d:%02d:%02d", hour, minute, second)
                    DetailRawRow(title: "Processing Time", value: timeStr, hex: data.subdata(in: 6..<8).hexString, color: .cyan)
                    
                    let shopTerm = data.subdata(in: 8..<10).hexString.uppercased()
                    DetailRawRow(title: "Vending Terminal ID", value: shopTerm, hex: shopTerm, color: .teal)
                } else {
                    let entryLow = Int(data[6]) << 8 | Int(data[7])
                    let exitLow = Int(data[8]) << 8 | Int(data[9])
                    
                    if process == 13 || process == 15 {
                        let operatorName = BusResolver.shared.resolve(entryLow) ?? "Bus Operator \(String(format: "%04X", entryLow))"
                        let stopName = exitLow == 0 ? "N/A" : "Station \(String(format: "%04X", exitLow))"
                        
                        DetailRawRow(title: "Bus Operator", value: operatorName, hex: String(format: "0x%04X", entryLow), color: .cyan)
                        DetailRawRow(title: "Bus Stop", value: stopName, hex: String(format: "0x%04X", exitLow), color: .teal)
                    } else {
                        let fullEntryCode = (r1 << 16) | entryLow
                        let fullExitCode = (r1 << 16) | exitLow
                        
                        let entryName = StationResolver.shared.resolve(fullEntryCode) ?? "Station \(String(format: "%X%04X", r1, entryLow))"
                        let exitName = StationResolver.shared.resolve(fullExitCode) ?? (exitLow == 0 ? nil : "Station \(String(format: "%X%04X", r1, exitLow))")
                        
                        DetailRawRow(title: "Entry Station", value: entryName, hex: String(format: "0x%04X", entryLow), color: .cyan)
                        if let exitName = exitName {
                            DetailRawRow(title: "Exit Station", value: exitName, hex: String(format: "0x%04X", exitLow), color: .teal)
                        }
                    }
                }
                
                DetailRawRow(title: "Balance (LE)", value: "¥\(Int(data[10]) | (Int(data[11]) << 8))", hex: data.subdata(in: 10..<12).hexString, color: .green)
                DetailRawRow(title: "Sequence", value: "\(data.bigEndianInt(start: 12, length: 3))", hex: data.subdata(in: 12..<15).hexString, color: .gray)
                DetailRawRow(title: "Region Code", value: "\(r1)", hex: String(format: "0x%02X", regionFull), color: .brown)
            }
        }
        .padding(.top, 4)
    }
    
    private func paymentType(_ type: UInt8) -> String {
        Localizer.localize(String(format: "pay_%02X", type))
    }
    
    private func ioTypeStatus(_ type: UInt8) -> String {
        Localizer.localize(String(format: "io_%02X", type))
    }
    
    // Copy-pasted helper from decoder for UI
    private func japaneseTerminal(_ console: UInt8) -> String {
        Localizer.localize("suica_terminal_\(console)")
    }
    private func japaneseProcess(_ process: UInt8) -> String {
        Localizer.localize("suica_process_\(process)")
    }
}

struct FeliCaTransitRawBreakdownView: View {
    let raw: String
    let tx: TransitTransaction?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let data = Data(hexString: raw)
            if data.count >= 16 {
                let activity = data[0]
                let subtype = data[1]
                let stationCode = data.subdata(in: 2..<4).hexString.uppercased()
                let deviceNumber = Int(data[4]) << 8 | Int(data[5])
                let rawDate = Int(data[6]) << 8 | Int(data[7])
                let year = 2000 + ((rawDate >> 9) & 0x7F)
                let month = (rawDate >> 5) & 0x0F
                let day = rawDate & 0x1F
                let hour = bcdByteToInt(data[8])
                let minute = bcdByteToInt(data[9])
                let amount = Int(data[10]) | (Int(data[11]) << 8)
                let passFare = Int(data[12]) | (Int(data[13]) << 8)
                let passLineCode = Int(data[14])
                let passStationCode = Int(data[15])
                let dateText = String(format: "%04d-%02d-%02d", year, month, day)
                let timeText = hour >= 0 && minute >= 0 ? String(format: "%02d:%02d", hour, minute) : "N/A"

                Group {
                    DetailRawRow(title: "Entry/Exit Type", value: transitActivityType(activity), hex: String(format: "0x%02X", activity), color: .red)
                    DetailRawRow(title: "Intermediate Gate / Discount Type", value: transitSubtypeDescription(subtype), hex: String(format: "0x%02X", subtype), color: .purple)
                    DetailRawRow(title: "Station Code", value: tx?.entryStation ?? tx?.exitStation ?? stationCode, hex: stationCode, color: .cyan)
                    DetailRawRow(title: "Device Number", value: "\(deviceNumber)", hex: data.subdata(in: 4..<6).hexString.uppercased(), color: .teal)
                    DetailRawRow(title: "Gate Date", value: dateText, hex: data.subdata(in: 6..<8).hexString.uppercased(), color: .orange)
                    DetailRawRow(title: "Gate Time", value: timeText, hex: data.subdata(in: 8..<10).hexString.uppercased(), color: .brown)
                    DetailRawRow(title: "Charge / Transfer / Receipt Amount", value: "¥\(amount)", hex: data.subdata(in: 10..<12).hexString.uppercased(), color: .green)
                    DetailRawRow(title: "Fare To Pass Boundary", value: passFare == 0 ? "None" : "¥\(passFare)", hex: data.subdata(in: 12..<14).hexString.uppercased(), color: .indigo)
                    DetailRawRow(title: "Pass Boundary Station", value: passLineCode == 0 && passStationCode == 0 ? "None" : String(format: "Line %02X / Station %02X", passLineCode, passStationCode), hex: data.subdata(in: 14..<16).hexString.uppercased(), color: .mint)
                }

                Text("FeliCa gate activity record layout for service `108F` (`8F10` little-endian on card I/O). Bytes `0-1` are activity/subtype, `2-3` station code, `4-5` device number, `6-7` packed date, `8-9` BCD time, `10-11` amount, `12-13` pass-boundary fare, and `14-15` pass-boundary station.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func transitActivityType(_ code: UInt8) -> String {
        switch code {
        case 0xA0: return "Entry"
        case 0xA2: return "Discount Entry"
        case 0x20: return "Exit"
        default: return String(format: "0x%02X", code)
        }
    }

    private func transitSubtypeDescription(_ code: UInt8) -> String {
        switch code {
        case 0x00: return "Standard"
        case 0x04: return "Discount"
        case 0x08: return "Transfer"
        default: return String(format: "0x%02X", code)
        }
    }

    private func bcdByteToInt(_ byte: UInt8) -> Int {
        let high = Int((byte >> 4) & 0x0F)
        let low = Int(byte & 0x0F)
        guard high < 10, low < 10 else { return -1 }
        return (high * 10) + low
    }
}

struct NanacoRawBreakdownView: View {
    let raw: String
    let tx: TransitTransaction?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let data = Data(hexString: raw)
            if data.count >= 16 {
                let type = data[0]
                let amount = data.bigEndianInt(start: 1, length: 4)
                let balance = data.bigEndianInt(start: 5, length: 4)
                let dateBits = UInt32(data.bigEndianInt(start: 9, length: 4))
                let sequence = data.bigEndianInt(start: 13, length: 2)

                let year = 2000 + Int((dateBits >> 21) & 0x7FF)
                let month = Int((dateBits >> 17) & 0x0F)
                let day = Int((dateBits >> 12) & 0x1F)
                let hour = Int((dateBits >> 6) & 0x3F)
                let minute = Int(dateBits & 0x3F)
                let timeText = String(format: "%04d-%02d-%02d %02d:%02d", year, month, day, hour, minute)

                Group {
                    DetailRawRow(title: "Transaction Type", value: nanacoTransactionTypeName(type), hex: String(format: "0x%02X", type), color: tx?.iconInfo.color ?? .red)
                    DetailRawRow(title: "Amount", value: formatCurrency(amount: Decimal(amount), code: "JPY"), hex: data.subdata(in: 1..<5).hexString.uppercased(), color: .orange)
                    DetailRawRow(title: "Balance After", value: formatCurrency(amount: Decimal(balance), code: "JPY"), hex: data.subdata(in: 5..<9).hexString.uppercased(), color: .green)
                    DetailRawRow(title: "Packed DateTime", value: timeText, hex: data.subdata(in: 9..<13).hexString.uppercased(), color: .brown)
                    DetailRawRow(title: "Sequence", value: "\(sequence)", hex: data.subdata(in: 13..<15).hexString.uppercased(), color: .blue)
                }

                Text("nanaco history record layout for service `564F` (`4F56` little-endian on card I/O). Byte `0` is the transaction type, bytes `1-4` the amount (BE), `5-8` the balance after (BE), `9-12` the packed date/time (BE), `13-14` the transaction number (BE), and `15` is reserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    private func nanacoTransactionTypeName(_ type: UInt8) -> String {
        switch type {
        case 0x47: return "Payment"
        case 0x6F, 0x70: return "Top-up"
        case 0x83: return "Points Redemption"
        case 0x35: return "Transfer"
        default: return String(format: "0x%02X", type)
        }
    }
}

struct WAONRawBreakdownView: View {
    let raw: String
    let tx: TransitTransaction?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let data = Data(hexString: raw)
            if data.count >= 29 {
                let terminalData = data.subdata(in: 0..<13)
                let terminal = formatUTF8OrHex(terminalData)
                let sequence = Int(data[13]) | (Int(data[14]) << 8)
                let type = data[17]
                let packed = data.subdata(in: 18..<29)

                let year = 2005 + Int(readMSBPackedBits(packed, offset: 0, length: 5))
                let month = Int(readMSBPackedBits(packed, offset: 5, length: 4))
                let day = Int(readMSBPackedBits(packed, offset: 9, length: 5))
                let hour = Int(readMSBPackedBits(packed, offset: 14, length: 5))
                let minute = Int(readMSBPackedBits(packed, offset: 19, length: 6))
                let balance = readMSBPackedBits(packed, offset: 25, length: 18)
                let usageAmount = readMSBPackedBits(packed, offset: 43, length: 18)
                let chargeAmount = readMSBPackedBits(packed, offset: 61, length: 17)
                let timeText = String(format: "%04d-%02d-%02d %02d:%02d", year, month, day, hour, minute)

                Group {
                    DetailRawRow(title: "Terminal", value: terminal, hex: terminalData.hexString.uppercased(), color: .cyan)
                    DetailRawRow(title: "Sequence", value: "\(sequence)", hex: data.subdata(in: 13..<15).hexString.uppercased(), color: .blue)
                    DetailRawRow(title: "Transaction Type", value: waonTransactionTypeName(type), hex: String(format: "0x%02X", type), color: tx?.iconInfo.color ?? .red)
                    DetailRawRow(title: "Packed DateTime", value: timeText, hex: packed.hexString.uppercased(), color: .brown)
                    DetailRawRow(title: "Balance After", value: formatCurrency(amount: Decimal(balance), code: "JPY"), hex: "bits 25-42", color: .green)
                    DetailRawRow(title: "Usage Amount", value: formatCurrency(amount: Decimal(usageAmount), code: "JPY"), hex: "bits 43-60", color: .orange)
                    DetailRawRow(title: "Charge Amount", value: formatCurrency(amount: Decimal(chargeAmount), code: "JPY"), hex: "bits 61-77", color: .mint)
                }

                Text("WAON history record layout for service `680B` (`0B68` little-endian on card I/O). Bytes `0-12` are the terminal number, `13-14` are the record number, byte `17` is the transaction type, and bytes `18-28` contain MSB-first packed date, balance, usage amount, and charge amount fields.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    private func readMSBPackedBits(_ data: Data, offset: Int, length: Int) -> UInt32 {
        var value: UInt32 = 0
        for bitIndex in offset..<(offset + length) {
            let byte = data[bitIndex / 8]
            let bit = (byte >> UInt8(7 - (bitIndex % 8))) & 0x01
            value = (value << 1) | UInt32(bit)
        }
        return value
    }

    private func waonTransactionTypeName(_ type: UInt8) -> String {
        switch type {
        case 0x04: return "Payment"
        case 0x0C, 0x10: return "Top-up"
        default: return String(format: "0x%02X", type)
        }
    }
}

struct EdyRawBreakdownView: View {
    let raw: String
    let tx: TransitTransaction?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let data = Data(hexString: raw)
            if data.count >= 16 {
                let type = data[0]
                let unknown = data[1]
                let sequence = data.bigEndianInt(start: 2, length: 2)
                let dateBits = UInt32(data.bigEndianInt(start: 4, length: 4))
                let amount = UInt32(data.bigEndianInt(start: 8, length: 4))
                let balance = UInt32(data.bigEndianInt(start: 12, length: 4))

                let elapsedDays = Int(dateBits >> 17)
                let elapsedSeconds = Int(dateBits & 0x1FFFF)
                let hour = elapsedSeconds / 3600
                let minute = (elapsedSeconds % 3600) / 60
                let second = elapsedSeconds % 60

                let calendar = Calendar(identifier: .gregorian)
                let dateText: String = {
                    var base = DateComponents()
                    base.year = 2000
                    base.month = 1
                    base.day = 1
                    base.timeZone = TimeZone(identifier: "Asia/Tokyo")

                    if let start = calendar.date(from: base),
                       let dayDate = calendar.date(byAdding: .day, value: elapsedDays, to: start) {
                        let c = calendar.dateComponents([.year, .month, .day], from: dayDate)
                        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, hour, minute, second)
                    }

                    return "day+\(elapsedDays) \(String(format: "%02d:%02d:%02d", hour, minute, second))"
                }()

                Group {
                    DetailRawRow(title: "Transaction Type", value: edyTransactionTypeName(type), hex: String(format: "0x%02X", type), color: tx?.iconInfo.color ?? .red)
                    DetailRawRow(title: "Unknown", value: String(format: "0x%02X", unknown), hex: data.subdata(in: 1..<2).hexString.uppercased(), color: .gray)
                    DetailRawRow(title: "Sequence", value: "\(sequence)", hex: data.subdata(in: 2..<4).hexString.uppercased(), color: .blue)
                    DetailRawRow(title: "Packed DateTime", value: dateText, hex: data.subdata(in: 4..<8).hexString.uppercased(), color: .brown)
                    DetailRawRow(title: "Amount", value: formatCurrency(amount: Decimal(amount), code: "JPY"), hex: data.subdata(in: 8..<12).hexString.uppercased(), color: .orange)
                    DetailRawRow(title: "Balance After", value: formatCurrency(amount: Decimal(balance), code: "JPY"), hex: data.subdata(in: 12..<16).hexString.uppercased(), color: .green)
                }

                Text("Edy history record layout for service `170F` (sent to the tag as bytes `17 0F`). Byte `0` is transaction type, byte `1` unknown, `2-3` transaction number (BE), `4-7` packed date/time (BE: 15-bit elapsed days since 2000-01-01 plus 17-bit seconds since midnight), `8-11` amount (BE), and `12-15` balance after (BE).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    private func edyTransactionTypeName(_ type: UInt8) -> String {
        switch type {
        case 0x20: return "Payment"
        case 0x02: return "Top-up"
        case 0x04: return "Edy Gift"
        default: return String(format: "0x%02X", type)
        }
    }
}

struct DetailRawRow: View {
    let title: String
    let value: String
    let hex: String
    var color: Color? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let color = color {
                    Circle().fill(color).frame(width: 8, height: 8)
                }
                Text(Localizer.localize(title)).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(Localizer.localize(value))
                if !hex.isEmpty {
                    Text("[\(hex)]").font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

private struct TUnionTransactionRecordDetails {
    let sequence: Int
    let overdraftLimitHex: String
    let amountCents: Int
    let typeByte: UInt8
    let terminalID: String
    let dateText: String
    let timeText: String
    let cityID: String
    let cityName: String?
    
    init?(raw: String, isCityUnion: Bool = false) {
        let data = Data(hexString: raw)
        guard data.count == 23 else { return nil }
        sequence = data.bigEndianInt(start: 0, length: 2)
        overdraftLimitHex = data.subdata(in: 2..<5).hexString.uppercased()
        amountCents = data.bigEndianInt(start: 5, length: 4)
        typeByte = data[9]
        terminalID = data.subdata(in: 10..<16).hexString.uppercased()
        let dateBCD = data.subdata(in: 16..<20).hexString.uppercased()
        let timeBCD = data.subdata(in: 20..<23).hexString.uppercased()
        dateText = "\(dateBCD.prefix(4))-\(dateBCD.dropFirst(4).prefix(2))-\(dateBCD.suffix(2))"
        timeText = "\(timeBCD.prefix(2)):\(timeBCD.dropFirst(2).prefix(2)):\(timeBCD.suffix(2))"
        let terminalStation = !isCityUnion && (typeByte == 0x06 || typeByte == 0x09)
            ? TUnionCityDatabase.lookupTerminalStation(recordKind: "18", terminalID: terminalID)
            : nil
        cityID = terminalStation?.cityID ?? String(terminalID.prefix(4))
        cityName = isCityUnion ? CityUnionStationDatabase.cityName(cityID) : TUnionCityDatabase.lookupCityName(for: cityID)
    }
    
    var cityDisplay: String {
        cityName.map { "\($0) (\(cityID))" } ?? cityID
    }
    
    var typeDescription: String {
        switch typeByte {
        case 0x06: return "Consumption"
        case 0x09: return "Composite Consumption"
        case 0x02: return "Top-up"
        default: return String(format: "0x%02X", typeByte)
        }
    }

    var signedAmountText: String {
        let amount = Decimal(amountCents) / 100
        let sign = typeByte == 0x02 ? "+" : "-"
        return sign + formatCurrency(amount: amount, code: "CNY", fractionDigits: 2)
    }
}

private struct TUnionTravelRecordDetails {
    let typeByte: UInt8
    let terminalID: String
    let subType: UInt8
    let stationID: String
    let stationName: String?
    let amountCents: Int
    let balanceCents: Int
    let dateTimeText: String
    let cityID: String
    let cityName: String?

    init?(raw: String) {
        let data = Data(hexString: raw)
        guard data.count >= 48 else { return nil }
        typeByte = data[0]
        terminalID = data.subdata(in: 1..<9).hexString.uppercased()
        subType = data[9]
        stationID = data.subdata(in: 10..<17).hexString.uppercased()
        amountCents = Int(UInt32(bigEndian: data.subdata(in: 17..<21).withUnsafeBytes { $0.load(as: UInt32.self) }))
        balanceCents = Int(UInt32(bigEndian: data.subdata(in: 21..<25).withUnsafeBytes { $0.load(as: UInt32.self) }))
        let dateBCD = data.subdata(in: 25..<32).hexString.uppercased()
        dateTimeText = "\(dateBCD.prefix(4))-\(dateBCD.dropFirst(4).prefix(2))-\(dateBCD.dropFirst(6).prefix(2)) \(dateBCD.dropFirst(8).prefix(2)):\(dateBCD.dropFirst(10).prefix(2)):\(dateBCD.suffix(2))"
        cityID = data.subdata(in: 32..<34).hexString.uppercased()
        cityName = TUnionCityDatabase.lookupCityName(for: cityID)
        stationName = TUnionCityDatabase.lookupTravelStation(
            cityID: cityID, stationID: stationID, terminalID: terminalID
        )?.name
    }

    var typeDescription: String {
        switch typeByte {
        case 0x03: return subType == 0x02 ? "Bus Boarding" : "Entry"
        case 0x04: return subType == 0x02 ? "Bus Exit" : "Exit"
        case 0x02, 0x06: return subType == 0x02 ? "Bus Trip" : "Transit Trip"
        default: return String(format: "0x%02X", typeByte)
        }
    }

    var stationDisplay: String {
        stationName.map { "\($0) (\(stationID))" } ?? stationID
    }

    var cityDisplay: String {
        cityName.map { "\($0) (\(cityID))" } ?? cityID
    }

    var signedAmountText: String {
        "-" + formatCurrency(amount: Decimal(amountCents) / 100, code: "CNY", fractionDigits: 2)
    }

    var balanceText: String {
        formatCurrency(amount: Decimal(balanceCents) / 100, code: "CNY", fractionDigits: 2)
    }
}

// octopusOffset moved to end of file
// formatFeliCaIDm moved to end of file

extension Data {
    var hexString: String { map { String(format: "%02X", $0) }.joined() }
    
    init(hexString: String) {
        var data = Data()
        // Strip everything except hex digits
        let hexDigits = hexString.replacingOccurrences(of: "[^0-9A-Fa-f]", with: "", options: .regularExpression)
        var text = hexDigits
        if text.count % 2 != 0 { text = "0" + text }
        
        var index = text.startIndex
        while index < text.endIndex {
            let nextIndex = text.index(index, offsetBy: 2)
            if let byte = UInt8(text[index..<nextIndex], radix: 16) {
                data.append(byte)
            }
            index = nextIndex
        }
        self = data
    }
    
    func sliceHexString(start: Int, length: Int) -> String {
        guard start >= 0, length > 0, count >= start + length else { return "Unavailable" }
        return self[start..<(start + length)].map { String(format: "%02X", $0) }.joined()
    }
    
    func bigEndianInt(start: Int, length: Int) -> Int {
        guard start >= 0, length > 0, count >= start + length else { return 0 }
        return self[start..<(start + length)].reduce(0) { ($0 << 8) | Int($1) }
    }
    
    var systemCodeCandidates: [String] {
        guard count >= 1 else { return [] }
        let count = Int(self[0])
        var candidates: [String] = []
        for i in 0..<count {
            let start = 1 + (i * 2)
            guard self.count >= start + 2 else { break }
            candidates.append(self[start..<(start+2)].hexString.uppercased())
        }
        return candidates
    }
}


struct BERTLVNode {
    let tag: [UInt8]
    let value: Data
    var isConstructed: Bool {
        guard let first = tag.first else { return false }
        return (first & 0x20) != 0
    }
}

func findTLVValue(tag targetTag: [UInt8], in data: Data) -> Data? {
    parseBERTLVs(in: data).lazy.compactMap { node -> Data? in
        if node.tag == targetTag { return node.value }
        if node.isConstructed { return findTLVValue(tag: targetTag, in: node.value) }
        return nil
    }.first
}

func parseBERTLVs(in data: Data) -> [BERTLVNode] {
    var nodes: [BERTLVNode] = []
    var index = data.startIndex
    while index < data.endIndex {
        let tagStart = index
        index = data.index(after: index)
        if data[tagStart] & 0x1F == 0x1F {
            while index < data.endIndex {
                let byte = data[index]
                index = data.index(after: index)
                if byte & 0x80 == 0 { break }
            }
        }
        let tagEnd = index
        guard index < data.endIndex else { break }
        let firstLengthByte = data[index]
        index = data.index(after: index)
        let length: Int
        if firstLengthByte & 0x80 == 0 {
            length = Int(firstLengthByte)
        } else {
            let byteCount = Int(firstLengthByte & 0x7F)
            guard byteCount > 0, data.distance(from: index, to: data.endIndex) >= byteCount else { break }
            var accumulated = 0
            for _ in 0..<byteCount {
                accumulated = (accumulated << 8) | Int(data[index]); index = data.index(after: index)
            }
            length = accumulated
        }
        guard length >= 0, data.distance(from: index, to: data.endIndex) >= length else { break }
        let valueEnd = data.index(index, offsetBy: length)
        nodes.append(BERTLVNode(tag: Array(data[tagStart..<tagEnd]), value: Data(data[index..<valueEnd])))
        index = valueEnd
    }
    return nodes
}

extension String {
    func binaryDecimalString() -> String { String(Int(self, radix: 2) ?? 0) }
}

func formatCurrency(amount: Decimal, code: String, fractionDigits: Int = 0) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = code
    if code == "MNT" {
        formatter.currencySymbol = "\u{20AE}"
    }
    formatter.minimumFractionDigits = fractionDigits
    formatter.maximumFractionDigits = fractionDigits
    return formatter.string(from: amount as NSDecimalNumber) ?? "\(code) \(amount)"
}

func formatUTF8OrHex(_ data: Data) -> String {
    if let text = String(data: data, encoding: .utf8), !text.isEmpty {
        return text
    }
    return data.hexString.uppercased()
}

func defaultFractionDigits(for currencyCode: String) -> Int {
    switch currencyCode {
        case "JPY", "KRW", "MNT", "IDR":
        return 0
    case "HKD":
        return 1
    case "CNY":
        return 2
    default:
        return 2
    }
}

func octopusOffset(for date: Date) -> Int {
    // Public purse units are HK$0.10; the public reference uses the scan date
    // for the 2017-10-01 Hong Kong offset transition (350 -> 500 units).
    date >= Date(timeIntervalSince1970: 1_506_787_200) ? 500 : 350
}

func formatFeliCaIDm(_ idm: String) -> String {
    let clean = idm.uppercased()
    guard clean.count == 16 else { return clean }
    return stride(from: 0, to: 16, by: 4).map { index in
        let start = clean.index(clean.startIndex, offsetBy: index)
        let end = clean.index(start, offsetBy: 4)
        return String(clean[start..<end])
    }.joined(separator: " ")
}

func formatFeliCaIDi(_ data: Data) -> String {
    guard data.count >= 8 else { return data.hexString }

    let issuerHex = data.subdata(in: 0..<2).hexString.uppercased()
    let remainder = data.subdata(in: 2..<4).hexString.uppercased()
    let issuer: String
    switch issuerHex {
    case "0102": issuer = "JH"
    case "0103": issuer = "JE"
    case "0104": issuer = "JC"
    case "0105": issuer = "JW"
    case "0107": issuer = "JK"
    case "0252": issuer = "PB"
    case "0387": issuer = "TP"
    case "04AD": issuer = "SU"
    case "05D5": issuer = "NR"
    case "05D7": issuer = "FC"
    default: issuer = issuerHex
    }

    let value = (Int(data[4]) << 8) | Int(data[5])
    let datePart = String(format: "%02d%02d%02d", (value >> 9) & 0x3F, (value >> 5) & 0x0F, value & 0x1F)
    let tail = String(format: "%05d", (Int(data[6]) << 8) | Int(data[7]))
    return "\(issuer)\(remainder)\(datePart)\(tail)"
}

struct CardRawDataHighlightView: View {
    let raw: String
    var tx: TransitTransaction? = nil
    let cardFamily: String
    @State private var copied = false
    
    var body: some View {
        let data = Data(hexString: raw)
        let highlights = getHighlights(for: cardFamily, tx: tx, dataCount: data.count)
        
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<((data.count + 7) / 8), id: \.self) { row in
                HStack(spacing: 0) {
                    Text(String(format: "0x%02X ", row * 8))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 6)
                    
                    ForEach(0..<8, id: \.self) { col in
                        let index = row * 8 + col
                        if index < data.count {
                            let byte = data[index]
                            let color = highlights.first { $0.range.contains(index) }?.color ?? .primary
                            Text(String(format: "%02X", byte))
                                .font(.system(.body, design: .monospaced).bold())
                                .foregroundStyle(color)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(color.opacity(0.12))
                        } else {
                            Text("  ").padding(.horizontal, 4)
                        }
                    }
                }
            }
        }
        .frame(
            minWidth: 0,
            maxWidth: .infinity,
            minHeight: 0,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .padding(.vertical, 8)
        .overlay(alignment: .topTrailing) {
            Button {
                UIPasteboard.general.string = raw
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .bold))
                    if copied {
                        Text("Copied").font(.system(size: 10, weight: .bold)).transition(.opacity)
                    }
                }
                .foregroundStyle(copied ? .white : .primary.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(copied ? Color.green : Color(uiColor: .tertiarySystemFill), in: Capsule())
            }
            .offset(x: 0, y: 0)
        }
    }
    
    struct Highlight {
        let range: Range<Int>
        let color: Color
        let label: String
    }
    
    private func getHighlights(for family: String, tx: TransitTransaction? = nil, dataCount: Int = 0) -> [Highlight] {
        let brand = ICCardBrand.from(family: family)
        
        if brand.isKorean {
            if dataCount >= 52 {
                return [
                    Highlight(range: 2..<3, color: .red, label: "Trip State"),
                    Highlight(range: 5..<9, color: .cyan, label: "Station Token"),
                    Highlight(range: 9..<11, color: .teal, label: "KOTRIS Transport Mode"),
                    Highlight(range: 11..<18, color: .brown, label: "Timestamp"),
                    Highlight(range: 18..<19, color: .gray, label: "Unknown"),
                    Highlight(range: 19..<21, color: .indigo, label: "Distance")
                ]
            } else if dataCount >= 14 {
                return [
                    Highlight(range: 0..<1, color: .red, label: "Type"),
                    Highlight(range: 2..<6, color: .green, label: "Balance After"),
                    Highlight(range: 6..<10, color: .blue, label: "NTEP (Counter)"),
                    Highlight(range: 10..<14, color: .orange, label: "Fare / Cost"),
                    Highlight(range: 14..<min(22, dataCount), color: .cyan, label: "IDSAM (Terminal)"),
                    Highlight(range: 22..<min(26, dataCount), color: .indigo, label: "NTSAM (Terminal Counter)"),
                    Highlight(range: 26..<min(33, dataCount), color: .brown, label: "Timestamp (BCD)")
                ]
            }
        }
        
        if brand == .waon && dataCount >= 29 {
            return [
                Highlight(range: 0..<13, color: .cyan, label: "Terminal"),
                Highlight(range: 13..<15, color: .blue, label: "Sequence"),
                Highlight(range: 15..<17, color: .gray, label: "Unknown"),
                Highlight(range: 17..<18, color: tx?.iconInfo.color ?? .red, label: "Transaction Type"),
                Highlight(range: 18..<21, color: .brown, label: "Packed DateTime"),
                Highlight(range: 21..<24, color: .green, label: "Balance After"),
                Highlight(range: 24..<26, color: .orange, label: "Usage Amount"),
                Highlight(range: 26..<29, color: .mint, label: "Charge Amount")
            ]
        }

        if brand.isJapan && dataCount == 16 {
            if brand == .edy {
                return [
                    Highlight(range: 0..<1, color: tx?.iconInfo.color ?? .red, label: "Transaction Type"),
                    Highlight(range: 1..<2, color: .gray, label: "Unknown"),
                    Highlight(range: 2..<4, color: .blue, label: "Sequence"),
                    Highlight(range: 4..<8, color: .brown, label: "Packed DateTime"),
                    Highlight(range: 8..<12, color: .orange, label: "Amount"),
                    Highlight(range: 12..<16, color: .green, label: "Balance After")
                ]
            }
            if brand == .nanaco {
                return [
                    Highlight(range: 0..<1, color: tx?.iconInfo.color ?? .red, label: "Transaction Type"),
                    Highlight(range: 1..<5, color: .orange, label: "Amount"),
                    Highlight(range: 5..<9, color: .green, label: "Balance After"),
                    Highlight(range: 9..<13, color: .brown, label: "Packed DateTime"),
                    Highlight(range: 13..<15, color: .blue, label: "Sequence"),
                    Highlight(range: 15..<16, color: .gray, label: "Reserved")
                ]
            }
            let isPurchase = tx?.category == .purchase
            return [
                Highlight(range: 0..<1, color: .red, label: "Terminal"),
                Highlight(range: 1..<2, color: tx?.iconInfo.color ?? .blue, label: "TX Type"),
                Highlight(range: 2..<3, color: .purple, label: "Payment Type"),
                Highlight(range: 3..<4, color: .pink, label: "Entry/Exit"),
                Highlight(range: 4..<6, color: .orange, label: "Processing Date"),
                Highlight(range: 6..<8, color: .cyan, label: isPurchase ? "Processing Time" : "Entry Station"),
                Highlight(range: 8..<10, color: .teal, label: isPurchase ? "Vending Terminal ID" : "Exit Station"),
                Highlight(range: 10..<12, color: .green, label: "Balance (LE)"),
                Highlight(range: 12..<15, color: .gray, label: "Sequence"),
                Highlight(range: 15..<16, color: .brown, label: "Region Code")
            ]
        }

        if brand == .tUnion && dataCount == 23 {
            return [
                Highlight(range: 0..<2, color: .blue, label: "Sequence"),
                Highlight(range: 2..<5, color: .purple, label: "Overdraft Limit"),
                Highlight(range: 5..<9, color: .orange, label: "Amount"),
                Highlight(range: 9..<10, color: tx?.iconInfo.color ?? .red, label: "Transaction Type"),
                Highlight(range: 10..<16, color: .cyan, label: "Terminal ID"),
                Highlight(range: 16..<20, color: .green, label: "Date"),
                Highlight(range: 20..<23, color: .brown, label: "Time")
            ]
        }

        if brand == .tUnion && dataCount >= 48 {
            return [
                Highlight(range: 0..<1, color: .red, label: "TX Type"),
                Highlight(range: 1..<9, color: .cyan, label: "Terminal ID"),
                Highlight(range: 9..<10, color: .purple, label: "Sub Type"),
                Highlight(range: 10..<17, color: .green, label: "Station"),
                Highlight(range: 17..<21, color: .orange, label: "Amount"),
                Highlight(range: 21..<25, color: .mint, label: "Balance After"),
                Highlight(range: 25..<32, color: .brown, label: "Timestamp"),
                Highlight(range: 32..<34, color: .teal, label: "City")
            ]
        }
        
        return []
    }
}
