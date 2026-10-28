import Foundation
import CoreNFC

public struct FeliCaProfile {
    let displayName: String
    let systemCode: String
    let serviceCode: String
    let serviceCodeLittleEndian: Data
    let brandOverrides: [String: String]
    let parseBalance: (Data, Date) -> ParsedBalance?

    public static func matching(candidates: [String]) -> FeliCaProfile? {
        let normalized = Set(candidates.map { $0.uppercased() })
        return all.first(where: { normalized.contains($0.systemCode) })
    }

    public func detectedBrand(using systemCodes: [String], realSN: String? = nil) -> String {
        let (sn, sc) = (realSN?.uppercased() ?? "none", systemCodes.joined(separator: ","))
        NSLog("[JapaneseICBrandDebug] SN Prefix check: %@, full SN: %@, SC: %@", String(sn.prefix(2)), sn, sc)
        if let sn = realSN?.uppercased() {
             if sn.hasPrefix("JE") { return "Suica" }
             if sn.hasPrefix("PB") { return "PASMO" }
             if sn.hasPrefix("JW") { return "ICOCA" }
             if sn.hasPrefix("FC") { return "Hayakaken" }
             if sn.hasPrefix("JK") { return "SUGOCA" }
             if sn.hasPrefix("TP") { return "Manaca" }
             if sn.hasPrefix("JH") { return "Kitaca" }
             if sn.hasPrefix("NR") { return "Nimoca" }
             if sn.hasPrefix("JC") { return "TOICA" }
        }
        
        let scMap: [String: String] = [
            "040F": "NicePass",
            "04C1": "QUICPay",
            "04C7": "Nanaco",
            "8005": "Shenzhen Tong",
            "8008": "Octopus",
            "800D": "Himawari Bus",
            "8016": "Nagasaki Smart",
            "804C": "Kitami Bus / LuLuCa",
            "8074": "Ohmi Railway Bus",
            "80DE": "IruCa",
            "80E0": "Desuca / IC E-Card",
            "80EF": "ICa",
            "8157": "CI-CA",
            "8194": "RapiCa",
            "8287": "NicoPa",
            "832C": "Passca / Ecomyca",
            "83CC": "Hareca",
            "83EE": "Ayuca",
            "84A1": "Hanica",
            "854C": "EX-IC",
            "8592": "PASPY",
            "862C": "Itappy",
            "865E": "SAPICA",
            "86A7": "Suica",
            "8760": "FCF",
            "88B4": "FeliCa Lite",
            "8B43": "NORUCA",
            "8B5D": "Ryuto",
            "8B61": "Rakuten Edy",
            "8B98": "Randen",
            "8E4B": "Univ Coop",
            "8FC1": "OKICA",
            "9027": "Kumamoto IC",
            "927A": "Hayakaken",
            "93EC": "Ntasu T-Card"
        ]
        
        let upperSC = systemCodes.map { $0.uppercased() }
        for sys in upperSC {
            if let brand = scMap[sys] { return brand }
        }
        
        for systemCode in upperSC {
            if let match = brandOverrides[systemCode] { return match }
        }
        return displayName
    }

    public static let all: [FeliCaProfile] = [
        FeliCaProfile(
            displayName: "Japan Transit IC",
            systemCode: "0003",
            serviceCode: "008B",
            serviceCodeLittleEndian: Data([0x8B, 0x00]),
            brandOverrides: [
                "86A7": "Suica", 
                "927A": "Hayakaken"
            ],
            parseBalance: { block, _ in
                guard block.count >= 13 else { return nil }
                let balance = Int(block[11]) | (Int(block[12]) << 8)
                return ParsedBalance(
                    formatted: formatCurrency(amount: Decimal(balance), code: "JPY"),
                    detail: "Parsed from bytes 11-12 in little-endian order.",
                    rawFields: [RawDataField(title: "Value", value: "\(balance)")]
                )
            }
        ),
        FeliCaProfile(
            displayName: "Octopus",
            systemCode: "8008",
            serviceCode: "0117",
            serviceCodeLittleEndian: Data([0x17, 0x01]),
            brandOverrides: [:],
            parseBalance: { block, scannedAt in
                guard block.count >= 4 else { return nil }
                let rawStored = block.bigEndianInt(start: 0, length: 4)
                let offset = octopusOffset(for: scannedAt)
                let value = Decimal(rawStored - offset) / 10
                return ParsedBalance(
                    formatted: formatCurrency(amount: value, code: "HKD", fractionDigits: 1),
                    detail: "Octopus stores a raw value with an offset. formula: (raw - \(offset)) / 10.",
                    rawFields: [RawDataField(title: "Raw Stored", value: "\(rawStored)")]
                )
            }
        ),
        FeliCaProfile(
            displayName: "IruCa",
            systemCode: "80DE",
            serviceCode: "008B",
            serviceCodeLittleEndian: Data([0x8B, 0x00]),
            brandOverrides: [:],
            parseBalance: { block, _ in
                guard block.count >= 13 else { return nil }
                let balance = Int(block[11]) | (Int(block[12]) << 8)
                return ParsedBalance(
                    formatted: formatCurrency(amount: Decimal(balance), code: "JPY"),
                    detail: "Parsed from bytes 11-12.",
                    rawFields: [RawDataField(title: "Value", value: "\(balance)")]
                )
            }
        ),
        FeliCaProfile(
            displayName: "PASPY",
            systemCode: "8592",
            serviceCode: "008B",
            serviceCodeLittleEndian: Data([0x8B, 0x00]),
            brandOverrides: [:],
            parseBalance: { block, _ in
                guard block.count >= 13 else { return nil }
                let balance = Int(block[11]) | (Int(block[12]) << 8)
                return ParsedBalance(
                    formatted: formatCurrency(amount: Decimal(balance), code: "JPY"),
                    detail: "Parsed from bytes 11-12.",
                    rawFields: [RawDataField(title: "Value", value: "\(balance)")]
                )
            }
        ),
        FeliCaProfile(
            displayName: "SAPICA",
            systemCode: "865E",
            serviceCode: "008B",
            serviceCodeLittleEndian: Data([0x8B, 0x00]),
            brandOverrides: [:],
            parseBalance: { block, _ in
                guard block.count >= 13 else { return nil }
                let balance = Int(block[11]) | (Int(block[12]) << 8)
                return ParsedBalance(
                    formatted: formatCurrency(amount: Decimal(balance), code: "JPY"),
                    detail: "Parsed from bytes 11-12.",
                    rawFields: [RawDataField(title: "Value", value: "\(balance)")]
                )
            }
        ),
        FeliCaProfile(
            displayName: "OKICA",
            systemCode: "8FC1",
            serviceCode: "028F",
            serviceCodeLittleEndian: Data([0x8F, 0x02]),
            brandOverrides: [:],
            parseBalance: { block, _ in
                guard block.count >= 12 else { return nil }
                let balance = Int(block[10]) | (Int(block[11]) << 8)
                return ParsedBalance(
                    formatted: formatCurrency(amount: Decimal(balance), code: "JPY"),
                    detail: "Parsed from the latest OKICA transaction record, bytes 10-11 in little-endian order.",
                    rawFields: [RawDataField(title: "Value", value: "\(balance)")]
                )
            }
        )
    ]
}
