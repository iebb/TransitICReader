import Foundation

/// A short, rolling record of recent scan steps, kept on this device to help fix
/// reading problems. It leaves the device only when the person taps Copy in Settings.
///
/// Lines must never hold raw card responses or command payloads, session or device
/// identifiers, or the enquiry server address. Shorten card numbers and other card
/// identifiers with `shortened(_:)`.
final class DebugLog: @unchecked Sendable {
    static let shared = DebugLog(fileURL: DebugLog.defaultFileURL())
    static let lineLimit = 600
    private static let messageLimit = 400

    private let lock = NSLock()
    private let fileURL: URL?
    private var lines: [String] = []
    private var isLoaded = false
    private var isWriteScheduled = false
    private let writer = DispatchQueue(label: "ad.neko.cardbal.debug-log", qos: .utility)
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Without a file the log stays in memory only.
    init(fileURL: URL?) { self.fileURL = fileURL }

    /// Application Support, excluded from backup. Command-line harnesses have no
    /// bundle identifier and keep their log in memory.
    private static func defaultFileURL() -> URL? {
        guard Bundle.main.bundleIdentifier != nil,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("DebugLog", isDirectory: true).appendingPathComponent("debug-log.txt")
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return lines.isEmpty
    }

    /// Adds one line. Cheap, never throws; the file is written shortly afterwards.
    func log(_ category: String, _ message: String) {
        let now = Date()
        lock.lock()
        loadIfNeeded()
        lines.append(formatter.string(from: now) + " [" + Self.singleLine(category, limit: 24) + "] "
                     + Self.singleLine(message, limit: Self.messageLimit))
        if lines.count > Self.lineLimit { lines.removeFirst(lines.count - Self.lineLimit) }
        let schedule = fileURL != nil && !isWriteScheduled
        if schedule { isWriteScheduled = true }
        lock.unlock()
        if schedule { writer.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.persist() } }
    }

    /// The recorded lines, oldest first.
    func text() -> String {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return lines.joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        isLoaded = true
        lines.removeAll()
        lock.unlock()
        if fileURL != nil { writer.async { [weak self] in self?.persist() } }
    }

    /// What Copy puts on the pasteboard: a short header, then the lines.
    func exportText(details: [String] = []) -> String {
        let header = ["CardBal Debug Log",
                      "App: " + Self.appVersion,
                      "System: " + Self.systemVersion,
                      "Device: " + Self.deviceModel] + details
        return (header + ["", text()]).joined(separator: "\n") + "\n"
    }

    // MARK: Formatting helpers

    /// Only the last four characters, e.g. "…1A2B", so a pasted log never holds a full card number.
    static func shortened(_ identifier: String) -> String {
        let compact = identifier.filter { $0.isLetter || $0.isNumber }
        return compact.isEmpty ? "(none)" : "…" + String(compact.suffix(4))
    }

    static func shortened(_ identifier: Data) -> String {
        shortened(identifier.map { String(format: "%02X", $0) }.joined())
    }

    static func hex(_ byte: UInt8) -> String { String(format: "0x%02X", byte) }

    /// Error type and case, or domain and code. URL errors give only their code,
    /// so no server address reaches the log.
    static func describe(_ error: Error) -> String {
        if let url = error as? URLError {
            return "URLError \(url.errorCode)" + (urlErrorName(url.code).map { " (\($0))" } ?? "")
        }
        if Mirror(reflecting: error).displayStyle == .enum {
            return String(describing: type(of: error)) + "." + String(describing: error)
        }
        let error = error as NSError
        return "\(error.domain) code \(error.code): \(error.localizedDescription)"
    }

    private static func urlErrorName(_ code: URLError.Code) -> String? {
        switch code {
        case .cancelled: return "cancelled"
        case .timedOut: return "timed out"
        case .cannotFindHost: return "cannot find host"
        case .cannotConnectToHost: return "cannot connect to host"
        case .networkConnectionLost: return "network connection lost"
        case .dnsLookupFailed: return "DNS lookup failed"
        case .notConnectedToInternet: return "not connected to the internet"
        case .badServerResponse: return "bad server response"
        case .secureConnectionFailed: return "secure connection failed"
        case .serverCertificateUntrusted: return "server certificate untrusted"
        case .dataNotAllowed: return "data not allowed"
        default: return nil
        }
    }

    private static func singleLine(_ text: String, limit: Int) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        if result.count > limit { result = String(result.prefix(limit)) + "…" }
        return result
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    private static var systemVersion: String {
        let process = ProcessInfo.processInfo
        let version = process.operatingSystemVersion
        let number = "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        if process.isMacCatalystApp { return "macOS \(number) (Mac Catalyst)" }
        if #available(iOS 14.0, macOS 11.0, *), process.isiOSAppOnMac { return "\(number) (iPad app on Mac)" }
        #if os(iOS)
        return "iOS \(number)"
        #else
        return number
        #endif
    }

    private static var deviceModel: String {
        #if targetEnvironment(simulator)
        if let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return model + " (Simulator)" }
        #endif
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: Storage

    /// Call with the lock held.
    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let stored = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        lines = Array((stored + lines).suffix(Self.lineLimit))
    }

    private func persist() {
        lock.lock()
        isWriteScheduled = false
        let contents = lines.joined(separator: "\n")
        lock.unlock()
        guard let fileURL else { return }
        let manager = FileManager.default
        if contents.isEmpty {
            try? manager.removeItem(at: fileURL)
            return
        }
        var directory = fileURL.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        if !manager.fileExists(atPath: directory.path) {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try? directory.setResourceValues(values)
        }
        var file = fileURL
        guard (try? Data(contents.utf8).write(to: file, options: .atomic)) != nil else { return }
        // An atomic write replaces the file, so mark the new one too.
        try? file.setResourceValues(values)
    }
}
