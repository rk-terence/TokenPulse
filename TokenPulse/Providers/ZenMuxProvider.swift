import Foundation
import SwiftUI

struct ZenMuxProvider: UsageProvider {
    let id = "zenmux"
    let displayName = "ZenMux"
    let shortLabel = "Z"
    let brandColor = Color.blue

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func isConfigured() -> Bool {
        (try? KeychainService.readGenericPassword(service: Self.keychainService)) != nil
    }

    func fetchUsage() async throws -> UsageData {
        let keyData = try KeychainService.readGenericPassword(service: Self.keychainService)
        guard let apiKey = String(data: keyData, encoding: .utf8) else {
            throw ZenMuxProviderError.missingAPIKey
        }

        // Fetch management API (primary) and subscription summary (optional) concurrently
        let cookies = try? ChromeCookieService.extractZenMuxCookies()

        async let primaryFetch = fetchManagementAPI(apiKey: apiKey)
        async let summaryFetch = fetchSubscriptionSummary(cookies: cookies)

        let primaryData = try await primaryFetch
        let summaryData = await summaryFetch

        return buildUsageData(primary: primaryData, summary: summaryData)
    }

    func classifyError(_ error: Error) -> FailureDisposition {
        if let error = error as? KeychainError {
            switch error {
            case .itemNotFound:
                return .unconfigured
            case .invalidData, .unexpectedStatus:
                return .persistent(error.localizedDescription)
            }
        }

        if let error = error as? ZenMuxProviderError {
            switch error {
            case .missingAPIKey:
                return .unconfigured
            case .httpError(let code) where code == 422 || code == 429 || code >= 500:
                return .transient(String(localized: "ZenMux API returned HTTP \(code). Showing last successful data."))
            case .httpError(401), .httpError(403):
                return .persistent(String(localized: "ZenMux API key was rejected. Update it in Settings."))
            case .httpError(let code):
                return .persistent(String(localized: "ZenMux API returned HTTP \(code)"))
            }
        }

        if let error = error as? URLError {
            return classifyURLError(error)
        }

        return .persistent(error.localizedDescription)
    }

    // MARK: - Internal

    static let keychainService = "TokenPulse-ZenMuxAPIKey"

    private static let managementEndpoint = "https://zenmux.ai/api/v1/management/subscription/detail"
    private static let summaryEndpoint = "https://zenmux.ai/api/dashboard/cost/query/subscription_summary"

    // MARK: - Management API (primary)

    private func fetchManagementAPI(apiKey: String) async throws -> ZenMuxData {
        var req = URLRequest(url: URL(string: Self.managementEndpoint)!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("TokenPulse/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: req)

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ZenMuxProviderError.httpError(code)
        }

        return try JSONDecoder().decode(ZenMuxResponse.self, from: data).data
    }

    // MARK: - Subscription summary (optional, cookie-based)

    private func fetchSubscriptionSummary(cookies: ZenMuxCookies?) async -> ZenMuxSummaryData? {
        guard let cookies else { return nil }

        var components = URLComponents(string: Self.summaryEndpoint)!
        components.queryItems = [URLQueryItem(name: "ctoken", value: cookies.ctoken)]

        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        let cookieHeader = "ctoken=\(cookies.ctoken); sessionId=\(cookies.sessionId); sessionId.sig=\(cookies.sessionIdSig)"
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("TokenPulse/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode(ZenMuxSummaryResponse.self, from: data).data
        } catch {
            return nil
        }
    }

    // MARK: - Build UsageData

    private func buildUsageData(primary d: ZenMuxData, summary: ZenMuxSummaryData?) -> UsageData {
        let fiveHour = d.quota5Hour.map { q in
            WindowUsage(utilization: (q.usagePercentage ?? 0) * 100.0, resetsAt: parseISO8601(q.resetsAt))
        }
        let sevenDay = d.quota7Day.map { q in
            WindowUsage(utilization: (q.usagePercentage ?? 0) * 100.0, resetsAt: parseISO8601(q.resetsAt))
        }

        var extras: [String: String] = [:]
        extras["tier"] = d.plan.tier
        extras["accountStatus"] = d.accountStatus
        extras["effectiveUsdPerFlow"] = String(format: "%.5f", d.effectiveUsdPerFlow)
        if let q = d.quota5Hour {
            if let v = q.usedFlows { extras["5hUsedFlows"] = String(format: "%.2f", v) }
            if let v = q.remainingFlows { extras["5hRemainingFlows"] = String(format: "%.2f", v) }
            if let v = q.maxFlows { extras["5hMaxFlows"] = String(format: "%.0f", v) }
            if let v = q.usedValueUsd { extras["5hUsedUsd"] = String(format: "%.2f", v) }
            if let v = q.maxValueUsd { extras["5hMaxUsd"] = String(format: "%.2f", v) }
        }
        if let q = d.quota7Day {
            if let v = q.usedFlows { extras["7dUsedFlows"] = String(format: "%.2f", v) }
            if let v = q.remainingFlows { extras["7dRemainingFlows"] = String(format: "%.2f", v) }
            if let v = q.maxFlows { extras["7dMaxFlows"] = String(format: "%.0f", v) }
            if let v = q.usedValueUsd { extras["7dUsedUsd"] = String(format: "%.2f", v) }
            if let v = q.maxValueUsd { extras["7dMaxUsd"] = String(format: "%.2f", v) }
        }
        if let q = d.quotaMonthly {
            if let v = q.maxFlows { extras["moMaxFlows"] = String(format: "%.0f", v) }
            if let v = q.maxValueUsd { extras["moMaxUsd"] = String(format: "%.2f", v) }
        }

        // Monthly utilization from subscription summary
        if let summary, let monthlyMax = d.quotaMonthly?.maxValueUsd, monthlyMax > 0 {
            let totalCost = summary.totalCost
            let utilization = totalCost / monthlyMax * 100.0
            extras["moUtilization"] = String(format: "%.1f", utilization)
            extras["moUsedUsd"] = String(format: "%.2f", totalCost)
            extras["moRequestCounts"] = summary.requestCounts
            extras["moTotalTokens"] = summary.totalTokens
        }

        // Monthly resets at (plan expiry)
        if let expiresAt = d.plan.expiresAt, let date = parseISO8601(expiresAt) {
            extras["moResetsAt"] = ISO8601DateFormatter().string(from: date)
        }

        return UsageData(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            extras: extras,
            fetchedAt: .now
        )
    }

    private func parseISO8601(_ string: String?) -> Date? {
        guard let string else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: string)
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

// MARK: - Management API response models

private struct ZenMuxResponse: Decodable {
    let data: ZenMuxData
}

private struct ZenMuxData: Decodable {
    let plan: ZenMuxPlan
    let accountStatus: String
    let effectiveUsdPerFlow: Double
    let quota5Hour: ZenMuxQuota?
    let quota7Day: ZenMuxQuota?
    let quotaMonthly: ZenMuxQuota?

    enum CodingKeys: String, CodingKey {
        case plan
        case accountStatus = "account_status"
        case effectiveUsdPerFlow = "effective_usd_per_flow"
        case quota5Hour = "quota_5_hour"
        case quota7Day = "quota_7_day"
        case quotaMonthly = "quota_monthly"
    }
}

private struct ZenMuxPlan: Decodable {
    let tier: String
    let amountUsd: Double?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case tier
        case amountUsd = "amount_usd"
        case expiresAt = "expires_at"
    }
}

private struct ZenMuxQuota: Decodable {
    let usagePercentage: Double?
    let resetsAt: String?
    let maxFlows: Double?
    let usedFlows: Double?
    let remainingFlows: Double?
    let usedValueUsd: Double?
    let maxValueUsd: Double?

    enum CodingKeys: String, CodingKey {
        case usagePercentage = "usage_percentage"
        case resetsAt = "resets_at"
        case maxFlows = "max_flows"
        case usedFlows = "used_flows"
        case remainingFlows = "remaining_flows"
        case usedValueUsd = "used_value_usd"
        case maxValueUsd = "max_value_usd"
    }
}

// MARK: - Subscription summary response models

private struct ZenMuxSummaryResponse: Decodable {
    let data: ZenMuxSummaryData
}

private struct ZenMuxSummaryData: Decodable {
    let totalCost: Double
    let inputCost: Double
    let outputCost: Double
    let otherCost: Double
    let requestCounts: String
    let totalTokens: String

    enum CodingKeys: String, CodingKey {
        case totalCost, inputCost, outputCost, otherCost, requestCounts, totalTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // These come as strings from the API
        let totalStr = try container.decode(String.self, forKey: .totalCost)
        let inputStr = try container.decode(String.self, forKey: .inputCost)
        let outputStr = try container.decode(String.self, forKey: .outputCost)
        let otherStr = try container.decode(String.self, forKey: .otherCost)
        totalCost = Double(totalStr) ?? 0
        inputCost = Double(inputStr) ?? 0
        outputCost = Double(outputStr) ?? 0
        otherCost = Double(otherStr) ?? 0
        requestCounts = try container.decode(String.self, forKey: .requestCounts)
        totalTokens = try container.decode(String.self, forKey: .totalTokens)
    }
}

// MARK: - Errors

enum ZenMuxProviderError: LocalizedError {
    case missingAPIKey
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return String(localized: "ZenMux Management API key not configured")
        case .httpError(let code):
            return String(localized: "ZenMux API returned HTTP \(code)")
        }
    }
}
