import CFNetwork
import Foundation

struct ProxyEndpoint: Equatable, Sendable {
    let host: String
    let port: Int

    static func parse(urlString: String) throws -> ProxyEndpoint {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HTTPSProxyConfigurationError.empty
        }

        guard let components = URLComponents(string: trimmed) else {
            throw HTTPSProxyConfigurationError.invalidURL
        }

        guard let scheme = components.scheme?.lowercased(), !scheme.isEmpty else {
            throw HTTPSProxyConfigurationError.invalidURL
        }

        guard scheme == "http" || scheme == "https" else {
            throw HTTPSProxyConfigurationError.unsupportedScheme(scheme)
        }

        guard let host = components.host, !host.isEmpty else {
            throw HTTPSProxyConfigurationError.missingHost
        }

        if components.user != nil || components.password != nil {
            throw HTTPSProxyConfigurationError.embeddedCredentialsNotSupported
        }

        if let queryItems = components.queryItems, !queryItems.isEmpty {
            throw HTTPSProxyConfigurationError.invalidURL
        }

        if components.fragment != nil {
            throw HTTPSProxyConfigurationError.invalidURL
        }

        let path = components.path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty && path != "/" {
            throw HTTPSProxyConfigurationError.unsupportedPath
        }

        let port = components.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else {
            throw HTTPSProxyConfigurationError.invalidPort
        }

        return ProxyEndpoint(host: host, port: port)
    }

    static func parseOptional(urlString: String) throws -> ProxyEndpoint? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        return try parse(urlString: trimmed)
    }
}

struct HTTPSProxyConfiguration: Equatable, Sendable {
    let httpProxy: ProxyEndpoint?
    let httpsProxy: ProxyEndpoint?

    var connectionProxyDictionary: [AnyHashable: Any] {
        var dictionary: [AnyHashable: Any] = [
            kCFNetworkProxiesHTTPEnable as String: false,
            kCFNetworkProxiesHTTPSEnable as String: false,
        ]

        if let httpProxy {
            dictionary[kCFNetworkProxiesHTTPEnable as String] = true
            dictionary[kCFNetworkProxiesHTTPProxy as String] = httpProxy.host
            dictionary[kCFNetworkProxiesHTTPPort as String] = httpProxy.port
        }

        if let httpsProxy {
            dictionary[kCFNetworkProxiesHTTPSEnable as String] = true
            dictionary[kCFNetworkProxiesHTTPSProxy as String] = httpsProxy.host
            dictionary[kCFNetworkProxiesHTTPSPort as String] = httpsProxy.port
        }

        return dictionary
    }

    var summaryDescription: String {
        let parts = [
            httpProxy.map { "HTTP \($0.host):\($0.port)" },
            httpsProxy.map { "HTTPS \($0.host):\($0.port)" }
        ].compactMap { $0 }

        return parts.joined(separator: " | ")
    }

    static func parse(httpProxyURLString: String, httpsProxyURLString: String) throws -> HTTPSProxyConfiguration {
        HTTPSProxyConfiguration(
            httpProxy: try ProxyEndpoint.parseOptional(urlString: httpProxyURLString),
            httpsProxy: try ProxyEndpoint.parseOptional(urlString: httpsProxyURLString)
        )
    }

    static func systemConfiguration() -> HTTPSProxyConfiguration? {
        guard let unmanaged = CFNetworkCopySystemProxySettings() else {
            return nil
        }

        let settings = unmanaged.takeRetainedValue() as NSDictionary
        let httpProxy = endpoint(
            enabledKey: kCFNetworkProxiesHTTPEnable as String,
            hostKey: kCFNetworkProxiesHTTPProxy as String,
            portKey: kCFNetworkProxiesHTTPPort as String,
            settings: settings
        )
        let httpsProxy = endpoint(
            enabledKey: kCFNetworkProxiesHTTPSEnable as String,
            hostKey: kCFNetworkProxiesHTTPSProxy as String,
            portKey: kCFNetworkProxiesHTTPSPort as String,
            settings: settings
        )

        guard httpProxy != nil || httpsProxy != nil else {
            return nil
        }

        return HTTPSProxyConfiguration(
            httpProxy: httpProxy,
            httpsProxy: httpsProxy
        )
    }

    private static func endpoint(
        enabledKey: String,
        hostKey: String,
        portKey: String,
        settings: NSDictionary
    ) -> ProxyEndpoint? {
        guard isEnabled(settings[enabledKey]) else {
            return nil
        }

        guard let host = settings[hostKey] as? String, !host.isEmpty else {
            return nil
        }

        guard let port = parsePort(settings[portKey]), (1...65535).contains(port) else {
            return nil
        }

        return ProxyEndpoint(host: host, port: port)
    }

    private static func isEnabled(_ value: Any?) -> Bool {
        switch value {
        case let number as NSNumber:
            return number.boolValue
        case let bool as Bool:
            return bool
        default:
            return false
        }
    }

    private static func parsePort(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }
}

enum UpstreamHTTPSProxySetting: Equatable, Sendable {
    case disabled
    case configured(HTTPSProxyConfiguration)
    case invalid(String)

    var proxyConfiguration: HTTPSProxyConfiguration? {
        switch self {
        case .configured(let configuration):
            return configuration
        case .disabled, .invalid:
            return nil
        }
    }

    var validationError: String? {
        switch self {
        case .invalid(let message):
            return message
        case .disabled, .configured:
            return nil
        }
    }
}

enum HTTPSProxyConfigurationError: LocalizedError, Sendable {
    case empty
    case invalidURL
    case unsupportedScheme(String)
    case missingHost
    case embeddedCredentialsNotSupported
    case invalidPort
    case unsupportedPath

    var errorDescription: String? {
        switch self {
        case .empty:
            return String(localized: "Enter a proxy URL.")
        case .invalidURL:
            return String(localized: "Enter a full proxy URL such as http://127.0.0.1:7890.")
        case .unsupportedScheme(let scheme):
            return String(localized: "Unsupported proxy scheme '\(scheme)'. Use http:// or https://.")
        case .missingHost:
            return String(localized: "The proxy URL is missing a host name.")
        case .embeddedCredentialsNotSupported:
            return String(localized: "Proxy URLs cannot include usernames or passwords.")
        case .invalidPort:
            return String(localized: "The proxy URL must use a port between 1 and 65535.")
        case .unsupportedPath:
            return String(localized: "Proxy URLs should not include a path. Use only the scheme, host, and port.")
        }
    }
}

enum UpstreamNetworkingError: LocalizedError, Sendable {
    case invalidHTTPSProxy(String)

    var errorDescription: String? {
        switch self {
        case .invalidHTTPSProxy(let message):
            return String(localized: "Upstream HTTPS proxy setting is invalid: \(message)")
        }
    }
}

enum UpstreamNetworking {
    static func makeSessionFromCurrentSettings() async throws -> URLSession {
        let proxySetting = await MainActor.run { ConfigService.shared.effectiveUpstreamProxySetting }
        return try makeSession(for: proxySetting)
    }

    static func makeSession(for proxySetting: UpstreamHTTPSProxySetting) throws -> URLSession {
        switch proxySetting {
        case .disabled:
            return URLSession(configuration: makeSessionConfiguration(proxyConfiguration: nil))
        case .configured(let configuration):
            return URLSession(configuration: makeSessionConfiguration(proxyConfiguration: configuration))
        case .invalid(let message):
            throw UpstreamNetworkingError.invalidHTTPSProxy(message)
        }
    }

    static func makeSessionConfiguration(
        proxyConfiguration: HTTPSProxyConfiguration?,
        timeoutIntervalForRequest: TimeInterval? = nil,
        timeoutIntervalForResource: TimeInterval? = nil
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        if let timeoutIntervalForRequest {
            configuration.timeoutIntervalForRequest = timeoutIntervalForRequest
        }
        if let timeoutIntervalForResource {
            configuration.timeoutIntervalForResource = timeoutIntervalForResource
        }
        configuration.connectionProxyDictionary = (proxyConfiguration ?? HTTPSProxyConfiguration(httpProxy: nil, httpsProxy: nil)).connectionProxyDictionary
        return configuration
    }
}
