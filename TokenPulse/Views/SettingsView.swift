import SwiftUI
import ServiceManagement

struct SettingsView: View {
    let manager: ProviderManager
    let config: ConfigService
    var proxyController: LocalProxyController?

    /// Tracks the last value we programmatically set to suppress the resulting onChange.
    @State private var launchAtLoginRevertTarget: Bool?
    @State private var launchAtLoginError: String?

    var body: some View {
        TabView {
            GeneralTab(config: config, launchAtLoginError: launchAtLoginError)
                .tabItem { Label("General", systemImage: "gear") }

            ProvidersTab(manager: manager, config: config)
                .tabItem { Label("Providers", systemImage: "server.rack") }

            ProxyTab(config: config, proxyController: proxyController)
                .tabItem { Label(String(localized: "Proxy"), systemImage: "network") }
        }
        .padding(20)
        .frame(minWidth: 400, minHeight: 280)
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
        Form {
            Toggle("Launch at login", isOn: $config.launchAtLogin)
            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Picker("Polling interval", selection: $config.pollInterval) {
                Text("60 seconds").tag(60.0)
                Text("2 minutes").tag(120.0)
                Text("5 minutes").tag(300.0)
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
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
        Form {
            Section("Claude") {
                Toggle(String(localized: "Enable Claude"), isOn: claudeEnabledBinding)

                if config.isProviderEnabled("claude") {
                    HStack {
                        Text("Credential status")
                        Spacer()
                        Text(claudeStatus)
                            .foregroundStyle(claudeConfigured ? .green : .secondary)
                    }
                }
            }

            Section("Codex") {
                Toggle(String(localized: "Enable Codex"), isOn: codexEnabledBinding)

                if config.isProviderEnabled("codex") {
                    HStack {
                        Text("Login status")
                        Spacer()
                        Text(codexStatus.description)
                            .foregroundStyle(codexStatus.isConfigured ? .green : .secondary)
                    }

                    Text(codexHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("ZenMux") {
                Toggle(String(localized: "Enable ZenMux"), isOn: zenMuxEnabledBinding)

                if config.isProviderEnabled("zenmux") {
                    HStack {
                        Text("API key status")
                        Spacer()
                        Text(zenMuxConfigured ? "Configured" : "Not set")
                            .foregroundStyle(zenMuxConfigured ? .green : .secondary)
                    }

                    SecureField("Management API Key", text: $zenMuxAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveZenMuxAPIKey() }

                    HStack {
                        Text("Get your key from the ZenMux dashboard.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if zenMuxKeySaved {
                            Text("Saved")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        if zenMuxConfigured {
                            Button(String(localized: "Remove")) { removeZenMuxAPIKey() }
                        }
                        Button("Save") { saveZenMuxAPIKey() }
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
        .formStyle(.grouped)
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
        claudeConfigured ? "Connected" : "Not found"
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
        VStack(spacing: 0) {
            Form {
                Section(String(localized: "Local Proxy")) {
                    Toggle(String(localized: "Enable local proxy"), isOn: proxyEnabledBinding)
                    if config.proxyEnabled {
                        TextField(String(localized: "Anthropic upstream URL"), text: $config.anthropicUpstreamURL)
                            .textFieldStyle(.roundedBorder)

                        TextField(String(localized: "OpenAI upstream URL"), text: $config.openAIUpstreamURL)
                            .textFieldStyle(.roundedBorder)

                        TextField(String(localized: "Port"), text: $portText)
                            .textFieldStyle(.roundedBorder)
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

                        Divider()

                        Toggle(String(localized: "Enable keepalive controls"), isOn: $config.keepaliveEnabled)
                        Text(String(localized: "Shows per-session keepalive controls in the activity popover. Keepalive applies only to Anthropic Messages traffic."))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        Toggle(String(localized: "Save event log"), isOn: $config.saveProxyEventLog)
                        if config.saveProxyEventLog {
                            Text(String(localized: "Saves proxy metadata to ~/.tokenpulse/proxy_events.sqlite (proxy_requests, proxy_keepalives, proxy_lifecycle tables), including request timing, status, cache metrics, and upstream request IDs. Prompt and response content are excluded unless Capture all content is enabled. Restart the proxy to apply."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Toggle(String(localized: "Capture all content"), isOn: $config.saveProxyPayloads)
                        if config.saveProxyPayloads {
                            Text(String(localized: "Saves full proxy request and response headers and bodies to the proxy_request_content table in ~/.tokenpulse/proxy_events.sqlite, linked to per-request rows. These records contain your prompts, conversation content, and model outputs. Restart the proxy to apply."))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if let controller = proxyController, controller.isRunning {
                    Section(String(localized: "Status")) {
                        LabeledContent(String(localized: "Port")) {
                            Text("\(controller.listeningPort)")
                                .monospacedDigit()
                        }
                        LabeledContent(String(localized: "Active sessions")) {
                            Text("\(controller.proxyStatus.activeSessions)")
                                .monospacedDigit()
                        }
                        LabeledContent(String(localized: "Requests forwarded")) {
                            Text("\(controller.proxyStatus.totalRequestsForwarded)")
                                .monospacedDigit()
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(alignment: .center) {
                Text(String(localized: "Use restart after changing proxy settings that apply only on startup."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    restartProxy()
                } label: {
                    Label(String(localized: "Restart Proxy"), systemImage: "arrow.clockwise")
                }
                .disabled(!canRestartProxy)
            }
            .padding(.top, 12)
        }
        .onAppear {
            portText = String(config.proxyPort)
        }
        .onChange(of: portText) { _, newValue in
            if let port = Int(newValue.trimmingCharacters(in: .whitespaces)),
               (1...65535).contains(port) {
                config.proxyPort = port
            } else {
                portText = String(config.proxyPort)
            }
        }
    }

    private var canRestartProxy: Bool {
        config.proxyEnabled && proxyController != nil
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
        guard canRestartProxy else { return }
        stopProxy()
        startProxy()
    }
}
