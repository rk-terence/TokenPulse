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
        .frame(width: 260)
    }

}

// MARK: - Provider Row

private struct ProviderRow: View {
    let entry: ProviderEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Main row: dot + name + 5h%
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(entry.displayName)
                    .font(.body)
                Spacer()
                Text(fiveHourText)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Detail row: 7-day + extras
            if case .ready(let data) = entry.status {
                HStack(spacing: 12) {
                    if let sevenDay = data.sevenDay {
                        Label {
                            Text(String(format: "%.0f%%", sevenDay.utilization))
                                .font(.caption.monospacedDigit())
                        } icon: {
                            Image(systemName: "calendar")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }

                    if let resetsAt = data.fiveHour?.resetsAt {
                        Label {
                            Text(resetsAt, style: .relative)
                                .font(.caption)
                        } icon: {
                            Image(systemName: "clock")
                                .font(.caption2)
                        }
                        .foregroundStyle(.tertiary)
                    }

                    // Extras
                    if let opus = data.extras["opusUtilization"] {
                        Text("Opus: \(opus)%")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if let tier = data.extras["tier"] {
                        Text(tier.capitalized)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
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
