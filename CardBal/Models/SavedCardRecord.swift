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
    case classic, sunrise, metro
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: return "Classic"
        case .sunrise: return "Sunrise"
        case .metro: return "Metro"
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
    var pmm: String?
    var selectedAID: String?
    var systemCode: String?
    var balanceText: String?
    var balanceDetail: String?
    var realSerialNumber: String?
    var enhancedFeliCaDecoded: Bool
    var resultFields: [SavedCardField]
    var scannedAt: Date
    var color: SavedCardColor
    var design: SavedCardDesign
    var faceImageFileName: String?

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
        return trimmed.isEmpty ? cardFamily : trimmed
    }

    var visibleBalance: String {
        if let balanceText, !balanceText.isEmpty { return balanceText }
        if let trips = fieldValue("Remaining Trips") { return "\(trips) trips" }
        return "No balance"
    }

    var cardNumber: String? { fieldValue("Card Number") ?? realSerialNumber }

    var displayedSerialNumber: String {
        let raw: String
        let trimmed = customDisplaySerialNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        raw = !trimmed.isEmpty ? trimmed : (cardNumber ?? identifierValue)

        if technology == "FeliCa" {
            let formatted = Self.formattedFeliCaSerial(raw)
            return formatted.isEmpty ? raw : formatted
        }

        return raw
    }

    func fieldValue(_ title: String) -> String? {
        resultFields.first(where: { $0.title == title })?.value
    }

    static func formattedFeliCaSerial(_ raw: String) -> String {
        let normalized = raw.uppercased().filter {
            $0.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
        }
        guard !normalized.isEmpty else { return "" }

        let firstGroupCount = min(5, normalized.count)
        let firstGroup = String(normalized.prefix(firstGroupCount))
        var groups = [firstGroup]
        var remainder = String(normalized.dropFirst(firstGroupCount))

        while !remainder.isEmpty {
            let nextCount = min(4, remainder.count)
            groups.append(String(remainder.prefix(nextCount)))
            remainder.removeFirst(nextCount)
        }

        return groups.joined(separator: " ")
    }
}
