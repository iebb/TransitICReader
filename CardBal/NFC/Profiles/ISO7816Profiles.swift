import Foundation
import CoreNFC

struct KSX6924CardProfile {
    let displayName: String
    let aid: String
    let parseBalance: (Data) -> ParsedBalance?

    static let configDFAID = "A0000004520001"

    static func matching(aid: String, configInfo: KSX6924ConfigDFInfo? = nil) -> KSX6924CardProfile {
        let normalized = aid.uppercased()
        if let p = all.first(where: { $0.aid == normalized }) { return p }
        if normalized.hasPrefix("D410000003") {
            return KSX6924CardProfile(displayName: "T-money", aid: normalized, parseBalance: ksx6924BalanceParser)
        }
        if normalized.hasPrefix("D410000014") {
            return KSX6924CardProfile(displayName: "EZL / Cashbee", aid: normalized, parseBalance: ksx6924BalanceParser)
        }
        if normalized.hasPrefix("D410000029") {
            return KSX6924CardProfile(displayName: "NAMANE", aid: normalized, parseBalance: ksx6924BalanceParser)
        }
        if normalized.hasPrefix("D410000030") {
            return KSX6924CardProfile(displayName: "MOIBA", aid: normalized, parseBalance: ksx6924BalanceParser)
        }
        if normalized.hasPrefix("D410650990") {
            return KSX6924CardProfile(displayName: "K-Cash", aid: normalized, parseBalance: ksx6924BalanceParser)
        }
        return KSX6924CardProfile(displayName: "ISO7816 Transit Card", aid: normalized, parseBalance: ksx6924BalanceParser)
    }

    private static let all: [KSX6924CardProfile] = [
        KSX6924CardProfile(displayName: "T-money", aid: "D4100000030001", parseBalance: ksx6924BalanceParser),
        KSX6924CardProfile(displayName: "EZL / Cashbee", aid: "D4100000140001", parseBalance: ksx6924BalanceParser),
        KSX6924CardProfile(displayName: "NAMANE", aid: "D410000029000001", parseBalance: ksx6924BalanceParser),
        KSX6924CardProfile(displayName: "MOIBA", aid: "D4100000300001", parseBalance: ksx6924BalanceParser),
        KSX6924CardProfile(displayName: "K-Cash", aid: "D4106509900020", parseBalance: ksx6924BalanceParser)
    ]
}

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

enum NFCISO7816AccessPolicy {
    static let exactAIDs: Set<String> = [
        "A0000004520001", "D4100000030001", "D4100000140001", "D410000029000001", "D4100000300001", "D4106509900020", "A000000632010105"
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
