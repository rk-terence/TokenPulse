import SwiftUI

struct PopoverView: View {
    private static let popoverWidth: CGFloat = 384

    let manager: ProviderManager
    var proxyController: LocalProxyController?
    var onTogglePin: ((Bool) -> Void)?
    var onOpenSettings: (() -> Void)?

    @State private var isPinned = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Text("TokenPulse")
                    .font(.headline)
                Spacer()

                Button {
                    isPinned.toggle()
                    onTogglePin?(isPinned)
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(HeaderActionButtonStyle(isEmphasized: isPinned))
                .help(isPinned
                    ? String(localized: "Unpin popover")
                    : String(localized: "Pin popover"))

                HeaderActionButton(
                    icon: "arrow.clockwise",
                    isEmphasized: manager.isRefreshing,
                    action: { manager.requestRefresh() }
                )
                .help(String(localized: "Refresh"))

                HeaderActionButton(
                    icon: "gearshape",
                    action: { onOpenSettings?() }
                )
                .help(String(localized: "Settings"))
            }

            Divider()

            if manager.enabledProviderCount == 0 {
                Text("No providers enabled. Open Settings to enable a provider.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Divider()
            } else if manager.configuredProviderCount == 0 {
                Text("No providers configured. Open Settings to connect your accounts.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Divider()
            }

            // Provider rows
            ForEach(manager.providerEntries, id: \.id) { entry in
                ProviderRow(entry: entry)
                if entry.id != manager.providerEntries.last?.id {
                    Divider()
                }
            }

            if let lastUpdate = manager.lastUpdated {
                Text("Last checked \(lastUpdate, style: .relative)")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
                    .animation(nil, value: lastUpdate)
            }

            Divider()

            // Proxy status (compact)
            if let proxy = proxyController, proxy.isRunning {
                ProxyStatusRow(proxy: proxy)
                Divider()
            }

            // Footer
            HStack {
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: Self.popoverWidth)
        .background(.thinMaterial)
    }

}

private struct HeaderActionButton: View {
    let icon: String
    var isEmphasized = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
        }
        .buttonStyle(HeaderActionButtonStyle(isEmphasized: isEmphasized))
    }
}

private struct HeaderActionButtonStyle: ButtonStyle {
    var isEmphasized: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(foregroundColor(isPressed: configuration.isPressed))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(backgroundColor(isPressed: configuration.isPressed), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(borderColor(isPressed: configuration.isPressed), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }

    private func foregroundColor(isPressed: Bool) -> Color {
        if isEmphasized || isPressed {
            return .primary
        }
        return .secondary
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isEmphasized {
            return isPressed ? Color.secondary.opacity(0.24) : Color.secondary.opacity(0.16)
        }
        return isPressed ? Color.secondary.opacity(0.16) : Color.secondary.opacity(0.08)
    }

    private func borderColor(isPressed: Bool) -> Color {
        if isEmphasized {
            return isPressed ? Color.secondary.opacity(0.42) : Color.secondary.opacity(0.28)
        }
        return isPressed ? Color.secondary.opacity(0.3) : Color.secondary.opacity(0.18)
    }
}

// MARK: - Provider Row

private struct ProviderRow: View {
    let entry: ProviderEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: dot + name + 5h%
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(entry.displayName)
                    .font(.body.weight(.medium))
                Spacer()
                Text(fiveHourText)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let data = entry.status.displayData {
                QuotaGrid(entry: entry, data: data, tone: dataTone)
            }

            if let detailText = entry.status.message {
                Text(detailText)
                    .font(.callout)
                    .foregroundStyle(detailColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsLastSuccessHint, let lastSuccessAt = entry.lastSuccessAt {
                Text("Last success \(lastSuccessAt, style: .relative)")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
                    .animation(nil, value: lastSuccessAt)
            }
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .unconfigured: return .gray
        case .pendingFirstLoad, .refreshing: return .blue
        case .ready(let data):
            guard let u = data.fiveHour?.utilization else { return .gray }
            if u <= 50 { return .green }
            else if u <= 80 { return .orange }
            else { return .red }
        case .stale: return .gray
        case .error: return .red
        }
    }

    private var fiveHourText: String {
        if let u = entry.status.displayData?.fiveHour?.utilization {
            return String(format: "%.0f%%", u)
        }

        switch entry.status {
        case .refreshing:
            return "..."
        case .stale(_, let reason, _) where reason == .auth:
            return "auth"
        case .error:
            return "err"
        case .unconfigured, .pendingFirstLoad, .ready, .stale:
            return "--"
        }
    }

    private var dataTone: ProviderDataTone {
        switch entry.status {
        case .ready:
            return .fresh
        case .refreshing:
            return .refreshing
        case .stale:
            return .stale
        case .unconfigured, .pendingFirstLoad, .error:
            return .fresh
        }
    }

    private var detailColor: Color {
        switch entry.status {
        case .stale(_, let reason, _) where reason == .auth:
            return .orange
        case .error:
            return .red
        case .unconfigured, .pendingFirstLoad, .refreshing, .stale, .ready:
            return .secondary
        }
    }

    private var showsLastSuccessHint: Bool {
        switch entry.status {
        case .refreshing(_, let lastMessage):
            return lastMessage != nil
        case .stale:
            return true
        case .unconfigured, .pendingFirstLoad, .ready, .error:
            return false
        }
    }
}

// MARK: - Data Tone

private enum ProviderDataTone {
    case fresh
    case refreshing
    case stale

    var opacity: Double {
        switch self {
        case .fresh: return 1.0
        case .refreshing: return 0.82
        case .stale: return 0.74
        }
    }

    var grayscaleAmount: Double {
        switch self {
        case .fresh, .refreshing: return 0
        case .stale: return 1
        }
    }
}

// MARK: - Quota Grid

private struct QuotaGrid: View {
    let entry: ProviderEntry
    let data: UsageData
    let tone: ProviderDataTone

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // 5-hour row
            if let fiveHour = data.fiveHour {
                QuotaRow(
                    label: data.primaryWindowLabel,
                    utilization: fiveHour.utilization,
                    resetsAt: fiveHour.resetsAt,
                    detail: usdDetail(used: "5hUsedUsd", max: "5hMaxUsd")
                )
            }

            // 7-day row
            if let sevenDay = data.sevenDay {
                QuotaRow(
                    label: data.secondaryWindowLabel,
                    utilization: sevenDay.utilization,
                    resetsAt: sevenDay.resetsAt,
                    detail: usdDetail(used: "7dUsedUsd", max: "7dMaxUsd")
                )
            }

            // Provider-specific extras
            switch entry.id {
            case "claude":
                claudeExtras
            case "codex":
                codexExtras
            case "zenmux":
                zenMuxExtras
            default:
                EmptyView()
            }
        }
        .grayscale(tone.grayscaleAmount)
        .opacity(tone.opacity)
    }

    // MARK: - Claude extras

    @ViewBuilder
    private var claudeExtras: some View {
        if let opusStr = data.extras["opusUtilization"],
           let opus = Double(opusStr) {
            HStack(spacing: 4) {
                Text("Opus")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                MiniBar(percentage: opus)
                Text(String(format: "%.0f%%", opus))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }

    // MARK: - ZenMux extras

    @ViewBuilder
    private var codexExtras: some View {
        HStack(spacing: 8) {
            if let planType = data.extras["planType"] {
                TagView(text: formattedPlanType(planType))
            }
        }
    }

    @ViewBuilder
    private var zenMuxExtras: some View {
        // Monthly utilization (from subscription_summary) or fallback to cap-only display
        if let utilizationStr = data.extras["moUtilization"],
           let utilization = Double(utilizationStr) {
            QuotaRow(
                label: "mo",
                utilization: utilization,
                resetsAt: data.extras["moResetsAt"].flatMap { ISO8601DateFormatter().date(from: $0) },
                detail: usdDetail(used: "moUsedUsd", max: "moMaxUsd")
            )
        } else if let maxUsd = data.extras["moMaxUsd"] {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("mo")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                    Text("cap $\(maxUsd)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if let issue = data.extras["moSummaryIssue"] {
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.leading, 32)
                }
            }
        }

        // Bottom line: tier + account status
        HStack(spacing: 8) {
            if let tier = data.extras["tier"] {
                TagView(text: tier.capitalized)
            }
            if let status = data.extras["accountStatus"], status != "healthy" {
                TagView(text: status, color: .red)
            }
        }
    }

    private func usdDetail(used usedKey: String, max maxKey: String) -> String? {
        guard let used = data.extras[usedKey],
              let max = data.extras[maxKey] else { return nil }
        return "$\(used)/$\(max)"
    }

    private func formattedPlanType(_ value: String) -> String {
        value
            .split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}

// MARK: - Quota Row

private struct QuotaRow: View {
    let label: String
    let utilization: Double
    let resetsAt: Date?
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)

                MiniBar(percentage: utilization)

                Text(String(format: "%.0f%%", utilization))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)

                Spacer(minLength: 0)

                if let resetsAt {
                    Text(resetsAt, style: .relative)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .contentTransition(.numericText())
                        .animation(nil, value: resetsAt)
                }
            }

            if let detail {
                Text(detail)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 32)
            }
        }
    }
}

// MARK: - Mini Bar

private struct MiniBar: View {
    let percentage: Double

    private static let barWidth: Double = 100

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.quaternary)
            RoundedRectangle(cornerRadius: 2)
                .fill(barColor)
                .frame(width: max(0, Self.barWidth * min(percentage, 100) / 100))
        }
        .frame(width: Self.barWidth, height: 6)
    }

    private var barColor: Color {
        if percentage <= 50 { return .green }
        else if percentage <= 80 { return .orange }
        else { return .red }
    }
}

// MARK: - Tag View

private struct TagView: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
    }
}

// MARK: - Proxy Status Row

private struct ProxyStatusRow: View {
    let proxy: LocalProxyController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: running indicator + port + total cost
            HStack {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text(String(localized: "Proxy"))
                    .font(.body.weight(.medium))

                if proxy.proxyStatus.totalEstimatedCostUSD > 0 {
                    Text("$\(formatTotalCost(proxy.proxyStatus.totalEstimatedCostUSD))")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await proxy.resetCost() }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Reset cost estimate"))

                Spacer()
                ProxyMetricLabel(
                    label: String(localized: "port"),
                    value: "\(proxy.listeningPort)"
                )
            }

            if !apiCostBreakdowns.isEmpty {
                HStack(spacing: 6) {
                    ForEach(apiCostBreakdowns, id: \.flavor) { breakdown in
                        TagView(
                            text: String(
                                format: NSLocalizedString(
                                    "proxy.costBreakdown.tag",
                                    value: "%@ $%@",
                                    comment: "Proxy aggregate cost breakdown tag: API label then formatted dollar cost"
                                ),
                                breakdown.flavor.summaryLabel,
                                formatTotalCost(breakdown.cost)
                            ),
                            color: breakdownColor(for: breakdown.flavor)
                        )
                    }
                }
            }

            ForEach(proxy.sessionActivities) { activity in
                SessionActivityRow(activity: activity, proxyController: proxy)
            }

        }
    }

    private var apiCostBreakdowns: [(flavor: ProxyAPIFlavor, cost: Double)] {
        ProxyAPIFlavor.allCases.compactMap { flavor in
            let cost = proxy.proxyStatus.estimatedCostUSDByAPI[flavor] ?? 0
            guard cost > 0 else { return nil }
            return (flavor, cost)
        }
    }

    private func formatTotalCost(_ cost: Double) -> String {
        if cost < 0.01 {
            return String(format: "%.4f", cost)
        } else if cost < 1 {
            return String(format: "%.3f", cost)
        } else {
            return String(format: "%.2f", cost)
        }
    }

    private func breakdownColor(for flavor: ProxyAPIFlavor) -> Color {
        switch flavor {
        case .anthropicMessages:
            return .orange
        case .openAIResponses:
            return .blue
        }
    }
}

// MARK: - Session Activity Row

private struct SessionActivityRow: View {
    let activity: LocalProxyController.SessionActivity
    let proxyController: LocalProxyController?

    private var keepaliveModeBinding: Binding<KeepaliveMode> {
        Binding(
            get: { activity.keepaliveMode },
            set: { mode in
                proxyController?.setSessionKeepaliveMode(mode, for: activity.sessionID)
            }
        )
    }

    private var isInFlight: Bool {
        proxyController?.manualKeepaliveInFlight.contains(activity.sessionID) ?? false
    }

    private var lastResult: Bool? {
        proxyController?.manualKeepaliveLastResult[activity.sessionID]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Coding agent + abbreviated session ID + completed / keepalive / errored counts
            HStack(spacing: 0) {
                sessionTitle
                Spacer()
                sessionStats
            }

            // In-flight requests
            if !activity.activeRequests.isEmpty {
                Text(String(localized: "Active"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 10)

                ForEach(activity.activeRequests) { request in
                    RequestActivityRow(request: request)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            if let highlightColor = rowHighlightColor(for: request) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(highlightColor)
                                    .frame(width: 3)
                                    .padding(.leading, 5)
                            }
                        }
                }
            }

            if !activity.doneRequests.isEmpty {
                Text(String(localized: "Done"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 10)

                ForEach(activity.doneRequests) { request in
                    RequestActivityRow(request: request)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            if let highlightColor = rowHighlightColor(for: request) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(highlightColor)
                                    .frame(width: 3)
                                    .padding(.leading, 5)
                            }
                        }
                }
            }

            keepaliveSection
        }
    }

    @ViewBuilder
    private var sessionTitle: some View {
        if let agentName = activity.agentName,
           !activity.isOtherTraffic {
            Text(localizedTrackedSessionTitle(agentName: agentName, shortID: activity.shortID))
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Text(activity.rowTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func localizedTrackedSessionTitle(agentName: String, shortID: String) -> String {
        let format = NSLocalizedString(
            "proxy.session.title",
            value: "%1$@ %2$@",
            comment: "Proxy popup session row title: agent name and abbreviated session ID"
        )
        return String(format: format, locale: Locale.current, agentName, shortID)
    }

    @ViewBuilder
    private var keepaliveSection: some View {
        if ConfigService.shared.keepaliveEnabled,
           activity.supportsKeepalive {
            // Per-session keepalive controls
            HStack(spacing: 6) {
                Picker("", selection: keepaliveModeBinding) {
                    Text(String(localized: "Off")).tag(KeepaliveMode.off)
                    Text(String(localized: "Manual")).tag(KeepaliveMode.manual)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .controlSize(.mini)

                if activity.keepaliveMode == .manual {
                    if isInFlight {
                        ProgressView()
                            .controlSize(.mini)
                    } else if let result = lastResult {
                        Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result ? .green : .red)
                            .font(.caption)
                    } else {
                        Button(String(localized: "Send")) {
                            proxyController?.sendManualKeepalive(for: activity.sessionID)
                        }
                        .controlSize(.mini)
                        .disabled(!activity.canSendKeepalive)
                        .help(activity.canSendKeepalive
                            ? String(localized: "Send a cache-warming keepalive request")
                            : String(localized: "Waiting for lineage to be established"))
                    }
                }

                if let reason = activity.keepaliveDisabledReason {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption2)
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 10)

            // Per-session keepalive stats
            if activity.keepaliveCount > 0,
               let cachePercent = activity.lastKeepaliveCacheReadPercent {
                HStack(spacing: 4) {
                    Text(String(
                        format: NSLocalizedString(
                            "proxy.keepalive.stats",
                            value: "#keepalive: %d  last: %.0f%% cache read, %d out tok",
                            comment: ""
                        ),
                        activity.keepaliveCount,
                        cachePercent,
                        activity.lastKeepaliveOutputTokens ?? 0
                    ))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                    if let lastAt = activity.lastKeepaliveAt {
                        Text(relativeTime(since: lastAt))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 10)
            }
        }
    }

    @ViewBuilder
    private var sessionStats: some View {
        HStack(spacing: 8) {
            if activity.completedRequests > 0 {
                ProxyMetricLabel(
                    label: String(localized: "done"),
                    value: "\(activity.completedRequests)"
                )
            }
            if activity.keepaliveCount > 0 {
                ProxyMetricLabel(
                    label: String(localized: "ka"),
                    value: "\(activity.keepaliveCount)"
                )
            }
            if activity.erroredRequests > 0 {
                HStack(spacing: 3) {
                    Text(String(localized: "err"))
                        .font(.callout)
                        .foregroundStyle(.red.opacity(0.7))
                    Text("\(activity.erroredRequests)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.red)
                }
            }
            if activity.estimatedCostUSD > 0 {
                ProxyMetricLabel(
                    label: "$",
                    value: formatCost(activity.estimatedCostUSD)
                )
            }
        }
    }

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 {
            return String(format: "%.4f", cost)
        } else if cost < 1 {
            return String(format: "%.3f", cost)
        } else {
            return String(format: "%.2f", cost)
        }
    }

    private func relativeTime(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds < 3600 {
            return "\(seconds / 60)m"
        } else {
            return "\(seconds / 3600)h"
        }
    }

    private func rowHighlightColor(for request: ProxyRequestActivity) -> Color? {
        if request.isKeepalive {
            return .green
        }
        if request.isMainAgentShaped {
            return .accentColor
        }
        return nil
    }
}

// MARK: - Request Activity Row

private struct RequestActivityRow: View {
    let request: ProxyRequestActivity

    private enum StatField {
        static let timingLabelWidth = 4
        static let valueWidth = 6
        static let outputValueWidth = 5
        static let durationWidth = 4
        static let costWidth = 5
    }

    private var rowFont: Font { .callout.monospaced() }

    var body: some View {
        HStack(spacing: 5) {
            if request.isKeepalive {
                Image(systemName: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .help(String(localized: "Keepalive request"))
            }
            if let modelName = compactModelName {
                Text(modelName)
                    .font(rowFont)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            leftStats
            Spacer()
            Text(request.startedAt, style: .timer)
                .font(rowFont)
                .foregroundStyle(.tertiary)
                .contentTransition(.numericText())
        }
    }

    @ViewBuilder
    private var leftStats: some View {
        switch request.state {
        case .uploading:
            if request.bytesSent > 0 {
                Text("\u{2191}")
                    .font(rowFont)
                    .foregroundStyle(.tertiary)
                Text(formattedBytes(request.bytesSent))
                    .font(rowFont)
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                Text(String(localized: "sending"))
                    .font(rowFont)
                    .foregroundStyle(.secondary)
                    .italic()
            }

        case .waiting:
            Text("\u{2191}")
                .font(rowFont)
                .foregroundStyle(.tertiary)
            Text(formattedBytes(request.bytesSent))
                .font(rowFont)
                .foregroundStyle(.tertiary)
            Text(String(localized: "waiting\u{2026}"))
                .font(rowFont)
                .foregroundStyle(.secondary)
                .italic()

        case .receiving:
            // upload bytes, italic download bytes, and TTFT duration
            Text("\u{2191}")
                .font(rowFont)
                .foregroundStyle(.tertiary)
            Text(formattedBytes(request.bytesSent))
                .font(rowFont)
                .foregroundStyle(.tertiary)
            Text("\u{2193}")
                .font(rowFont)
                .foregroundStyle(.tertiary)
            Text(formattedBytes(request.bytesReceived))
                .font(rowFont)
                .foregroundStyle(.secondary)
                .italic()
            if let ttft = timeToFirstToken {
                Text(paddedLabel("ttft", width: StatField.timingLabelWidth))
                    .font(rowFont)
                    .foregroundStyle(.tertiary)
                Text(formattedDuration(ttft))
                    .font(rowFont)
                    .foregroundStyle(.secondary)
            }

        case .done:
            if let promptK = request.promptTokens {
                Text("\u{2191}")
                    .font(rowFont)
                    .foregroundStyle(.tertiary)
                Text(formattedTokenCount(promptK))
                    .font(rowFont)
                    .foregroundStyle(.secondary)
            }
            if let outputK = request.tokenUsage?.outputTokens, outputK > 0 {
                Text("\u{2193}")
                    .font(rowFont)
                    .foregroundStyle(.tertiary)
                Text(formattedTokenCount(outputK, width: StatField.outputValueWidth))
                    .font(rowFont)
                    .foregroundStyle(.secondary)
            }
            if let e2e = endToEndDuration {
                Text(paddedLabel("e2e", width: StatField.timingLabelWidth))
                    .font(rowFont)
                    .foregroundStyle(.tertiary)
                Text(formattedDuration(e2e))
                    .font(rowFont)
                    .foregroundStyle(.secondary)
            }
            if let cost = request.estimatedCost {
                Text("$")
                    .font(rowFont)
                    .foregroundStyle(.tertiary)
                Text(formatCost(cost))
                    .font(rowFont)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Computed timing

    /// Time from request start to the first upstream data chunk.
    /// Falls back to `receivingStartedAt` (headers) for non-streaming responses.
    private var timeToFirstToken: TimeInterval? {
        guard let dataAt = request.firstDataAt ?? request.receivingStartedAt else { return nil }
        return dataAt.timeIntervalSince(request.startedAt)
    }

    /// Total request duration from start to completion.
    private var endToEndDuration: TimeInterval? {
        guard let completedAt = request.completedAt else { return nil }
        return completedAt.timeIntervalSince(request.startedAt)
    }

    private var compactModelName: String? {
        guard let rawModelID = request.modelID?
            .replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
            .split(separator: "/")
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawModelID.isEmpty else {
            return nil
        }

        let modelID = rawModelID
            .replacingOccurrences(of: #"[-_@.]20\d{6}$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[-_@.]20\d{2}[-_]\d{2}[-_]\d{2}$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[-_@.]v?\d{8}$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_.@"))

        let normalized = modelID.lowercased()

        if normalized.contains("sonnet") {
            return "Sonnet"
        }
        if normalized.contains("opus") {
            return "Opus"
        }
        if normalized.contains("haiku") {
            return "Haiku"
        }
        if normalized.contains("gpt-5.4") {
            return "GPT-5.4"
        }
        if normalized.contains("gpt-5.3") {
            return "GPT-5.3"
        }
        if normalized.contains("gpt-5.2") {
            return "GPT-5.2"
        }
        if normalized.contains("gpt-5.1") {
            return "GPT-5.1"
        }
        if normalized.contains("gpt-5") {
            return "GPT-5"
        }
        if normalized.contains("gpt-4.1") {
            return "GPT-4.1"
        }
        if normalized.contains("gpt-4o") {
            return "GPT-4o"
        }
        if normalized.contains("o4-mini") {
            return "o4-mini"
        }
        if normalized.contains("o3") {
            return "o3"
        }
        if normalized.contains("o1") {
            return "o1"
        }

        return modelID.isEmpty ? rawModelID : modelID
    }

    // MARK: - Formatting

    private func formattedBytes(_ bytes: Int) -> String {
        formattedScaledField(
            value: Double(max(0, bytes)),
            units: ["B", "KB", "MB", "GB", "TB", "PB"],
            totalWidth: StatField.valueWidth,
            allowFractionInBaseUnit: false
        )
    }

    private func formattedTokenCount(_ tokens: Int) -> String {
        formattedTokenCount(tokens, width: StatField.valueWidth)
    }

    private func formattedTokenCount(_ tokens: Int, width: Int) -> String {
        formattedScaledField(
            value: Double(max(0, tokens)),
            units: ["", "K", "M", "B", "T", "P", "E"],
            totalWidth: width,
            allowFractionInBaseUnit: false
        )
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        formattedCompactDuration(seconds, width: StatField.durationWidth)
    }

    private func formatCost(_ cost: Double) -> String {
        formattedFixedWidthNumber(max(0, cost), width: StatField.costWidth)
    }

    private func formattedScaledField(
        value: Double,
        units: [String],
        totalWidth: Int,
        allowFractionInBaseUnit: Bool
    ) -> String {
        let base = 1000.0  // KB/MB/GB are decimal units; 1024 would be KiB/MiB/GiB.
        var scaled = value
        var unitIndex = 0

        while unitIndex < units.count - 1 && scaled >= base {
            scaled /= base
            unitIndex += 1
        }

        while true {
            let unit = units[unitIndex]
            let numericWidth = max(1, totalWidth - unit.count)
            if unitIndex > 0,
               unitIndex < units.count - 1,
               roundedValueForWidth(scaled, width: numericWidth) >= base {
                scaled /= base
                unitIndex += 1
                continue
            }

            let numeric: String
            if unitIndex == 0 && !allowFractionInBaseUnit {
                numeric = String(Int(scaled.rounded(.down)))
            } else {
                numeric = formattedFixedWidthNumber(scaled, width: numericWidth)
            }

            if numeric.count <= numericWidth || unitIndex == units.count - 1 {
                return leftPadded(numeric, to: numericWidth) + unit
            }

            scaled /= base
            unitIndex += 1
        }
    }

    private func formattedFixedWidthNumber(_ value: Double, width: Int) -> String {
        var decimals = max(0, width - integerDigitCount(of: value) - 1)

        while true {
            let rounded = roundedValue(value, decimals: decimals)
            let digits = integerDigitCount(of: rounded)
            let maxDecimals = max(0, width - digits - 1)
            if decimals > maxDecimals {
                decimals = maxDecimals
                continue
            }

            if decimals > 0 {
                return String(
                    format: "%.\(decimals)f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    rounded
                )
            }

            let integerString = String(Int(rounded))
            if integerString.count < width {
                return integerString + "."
            }
            return integerString
        }
    }

    private func integerDigitCount(of value: Double) -> Int {
        String(Int(max(0, value.rounded(.down)))).count
    }

    private func roundedValue(_ value: Double, decimals: Int) -> Double {
        let factor = pow(10.0, Double(decimals))
        return (value * factor).rounded() / factor
    }

    private func roundedValueForWidth(_ value: Double, width: Int) -> Double {
        let decimals = max(0, width - integerDigitCount(of: value) - 1)
        return roundedValue(value, decimals: decimals)
    }

    private func leftPadded(_ string: String, to width: Int) -> String {
        let padding = max(0, width - string.count)
        return String(repeating: " ", count: padding) + string
    }

    private func paddedLabel(_ label: String, width: Int) -> String {
        let padding = max(0, width - label.count)
        return label + String(repeating: " ", count: padding)
    }

    private func formattedCompactDuration(_ seconds: TimeInterval, width: Int) -> String {
        let clamped = max(0, seconds)
        let wholeSeconds = Int(clamped.rounded(.down))
        let rendered: String

        if clamped < 10 {
            rendered = String(
                format: "%.1fs",
                locale: Locale(identifier: "en_US_POSIX"),
                clamped
            )
        } else if wholeSeconds < 1000 {
            rendered = "\(wholeSeconds)s"
        } else if wholeSeconds < 3600 {
            rendered = "\(wholeSeconds / 60)m"
        } else if wholeSeconds < 86_400 {
            rendered = "\(wholeSeconds / 3600)h"
        } else {
            rendered = "\(wholeSeconds / 86_400)d"
        }

        return leftPadded(rendered, to: width)
    }
}

// MARK: - Proxy Metric Label

private struct ProxyMetricLabel: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
