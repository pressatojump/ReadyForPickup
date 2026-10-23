import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Bindable var store: WatchStore
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @Environment(\.scenePhase) private var scenePhase

    private var notificationLabel: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: return "Allowed"
        case .denied: return "Off in iOS Settings"
        default: return "Not requested"
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "bag").font(.largeTitle).foregroundStyle(Color.pickupGreen)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A better way to keep watch.").font(.headline)
                        Text("ReadyForPickup · iOS").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }
            Section("New watches") {
                Picker("Default country", selection: $store.defaultCountry) {
                    ForEach(store.catalog?.countries ?? []) { Text($0.name).tag($0.code) }
                }
            }
            Section {
                Toggle("Automatic checks", isOn: $store.autoRefresh).accessibilityIdentifier("auto-refresh-toggle")
                Picker("While app is open", selection: $store.refreshInterval) {
                    Text("Every 2 minutes").tag(TimeInterval(120))
                    Text("Every 5 minutes").tag(TimeInterval(300))
                    Text("Every 10 minutes").tag(TimeInterval(600))
                    Text("Every 15 minutes").tag(TimeInterval(900))
                    Text("Every 30 minutes").tag(TimeInterval(1800))
                }
                .disabled(!store.autoRefresh)
            } header: { Text("Refresh") } footer: {
                Text("Automatic checks follow this interval only while the app is active. Background App Refresh is opportunistic: iOS decides when it can run, and can stop it entirely. Force-quitting the app stops background checks. Apple request limits pause all checks for 30 minutes.")
            }
            Section {
                LabeledContent("Notification permission", value: notificationLabel)
                if notificationStatus == .notDetermined {
                    Button("Allow notifications") {
                        Task {
                            _ = await NotificationService.shared.requestPermission()
                            notificationStatus = await NotificationService.shared.status()
                        }
                    }
                }
                Button("Open iOS Settings", systemImage: "arrow.up.right.square") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            } header: { Text("Notifications") } footer: {
                Text("Enable alerts for each watch in its edit screen. Alerts need a successful inventory check; this app does not include a continuously running server or guaranteed push monitoring.")
            }
            Section("About") {
                LabeledContent("Version", value: version)
                LabeledContent("Countries", value: "\(store.catalog?.countries.count ?? 0)")
                Link("Original macOS project", destination: URL(string: "https://github.com/pressatojump/ReadyForPickup")!)
                Link("Source & GPL-3.0 license", destination: URL(string: "https://github.com/pressatojump/ReadyForPickup/blob/main/LICENSE.md")!)
                Text("An independent iOS adaptation. Not affiliated with or endorsed by Apple. Product and store data are bundled from the original project; they are not a promise of current stock.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .task(id: scenePhase) { notificationStatus = await NotificationService.shared.status() }
        .onChange(of: store.autoRefresh) { _, enabled in BackgroundRefresh.schedule(enabled: enabled && !store.demoMode) }
    }
}
