import Foundation

/// Manages per-session keepalive loops that send periodic cache-warming requests
/// to the upstream Anthropic API. Lives off the main actor for concurrency safety.
actor KeepaliveManager {

    private var intervalSeconds: Int
    private var inactivityTimeoutSeconds: Int
    private var upstreamBaseURL: String

    private let sessionStore: ProxySessionStore
    private let metricsStore: ProxyMetricsStore
    private let session: URLSession
    private let eventLogger: ProxyEventLogger?
    private let proxyPort: Int
    private var suppressStatusSnapshots = false
    private var acceptsNewKeepalives = true

    /// One keepalive loop Task per session ID.
    private var activeTasks: [String: Task<Void, Never>] = [:]

    /// Stored headers per session from the most recent real request.
    private var sessionHeaders: [String: [(name: String, value: String)]] = [:]

    /// Generation counter per session to avoid stale task cleanup.
    private var sessionGenerations: [String: UInt64] = [:]

    /// Maximum cumulative failures before stopping a session's keepalive.
    private static let maxCumulativeFailures = 5

    init(
        intervalSeconds: Int,
        inactivityTimeoutSeconds: Int,
        upstreamBaseURL: String,
        sessionStore: ProxySessionStore,
        metricsStore: ProxyMetricsStore,
        eventLogger: ProxyEventLogger? = nil,
        proxyPort: Int = 0
    ) {
        self.intervalSeconds = intervalSeconds
        self.inactivityTimeoutSeconds = inactivityTimeoutSeconds
        self.upstreamBaseURL = upstreamBaseURL
        self.sessionStore = sessionStore
        self.metricsStore = metricsStore
        self.eventLogger = eventLogger
        self.proxyPort = proxyPort

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    /// Start or reset the keepalive loop for a session.
    /// If a loop is already running, cancel it and start a new one.
    /// Skips sessions whose keepalive has been disabled due to cumulative failures.
    func startOrReset(sessionID: String, headers: [(name: String, value: String)]) async {
        guard acceptsNewKeepalives else { return }

        // Don't restart keepalive for sessions that have been disabled due to failures.
        let disabled = await sessionStore.isKeepaliveDisabled(for: sessionID)
        if disabled {
            ProxyLogger.log("Keepalive: session \(sessionID) is disabled, skipping startOrReset")
            return
        }

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
        let logger = eventLogger
        let port = proxyPort

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
                manager: self,
                eventLogger: logger,
                proxyPort: port
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

    /// Reconfigure active keepalive loops without requiring a proxy restart.
    /// Existing loops are restarted with the latest settings and preserved headers.
    func reconfigure(
        intervalSeconds: Int,
        inactivityTimeoutSeconds: Int,
        upstreamBaseURL: String
    ) async {
        self.intervalSeconds = intervalSeconds
        self.inactivityTimeoutSeconds = inactivityTimeoutSeconds
        self.upstreamBaseURL = upstreamBaseURL
        self.suppressStatusSnapshots = false
        self.acceptsNewKeepalives = true

        let preservedHeaders = sessionHeaders
        stopAll()

        for (sessionID, headers) in preservedHeaders {
            await startOrReset(sessionID: sessionID, headers: headers)
        }
    }

    /// Stop all loops permanently as part of proxy shutdown, suppressing any late
    /// snapshot writes from cancelled tasks so the controller can write the final state.
    func shutdown() {
        suppressStatusSnapshots = true
        acceptsNewKeepalives = false
        stopAll()
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

    fileprivate func statusSnapshotsSuppressed() -> Bool {
        suppressStatusSnapshots
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
        manager: KeepaliveManager?,
        eventLogger: ProxyEventLogger?,
        proxyPort: Int
    ) async {
        let hopByHopHeaders: Set<String> = ["host", "content-length", "transfer-encoding"]

        // Use a flag to signal the loop should exit after writing the status snapshot.
        var shouldExit = false

        while !Task.isCancelled && !shouldExit {
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
                    shouldExit = true
                }

                // 4. Check cumulative failures (before any network call).
                if !shouldExit && sessionData.keepaliveFailureCount >= maxCumulativeFailures {
                    ProxyLogger.log("Keepalive: session \(sessionID) exceeded \(maxCumulativeFailures) cumulative failures, stopping")
                    let shortSessionID = String(sessionID.prefix(8))
                    await eventLogger?.logKeepaliveDisabled(session: sessionID, reason: "cumulative_failures", failureCount: sessionData.keepaliveFailureCount)
                    await sessionStore.disableKeepalive(for: sessionID)
                    await MainActor.run {
                        NotificationService.shared.sendProxyKeepaliveDisabled(sessionID: shortSessionID)
                    }
                    shouldExit = true
                }
            }

            // Only perform network work if we are not already exiting.
            if !shouldExit {
                // 5. Load last request body.
                guard let lastBody = await sessionStore.lastRequestBody(for: sessionID) else {
                    // Write status snapshot even when skipping.
                    await writeStatusSnapshot(
                        eventLogger: eventLogger,
                        proxyPort: proxyPort,
                        sessionStore: sessionStore,
                        metricsStore: metricsStore,
                        manager: manager
                    )
                    continue
                }

                // 6. Build keepalive body.
                guard let keepaliveBody = KeepaliveRequestBuilder.build(from: lastBody) else {
                    await writeStatusSnapshot(
                        eventLogger: eventLogger,
                        proxyPort: proxyPort,
                        sessionStore: sessionStore,
                        metricsStore: metricsStore,
                        manager: manager
                    )
                    continue
                }

                // 7. Build the upstream URL and send the keepalive request.
                let urlString = upstreamBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    + "/v1/messages"
                guard let url = URL(string: urlString) else {
                    ProxyLogger.log("Keepalive: invalid upstream URL for session \(sessionID)")
                    await writeStatusSnapshot(
                        eventLogger: eventLogger,
                        proxyPort: proxyPort,
                        sessionStore: sessionStore,
                        metricsStore: metricsStore,
                        manager: manager
                    )
                    continue
                }

                var urlRequest = URLRequest(url: url)
                urlRequest.httpMethod = "POST"
                urlRequest.httpBody = keepaliveBody
                let keepaliveStartedAt = Date()

                // Copy stored headers, skipping hop-by-hop.
                for header in headers {
                    let lowered = header.name.lowercased()
                    if hopByHopHeaders.contains(lowered) { continue }
                    urlRequest.addValue(header.value, forHTTPHeaderField: header.name)
                }
                // Ensure content-type is set.
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

                await metricsStore.recordKeepaliveSent()
                let keepaliveID = await eventLogger?.logKeepaliveSent(session: sessionID)

                // 8. Send keepalive and process result.
                do {
                    let (data, response) = try await urlSession.data(for: urlRequest)

                    if let httpResponse = response as? HTTPURLResponse {
                        let statusCode = httpResponse.statusCode
                        let upstreamRequestID = ProxyHTTPUtils.allHeaders(from: httpResponse)
                            .first(where: { $0.name.caseInsensitiveCompare("request-id") == .orderedSame
                                || $0.name.caseInsensitiveCompare("x-request-id") == .orderedSame })?.value

                        // Handle auth failures -- permanently disable and stop keepalive.
                        if statusCode == 401 || statusCode == 403 {
                            ProxyLogger.log("Keepalive: auth failure (\(statusCode)) for session \(sessionID), stopping")
                            await eventLogger?.logKeepaliveCompleted(
                                keepaliveID: keepaliveID,
                                session: sessionID,
                                success: false,
                                statusCode: statusCode,
                                durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: keepaliveStartedAt),
                                upstreamRequestID: upstreamRequestID,
                                tokenUsage: TokenUsage.empty,
                                error: "auth failure"
                            )
                            await recordFailure(
                                sessionID: sessionID,
                                sessionStore: sessionStore,
                                metricsStore: metricsStore
                            )
                            await sessionStore.disableKeepalive(for: sessionID)
                            shouldExit = true

                        // Handle rate limiting and server errors -- count toward cumulative failures.
                        } else if statusCode == 429 || statusCode >= 500 {
                            ProxyLogger.log("Keepalive: status \(statusCode) for session \(sessionID), counting failure")
                            await eventLogger?.logKeepaliveCompleted(
                                keepaliveID: keepaliveID,
                                session: sessionID,
                                success: false,
                                statusCode: statusCode,
                                durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: keepaliveStartedAt),
                                upstreamRequestID: upstreamRequestID,
                                tokenUsage: TokenUsage.empty,
                                error: "upstream returned status \(statusCode)"
                            )
                            await recordFailure(
                                sessionID: sessionID,
                                sessionStore: sessionStore,
                                metricsStore: metricsStore
                            )

                        // Handle other non-success status codes.
                        } else if statusCode < 200 || statusCode >= 300 {
                            ProxyLogger.log("Keepalive: unexpected status \(statusCode) for session \(sessionID)")
                            await eventLogger?.logKeepaliveCompleted(
                                keepaliveID: keepaliveID,
                                session: sessionID,
                                success: false,
                                statusCode: statusCode,
                                durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: keepaliveStartedAt),
                                upstreamRequestID: upstreamRequestID,
                                tokenUsage: TokenUsage.empty,
                                error: "unexpected upstream status \(statusCode)"
                            )
                            await recordFailure(
                                sessionID: sessionID,
                                sessionStore: sessionStore,
                                metricsStore: metricsStore
                            )

                        } else {
                            // Parse token usage from the response.
                            let tokenUsage = ProxyHTTPUtils.parseTokenUsage(from: data, streaming: false)

                            // Record success.
                            await sessionStore.recordKeepaliveResult(
                                for: sessionID,
                                success: true,
                                cacheReadTokens: tokenUsage.cacheReadInputTokens,
                                cacheCreationTokens: tokenUsage.cacheCreationInputTokens
                            )

                            if (tokenUsage.cacheReadInputTokens ?? 0) > 0 {
                                await metricsStore.recordCacheRead()
                            }
                            if (tokenUsage.cacheCreationInputTokens ?? 0) > 0 {
                                await metricsStore.recordCacheWrite()
                            }
                            await metricsStore.recordTokenUsage(tokenUsage)
                            let sessionModel = await sessionStore.session(for: sessionID)?.lastKnownModel
                            await sessionStore.recordTokenUsage(tokenUsage, model: sessionModel, for: sessionID)

                            await eventLogger?.logKeepaliveCompleted(
                                keepaliveID: keepaliveID,
                                session: sessionID,
                                success: true,
                                statusCode: statusCode,
                                durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: keepaliveStartedAt),
                                upstreamRequestID: upstreamRequestID,
                                tokenUsage: tokenUsage,
                                error: nil
                            )

                            ProxyLogger.log("Keepalive: success for session \(sessionID) "
                                + "(cache_read: \(tokenUsage.cacheReadInputTokens ?? 0), cache_creation: \(tokenUsage.cacheCreationInputTokens ?? 0))")
                        }

                    } else {
                        ProxyLogger.log("Keepalive: non-HTTP response for session \(sessionID)")
                        await eventLogger?.logKeepaliveCompleted(
                            keepaliveID: keepaliveID,
                            session: sessionID,
                            success: false,
                            statusCode: nil,
                            durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: keepaliveStartedAt),
                            upstreamRequestID: nil,
                            tokenUsage: TokenUsage.empty,
                            error: "non-HTTP response from upstream"
                        )
                        await recordFailure(
                            sessionID: sessionID,
                            sessionStore: sessionStore,
                            metricsStore: metricsStore
                        )
                    }

                } catch is CancellationError {
                    break
                } catch {
                    ProxyLogger.log("Keepalive: network error for session \(sessionID): \(error.localizedDescription)")
                    await eventLogger?.logKeepaliveCompleted(
                        keepaliveID: keepaliveID,
                        session: sessionID,
                        success: false,
                        statusCode: nil,
                        durationMs: ProxyHTTPUtils.elapsedMilliseconds(since: keepaliveStartedAt),
                        upstreamRequestID: nil,
                        tokenUsage: TokenUsage.empty,
                        error: error.localizedDescription
                    )
                    await recordFailure(
                        sessionID: sessionID,
                        sessionStore: sessionStore,
                        metricsStore: metricsStore
                    )
                }
            }

            // Write status snapshot after every iteration, regardless of outcome.
            await writeStatusSnapshot(
                eventLogger: eventLogger,
                proxyPort: proxyPort,
                sessionStore: sessionStore,
                metricsStore: metricsStore,
                manager: manager
            )
        }

        // Clean up when loop ends (only if generation matches).
        await manager?.removeTask(for: sessionID, generation: generation)

        // Write final snapshot so activeKeepalives count drops correctly.
        await writeStatusSnapshot(
            eventLogger: eventLogger,
            proxyPort: proxyPort,
            sessionStore: sessionStore,
            metricsStore: metricsStore,
            manager: manager
        )
    }

    // MARK: - Helpers (keepalive-local)

    private static func recordFailure(
        sessionID: String,
        sessionStore: ProxySessionStore,
        metricsStore: ProxyMetricsStore
    ) async {
        await metricsStore.recordKeepaliveFailed()
        await sessionStore.recordKeepaliveResult(
            for: sessionID,
            success: false,
            cacheReadTokens: nil,
            cacheCreationTokens: nil
        )
    }

    /// Write an atomic status snapshot via the event logger.
    private static func writeStatusSnapshot(
        eventLogger: ProxyEventLogger?,
        proxyPort: Int,
        sessionStore: ProxySessionStore,
        metricsStore: ProxyMetricsStore,
        manager: KeepaliveManager?
    ) async {
        guard let logger = eventLogger else { return }
        if await manager?.statusSnapshotsSuppressed() == true {
            return
        }
        let activeSessions = await sessionStore.activeSessions().count
        let activeKeepalives = await manager?.activeCount() ?? 0
        let snapshot = await metricsStore.snapshot()
        await logger.writeStatusSnapshot(
            enabled: true,
            port: proxyPort,
            activeSessions: activeSessions,
            activeKeepalives: activeKeepalives,
            metrics: snapshot
        )
    }
}
