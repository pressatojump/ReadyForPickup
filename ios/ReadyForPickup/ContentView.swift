import SwiftUI

extension Color {
    static let pickupGreen = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.36, green: 0.82, blue: 0.60, alpha: 1)
            : UIColor(red: 0.08, green: 0.48, blue: 0.33, alpha: 1)
    })
    static let pickupButton = Color(red: 0.08, green: 0.48, blue: 0.33)
}

struct ContentView: View {
    @Bindable var store: WatchStore
    @State private var selectedTab = 0
    @State private var watchPath: [UUID] = []

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $watchPath) {
                WatchesView(store: store)
                    .navigationDestination(for: UUID.self) { WatchDetailView(store: store, watchID: $0) }
            }
            .tabItem { Label("Watches", systemImage: "bag") }.tag(0)

            NavigationStack { ActivityView(store: store) }
                .tabItem { Label("Activity", systemImage: "bell") }.tag(1)

            NavigationStack { SettingsView(store: store) }
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag(2)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPickupWatch)) { notification in
            guard let raw = notification.object as? String, let id = UUID(uuidString: raw), store.watch(id) != nil else { return }
            selectedTab = 0
            watchPath = [id]
        }
    }
}

struct WatchesView: View {
    @Bindable var store: WatchStore
    @State private var addingWatch = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if store.demoMode {
                    Label("DEMO · Sample results, not live inventory", systemImage: "sparkles")
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        .accessibilityIdentifier("demo-banner")
                }
                hero
                if let storageError = store.storageError {
                    NoticeCard(title: "Storage needs attention", message: storageError, symbol: "externaldrive.badge.exclamationmark")
                }
                if store.catalog == nil {
                    NoticeCard(title: "Catalog unavailable", message: InventoryError.catalogUnavailable.localizedDescription, symbol: "exclamationmark.triangle")
                } else if store.watches.isEmpty {
                    emptyState
                } else {
                    HStack {
                        Text("YOUR WATCHES").font(.caption.weight(.bold)).tracking(1.5).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(store.watches.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 14) {
                        ForEach(store.watches) { watch in
                            NavigationLink(value: watch.id) { WatchCard(store: store, watch: watch) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("watch-\(watch.id.uuidString)")
                        }
                    }
                }
                Label("Availability can change before you complete an order.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary).padding(.top, 2)
            }
            .padding(20)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("ReadyForPickup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Image(systemName: "bag").foregroundStyle(Color.pickupGreen).accessibilityHidden(true)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add watch", systemImage: "plus") { addingWatch = true }
                    .accessibilityIdentifier("add-watch")
                    .disabled(store.catalog == nil || store.storageError != nil)
            }
        }
        .refreshable { if !store.demoMode { await store.refreshAll() } }
        .sheet(isPresented: $addingWatch) { WatchEditor(store: store) }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 7) {
                Circle().fill(store.isCoolingDown ? .orange : Color.pickupGreen).frame(width: 7, height: 7)
                Text(store.isCoolingDown ? "TAKING A BREATHER" : "A LITTLE LESS REFRESHING")
                    .font(.caption2.weight(.bold)).tracking(1.2)
            }
            .foregroundStyle(Color.pickupGreen)
            Text("The right pick.\nThe right place.")
                .font(.system(size: 34, weight: .bold, design: .rounded)).tracking(-1)
                .fixedSize(horizontal: false, vertical: true)
            Text("Keep an eye on your next iPhone or Mac.\nWe’ll check the stores that matter to you.")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                stat(value: store.watches.filter(\.isEnabled).count, label: "watching")
                Rectangle().fill(.quaternary).frame(width: 1, height: 30)
                stat(value: store.totalAvailable, label: "stores with stock")
                Spacer(minLength: 0)
                Image(systemName: "bag")
                    .font(.system(size: 47, weight: .light)).foregroundStyle(Color.pickupGreen).accessibilityHidden(true)
            }
            .padding(.top, 4)
            if store.isCoolingDown, let until = store.cooldownUntil {
                Text("Apple request limit reached. Checks resume after \(until.formatted(date: .omitted, time: .shortened)).")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pickupGreen.opacity(0.07), in: RoundedRectangle(cornerRadius: 26))
    }

    private func stat(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)").font(.title2.bold().monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "binoculars").font(.system(size: 38, weight: .light)).foregroundStyle(Color.pickupGreen)
            Text("Your next find starts here").font(.title3.bold())
            Text("Pick a product, choose your configurations,\nand watch an Apple Store nearby.")
                .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Create your first watch") { addingWatch = true }
                .buttonStyle(.borderedProminent).tint(.pickupButton).controlSize(.large)
                .accessibilityIdentifier("create-first-watch")
        }
        .padding(.vertical, 30).frame(maxWidth: .infinity)
    }
}

struct WatchCard: View {
    let store: WatchStore
    let watch: PickupWatch

    private var available: Int { store.snapshots[watch.id]?.results.filter { !$0.configurations.isEmpty }.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: watch.product.symbol)
                    .font(.system(size: 28, weight: .light)).foregroundStyle(Color.pickupGreen)
                    .frame(width: 54, height: 62)
                    .background(Color.pickupGreen.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 6) {
                    Text(watch.product.name).font(.headline)
                    Text(store.catalog?.store(watch.storeID, countryCode: watch.countryCode)?.name ?? watch.storeID)
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("\(watch.configurations.count) configuration\(watch.configurations.count == 1 ? "" : "s") · \(watch.countryCode)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 5)
            }
            Divider()
            HStack {
                status
                Spacer(minLength: 8)
                if let checkedAt = store.snapshots[watch.id]?.checkedAt {
                    Text(checkedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.primary.opacity(0.04)))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var status: some View {
        if !watch.isEnabled {
            Label("Paused", systemImage: "pause.circle").foregroundStyle(.secondary)
        } else if store.checking.contains(watch.id) {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking Apple…") }
        } else if store.errors[watch.id] != nil {
            Label("Check needs attention", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        } else if available > 0 {
            Label("Available at \(available) store\(available == 1 ? "" : "s")", systemImage: "checkmark.circle.fill").foregroundStyle(Color.pickupGreen)
        } else if let snapshot = store.snapshots[watch.id] {
            let quote = snapshot.results.lazy.compactMap(\.pickupQuote).first
            Label(quote ?? "No pickup just yet", systemImage: "clock").foregroundStyle(.secondary)
        } else {
            Label("Ready to check", systemImage: "arrow.clockwise").foregroundStyle(.secondary)
        }
    }
}

struct NoticeCard: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.subheadline.bold())
            Text(message).font(.footnote)
        }
        .foregroundStyle(.orange)
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}
