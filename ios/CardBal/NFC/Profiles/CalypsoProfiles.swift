import Foundation

/// AID matching routes a tag to public-record probing, never to a city/brand.
/// Network identity is established by CalypsoProtocol's environment parser.
enum CalypsoCardProfile {
    static let supportedPrefixes = ["A000000291", "A000000404"]
    static func matches(aid: String) -> Bool {
        let aid = aid.uppercased()
        // Core NFC can report the full DF name, e.g. 3MTR.ICA padded with zero bytes.
        return supportedPrefixes.contains { aid.hasPrefix($0) }
            || CalypsoProtocol.selectionAIDs.contains { aid.hasPrefix($0) }
    }
}
