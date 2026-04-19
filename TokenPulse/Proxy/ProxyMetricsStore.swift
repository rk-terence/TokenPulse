import Foundation

/// Aggregated proxy metrics. Lives off the main actor for concurrency safety.
actor ProxyMetricsStore {

    struct Snapshot: Sendable {
        let totalRequestsForwarded: Int
        let totalRequestsFailed: Int
        let totalInputTokens: Int
        let totalOutputTokens: Int
        let totalCacheReadInputTokens: Int
        let totalCacheCreationInputTokens: Int
    }

    private(set) var totalRequestsForwarded: Int = 0
    private(set) var totalRequestsFailed: Int = 0
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
        totalInputTokens = 0
        totalOutputTokens = 0
        totalCacheReadInputTokens = 0
        totalCacheCreationInputTokens = 0
    }

    func snapshot() -> Snapshot {
        Snapshot(
            totalRequestsForwarded: totalRequestsForwarded,
            totalRequestsFailed: totalRequestsFailed,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            totalCacheReadInputTokens: totalCacheReadInputTokens,
            totalCacheCreationInputTokens: totalCacheCreationInputTokens
        )
    }
}
