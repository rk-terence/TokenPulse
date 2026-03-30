import SwiftUI

struct PopoverView: View {
    let manager: ProviderManager
    var onOpenSettings: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Text("TokenPulse")
                    .font(.headline)
                Spacer()
                Button(action: { manager.requestRefresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.callout)
                        .rotationEffect(.degrees(manager.isRefreshing ? 360 : 0))
                        .animation(manager.isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: manager.isRefreshing)
                }
                .buttonStyle(.plain)

                Button(action: { onOpenSettings?() }) {
                    Image(systemName: "gear")
                        .font(.callout)
                }
                .buttonStyle(.plain)
            }

            Divider()

            if manager.configuredProviderCount == 0 {
                Text("No providers configured. Open Settings to connect Claude or ZenMux.")
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

            // Footer
            HStack {
                if let lastUpdate = manager.lastUpdated {
                    Text("Last checked \(lastUpdate, style: .relative)")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
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
        case .refreshing:
            return false
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
                    label: "5h",
                    utilization: fiveHour.utilization,
                    resetsAt: fiveHour.resetsAt,
                    detail: usdDetail(used: "5hUsedUsd", max: "5hMaxUsd")
                )
            }

            // 7-day row
            if let sevenDay = data.sevenDay {
                QuotaRow(
                    label: "7d",
                    utilization: sevenDay.utilization,
                    resetsAt: sevenDay.resetsAt,
                    detail: usdDetail(used: "7dUsedUsd", max: "7dMaxUsd")
                )
            }

            // Provider-specific extras
            switch entry.id {
            case "claude":
                claudeExtras
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
            HStack(spacing: 4) {
                Text("mo")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
                Text("cap $\(maxUsd)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.tertiary)
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

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor)
                    .frame(width: max(0, geo.size.width * min(percentage, 100) / 100))
            }
        }
        .frame(width: 100, height: 6)
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
