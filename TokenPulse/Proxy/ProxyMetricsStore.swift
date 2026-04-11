import Foundation

/// Aggregated proxy metrics. Lives off the main actor for concurrency safety.
actor ProxyMetricsStore {

    struct Snapshot: Sendable {
        let totalRequestsForwarded: Int
        let totalRequestsFailed: Int
    }

    private(set) var totalRequestsForwarded: Int = 0
    private(set) var totalRequestsFailed: Int = 0

    func recordForwarded() {
        totalRequestsForwarded += 1
    }

    func recordFailed() {
        totalRequestsFailed += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(
            totalRequestsForwarded: totalRequestsForwarded,
            totalRequestsFailed: totalRequestsFailed
        )
    }
}
