import Foundation

/// The invocation is navigation only. Never read card data or scan options from a URL.
struct ClipInvocation: Equatable {
    static let bundleID = "ad.neko.cardbal.Clip"
    static let defaultURL = URL(string: "https://appclip.apple.com/id?p=ad.neko.cardbal.Clip")!

    init?(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "appclip.apple.com",
              components.port == nil,
              components.user == nil, components.password == nil,
              components.path == "/id" else { return nil }
        let identifiers = (components.queryItems ?? []).filter { $0.name == "p" }
        guard identifiers.count == 1, identifiers[0].value == Self.bundleID else { return nil }
        // All other parameters are ignored, including duplicates and apparent scan commands.
    }
}
