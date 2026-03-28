import Foundation
import SwiftUI

struct ZenMuxProvider: UsageProvider {
    let id = "zenmux"
    let displayName = "ZenMux"
    let shortLabel = "Z"
    let brandColor = Color.blue

    private let session: URLSession

    /// Optional manually-pasted cookies (from Settings fallback).
    var manualCookies: ZenMuxCookies?

    init(session: URLSession = .shared, manualCookies: ZenMuxCookies? = nil) {
        self.session = session
        self.manualCookies = manualCookies
    }

    func isConfigured() -> Bool {
        if manualCookies != nil { return true }
        return (try? ChromeCookieService.extractZenMuxCookies()) != nil
    }

    func fetchUsage() async throws -> UsageData {
        let cookies: ZenMuxCookies
        if let manual = manualCookies {
            cookies = manual
        } else {
            cookies = try ChromeCookieService.extractZenMuxCookies()
        }

        let request = buildRequest(cookies: cookies)
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ZenMuxProviderError.httpError(code)
        }

        return try parseResponse(data)
    }

    // MARK: - Private

    private static let baseURL = "https://zenmux.ai/api/subscription/get_current_usage"

    private func buildRequest(cookies: ZenMuxCookies) -> URLRequest {
        var components = URLComponents(string: Self.baseURL)!
        components.queryItems = [URLQueryItem(name: "ctoken", value: cookies.ctoken)]

        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        let cookieHeader = "ctoken=\(cookies.ctoken); sessionId=\(cookies.sessionId); sessionId.sig=\(cookies.sessionIdSig)"
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("TokenPulse/1.0", forHTTPHeaderField: "User-Agent")
        return req
    }

    private func parseResponse(_ data: Data) throws -> UsageData {
        let raw = try JSONDecoder().decode(ZenMuxResponse.self, from: data)

        var fiveHour: WindowUsage?
        var sevenDay: WindowUsage?
        var extras: [String: String] = [:]

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for entry in raw.data {
            let utilization = entry.usedRate * 100.0
            let resetsAt = isoFormatter.date(from: entry.cycleEndTime)

            let window = WindowUsage(utilization: utilization, resetsAt: resetsAt)

            switch entry.periodType {
            case "hour_5":
                fiveHour = window
            case "week":
                sevenDay = window
            default:
                break
            }

            if entry.quotaStatus != 0 {
                extras["quotaExhausted_\(entry.periodType)"] = "true"
            }
        }

        if let tierCode = raw.data.first?.tierCode {
            extras["tier"] = tierCode
        }

        return UsageData(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            extras: extras,
            fetchedAt: .now
        )
    }
}

// MARK: - Response models

private struct ZenMuxResponse: Decodable {
    let data: [ZenMuxUsageEntry]
}

private struct ZenMuxUsageEntry: Decodable {
    let tierCode: String
    let periodType: String
    let periodDuration: String
    let cycleStartTime: String
    let cycleEndTime: String
    let usedRate: Double
    let quotaStatus: Int
    let status: Int
}

// MARK: - Errors

enum ZenMuxProviderError: LocalizedError {
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .httpError(let code):
            return String(localized: "ZenMux API returned HTTP \(code)")
        }
    }
}
