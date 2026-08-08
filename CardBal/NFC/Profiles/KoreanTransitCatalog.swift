import Foundation

/// The transport class published by KORAIL's KOTRIS public-transport code table.
///
/// This class describes a transport mode. It is not a company identifier.
enum KOTRISTransportClass: String, Codable, CaseIterable {
    case rail = "R"
    case bus = "B"
    case taxi = "T"

    var displayName: String {
        switch self {
        case .rail: return NSLocalizedString("kotris_class_rail", comment: "KOTRIS rail transport class")
        case .bus: return NSLocalizedString("kotris_class_bus", comment: "KOTRIS bus transport class")
        case .taxi: return NSLocalizedString("kotris_class_taxi", comment: "KOTRIS taxi transport class")
        }
    }
}

struct KOTRISTransportMode: Codable, Equatable {
    let code: Int
    let nameKo: String
    let transportClass: KOTRISTransportClass
    let matchStatus: String?
    let sourceTitle: String?
    let sourceURL: URL?

    var hexCode: String {
        String(format: "%04X", code)
    }

    var provenanceDisplayName: String {
        switch matchStatus {
        case nil, "official_kotris":
            return "KORAIL KOTRIS"
        case "official_seoul":
            return "Seoul Smart Card official table"
        case "institutional_reference":
            return "Institutional reference"
        case "corpus_geometry_inference":
            return "CardBal corpus geometry inference"
        default:
            return matchStatus ?? "Unknown source"
        }
    }
}

struct KOTRISDataSource: Codable, Equatable {
    let title: String
    let publisher: String
    let system: String
    let catalogURL: URL
    let datasetDate: String
    let portalModifiedDate: String
    let retrievedAt: String
    let license: String
    let licenseEnglish: String
    let rowCount: Int
    let generatedFrom: String
    let sourceEncoding: String
    let sourceSHA256: String
    let transformation: String
}

enum KOTRISTransportModeCatalogError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case rowCountMismatch(expected: Int, actual: Int)
    case duplicateCode(Int)
    case invalidCode(Int)
    case emptyName(Int)
}

/// Offline catalog used to interpret bytes 09-10 of a 52-byte Korean transit-history record.
///
/// KORAIL publishes the code/name/class table. Treating the two record bytes as
/// its unsigned big-endian transport-mode code is a CardBal corpus inference.
/// The bundled payload is a UTF-8 conversion of the official KORAIL CSV; its
/// complete provenance is retained in `source`.
struct KOTRISTransportModeCatalog {
    private struct Payload: Decodable {
        let schemaVersion: Int
        let source: KOTRISDataSource
        let modes: [KOTRISTransportMode]
        let supplementaryModes: [KOTRISTransportMode]?
    }

    static let bundled: KOTRISTransportModeCatalog? = {
        guard let url = Bundle.main.url(forResource: "KOTRISTransportModes", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? KOTRISTransportModeCatalog(data: data)
    }()

    let source: KOTRISDataSource
    let modes: [KOTRISTransportMode]
    private let modesByCode: [Int: KOTRISTransportMode]

    init(data: Data) throws {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.schemaVersion == 1 else {
            throw KOTRISTransportModeCatalogError.unsupportedSchemaVersion(payload.schemaVersion)
        }
        guard payload.source.rowCount == payload.modes.count else {
            throw KOTRISTransportModeCatalogError.rowCountMismatch(
                expected: payload.source.rowCount,
                actual: payload.modes.count
            )
        }

        let mergedModes = payload.modes + (payload.supplementaryModes ?? [])
        var byCode: [Int: KOTRISTransportMode] = [:]
        for mode in mergedModes {
            guard (0...Int(UInt16.max)).contains(mode.code) else {
                throw KOTRISTransportModeCatalogError.invalidCode(mode.code)
            }
            guard !mode.nameKo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KOTRISTransportModeCatalogError.emptyName(mode.code)
            }
            guard byCode.updateValue(mode, forKey: mode.code) == nil else {
                throw KOTRISTransportModeCatalogError.duplicateCode(mode.code)
            }
        }

        source = payload.source
        modes = mergedModes.sorted { $0.code < $1.code }
        modesByCode = byCode
    }

    func mode(for code: Int) -> KOTRISTransportMode? {
        modesByCode[code]
    }

    func mode(forHexCode hexCode: String) -> KOTRISTransportMode? {
        let normalized = hexCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count == 4, let code = Int(normalized, radix: 16) else { return nil }
        return mode(for: code)
    }

    func mode(forCodeBytes bytes: Data) -> KOTRISTransportMode? {
        guard bytes.count == 2 else { return nil }
        let code = (Int(bytes[bytes.startIndex]) << 8) | Int(bytes[bytes.index(after: bytes.startIndex)])
        return mode(for: code)
    }

    func mode(forKoreanTransitRecord record: Data) -> KOTRISTransportMode? {
        guard record.count == KoreanTransitTimestampDecoder.recordLength else { return nil }
        let code = (Int(record[9]) << 8) | Int(record[10])
        return mode(for: code)
    }
}

struct KoreanStationAlias: Equatable {
    let locationCode: String
    let stationID: String
    let transportModeCode: Int
    let nameKorean: String
    let canonicalNameKorean: String
    let nameEnglish: String?
    let nameJapanese: String?
    let nameHanja: String?
    let nameChineseSimplified: String?
    let nameChineseTraditional: String?
    let latitude: Double?
    let longitude: Double?
    let provinceCode: String?
    let districtCode: String?
    let operatorName: String?
    let lineName: String?

    var localizedDisplayName: String {
        let languageCode = Locale.current.language.languageCode?.identifier.lowercased()
        let scriptCode = Locale.current.language.script?.identifier.lowercased()
        if languageCode == "en", let nameEnglish, !nameEnglish.isEmpty {
            return nameEnglish
        }
        if languageCode == "ja", let nameJapanese, !nameJapanese.isEmpty {
            return nameJapanese
        }
        if languageCode == "zh" {
            if scriptCode == "hant",
               let nameChineseTraditional,
               !nameChineseTraditional.isEmpty {
                return nameChineseTraditional
            }
            if let nameChineseSimplified, !nameChineseSimplified.isEmpty {
                return nameChineseSimplified
            }
            if let nameChineseTraditional, !nameChineseTraditional.isEmpty {
                return nameChineseTraditional
            }
        }
        return canonicalNameKorean
    }

    var mapStationID: String {
        guard let latitude, let longitude else { return stationID }
        return [
            provinceCode ?? "",
            districtCode ?? "",
            canonicalNameKorean,
            operatorName ?? "",
            lineName ?? "",
            String(latitude.bitPattern),
            String(longitude.bitPattern),
        ].map(normalizedMapComponent).joined(separator: "|")
    }

    var allowedEventRawValues: Set<Int>? {
        switch locationCode {
        case "221000000368", "230000000368":
            return [0]
        case "221022900368", "230022100368":
            return [1]
        default:
            return nil
        }
    }

    private func normalizedMapComponent(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

enum KoreanStationAliasCatalogError: Error, Equatable {
    case invalidUTF8
    case unexpectedHeader
    case invalidRow(Int)
    case rowCountMismatch(expected: Int, actual: Int)
    case duplicateLocationCode(String)
    case invalidLocationCode(String)
}

/// Reviewed Korean stations from the current-state consumer export published by
/// https://github.com/iebb/korean-stations.
struct KoreanStationAliasCatalog {
    private static let expectedRowCount = 832
    private static let expectedHeader = [
        "location_code", "station_id", "transport_mode_code",
        "transport_mode_name_ko", "transport_mode_name_en", "transport_mode_name_ja",
        "transport_mode_name_hanja", "transport_mode_name_zh_hans", "transport_mode_name_zh_hant",
        "transport_class", "station_name_ko", "canonical_name_ko",
        "station_name_en", "station_name_ja", "station_name_hanja",
        "station_name_zh_hans", "station_name_zh_hant", "operator_name", "line_name",
        "latitude", "longitude", "province_code", "province_name", "district_code", "district_name",
    ]

    static let bundled: KoreanStationAliasCatalog? = {
        guard let url = Bundle.main.url(forResource: "korean_stations", withExtension: "tsv") else {
            return nil
        }
        return try? KoreanStationAliasCatalog(tsvURL: url)
    }()

    let locations: [KoreanStationAlias]
    private let locationsByCode: [String: KoreanStationAlias]

    init(tsvURL: URL) throws {
        try self.init(data: Data(contentsOf: tsvURL))
    }

    init(data: Data) throws {
        guard let payload = String(data: data, encoding: .utf8) else {
            throw KoreanStationAliasCatalogError.invalidUTF8
        }
        let lines = payload.split(whereSeparator: \.isNewline)
        guard let headerLine = lines.first,
              headerLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) == Self.expectedHeader else {
            throw KoreanStationAliasCatalogError.unexpectedHeader
        }
        var loaded: [KoreanStationAlias] = []
        var byCode: [String: KoreanStationAlias] = [:]
        for (offset, line) in lines.dropFirst().enumerated() {
            let lineNumber = offset + 2
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count == Self.expectedHeader.count,
                  let transportModeCode = Int(columns[2]) else {
                throw KoreanStationAliasCatalogError.invalidRow(lineNumber)
            }
            let latitude = Double(columns[19])
            let longitude = Double(columns[20])
            guard columns[19].isEmpty == columns[20].isEmpty,
                  columns[19].isEmpty || (latitude != nil && longitude != nil),
                  !columns[10].isEmpty,
                  !columns[11].isEmpty else {
                throw KoreanStationAliasCatalogError.invalidRow(lineNumber)
            }
            if let latitude, let longitude {
                guard latitude.isFinite,
                      longitude.isFinite,
                      (32.0...40.0).contains(latitude),
                      (123.0...133.0).contains(longitude) else {
                    throw KoreanStationAliasCatalogError.invalidRow(lineNumber)
                }
            }
            let locationCode = columns[0].uppercased()
            let stationID = columns[1].uppercased()
            guard locationCode.count == 12,
                  locationCode.allSatisfy(\.isHexDigit),
                  stationID.count == 8,
                  locationCode.hasPrefix(stationID),
                  String(locationCode.suffix(4)) == String(format: "%04X", transportModeCode) else {
                throw KoreanStationAliasCatalogError.invalidLocationCode(locationCode)
            }
            let alias = KoreanStationAlias(
                locationCode: locationCode,
                stationID: stationID,
                transportModeCode: transportModeCode,
                nameKorean: columns[10],
                canonicalNameKorean: columns[11],
                nameEnglish: Self.optionalText(columns[12]),
                nameJapanese: Self.optionalText(columns[13]),
                nameHanja: Self.optionalText(columns[14]),
                nameChineseSimplified: Self.optionalText(columns[15]),
                nameChineseTraditional: Self.optionalText(columns[16]),
                latitude: latitude,
                longitude: longitude,
                provinceCode: Self.optionalText(columns[21]),
                districtCode: Self.optionalText(columns[23]),
                operatorName: Self.optionalText(columns[17]),
                lineName: Self.optionalText(columns[18])
            )
            guard byCode.updateValue(alias, forKey: locationCode) == nil else {
                throw KoreanStationAliasCatalogError.duplicateLocationCode(locationCode)
            }
            loaded.append(alias)
        }
        guard loaded.count == Self.expectedRowCount else {
            throw KoreanStationAliasCatalogError.rowCountMismatch(
                expected: Self.expectedRowCount,
                actual: loaded.count
            )
        }

        locations = loaded
        locationsByCode = byCode
    }

    func location(for locationCode: String, eventRaw: Int? = nil) -> KoreanStationAlias? {
        guard let alias = locationsByCode[locationCode.uppercased()] else { return nil }
        if let eventRaw,
           let allowedEventRawValues = alias.allowedEventRawValues,
           !allowedEventRawValues.contains(eventRaw) {
            return nil
        }
        return alias
    }

    private static func optionalText(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

}

enum KoreanTransitOperatorFieldProfile: String, Codable {
    case standardPacked33 = "standard_packed33"
    case bcd14Regional = "bcd14_regional"
    case mybiBusanSubway = "mybi_busan_subway"
    case mybiBusan = "mybi_busan"
    case mybiTotal = "mybi_total"
    case mybiGwangju = "mybi_gwangju"

    var usesMybiFieldLayout: Bool {
        switch self {
        case .mybiBusanSubway, .mybiBusan, .mybiTotal, .mybiGwangju:
            return true
        case .standardPacked33, .bcd14Regional:
            return false
        }
    }

    static func forModeCode(_ code: Int) -> KoreanTransitOperatorFieldProfile {
        if code == 870 { return .mybiBusanSubway }
        if (600..<619).contains(code)
            || (632..<637).contains(code)
            || (641..<661).contains(code)
            || (711..<714).contains(code)
            || (776..<800).contains(code)
            || [887, 936, 940].contains(code)
            || (901..<905).contains(code)
            || (913..<917).contains(code)
            || (925..<928).contains(code) {
            return .mybiBusan
        }
        if (621..<632).contains(code)
            || (637..<641).contains(code)
            || (684..<686).contains(code)
            || [729, 888].contains(code)
            || (928..<932).contains(code) {
            return .mybiTotal
        }
        if code == 691 || (770..<776).contains(code) || code == 871 {
            return .mybiGwangju
        }
        if (672..<684).contains(code)
            || (828..<831).contains(code)
            || (701..<704).contains(code)
            || (752..<756).contains(code)
            || (759..<763).contains(code)
            || (824..<826).contains(code)
            || (810..<821).contains(code)
            || (990..<1000).contains(code)
            || code == 853 {
            return .bcd14Regional
        }
        return .standardPacked33
    }

    static func forRecord(_ record: Data) -> KoreanTransitOperatorFieldProfile? {
        guard record.count == KoreanTransitTimestampDecoder.recordLength else { return nil }
        return forModeCode((Int(record[9]) << 8) | Int(record[10]))
    }
}

struct KoreanTransitTimestamp: Equatable {
    enum Layout: String, Codable {
        case packed33
        case bcd14
        case mybi24
    }

    let date: Date
    let layout: Layout
    let rawHex: String
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
    let second: Int

    var timeString: String {
        String(format: "%02d:%02d:%02d", hour, minute, second)
    }

    /// A collection timestamp can be supplied by the caller without making it
    /// part of format detection. Both values are absolute `Date` instances;
    /// callers may opt into a nonzero tolerance for clock skew.
    func isPlausible(notAfter referenceDate: Date, futureTolerance: TimeInterval = 0) -> Bool {
        date <= referenceDate.addingTimeInterval(futureTolerance)
    }
}

/// Strict timestamp decoder for the 52-byte T-money/EZL transit-history layout.
///
/// For standard/regional profiles, seven-byte `yyyyMMddHHmmss` BCD must be
/// attempted before the 33-bit packed clock because many BCD rows also form a
/// superficially valid packed date. Evidence-backed Mybi Busan profiles use
/// two 24-bit day/hour/minute clocks relative to 2011-11-12 in Asia/Seoul:
/// boarding uses bytes 11-13 and alighting uses bytes 14-16. Integrated-Mybi
/// and Gwangju 24-bit profiles remain opaque until their own rows validate a
/// dialect; independently valid seven-byte BCD is still accepted first.
enum KoreanTransitTimestampDecoder {
    static let recordLength = 52
    private static let timestampOffset = 11
    private static let mybiSentinel: UInt32 = 0xFBF000

    static func decode(_ record: Data, brand: ICCardBrand = .tmoney) -> KoreanTransitTimestamp? {
        guard record.count == recordLength else { return nil }
        guard let profile = KoreanTransitOperatorFieldProfile.forRecord(record) else { return nil }
        let calendar = issuerCalendar(for: brand)
        switch profile {
        case .mybiBusan, .mybiBusanSubway:
            return decodeMybi24(record, calendar: calendar)
        case .mybiTotal, .mybiGwangju:
            return decodeBCD14(record, calendar: calendar)
        case .standardPacked33, .bcd14Regional:
            if let bcd = decodeBCD14(record, calendar: calendar) { return bcd }
            return decodePacked33(record, calendar: calendar)
        }
    }

    private static func decodeMybi24(_ record: Data, calendar: Calendar) -> KoreanTransitTimestamp? {
        let clockOffset: Int
        switch record[2] {
        case 0:
            clockOffset = timestampOffset
        case 1:
            clockOffset = timestampOffset + 3
        default:
            return nil
        }

        let value = (UInt32(record[clockOffset]) << 16)
            | (UInt32(record[clockOffset + 1]) << 8)
            | UInt32(record[clockOffset + 2])
        guard value != 0, value != mybiSentinel else { return nil }

        let day = Int(value >> 11)
        let hour = Int((value >> 6) & 0x1F)
        let minute = Int(value & 0x3F)
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }

        var epochComponents = DateComponents()
        epochComponents.calendar = calendar
        epochComponents.timeZone = calendar.timeZone
        epochComponents.year = 2011
        epochComponents.month = 11
        epochComponents.day = 12
        guard let epoch = calendar.date(from: epochComponents),
              let date = calendar.date(
                byAdding: DateComponents(day: day, hour: hour, minute: minute),
                to: epoch
              ) else {
            return nil
        }

        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        guard let year = components.year,
              let month = components.month,
              let calendarDay = components.day,
              let decodedHour = components.hour,
              let decodedMinute = components.minute else {
            return nil
        }

        return KoreanTransitTimestamp(
            date: date,
            layout: .mybi24,
            rawHex: record[clockOffset..<(clockOffset + 3)]
                .map { String(format: "%02X", $0) }
                .joined(),
            year: year,
            month: month,
            day: calendarDay,
            hour: decodedHour,
            minute: decodedMinute,
            second: components.second ?? 0
        )
    }

    private static func decodeBCD14(_ record: Data, calendar: Calendar) -> KoreanTransitTimestamp? {
        let bytes = record[timestampOffset..<(timestampOffset + 7)]
        var digits: [Int] = []
        digits.reserveCapacity(14)

        for byte in bytes {
            let high = Int(byte >> 4)
            let low = Int(byte & 0x0F)
            guard high <= 9, low <= 9 else { return nil }
            digits.append(high)
            digits.append(low)
        }

        let year = digits[0] * 1000 + digits[1] * 100 + digits[2] * 10 + digits[3]
        guard (2000...2099).contains(year) else { return nil }

        return makeTimestamp(
            layout: .bcd14,
            rawBytes: bytes,
            year: year,
            month: digits[4] * 10 + digits[5],
            day: digits[6] * 10 + digits[7],
            hour: digits[8] * 10 + digits[9],
            minute: digits[10] * 10 + digits[11],
            second: digits[12] * 10 + digits[13],
            calendar: calendar
        )
    }

    private static func decodePacked33(_ record: Data, calendar: Calendar) -> KoreanTransitTimestamp? {
        let rawDateWord = (UInt16(record[timestampOffset]) << 8) | UInt16(record[timestampOffset + 1])
        let timeWord = (UInt16(record[timestampOffset + 2]) << 8) | UInt16(record[timestampOffset + 3])
        let year = 2000 + Int(rawDateWord >> 9)

        return makeTimestamp(
            layout: .packed33,
            rawBytes: record[timestampOffset..<(timestampOffset + 5)],
            year: year,
            month: Int((rawDateWord >> 5) & 0x0F),
            day: Int(rawDateWord & 0x1F),
            hour: Int(timeWord >> 11),
            minute: Int((timeWord >> 5) & 0x3F),
            second: (Int(timeWord & 0x1F) << 1) | Int(record[timestampOffset + 4] >> 7),
            calendar: calendar
        )
    }

    private static func makeTimestamp(
        layout: KoreanTransitTimestamp.Layout,
        rawBytes: Data.SubSequence,
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int,
        calendar: Calendar
    ) -> KoreanTransitTimestamp? {
        guard (1...12).contains(month),
              (1...31).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second) else {
            return nil
        }

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second

        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        guard roundTrip.year == year,
              roundTrip.month == month,
              roundTrip.day == day,
              roundTrip.hour == hour,
              roundTrip.minute == minute,
              roundTrip.second == second else {
            return nil
        }

        return KoreanTransitTimestamp(
            date: date,
            layout: layout,
            rawHex: rawBytes.map { String(format: "%02X", $0) }.joined(),
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
    }

    private static func issuerCalendar(for brand: ICCardBrand) -> Calendar {
        var calendar = CardDateFormatting.calendar(for: brand)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }
}
