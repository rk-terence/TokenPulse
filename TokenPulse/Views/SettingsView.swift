import AppKit
import ServiceManagement
import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case providers
    case proxy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return String(localized: "General")
        case .providers:
            return String(localized: "Providers")
        case .proxy:
            return String(localized: "Proxy")
        }
    }

    var subtitle: String {
        switch self {
        case .general:
            return String(localized: "App behavior and refresh timing")
        case .providers:
            return String(localized: "Connected services and credentials")
        case .proxy:
            return String(localized: "Local proxy routing and logging")
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .providers:
            return "server.rack"
        case .proxy:
            return "network"
        }
    }
}

struct SettingsView: View {
    let manager: ProviderManager
    let config: ConfigService
    var proxyController: LocalProxyController?

    /// Tracks the last value we programmatically set to suppress the resulting onChange.
    @State private var launchAtLoginRevertTarget: Bool?
    @State private var launchAtLoginError: String?
    @State private var selection: SettingsPane = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            detailPane
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 820, minHeight: 620)
        .onChange(of: config.launchAtLogin) { _, newValue in
            if let target = launchAtLoginRevertTarget, target == newValue {
                launchAtLoginRevertTarget = nil
                return
            }
            setLaunchAtLogin(newValue)
        }
        .onChange(of: config.pollInterval) { _, newValue in
            manager.onPollIntervalChanged?(newValue)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Settings"))
                    .font(.system(size: 28, weight: .semibold))

                Text(String(localized: "Adjust providers, refresh behavior, and local proxy tools without feeling boxed in."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                ForEach(SettingsPane.allCases) { pane in
                    Button {
                        selection = pane
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: pane.systemImage)
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(pane.title)
                                    .font(.headline)
                                Text(pane.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(SettingsSidebarButtonStyle(isSelected: selection == pane))
                }
            }

            Spacer(minLength: 0)
        }
        .frame(width: 240, alignment: .topLeading)
        .padding(20)
    }

    @ViewBuilder
    private var detailPane: some View {
        switch selection {
        case .general:
            GeneralTab(config: config, launchAtLoginError: launchAtLoginError)
        case .providers:
            ProvidersTab(manager: manager, config: config)
        case .proxy:
            ProxyTab(config: config, proxyController: proxyController)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            let reverted = !enabled
            launchAtLoginRevertTarget = reverted
            config.launchAtLogin = reverted
            launchAtLoginError = String(localized: "Failed to update launch at login: \(error.localizedDescription)")
        }
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @Bindable var config: ConfigService
    var launchAtLoginError: String?

    var body: some View {
        SettingsPage(
            title: String(localized: "General"),
            subtitle: String(localized: "Choose how TokenPulse starts and how often it refreshes your provider usage.")
        ) {
            SettingsCard(
                title: String(localized: "App startup"),
                description: String(localized: "Keep TokenPulse handy after login without reopening it manually.")
            ) {
                Toggle(String(localized: "Launch at login"), isOn: $config.launchAtLogin)

                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            SettingsCard(
                title: String(localized: "Refresh cadence"),
                description: String(localized: "The minimum refresh interval is 60 seconds across all providers.")
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "Polling interval"))
                        .font(.headline)

                    Picker(String(localized: "Polling interval"), selection: $config.pollInterval) {
                        Text(String(localized: "60 seconds")).tag(60.0)
                        Text(String(localized: "2 minutes")).tag(120.0)
                        Text(String(localized: "5 minutes")).tag(300.0)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    Text(String(localized: "Shorter intervals keep the menu bar current, while longer ones reduce provider traffic."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Providers Tab

private struct ProvidersTab: View {
    let manager: ProviderManager
    @Bindable var config: ConfigService

    @State private var zenMuxAPIKey = ""
    @State private var zenMuxKeySaved = false
    @State private var zenMuxRemoveError: String?

    var body: some View {
        SettingsPage(
            title: String(localized: "Providers"),
            subtitle: String(localized: "Enable the services you want to monitor and make sure TokenPulse can access the credentials it needs.")
        ) {
            SettingsCard(
                title: String(localized: "Claude"),
                description: String(localized: "Claude uses credentials already stored on this Mac, so there is nothing extra to paste here.")
            ) {
                Toggle(String(localized: "Enable Claude"), isOn: claudeEnabledBinding)

                if config.isProviderEnabled("claude") {
                    Divider()
                    SettingsStatusRow(
                        label: String(localized: "Credential status"),
                        value: claudeStatus,
                        tint: claudeConfigured ? .green : .secondary
                    )
                }
            }

            SettingsCard(
                title: String(localized: "Codex"),
                description: String(localized: "Codex reads your existing local Codex login and uses that to monitor ChatGPT subscription usage.")
            ) {
                Toggle(String(localized: "Enable Codex"), isOn: codexEnabledBinding)

                if config.isProviderEnabled("codex") {
                    Divider()

                    SettingsStatusRow(
                        label: String(localized: "Login status"),
                        value: codexStatus.description,
                        tint: codexStatus.isConfigured ? .green : .secondary
                    )

                    Text(codexHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsCard(
                title: String(localized: "ZenMux"),
                description: String(localized: "ZenMux requires a management API key that TokenPulse stores in your Keychain.")
            ) {
                Toggle(String(localized: "Enable ZenMux"), isOn: zenMuxEnabledBinding)

                if config.isProviderEnabled("zenmux") {
                    Divider()

                    SettingsStatusRow(
                        label: String(localized: "API key status"),
                        value: zenMuxConfigured ? String(localized: "Configured") : String(localized: "Not set"),
                        tint: zenMuxConfigured ? .green : .secondary
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "Management API key"))
                            .font(.headline)

                        SecureField(String(localized: "Paste your ZenMux management API key"), text: $zenMuxAPIKey)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { saveZenMuxAPIKey() }
                            .onChange(of: zenMuxAPIKey) { _, _ in
                                zenMuxKeySaved = false
                            }
                    }

                    HStack(alignment: .center, spacing: 12) {
                        Text(String(localized: "Get your key from the ZenMux dashboard."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)

                        if zenMuxKeySaved {
                            StatusPill(
                                text: String(localized: "Saved"),
                                tint: .green
                            )
                        }

                        if zenMuxConfigured {
                            Button(String(localized: "Remove")) {
                                removeZenMuxAPIKey()
                            }
                        }

                        Button(String(localized: "Save")) {
                            saveZenMuxAPIKey()
                        }
                        .disabled(zenMuxAPIKey.isEmpty)
                    }

                    if let zenMuxRemoveError {
                        Text(zenMuxRemoveError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    // MARK: - Enabled bindings

    private var claudeEnabledBinding: Binding<Bool> {
        Binding(
            get: { config.isProviderEnabled("claude") },
            set: { newValue in
                config.setProviderEnabled("claude", newValue)
                manager.providerEnabledChanged()
            }
        )
    }

    private var zenMuxEnabledBinding: Binding<Bool> {
        Binding(
            get: { config.isProviderEnabled("zenmux") },
            set: { newValue in
                config.setProviderEnabled("zenmux", newValue)
                manager.providerEnabledChanged()
            }
        )
    }

    private var codexEnabledBinding: Binding<Bool> {
        Binding(
            get: { config.isProviderEnabled("codex") },
            set: { newValue in
                config.setProviderEnabled("codex", newValue)
                manager.providerEnabledChanged()
            }
        )
    }

    // MARK: - Credential status

    private var claudeConfigured: Bool {
        ClaudeProvider().isConfigured()
    }

    private var claudeStatus: String {
        claudeConfigured ? String(localized: "Connected") : String(localized: "Not found")
    }

    private var zenMuxConfigured: Bool {
        (try? KeychainService.readGenericPassword(service: ZenMuxProvider.keychainService)) != nil
    }

    private var codexStatus: CodexConfigurationStatus {
        CodexProvider.configurationStatus()
    }

    private var codexHelpText: String {
        switch codexStatus {
        case .connected:
            return String(localized: "TokenPulse reads your existing Codex ChatGPT login from ~/.codex/auth.json.")
        case .apiKeyOnly:
            return String(localized: "Run `codex login` to switch from API key billing to your ChatGPT subscription.")
        case .missingLogin, .invalidAuthFile, .missingToken:
            return String(localized: "Sign in with `codex login`, then refresh TokenPulse.")
        }
    }

    private func saveZenMuxAPIKey() {
        guard !zenMuxAPIKey.isEmpty,
              let data = zenMuxAPIKey.data(using: .utf8) else { return }
        do {
            try KeychainService.saveGenericPassword(data, service: ZenMuxProvider.keychainService)
            zenMuxKeySaved = true
            zenMuxAPIKey = ""
            zenMuxRemoveError = nil
            manager.requestRefresh()
        } catch {
            zenMuxKeySaved = false
        }
    }

    private func removeZenMuxAPIKey() {
        do {
            try KeychainService.deleteGenericPassword(service: ZenMuxProvider.keychainService)
            zenMuxKeySaved = false
            zenMuxAPIKey = ""
            zenMuxRemoveError = nil
            manager.requestRefresh()
        } catch {
            zenMuxKeySaved = false
            zenMuxRemoveError = String(localized: "Failed to remove API key: \(error.localizedDescription)")
        }
    }
}

// MARK: - Proxy Tab

private struct ProxyTab: View {
    @Bindable var config: ConfigService
    var proxyController: LocalProxyController?

    @State private var portText: String = ""

    private var proxyEnabledBinding: Binding<Bool> {
        Binding(
            get: { config.proxyEnabled },
            set: { newValue in
                config.proxyEnabled = newValue
                if newValue {
                    startProxy()
                } else {
                    stopProxy()
                }
            }
        )
    }

    var body: some View {
        SettingsPage(
            title: String(localized: "Proxy"),
            subtitle: String(localized: "Control TokenPulse's local proxy routing, session controls, and request logging.")
        ) {
            SettingsCard(
                title: String(localized: "Local proxy"),
                description: String(localized: "The proxy listens on 127.0.0.1 and can forward both Anthropic Messages and OpenAI Responses traffic from one local port.")
            ) {
                Toggle(String(localized: "Enable local proxy"), isOn: proxyEnabledBinding)

                if config.proxyEnabled {
                    Divider()

                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(localized: "Anthropic upstream URL"))
                                .font(.headline)
                            TextField(String(localized: "Anthropic upstream URL"), text: $config.anthropicUpstreamURL)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(localized: "OpenAI upstream URL"))
                                .font(.headline)
                            TextField(String(localized: "OpenAI upstream URL"), text: $config.openAIUpstreamURL)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(localized: "Port"))
                                .font(.headline)
                            TextField(String(localized: "Port"), text: $portText)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    Text(String(
                        format: NSLocalizedString(
                            "proxy.settings.restartRoute",
                            value: "Restart the proxy to apply upstream URL changes. The proxy serves %@ and %@ on the same local port.",
                            comment: ""
                        ),
                        ProxyAPIFlavor.anthropicMessages.supportedRouteDescription,
                        ProxyAPIFlavor.openAIResponses.supportedRouteDescription
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsCard(
                title: String(localized: "System proxy"),
                description: String(localized: "Use the current macOS HTTP or HTTPS proxy settings for outbound upstream requests when no custom proxy is configured.")
            ) {
                Toggle(String(localized: "Use macOS system proxy settings"), isOn: $config.useSystemUpstreamProxy)

                if config.useSystemUpstreamProxy {
                    Text(
                        config.systemUpstreamProxySummary
                            ?? String(localized: "No system HTTP or HTTPS proxy is currently configured.")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsCard(
                title: String(localized: "Custom upstream proxy"),
                description: String(localized: "Override the macOS system proxy with a specific upstream HTTP or HTTPS proxy.")
            ) {
                Toggle(String(localized: "Use custom upstream proxy"), isOn: $config.upstreamHTTPSProxyEnabled)

                if config.upstreamHTTPSProxyEnabled {
                    Divider()

                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(localized: "HTTP proxy URL"))
                                .font(.headline)

                            TextField(
                                String(localized: "http://127.0.0.1:7890"),
                                text: $config.upstreamHTTPProxyURL
                            )
                            .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(localized: "HTTPS proxy URL"))
                                .font(.headline)

                            TextField(
                                String(localized: "http://127.0.0.1:7890"),
                                text: $config.upstreamHTTPSProxyURL
                            )
                            .textFieldStyle(.roundedBorder)
                        }
                    }

                    Text(
                        config.customUpstreamProxyValidationError
                            ?? String(localized: "Each field applies only to its matching traffic, like macOS system proxy settings. Leave a field blank to disable proxying for that traffic. Custom values override the macOS system proxy settings when enabled. Provider refreshes pick this up on the next request; restart the local proxy to apply it to forwarded traffic.")
                    )
                    .font(.caption)
                    .foregroundStyle(config.customUpstreamProxyValidationError == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsCard(
                title: String(localized: "Logging"),
                description: String(localized: "Store proxy metadata and deduplicated request/response payloads locally.")
            ) {
                Toggle(String(localized: "Save event log"), isOn: $config.saveProxyEventLog)

                if config.saveProxyEventLog {
                    Text(String(localized: "Saves proxy metadata and deduplicated payloads to ~/.tokenpulse/proxy_events.sqlite. These records contain your prompts, conversation content, and model outputs. Restart the proxy to apply."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let controller = proxyController, controller.isRunning {
                SettingsCard(
                    title: String(localized: "Live status"),
                    description: String(localized: "Useful when you want to confirm the local proxy is active and forwarding traffic.")
                ) {
                    SettingsStatusRow(
                        label: String(localized: "Port"),
                        value: "\(controller.listeningPort)",
                        tint: .primary,
                        usesMonospacedDigits: true
                    )

                    Divider()

                    SettingsStatusRow(
                        label: String(localized: "Active sessions"),
                        value: "\(controller.proxyStatus.activeSessions)",
                        tint: .primary,
                        usesMonospacedDigits: true
                    )

                    Divider()

                    SettingsStatusRow(
                        label: String(localized: "Requests forwarded"),
                        value: "\(controller.proxyStatus.totalRequestsForwarded)",
                        tint: .primary,
                        usesMonospacedDigits: true
                    )
                }
            }
        } footer: {
            Button {
                restartProxy()
            } label: {
                Label(String(localized: "Restart Proxy"), systemImage: "arrow.clockwise")
            }
            .disabled(!canRestartProxy)
        }
        .onAppear {
            portText = String(config.proxyPort)
        }
        .onChange(of: portText) { _, newValue in
            if let port = Int(newValue.trimmingCharacters(in: .whitespaces)),
               (1...65535).contains(port) {
                config.proxyPort = port
            } else if !newValue.isEmpty {
                portText = String(config.proxyPort)
            }
        }
    }

    private var canRestartProxy: Bool {
        guard let proxyController else { return false }
        return config.proxyEnabled && !proxyController.isRestarting
    }

    private func startProxy() {
        proxyController?.start(
            port: config.proxyPort,
            anthropicUpstreamURL: config.anthropicUpstreamURL,
            openAIUpstreamURL: config.openAIUpstreamURL
        )
    }

    private func stopProxy() {
        proxyController?.stop()
    }

    private func restartProxy() {
        guard canRestartProxy, let proxyController else { return }
        proxyController.restart(
            port: config.proxyPort,
            anthropicUpstreamURL: config.anthropicUpstreamURL,
            openAIUpstreamURL: config.openAIUpstreamURL
        )
    }
}

// MARK: - Shared Views

private struct SettingsPage<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    let content: Content
    let footer: Footer?

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) where Footer == EmptyView {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.footer = nil
    }

    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.system(size: 30, weight: .semibold))

                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    content
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.vertical, 28)
            }
            if let footer {
                Divider()

                HStack {
                    Spacer(minLength: 0)
                    footer
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 14)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let description: String?
    let content: Content

    init(title: String, description: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.description = description
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))

                if let description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct SettingsStatusRow: View {
    let label: String
    let value: String
    var tint: Color
    var usesMonospacedDigits = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.headline)

            Spacer(minLength: 0)

            StatusPill(text: value, tint: tint, usesMonospacedDigits: usesMonospacedDigits)
        }
    }
}

private struct StatusPill: View {
    let text: String
    let tint: Color
    var usesMonospacedDigits = false

    var body: some View {
        Group {
            if usesMonospacedDigits {
                Text(text)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            } else {
                Text(text)
                    .font(.caption.weight(.semibold))
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct SettingsSidebarButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? .primary : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.22) : Color.clear,
                        lineWidth: 1
                    )
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeInOut(duration: 0.14), value: configuration.isPressed)
    }
}
