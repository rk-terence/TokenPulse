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
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(manager.isRefreshing)

                Button(action: { onOpenSettings?() }) {
                    Image(systemName: "gear")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Provider rows
            if manager.providerEntries.isEmpty {
                Text("No providers configured")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(manager.providerEntries, id: \.id) { entry in
                    ProviderRow(entry: entry)
                    if entry.id != manager.providerEntries.last?.id {
                        Divider()
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                if let lastUpdate = manager.lastUpdated {
                    Text("Updated \(lastUpdate, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 280)
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

            if case .ready(let data) = entry.status {
                // Quota rows
                QuotaGrid(entry: entry, data: data)
            }

            if case .error(let msg) = entry.status {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .idle: return .gray
        case .loading: return .blue
        case .ready(let data):
            guard let u = data.fiveHour?.utilization else { return .gray }
            if u <= 50 { return .green }
            else if u <= 80 { return .orange }
            else { return .red }
        case .error: return .red
        }
    }

    private var fiveHourText: String {
        switch entry.status {
        case .ready(let data):
            if let u = data.fiveHour?.utilization {
                return String(format: "%.0f%%", u)
            }
            return "--"
        case .loading: return "..."
        case .error: return "err"
        case .idle: return "--"
        }
    }
}

// MARK: - Quota Grid

private struct QuotaGrid: View {
    let entry: ProviderEntry
    let data: UsageData

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
    }

    // MARK: - Claude extras

    @ViewBuilder
    private var claudeExtras: some View {
        if let opusStr = data.extras["opusUtilization"],
           let opus = Double(opusStr) {
            HStack(spacing: 4) {
                Text("Opus")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                MiniBar(percentage: opus)
                Text(String(format: "%.0f%%", opus))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    // MARK: - ZenMux extras

    @ViewBuilder
    private var zenMuxExtras: some View {
        // Monthly cap
        if let maxUsd = data.extras["moMaxUsd"] {
            HStack(spacing: 4) {
                Text("mo")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
                Text("cap $\(maxUsd)")
                    .font(.callout.monospacedDigit())
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
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)

                MiniBar(percentage: utilization)

                Text(String(format: "%.0f%%", utilization))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)

                Spacer(minLength: 0)

                if let resetsAt {
                    Text(resetsAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if let detail {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 28)
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
        .frame(width: 60, height: 6)
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
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
    }
}
