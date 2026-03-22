import Foundation
import CoreNFC

struct JapaneseICDecoder: TransitCardDecoder {
    static func canDecode(tag: NFCTag) async -> Bool {
        guard case .feliCa = tag else { return false }
        return true
    }

    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .feliCa(let feliCa) = tag else { throw NFCTestError.unsupportedCard }
        
        // Japan SV cards (Edy, etc.) are handled by other decoders. 
        // Here we handle Suica/Octopus/IruCa etc.
        
        // Try Rail/Transit IC (Service 008B)
        if let readResult = try? await feliCa.readWithoutEncryption(serviceCodeList: [Data([0x8B, 0x00])], blockList: [Data([0x80, 0x00])]),
           let block = readResult.2.first {
            let profile = FeliCaProfile.all[0] // Transit IC
            if let parsed = profile.parseBalance(block, scannedAt) {
                return createSnapshot(feliCa: feliCa, profile: profile, parsedBalance: parsed, scannedAt: scannedAt)
            }
        }
        
        // Try Octopus (Service 0117)
        if let readResult = try? await feliCa.readWithoutEncryption(serviceCodeList: [Data([0x17, 0x01])], blockList: [Data([0x80, 0x00])]),
           let block = readResult.2.first {
            let profile = FeliCaProfile.all[1] // Octopus
            if let parsed = profile.parseBalance(block, scannedAt) {
                return createSnapshot(feliCa: feliCa, profile: profile, parsedBalance: parsed, scannedAt: scannedAt)
            }
        }
        
        throw NFCTestError.unsupportedCard
    }
    
    private static func createSnapshot(feliCa: NFCFeliCaTag, profile: FeliCaProfile, parsedBalance: ParsedBalance, scannedAt: Date) -> TransitCardSnapshot {
        let feliCaTag = feliCa as NFCFeliCaTag
        let idm = feliCaTag.currentIDm.hexString.uppercased()
        let formattedIDm = formatFeliCaIDm(idm)
        let detectedBrand = profile.displayName // Simpler branding when system codes are unavailable
        
        var resultFields: [ResultField] = []
        if profile.displayName == "Japan Transit IC" {
            resultFields.append(ResultField(title: "Detected Type", value: detectedBrand))
        }
        resultFields.append(ResultField(title: "Card Number (IDm)", value: formattedIDm))
        
        var rawSections: [RawDataSection] = [
            RawDataSection(title: "Tag", fields: [
                RawDataField(title: "Technology", value: "FeliCa"),
                RawDataField(title: "IDm", value: formattedIDm),
                RawDataField(title: "System Code", value: profile.systemCode)
            ])
        ]
        
        var fields = [RawDataField(title: "Decoder", value: parsedBalance.detail)]
        fields.append(contentsOf: parsedBalance.rawFields)
        rawSections.append(RawDataSection(title: "Decoded Balance", fields: fields))

        return TransitCardSnapshot(
            technology: "FeliCa",
            cardFamily: profile.displayName,
            identifierLabel: "IDm",
            identifierValue: formattedIDm,
            rawIdentifierValue: idm,
            pmm: "Unavailable",
            systemCode: profile.systemCode,
            selectedAID: nil,
            balanceText: parsedBalance.formatted,
            balanceDetail: parsedBalance.detail,
            realSerialNumber: nil,
            region: detectedBrand == profile.displayName ? nil : detectedBrand,
            resultFields: resultFields,
            rawSections: rawSections,
            scannedAt: scannedAt
        )
    }
}

// MARK: - FeliCa Profiles (Extracted from NFCUtils)

private struct FeliCaProfile {
    let displayName: String
    let systemCode: String
    let serviceCode: String
    let serviceCodeLittleEndian: Data
    let brandOverrides: [String: String]
    let parseBalance: (Data, Date) -> ParsedBalance?

    static func matching(candidates: [String]) -> FeliCaProfile? {
        let normalized = Set(candidates.map { $0.uppercased() })
        return all.first(where: { normalized.contains($0.systemCode) })
    }

    func detectedBrand(using systemCodes: [String]) -> String {
        for systemCode in systemCodes.map({ $0.uppercased() }) {
            if let match = brandOverrides[systemCode] { return match }
        }
        return displayName
    }

    static let all: [FeliCaProfile] = [
        FeliCaProfile(
            displayName: "Japan Transit IC",
            systemCode: "0003",
            serviceCode: "008B",
            serviceCodeLittleEndian: Data([0x8B, 0x00]),
            brandOverrides: ["86A7": "Suica", "927A": "Hayakaken"],
            parseBalance: { block, _ in
                guard block.count >= 13 else { return nil }
                let balance = Int(block[11]) | (Int(block[12]) << 8)
                return ParsedBalance(
                    formatted: formatCurrency(amount: Decimal(balance), code: "JPY", fractionDigits: 0),
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
            systemCode: "DE80",
            serviceCode: "008B",
            serviceCodeLittleEndian: Data([0x8B, 0x00]),
            brandOverrides: [:],
            parseBalance: { block, _ in
                guard block.count >= 13 else { return nil }
                let balance = Int(block[11]) | (Int(block[12]) << 8)
                return ParsedBalance(
                    formatted: formatCurrency(amount: Decimal(balance), code: "JPY", fractionDigits: 0),
                    detail: "Parsed from bytes 11-12.",
                    rawFields: [RawDataField(title: "Value", value: "\(balance)")]
                )
            }
        )
    ]
}

