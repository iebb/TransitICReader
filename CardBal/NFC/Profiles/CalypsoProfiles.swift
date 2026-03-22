import Foundation
import CoreNFC

struct CalypsoProbeTarget {
    let title: String
    let description: String
    let apdu: NFCISO7816APDU
    let commandData: Data
}

struct CalypsoCardProfile {
    let displayName: String
    let aidPrefixes: [String]
    let probeTargets: [CalypsoProbeTarget]

    static func matches(aid: String) -> Bool {
        let normalized = aid.uppercased()
        return all.contains { p in p.aidPrefixes.contains { normalized.hasPrefix($0) } }
    }

    static func matching(aid: String) -> CalypsoCardProfile {
        let normalized = aid.uppercased()
        return all.first(where: { p in p.aidPrefixes.contains { normalized.hasPrefix($0) } }) ?? all[0]
    }

    static let supportedPrefixes: [String] = ["A000000291", "A000000404"]

    func applicationAID(for selectedAID: String) -> String {
        let normalized = selectedAID.uppercased()
        if aidPrefixes.contains(where: { normalized.hasPrefix($0) }) {
            return normalized
        }
        return aidPrefixes[0]
    }

    private static let all: [CalypsoCardProfile] = [
        CalypsoCardProfile(
            displayName: "Calypso Card",
            aidPrefixes: supportedPrefixes,
            probeTargets: commonProbeTargets
        )
    ]

    private static let commonProbeTargets: [CalypsoProbeTarget] = [
        CalypsoProbeTarget(
            title: "GET DATA AID",
            description: "Calypso GET DATA tag 004F, often returns the DF name / application identifier.",
            apdu: .getData(tag: 0x004F),
            commandData: NFCISO7816APDU.getDataCommandData(tag: 0x004F)
        ),
        CalypsoProbeTarget(
            title: "GET DATA FCI Template",
            description: "Calypso GET DATA tag 006F, often returns an FCI template.",
            apdu: .getData(tag: 0x006F),
            commandData: NFCISO7816APDU.getDataCommandData(tag: 0x006F)
        ),
        CalypsoProbeTarget(
            title: "GET DATA FCP Template",
            description: "Calypso GET DATA tag 0062, often returns file control parameters.",
            apdu: .getData(tag: 0x0062),
            commandData: NFCISO7816APDU.getDataCommandData(tag: 0x0062)
        ),
        CalypsoProbeTarget(
            title: "GET DATA EF List",
            description: "Calypso GET DATA tag C030, referenced by the Nice Android source for EF discovery.",
            apdu: .getData(tag: 0xC030),
            commandData: NFCISO7816APDU.getDataCommandData(tag: 0xC030)
        ),
        CalypsoProbeTarget(
            title: "GET DATA Traceability",
            description: "Calypso GET DATA tag D020, referenced by the Nice Android source for traceability data.",
            apdu: .getData(tag: 0xD020),
            commandData: NFCISO7816APDU.getDataCommandData(tag: 0xD020)
        ),
        CalypsoProbeTarget(
            title: "Environment Record 1",
            description: "Calypso public example record: SFI 07, record 1.",
            apdu: .readRecord(recordNumber: 1, sfi: 0x07),
            commandData: NFCISO7816APDU.readRecordCommandData(recordNumber: 1, sfi: 0x07)
        ),
        CalypsoProbeTarget(
            title: "Environment Record 2",
            description: "Optional follow-up record in the same SFI, often holder-related on some cards.",
            apdu: .readRecord(recordNumber: 2, sfi: 0x07),
            commandData: NFCISO7816APDU.readRecordCommandData(recordNumber: 2, sfi: 0x07)
        ),
        CalypsoProbeTarget(
            title: "SFI 01 Record 1",
            description: "Additional public record probe for applications that store environment data in low SFIs.",
            apdu: .readRecord(recordNumber: 1, sfi: 0x01),
            commandData: NFCISO7816APDU.readRecordCommandData(recordNumber: 1, sfi: 0x01)
        ),
        CalypsoProbeTarget(
            title: "SFI 02 Record 1",
            description: "Additional public record probe for applications that store contracts or counters in SFI 02.",
            apdu: .readRecord(recordNumber: 1, sfi: 0x02),
            commandData: NFCISO7816APDU.readRecordCommandData(recordNumber: 1, sfi: 0x02)
        ),
        CalypsoProbeTarget(
            title: "SFI 08 Record 1",
            description: "Additional public record probe for alternate environment locations.",
            apdu: .readRecord(recordNumber: 1, sfi: 0x08),
            commandData: NFCISO7816APDU.readRecordCommandData(recordNumber: 1, sfi: 0x08)
        )
    ]
}

extension NFCISO7816APDU {
    static func getData(tag: UInt16) -> NFCISO7816APDU {
        NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xCA, p1Parameter: UInt8(tag >> 8), p2Parameter: UInt8(tag & 0xFF), data: Data(), expectedResponseLength: 256)
    }
    
    static func getDataCommandData(tag: UInt16) -> Data {
        Data([0x00, 0xCA, UInt8(tag >> 8), UInt8(tag & 0xFF), 0x00])
    }
    
    static func readRecord(recordNumber: UInt8, sfi: UInt8) -> NFCISO7816APDU {
        let p2 = (sfi << 3) | 0x01 | 0x04
        return NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xB2, p1Parameter: recordNumber, p2Parameter: p2, data: Data(), expectedResponseLength: 256)
    }
    
    static func readRecordCommandData(recordNumber: UInt8, sfi: UInt8) -> Data {
        let p2 = (sfi << 3) | 0x01 | 0x04
        return Data([0x00, 0xB2, recordNumber, p2, 0x00])
    }
}
