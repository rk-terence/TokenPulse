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
    }

    private(set) var totalRequestsForwarded: Int = 0
    private(set) var totalRequestsFailed: Int = 0
    private(set) var totalKeepalivesSent: Int = 0
    private(set) var totalKeepalivesFailed: Int = 0
    private(set) var totalCacheReads: Int = 0
    private(set) var totalCacheWrites: Int = 0

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

    func snapshot() -> Snapshot {
        Snapshot(
            totalRequestsForwarded: totalRequestsForwarded,
            totalRequestsFailed: totalRequestsFailed,
            totalKeepalivesSent: totalKeepalivesSent,
            totalKeepalivesFailed: totalKeepalivesFailed,
            totalCacheReads: totalCacheReads,
            totalCacheWrites: totalCacheWrites
        )
    }
}
