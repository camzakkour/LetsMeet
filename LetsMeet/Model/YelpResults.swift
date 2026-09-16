//
//  YelpResults.swift
//  LetsMeet
//
//  Created by Cameron Zakkour on 5/5/22.
//

import Foundation
import CoreLocation
#if DEBUG
import os.log
#endif

//Details to be shown: Name, Hours of Operation, and Price("$$")
struct TopLevelDictionary: Decodable {
    var businesses: [Restaurant]

    private enum CodingKeys: String, CodingKey {
        case businesses
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let wrapped = try container.decode([FailableDecodable<Restaurant>].self, forKey: .businesses)
        businesses = wrapped.compactMap(\.base)

        #if DEBUG
        let droppedCount = wrapped.count - businesses.count
        if droppedCount > 0 {
            Logger(subsystem: "com.letsmeet.app", category: "Yelp")
                .log("[Yelp] dropped \(droppedCount) of \(wrapped.count) businesses - genuinely undecodable (not just a malformed image_url)")
        }
        #endif
    }
}

/// Decodes one array element independently so a single genuinely-malformed
/// business (not just a malformed `image_url`, which `Restaurant` already
/// tolerates on its own) doesn't invalidate every other valid business in
/// the same response. `init(from:)` never throws, so decoding this from an
/// unkeyed container always advances past the element regardless of whether
/// the inner decode succeeded.
private struct FailableDecodable<Base: Decodable>: Decodable {
    let base: Base?

    init(from decoder: Decoder) throws {
        base = try? Base(from: decoder)
    }
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

    /// Custom decoding only so `image_url` can be decoded losslessly:
    /// missing/null -> nil, valid URL string -> URL, malformed URL string ->
    /// nil. A malformed `image_url` must never fail an otherwise-valid
    /// Restaurant - every other field still decodes (and still throws)
    /// exactly as the synthesized initializer would have.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        imageURL = try container.decodeIfPresent(String.self, forKey: .imageURL).flatMap(URL.init(string:))
        price = try container.decodeIfPresent(String.self, forKey: .price)
        rating = try container.decode(Double.self, forKey: .rating)
        reviewCount = try container.decodeIfPresent(Int.self, forKey: .reviewCount)
        categories = try container.decode([Categories].self, forKey: .categories)
        location = try container.decodeIfPresent(Location.self, forKey: .location)
        distance = try container.decodeIfPresent(Double.self, forKey: .distance)
        coordinates = try container.decodeIfPresent(Coordinates.self, forKey: .coordinates)
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
