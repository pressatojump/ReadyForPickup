import SwiftUI

struct WatchEditor: View {
    @Bindable var store: WatchStore
    let existing: PickupWatch?
    @Environment(\.dismiss) private var dismiss
    @State private var countryCode: String
    @State private var productID: String
    @State private var storeID: String
    @State private var selectedSKUs: Set<String>
    @State private var includeNearby: Bool
    @State private var notificationsEnabled: Bool
    @State private var customSKU = ""
    @State private var customName = ""
    @State private var saving = false

    init(store: WatchStore, existing: PickupWatch? = nil) {
        self.store = store
        self.existing = existing
        let country = existing?.countryCode ?? store.defaultCountry
        let product = existing?.productID ?? store.catalog?.products(in: country).first?.id ?? ""
        let models = store.catalog?.country(country)?.products[product] ?? []
        _countryCode = State(initialValue: country)
        _productID = State(initialValue: product)
        _storeID = State(initialValue: existing?.storeID ?? store.catalog?.stores(in: country).first?.id ?? "")
        _selectedSKUs = State(initialValue: Set(existing?.configurations.map(\.sku) ?? models.prefix(1).map(\.sku)))
        _includeNearby = State(initialValue: existing?.includeNearby ?? true)
        _notificationsEnabled = State(initialValue: existing?.notificationsEnabled ?? false)
        if let custom = existing?.configurations.first(where: { configuration in !models.contains { $0.sku == configuration.sku } }) {
            _customSKU = State(initialValue: custom.sku)
            _customName = State(initialValue: custom.name)
            _selectedSKUs = State(initialValue: Set(existing?.configurations.filter { $0.sku != custom.sku }.map(\.sku) ?? []))
        }
    }

    private var configurations: [ProductConfiguration] {
        let models = store.catalog?.country(countryCode)?.products[productID] ?? []
        var selected = models.filter { selectedSKUs.contains($0.sku) }
        let trimmed = customSKU.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !trimmed.isEmpty, !selected.contains(where: { $0.sku == trimmed }) {
            selected.append(ProductConfiguration(sku: trimmed, name: customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? trimmed : customName))
        }
        return selected
    }

    private var canSave: Bool {
        let validSKU = customSKU.isEmpty || customSKU.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/-").contains($0)
        }
        return !storeID.isEmpty && !configurations.isEmpty && configurations.count <= 20 && validSKU && !saving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Make it your kind of pickup.", systemImage: "bag.badge.plus")
                        .font(.headline).foregroundStyle(Color.pickupGreen).padding(.vertical, 8)
                }
                Section("Product & location") {
                    Picker("Country", selection: $countryCode) {
                        ForEach(store.catalog?.countries ?? []) { country in Text(country.name).tag(country.code) }
                    }
                    .accessibilityIdentifier("country-picker")
                    Picker("Product", selection: $productID) {
                        ForEach(store.catalog?.products(in: countryCode) ?? []) { product in Text(product.name).tag(product.id) }
                    }
                    .accessibilityIdentifier("product-picker")
                    NavigationLink {
                        StorePicker(stores: store.catalog?.stores(in: countryCode) ?? [], selected: $storeID)
                    } label: {
                        LabeledContent("Apple Store", value: store.catalog?.store(storeID, countryCode: countryCode)?.name ?? "Choose a store")
                    }
                    .accessibilityIdentifier("store-picker")
                    HStack {
                        Text("Include nearby stores").accessibilityHidden(true)
                        Spacer()
                        Toggle("Include nearby stores", isOn: $includeNearby)
                            .labelsHidden()
                            .accessibilityIdentifier("include-nearby-toggle")
                    }
                }
                Section {
                    NavigationLink {
                        ConfigurationPicker(models: store.catalog?.country(countryCode)?.products[productID] ?? [], selected: $selectedSKUs, maximum: customSKU.isEmpty ? 20 : 19)
                    } label: {
                        LabeledContent("Configurations", value: "\(selectedSKUs.count) selected")
                    }
                    .accessibilityIdentifier("configuration-picker")
                } header: { Text("Your exact pick") } footer: {
                    Text("Choose up to 20 configurations per watch. Smaller searches use fewer requests to Apple.")
                }
                Section {
                    TextField("Part number (optional)", text: $customSKU)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .accessibilityIdentifier("custom-sku")
                    if !customSKU.isEmpty {
                        TextField("Nickname (optional)", text: $customName)
                    }
                } header: { Text("Custom configuration") } footer: {
                    Text("Use an Apple part number for this country’s storefront, such as the SKU shown in its product catalog. Not every custom-built Mac supports pickup.")
                }
                Section {
                    Toggle("Notify when available", isOn: $notificationsEnabled)
                        .accessibilityIdentifier("notify-toggle")
                } header: { Text("A heads-up, not a guarantee") } footer: {
                    Text("Checks run while the app is open. iOS may allow occasional background checks, but continuous background monitoring isn’t possible. Stock is confirmed only when you order from Apple.")
                }
            }
            .navigationTitle(existing == nil ? "New watch" : "Edit watch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save watch") { Task { await save() } }
                        .fontWeight(.semibold).disabled(!canSave)
                        .accessibilityIdentifier("save-watch")
                }
            }
            .onChange(of: countryCode) { _, code in
                productID = store.catalog?.products(in: code).first?.id ?? ""
                storeID = store.catalog?.stores(in: code).first?.id ?? ""
                resetConfigurations()
            }
            .onChange(of: productID) { _, _ in resetConfigurations() }
        }
    }

    private func resetConfigurations() {
        selectedSKUs = Set((store.catalog?.country(countryCode)?.products[productID] ?? []).prefix(1).map(\.sku))
        customSKU = ""
        customName = ""
    }

    private func save() async {
        saving = true
        var enabled = notificationsEnabled
        if enabled { enabled = await NotificationService.shared.requestPermission() }
        var watch = existing ?? PickupWatch(countryCode: countryCode, productID: productID, storeID: storeID, configurations: configurations)
        watch.countryCode = countryCode
        watch.productID = productID
        watch.storeID = storeID
        watch.configurations = configurations
        watch.includeNearby = includeNearby
        watch.notificationsEnabled = enabled
        store.save(watch)
        dismiss()
    }
}

struct StorePicker: View {
    let stores: [AppleStore]
    @Binding var selected: String
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [AppleStore] {
        stores.filter { search.isEmpty || "\($0.name) \($0.address.display)".localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List(filtered) { store in
            Button {
                selected = store.id
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.name).foregroundStyle(.primary)
                        Text(store.address.display).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selected == store.id { Image(systemName: "checkmark").foregroundStyle(Color.pickupGreen) }
                }
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("store-\(store.id)")
            .buttonStyle(.plain)
        }
        .navigationTitle("Apple Stores").searchable(text: $search, prompt: "Store name or city")
        .overlay { if filtered.isEmpty { ContentUnavailableView.search(text: search) } }
    }
}

struct ConfigurationPicker: View {
    let models: [ProductConfiguration]
    @Binding var selected: Set<String>
    let maximum: Int
    @State private var search = ""

    var body: some View {
        List {
            Section {
                ForEach(models.filter { search.isEmpty || "\($0.name) \($0.sku)".localizedCaseInsensitiveContains(search) }) { model in
                    Button {
                        if selected.contains(model.sku) { selected.remove(model.sku) }
                        else if selected.count < maximum { selected.insert(model.sku) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selected.contains(model.sku) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(model.sku) ? Color.pickupGreen : Color.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(model.name).font(.subheadline).foregroundStyle(.primary)
                                Text(model.sku).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("configuration-\(model.sku)")
                    .accessibilityAddTraits(selected.contains(model.sku) ? .isSelected : [])
                    .buttonStyle(.plain)
                }
            } footer: { Text("\(selected.count) of \(maximum) configurations selected") }
        }
        .navigationTitle("Configurations")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Color, storage, or part number")
    }
}
