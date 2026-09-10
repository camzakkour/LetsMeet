//
//  YelpResults.swift
//  LetsMeet
//
//  Created by Cameron Zakkour on 5/5/22.
//

import Foundation
import CoreLocation

//Details to be shown: Name, Hours of Operation, and Price("$$")
struct TopLevelDictionary: Decodable {
    var businesses: [Restaurant]
}

struct Restaurant: Decodable, Identifiable, Equatable {
    var id: String
    var name: String
    var imageURL: URL?
    var price: String? = "0"
    var rating: Double
    var reviewCount: Int?
    var categories: [Categories]
    var location: Location?
    /// Meters from the search coordinate - which is always our computed midpoint,
    /// since that's what YelpManager.searchBusiness queries with.
    var distance: Double?
    var coordinates: Coordinates?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case imageURL = "image_url"
        case price
        case rating
        case reviewCount = "review_count"
        case categories
        case location
        case distance
        case coordinates
    }

    /// Convenience for map annotations - nil if Yelp didn't return coordinates
    /// for this business (rare, but not guaranteed).
    var coordinate: CLLocationCoordinate2D? {
        guard let coordinates else { return nil }
        return CLLocationCoordinate2D(latitude: coordinates.latitude, longitude: coordinates.longitude)
    }
}

struct Coordinates: Decodable, Equatable {
    var latitude: Double
    var longitude: Double
}

struct Location: Decodable, Equatable {
    var address1: String
    var city: String
    var zip_code: String
    var state: String
    var display_address: [String]
}

struct Categories: Decodable, Equatable {
    var title: String
}

/// Decodes only the field we need from Yelp's Business Details response
/// (GET /v3/businesses/{id}) - the multi-photo gallery source, distinct
/// from the single image_url Business Search already provides.
struct BusinessDetails: Decodable {
    var photos: [URL]
}
