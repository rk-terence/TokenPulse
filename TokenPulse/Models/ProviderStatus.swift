import Foundation

enum StaleReason: Sendable {
    case transient
    case auth
}

enum ProviderStatus: Sendable {
    case unconfigured
    case pendingFirstLoad
    case refreshing(lastData: UsageData?, lastMessage: String? = nil)
    case ready(UsageData)
    case stale(UsageData, reason: StaleReason, message: String)
    case error(String)

    var displayData: UsageData? {
        switch self {
        case .refreshing(let lastData, _):
            return lastData
        case .ready(let data):
            return data
        case .stale(let data, _, _):
            return data
        case .unconfigured, .pendingFirstLoad, .error:
            return nil
        }
    }

    var isLoading: Bool {
        if case .refreshing = self { return true }
        return false
    }

    var isConfigured: Bool {
        if case .unconfigured = self { return false }
        return true
    }

    var canDrivePrimaryUI: Bool {
        switch self {
        case .ready, .refreshing, .stale:
            return true
        case .unconfigured, .pendingFirstLoad, .error:
            return false
        }
    }

    var message: String? {
        switch self {
        case .unconfigured:
            return String(localized: "Not configured")
        case .pendingFirstLoad:
            return String(localized: "Waiting for first refresh")
        case .refreshing(let lastData, let lastMessage):
            if lastData == nil {
                return String(localized: "Refreshing...")
            }
            return lastMessage
        case .ready:
            return nil
        case .stale(_, _, let message), .error(let message):
            return message
        }
    }
}
