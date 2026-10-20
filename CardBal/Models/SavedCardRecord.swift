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
    var applications: [TransitApplication]? = nil
    var mergedIdentifiers: [String]? = nil
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
        case applications, mergedIdentifiers
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
        rawTransactions = try container.decode([String].self, forKey: .rawTransactions).filter(Self.rawRecordHasContent)
        rawTransitHistory = try container.decode([String].self, forKey: .rawTransitHistory).filter(Self.rawRecordHasContent)
        applications = try container.decodeIfPresent([TransitApplication].self, forKey: .applications)
        mergedIdentifiers = try container.decodeIfPresent([String].self, forKey: .mergedIdentifiers)
        resultFields = try container.decode([SavedCardField].self, forKey: .resultFields)
        scannedAt = try container.decode(Date.self, forKey: .scannedAt)
        color = try container.decode(SavedCardColor.self, forKey: .color)
        design = try container.decode(SavedCardDesign.self, forKey: .design)
        faceImageFileName = try container.decodeIfPresent(String.self, forKey: .faceImageFileName)
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned)
    }


    var transactions: [TransitTransaction] {
        if !applicationSnapshots.isEmpty { return TransitApplicationHistory.decode(applicationSnapshots, kind: .transactions) }
        return rawTransactions.enumerated().compactMap { idx, hex in
            TransactionDecoderRegistry.decode(raw: hex, family: cardFamily, technology: technology, context: rawTransactions, at: idx, kind: .transactions)
        }
    }

    var transitHistory: [TransitTransaction] {
        if !applicationSnapshots.isEmpty { return TransitApplicationHistory.decode(applicationSnapshots, kind: .transit) }
        return rawTransitHistory.enumerated().compactMap { idx, hex in
            TransactionDecoderRegistry.decode(raw: hex, family: cardFamily, technology: technology, context: rawTransitHistory, at: idx, kind: .transit, relatedContext: rawTransactions)
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

        let brand = ICCardBrand.from(family: cardFamily)

        // For T-Union cards, prefer the specific brand name (e.g. "羊城通") over generic family
        if brand == .tUnion {
            if let region, !region.isEmpty, region != "T-Union Cities" { return Self.displayBrandName(region) }
            // Check resultFields as fallback
            if let brandField = resultFields.first(where: { $0.title == "Brand" })?.value,
               !brandField.isEmpty, brandField != "T-Union Cities" {
                return Self.displayBrandName(brandField)
            }
            // "T-Union Cities" or region is still better than "China T-Union"
            if let region, !region.isEmpty { return region }
        }

        // For Japanese IC cards, resolve brand from serial number if available
        if brand.region == .japan || cardFamily == "Japan Transit IC" {
            if let resolved = Self.resolveJapaneseICBrand(from: realSerialNumber ?? customDisplaySerialNumber),
               resolved != "Japan Transit IC" {
                return resolved
            }
        }

        return Self.displayBrandName(region ?? cardFamily)
    }

    /// Official brand casing for names stored by older scans, and a readable
    /// name for City Union cards whose issuing city is not in the catalog.
    static func displayBrandName(_ name: String) -> String {
        if name.hasPrefix("City-Union City ") { return "City Union" }
        switch name {
        case "Manaca": return "manaca"
        case "Nimoca": return "nimoca"
        case "Lignes d'Azur card": return "Lignes d’Azur"
        default: return name
        }
    }

    /// Resolve Japanese IC card brand from serial number prefix.
    private static func resolveJapaneseICBrand(from serialNumber: String?) -> String? {
        guard let sn = serialNumber?.uppercased(), !sn.isEmpty else { return nil }
        let prefixMap: [(String, String)] = [
            ("JE", "Suica"), ("PB", "PASMO"), ("JW", "ICOCA"),
            ("FC", "Hayakaken"), ("JK", "SUGOCA"), ("TP", "manaca"),
            ("JH", "Kitaca"), ("NR", "nimoca"), ("JC", "TOICA"),
        ]
        for (prefix, name) in prefixMap {
            if sn.hasPrefix(prefix) { return name }
        }
        return nil
    }

    var visibleBalance: String {
        if let balanceText, !balanceText.isEmpty { return Self.displayBalance(balanceText, detail: balanceDetail) }
        if let trips = fieldValue("Remaining Trips").flatMap({ Int($0) }) { return Self.remainingTripsText(trips) }
        return ""
    }

    /// True when the card stores no stored value to show, such as an unlimited pass.
    var hasNoStoredBalance: Bool {
        guard let balanceText else { return true }
        return balanceText == "N/A" || balanceText.isEmpty
    }

    static func remainingTripsText(_ trips: Int) -> String {
        trips == 1 ? String(localized: "1 trip") : String(localized: "\(trips) trips")
    }

    /// Normalises balance text saved by older versions: one yen sign for Japan and
    /// China, singular trip counts, and a readable label in place of "N/A".
    static func displayBalance(_ text: String, detail: String?) -> String {
        if text == "N/A" {
            return detail?.localizedCaseInsensitiveContains("unlimited") == true ? String(localized: "Unlimited") : "—"
        }
        for suffix in [" trips", " trip"] where text.hasSuffix(suffix) {
            if let trips = Int(text.dropLast(suffix.count)) { return remainingTripsText(trips) }
        }
        for prefix in ["JP¥", "CN¥"] where text.hasPrefix(prefix) {
            return "¥" + text.dropFirst(prefix.count)
        }
        return text
    }

    var isCalypsoCard: Bool {
        let family = cardFamily.lowercased()
        let aid = selectedAID?.uppercased() ?? ""
        return family.contains("calypso")
            || family.contains("lignes d'azur")
            || aid.hasPrefix("A000000291")
            || aid.hasPrefix("A000000404")
            || aid == "315449432E494341"
    }

    var supportsRideMap: Bool {
        !isCalypsoCard
    }

    var calypsoOnlineSerialNumber: String? {
        let candidates = [
            realSerialNumber,
            fieldValue("Card Number"),
            customDisplaySerialNumber,
            identifierValue
        ]
        for candidate in candidates {
            let digits = candidate?.filter(\.isNumber) ?? ""
            let trimmed = digits.trimmingLeadingZeros(defaultValue: "")
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    var calypsoMediaUnicity: Int {
        if isCalypsoCard { return 2 }
        guard let value = fieldValue("Media Unicity"),
              let parsed = Int(value.filter(\.isNumber)) else {
            return 2
        }
        return parsed
    }

    var fullHexExportText: String {
        var lines: [String] = [
            "# CardBal Hex Export",
            "card_family=\(cardFamily)",
            "technology=\(technology)",
            "scanned_at=\(scannedAt.ISO8601Format())",
            ""
        ]

        appendHexLine("raw_identifier", rawIdentifierValue, to: &lines)
        appendHexLine("pmm", pmm, to: &lines)
        appendHexLine("system_code", systemCode, to: &lines)
        appendHexLine("selected_aid", selectedAID, to: &lines)
        appendHexLine("real_serial_number", realSerialNumber, to: &lines)

        let hexFields = resultFields.filter { Self.normalizedHex($0.value) != nil }
        if !hexFields.isEmpty {
            lines.append("")
            lines.append("[decoded_hex_fields]")
            for field in hexFields {
                if let hex = Self.normalizedHex(field.value) {
                    lines.append("\(Self.exportKey(from: field.title))=\(hex)")
                }
            }
        }

        lines.append("")
        lines.append("[transactions]")
        if rawTransactions.isEmpty {
            lines.append("# none")
        } else {
            for (index, hex) in rawTransactions.enumerated() {
                lines.append(String(format: "%03d=%@", index, Self.normalizedHex(hex) ?? hex.uppercased()))
            }
        }

        lines.append("")
        lines.append("[transit_history]")
        if rawTransitHistory.isEmpty {
            lines.append("# none")
        } else {
            for (index, hex) in rawTransitHistory.enumerated() {
                lines.append(String(format: "%03d=%@", index, Self.normalizedHex(hex) ?? hex.uppercased()))
            }
        }

        for app in applicationSnapshots {
            lines.append("\n[application \(app.id)]")
            lines.append("card_number=\(app.serialNumber ?? app.identifier)")
            lines.append("scanned_at=\(app.scannedAt.ISO8601Format())")
            for record in app.records {
                lines.append(String(format: "sfi_%02X_record_%03d_%@=%@", record.sfi, record.index, record.kind.rawValue, record.hex))
            }
            for section in app.diagnostics {
                lines.append("[\(app.id) · \(section.title)]")
                lines.append(contentsOf: section.fields.map { "\($0.title)=\($0.value)" })
            }
        }
        return lines.joined(separator: "\n") + "\n"
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

    private static func normalizedHex(_ value: String?) -> String? {
        guard let value else { return nil }
        let hex = value.replacingOccurrences(of: "[^0-9A-Fa-f]", with: "", options: .regularExpression).uppercased()
        guard !hex.isEmpty, hex.count.isMultiple(of: 2) else { return nil }
        return hex
    }

    static func rawRecordHasContent(_ value: String) -> Bool {
        guard let hex = normalizedHex(value) else { return false }
        return hex.contains { $0 != "0" }
    }

    private static func exportKey(from title: String) -> String {
        let cleaned = title.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private func appendHexLine(_ key: String, _ value: String?, to lines: inout [String]) {
        guard let hex = Self.normalizedHex(value) else { return }
        lines.append("\(key)=\(hex)")
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
        // Use snapshot.region directly (set by the decoder), with fallback to resultFields
        self.region = snapshot.region
            ?? snapshot.resultFields.first(where: { $0.title == "Brand" })?.value
            ?? snapshot.resultFields.first(where: { $0.title == "Region" })?.value
        self.enhancedFeliCaDecoded = false
        self.issuingCity = snapshot.resultFields.first(where: {$0.title == "Issuing City"})?.value
        self.cardTypeStr = snapshot.resultFields.first(where: {$0.title == "Card Type"})?.value
        self.issueDateStr = snapshot.resultFields.first(where: {$0.title == "Issue Date"})?.value
        self.expiryDateStr = snapshot.resultFields.first(where: {$0.title == "Expiry Date"})?.value
        self.rawTransactions = snapshot.rawTransactions.filter(Self.rawRecordHasContent)
        self.rawTransitHistory = snapshot.rawTransitHistory.filter(Self.rawRecordHasContent)
        self.applications = snapshot.applications
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
        if f.contains("u-money") || f.contains("umoney") { return SavedCardColor(red: 0.64, green: 0.04, blue: 0.45) } // U-Money Magenta
        if f.contains("t-money") || f.contains("ezl") { return SavedCardColor(red: 0.94, green: 0.5, blue: 0.0) } // Transit Orange
        if f.contains("octopus") { return SavedCardColor(red: 0.92, green: 0.48, blue: 0.1) } // Octopus Amber
        if f.contains("china") || f.contains("union") { return SavedCardColor(red: 0.75, green: 0.1, blue: 0.12) } // T-Union Red
        return SavedCardColor(red: 0.19, green: 0.38, blue: 0.73) // Default brand color
    }
}

private extension String {
    func trimmingLeadingZeros(defaultValue: String) -> String {
        let trimmed = drop { $0 == "0" }
        return trimmed.isEmpty ? defaultValue : String(trimmed)
    }
}
