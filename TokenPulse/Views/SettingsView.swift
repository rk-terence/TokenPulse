import SwiftUI
import ServiceManagement

struct SettingsView: View {
    let manager: ProviderManager

    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("pollInterval") private var pollInterval: Double = ProviderConfig.defaultPollInterval

    var body: some View {
        TabView {
            GeneralTab(launchAtLogin: $launchAtLogin, pollInterval: $pollInterval)
                .tabItem { Label("General", systemImage: "gear") }

            ProvidersTab(manager: manager)
                .tabItem { Label("Providers", systemImage: "server.rack") }
        }
        .padding(20)
        .frame(minWidth: 400, minHeight: 280)
        .onChange(of: launchAtLogin) { _, newValue in
            setLaunchAtLogin(newValue)
        }
        .onChange(of: pollInterval) { _, newValue in
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
        } catch {
            launchAtLogin = !enabled // revert on failure
        }
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @Binding var launchAtLogin: Bool
    @Binding var pollInterval: Double

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)

            Picker("Polling interval", selection: $pollInterval) {
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

    @AppStorage("manualZenMuxCtoken") private var manualCtoken = ""
    @AppStorage("manualZenMuxSessionId") private var manualSessionId = ""
    @AppStorage("manualZenMuxSessionIdSig") private var manualSessionIdSig = ""

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
                    Text("Auto-detect (Chrome)")
                    Spacer()
                    Text(zenMuxAutoStatus)
                        .foregroundStyle(zenMuxAutoConfigured ? .green : .secondary)
                }

                DisclosureGroup("Manual cookie override") {
                    TextField("ctoken", text: $manualCtoken)
                        .textFieldStyle(.roundedBorder)
                    TextField("sessionId", text: $manualSessionId)
                        .textFieldStyle(.roundedBorder)
                    TextField("sessionId.sig", text: $manualSessionIdSig)
                        .textFieldStyle(.roundedBorder)
                    Text("Paste cookie values from browser DevTools if auto-detect fails.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    private var zenMuxAutoConfigured: Bool {
        (try? ChromeCookieService.extractZenMuxCookies()) != nil
    }

    private var zenMuxAutoStatus: String {
        zenMuxAutoConfigured ? "Connected" : "Not found"
    }
}
