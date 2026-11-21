import Foundation

/// Tarjeta Transporte Público of the Consorcio Regional de Transportes de Madrid (CRTM).
/// Every file in its DESFire application needs authentication with keys that only CRTM
/// holds, so the card is read by relaying the commands of CRTM's card-reading service.
/// See docs/decoding/madrid-ttp.md.
enum MadridTTPError: Error, Equatable {
    case refusedCommand(UInt8), invalidResponse, service(String), budgetExceeded
}

enum MadridTTPPreferences {
    static let enabledKey = "madridOnlineEnabled"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var debugSummary: String { "Madrid Online: \(isEnabled ? "on" : "off")" }
}

struct MadridTTPCard: Equatable {
    struct Ticket: Equatable {
        enum Kind: String { case pass, multiTrip }
        let kind: Kind
        let name: String
        var zones: String?
        var soldAt: String?
        var validFrom: String?
        var validUntil: String?
        var trips: String?
        var lastUse: String?
        var expired = false
    }
    struct Profile: Equatable { let name: String; let validUntil: String? }

    let statusCode: String
    var cardNumber: String?
    var serial: String?
    var cardName: String?
    var group: String?
    var profiles: [Profile] = []
    var issueDate: String?
    var expiryDate: String?
    var blocked = false
    var tickets: [Ticket] = []
    /// The service's card and ticket objects without the list of titles on sale.
    var summaryJSON: String = "{}"

    /// A trip count for the card face, only when it cannot be mistaken for another ticket's.
    var remainingTrips: Int? {
        let current = tickets.filter { !$0.expired }
        guard !current.contains(where: { $0.kind == .pass }) else { return nil }
        let counted = current.filter { $0.kind == .multiTrip }
        guard counted.count == 1, let trips = counted[0].trips else { return nil }
        return Int(trips)
    }

    var fields: [(String, String)] {
        var output: [(String, String)] = []
        func add(_ title: String, _ value: String?) {
            if let value, !value.isEmpty { output.append((title, value)) }
        }
        add("Card Number", cardNumber)
        add("Card Type", cardName)
        add("Profile", group)
        for profile in profiles where profile.validUntil != expiryDate {
            add(profile.name + " Valid Until", profile.validUntil)
        }
        add("Issue Date", issueDate)
        add("Expiry Date", expiryDate)
        if blocked { add("Status", "Blocked") }
        if let remainingTrips { add("Remaining Trips", String(remainingTrips)) }
        var used: [String: Int] = [:]
        for ticket in tickets {
            used[ticket.name, default: 0] += 1
            let label = used[ticket.name]! == 1 ? ticket.name : "\(ticket.name) (\(used[ticket.name]!))"
            add("Ticket", label)
            if ticket.expired { add(label + " Status", "Expired") }
            add(label + " Zones", ticket.zones)
            add(label + " Valid From", ticket.validFrom)
            add(label + " Valid Until", ticket.validUntil)
            add(label + " Remaining Trips", ticket.trips)
            add(label + " Sold At", ticket.soldAt)
            add(label + " Last Use", ticket.lastUse)
        }
        return output
    }
}

enum MadridTTPProtocol {
    static let initPath = "/midd/device/init/conn"
    static let readingPath = "/device/front/CardReading"
    /// Wrapped DESFire SELECT APPLICATION 000001, sent before anything reaches the service.
    static let selectApplication = Data([0x90, 0x5A, 0, 0, 3, 0, 0, 1, 0])
    static let maximumRounds = 16
    static let maximumCommandsPerRound = 64
    static let maximumBody = 262_144
    /// DESFire instructions that only read, select or authenticate. Additional frames (AF)
    /// are relayed only after the card itself asked for one.
    static let readInstructions: Set<UInt8> = [
        0x60, 0x5A, 0x0A, 0x1A, 0xAA, 0x71, 0x77, 0xBD, 0xBB, 0x6C,
        0x6F, 0x6A, 0x6D, 0x61, 0x45, 0x64, 0xF5, 0x51, 0x6E,
    ]

    static func initBody() -> Data {
        try! JSONSerialization.data(withJSONObject: ["language": "en", "timezone": "Europe/Madrid"], options: [.sortedKeys])
    }

    /// Card updates are never requested: the service is asked for a read only.
    static func readingBody(rapdu: [String]?) -> Data {
        var body: [String: Any] = [
            "titleList": "COMMON", "salePoint": "010201000005", "updateCard": false,
            "commandType": "WRAPPED", "opInspection": false,
        ]
        if let rapdu { body["rapdu"] = rapdu }
        return try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// The APDU of a wrapped read, select or authentication command, or nil for anything else.
    static func permittedCommand(_ hex: String, afterAdditionalFrame: Bool) -> Data? {
        guard hex.count >= 10, hex.count <= 600, let apdu = hexData(hex) else { return nil }
        let bytes = [UInt8](apdu)
        guard bytes[0] == 0x90, bytes[2] == 0, bytes[3] == 0 else { return nil }
        if bytes.count > 5 {
            guard bytes.count == 6 + Int(bytes[4]), bytes[4] > 0, bytes.last == 0 else { return nil }
        } else if bytes[4] != 0 {
            return nil
        }
        if bytes[1] == 0xAF { return afterAdditionalFrame ? apdu : nil }
        return readInstructions.contains(bytes[1]) ? apdu : nil
    }

    struct Outcome { let card: MadridTTPCard; let rounds: Int; let commands: Int }

    /// Relays the service's commands until it returns the card. A command outside the read set
    /// ends the exchange before it reaches the card.
    static func read(post: (String, Data) async throws -> Data,
                     transceive: (Data) async throws -> Data,
                     log: (String) -> Void = { _ in }) async throws -> Outcome {
        let greeting = try object(try await post(initPath, initBody()))
        guard statusCode(greeting) == "0000" else {
            log("Session: status \(statusCode(greeting) ?? "missing")")
            throw MadridTTPError.service(statusCode(greeting) ?? "")
        }
        var response = try object(try await post(readingPath, readingBody(rapdu: nil)))
        var relayed = 0
        // Authentication continues across rounds: its 91AF reply is answered in the next one.
        var additionalFrame = false
        for round in 1...maximumRounds {
            let code = statusCode(response) ?? ""
            if code == "0000" || code == "0001" {
                guard let card = parse(response) else {
                    log("Round \(round): status \(code) without card data")
                    throw MadridTTPError.invalidResponse
                }
                log("Finished after \(round - 1) rounds and \(relayed) card commands, status \(code)")
                return Outcome(card: card, rounds: round - 1, commands: relayed)
            }
            guard code == "0010" else {
                log("Round \(round): service status \(code.isEmpty ? "missing" : code)")
                throw MadridTTPError.service(code)
            }
            guard let commands = response["capdu"] as? [String], !commands.isEmpty,
                  commands.count <= maximumCommandsPerRound else {
                log("Round \(round): command list missing or too long")
                throw MadridTTPError.invalidResponse
            }
            var replies: [String] = []
            for hex in commands {
                try Task.checkCancellation()
                guard let apdu = permittedCommand(hex, afterAdditionalFrame: additionalFrame) else {
                    let instruction = hexData(String(hex.prefix(4))).flatMap { $0.count == 2 ? $0[1] : nil } ?? 0
                    log("Round \(round): refused instruction \(String(format: "%02X", instruction)); nothing more was sent to the card")
                    throw MadridTTPError.refusedCommand(instruction)
                }
                let reply = try await transceive(apdu)
                guard reply.count >= 2 else { throw MadridTTPError.invalidResponse }
                additionalFrame = reply[reply.count - 2] == 0x91 && reply[reply.count - 1] == 0xAF
                replies.append(reply.map { String(format: "%02X", $0) }.joined())
                relayed += 1
            }
            log("Round \(round): relayed \(commands.count) commands")
            response = try object(try await post(readingPath, readingBody(rapdu: replies)))
        }
        log("Round budget exceeded")
        throw MadridTTPError.budgetExceeded
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= maximumBody,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MadridTTPError.invalidResponse
        }
        return value
    }

    static func statusCode(_ response: [String: Any]) -> String? {
        (response["status"] as? [String: Any])?["code"] as? String
    }

    static func parse(_ response: [String: Any]) -> MadridTTPCard? {
        guard let balance = response["balance"] as? [String: Any] else { return nil }
        let titles = response["titleList"] as? [String: Any]
        var card = MadridTTPCard(statusCode: statusCode(response) ?? "")
        card.cardNumber = text(balance["cardNumber"]) ?? printedNumber(balance)
        card.serial = text(balance["desfireSerial"])
        card.cardName = text(titles?["cardName"])
        card.group = text(balance["groupName"])
        card.profiles = (balance["profiles"] as? [[String: Any]] ?? []).compactMap { profile in
            text(profile["profileName"]).map { MadridTTPCard.Profile(name: $0, validUntil: date(profile["finishProfileDate"])) }
        }
        card.issueDate = date(balance["initAppDate"])
        card.expiryDate = date(balance["finishAppDate"])
        card.blocked = balance["blockedApp"] as? Bool ?? false
        if let pass = balance["titTemp"] as? [String: Any], let name = text(pass["name"]) {
            card.tickets.append(MadridTTPCard.Ticket(
                kind: .pass, name: name, zones: text(pass["validityZones"]), soldAt: date(pass["purchaseChargeDate"]),
                validFrom: date(pass["firstDateValCharge"]) ?? date(pass["initChargeDate"]),
                validUntil: date(pass["finalDateValCharge"]) ?? date(pass["finishChargeDate"]),
                trips: nil, lastUse: date(pass["lastValidationDate"]), expired: isExpired(pass)))
        }
        for key in ["titMV1", "titMV2", "titMV3"] {
            guard let ticket = balance[key] as? [String: Any], let name = text(ticket["name"]) else { continue }
            card.tickets.append(MadridTTPCard.Ticket(
                kind: .multiTrip, name: name, zones: text(ticket["validityZones"]), soldAt: date(ticket["purchaseChargeDate"]),
                validFrom: nil, validUntil: nil, trips: text(ticket["trips"]), lastUse: date(ticket["lastValidationDate"]),
                expired: isExpired(ticket)))
        }
        var summary: [String: Any] = ["balance": balance]
        if let name = titles?["cardName"] { summary["cardName"] = name }
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            card.summaryJSON = string
        }
        return card
    }

    /// A Tarjeta MULTI has no `cardNumber`; its printed number is the order code and order number, as in MB0-12345678.
    static func printedNumber(_ balance: [String: Any]) -> String? {
        guard let code = text(balance["orderCode"]), let number = text(balance["cardOrderNumber"]),
              code.count <= 8, code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              number.count <= 20, number.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return code + "-" + number
    }

    /// `chargeState` "CADUCADO" marks a ticket that can no longer be used.
    static func isExpired(_ ticket: [String: Any]) -> Bool {
        text(ticket["chargeState"])?.uppercased() == "CADUCADO"
    }

    static func text(_ value: Any?) -> String? {
        let string: String
        switch value {
        case let value as String: string = value
        case let value as NSNumber where CFGetTypeID(value) != CFBooleanGetTypeID(): string = value.stringValue
        default: return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.count > 120 ? nil : trimmed
    }

    private static let localDate = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2})(?:[ T](\d{2}:\d{2})(?::\d{2}(?:\.\d+)?)?)?$"#)

    /// Dates as the service wrote them in Madrid time. A time of midnight is left out; values
    /// with an explicit offset are shown in Madrid time; anything unrecognised stays verbatim.
    static func date(_ value: Any?) -> String? {
        guard let string = text(value) else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        if let match = localDate.firstMatch(in: string, range: range) {
            let day = String(string[Range(match.range(at: 1), in: string)!])
            guard let timeRange = Range(match.range(at: 2), in: string) else { return day }
            let time = String(string[timeRange])
            return time == "00:00" ? day : day + " " + time
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let normalized = string.replacingOccurrences(of: #"([+-]\d{2})(\d{2})$"#, with: "$1:$2", options: .regularExpression)
        if let instant = iso.date(from: normalized) ?? plain.date(from: normalized) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Europe/Madrid")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            let shown = formatter.string(from: instant)
            return shown.hasSuffix(" 00:00") ? String(shown.prefix(10)) : shown
        }
        return string
    }

    static func hexData(_ hex: String) -> Data? {
        let characters = Array(hex.utf8)
        guard characters.count % 2 == 0 else { return nil }
        var data = Data(capacity: characters.count / 2)
        func nibble(_ character: UInt8) -> UInt8? {
            switch character {
            case 0x30...0x39: return character - 0x30
            case 0x41...0x46: return character - 0x37
            case 0x61...0x66: return character - 0x57
            default: return nil
            }
        }
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let high = nibble(characters[index]), let low = nibble(characters[index + 1]) else { return nil }
            data.append(high << 4 | low)
        }
        return data
    }
}
