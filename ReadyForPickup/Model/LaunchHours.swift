//
//  LaunchHours.swift
//  ReadyForPickup
//

import Foundation

/// Settings > Auto-refresh's launch hours: a daily window in which searches
/// refresh as often as Apple's limit allows, for the hours stock drops at a
/// launch. Outside it they follow the Auto-refresh setting, which may be
/// Off. Times are minutes after midnight on the Mac's clock; a window whose
/// end comes before its start runs past midnight. Each day's window opens
/// at its start time and stays open for its length, so on a night the
/// clocks change it keeps its length rather than its end time.
struct LaunchHours: Equatable, Sendable {
    var isEnabled: Bool
    var start: Int
    var end: Int

    // UserDefaults keys, shared with SettingsView's @AppStorage.
    static let enabledKey = "launchHoursEnabled"
    static let startKey = "launchHoursStart"
    static let endKey = "launchHoursEnd"
    static let defaultStart = 8 * 60
    static let defaultEnd = 9 * 60

    /// On 2026-10-21 the app alone, one search every 2 minutes, got exactly
    /// 31 answers from Apple and then 20-30 minutes of HTTP 541 for the
    /// whole network, four times in a row, each time with those 31 in the
    /// last 94 minutes. Launch hours keep any 94 minutes to 30 requests.
    static let requestsAppleAnswers = 31
    static let requestBudget = requestsAppleAnswers - 1
    static let budgetMinutes = 94

    static var stored: LaunchHours {
        let defaults = UserDefaults.standard
        func time(_ key: String, _ fallback: Int) -> Int {
            let stored = defaults.object(forKey: key) as? Int ?? fallback
            return (stored % minutesPerDay + minutesPerDay) % minutesPerDay
        }
        return LaunchHours(isEnabled: defaults.bool(forKey: enabledKey),
                           start: time(startKey, defaultStart),
                           end: time(endKey, defaultEnd))
    }

    private static let minutesPerDay = 24 * 60

    /// The window's length in minutes: 0 (it never opens) when it starts
    /// and ends at the same time.
    var minutes: Int {
        ((end - start) % Self.minutesPerDay + Self.minutesPerDay) % Self.minutesPerDay
    }

    /// On, with a window that opens.
    var isActive: Bool { isEnabled && minutes > 0 }

    /// Minutes between refreshes during launch hours: the fewest, from 2,
    /// that keep any 94 minutes to requestBudget requests, counting
    /// Auto-refresh's (every `autoRefreshMinutes`, 0 = Off) in the part of
    /// those 94 minutes outside the window. A refresh sends
    /// `requestsPerSweep`: one per search, two for a search watching more
    /// than 20 models. One search with Auto-refresh Off: every 2 minutes in
    /// a window of up to an hour, 3 up to an hour and a half, 4 beyond.
    func intervalMinutes(requestsPerSweep: Int, autoRefreshMinutes: Int) -> Int {
        let span = min(minutes, Self.budgetMinutes)
        func fewest(besides around: Int) -> Int? {
            (2..<Self.budgetMinutes).first { interval in
                requestsPerSweep * ((span + interval - 1) / interval) + around <= Self.requestBudget
            }
        }
        let fitting = fewest(besides: requestsAround(requestsPerSweep: requestsPerSweep,
                                                     autoRefreshMinutes: autoRefreshMinutes))
        // Never slower than an Auto-refresh that keeps to the budget by
        // itself: going on at its pace in the window keeps to it too.
        if Self.keepsToBudget(requestsPerSweep: requestsPerSweep, everyMinutes: autoRefreshMinutes) {
            return min(fitting ?? autoRefreshMinutes, autoRefreshMinutes)
        }
        // Auto-refresh alone sends more (Settings warns): keep the window
        // itself to the budget.
        return fitting ?? fewest(besides: 0) ?? Self.budgetMinutes
    }

    /// Whether refreshing every `everyMinutes` (0 = Off) keeps any 94
    /// minutes to requestBudget requests.
    static func keepsToBudget(requestsPerSweep: Int, everyMinutes: Int) -> Bool {
        everyMinutes > 0 && requestsPerSweep * ((budgetMinutes + everyMinutes - 1) / everyMinutes) <= requestBudget
    }

    /// Requests Auto-refresh (every `autoRefreshMinutes`, 0 = Off) sends in
    /// the part of 94 minutes that a window shorter than that leaves.
    func requestsAround(requestsPerSweep: Int, autoRefreshMinutes: Int) -> Int {
        guard autoRefreshMinutes > 0, minutes < Self.budgetMinutes else { return 0 }
        let gap = Self.budgetMinutes - minutes
        return requestsPerSweep * ((gap + autoRefreshMinutes - 1) / autoRefreshMinutes)
    }

    /// The window open at `date`; nil when none is, or launch hours are off.
    func window(containing date: Date, calendar: Calendar = .current) -> DateInterval? {
        guard isActive else { return nil }
        // The window that opened today, or yesterday's if it runs past midnight.
        for days in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: days, to: date),
                  let opens = opening(on: day, calendar: calendar) else { continue }
            let window = DateInterval(start: opens, duration: TimeInterval(minutes * 60))
            if opens <= date, date < window.end { return window }
        }
        return nil
    }

    /// When the window next opens after `date`; nil when launch hours are off.
    func nextOpening(after date: Date, calendar: Calendar = .current) -> Date? {
        guard isActive else { return nil }
        for days in 0...2 {
            if let day = calendar.date(byAdding: .day, value: days, to: date),
               let opens = opening(on: day, calendar: calendar), opens > date {
                return opens
            }
        }
        return nil
    }

    /// When the window opens on `day`: at its start time, or, on a day the
    /// clocks skip that time, at the first time after it.
    private func opening(on day: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: start / 60, minute: start % 60, second: 0, of: day)
    }
}

/// When auto-refresh refreshes: every launch hours interval while the
/// window is open, every Auto-refresh interval (0 = Off) the rest of the day.
struct AutoRefreshSchedule {
    var autoRefreshMinutes: Int
    var launchHours: LaunchHours
    var launchHoursMinutes: Int
    var calendar: Calendar = .current

    /// Minutes between refreshes at `date`; 0 when auto-refresh is off then.
    func intervalMinutes(at date: Date) -> Int {
        launchHours.window(containing: date, calendar: calendar) == nil ? autoRefreshMinutes : launchHoursMinutes
    }

    /// The first moment from `earliest` on when the interval at that moment
    /// has passed since the refresh at `last`. Nil when there's none
    /// (Auto-refresh Off, launch hours off).
    func nextRefresh(after last: Date, notBefore earliest: Date) -> Date? {
        var from = earliest
        // One stretch at one interval (the window, or the time between
        // windows) per pass. A refresh comes by the third: at worst the
        // window closes first and the next one is a day away.
        for _ in 0..<4 {
            let window = launchHours.window(containing: from, calendar: calendar)
            let minutes = window == nil ? autoRefreshMinutes : launchHoursMinutes
            let stretchEnd = window?.end ?? launchHours.nextOpening(after: from, calendar: calendar)
            let due = max(from, last.addingTimeInterval(TimeInterval(minutes * 60)))
            if minutes > 0, stretchEnd.map({ due < $0 }) ?? true { return due }
            guard let stretchEnd else { return nil }
            from = stretchEnd
        }
        return nil
    }
}
