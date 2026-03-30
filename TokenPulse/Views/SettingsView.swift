import SwiftUI
import ServiceManagement

struct SettingsView: View {
    let manager: ProviderManager
    let config: ConfigService

    /// Guards against re-entrant onChange when reverting launchAtLogin on failure.
    @State private var isRevertingLaunchAtLogin = false
    @State private var launchAtLoginError: String?

    var body: some View {
        TabView {
            GeneralTab(config: config, launchAtLoginError: launchAtLoginError)
                .tabItem { Label("General", systemImage: "gear") }

            ProvidersTab(manager: manager)
                .tabItem { Label("Providers", systemImage: "server.rack") }
        }
        .padding(20)
        .frame(minWidth: 400, minHeight: 280)
        .onChange(of: config.launchAtLogin) { _, newValue in
            guard !isRevertingLaunchAtLogin else { return }
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
            isRevertingLaunchAtLogin = true
            config.launchAtLogin = !enabled
            isRevertingLaunchAtLogin = false
            launchAtLoginError = error.localizedDescription
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

    @State private var zenMuxAPIKey = ""
    @State private var zenMuxKeySaved = false

    var body: some View {
        Form {
            Section("Claude") {
                HStack {
                    Text("Credential status")
                    Spacer()
                    Text(claudeStatus)
                        .foregroundStyle(claudeConfigured ? .green : .secondary)
                }
            }

            Section("ZenMux") {
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
                        Button("Remove") { removeZenMuxAPIKey() }
                    }
                    Button("Save") { saveZenMuxAPIKey() }
                        .disabled(zenMuxAPIKey.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var claudeConfigured: Bool {
        ClaudeProvider().isConfigured()
    }

    private var claudeStatus: String {
        claudeConfigured ? "Connected" : "Not found"
    }

    private var zenMuxConfigured: Bool {
        (try? KeychainService.readGenericPassword(service: ZenMuxProvider.keychainService)) != nil
    }

    private func saveZenMuxAPIKey() {
        guard !zenMuxAPIKey.isEmpty,
              let data = zenMuxAPIKey.data(using: .utf8) else { return }
        do {
            try KeychainService.saveGenericPassword(data, service: ZenMuxProvider.keychainService)
            zenMuxKeySaved = true
            zenMuxAPIKey = ""
            manager.requestRefresh()
        } catch {
            zenMuxKeySaved = false
        }
    }

    private func removeZenMuxAPIKey() {
        try? KeychainService.deleteGenericPassword(service: ZenMuxProvider.keychainService)
        zenMuxKeySaved = false
        zenMuxAPIKey = ""
        manager.requestRefresh()
    }
}
