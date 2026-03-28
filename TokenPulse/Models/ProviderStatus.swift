import Foundation

enum ProviderStatus: Sendable {
    case idle
    case loading
    case ready(UsageData)
    case error(String)

    var usageData: UsageData? {
        if case .ready(let data) = self { return data }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .error(let msg) = self { return msg }
        return nil
    }
}
