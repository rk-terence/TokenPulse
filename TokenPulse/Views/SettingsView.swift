import SwiftUI
import ServiceManagement

struct SettingsView: View {
    let manager: ProviderManager
    let config: ConfigService

    /// Tracks the last value we programmatically set to suppress the resulting onChange.
    @State private var launchAtLoginRevertTarget: Bool?
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

    @State private var zenMuxAPIKey = ""
    @State private var zenMuxKeySaved = false
    @State private var zenMuxRemoveError: String?

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
