import Foundation

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

    /// Services in system 0003 that only one issuer's cards carry, checked in
    /// this order with Request Service. Cards without any are left generic.
    static let transitIssuerServices: [(service: UInt16, brand: String)] = [
        (0x1808, "Suica"), (0x1A48, "ICOCA"), (0x1CC8, "PASMO"), (0x9888, "Manaca"),
        (0x1FC8, "Nimoca"), (0x1E08, "TOICA"), (0x1B88, "PiTaPa"), (0x228A, "SUGOCA"),
        (0x254A, "Hayakaken"), (0x2088, "Kitaca"), (0xBD48, "icsca")
    ]

    static var transitIssuerNodeCodes: [Data] {
        transitIssuerServices.map { Data([UInt8($0.service & 0xFF), UInt8($0.service >> 8)]) }
    }

    /// The brand of the first issuer service whose key version is not FFFF.
    static func transitIssuer(keyVersions: [Data]) -> String? {
        guard keyVersions.count == transitIssuerServices.count else { return nil }
        return zip(transitIssuerServices, keyVersions)
            .first { $0.1.count == 2 && $0.1 != Data([0xFF, 0xFF]) }?.0.brand
    }

    public func detectedBrand(using systemCodes: [String], realSN: String? = nil) -> String {
        if systemCode == KMTCardFormat.systemCode { return "KMT" }
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
            displayName: "KMT",
            systemCode: KMTCardFormat.systemCode,
            serviceCode: "1017",
            serviceCodeLittleEndian: KMTCardFormat.balanceService,
            brandOverrides: [:],
            parseBalance: { block, _ in
                guard let balance = KMTCardFormat.parseBalance(block) else { return nil }
                return ParsedBalance(
                    formatted: formatCurrency(amount: Decimal(balance.amountIDR), code: "IDR", fractionDigits: 0),
                    detail: "KMT stored value in whole Indonesian rupiah.",
                    rawFields: [
                        RawDataField(title: "Balance (IDR)", value: "\(balance.amountIDR)"),
                        RawDataField(title: "Last Transaction Amount (IDR)", value: "\(balance.lastTransactionAmountIDR)"),
                        RawDataField(title: "Transaction Counter", value: "\(balance.transactionCounter)")
                    ]
                )
            }
        ),
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
            // Requires an IDm-specific calibration in OctopusOnlineDecoder.
            parseBalance: { _, _ in nil }
        ),
        FeliCaProfile(
            displayName: "Ryuto", systemCode: RyutoCardFormat.systemCode,
            serviceCode: "898F", serviceCodeLittleEndian: RyutoCardFormat.service,
            brandOverrides: [:], parseBalance: { block, _ in
                guard let record = RyutoCardFormat.decode(block) else { return nil }
                return ParsedBalance(formatted: formatCurrency(amount: Decimal(record.balance), code: "JPY"),
                                     detail: "Stored balance from the latest Ryuto transaction.",
                                     rawFields: [RawDataField(title: "Balance", value: String(record.balance))])
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
        ),
        // Last: only a Hanica card answers 84A1, so other cards skip one failed poll.
        FeliCaProfile(
            displayName: "Hanica", systemCode: HanicaCardFormat.systemCode,
            serviceCode: "898F", serviceCodeLittleEndian: HanicaCardFormat.service,
            // One record cannot place the balance; JapaneseICDecoder reads the whole log.
            brandOverrides: [:], parseBalance: { _, _ in nil }
        )
    ]
}
