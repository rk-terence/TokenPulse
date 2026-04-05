import Foundation
import SwiftUI

enum CodexConfigurationStatus {
    case connected
    case missingLogin
    case apiKeyOnly
    case invalidAuthFile
    case missingToken

    var isConfigured: Bool {
        if case .connected = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .connected:
            return String(localized: "Connected")
        case .missingLogin:
            return String(localized: "Not found")
        case .apiKeyOnly:
            return String(localized: "API key mode")
        case .invalidAuthFile:
            return String(localized: "Unreadable login")
        case .missingToken:
            return String(localized: "Missing token")
        }
    }
}

struct CodexProvider: UsageProvider {
    let id = "codex"
    let displayName = "Codex"
    let shortLabel = "X"
    let brandColor = Color.green

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func isConfigured() -> Bool {
        CodexAuthStore.configurationStatus().isConfigured
    }

    func fetchUsage() async throws -> UsageData {
        let auth = try CodexAuthStore.readChatGPTSession()
        let request = buildRequest(auth: auth)
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw CodexProviderError.httpError(-1)
        }
        if http.statusCode == 401 {
            throw CodexProviderError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CodexProviderError.httpError(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        return try buildUsageData(from: decoded)
    }

    func classifyError(_ error: Error) -> FailureDisposition {
        if let error = error as? CodexProviderError {
            switch error {
            case .authFileNotFound, .missingAccessToken, .notChatGPTAuth:
                return .unconfigured
            case .invalidAuthFile:
                return .auth(String(localized: "Codex login data is unreadable. Run `codex login` again."))
            case .unauthorized:
                return .auth(String(localized: "Codex session expired. Run `codex login` again."))
            case .httpError(429):
                return .transient(String(localized: "Codex usage endpoint is rate limited. Showing last successful data."))
            case .httpError(let code) where code >= 500:
                return .transient(String(localized: "Codex usage endpoint returned HTTP \(code). Showing last successful data."))
            case .httpError(let code):
                return .persistent(String(localized: "Codex usage endpoint returned HTTP \(code)"))
            case .invalidResponse:
                return .persistent(String(localized: "Codex returned an unexpected response shape"))
            }
        }

        if let error = error as? URLError {
            switch error.code {
            case .timedOut:
                return .transient(String(localized: "Request timed out. Showing last successful data."))
            case .notConnectedToInternet, .networkConnectionLost:
                return .transient(String(localized: "Network connection dropped. Showing last successful data."))
            default:
                return .transient(String(localized: "\(error.localizedDescription). Showing last successful data."))
            }
        }

        if error is DecodingError {
            return .persistent(String(localized: "Codex returned an unexpected response shape"))
        }

        return .persistent(error.localizedDescription)
    }

    static func configurationStatus() -> CodexConfigurationStatus {
        CodexAuthStore.configurationStatus()
    }

    private static let usageEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private func buildRequest(auth: CodexChatGPTSession) -> URLRequest {
        var req = URLRequest(url: Self.usageEndpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("TokenPulse/1.0", forHTTPHeaderField: "User-Agent")
        if let accountID = auth.accountID, !accountID.isEmpty {
            req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return req
    }

    private func buildUsageData(from response: CodexUsageResponse) throws -> UsageData {
        let primary = response.rateLimit?.primaryWindow.map { window in
            WindowUsage(
                utilization: window.usedPercent,
                resetsAt: window.resolveResetDate(relativeTo: .now)
            )
        }
        let secondary = response.rateLimit?.secondaryWindow.map { window in
            WindowUsage(
                utilization: window.usedPercent,
                resetsAt: window.resolveResetDate(relativeTo: .now)
            )
        }

        guard primary != nil || secondary != nil else {
            throw CodexProviderError.invalidResponse
        }

        var extras: [String: String] = [
            "primaryWindowLabel": "5h",
            "secondaryWindowLabel": "7d",
        ]

        if let planType = response.planType, !planType.isEmpty {
            extras["planType"] = planType
        }

        return UsageData(
            fiveHour: primary,
            sevenDay: secondary,
            extras: extras,
            fetchedAt: .now
        )
    }
}

struct CodexChatGPTSession: Sendable {
    let accessToken: String
    let accountID: String?
}

private enum CodexAuthStore {
    private static let authFileName = "auth.json"

    static func configurationStatus() -> CodexConfigurationStatus {
        do {
            _ = try readChatGPTSession()
            return .connected
        } catch let error as CodexProviderError {
            switch error {
            case .authFileNotFound:
                return .missingLogin
            case .notChatGPTAuth:
                return .apiKeyOnly
            case .invalidAuthFile:
                return .invalidAuthFile
            case .missingAccessToken:
                return .missingToken
            case .unauthorized, .httpError(_), .invalidResponse:
                return .missingToken
            }
        } catch {
            return .invalidAuthFile
        }
    }

    static func readChatGPTSession() throws -> CodexChatGPTSession {
        let url = try authFileURL()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CodexProviderError.invalidAuthFile
        }

        let auth: CodexAuthFile
        do {
            auth = try JSONDecoder().decode(CodexAuthFile.self, from: data)
        } catch {
            throw CodexProviderError.invalidAuthFile
        }

        guard auth.authMode?.lowercased() == "chatgpt" else {
            throw CodexProviderError.notChatGPTAuth
        }

        guard let accessToken = auth.tokens?.accessToken,
              !accessToken.isEmpty else {
            throw CodexProviderError.missingAccessToken
        }

        return CodexChatGPTSession(
            accessToken: accessToken,
            accountID: auth.tokens?.accountID
        )
    }

    private static func authFileURL() throws -> URL {
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            let candidate = URL(fileURLWithPath: codexHome, isDirectory: true).appendingPathComponent(authFileName)
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                throw CodexProviderError.authFileNotFound
            }
            return candidate
        }

        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent(authFileName)
        guard FileManager.default.fileExists(atPath: fallback.path) else {
            throw CodexProviderError.authFileNotFound
        }
        return fallback
    }
}

private struct CodexAuthFile: Decodable {
    let authMode: String?
    let tokens: CodexAuthTokens?

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case tokens
    }
}

private struct CodexAuthTokens: Decodable {
    let accessToken: String?
    let accountID: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accountID = "account_id"
    }
}

private struct CodexUsageResponse: Decodable {
    let planType: String?
    let rateLimit: CodexRateLimit?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }
}

private struct CodexRateLimit: Decodable {
    let primaryWindow: CodexRateLimitWindow?
    let secondaryWindow: CodexRateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexRateLimitWindow: Decodable {
    let usedPercent: Double
    let resetAfterSeconds: Double?
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case utilization
        case resetAfterSeconds = "reset_after_seconds"
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let value = try container.decodeLossyDouble(forKey: .usedPercent) {
            usedPercent = value
        } else if let value = try container.decodeLossyDouble(forKey: .utilization) {
            usedPercent = value
        } else {
            throw CodexProviderError.invalidResponse
        }

        resetAfterSeconds = try container.decodeLossyDouble(forKey: .resetAfterSeconds)
        resetsAt = try container.decodeFlexibleDate(forKey: .resetsAt)
    }

    func resolveResetDate(relativeTo now: Date) -> Date? {
        if let resetsAt {
            return resetsAt
        }
        guard let resetAfterSeconds else { return nil }
        return now.addingTimeInterval(resetAfterSeconds)
    }

}

private extension KeyedDecodingContainer {
    func decodeLossyDouble(forKey key: Key) throws -> Double? {
        if let value = try decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try decodeIfPresent(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }

    func decodeFlexibleDate(forKey key: Key) throws -> Date? {
        if let unixSeconds = try decodeLossyDouble(forKey: key) {
            return Date(timeIntervalSince1970: unixSeconds)
        }

        guard let string = try decodeIfPresent(String.self, forKey: key) else {
            return nil
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: string) {
            return date
        }

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]
        return fallbackFormatter.date(from: string)
    }
}

enum CodexProviderError: LocalizedError {
    case authFileNotFound
    case invalidAuthFile
    case notChatGPTAuth
    case missingAccessToken
    case unauthorized
    case httpError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .authFileNotFound:
            return String(localized: "Codex login not found")
        case .invalidAuthFile:
            return String(localized: "Codex login data is unreadable")
        case .notChatGPTAuth:
            return String(localized: "Codex is using API key auth instead of ChatGPT login")
        case .missingAccessToken:
            return String(localized: "Codex ChatGPT access token is missing")
        case .unauthorized:
            return String(localized: "Codex ChatGPT session expired")
        case .httpError(let code):
            return String(localized: "Codex usage endpoint returned HTTP \(code)")
        case .invalidResponse:
            return String(localized: "Codex usage endpoint returned an unexpected response shape")
        }
    }
}
