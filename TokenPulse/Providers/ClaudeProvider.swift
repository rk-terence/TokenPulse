import Foundation
import SwiftUI

struct ClaudeProvider: UsageProvider {
    let id = "claude"
    let displayName = "Claude"
    let shortLabel = "C"
    let brandColor = Color.orange

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func isConfigured() -> Bool {
        (try? readAccessToken()) != nil
    }

    func fetchUsage() async throws -> UsageData {
        let token = try readAccessToken()
        let request = buildRequest(token: token)
        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode == 429 {
            throw ClaudeProviderError.rateLimited
        }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ClaudeProviderError.httpError(code)
        }

        return try parseResponse(data)
    }

    func classifyError(_ error: Error) -> FailureDisposition {
        if let error = error as? KeychainError {
            switch error {
            case .itemNotFound:
                return .unconfigured
            case .invalidData:
                return .auth(String(localized: "Claude credentials changed. Sign in to Claude Code again. TokenPulse will recover automatically."))
            case .unexpectedStatus:
                return .persistent(error.localizedDescription)
            }
        }

        if let error = error as? ClaudeProviderError {
            switch error {
            case .credentialParseFailed:
                return .auth(String(localized: "Claude credentials changed. Sign in to Claude Code again. TokenPulse will recover automatically."))
            case .rateLimited:
                return .transient(String(localized: "Claude is rate limited. Showing last successful data."))
            case .httpError(401):
                return .auth(String(localized: "Claude session expired. Sign in to Claude Code. TokenPulse will recover automatically."))
            case .httpError(let code) where code >= 500:
                return .transient(String(localized: "Claude API returned HTTP \(code). Showing last successful data."))
            case .httpError(let code):
                return .persistent(String(localized: "Claude API returned HTTP \(code)"))
            }
        }

        if let error = error as? URLError {
            return classifyURLError(error)
        }

        return .persistent(error.localizedDescription)
    }

    // MARK: - Private

    private static let credentialService = "Claude Code-credentials"
    private static let baseURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private func readAccessToken() throws -> String {
        let data = try KeychainService.readGenericPassword(service: Self.credentialService)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let oauth = json?["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            throw ClaudeProviderError.credentialParseFailed
        }
        return token
    }

    private func buildRequest(token: String) -> URLRequest {
        var req = URLRequest(url: Self.baseURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("TokenPulse/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    private func parseResponse(_ data: Data) throws -> UsageData {
        let raw = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)

        let fiveHour = raw.fiveHour.map {
            WindowUsage(utilization: $0.utilization, resetsAt: $0.resetsAt)
        }
        let sevenDay = raw.sevenDay.map {
            WindowUsage(utilization: $0.utilization, resetsAt: $0.resetsAt)
        }

        var extras: [String: String] = [:]
        if let opus = raw.sevenDayOpus {
            extras["opusUtilization"] = String(format: "%.1f", opus.utilization)
            if let r = opus.resetsAt {
                extras["opusResetsAt"] = ISO8601DateFormatter().string(from: r)
            }
        }

        return UsageData(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            extras: extras,
            fetchedAt: .now
        )
    }

    private func classifyURLError(_ error: URLError) -> FailureDisposition {
        switch error.code {
        case .timedOut:
            return .transient(String(localized: "Request timed out. Showing last successful data."))
        case .notConnectedToInternet, .networkConnectionLost:
            return .transient(String(localized: "Network connection dropped. Showing last successful data."))
        default:
            return .transient(String(localized: "\(error.localizedDescription). Showing last successful data."))
        }
    }
}

// MARK: - Response model

private struct ClaudeUsageWindow: Decodable {
    let utilization: Double
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try c.decode(Double.self, forKey: .utilization)
        // Handle ISO 8601 with fractional seconds
        if let str = try c.decodeIfPresent(String.self, forKey: .resetsAt) {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetsAt = fmt.date(from: str)
        } else {
            resetsAt = nil
        }
    }
}

private struct ClaudeUsageResponse: Decodable {
    let fiveHour: ClaudeUsageWindow?
    let sevenDay: ClaudeUsageWindow?
    let sevenDayOpus: ClaudeUsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
    }
}

// MARK: - Errors

enum ClaudeProviderError: LocalizedError {
    case credentialParseFailed
    case rateLimited
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .credentialParseFailed:
            return String(localized: "Failed to parse Claude credentials from Keychain")
        case .rateLimited:
            return String(localized: "Claude API rate limited (429). Will retry later.")
        case .httpError(let code):
            return String(localized: "Claude API returned HTTP \(code)")
        }
    }
}
