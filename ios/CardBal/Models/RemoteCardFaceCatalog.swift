import Foundation
import CryptoKit
import UIKit

/// Card faces published from github.com/iebb/card-faces. They download on
/// demand, are checked against the manifest's sha256 and live outside
/// CardFaces, so backups and unused-face cleanup ignore them; a missing file is
/// simply downloaded again. A card stores a face as a `remote.…png` token.
struct RemoteFaceManifest: Codable, Equatable {
    struct Match: Codable, Equatable {
        var cityCodes: [String]
        var cityUnionCodes: [String]
        var cardPrefixes: [String]
        var families: [String]
        var serialPrefixes: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            cityCodes = try container.decodeIfPresent([String].self, forKey: .cityCodes) ?? []
            cityUnionCodes = try container.decodeIfPresent([String].self, forKey: .cityUnionCodes) ?? []
            cardPrefixes = try container.decodeIfPresent([String].self, forKey: .cardPrefixes) ?? []
            families = try container.decodeIfPresent([String].self, forKey: .families) ?? []
            serialPrefixes = try container.decodeIfPresent([String].self, forKey: .serialPrefixes) ?? []
        }
    }

    struct Design: Codable, Equatable {
        let id: String
        let name: [String: String]?
        let bundledAsset: String?
        let file: String
        let sha256: String
        let bytes: Int
    }

    struct Card: Codable, Equatable {
        let id: String
        let name: [String: String]
        let city: [String: String]?
        let match: Match
        let designs: [Design]
    }

    struct Entry: Identifiable, Equatable {
        let token: String
        let card: Card
        let design: Design
        var id: String { token }
    }

    static let supportedSchemaVersion = 2
    static let maxFaceBytes = 40_000
    private static let tokenPattern = try! NSRegularExpression(pattern: "^remote(\\.[a-z0-9][a-z0-9-]*)+\\.png$")

    let schemaVersion: Int
    let cards: [Card]

    static func token(cardID: String, designID: String) -> String {
        "remote.\(cardID.replacingOccurrences(of: "/", with: ".")).\(designID).png"
    }

    static func isToken(_ fileName: String) -> Bool {
        tokenPattern.firstMatch(in: fileName, range: NSRange(fileName.startIndex..., in: fileName)) != nil
    }

    var entries: [Entry] {
        cards.flatMap { card in
            card.designs.map { Entry(token: Self.token(cardID: card.id, designID: $0.id), card: card, design: $0) }
        }
    }

    func entry(for token: String) -> Entry? {
        entries.first { $0.token == token }
    }

    // Older backups store bundle names. Keep those choices working after the
    // artwork moves out of the app, including before the first manifest fetch.
    static let legacyCardIDs = [
        "suica": "jp/suica", "pasmo": "jp/pasmo", "icoca": "jp/icoca",
        "hayakaken": "jp/hayakaken", "sugoca": "jp/sugoca", "manaca": "jp/manaca",
        "kitaca": "jp/kitaca", "nimoca": "jp/nimoca", "toica": "jp/toica",
        "okica": "jp/okica", "edy": "jp/edy", "waon": "jp/waon", "nanaco": "jp/nanaco",
        "ezlink": "sg/ezlink", "ezl": "kr/ezl", "tmoney": "kr/tmoney",
        "climate-card": "kr/climate-card", "la-carte": "fr/la-carte",
        "la-carte-blue": "fr/la-carte", "umoney": "mn/umoney",
    ]
    static let offlineAssets: Set<String> = ["suica", "pasmo", "icoca", "tmoney", "ezl"]

    static func publishedToken(for fileName: String) -> String? {
        if isToken(fileName) { return fileName }
        guard let cardID = legacyCardIDs[fileName] else { return nil }
        return token(cardID: cardID, designID: fileName == "la-carte-blue" ? "blue" : "default")
    }

    static func offlineAsset(for fileName: String) -> String? {
        offlineAssets.first { $0 == fileName || publishedToken(for: $0) == fileName }
    }

    func faceToken(for card: SavedCardRecord) -> String? {
        guard card.isUsingImage != false else { return nil }
        if let fileName = card.faceImageFileName {
            return entryForBundledAsset(fileName)?.token ?? Self.publishedToken(for: fileName)
        }
        guard let matched = match(card.remoteFaceMatchInput),
              let design = matched.designs.first(where: { $0.id == "default" }) else { return nil }
        return Self.token(cardID: matched.id, designID: design.id)
    }

    func entryForBundledAsset(_ asset: String) -> Entry? {
        entries.first { $0.design.bundledAsset == asset }
    }

    /// T-Union city code, then City Union city code, then the longest card
    /// number prefix, then the longest family-name substring, then the serial
    /// prefix that Japanese cards print before their number.
    func match(_ input: RemoteFaceMatchInput) -> Card? {
        for code in input.tUnionCityCodes.map({ $0.uppercased() }) {
            if let card = cards.first(where: { $0.match.cityCodes.contains(code) }) { return card }
        }
        for code in input.cityUnionCodes.map({ $0.uppercased() }) {
            if let card = cards.first(where: { $0.match.cityUnionCodes.contains(code) }) { return card }
        }
        let digits = input.serialNumbers.map { $0.filter { $0.isASCII && $0.isNumber } }.filter { !$0.isEmpty }
        if let card = longestMatch(\.cardPrefixes, where: { prefix in digits.contains { $0.hasPrefix(prefix) } }) {
            return card
        }
        let family = input.family.lowercased()
        if !family.isEmpty, let card = longestMatch(\.families, where: { family.contains($0) }) {
            return card
        }
        let serials = input.serialNumbers.map { $0.uppercased().filter { $0.isLetter || $0.isNumber } }
        return longestMatch(\.serialPrefixes, where: { prefix in serials.contains { $0.hasPrefix(prefix) } })
    }

    /// Keep all designs for the physical card ahead of related city cards and
    /// the rest of the collection, regardless of the artwork currently chosen.
    func pickerEntries(matching matched: Card?) -> [Entry] {
        let exact = entries.filter { $0.card.id == matched?.id }
        let city = entries.filter { $0.card.id != matched?.id && isPickerMatch($0.card, matching: matched) }
        let others = entries.filter { !isPickerMatch($0.card, matching: matched) }
        return exact + city + others
    }

    func isPickerMatch(_ card: Card, matching matched: Card?) -> Bool {
        guard let matched else { return false }
        if card.id == matched.id { return true }
        guard card.id.prefix(3) == matched.id.prefix(3) else { return false }
        if !Set(card.match.cityCodes).isDisjoint(with: matched.match.cityCodes) ||
            !Set(card.match.cityUnionCodes).isDisjoint(with: matched.match.cityUnionCodes) {
            return true
        }
        let names = Set(card.city?.values.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty } ?? [])
        let matchedNames = matched.city?.values.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty } ?? []
        return !names.isDisjoint(with: matchedNames)
    }

    private func longestMatch(_ key: KeyPath<Match, [String]>, where matches: (String) -> Bool) -> Card? {
        var best: (card: Card, length: Int)?
        for card in cards {
            for value in card.match[keyPath: key] where matches(value) && value.count > (best?.length ?? 0) {
                best = (card, value.count)
            }
        }
        return best?.card
    }
}

struct RemoteFaceMatchInput: Equatable {
    var tUnionCityCodes: [String] = []
    var cityUnionCodes: [String] = []
    var serialNumbers: [String] = []
    var family: String = ""
}

extension RemoteFaceManifest.Entry {
    /// A short tile title: the design name for alternates, otherwise the city
    /// for Chinese cards and the card name elsewhere.
    func title(languages: [String] = Locale.preferredLanguages) -> String {
        let names = design.id == "default" ? nil : design.name
        return Self.localized(names, languages: languages)
            ?? Self.localized(card.city, languages: languages)
            ?? Self.localized(card.name, languages: languages)
            ?? card.id
    }

    static func localized(_ names: [String: String]?, languages: [String]) -> String? {
        guard let names, !names.isEmpty else { return nil }
        for language in languages {
            let code = String(language.prefix { $0 != "-" && $0 != "_" }).lowercased()
            if let name = names[code] { return name }
        }
        return names["en"] ?? names.values.sorted().first
    }
}

extension SavedCardRecord {
    var remoteFaceMatchInput: RemoteFaceMatchInput {
        let apps = applications ?? []
        return RemoteFaceMatchInput(
            tUnionCityCodes: apps.filter(\.isTUnion).compactMap(\.cityCode),
            cityUnionCodes: apps.filter(\.isCityUnion).compactMap(\.cityCode),
            serialNumbers: ([realSerialNumber] + apps.map(\.serialNumber)).compactMap { $0 },
            family: cardFamily
        )
    }
}

final class RemoteCardFaceCatalog: @unchecked Sendable {
    static let shared = RemoteCardFaceCatalog()
    /// Cloudflare Pages first; jsDelivr is reachable from mainland China.
    static let baseURLs = [
        URL(string: "https://faces.cardb.al/")!,
        URL(string: "https://cdn.jsdelivr.net/gh/iebb/card-faces@master/")!,
        URL(string: "https://raw.githubusercontent.com/iebb/card-faces/master/")!,
    ]
    private static let refreshInterval: TimeInterval = 24 * 60 * 60
    private static let lastRefreshKey = "remote_card_faces_refreshed_at"

    let directory: URL
    private let session: URLSession
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cachedManifest: RemoteFaceManifest?
    private var refreshRequest: (id: UUID, task: Task<Set<String>?, Never>)?

    init(directory: URL? = nil, session: URLSession = .shared, defaults: UserDefaults = .standard) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.directory = directory ?? base.appendingPathComponent("CardBal/RemoteFaces", isDirectory: true)
        self.session = session
        self.defaults = defaults
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(RemoteFaceManifest.self, from: data),
           manifest.schemaVersion == RemoteFaceManifest.supportedSchemaVersion {
            cachedManifest = manifest
        }
    }

    var manifest: RemoteFaceManifest? { lock.withLock { cachedManifest } }

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    private func fileURL(for token: String) -> URL { directory.appendingPathComponent(token) }

    func cachedImage(for token: String) -> UIImage? {
        guard RemoteFaceManifest.isToken(token) else { return nil }
        return UIImage(contentsOfFile: fileURL(for: token).path)
    }

    /// Fetches the manifest at most once a day. Returns the tokens whose cached
    /// file no longer matches it, or nil when nothing was fetched.
    @discardableResult
    func refreshIfNeeded(force: Bool = false) async -> Set<String>? {
        let request = lock.withLock { () -> (id: UUID, task: Task<Set<String>?, Never>)? in
            if let refreshRequest { return refreshRequest }
            let last = defaults.object(forKey: Self.lastRefreshKey) as? Date ?? .distantPast
            guard force || cachedManifest == nil || Date().timeIntervalSince(last) > Self.refreshInterval else {
                return nil
            }
            let request = (id: UUID(), task: Task { await self.fetchManifest() })
            refreshRequest = request
            return request
        }
        guard let request else { return nil }
        let stale = await request.task.value
        lock.withLock {
            if refreshRequest?.id == request.id { refreshRequest = nil }
        }
        return stale
    }

    private func fetchManifest() async -> Set<String>? {
        for base in Self.baseURLs {
            let request = URLRequest(url: base.appendingPathComponent("manifest.json"),
                                     cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let manifest = try? JSONDecoder().decode(RemoteFaceManifest.self, from: data),
                  manifest.schemaVersion == RemoteFaceManifest.supportedSchemaVersion else { continue }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: manifestURL, options: .atomic)
            lock.withLock {
                cachedManifest = manifest
                defaults.set(Date(), forKey: Self.lastRefreshKey)
            }
            return removeStaleFaces(manifest)
        }
        return nil
    }

    /// Returns the cached face or downloads it, trying each mirror in turn.
    func image(for token: String) async -> UIImage? {
        if let image = cachedImage(for: token) { return image }
        if manifest?.entry(for: token) == nil {
            await refreshIfNeeded(force: manifest != nil)
        }
        guard let design = manifest?.entry(for: token)?.design else { return nil }
        for base in Self.baseURLs {
            guard var components = URLComponents(url: base.appendingPathComponent(design.file), resolvingAgainstBaseURL: false) else { continue }
            components.queryItems = [URLQueryItem(name: "v", value: String(design.sha256.prefix(12)))]
            guard let url = components.url,
                  let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count == design.bytes, data.count < RemoteFaceManifest.maxFaceBytes,
                  Self.sha256(data) == design.sha256.lowercased(),
                  let image = UIImage(data: data) else { continue }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: fileURL(for: token), options: .atomic)
            return image
        }
        return nil
    }

    private func removeStaleFaces(_ manifest: RemoteFaceManifest) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var stale: Set<String> = []
        for name in names where RemoteFaceManifest.isToken(name) {
            let url = fileURL(for: name)
            let current = manifest.entry(for: name)?.design.sha256.lowercased()
            if let data = try? Data(contentsOf: url), Self.sha256(data) == current { continue }
            try? FileManager.default.removeItem(at: url)
            stale.insert(name)
        }
        return stale
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
