import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationService()

    private struct ProviderSnapshot {
        var fiveHourUtilization: Double?
        var fiveHourResetsAt: Date?
        var sevenDayResetsAt: Date?
    }

    private var snapshots: [String: ProviderSnapshot] = [:]

    private override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Called after each successful provider refresh with the latest entries.
    func evaluate(entries: [ProviderEntry]) {
        for entry in entries {
            guard case .ready(let data) = entry.status else { continue }

            let previous = snapshots[entry.id]
            let current = ProviderSnapshot(
                fiveHourUtilization: data.fiveHour?.utilization,
                fiveHourResetsAt: data.fiveHour?.resetsAt,
                sevenDayResetsAt: data.sevenDay?.resetsAt
            )

            if let previous {
                checkThresholds(provider: entry.displayName, previous: previous, current: current, data: data)
                checkResets(provider: entry.displayName, previous: previous, current: current, data: data)
            }

            snapshots[entry.id] = current
        }
    }

    // MARK: - Threshold checks

    private func checkThresholds(provider: String, previous: ProviderSnapshot, current: ProviderSnapshot, data: UsageData) {
        guard let prevUtil = previous.fiveHourUtilization,
              let curUtil = current.fiveHourUtilization else { return }

        if prevUtil < 80 && curUtil >= 80 {
            let body = String(
                format: NSLocalizedString("notification.threshold.body", value: "Used %.1f%% — resets %@", comment: ""),
                curUtil,
                resetTimeDescription(data.fiveHour?.resetsAt)
            )
            send(
                id: "\(provider)-5h-80",
                title: String(
                    format: NSLocalizedString("notification.threshold80.title", value: "%@ %@ usage above 80%%", comment: ""),
                    provider,
                    data.primaryWindowLabel
                ),
                body: body
            )
        } else if prevUtil < 50 && curUtil >= 50 {
            let body = String(
                format: NSLocalizedString("notification.threshold.body", value: "Used %.1f%% — resets %@", comment: ""),
                curUtil,
                resetTimeDescription(data.fiveHour?.resetsAt)
            )
            send(
                id: "\(provider)-5h-50",
                title: String(
                    format: NSLocalizedString("notification.threshold50.title", value: "%@ %@ usage above 50%%", comment: ""),
                    provider,
                    data.primaryWindowLabel
                ),
                body: body
            )
        }
    }

    // MARK: - Reset checks

    private func checkResets(provider: String, previous: ProviderSnapshot, current: ProviderSnapshot, data: UsageData) {
        // A real 5h reset jumps resetsAt forward by hours; ignore jitter under 1h
        if let prevReset = previous.fiveHourResetsAt,
           let curReset = current.fiveHourResetsAt,
           curReset.timeIntervalSince(prevReset) > 3600 {
            send(
                id: "\(provider)-5h-reset",
                title: String(
                    format: NSLocalizedString("notification.5hReset.title", value: "%@ %@ quota reset", comment: ""),
                    provider,
                    data.primaryWindowLabel
                ),
                body: NSLocalizedString("notification.5hReset.body", value: "Usage back to 0% — full quota available", comment: "")
            )
        }

        // A real 7d reset jumps resetsAt forward by days; ignore jitter under 1 day
        if let prevReset = previous.sevenDayResetsAt,
           let curReset = current.sevenDayResetsAt,
           curReset.timeIntervalSince(prevReset) > 86400 {
            send(
                id: "\(provider)-7d-reset",
                title: String(
                    format: NSLocalizedString("notification.7dReset.title", value: "%@ %@ quota reset", comment: ""),
                    provider,
                    data.secondaryWindowLabel
                ),
                body: NSLocalizedString("notification.7dReset.body", value: "Quota window has been refreshed", comment: "")
            )
        }
    }

    // MARK: - Helpers

    private func resetTimeDescription(_ date: Date?) -> String {
        guard let date else {
            return NSLocalizedString("notification.resetTime.unknown", value: "at unknown time", comment: "")
        }
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else {
            return NSLocalizedString("notification.resetTime.soon", value: "soon", comment: "")
        }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 0 {
            return String(
                format: NSLocalizedString("notification.resetTime.hoursMinutes", value: "in %dh %dm", comment: ""),
                hours, minutes
            )
        }
        return String(
            format: NSLocalizedString("notification.resetTime.minutes", value: "in %dm", comment: ""),
            minutes
        )
    }

    private func send(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
