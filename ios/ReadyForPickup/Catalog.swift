import Foundation

struct ProductConfiguration: Codable, Identifiable, Hashable, Sendable {
    let sku: String
    let name: String
    var id: String { sku }
}

struct StoreCountry: Decodable, Identifiable, Sendable {
    let code: String
    let name: String
    let locale: String
    let storeHost: String
    let storePath: String
    let products: [String: [ProductConfiguration]]
    var id: String { code }

    func url(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = storeHost
        components.path = "/" + [storePath, path].filter { !$0.isEmpty }.joined(separator: "/")
        return components.url
    }
}

struct AppleStore: Decodable, Identifiable, Hashable, Sendable {
    struct Address: Decodable, Hashable, Sendable {
        let city: String
        let stateName: String?
        let stateCode: String?
        let postalCode: String?

        var display: String {
            [city, stateCode ?? stateName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    let id: String
    let name: String
    let slug: String
    let address: Address
}

struct ProductFamily: Identifiable, Hashable {
    let id: String
    let name: String
    var symbol: String { id.lowercased().contains("iphone") ? "iphone" : "laptopcomputer" }

    static let ordered: [ProductFamily] = [
        .init(id: "iPhoneDuo", name: "iPhone Duo"),
        .init(id: "iPhonePro18", name: "iPhone 18 Pro"),
        .init(id: "iPhoneProMax18", name: "iPhone 18 Pro Max"),
        .init(id: "iPhoneAir", name: "iPhone Air"),
        .init(id: "iPhone17", name: "iPhone 17"),
        .init(id: "iPhone17e", name: "iPhone 17e"),
        .init(id: "iPhone16", name: "iPhone 16"),
        .init(id: "MacBookNeo", name: "MacBook Neo"),
        .init(id: "M5MacBookAir13", name: "MacBook Air 13-inch"),
        .init(id: "M5MacBookAir15", name: "MacBook Air 15-inch"),
        .init(id: "MacBookPro14", name: "MacBook Pro 14-inch"),
        .init(id: "MacBookPro16", name: "MacBook Pro 16-inch"),
        .init(id: "iMac", name: "iMac"),
        .init(id: "MacMini", name: "Mac mini"),
        .init(id: "MacStudio", name: "Mac Studio")
    ]

    static func named(_ id: String) -> ProductFamily {
        ordered.first { $0.id == id } ?? ProductFamily(id: id, name: id)
    }
}

struct Catalog: Sendable {
    let countries: [StoreCountry]
    let storesByLocale: [String: [AppleStore]]
    let generatedAt: String

    func country(_ code: String) -> StoreCountry? { countries.first { $0.code == code } }
    func stores(in countryCode: String) -> [AppleStore] {
        guard let country = country(countryCode) else { return [] }
        return (storesByLocale[country.locale] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func store(_ id: String, countryCode: String) -> AppleStore? {
        stores(in: countryCode).first { $0.id == id }
    }
    func products(in countryCode: String) -> [ProductFamily] {
        guard let country = country(countryCode) else { return [] }
        let known = ProductFamily.ordered.filter { !(country.products[$0.id] ?? []).isEmpty }
        let extra = country.products.keys.filter { key in !known.contains { $0.id == key } }.sorted()
        return known + extra.map { ProductFamily.named($0) }
    }

    static func load() throws -> Catalog {
        struct ProductFile: Decodable {
            let generatedAt: String
            let countries: [StoreCountry]
        }
        struct StoreFile: Decodable {
            struct Region: Decodable {
                struct State: Decodable { let store: [AppleStore] }
                let locale: String
                let store: [AppleStore]?
                let state: [State]?
                var stores: [AppleStore] { store ?? state?.flatMap(\.store) ?? [] }
            }
            let storeListData: [Region]
        }
        guard let productURL = Bundle.main.url(forResource: "ProductCatalog", withExtension: "json"),
              let storeURL = Bundle.main.url(forResource: "Stores_LocalBootstrap", withExtension: "json") else {
            throw InventoryError.catalogUnavailable
        }
        let decoder = JSONDecoder()
        let products = try decoder.decode(ProductFile.self, from: Data(contentsOf: productURL))
        let stores = try decoder.decode(StoreFile.self, from: Data(contentsOf: storeURL))
        let byLocale = Dictionary(stores.storeListData.map { ($0.locale, $0.stores) }, uniquingKeysWith: { first, _ in first })
        guard !products.countries.isEmpty, products.countries.allSatisfy({ !(byLocale[$0.locale] ?? []).isEmpty }) else {
            throw InventoryError.catalogUnavailable
        }
        return Catalog(countries: products.countries, storesByLocale: byLocale, generatedAt: products.generatedAt)
    }
}
