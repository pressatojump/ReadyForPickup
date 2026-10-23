import Foundation

struct PickupWatch: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var countryCode: String
    var productID: String
    var storeID: String
    var configurations: [ProductConfiguration]
    var includeNearby = true
    var notificationsEnabled = false
    var isEnabled = true
    var createdAt = Date()
    var product: ProductFamily { ProductFamily.named(productID) }

    func requestsSameInventory(as other: PickupWatch) -> Bool {
        countryCode == other.countryCode && productID == other.productID
            && storeID == other.storeID && configurations == other.configurations
            && includeNearby == other.includeNearby
    }
}

struct PickupResult: Codable, Identifiable, Sendable {
    let storeID: String
    let storeName: String
    let city: String
    let configurations: [ProductConfiguration]
    var pickupQuote: String? = nil
    var id: String { storeID }
}

struct WatchSnapshot: Codable, Sendable {
    var results: [PickupResult]
    var checkedAt: Date
    var fingerprint: Set<String> {
        Set(results.flatMap { result in result.configurations.map { "\(result.storeID):\($0.sku)" } })
    }
}

struct ActivityEntry: Codable, Identifiable, Sendable {
    var id = UUID()
    var watchID: UUID
    var title: String
    var detail: String
    var date = Date()
    var isAvailable: Bool
}

enum InventoryError: LocalizedError {
    case catalogUnavailable
    case invalidWatch
    case throttled
    case unavailable(Int)
    case invalidResponse
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .catalogUnavailable: return "The bundled product or store catalog could not be loaded."
        case .invalidWatch: return "Choose a supported country, store, and at least one configuration."
        case .throttled: return "Apple is limiting requests. Checks are paused for 30 minutes to protect your access."
        case .unavailable(let status): return "Apple’s pickup service is unavailable (HTTP \(status)). Try again later."
        case .invalidResponse: return "Apple returned an unexpected response. Your previous results have been kept."
        case .rejected(let message): return "Apple could not check these configurations: \(message)"
        }
    }
}

actor InventoryClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 45
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func check(_ watch: PickupWatch, country: StoreCountry, store: AppleStore) async throws -> [PickupResult] {
        guard !watch.configurations.isEmpty, watch.configurations.count <= 20,
              let endpoint = country.url(path: "shop/retail/pickup-message"),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw InventoryError.invalidWatch
        }
        let location = store.address.postalCode.flatMap { $0.isEmpty ? nil : $0 } ?? store.address.city
        components.queryItems = [URLQueryItem(name: "pl", value: "true"), URLQueryItem(name: "location", value: location)]
            + watch.configurations.enumerated().map { index, model in URLQueryItem(name: "parts.\(index)", value: model.sku) }
        guard let url = components.url else { throw InventoryError.invalidWatch }
        var request = URLRequest(url: url)
        request.setValue(country.url(path: "shop/")?.absoluteString, forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw InventoryError.invalidResponse }
        if [429, 541].contains(response.statusCode) { throw InventoryError.throttled }
        guard response.statusCode == 200 else { throw InventoryError.unavailable(response.statusCode) }
        return try Self.parse(data, watch: watch)
    }

    static func parse(_ data: Data, watch: PickupWatch) throws -> [PickupResult] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["body"] as? [String: Any] else { throw InventoryError.invalidResponse }
        let legacy = (body["content"] as? [String: Any])?["pickupMessage"] as? [String: Any]
        guard let stores = body["stores"] as? [[String: Any]] ?? legacy?["stores"] as? [[String: Any]], !stores.isEmpty else {
            if let message = body["errorMessage"] as? String { throw InventoryError.rejected(message) }
            throw InventoryError.invalidResponse
        }
        var results: [PickupResult] = []
        for entry in stores {
            // Like the Mac app, skip a store entry that lacks these instead of
            // failing the whole check.
            guard let storeID = entry["storeNumber"] as? String,
                  let name = entry["storeName"] as? String,
                  let parts = entry["partsAvailability"] as? [String: [String: Any]] else { continue }
            guard watch.includeNearby || storeID == watch.storeID else { continue }
            // A configuration missing from a store's reply, or with any status
            // but "available", isn't available there.
            let available = watch.configurations.filter { model in
                let part = parts[model.sku] ?? parts.values.first { $0["partNumber"] as? String == model.sku }
                return part?["partNumber"] as? String == model.sku && part?["pickupDisplay"] as? String == "available"
            }
            let quote: String? = watch.configurations.lazy.compactMap { model -> String? in
                guard let part = parts[model.sku] ?? parts.values.first(where: { $0["partNumber"] as? String == model.sku }),
                      part["pickupDisplay"] as? String == "default" else { return nil }
                let regular = (part["messageTypes"] as? [String: Any])?["regular"] as? [String: Any]
                let raw = (regular?["storePickupQuote"] as? String) ?? (part["pickupSearchQuote"] as? String)
                let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }.first
            results.append(PickupResult(storeID: storeID, storeName: name, city: entry["city"] as? String ?? "", configurations: available, pickupQuote: quote))
        }
        guard !results.isEmpty else { throw InventoryError.rejected("The selected store was not included in Apple’s response.") }
        return results.sorted { first, second in
            if (first.storeID == watch.storeID) != (second.storeID == watch.storeID) { return first.storeID == watch.storeID }
            return first.storeName.localizedStandardCompare(second.storeName) == .orderedAscending
        }
    }
}
