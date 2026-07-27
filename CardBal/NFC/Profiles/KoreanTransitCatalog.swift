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

enum KoreanStationAliasProvenance: String, Codable {
    case officialDatasetExactMatch = "official_dataset_exact_match"
    case officialDatasetTransformedExactMatch = "official_dataset_transformed_exact_match"
    case userConfirmed = "user_confirmed"

    var displayName: String {
        switch self {
        case .officialDatasetExactMatch:
            return NSLocalizedString("korean_station_provenance_official_exact", comment: "Exact station match in an official dataset")
        case .officialDatasetTransformedExactMatch:
            return NSLocalizedString("korean_station_provenance_official_transformed", comment: "Station match using an official row and documented transform")
        case .userConfirmed:
            return NSLocalizedString("korean_station_provenance_user_confirmed", comment: "Station label confirmed by a CardBal user")
        }
    }
}

struct KoreanStationAliasSource: Codable, Equatable {
    let id: String
    let title: String
    let publisher: String
    let catalogURL: URL?
    let localPath: String?
    let datasetDate: String?
    let portalModifiedDate: String?
    let retrievedAt: String
    let license: String
    let note: String
    let sourceSHA256: String?
    let rowCount: Int?
    let matchingMethod: String?
}

struct KoreanStationAliasStatistics: Codable, Equatable {
    let corpusRows: Int
    let officialBusRows: Int
    let eligibleBusRows: Int
    let exactMatchedRows: Int
    let exactMatchedLocationCodes: Int
    let exactMatchedSettlementStationIDs: Int
    let exactMatchedNames: Int
    let userConfirmedLocationCodes: Int
    let transformedRailMatchedRows: Int?
    let transformedRailMatchedLocationCodes: Int?
    let transformedRailMatchedStationIDs: Int?
    let busanBIMSMatchedRows: Int?
    let busanBIMSMatchedLocationCodes: Int?
    let busanTransformedRailMatchedRows: Int?
    let daeguTransformedRailMatchedRows: Int?
    let capitalRailMatchedRows: Int?
    let capitalRailMatchedLocationCodes: Int?
    let capitalRailExcludedReviewRows: Int?
}

struct KoreanStationAlias: Codable, Equatable {
    let locationCode: String
    let stationToken: String
    let transportModeCode: Int
    let name: String
    let provenance: KoreanStationAliasProvenance
    let sourceID: String
    let sourceStationID: String?
    let sourceStopID: String?
    let arsID: String?
    let ctpvCode: String?
    let ctpvName: String?
    let sggCode: String?
    let sggName: String?
    let latitude: Double?
    let longitude: Double?
    let coordinateSourceID: String?
    let coordinateSourceStationID: String?
    let coordinateMatchingMethod: String?
    let nameCanonicalKo: String?
    let nameEnglish: String?
    let nameHanja: String?
    let nameChineseSimplified: String?
    let nameChineseTraditional: String?
    let nameJapanese: String?
    let nameSourceID: String?
    let nameSourceStationID: String?
    let nameHanjaSourceID: String?
    let nameMatchingMethod: String?
    let eventRaw: Int?
    let userConfirmedSampleIDs: [String]?
    let matchingMethod: String?

    var administrativeAreaDisplay: String? {
        let parts = [ctpvName, sggName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

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
        if let nameCanonicalKo, !nameCanonicalKo.isEmpty {
            return nameCanonicalKo
        }
        return name
    }
}

enum KoreanStationAliasCatalogError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case duplicateLocationCode(String)
    case invalidLocationCode(String)
    case inconsistentLocationCode(String)
    case missingSource(String)
    case incompleteCoordinates(String)
    case invalidCoordinates(String)
    case coordinateSourceWithoutCoordinates(String)
}

/// Exact station aliases keyed by the complete bytes 05-10 fingerprint.
///
/// The four-byte station token is not globally unique and is not assumed to be
/// a public rail station ID. Bus stop candidates are exposed only for decimal
/// BCD tokens ending in zero and still require an exact source-catalog match.
struct KoreanStationAliasCatalog {
    private struct Payload: Decodable {
        let schemaVersion: Int
        let sources: [KoreanStationAliasSource]
        let statistics: KoreanStationAliasStatistics?
        let locations: [KoreanStationAlias]
    }

    static let bundled: KoreanStationAliasCatalog? = {
        guard let url = Bundle.main.url(forResource: "KoreanStationAliases", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? KoreanStationAliasCatalog(data: data)
    }()

    let sources: [KoreanStationAliasSource]
    let statistics: KoreanStationAliasStatistics?
    let locations: [KoreanStationAlias]
    private let locationsByCode: [String: KoreanStationAlias]
    private let eventLocationsByKey: [String: KoreanStationAlias]

    init(data: Data) throws {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.schemaVersion == 1 else {
            throw KoreanStationAliasCatalogError.unsupportedSchemaVersion(payload.schemaVersion)
        }

        let sourceIDs = Set(payload.sources.map(\.id))
        var byCode: [String: KoreanStationAlias] = [:]
        var byEventKey: [String: KoreanStationAlias] = [:]
        for location in payload.locations {
            let code = location.locationCode.uppercased()
            guard code.count == 12, code.allSatisfy({ $0.isHexDigit }) else {
                throw KoreanStationAliasCatalogError.invalidLocationCode(location.locationCode)
            }
            let expectedMode = String(format: "%04X", location.transportModeCode)
            guard location.stationToken.uppercased() == String(code.prefix(8)),
                  expectedMode == String(code.suffix(4)) else {
                throw KoreanStationAliasCatalogError.inconsistentLocationCode(location.locationCode)
            }
            guard sourceIDs.contains(location.sourceID) else {
                throw KoreanStationAliasCatalogError.missingSource(location.sourceID)
            }
            if let nameSourceID = location.nameSourceID,
               !sourceIDs.contains(nameSourceID) {
                throw KoreanStationAliasCatalogError.missingSource(nameSourceID)
            }
            if let nameHanjaSourceID = location.nameHanjaSourceID,
               !sourceIDs.contains(nameHanjaSourceID) {
                throw KoreanStationAliasCatalogError.missingSource(nameHanjaSourceID)
            }
            switch (location.latitude, location.longitude) {
            case let (latitude?, longitude?):
                guard latitude.isFinite,
                      longitude.isFinite,
                      (32.0...40.0).contains(latitude),
                      (123.0...133.0).contains(longitude) else {
                    throw KoreanStationAliasCatalogError.invalidCoordinates(location.locationCode)
                }
                if let coordinateSourceID = location.coordinateSourceID,
                   !sourceIDs.contains(coordinateSourceID) {
                    throw KoreanStationAliasCatalogError.missingSource(coordinateSourceID)
                }
            case (nil, nil):
                if location.coordinateSourceID != nil
                    || location.coordinateSourceStationID != nil
                    || location.coordinateMatchingMethod != nil {
                    throw KoreanStationAliasCatalogError.coordinateSourceWithoutCoordinates(location.locationCode)
                }
            default:
                throw KoreanStationAliasCatalogError.incompleteCoordinates(location.locationCode)
            }
            if let eventRaw = location.eventRaw {
                let eventKey = "\(code):\(eventRaw)"
                guard (0...255).contains(eventRaw),
                      byEventKey.updateValue(location, forKey: eventKey) == nil else {
                    throw KoreanStationAliasCatalogError.duplicateLocationCode(eventKey)
                }
            } else if byCode.updateValue(location, forKey: code) != nil {
                throw KoreanStationAliasCatalogError.duplicateLocationCode(code)
            }
        }

        sources = payload.sources
        statistics = payload.statistics
        locations = payload.locations
        locationsByCode = byCode
        eventLocationsByKey = byEventKey
    }

    func location(for locationCode: String, eventRaw: Int? = nil) -> KoreanStationAlias? {
        let code = locationCode.uppercased()
        if let eventRaw, let eventMatch = eventLocationsByKey["\(code):\(eventRaw)"] {
            return eventMatch
        }
        return locationsByCode[code]
    }

    func source(for id: String) -> KoreanStationAliasSource? {
        sources.first { $0.id == id }
    }

    static func busSettlementStationIDCandidate(
        stationToken: String,
        transportClass: KOTRISTransportClass?
    ) -> String? {
        guard transportClass == .bus,
              stationToken.count == 8,
              stationToken.allSatisfy({ $0.isNumber }),
              stationToken.last == "0" else {
            return nil
        }
        return String(stationToken.dropLast())
    }
}

enum KoreanTransitOperatorFieldProfile: String, Codable {
    case standardPacked33 = "standard_packed33"
    case bcd14Regional = "bcd14_regional"
    case mybiBusanSubway = "mybi_busan_subway"
    case mybiBusan = "mybi_busan"
    case mybiTotal = "mybi_total"
    case mybiGwangju = "mybi_gwangju"

    var usesOpaqueCounters: Bool {
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
/// Seven-byte `yyyyMMddHHmmss` BCD must be attempted first because many BCD
/// rows also form a superficially valid packed date. The standard clock is 33
/// bits: a 16-bit date, a 16-bit time word, and the high bit of byte 15 as the
/// seconds low bit. Mybi-family profiles use this block as opaque counters and
/// deliberately return `nil` rather than manufacturing a calendar timestamp.
enum KoreanTransitTimestampDecoder {
    static let recordLength = 52
    private static let timestampOffset = 11

    static func decode(_ record: Data) -> KoreanTransitTimestamp? {
        guard record.count == recordLength else { return nil }
        if let bcd = decodeBCD14(record) { return bcd }
        guard KoreanTransitOperatorFieldProfile.forRecord(record)?.usesOpaqueCounters == false else {
            return nil
        }
        return decodePacked33(record)
    }

    private static func decodeBCD14(_ record: Data) -> KoreanTransitTimestamp? {
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
            second: digits[12] * 10 + digits[13]
        )
    }

    private static func decodePacked33(_ record: Data) -> KoreanTransitTimestamp? {
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
            second: (Int(timeWord & 0x1F) << 1) | Int(record[timestampOffset + 4] >> 7)
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
        second: Int
    ) -> KoreanTransitTimestamp? {
        guard (1...12).contains(month),
              (1...31).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 60 * 60)!

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
}
