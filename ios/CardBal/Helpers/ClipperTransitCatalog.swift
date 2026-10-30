import Foundation

final class ClipperTransitCatalog {
    struct Station: Decodable {
        let id: Int
        let name: String
        let latitude: Double
        let longitude: Double
        var lookupCode: String { "CLIPPER:\(id)" }
        var hasLocation: Bool {
            (-90...90).contains(latitude) && (-180...180).contains(longitude) && (latitude != 0 || longitude != 0)
        }
    }
    struct Operator: Decodable { let name: String; let mode: Int }
    private struct Payload: Decodable {
        let version: Int
        let notice: String
        let operators: [String: Operator]
        let lines: [String: Operator]
        let stations: [String: Station]
    }
    static let shared = ClipperTransitCatalog(url: Bundle.main.url(forResource: "ClipperTransit", withExtension: "json"))
    private let payload: Payload?
    var stations: [Station] { payload.map { Array($0.stations.values) } ?? [] }
    var notice: String { payload?.notice ?? "" }

    init(url: URL?) {
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data), decoded.version == 1 {
            payload = decoded
        } else { payload = nil }
    }

    func agencyName(_ agency: Int) -> String {
        payload?.operators[String(agency)]?.name ?? String(format: "Agency 0x%X", agency)
    }

    func defaultMode(agency: Int) -> Int { payload?.operators[String(agency)]?.mode ?? 0 }

    func station(agency: Int, station: Int) -> Station? {
        payload?.stations[String(agency << 16 | station)]
    }

    func stationName(agency: Int, station: Int, isEnd: Bool) -> String? {
        if let known = self.station(agency: agency, station: station) { return known.name }
        if [6, 11, 12, 25].contains(agency) {
            if station == 0xFFFF { return String(localized: "End of line") }
            if agency != 25 { return String(format: String(localized: "Zone %d"), station) }
        }
        if station == (isEnd ? 0xFFFF : 0) { return nil }
        return String(format: "0x%X/0x%X", agency, station)
    }

    func routeName(agency: Int, route: Int) -> String? {
        if let known = payload?.lines[String(agency << 16 | route)]?.name { return known }
        guard route != 0, route != 0xFFFF else { return nil }
        return String(format: String(localized: "Route 0x%X"), route)
    }
}
