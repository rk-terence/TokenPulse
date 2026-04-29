import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationService()
    nonisolated static let keepaliveReminderCategoryIdentifier = "proxy.keepalive.reminder"
    nonisolated static let keepaliveReminderActionIdentifier = "proxy.keepalive.reminder.send"

    private struct ProviderSnapshot {
        var fiveHourUtilization: Double?
        var fiveHourResetsAt: Date?
        var sevenDayResetsAt: Date?
    }

    private var snapshots: [String: ProviderSnapshot] = [:]
    /// Latest delivered KA reminder identifier, keyed by conversation. Used
    /// to drop stale notifications when a new reminder issues for the same
    /// conversation (source flip) or the selection ends (manual stop / auto
    /// deactivation). The action button on a stale notification still
    /// no-ops via actor-isolated validation, but we don't want to leave
    /// dead "Send keep-alive request" buttons sitting in Notification
    /// Center.
    private var pendingKeepaliveReminderIDs: [UUID: String] = [:]
    var onKeepaliveReminderAction: ((KeepaliveReminder) -> Void)?

    private override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerCategories(center: center)
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func registerCategories(center: UNUserNotificationCenter) {
        let sendKeepaliveAction = UNNotificationAction(
            identifier: Self.keepaliveReminderActionIdentifier,
            title: NSLocalizedString(
                "notification.proxy.keepaliveReminder.action",
                value: "Send keep-alive request",
                comment: "Action button title for a keep-alive reminder notification"
            ),
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.keepaliveReminderCategoryIdentifier,
            actions: [sendKeepaliveAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
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

    /// Notify the user that keepalive has been auto-stopped for a proxy session.
    /// When `reason` is provided (e.g. lineage divergence), it replaces the default failure message.
    func sendProxyKeepaliveDisabled(sessionID: String, reason: String? = nil) {
        let message: String
        if let reason {
            message = String(
                format: NSLocalizedString(
                    "notification.proxy.keepaliveDisabledReason.body",
                    value: "Keep-alive stopped for session %@: %@",
                    comment: ""
                ),
                sessionID,
                reason
            )
        } else {
            message = String(
                format: NSLocalizedString(
                    "notification.proxy.keepaliveDisabled.body",
                    value: "Keep-alive stopped for session %@ after repeated failures.",
                    comment: ""
                ),
                sessionID
            )
        }
        send(
            id: "proxy-keepalive-disabled-\(sessionID)",
            title: String(localized: "Proxy keep-alive stopped"),
            body: message
        )
    }

    /// Notify the user that the selected KA source is nearing the prompt-cache
    /// TTL. The action button only routes back through stale-click validation.
    func sendProxyKeepaliveReminder(_ reminder: KeepaliveReminder) {
        guard let userInfo = Self.userInfo(for: reminder) else { return }
        let id = "proxy-keepalive-reminder-\(reminder.conversationID.uuidString)-\(reminder.sourceRequestID.uuidString)"
        if let previousID = pendingKeepaliveReminderIDs[reminder.conversationID], previousID != id {
            removeKeepaliveReminderNotification(id: previousID)
        }
        pendingKeepaliveReminderIDs[reminder.conversationID] = id
        let sessionID = ProxySessionID.shortDisplayID(for: reminder.sourceSessionID)
        let body = String(
            format: NSLocalizedString(
                "notification.proxy.keepaliveReminder.body",
                value: "Session %@ has been quiet for 4m30s.",
                comment: "Keep-alive reminder notification body; parameter is a short proxy session ID"
            ),
            sessionID
        )
        send(
            id: id,
            title: NSLocalizedString(
                "notification.proxy.keepaliveReminder.title",
                value: "Keep-alive reminder",
                comment: "Keep-alive reminder notification title"
            ),
            body: body,
            categoryIdentifier: Self.keepaliveReminderCategoryIdentifier,
            userInfo: userInfo
        )
    }

    /// Drop any pending or delivered KA reminder notification for the given
    /// conversation. Called from both the auto-deactivation and manual-stop
    /// paths so a "Send keep-alive request" button never lingers after the
    /// selection that backed it has gone away.
    func clearProxyKeepaliveReminder(forConversationID conversationID: UUID) {
        guard let id = pendingKeepaliveReminderIDs.removeValue(forKey: conversationID) else { return }
        removeKeepaliveReminderNotification(id: id)
    }

    private func removeKeepaliveReminderNotification(id: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
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

    private func send(
        id: String,
        title: String,
        body: String,
        categoryIdentifier: String? = nil,
        userInfo: [AnyHashable: Any] = [:]
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated static let keepaliveReminderUserInfoKey = "keepaliveReminderPayload"

    nonisolated private static func userInfo(for reminder: KeepaliveReminder) -> [AnyHashable: Any]? {
        guard let data = try? JSONEncoder().encode(reminder) else { return nil }
        return [keepaliveReminderUserInfoKey: data]
    }

    nonisolated private static func reminder(from userInfo: [AnyHashable: Any]) -> KeepaliveReminder? {
        guard let data = userInfo[keepaliveReminderUserInfoKey] as? Data else { return nil }
        return try? JSONDecoder().decode(KeepaliveReminder.self, from: data)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == Self.keepaliveReminderActionIdentifier else { return }
        guard let reminder = Self.reminder(from: response.notification.request.content.userInfo) else {
            return
        }
        await MainActor.run {
            self.onKeepaliveReminderAction?(reminder)
        }
    }
}
