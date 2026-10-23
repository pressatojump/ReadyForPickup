import Foundation
import Observation

@MainActor @Observable
final class WatchStore {
    private struct SavedState: Codable {
        var watches: [PickupWatch] = []
        var snapshots: [UUID: WatchSnapshot] = [:]
        var activity: [ActivityEntry] = []
        var cooldownUntil: Date?
        var lastAttempts: [UUID: Date] = [:]
    }

    let catalog: Catalog?
    var watches: [PickupWatch] = []
    var snapshots: [UUID: WatchSnapshot] = [:]
    var activity: [ActivityEntry] = []
    var errors: [UUID: String] = [:]
    var checking: Set<UUID> = []
    var cooldownUntil: Date?
    var storageError: String?
    var navigationWatchID: UUID?
    var defaultCountry: String {
        didSet { if !demoMode { preferences.set(defaultCountry, forKey: "defaultCountry") } }
    }
    var refreshInterval: TimeInterval {
        didSet { if !demoMode { preferences.set(refreshInterval, forKey: "refreshInterval") } }
    }
    var autoRefresh: Bool {
        didSet { if !demoMode { preferences.set(autoRefresh, forKey: "autoRefresh") } }
    }
    let demoMode: Bool
    private let client = InventoryClient()
    private var isRefreshingAll = false
    private let storageURL: URL?
    private let preferences: UserDefaults
    private var lastAttempts: [UUID: Date] = [:]

    init() {
        demoMode = ProcessInfo.processInfo.arguments.contains("--demo")
        let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        let defaults = testing ? UserDefaults(suiteName: "com.wehbs.ReadyForPickup.ios.ui-testing")! : .standard
        preferences = defaults
        catalog = try? Catalog.load()
        defaultCountry = defaults.string(forKey: "defaultCountry") ?? "US"
        let interval = defaults.double(forKey: "refreshInterval")
        refreshInterval = max(120, interval == 0 ? 300 : interval)
        autoRefresh = defaults.object(forKey: "autoRefresh") as? Bool ?? !testing
        storageURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ReadyForPickup", isDirectory: true).appendingPathComponent(testing ? "ui-testing-watches.json" : "watches.json")
        if demoMode { seedDemo() } else { restore() }
    }

    var totalAvailable: Int {
        watches.filter(\.isEnabled).reduce(0) { count, watch in count + (snapshots[watch.id]?.results.filter { !$0.configurations.isEmpty }.count ?? 0) }
    }

    var isCoolingDown: Bool { (cooldownUntil ?? .distantPast) > Date() }

    func watch(_ id: UUID) -> PickupWatch? { watches.first { $0.id == id } }

    func save(_ watch: PickupWatch) {
        guard let catalog, catalog.country(watch.countryCode) != nil,
              catalog.store(watch.storeID, countryCode: watch.countryCode) != nil,
              !watch.configurations.isEmpty, watch.configurations.count <= 20 else { return }
        if let index = watches.firstIndex(where: { $0.id == watch.id }) {
            if !watches[index].requestsSameInventory(as: watch) {
                snapshots[watch.id] = nil
                errors[watch.id] = nil
                lastAttempts[watch.id] = nil
            }
            watches[index] = watch
        } else { watches.append(watch) }
        persist()
    }

    func delete(_ id: UUID) {
        watches.removeAll { $0.id == id }
        snapshots[id] = nil
        errors[id] = nil
        lastAttempts[id] = nil
        persist()
    }

    func toggle(_ id: UUID) {
        guard let index = watches.firstIndex(where: { $0.id == id }) else { return }
        watches[index].isEnabled.toggle()
        persist()
    }

    func clearActivity() { activity = []; persist() }

    func check(_ id: UUID) async {
        guard !demoMode, !checking.contains(id), !isCoolingDown, let original = watch(id), original.isEnabled,
              let catalog, let country = catalog.country(original.countryCode),
              let store = catalog.store(original.storeID, countryCode: original.countryCode) else { return }
        checking.insert(id)
        lastAttempts[id] = Date()
        defer { checking.remove(id) }
        do {
            let results = try await client.check(original, country: country, store: store)
            try Task.checkCancellation()
            // Edits that don't change what's fetched (alerts on or off, pausing)
            // keep this result; the current alert setting decides below.
            guard let current = watch(id), current.requestsSameInventory(as: original) else { return }
            let previous = snapshots[id]?.fingerprint ?? []
            let snapshot = WatchSnapshot(results: results, checkedAt: Date())
            snapshots[id] = snapshot
            errors[id] = nil
            let newStock = snapshot.fingerprint.subtracting(previous)
            let available = results.filter { !$0.configurations.isEmpty }
            if !newStock.isEmpty {
                activity.insert(ActivityEntry(watchID: id, title: "\(original.product.name) available", detail: available.map(\.storeName).joined(separator: ", "), isAvailable: true), at: 0)
                activity = Array(activity.prefix(100))
                if current.notificationsEnabled { await NotificationService.shared.notify(watch: current, results: results) }
            }
            persist()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            guard watch(id)?.requestsSameInventory(as: original) == true else { return }
            errors[id] = error.localizedDescription
            if let inventoryError = error as? InventoryError, case .throttled = inventoryError {
                cooldownUntil = Date().addingTimeInterval(1800)
            }
            persist()
        }
    }

    func refreshAll(onlyIfDue: Bool = false) async {
        guard !isRefreshingAll else { return }
        isRefreshingAll = true
        defer { isRefreshingAll = false }
        for item in watches where item.isEnabled {
            if Task.isCancelled || isCoolingDown { break }
            if onlyIfDue, let attemptedAt = lastAttempts[item.id], Date().timeIntervalSince(attemptedAt) < refreshInterval { continue }
            if onlyIfDue, let checkedAt = snapshots[item.id]?.checkedAt, Date().timeIntervalSince(checkedAt) < refreshInterval { continue }
            await check(item.id)
        }
    }

    func monitorWhileActive() async {
        while !Task.isCancelled {
            if let until = cooldownUntil, until <= Date() {
                cooldownUntil = nil
                persist()
            }
            if autoRefresh && !demoMode { await refreshAll(onlyIfDue: true) }
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
    }

    private func restore() {
        guard let storageURL, FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let saved = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: storageURL))
            watches = saved.watches
            snapshots = saved.snapshots
            activity = Array(saved.activity.prefix(100))
            cooldownUntil = saved.cooldownUntil
            lastAttempts = saved.lastAttempts
        } catch { storageError = "Saved watches could not be read. The original file has been left untouched." }
    }

    private func persist() {
        guard !demoMode, storageError == nil, let storageURL else { return }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(SavedState(watches: watches, snapshots: snapshots, activity: activity, cooldownUntil: cooldownUntil, lastAttempts: lastAttempts))
            try data.write(to: storageURL, options: .atomic)
        } catch { storageError = "Your latest changes could not be saved: \(error.localizedDescription)" }
    }

    private func seedDemo() {
        guard let catalog, let country = catalog.country("US"),
              let product = catalog.products(in: "US").first,
              let models = country.products[product.id], let model = models.first,
              let store = catalog.stores(in: "US").first(where: { $0.name.contains("Fifth Avenue") }) ?? catalog.stores(in: "US").first else { return }
        let watch = PickupWatch(countryCode: "US", productID: product.id, storeID: store.id, configurations: Array(models.prefix(2)))
        watches = [watch]
        snapshots[watch.id] = WatchSnapshot(results: [PickupResult(storeID: store.id, storeName: store.name, city: store.address.city, configurations: [model])], checkedAt: Date())
        activity = [ActivityEntry(watchID: watch.id, title: "\(product.name) available", detail: store.name, isAvailable: true)]
    }
}
