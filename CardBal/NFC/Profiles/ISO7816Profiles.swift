import Foundation
import CoreNFC

struct KSX6924CardProfile {
    let displayName: String
    let aid: String
    let parseBalance: (Data) -> ParsedBalance?

    static func matching(aid: String) -> KSX6924CardProfile {
        let normalized = aid.uppercased()
        if let p = all.first(where: { $0.aid == normalized }) { return p }
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

    private static let all: [CalypsoCardProfile] = [
        CalypsoCardProfile(
            displayName: "Calypso Card",
            aidPrefixes: supportedPrefixes,
            probeTargets: [
                CalypsoProbeTarget(title: "GET DATA AID", description: "DF Name", apdu: .getData(tag: 0x004F), commandData: NFCISO7816APDU.getDataCommandData(tag: 0x004F)),
                CalypsoProbeTarget(title: "Environment Record 1", description: "SFI 07, record 1", apdu: .readRecord(recordNumber: 1, sfi: 0x07), commandData: NFCISO7816APDU.readRecordCommandData(recordNumber: 1, sfi: 0x07))
            ]
        )
    ]
}

enum NFCISO7816AccessPolicy {
    static let exactAIDs: Set<String> = [
        "A0000004520001", "D4100000030001", "D4100000140001", "D410000029000001", "D4100000300001", "D4106509900020"
    ]
    static func isAllowed(aid: String) -> Bool {
        let normalized = aid.uppercased()
        return exactAIDs.contains(normalized) || CalypsoCardProfile.supportedPrefixes.contains { normalized.hasPrefix($0) }
    }
}
