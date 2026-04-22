import Foundation

/// A compiled set of content-blocking rules built from user-configured keyword strings.
/// Substring rules use case-insensitive literal matching; `re:`-prefixed rules are
/// compiled as `NSRegularExpression` (case-insensitive).
///
/// Instances are value-semantic (`Sendable`) and are created once at proxy start,
/// then passed to `ProxyForwarder` for use on the forwarding hot path.
struct ContentBlocklist: Sendable {

    enum Rule: Sendable {
        /// Plain case-insensitive substring match. `needle` is the lowercased form of
        /// the original keyword (minus the optional `re:` prefix).
        case substring(original: String, needle: String)
        /// Regex match compiled from the text after the `re:` prefix.
        case regex(original: String, regex: NSRegularExpression)
    }

    struct Match: Sendable {
        /// The original user-entered string (including any `re:` prefix).
        let rule: String
    }

    private let rules: [Rule]

    /// True when no rules were compiled — callers can skip scanning entirely.
    var isEmpty: Bool { rules.isEmpty }

    /// Compile `keywords` into rules. Blank/whitespace-only entries are dropped.
    /// Invalid regex patterns are logged via `ProxyLogger` and dropped; other
    /// rules remain active.
    init(keywords: [String]) {
        var compiled: [Rule] = []
        for raw in keywords {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("re:") {
                let pattern = String(trimmed.dropFirst(3))
                do {
                    let regex = try NSRegularExpression(
                        pattern: pattern,
                        options: [.caseInsensitive]
                    )
                    compiled.append(.regex(original: raw, regex: regex))
                } catch {
                    ProxyLogger.log("ContentBlocklist: invalid regex '\(pattern)': \(error.localizedDescription) — rule dropped")
                }
            } else {
                compiled.append(.substring(original: raw, needle: trimmed.lowercased()))
            }
        }
        self.rules = compiled
    }

    /// Return the first rule that matches `text`, or `nil` if no rule matches.
    func firstMatch(in text: String) -> Match? {
        let lowered = text.lowercased()
        let range = NSRange(text.startIndex..., in: text)
        for rule in rules {
            switch rule {
            case .substring(let original, let needle):
                if lowered.range(of: needle, options: [.literal]) != nil {
                    return Match(rule: original)
                }
            case .regex(let original, let regex):
                if regex.firstMatch(in: text, options: [], range: range) != nil {
                    return Match(rule: original)
                }
            }
        }
        return nil
    }
}
