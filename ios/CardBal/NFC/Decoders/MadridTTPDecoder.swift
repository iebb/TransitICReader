import Foundation

/// Tarjeta Transporte Público, read through CRTM's card-reading service. The card must
/// have DESFire application 000001 before anything is sent to the service.
struct MadridTTPDecoder: TransitCardDecoder {
    static let family = "Tarjeta Transporte Público"

    static func canDecode(tag: CardTag) async -> Bool {
        guard !CardReadPolicy.localOnly, MadridTTPPreferences.isEnabled else { return false }
        switch tag {
        case .miFare(let card): return card.mifareFamily == .desfire
        case .iso7816: return true
        default: return false
        }
    }

    static func decode(tag: CardTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        let uid: Data
        let transceive: (Data) async throws -> Data
        switch tag {
        case .miFare(let card) where card.mifareFamily == .desfire:
            uid = card.identifier
            transceive = { try await card.sendMiFareCommand(commandPacket: $0) }
        case .iso7816(let card):
            uid = card.identifier
            transceive = { request in
                guard let apdu = CardAPDU(data: request) else { throw MadridTTPError.invalidResponse }
                let reply = try await card.sendCommand(apdu: apdu)
                return reply.0 + Data([reply.1, reply.2])
            }
        default: throw NFCTestError.unsupportedCard
        }
        guard try await transceive(MadridTTPProtocol.selectApplication) == Data([0x91, 0]) else {
            throw NFCTestError.unsupportedCard
        }
        madridDebugLog("DESFire application 000001 found; reading through the CRTM service")
        ScanProgress.report(.madridOnline)
        let client = MadridTTPClient()
        defer { client.close() }
        do {
            let outcome = try await MadridTTPProtocol.read(post: { try await client.post($0, body: $1) },
                                                           transceive: transceive, log: madridDebugLog)
            return snapshot(outcome, uid: uid, scannedAt: scannedAt)
        } catch {
            madridDebugLog("Read failed: " + DebugLog.describe(error))
            throw error
        }
    }

    static func snapshot(_ outcome: MadridTTPProtocol.Outcome, uid: Data, scannedAt: Date) -> TransitCardSnapshot {
        let card = outcome.card
        let serial = card.serial.flatMap { value -> String? in
            let upper = value.uppercased()
            return upper.count == 14 && MadridTTPProtocol.hexData(upper) != nil ? upper : nil
        }
        let identifier = serial ?? uid.hexString.uppercased()
        let raw = RawDataSection(title: "CRTM Service", fields: [
            RawDataField(title: "Status", value: card.statusCode),
            RawDataField(title: "Rounds", value: String(outcome.rounds)),
            RawDataField(title: "Card Commands", value: String(outcome.commands)),
            RawDataField(title: "Response", value: card.summaryJSON),
        ])
        return TransitCardSnapshot(
            technology: "DESFire", cardFamily: family, identifierLabel: "UID",
            identifierValue: identifier, rawIdentifierValue: identifier,
            pmm: nil, systemCode: nil, selectedAID: nil, balanceText: nil, balanceDetail: nil,
            realSerialNumber: card.cardNumber, region: "Madrid",
            resultFields: card.fields.map { ResultField(title: $0.0, value: $0.1) },
            rawSections: [raw], rawTransactions: [], rawTransitHistory: [], scannedAt: scannedAt)
    }
}

/// CRTM's card-reading service. The session lives in cookies held only for one read.
final class MadridTTPClient: NSObject, URLSessionTaskDelegate {
    static let baseURL = URL(string: "https://latsecu.comunidad.madrid/middlelat")!
    static let requestTimeout: TimeInterval = 10
    private let baseURL: URL
    private let deadline: Date
    private var cookies: [String: String] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(baseURL: URL = MadridTTPClient.baseURL, deadline: Date = Date().addingTimeInterval(30)) {
        self.baseURL = baseURL
        self.deadline = deadline
    }

    func close() { session.invalidateAndCancel() }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func post(_ path: String, body: Data) async throws -> Data {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw MadridTTPError.budgetExceeded }
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = min(Self.requestTimeout, remaining)
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CardBal", forHTTPHeaderField: "User-Agent")
        if !cookies.isEmpty {
            request.setValue(cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "),
                             forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MadridTTPError.invalidResponse }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            if let key = entry.key as? String, let value = entry.value as? String { result[key] = value }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: request.url!) {
            cookies[cookie.name] = cookie.value
        }
        guard http.statusCode == 200, data.count <= MadridTTPProtocol.maximumBody else {
            madridDebugLog("\(path == MadridTTPProtocol.initPath ? "Session" : "Reading") request: HTTP \(http.statusCode), \(data.count) bytes")
            throw MadridTTPError.invalidResponse
        }
        return data
    }
}

/// Lines for the on-device debug log; never card numbers, session cookies or replies.
func madridDebugLog(_ message: String) { DebugLog.shared.log("Madrid", message) }
