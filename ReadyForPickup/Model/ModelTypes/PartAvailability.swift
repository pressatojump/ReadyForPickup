//
//  PartAvailability.swift
//  ReadyForPickup
//
//  Created by Worth Baker on 7/27/22.
//

import Foundation

struct PartAvailability: Equatable, Hashable {
    enum PickupAvailability: String {
        case available, unavailable, ineligible
    }
    
    let partNumber: String
    let partName: String
    let availability: PickupAvailability
    /// Pre-launch / check-back quote from Apple when pickupDisplay is "default"
    /// (e.g. "Check back for availability on 10.24").
    let pickupQuote: String?

    init(partNumber: String, partName: String, availability: PickupAvailability, pickupQuote: String? = nil) {
        self.partNumber = partNumber
        self.partName = partName
        self.availability = availability
        self.pickupQuote = pickupQuote
    }
}

extension PartAvailability: Identifiable {
    var id: String {
        partNumber
    }
}
