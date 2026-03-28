import SwiftUI
import UniformTypeIdentifiers

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
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    static let white = SavedCardColor(red: 1, green: 1, blue: 1)
    static let black = SavedCardColor(red: 0, green: 0, blue: 0)
}

enum SavedCardDesign: String, Codable, CaseIterable, Identifiable {
    case classic, sunrise
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: return "Classic"
        case .sunrise: return "Sunrise"
        }
    }
}

enum ImageFaceEnhancer: String, Codable, CaseIterable, Identifiable {
    case mask, border, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mask: return "Mask"
        case .border: return "Text Border/Shadow"
        case .none: return "None"
        }
    }
}

enum SavedCardMarkerShape: String, Codable, CaseIterable, Identifiable {
    case circle, square
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
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
    var isUsingImage: Bool?
    var hideTitleOnImage: Bool?
    var hideSerialNumber: Bool?
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
    var pmm: String?
    var selectedAID: String?
    var systemCode: String?
    var balanceText: String?
    var balanceDetail: String?
    var realSerialNumber: String?
    var region: String?
    var enhancedFeliCaDecoded: Bool?
    var issuingCity: String?
    var cardTypeStr: String?
    var issueDateStr: String?
    var expiryDateStr: String?
    var rawTransactions: [String] // Hex strings
    var rawTransitHistory: [String] // Hex strings
    var resultFields: [SavedCardField]
    var scannedAt: Date
    var color: SavedCardColor
    var design: SavedCardDesign
    var faceImageFileName: String?
    var order: Int
    var isPinned: Bool?

    enum CodingKeys: String, CodingKey {
        case id, cardFamily, markerSymbolName, markerColor, markerOuterColor, markerShape
        case customTitle, customDisplaySerialNumber, isUsingImage, hideTitleOnImage, hideSerialNumber
        case imageFaceEnhancer, autoImageTextColors, autoTitleTextColor, autoBalanceTextColor
        case titleTextColorOverride, balanceTextColorOverride, technology, identifierLabel
        case rawIdentifierValue, identifierValue, pmm, selectedAID, systemCode, balanceText
        case balanceDetail, realSerialNumber, region, enhancedFeliCaDecoded, issuingCity
        case cardTypeStr, issueDateStr, expiryDateStr, rawTransactions, rawTransitHistory
        case resultFields, scannedAt, color, design, faceImageFileName, order, isPinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        cardFamily = try container.decode(String.self, forKey: .cardFamily)
        markerSymbolName = try container.decodeIfPresent(String.self, forKey: .markerSymbolName)
        markerColor = try container.decode(SavedCardColor.self, forKey: .markerColor)
        markerOuterColor = try container.decode(SavedCardColor.self, forKey: .markerOuterColor)
        markerShape = try container.decode(SavedCardMarkerShape.self, forKey: .markerShape)
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        customDisplaySerialNumber = try container.decodeIfPresent(String.self, forKey: .customDisplaySerialNumber)
        isUsingImage = try container.decodeIfPresent(Bool.self, forKey: .isUsingImage)
        hideTitleOnImage = try container.decodeIfPresent(Bool.self, forKey: .hideTitleOnImage)
        hideSerialNumber = try container.decodeIfPresent(Bool.self, forKey: .hideSerialNumber)
        imageFaceEnhancer = try container.decode(ImageFaceEnhancer.self, forKey: .imageFaceEnhancer)
        autoImageTextColors = try container.decode(Bool.self, forKey: .autoImageTextColors)
        autoTitleTextColor = try container.decodeIfPresent(SavedCardColor.self, forKey: .autoTitleTextColor)
        autoBalanceTextColor = try container.decodeIfPresent(SavedCardColor.self, forKey: .autoBalanceTextColor)
        titleTextColorOverride = try container.decodeIfPresent(SavedCardColor.self, forKey: .titleTextColorOverride)
        balanceTextColorOverride = try container.decodeIfPresent(SavedCardColor.self, forKey: .balanceTextColorOverride)
        technology = try container.decode(String.self, forKey: .technology)
        identifierLabel = try container.decode(String.self, forKey: .identifierLabel)
        rawIdentifierValue = try container.decode(String.self, forKey: .rawIdentifierValue)
        identifierValue = try container.decode(String.self, forKey: .identifierValue)
        pmm = try container.decodeIfPresent(String.self, forKey: .pmm)
        selectedAID = try container.decodeIfPresent(String.self, forKey: .selectedAID)
        systemCode = try container.decodeIfPresent(String.self, forKey: .systemCode)
        balanceText = try container.decodeIfPresent(String.self, forKey: .balanceText)
        balanceDetail = try container.decodeIfPresent(String.self, forKey: .balanceDetail)
        realSerialNumber = try container.decodeIfPresent(String.self, forKey: .realSerialNumber)
        region = try container.decodeIfPresent(String.self, forKey: .region)
        enhancedFeliCaDecoded = try container.decodeIfPresent(Bool.self, forKey: .enhancedFeliCaDecoded)
        issuingCity = try container.decodeIfPresent(String.self, forKey: .issuingCity)
        cardTypeStr = try container.decodeIfPresent(String.self, forKey: .cardTypeStr)
        issueDateStr = try container.decodeIfPresent(String.self, forKey: .issueDateStr)
        expiryDateStr = try container.decodeIfPresent(String.self, forKey: .expiryDateStr)
        rawTransactions = try container.decode([String].self, forKey: .rawTransactions)
        rawTransitHistory = try container.decode([String].self, forKey: .rawTransitHistory)
        resultFields = try container.decode([SavedCardField].self, forKey: .resultFields)
        scannedAt = try container.decode(Date.self, forKey: .scannedAt)
        color = try container.decode(SavedCardColor.self, forKey: .color)
        design = try container.decode(SavedCardDesign.self, forKey: .design)
        faceImageFileName = try container.decodeIfPresent(String.self, forKey: .faceImageFileName)
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned)
    }


    var transactions: [TransitTransaction] {
        rawTransactions.enumerated().compactMap { idx, hex in
            TransactionDecoderRegistry.decode(raw: hex, family: cardFamily, technology: technology, context: rawTransactions, at: idx)
        }
    }

    var transitHistory: [TransitTransaction] {
        rawTransitHistory.enumerated().compactMap { idx, hex in
            TransactionDecoderRegistry.decode(raw: hex, family: cardFamily, technology: technology, context: rawTransitHistory, at: idx)
        }
    }

    var unifiedRecentTransactions: [TransitTransaction] {
        sortTransactionsByRecency(transactions)
    }

    var brand: String { cardFamily }

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
        if !trimmed.isEmpty { return trimmed }
        return region ?? cardFamily
    }

    var visibleBalance: String {
        if let balanceText, !balanceText.isEmpty { return balanceText }
        if let trips = fieldValue("Remaining Trips") { return "\(trips) trips" }
        return ""
    }

    var cardNumber: String? { 
        // For FeliCa, prefer the linked physical SN over the technical IDm
        realSerialNumber ?? fieldValue("Card Number") ?? identifierValue 
    }

    var finalIsUsingImage: Bool { isUsingImage ?? (faceImageFileName != nil) }
    var finalHideTitle: Bool { hideTitleOnImage ?? false }
    var finalHideSN: Bool { hideSerialNumber ?? false }

    var displayedSerialNumber: String {
        let raw: String
        let trimmed = customDisplaySerialNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        raw = !trimmed.isEmpty ? trimmed : (cardNumber ?? identifierValue)

        if technology == "FeliCa" {
            let formatted = Self.formattedFeliCaSerial(raw, cardFamily: cardFamily)
            return formatted.isEmpty ? raw : formatted
        }
        return raw
    }

    func privacyFormattedSerialNumber(mode: Int) -> String {
        // mode 0: Full, 1: Last digits, 2: Hidden
        if mode == 2 { return "" }
        let full = displayedSerialNumber
        if mode == 0 { return full }
        
        let digitsOnly = full.filter { "0123456789".contains($0) }
        let alphanumerics = full.filter { $0.isLetter || $0.isNumber }
        
        if cardFamily == "Octopus" {
             // Octopus example: 1234 5678 (Y) -> 5678
             if digitsOnly.count >= 8 {
                 let start = digitsOnly.index(digitsOnly.startIndex, offsetBy: 4)
                 let end = digitsOnly.index(start, offsetBy: 4)
                 return String(digitsOnly[start..<end])
             }
             return String(digitsOnly.suffix(4))
        } else if cardFamily == "Lignes d'Azur card" {
            return String(alphanumerics.suffix(3))
        } else {
            return String(alphanumerics.suffix(4))
        }
    }

    func fieldValue(_ title: String) -> String? {
        resultFields.first(where: { $0.title == title })?.value
    }

    static func formattedFeliCaSerial(_ raw: String, cardFamily: String) -> String {
        let normalized = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        guard !normalized.isEmpty else { return "" }
        
        // Octopus special formatting: 1234 5678 (9)
        if cardFamily == "Octopus" {
            if normalized.count == 9 {
                 return "\(normalized.prefix(4)) \(normalized.dropFirst(4).prefix(4)) (\(normalized.suffix(1)))"
            } else if normalized.count == 8 {
                 return "\(normalized.prefix(4)) \(normalized.suffix(4))"
            }
        }

        // 17-digit FeliCa specialized formatting: 5-4-4-4 (Standard for Suica/Pasmo)
        if normalized.count == 17 {
            let first = String(normalized.prefix(5))
            var remainder = normalized.dropFirst(5)
            var groups = [first]
            while !remainder.isEmpty {
                let count = min(4, remainder.count)
                groups.append(String(remainder.prefix(count)))
                remainder.removeFirst(count)
            }
            return groups.joined(separator: " ")
        }

        var groups: [String] = []
        var remainder = normalized
        while !remainder.isEmpty {
            let count = min(4, remainder.count)
            groups.append(String(remainder.prefix(count)))
            remainder.removeFirst(count)
        }
        return groups.joined(separator: " ")
    }
}

extension SavedCardRecord {
    init(snapshot: TransitCardSnapshot) {
        self.id = snapshot.storageIdentifier
        self.cardFamily = snapshot.cardFamily
        self.markerSymbolName = nil
        self.markerColor = .black
        self.markerOuterColor = .white
        self.markerShape = .circle
        self.customTitle = nil
        self.customDisplaySerialNumber = nil
        self.isUsingImage = nil
        self.hideTitleOnImage = nil
        self.hideSerialNumber = nil
        self.imageFaceEnhancer = .mask
        self.autoImageTextColors = true
        self.autoTitleTextColor = nil
        self.autoBalanceTextColor = nil
        self.titleTextColorOverride = nil
        self.balanceTextColorOverride = nil
        self.technology = snapshot.technology
        self.identifierLabel = snapshot.identifierLabel
        self.rawIdentifierValue = snapshot.rawIdentifierValue
        self.identifierValue = snapshot.identifierValue
        self.pmm = snapshot.pmm
        self.selectedAID = snapshot.selectedAID
        self.systemCode = snapshot.systemCode
        self.balanceText = snapshot.balanceText
        self.balanceDetail = snapshot.balanceDetail
        self.realSerialNumber = snapshot.realSerialNumber
        self.region = snapshot.resultFields.first(where: { $0.title == "Region" })?.value
        self.enhancedFeliCaDecoded = false
        self.issuingCity = snapshot.resultFields.first(where: {$0.title == "Issuing City"})?.value
        self.cardTypeStr = snapshot.resultFields.first(where: {$0.title == "Card Type"})?.value
        self.issueDateStr = snapshot.resultFields.first(where: {$0.title == "Issue Date"})?.value
        self.expiryDateStr = snapshot.resultFields.first(where: {$0.title == "Expiry Date"})?.value
        self.rawTransactions = snapshot.rawTransactions
        self.rawTransitHistory = snapshot.rawTransitHistory
        self.resultFields = snapshot.resultFields.map(SavedCardField.init)
        self.scannedAt = snapshot.scannedAt
        self.color = Self.defaultColor(for: snapshot.cardFamily)
        self.design = .classic
        self.faceImageFileName = nil
        self.order = 0
        self.isPinned = nil
    }

    private static func defaultColor(for family: String) -> SavedCardColor {
        let f = family.lowercased()
        if f.contains("suica") { return SavedCardColor(red: 0.1, green: 0.58, blue: 0.12) } // Suica Green
        if f.contains("pasmo") { return SavedCardColor(red: 0.88, green: 0.28, blue: 0.44) } // PASMO Pink
        if f.contains("icoca") { return SavedCardColor(red: 0.0, green: 0.48, blue: 0.72) } // ICOCA Blue
        if f.contains("hayakaken") { return SavedCardColor(red: 0.0, green: 0.68, blue: 0.94) } // Hayakaken Cyan
        if f.contains("sugoca") { return SavedCardColor(red: 0.82, green: 0.1, blue: 0.12) } // SUGOCA Red
        if f.contains("manaca") { return SavedCardColor(red: 0.96, green: 0.53, blue: 0.14) } // Manaca Orange/Yellow
        if f.contains("t-money") || f.contains("ezl") { return SavedCardColor(red: 0.94, green: 0.5, blue: 0.0) } // Transit Orange
        if f.contains("octopus") { return SavedCardColor(red: 0.92, green: 0.48, blue: 0.1) } // Octopus Amber
        if f.contains("china") || f.contains("union") { return SavedCardColor(red: 0.75, green: 0.1, blue: 0.12) } // T-Union Red
        return SavedCardColor(red: 0.19, green: 0.38, blue: 0.73) // Default brand color
    }
}
