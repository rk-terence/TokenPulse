import SwiftUI

struct PopoverView: View {
    let manager: ProviderManager
    var proxyController: LocalProxyController?
    var onOpenSettings: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Text("TokenPulse")
                    .font(.headline)
                Spacer()
                HeaderActionButton(
                    title: manager.isRefreshing
                        ? String(localized: "Refreshing…")
                        : String(localized: "Refresh"),
                    isEmphasized: manager.isRefreshing,
                    action: { manager.requestRefresh() }
                )

                HeaderActionButton(
                    title: String(localized: "Settings"),
                    action: { onOpenSettings?() }
                )
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

            Divider()

            // Proxy status (compact)
            if let proxy = proxyController, proxy.isRunning {
                ProxyStatusRow(proxy: proxy)
                Divider()
            }

            // Footer
            HStack {
                if let lastUpdate = manager.lastUpdated {
                    Text("Last checked \(lastUpdate, style: .relative)")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .contentTransition(.numericText())
                        .animation(nil, value: lastUpdate)
                }
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
        .frame(width: 320)
    }

}

private struct HeaderActionButton: View {
    let title: String
    var isEmphasized = false
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(HeaderActionButtonStyle(isEmphasized: isEmphasized))
    }
}

private struct HeaderActionButtonStyle: ButtonStyle {
    var isEmphasized: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(foregroundColor(isPressed: configuration.isPressed))
            .padding(.horizontal, 11)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text(String(localized: "Proxy"))
                    .font(.body.weight(.medium))
                Spacer()
                Text(":\(proxy.listeningPort)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Compact metrics grid
            HStack(spacing: 12) {
                ProxyMetricLabel(label: String(localized: "sessions"), value: "\(proxy.proxyStatus.activeSessions)")
                ProxyMetricLabel(label: String(localized: "keepalive"), value: "\(proxy.proxyStatus.activeKeepalives)")
                ProxyMetricLabel(label: String(localized: "fwd"), value: "\(proxy.proxyStatus.totalRequestsForwarded)")
            }

            // Cache metrics
            HStack(spacing: 12) {
                ProxyMetricLabel(label: String(localized: "cache rd"), value: "\(proxy.proxyStatus.cacheReads)")
                ProxyMetricLabel(label: String(localized: "cache wr"), value: "\(proxy.proxyStatus.cacheWrites)")
            }
        }
    }
}

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
