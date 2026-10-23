//
//  SettingsView.swift
//  ReadyForPickup
//
//  Created by Worth Baker on 11/9/21.
//

import SwiftUI

/// Per-search settings now live in the main window's inspector
/// (2.0-style layout). This scene keeps only app-wide preferences, in
/// tabs short enough to show every caption in full on a 900 pt screen.
struct SettingsView: View {
    @EnvironmentObject var model: ViewModel
    @EnvironmentObject var updater: UpdaterViewModel
    @AppStorage("preferredCountry") private var preferredCountry = "US"
    @AppStorage("preferredUpdateInterval") private var preferredUpdateInterval: Int = 5
    // Read by LaunchHours.stored.
    @AppStorage(LaunchHours.enabledKey) private var launchHoursEnabled = false
    @AppStorage(LaunchHours.startKey) private var launchHoursStart = LaunchHours.defaultStart
    @AppStorage(LaunchHours.endKey) private var launchHoursEnd = LaunchHours.defaultEnd
    // Read by PushoverSettings.highPriorityAlerts.
    @AppStorage("pushoverHighPriority") private var pushoverHighPriority = false
    @State private var pushoverUserKey: String = PushoverSettings.userKey
    @State private var pushoverApiToken: String = PushoverSettings.apiToken
    @State private var isSendingTest = false

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            notifications
                .tabItem { Label("Notifications", systemImage: "bell") }
            updates
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .task { await model.refreshMacNotificationStatus() }
        // Picks up a change made in System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshMacNotificationStatus() }
        }
    }

    private var general: some View {
        Form {
            Text("Searches, countries, products, stores and notifications are configured per search in the main window's right-hand inspector.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Stored under the old app-wide setting's key (see DefaultsVendor).
            Picker("Default country", selection: $preferredCountry) {
                ForEach(Country.all) { country in
                    Text(country.name).tag(country.code)
                }
            }
            Text("New searches start in this country, at a store there. Each search's own country is set in the inspector.")
                .caption()

            Picker("Auto-refresh every", selection: $preferredUpdateInterval) {
                Text("Off").tag(0)
                Text("2 minutes").tag(2)
                Text("5 minutes").tag(5)
                Text("10 minutes").tag(10)
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
            }
            .onChange(of: preferredUpdateInterval) { newValue in
                // Takes effect immediately; no relaunch needed. The
                // scheduler doubles this wait (up to 60 min) while
                // Apple is throttling requests.
                model.restartAutoRefresh(withMinutes: newValue)
            }
            Text("Searches refresh automatically, one after another, while the app is running - even with its window closed. To re-check now, use the toolbar refresh button or File > Refresh Selected Search (Cmd-R), or File > Refresh All Searches (Shift-Cmd-R); either also resets the schedule. If Apple starts refusing requests, the app waits longer between refreshes, up to an hour, until Apple answers again.")
                .caption()
            // On 2026-10-21 the app alone, every 2 minutes, got 31 answers
            // and then 20-30 minutes of refusals, four times in a row; it was
            // never refused at 12 an hour.
            if requestsPerHour >= 20 {
                Text("That's about \(requestsPerHour) requests an hour, one per search per refresh. Apple answers about 31 in an hour and a half, then refuses every device on your network for up to half an hour, so the app will miss stretches. Under 20 an hour, such as one search every 5 minutes, it keeps answering.")
                    .caption(.orange)
            }

            Toggle("Check more often during launch hours", isOn: $launchHoursEnabled)
                .onChange(of: launchHoursSetting) { _ in
                    // Takes effect immediately, like the interval above.
                    model.restartAutoRefresh()
                }
            Group {
                DatePicker("From", selection: timeOfDay($launchHoursStart), displayedComponents: .hourAndMinute)
                DatePicker("To", selection: timeOfDay($launchHoursEnd), displayedComponents: .hourAndMinute)
            }
            .environment(\.timeZone, Self.utc)
            .disabled(launchHoursEnabled == false)
            Text(launchHoursCaption)
                // Always 7 lines while on, the longest caption at 420 pt, so
                // Settings keeps its height as From or To change and nothing
                // moves under the pointer.
                .lineLimit(7, reservesSpace: launchHoursEnabled)
                .caption()
            if launchHoursEnabled, let warning = launchHoursWarning {
                Text(warning)
                    .caption(.orange)
            }
        }
        .settingsTab()
    }

    private var notifications: some View {
        Form {
            VStack(alignment: .leading, spacing: 8) {
                Text("Mac notifications").font(.headline)
                // On only when macOS allows them too; turning it on asks
                // macOS, or opens System Settings if the user said no there.
                Toggle("Enable Mac notifications", isOn: Binding(
                    get: { model.macNotificationsActive },
                    set: { on in Task { await model.setMacNotificationsEnabled(on) } }))
                Text(macNotificationsCaption)
                    .caption()
                HStack {
                    if model.macNotificationsEnabled, model.macNotificationStatus == .denied {
                        Button("Open Notification Settings…") { NotificationManager.openSystemSettings() }
                    }
                    Button("Send test notification") {
                        Task { await model.sendTestMacNotification() }
                    }
                    .disabled(model.macNotificationsActive == false)
                }
                if let feedback = model.macNotificationFeedback {
                    Text(feedback).caption(.primary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Pushover (push to your phone)").font(.headline)
                Text("Pushover requires your own account and app token: install Pushover on your iPhone, register an application at pushover.net/apps, then paste your User Key and that app's API Token below. Keys are stored in your Mac's Keychain, never in the app.")
                    .caption()

                Toggle("Enable Pushover notifications", isOn: Binding(
                    get: { model.pushoverEnabled },
                    set: { model.setPushoverEnabled($0) }))

                SecureField("Pushover User Key", text: $pushoverUserKey)
                    .onChange(of: pushoverUserKey) { PushoverSettings.userKey = $0; model.refreshPushoverState() }
                SecureField("Application API Token", text: $pushoverApiToken)
                    .onChange(of: pushoverApiToken) { PushoverSettings.apiToken = $0; model.refreshPushoverState() }

                Toggle("Send stock alerts at high priority", isOn: $pushoverHighPriority)
                Text("High-priority alerts get through your Pushover quiet hours, always with sound, and show in red. Test notifications stay at normal priority.")
                    .caption()

                HStack {
                    Button("Send test notification") {
                        isSendingTest = true
                        Task { await model.sendTestPushover(); isSendingTest = false }
                    }
                    .disabled(isSendingTest || pushoverUserKey.isEmpty || pushoverApiToken.isEmpty)
                    if isSendingTest { ProgressView().controlSize(.small) }
                }
                if pushoverUserKey.isEmpty || pushoverApiToken.isEmpty {
                    Text("Enter both keys to enable the test button. With invalid keys, Pushover's own error is shown here.")
                        .caption()
                }
                if let feedback = model.pushoverFeedback {
                    Text(feedback)
                        .caption(feedback.hasPrefix("Test sent") ? .green : .red)
                }
            }
        }
        .settingsTab()
    }

    private var updates: some View {
        Form {
            VStack(alignment: .leading, spacing: 8) {
                Text("Software Updates").font(.headline)
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                CheckForUpdatesView(updater: updater)
                Text("Updates are downloaded from GitHub via Sparkle. Version 0.3.2 and earlier can't install updates: download 0.3.3 or later once from the Releases page.")
                    .caption()
            }
        }
        .settingsTab()
    }

    /// Auto-refresh's pickup requests an hour: one per search per refresh
    /// (two for a search watching more than 20 models).
    private var requestsPerHour: Int {
        preferredUpdateInterval > 0 ? model.requestsPerSweep * 60 / preferredUpdateInterval : 0
    }

    private var launchHoursSetting: LaunchHours {
        LaunchHours(isEnabled: launchHoursEnabled, start: launchHoursStart, end: launchHoursEnd)
    }

    private var launchHoursCaption: String {
        let hours = launchHoursSetting
        guard hours.isEnabled else {
            return "Turn this on to refresh searches more often in a daily window, such as the hours stock drops at a launch."
        }
        guard hours.minutes > 0 else {
            return "From and To are the same time, so launch hours never start."
        }
        let requests = model.requestsPerSweep
        let interval = hours.intervalMinutes(requestsPerSweep: requests, autoRefreshMinutes: preferredUpdateInterval)
        let end = time(hours.end) + (hours.end < hours.start ? " the next day" : "")
        var caption = "Every day from \(time(hours.start)) to \(end), searches refresh every \(interval) minutes: as often as keeps the app to \(LaunchHours.requestBudget) requests in any hour and a half (Apple answers about \(LaunchHours.requestsAppleAnswers)), counting Auto-refresh's outside the window. At other times they follow Auto-refresh above, which can be Off."
        // What would make launch hours refresh more often.
        var hour = hours
        hour.end = (hours.start + 60) % (24 * 60)
        let withoutAutoRefresh = hours.intervalMinutes(requestsPerSweep: requests, autoRefreshMinutes: 0)
        let hourLong = hour.intervalMinutes(requestsPerSweep: requests, autoRefreshMinutes: preferredUpdateInterval)
        if preferredUpdateInterval > 0, withoutAutoRefresh < interval {
            caption += " With Auto-refresh Off they'd refresh every \(withoutAutoRefresh) minutes."
        } else if hours.minutes > 60, hourLong < interval {
            caption += " An hour-long window would refresh every \(hourLong) minutes."
        }
        return caption
    }

    /// Shown when Auto-refresh by itself sends more than requestBudget in
    /// an hour and a half: launch hours can't keep the app under it then.
    private var launchHoursWarning: String? {
        guard launchHoursSetting.minutes > 0, preferredUpdateInterval > 0,
              LaunchHours.keepsToBudget(requestsPerSweep: model.requestsPerSweep, everyMinutes: preferredUpdateInterval) == false
        else { return nil }
        return "Auto-refresh above sends more than Apple answers, so the app may be refused during launch hours too. Set it to refresh less often, or Off."
    }

    // Launch hours' times are minutes after midnight on the Mac's clock,
    // not dates. The pickers show them as that time on 2001-01-01 in UTC,
    // which never skips or repeats an hour, so any time can be picked and
    // reads back as picked.
    private static let utc = TimeZone(secondsFromGMT: 0)!
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }()

    private func timeOfDay(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(get: { Date(timeIntervalSinceReferenceDate: TimeInterval(minutes.wrappedValue * 60)) },
                set: { date in
                    let parts = Self.utcCalendar.dateComponents([.hour, .minute], from: date)
                    minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                })
    }

    private func time(_ minutes: Int) -> String {
        Date(timeIntervalSinceReferenceDate: TimeInterval(minutes * 60))
            .formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: Self.utc))
    }

    private var macNotificationsCaption: String {
        if model.macNotificationsActive {
            return "On. Banners, sounds and Focus follow System Settings > Notifications > ReadyForPickup. Each search can also turn them off in the inspector."
        }
        if model.macNotificationsEnabled == false {
            return "Off: ReadyForPickup sends no Mac notifications."
        }
        switch model.macNotificationStatus {
        case .denied:
            return "macOS has notifications turned off for ReadyForPickup, and only System Settings can turn them back on: turn on Allow notifications there, then come back."
        default:
            return "Turn this on and macOS will ask whether ReadyForPickup may send notifications."
        }
    }
}

private extension View {
    /// A setting's caption, shown in full. Without fixedSize, Settings made
    /// its window too short and cut captions off after one line. It takes
    /// the column's whole width: the Form centers its columns on their
    /// widest row, so a caption's longest line changing as its text did
    /// moved every control sideways.
    func caption(_ color: Color = .secondary) -> some View {
        font(.caption).foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One tab of Settings: 420 pt wide and as tall as its settings. The
    /// window grows and shrinks from its bottom edge to fit.
    func settingsTab() -> some View {
        padding(20).frame(width: 420)
    }
}
