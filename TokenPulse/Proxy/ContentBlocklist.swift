import Foundation

/// One configured blocklist row: a blocking keyword (or `re:`-prefixed regex)
/// plus an optional list of exception patterns. A blocking match at position P
/// is exempted only when its full range is contained within a match of one of
/// the entry's `whitelist` patterns — broad rules are narrowed to specific
/// safe spans (e.g. block `~/` but exempt `~/.tokenpulse`) without globally
/// disabling the rule whenever the exception happens to appear elsewhere in
/// the same request.
struct ContentBlocklistEntry: Sendable, Codable, Equatable {
    var keyword: String
    var whitelist: [String]

    init(keyword: String, whitelist: [String] = []) {
        self.keyword = keyword
        self.whitelist = whitelist
    }
}

/// A compiled set of content-blocking rules built from user-configured entries.
/// Each rule has its own optional whitelist; a blocking match is bypassed only
/// when its full range is covered by some whitelist match in the same text, so
/// a request that mixes legitimate (whitelisted) and disallowed occurrences of
/// the same keyword is still blocked. Substring rules use case-insensitive
/// literal matching; `re:`-prefixed rules are compiled as
/// `NSRegularExpression` (case-insensitive).
///
/// Instances are value-semantic (`Sendable`) and are created once at proxy
/// start, then passed to `ProxyForwarder` for use on the forwarding hot path.
struct ContentBlocklist: Sendable {

    private enum Matcher: Sendable {
        /// Plain case-insensitive substring match. The needle is the raw
        /// (whitespace-trimmed) keyword; case folding happens in the
        /// matching call via `.caseInsensitive`.
        case substring(needle: String)
        /// Regex match compiled from the text after the `re:` prefix.
        case regex(NSRegularExpression)
    }

    private struct CompiledRule: Sendable {
        /// The original user-entered string for the blocking keyword
        /// (including any `re:` prefix). Used in match results so the
        /// surfaced error names the rule the user wrote.
        let original: String
        let matcher: Matcher
        /// Compiled exception patterns. Empty when no exceptions configured.
        let whitelist: [Matcher]
    }

    struct Match: Sendable {
        /// The original user-entered string (including any `re:` prefix).
        let rule: String
    }

    private let rules: [CompiledRule]

    /// True when no rules were compiled — callers can skip scanning entirely.
    var isEmpty: Bool { rules.isEmpty }

    /// Compile `entries` into rules. Blank/whitespace-only blocking keywords
    /// drop the entire entry; blank/whitespace-only or invalid whitelist
    /// patterns are dropped individually so the rest of the rule remains
    /// active. Invalid or empty regex patterns are logged via `ProxyLogger`.
    init(entries: [ContentBlocklistEntry]) {
        var compiled: [CompiledRule] = []
        for entry in entries {
            guard let matcher = Self.compileMatcher(from: entry.keyword, role: .keyword) else { continue }
            let whitelistMatchers = entry.whitelist.compactMap { pattern in
                Self.compileMatcher(from: pattern, role: .whitelist(forKeyword: entry.keyword))
            }
            compiled.append(
                CompiledRule(
                    original: entry.keyword,
                    matcher: matcher,
                    whitelist: whitelistMatchers
                )
            )
        }
        self.rules = compiled
    }

    /// Return the first rule that has at least one blocking occurrence not
    /// covered by any of the rule's whitelist matches, or `nil` when every
    /// blocking occurrence is exempted (or no rule matches at all).
    func firstMatch(in text: String) -> Match? {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        for rule in rules {
            let blockingRanges = Self.matchRanges(of: rule.matcher, in: text, nsText: nsText, fullRange: fullRange)
            guard !blockingRanges.isEmpty else { continue }

            let whitelistRanges: [NSRange]
            if rule.whitelist.isEmpty {
                whitelistRanges = []
            } else {
                whitelistRanges = rule.whitelist.flatMap {
                    Self.matchRanges(of: $0, in: text, nsText: nsText, fullRange: fullRange)
                }
            }

            let hasUncovered = blockingRanges.contains { blocking in
                !whitelistRanges.contains { Self.range($0, contains: blocking) }
            }
            if hasUncovered {
                return Match(rule: rule.original)
            }
        }
        return nil
    }

    // MARK: - Compilation helpers

    private enum CompileRole {
        case keyword
        case whitelist(forKeyword: String)

        var description: String {
            switch self {
            case .keyword:
                return "keyword"
            case .whitelist(let keyword):
                return "whitelist pattern for '\(keyword)'"
            }
        }
    }

    private static func compileMatcher(from raw: String, role: CompileRole) -> Matcher? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("re:") {
            let pattern = String(trimmed.dropFirst(3))
            guard !pattern.trimmingCharacters(in: .whitespaces).isEmpty else {
                ProxyLogger.log("ContentBlocklist: empty regex pattern in \(role.description) — rule dropped")
                return nil
            }
            do {
                let regex = try NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive]
                )
                return .regex(regex)
            } catch {
                ProxyLogger.log("ContentBlocklist: invalid regex '\(pattern)' in \(role.description): \(error.localizedDescription) — rule dropped")
                return nil
            }
        }
        return .substring(needle: trimmed)
    }

    /// True when `outer` fully contains `inner`. Equivalent to Foundation's
    /// `NSContainsRange`, which is not bridged to Swift.
    private static func range(_ outer: NSRange, contains inner: NSRange) -> Bool {
        outer.location <= inner.location
            && (outer.location + outer.length) >= (inner.location + inner.length)
    }

    /// Find every occurrence of `matcher` in `text`. Substring matches use
    /// case-insensitive literal comparison; regex matches use the compiled
    /// `NSRegularExpression`. Empty-length matches advance by one position so
    /// pathological zero-width regex patterns do not loop forever.
    private static func matchRanges(
        of matcher: Matcher,
        in text: String,
        nsText: NSString,
        fullRange: NSRange
    ) -> [NSRange] {
        switch matcher {
        case .substring(let needle):
            var results: [NSRange] = []
            var searchStart = 0
            let totalLength = nsText.length
            while searchStart < totalLength {
                let searchRange = NSRange(location: searchStart, length: totalLength - searchStart)
                let r = nsText.range(of: needle, options: [.literal, .caseInsensitive], range: searchRange)
                if r.location == NSNotFound { break }
                results.append(r)
                searchStart = r.location + max(r.length, 1)
            }
            return results
        case .regex(let regex):
            return regex.matches(in: text, options: [], range: fullRange).map { $0.range }
        }
    }
}
