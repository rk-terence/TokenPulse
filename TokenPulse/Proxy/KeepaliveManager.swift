import Foundation

/// Manages per-session keepalive loops that send periodic cache-warming requests
/// to the upstream Anthropic API. Lives off the main actor for concurrency safety.
actor KeepaliveManager {

    let intervalSeconds: Int
    let inactivityTimeoutSeconds: Int
    let upstreamBaseURL: String

    private let sessionStore: ProxySessionStore
    private let metricsStore: ProxyMetricsStore
    private let session: URLSession

    /// One keepalive loop Task per session ID.
    private var activeTasks: [String: Task<Void, Never>] = [:]

    /// Stored headers per session from the most recent real request.
    private var sessionHeaders: [String: [(name: String, value: String)]] = [:]

    /// Generation counter per session to avoid stale task cleanup.
    private var sessionGenerations: [String: UInt64] = [:]

    /// Maximum consecutive failures before stopping a session's keepalive.
    private static let maxConsecutiveFailures = 3

    init(
        intervalSeconds: Int,
        inactivityTimeoutSeconds: Int,
        upstreamBaseURL: String,
        sessionStore: ProxySessionStore,
        metricsStore: ProxyMetricsStore
    ) {
        self.intervalSeconds = intervalSeconds
        self.inactivityTimeoutSeconds = inactivityTimeoutSeconds
        self.upstreamBaseURL = upstreamBaseURL
        self.sessionStore = sessionStore
        self.metricsStore = metricsStore

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    /// Start or reset the keepalive loop for a session.
    /// If a loop is already running, cancel it and start a new one.
    func startOrReset(sessionID: String, headers: [(name: String, value: String)]) {
        // Store the latest headers for this session.
        sessionHeaders[sessionID] = headers

        // Cancel any existing task.
        activeTasks[sessionID]?.cancel()

        // Increment the generation so the old task's cleanup becomes a no-op.
        let newGeneration = (sessionGenerations[sessionID] ?? 0) + 1
        sessionGenerations[sessionID] = newGeneration

        let interval = intervalSeconds
        let timeout = inactivityTimeoutSeconds
        let upstream = upstreamBaseURL
        let store = sessionStore
        let metrics = metricsStore
        let urlSession = session
        let storedHeaders = headers

        activeTasks[sessionID] = Task { [weak self] in
            await Self.keepaliveLoop(
                sessionID: sessionID,
                generation: newGeneration,
                intervalSeconds: interval,
                inactivityTimeoutSeconds: timeout,
                upstreamBaseURL: upstream,
                headers: storedHeaders,
                sessionStore: store,
                metricsStore: metrics,
                urlSession: urlSession,
                manager: self
            )
        }
    }

    /// Stop the keepalive loop for a specific session.
    func stop(sessionID: String) {
        activeTasks[sessionID]?.cancel()
        activeTasks.removeValue(forKey: sessionID)
        sessionHeaders.removeValue(forKey: sessionID)
        sessionGenerations.removeValue(forKey: sessionID)
    }

    /// Stop all keepalive loops (called on proxy shutdown).
    func stopAll() {
        for task in activeTasks.values {
            task.cancel()
        }
        activeTasks.removeAll()
        sessionHeaders.removeAll()
        sessionGenerations.removeAll()
    }

    /// Number of currently active keepalive loops.
    func activeCount() -> Int {
        activeTasks.count
    }

    /// Called from the loop to remove a completed/stopped task.
    /// Only removes if the generation matches, preventing stale cleanup.
    fileprivate func removeTask(for sessionID: String, generation: UInt64) {
        guard sessionGenerations[sessionID] == generation else { return }
        activeTasks.removeValue(forKey: sessionID)
        sessionHeaders.removeValue(forKey: sessionID)
        sessionGenerations.removeValue(forKey: sessionID)
    }

    // MARK: - Keepalive loop

    private static func keepaliveLoop(
        sessionID: String,
        generation: UInt64,
        intervalSeconds: Int,
        inactivityTimeoutSeconds: Int,
        upstreamBaseURL: String,
        headers: [(name: String, value: String)],
        sessionStore: ProxySessionStore,
        metricsStore: ProxyMetricsStore,
        urlSession: URLSession,
        manager: KeepaliveManager?
    ) async {
        let hopByHopHeaders: Set<String> = ["host", "content-length", "transfer-encoding"]

        while !Task.isCancelled {
            // 1. Sleep for the configured interval.
            do {
                try await Task.sleep(for: .seconds(intervalSeconds))
            } catch {
                // CancellationError -- exit gracefully.
                break
            }

            // 2. Check for cancellation after waking.
            guard !Task.isCancelled else { break }

            // 3. Check inactivity timeout (before any network call).
            if let sessionData = await sessionStore.session(for: sessionID) {
                let elapsed = Date().timeIntervalSince(sessionData.lastSeenAt)
                if elapsed > Double(inactivityTimeoutSeconds) {
                    ProxyLogger.log("Keepalive: session \(sessionID) inactive for \(Int(elapsed))s, stopping")
                    break
                }

                // 4. Check consecutive failures (before any network call).
                if sessionData.keepaliveFailureCount >= maxConsecutiveFailures {
                    ProxyLogger.log("Keepalive: session \(sessionID) exceeded \(maxConsecutiveFailures) consecutive failures, stopping")
                    break
                }
            }

            // 5. Load last request body.
            guard let lastBody = await sessionStore.lastRequestBody(for: sessionID) else {
                continue
            }

            // 6. Build keepalive body.
            guard let keepaliveBody = KeepaliveRequestBuilder.build(from: lastBody) else {
                continue
            }

            // 7. Build the upstream URL and send the keepalive request.
            let urlString = upstreamBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                + "/v1/messages"
            guard let url = URL(string: urlString) else {
                ProxyLogger.log("Keepalive: invalid upstream URL for session \(sessionID)")
                continue
            }

            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = keepaliveBody

            // Copy stored headers, skipping hop-by-hop.
            for header in headers {
                let lowered = header.name.lowercased()
                if hopByHopHeaders.contains(lowered) { continue }
                urlRequest.setValue(header.value, forHTTPHeaderField: header.name)
            }
            // Ensure content-type is set.
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

            await metricsStore.recordKeepaliveSent()

            // 8. Send keepalive and process result.
            do {
                let (data, response) = try await urlSession.data(for: urlRequest)

                guard let httpResponse = response as? HTTPURLResponse else {
                    ProxyLogger.log("Keepalive: non-HTTP response for session \(sessionID)")
                    await recordFailure(
                        sessionID: sessionID,
                        sessionStore: sessionStore,
                        metricsStore: metricsStore,
                        countAsConsecutive: true
                    )
                    continue
                }

                let statusCode = httpResponse.statusCode

                // Handle auth failures -- stop keepalive.
                if statusCode == 401 || statusCode == 403 {
                    ProxyLogger.log("Keepalive: auth failure (\(statusCode)) for session \(sessionID), stopping")
                    await recordFailure(
                        sessionID: sessionID,
                        sessionStore: sessionStore,
                        metricsStore: metricsStore,
                        countAsConsecutive: true
                    )
                    break
                }

                // Handle rate limiting and server errors -- skip, don't count as consecutive failure.
                if statusCode == 429 || statusCode >= 500 {
                    ProxyLogger.log("Keepalive: status \(statusCode) for session \(sessionID), skipping attempt")
                    await metricsStore.recordKeepaliveFailed()
                    continue
                }

                // Handle other non-success status codes.
                if statusCode < 200 || statusCode >= 300 {
                    ProxyLogger.log("Keepalive: unexpected status \(statusCode) for session \(sessionID)")
                    await recordFailure(
                        sessionID: sessionID,
                        sessionStore: sessionStore,
                        metricsStore: metricsStore,
                        countAsConsecutive: true
                    )
                } else {
                    // Parse cache metrics from the response.
                    let (cacheReadTokens, cacheCreationTokens) = parseCacheMetrics(from: data)

                    // Record success.
                    await sessionStore.recordKeepaliveResult(
                        for: sessionID,
                        success: true,
                        cacheReadTokens: cacheReadTokens,
                        cacheCreationTokens: cacheCreationTokens
                    )

                    if cacheReadTokens != nil && (cacheReadTokens ?? 0) > 0 {
                        await metricsStore.recordCacheRead()
                    }
                    if cacheCreationTokens != nil && (cacheCreationTokens ?? 0) > 0 {
                        await metricsStore.recordCacheWrite()
                    }

                    ProxyLogger.log("Keepalive: success for session \(sessionID) "
                        + "(cache_read: \(cacheReadTokens ?? 0), cache_creation: \(cacheCreationTokens ?? 0))")
                }

            } catch is CancellationError {
                break
            } catch {
                ProxyLogger.log("Keepalive: network error for session \(sessionID): \(error.localizedDescription)")
                await recordFailure(
                    sessionID: sessionID,
                    sessionStore: sessionStore,
                    metricsStore: metricsStore,
                    countAsConsecutive: true
                )
            }
        }

        // Clean up when loop ends (only if generation matches).
        await manager?.removeTask(for: sessionID, generation: generation)
    }

    // MARK: - Helpers

    private static func recordFailure(
        sessionID: String,
        sessionStore: ProxySessionStore,
        metricsStore: ProxyMetricsStore,
        countAsConsecutive: Bool
    ) async {
        await metricsStore.recordKeepaliveFailed()
        if countAsConsecutive {
            await sessionStore.recordKeepaliveResult(
                for: sessionID,
                success: false,
                cacheReadTokens: nil,
                cacheCreationTokens: nil
            )
        }
    }

    /// Parse `cache_read_input_tokens` and `cache_creation_input_tokens` from
    /// the upstream JSON response's `usage` object.
    private static func parseCacheMetrics(from data: Data) -> (cacheReadTokens: Int?, cacheCreationTokens: Int?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any] else {
            return (nil, nil)
        }
        let cacheRead = usage["cache_read_input_tokens"] as? Int
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int
        return (cacheRead, cacheCreation)
    }
}
