import SwiftUI
import BackgroundTasks

@main
@MainActor
struct ReadyForPickupApp: App {
    @State private var store: WatchStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = WatchStore()
        _store = State(initialValue: store)
        NotificationService.shared.configure()
        BackgroundRefresh.register(store: store)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .tint(.pickupGreen)
                .task(id: scenePhase) {
                    if scenePhase == .active {
                        await store.monitorWhileActive()
                    } else if scenePhase == .background {
                        BackgroundRefresh.schedule(enabled: store.autoRefresh && !store.demoMode)
                    }
                }
        }
    }
}

@MainActor
enum BackgroundRefresh {
    static let identifier = "com.wehbs.ReadyForPickup.ios.refresh"
    private static var registered = false

    static func register(store: WatchStore) {
        guard !registered else { return }
        registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            let operation = Task { @MainActor in
                schedule(enabled: store.autoRefresh && !store.demoMode)
                if store.autoRefresh && !store.demoMode { await store.refreshAll(onlyIfDue: true) }
                refreshTask.setTaskCompleted(success: !Task.isCancelled)
            }
            refreshTask.expirationHandler = { operation.cancel() }
        }
    }

    static func schedule(enabled: Bool) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        guard enabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
