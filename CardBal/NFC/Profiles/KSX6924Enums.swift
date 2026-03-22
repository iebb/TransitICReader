import Foundation

// MARK: - KS X 6924 Purse Info Enums (based on ksx6924core.h)

enum KSX6924CardType: UInt8 {
    case prePaid = 0x00
    case postPay = 0x10
    case mobilePostPay = 0x20

    var displayName: String {
        switch self {
        case .prePaid: return "Pre-paid"
        case .postPay: return "Post-pay"
        case .mobilePostPay: return "Mobile post-pay"
        }
    }

    static func lookup(_ value: UInt8) -> String {
        KSX6924CardType(rawValue: value)?.displayName ?? String(format: "Unknown (0x%02X)", value)
    }
}

enum KSX6924Algorithm: UInt8 {
    case seed = 0x00
    case tripleDES = 0x10

    var displayName: String {
        switch self {
        case .seed: return "SEED"
        case .tripleDES: return "3DES"
        }
    }

    static func lookup(_ value: UInt8) -> String {
        KSX6924Algorithm(rawValue: value)?.displayName ?? String(format: "Unknown (0x%02X)", value)
    }
}

struct KSX6924IDCenter {
    static let names: [UInt8: String] = [
        0x00: "Reserved",
        0x01: "Korea Financial Telecommunications and Clearings Institute",
        0x02: "A-Cash",
        0x03: "Mybi",
        0x05: "V-Cash",
        0x06: "Mondex Korea",
        0x07: "Korea Expressway Corporation",
        0x08: "Korea Smart Card Corporation",
        0x09: "KORAIL Networks",
        0x0b: "EB Card Corporation",
        0x0c: "Seoul Bus Transport Association",
        0x0d: "Cardnet"
    ]

    static func lookup(_ value: UInt8) -> String {
        names[value] ?? String(format: "Unknown (0x%02X)", value)
    }
}

struct KSX6924UserCode {
    static let names: [UInt8: String] = [
        0x01: "Regular/Normal",
        0x02: "Child",
        0x04: "Youth",
        0x06: "Elderly",
        0x0f: "Test",
        0xff: "Inactive"
    ]

    static func lookup(_ value: UInt8) -> String {
        names[value] ?? String(format: "Unknown (0x%02X)", value)
    }
}

struct KSX6924DisRate {
    static let names: [UInt8: String] = [
        0x00: "No discount",
        0x10: "Disabled, basic",
        0x11: "Disabled, companion",
        0x20: "Merit, basic",
        0x21: "Merit, companion"
    ]

    static func lookup(_ value: UInt8) -> String {
        names[value] ?? String(format: "Unknown (0x%02X)", value)
    }
}

struct KSX6924TCode {
    static let names: [UInt8: String] = [
        0x00: "None",
        0x01: "SK Telecom",
        0x02: "Korea Telecom",
        0x03: "LG Uplus"
    ]

    static func lookup(_ value: UInt8) -> String {
        names[value] ?? String(format: "Unknown (0x%02X)", value)
    }
}

struct KSX6924CCode {
    static let names: [UInt8: String] = [
        0x00: "None",
        0x01: "KB Kookmin Bank",
        0x02: "Nonghyup Bank",
        0x03: "Lotte Card",
        0x04: "BC Card",
        0x05: "Samsung Card",
        0x06: "Shinhan Bank",
        0x07: "Citibank Korea",
        0x08: "Korea Exchange Bank",
        0x09: "Woori",
        0x0a: "Hana SK Card",
        0x0b: "Hyundai Capital Services"
    ]

    static func lookup(_ value: UInt8) -> String {
        names[value] ?? String(format: "Unknown (0x%02X)", value)
    }
}
