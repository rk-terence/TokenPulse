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
    @State private var keepaliveIntervalText: String = ""
    @State private var inactivityTimeoutText: String = ""

    private var proxyEnabledBinding: Binding<Bool> {
        Binding(
            get: { config.proxyEnabled },
            set: { newValue in
                config.proxyEnabled = newValue
                if newValue {
                    proxyController?.start(
                        port: config.proxyPort,
                        upstreamURL: config.proxyUpstreamURL
                    )
                } else {
                    proxyController?.stop()
                }
            }
        )
    }

    var body: some View {
        Form {
            Section(String(localized: "Local Proxy")) {
                Toggle(String(localized: "Enable local proxy"), isOn: proxyEnabledBinding)
                if config.proxyEnabled {
                    TextField(String(localized: "Upstream URL"), text: $config.proxyUpstreamURL)
                        .textFieldStyle(.roundedBorder)
                    TextField(String(localized: "Port"), text: $portText)
                        .textFieldStyle(.roundedBorder)
                    Text(String(localized: "Restart the proxy to apply changes."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Toggle(String(localized: "Enable keepalive"), isOn: $config.keepaliveEnabled)

                    if config.keepaliveEnabled {
                        HStack {
                            Text(String(localized: "Keepalive interval (seconds)"))
                            Spacer()
                            TextField("", text: $keepaliveIntervalText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                        }

                        HStack {
                            Text(String(localized: "Inactivity timeout (seconds)"))
                            Spacer()
                            TextField("", text: $inactivityTimeoutText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                        }

                        Text(String(localized: "Sends periodic cache-warming requests to keep the prompt cache alive during long generations. Each keepalive costs 0.10x base input; avoiding a cache write saves 1.15x."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    Toggle(String(localized: "Save event log"), isOn: $config.saveProxyEventLog)

                    Toggle(String(localized: "Save request payloads"), isOn: $config.saveProxyPayloads)
                    if config.saveProxyPayloads {
                        Text(String(localized: "Saves compressed copies of proxied request bodies to ~/.tokenpulse/proxy_payloads/. These contain your prompts and conversation content. Restart the proxy to apply."))
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
                    LabeledContent(String(localized: "Keepalive loops")) {
                        Text("\(controller.proxyStatus.activeKeepalives)")
                            .monospacedDigit()
                    }
                    LabeledContent(String(localized: "Requests forwarded")) {
                        Text("\(controller.proxyStatus.totalRequestsForwarded)")
                            .monospacedDigit()
                    }
                    LabeledContent(String(localized: "Cache reads")) {
                        Text("\(controller.proxyStatus.cacheReads)")
                            .monospacedDigit()
                    }
                    LabeledContent(String(localized: "Cache writes")) {
                        Text("\(controller.proxyStatus.cacheWrites)")
                            .monospacedDigit()
                    }
                    if controller.proxyStatus.estimatedSavings > 0 {
                        LabeledContent(String(localized: "Est. savings")) {
                            Text(String(format: NSLocalizedString("proxy.savings.format", value: "~%.1fx base input", comment: "Estimated savings in base-input-price multiples"), controller.proxyStatus.estimatedSavings))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            portText = String(config.proxyPort)
            keepaliveIntervalText = String(config.keepaliveIntervalSeconds)
            inactivityTimeoutText = String(config.proxyInactivityTimeoutSeconds)
        }
        .onChange(of: portText) { _, newValue in
            if let port = Int(newValue.trimmingCharacters(in: .whitespaces)),
               (1...65535).contains(port) {
                config.proxyPort = port
            } else {
                portText = String(config.proxyPort)
            }
        }
        .onChange(of: keepaliveIntervalText) { _, newValue in
            if let interval = Int(newValue.trimmingCharacters(in: .whitespaces)),
               (60...300).contains(interval) {
                config.keepaliveIntervalSeconds = interval
            } else {
                keepaliveIntervalText = String(config.keepaliveIntervalSeconds)
            }
        }
        .onChange(of: inactivityTimeoutText) { _, newValue in
            if let timeout = Int(newValue.trimmingCharacters(in: .whitespaces)),
               (300...3600).contains(timeout) {
                config.proxyInactivityTimeoutSeconds = timeout
            } else {
                inactivityTimeoutText = String(config.proxyInactivityTimeoutSeconds)
            }
        }
    }
}
