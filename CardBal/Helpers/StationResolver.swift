import Foundation

class StationResolver {
    static let shared = StationResolver()
    private var stationMap: [String: String] = [:]
    
    private init() {
        if let path = Bundle.main.path(forResource: "JPStationCodes", ofType: "csv"),
           let content = try? String(contentsOfFile: path, encoding: .utf8) {
            let lines = content.components(separatedBy: .newlines)
            for line in lines {
                let parts = line.components(separatedBy: ",")
                if parts.count >= 2 {
                    let hex = parts[0].trimmingCharacters(in: .whitespaces).uppercased()
                    let name = parts[1].trimmingCharacters(in: .whitespaces)
                    stationMap[hex] = name
                }
            }
        }
    }
    
    func resolve(_ code: Int) -> String? {
        let hex = String(format: "%05X", code)
        return stationMap[hex]
    }
}
