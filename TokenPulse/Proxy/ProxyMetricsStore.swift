import Foundation

/// Aggregated proxy metrics. Lives off the main actor for concurrency safety.
actor ProxyMetricsStore {

    struct Snapshot: Sendable {
        let totalRequestsForwarded: Int
        let totalRequestsFailed: Int
        let totalKeepalivesSent: Int
        let totalKeepalivesFailed: Int
        let totalCacheReads: Int
        let totalCacheWrites: Int
        let estimatedSavingsMultiple: Double
        let totalInputTokens: Int
        let totalOutputTokens: Int
        let totalCacheReadInputTokens: Int
        let totalCacheCreationInputTokens: Int
    }

    private(set) var totalRequestsForwarded: Int = 0
    private(set) var totalRequestsFailed: Int = 0
    private(set) var totalKeepalivesSent: Int = 0
    private(set) var totalKeepalivesFailed: Int = 0
    private(set) var totalCacheReads: Int = 0
    private(set) var totalCacheWrites: Int = 0
    private(set) var totalInputTokens: Int = 0
    private(set) var totalOutputTokens: Int = 0
    private(set) var totalCacheReadInputTokens: Int = 0
    private(set) var totalCacheCreationInputTokens: Int = 0

    func recordForwarded() {
        totalRequestsForwarded += 1
    }

    func recordFailed() {
        totalRequestsFailed += 1
    }

    func recordKeepaliveSent() {
        totalKeepalivesSent += 1
    }

    func recordKeepaliveFailed() {
        totalKeepalivesFailed += 1
    }

    func recordCacheRead() {
        totalCacheReads += 1
    }

    func recordCacheWrite() {
        totalCacheWrites += 1
    }

    func recordTokenUsage(_ usage: TokenUsage) {
        if let v = usage.inputTokens { totalInputTokens += v }
        if let v = usage.outputTokens { totalOutputTokens += v }
        if let v = usage.cacheReadInputTokens { totalCacheReadInputTokens += v }
        if let v = usage.cacheCreationInputTokens { totalCacheCreationInputTokens += v }
    }

    /// Reset all counters to zero.
    func reset() {
        totalRequestsForwarded = 0
        totalRequestsFailed = 0
        totalKeepalivesSent = 0
        totalKeepalivesFailed = 0
        totalCacheReads = 0
        totalCacheWrites = 0
        totalInputTokens = 0
        totalOutputTokens = 0
        totalCacheReadInputTokens = 0
        totalCacheCreationInputTokens = 0
    }

    /// Note: `totalCacheReads` is only incremented from keepalive results (not real
    /// requests), so it serves as a proxy for "avoided cache writes" in the savings formula.
    func snapshot() -> Snapshot {
        let savings = max(0, Double(totalCacheReads) * 1.15 - Double(totalKeepalivesSent) * 0.10)
        return Snapshot(
            totalRequestsForwarded: totalRequestsForwarded,
            totalRequestsFailed: totalRequestsFailed,
            totalKeepalivesSent: totalKeepalivesSent,
            totalKeepalivesFailed: totalKeepalivesFailed,
            totalCacheReads: totalCacheReads,
            totalCacheWrites: totalCacheWrites,
            estimatedSavingsMultiple: savings,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            totalCacheReadInputTokens: totalCacheReadInputTokens,
            totalCacheCreationInputTokens: totalCacheCreationInputTokens
        )
    }
}
