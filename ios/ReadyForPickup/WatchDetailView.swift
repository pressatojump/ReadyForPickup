import SwiftUI

struct WatchDetailView: View {
    @Bindable var store: WatchStore
    let watchID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if let watch = store.watch(watchID) {
                detail(watch)
            } else {
                ContentUnavailableView("Watch removed", systemImage: "bag")
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Your watch")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Edit watch", systemImage: "pencil") { editing = true }
                    Button(store.watch(watchID)?.isEnabled == true ? "Pause watch" : "Resume watch", systemImage: "pause.circle") { store.toggle(watchID) }
                    Button("Delete watch", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityIdentifier("watch-menu")
            }
        }
        .sheet(isPresented: $editing) {
            if let watch = store.watch(watchID) { WatchEditor(store: store, existing: watch) }
        }
        .confirmationDialog("Delete this watch?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete watch", role: .destructive) { store.delete(watchID); dismiss() }
        } message: { Text("You can create another watch at any time.") }
    }

    private func detail(_ watch: PickupWatch) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if store.demoMode {
                    Label("Sample results · Not live availability", systemImage: "sparkles")
                        .font(.caption.bold()).foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: watch.product.symbol)
                        .font(.system(size: 54, weight: .ultraLight)).foregroundStyle(Color.pickupGreen).padding(.vertical, 8)
                    Text(watch.product.name).font(.largeTitle.bold())
                    Label(store.catalog?.store(watch.storeID, countryCode: watch.countryCode)?.name ?? watch.storeID, systemImage: "mappin.and.ellipse")
                        .foregroundStyle(.secondary)
                    Text("\(watch.configurations.count) configuration\(watch.configurations.count == 1 ? "" : "s") · \(watch.includeNearby ? "Nearby stores included" : "This store only")")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !watch.isEnabled { Label("This watch is paused", systemImage: "pause.circle").font(.subheadline).foregroundStyle(.orange) }
                    Button {
                        Task { await store.check(watchID) }
                    } label: {
                        HStack {
                            if store.checking.contains(watchID) { ProgressView().tint(.white) }
                            else { Image(systemName: "arrow.clockwise") }
                            Text(store.checking.contains(watchID) ? "Checking…" : "Check availability")
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent).tint(.pickupButton).controlSize(.large)
                    .disabled(!watch.isEnabled || store.checking.contains(watchID) || store.isCoolingDown || store.demoMode)
                    .accessibilityIdentifier("check-availability")
                }
                if let message = store.errors[watchID] {
                    NoticeCard(title: "Couldn’t update availability", message: message, symbol: "wifi.exclamationmark")
                }
                if store.isCoolingDown, let until = store.cooldownUntil {
                    NoticeCard(title: "Checks temporarily paused", message: "Apple limited requests. Try again after \(until.formatted(date: .omitted, time: .shortened)).", symbol: "clock")
                }
                if let snapshot = store.snapshots[watchID] {
                    HStack {
                        Text("STORE AVAILABILITY").font(.caption.bold()).tracking(1.1)
                        Spacer()
                        Text(snapshot.checkedAt, style: .time).font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                    if Date().timeIntervalSince(snapshot.checkedAt) > store.refreshInterval * 2 || store.errors[watchID] != nil {
                        Text("These are previous results, not a fresh stock check.").font(.footnote).foregroundStyle(.orange)
                    }
                    ForEach(snapshot.results) { result in resultCard(result, watch: watch) }
                } else {
                    ContentUnavailableView {
                        Label("Let’s take a look", systemImage: "binoculars")
                    } description: {
                        Text("Check availability to see which stores have your exact pick. An unavailable service is never treated as out of stock.")
                    }
                    .padding(.vertical, 12)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("WATCHING THESE").font(.caption.bold()).tracking(1.1).foregroundStyle(.secondary)
                    ForEach(watch.configurations) { configuration in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(configuration.name).font(.subheadline)
                            Text(configuration.sku).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                Text("No reservation is made by this app. Open Apple to confirm availability and complete your purchase.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .refreshable { if !store.demoMode { await store.check(watchID) } }
    }

    private func resultCard(_ result: PickupResult, watch: PickupWatch) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(result.storeName).font(.headline)
                    Text(result.city).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: result.configurations.isEmpty ? "clock" : "checkmark.circle.fill")
                    .foregroundStyle(result.configurations.isEmpty ? Color.secondary : Color.pickupGreen)
            }
            if result.configurations.isEmpty {
                Text(result.pickupQuote ?? "No selected configurations available for pickup.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(result.configurations) { configuration in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(configuration.name).font(.subheadline)
                        if let url = store.catalog?.country(watch.countryCode)?.url(path: "shop/product/\(configuration.sku)") {
                            Link(destination: url) { Label("View at Apple", systemImage: "arrow.up.right") }
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct ActivityView: View {
    @Bindable var store: WatchStore
    @State private var confirmingClear = false

    var body: some View {
        List {
            if store.demoMode {
                Section { Label("Demo activity · Sample data", systemImage: "sparkles").foregroundStyle(.orange) }
            }
            if store.activity.isEmpty {
                ContentUnavailableView("Quiet for now", systemImage: "bell.badge", description: Text("New pickup availability appears here after a successful check. Failed checks never create stock alerts."))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(store.activity) { entry in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.pickupGreen).font(.title2)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.title).font(.headline)
                            Text(entry.detail).font(.subheadline).foregroundStyle(.secondary)
                            Text(entry.date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            if !store.activity.isEmpty {
                Button("Clear") { confirmingClear = true }.accessibilityIdentifier("clear-activity")
            }
        }
        .confirmationDialog("Clear availability history?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear activity", role: .destructive) { store.clearActivity() }
        }
    }
}
