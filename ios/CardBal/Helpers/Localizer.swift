import Foundation

/// Localizes app-owned labels, including English labels persisted in older wallets.
/// User names, identifiers and raw card bytes should be displayed verbatim.
struct Localizer {
    private static let languages = ["en", "zh-Hans", "ja", "ko"]
    private static let tables: [String: [String: String]] = Dictionary(uniqueKeysWithValues: languages.map { language in
        let path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language)
        let table = path.flatMap { NSDictionary(contentsOfFile: $0) as? [String: String] } ?? [:]
        return (language, table)
    })
    private static let aliases: [String: String] = {
        var result = Dictionary(uniqueKeysWithValues: (tables["en"] ?? [:]).keys.map { ($0, $0) })
        for (key, value) in (tables["en"] ?? [:]).sorted(by: { $0.key < $1.key }) where result[value] == nil {
            result[value] = key
        }
        return result
    }()
    private static let placeholder = try! NSRegularExpression(
        pattern: #"%(?:(\d+)\$)?[-+0 #]*\d*(?:\.\d+)?(?:ll|l)?([@diuoxXfFeEgGs])"#
    )
    private struct Pattern {
        let source: String
        let key: String
        let regex: NSRegularExpression
    }
    private static let patterns: [Pattern] = aliases.compactMap { source, key in
        let range = NSRange(source.startIndex..., in: source)
        let matches = placeholder.matches(in: source, range: range)
        guard !matches.isEmpty else { return nil }
        let literal = placeholder.stringByReplacingMatches(in: source, range: range, withTemplate: "")
        guard literal.range(of: "[A-Za-z]{2}", options: .regularExpression) != nil else { return nil }
        var expression = "^"
        var offset = 0
        let text = source as NSString
        for match in matches {
            expression += NSRegularExpression.escapedPattern(for: text.substring(with: NSRange(location: offset, length: match.range.location - offset)))
            let type = text.substring(with: match.range(at: 2))
            expression += type == "@" || type == "s" ? "(.+?)" : "([-+0-9A-Fa-f.,]+)"
            offset = NSMaxRange(match.range)
        }
        expression += NSRegularExpression.escapedPattern(for: text.substring(from: offset)) + "$"
        guard let regex = try? NSRegularExpression(pattern: expression, options: [.dotMatchesLineSeparators]) else { return nil }
        return Pattern(source: source, key: key, regex: regex)
    }.sorted { $0.source.count > $1.source.count }

    static func localize(_ text: String, preferredLocale: String? = nil) -> String {
        let locale = preferredLocale ?? Bundle.main.preferredLocalizations.first ?? "en"
        let language = locale.hasPrefix("zh") ? "zh-Hans" : languages.first(where: { locale.hasPrefix($0) }) ?? "en"
        return translate(text, language: language, depth: 0)
    }

    private static func translate(_ text: String, language: String, depth: Int) -> String {
        guard depth < 5, !text.isEmpty else { return text }
        let table = tables[language] ?? [:]
        if let key = aliases[text], let value = table[key] { return value }
        for pattern in patterns {
            guard let match = pattern.regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let template = table[pattern.key] else { continue }
            let source = text as NSString
            let arguments = (1..<match.numberOfRanges).map {
                translate(source.substring(with: match.range(at: $0)), language: language, depth: depth + 1)
            }
            let result = NSMutableString(string: template)
            let matches = placeholder.matches(in: template, range: NSRange(template.startIndex..., in: template))
            for (index, token) in matches.enumerated().reversed() {
                let position = token.range(at: 1).location == NSNotFound ? index : (Int((template as NSString).substring(with: token.range(at: 1))) ?? 1) - 1
                if arguments.indices.contains(position) { result.replaceCharacters(in: token.range, with: arguments[position]) }
            }
            return result as String
        }
        // Protocol suffixes and application-qualified labels keep their data intact.
        if let open = text.range(of: " ("), text.hasSuffix(")") {
            let prefix = String(text[..<open.lowerBound])
            let translated = translate(prefix, language: language, depth: depth + 1)
            if translated != prefix { return translated + text[open.lowerBound...] }
        }
        for separator in ["\n", " · ", ": ", " / ", " + ", " → ", " -> "] where text.contains(separator) {
            return text.components(separatedBy: separator)
                .map { translate($0, language: language, depth: depth + 1) }.joined(separator: separator)
        }
        return text
    }
}
