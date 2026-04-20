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

        let primaryData = try await fetchManagementAPI(apiKey: apiKey)
        return buildUsageData(primary: primaryData)
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

    // MARK: - Build UsageData

    private func buildUsageData(primary d: ZenMuxData) -> UsageData {
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
