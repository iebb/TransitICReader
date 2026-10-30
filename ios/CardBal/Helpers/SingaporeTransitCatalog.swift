import Foundation

struct SingaporeStation: Decodable {
    let id: String
    let name: String
    let nameZh: String
    let publicCodes: [String]
    let latitude: Double
    let longitude: Double
    var displayName: String {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? nameZh : name
    }
}

struct SingaporeCountryBoundary: Decodable {
    struct Component: Decodable { let outer: [[Double]]; let holes: [[[Double]]] }
    let id: String
    let name: String
    let nameZh: String
    let center: [Double]
    let bbox: [Double]
    let components: [Component]
}

final class SingaporeTransitCatalog {
    struct Payload: Decodable {
        let version: Int
        let stations: [SingaporeStation]
        let aliases: [String: String]
        let country: SingaporeCountryBoundary
    }
    static let shared = SingaporeTransitCatalog(url: Bundle.main.url(forResource: "SingaporeTransit", withExtension: "json"))
    let stations: [SingaporeStation]
    let country: SingaporeCountryBoundary?
    private let byCode: [String: SingaporeStation]

    init(url: URL?) {
        guard let url, let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.version == 1 else {
            stations = []; country = nil; byCode = [:]; return
        }
        stations = payload.stations
        country = payload.country
        let byID = Dictionary(uniqueKeysWithValues: stations.map { ($0.id, $0) })
        var codes: [String: SingaporeStation] = [:]
        for station in stations {
            for code in station.publicCodes { codes[code] = station }
        }
        for (code, id) in payload.aliases { codes[code] = byID[id] }
        byCode = codes
    }

    func station(code: String) -> SingaporeStation? {
        byCode[code.uppercased().replacingOccurrences(of: "SG:", with: "")]
    }

    var lookupStations: [String: SingaporeStation] { byCode }

    func route(userData: String?) -> SingaporeTransitRoute? {
        let parts = userData?.split(separator: "-", omittingEmptySubsequences: false).map(String.init) ?? []
        guard parts.count == 2, parts.allSatisfy({ $0.count == 3 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }) else { return nil }
        return SingaporeTransitRoute(startCode: parts[0], endCode: parts[1],
                                     start: station(code: parts[0]), end: station(code: parts[1]))
    }
}

struct SingaporeTransitRoute {
    let startCode: String, endCode: String
    let start: SingaporeStation?, end: SingaporeStation?
    var displayName: String { "\(start?.displayName ?? startCode) → \(end?.displayName ?? endCode)" }
}
