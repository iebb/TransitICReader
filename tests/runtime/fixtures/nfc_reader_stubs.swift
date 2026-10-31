// Core NFC/SwiftUI adapters for exercising the production reader on macOS.
// The RF callbacks are driven by the harness; no physical-card QA is implied.
enum Color { case secondary, green, orange }
enum StatusKind { case idle, success, error }
protocol NFCTagReaderSessionDelegate: AnyObject {}
protocol NFCFeliCaTag {
    func requestSystemCode() async throws -> [Data]
}
final class TestFeliCaTag: NFCFeliCaTag {
    let snapshot: TransitCardSnapshot
    init(_ snapshot: TransitCardSnapshot) { self.snapshot = snapshot }
    func requestSystemCode() async throws -> [Data] { [Data(hexString: "8008")] }
}
final class NFCTagReaderSession {
    struct PollingOption: OptionSet {
        let rawValue: Int
        static let iso18092 = Self(rawValue: 1)
        static let iso14443 = Self(rawValue: 2)
        static let iso15693 = Self(rawValue: 4)
    }
    struct Configuration {
        let pollingOption: PollingOption
        let iso7816SelectIdentifiers: [String]
        let feliCaSystemCodes: [String]
    }
    static let readingAvailable = true
    var alertMessage = ""
    var pollingOption: PollingOption
    var restarts = 0
    var invalidated = false
    init(pollingOption: PollingOption, delegate: NFCTagReaderSessionDelegate, queue: DispatchQueue?) {
        self.pollingOption = pollingOption
    }
    init(configuration: Configuration, delegate: NFCTagReaderSessionDelegate, queue: DispatchQueue?) {
        pollingOption = configuration.pollingOption
    }
    func begin() {}
    func invalidate() { invalidated = true }
    func invalidate(errorMessage: String) { invalidated = true }
    func restartPolling() { restarts += 1 }
    func restartPolling(configuration: Configuration) {
        pollingOption = configuration.pollingOption
        restarts += 1
    }
    func connect(to tag: NFCTag) async throws {}
}
enum JapaneseICDecoder: TransitCardDecoder {
    static func canDecode(tag: NFCTag) async -> Bool {
        if case .feliCa = tag { return true }
        return false
    }
    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .feliCa(let tag) = tag, let fixture = tag as? TestFeliCaTag else {
            throw NFCTestError.unsupportedCard
        }
        return fixture.snapshot
    }
}
enum UnsupportedTestDecoder: TransitCardDecoder {
    static func canDecode(tag: NFCTag) async -> Bool { false }
    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        throw NFCTestError.unsupportedCard
    }
}
typealias CalypsoDecoder = UnsupportedTestDecoder
typealias CEPASDecoder = UnsupportedTestDecoder
typealias StoredValueDecoder = UnsupportedTestDecoder
typealias ClipperDecoder = UnsupportedTestDecoder
typealias ClipperUltralightDecoder = UnsupportedTestDecoder
typealias MacauPassDecoder = UnsupportedTestDecoder
typealias KSX6924Decoder = UnsupportedTestDecoder
typealias EdyDecoder = UnsupportedTestDecoder
typealias WAONDecoder = UnsupportedTestDecoder
typealias NanacoDecoder = UnsupportedTestDecoder
struct FeliCaProfile {
    static let all = [Self()]
    func detectedBrand(using codes: [String], realSN: String) -> String { "Test FeliCa" }
}
extension NFCTransitReader {
    func performEnhancedFeliCaHandshake(tag: any NFCFeliCaTag) async throws -> String? { nil }
    func describeDetectedTag(_ tag: NFCTag) -> String { "test tag" }
}
