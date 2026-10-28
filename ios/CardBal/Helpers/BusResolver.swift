import Foundation

class BusResolver {
    static let shared = BusResolver()
    private var busNames: [Int: String] = [:]
    
    private init() {
        loadData()
    }
    
    private func loadData() {
        guard let url = Bundle.main.url(forResource: "JPBusCodes", withExtension: "csv") else { return }
        do {
            let data = try String(contentsOf: url)
            let lines = data.components(separatedBy: .newlines)
            for line in lines where !line.isEmpty {
                let parts = line.components(separatedBy: ",")
                if parts.count >= 2, let code = Int(parts[0], radix: 16) {
                    busNames[code] = parts[1]
                }
            }
        } catch {}
    }
    
    func resolve(_ code: Int) -> String? {
        return busNames[code]
    }
}
