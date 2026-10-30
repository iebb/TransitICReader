import Foundation

/// Routes each public on-card envelope to its own codec before generic ISO/FeliCa decoding.
enum AdditionalCardHistory {
    static let families: Set<String> = ["ez-link", "nets flashpay", "opal", "hsl", "waltti", "clipper", "calypso", "lignes d'azur card", "navigo", "opus", "mobib", "rav-kav"]
    static func handles(_ family: String) -> Bool { families.contains(family.lowercased()) }
    static func merge(_ records: [String]) -> [String] {
        var seen = Set<String>()
        return CalypsoProtocol.mergeHistory(records).filter { raw in
            let bytes = Data(hexString: raw)
            let key: String
            if bytes.count >= 12 && bytes.prefix(5) == Data([0x44, 0x46, 0x53, 0x56, 1]) {
                key = (Data(bytes.prefix(7)) + Data(bytes.dropFirst(9))).hexString
            } else { key = raw.uppercased() }
            return seen.insert(key).inserted
        }
    }
    static func decode(raw: String, family: String, context: [String] = []) -> TransitTransaction? {
        let normalized = family.lowercased()
        if normalized == "ez-link" || normalized == "nets flashpay" {
            guard let history = CEPASProtocol.decodeHistory(Data(hexString: raw)) else { return nil }
            let category: TransactionCategory
            switch history.kind {
            case .train: category = .train
            case .bus: category = .bus
            case .topUp: category = .topUp
            case .refund: category = .refund
            case .purchase, .service: category = .payment
            default: category = .unknown
            }
            return transaction(raw: raw, date: history.timestamp, amount: history.hasMonetaryAmount ? history.amountMinor : nil,
                               balance: nil, currency: "SGD", zone: "Asia/Singapore", label: history.type, category: category,
                               terminal: nil, location: history.userData)
        }
        if ["opal", "hsl", "waltti", "clipper"].contains(normalized) {
            let canonical = ["opal": "Opal", "hsl": "HSL", "waltti": "Waltti", "clipper": "Clipper"][normalized]!
            guard let history = StoredValueProtocol.parseHistories(context.isEmpty ? [raw] : merge(context), expectedFamily: canonical).first(where: { $0.rawEnvelope == raw }) else { return nil }
            let category: TransactionCategory = history.kind == "reload" ? .topUp
                : history.label == "Tap on" ? .tapOn : history.label == "Tap off" ? .tapOff : .train
            return transaction(raw: raw, date: history.dateEpochSeconds.map(Date.init(timeIntervalSince1970:)),
                               amount: history.amountMinor, balance: history.balanceMinor, currency: history.currencyCode,
                               zone: history.issuerTimeZone, label: history.label, category: category, terminal: history.route,
                               location: history.locationCode, counter: history.counter)
        }
        guard let history = CalypsoProtocol.parseHistory(Data(hexString: raw)), history.network.family.lowercased() == normalized else { return nil }
        return transaction(raw: raw, date: history.timestamp, amount: history.amountMinor, balance: nil,
                           currency: history.currency ?? "EUR", zone: history.network.timeZone,
                           label: history.description, category: .train, terminal: history.operatorCode,
                           location: [history.routeCode.map { "Route \($0)" }, history.stationCode.map { "Station code \($0)" }].compactMap { $0 }.joined(separator: " · "),
                           counter: history.counter.map(Int.init))
    }
    private static func transaction(raw: String, date: Date?, amount: Int64?, balance: Int64?, currency: String, zone: String,
                                    label: String, category: TransactionCategory, terminal: String?, location: String?, counter: Int? = nil) -> TransitTransaction {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: zone); formatter.dateFormat = "HH:mm:ss"
        var tx = TransitTransaction(date: date, time: date.map(formatter.string(from:)), amount: Decimal(amount ?? 0) / 100,
                                    terminalID: terminal, type: label, category: category,
                                    balanceAfter: balance.map { Decimal($0) / 100 }, location: location?.isEmpty == true ? nil : location,
                                    rawData: raw, recordNumber: counter)
        tx.currencyCode = currency; tx.issuerTimeZone = zone; tx.amountKnown = amount != nil; tx.amountIsSigned = true
        return tx
    }
}
