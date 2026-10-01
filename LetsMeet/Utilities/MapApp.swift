//
//  MapApp.swift
//  LetsMeet
//

import UIKit

/// The map apps the restaurant card's "Directions" action can hand off to.
/// Apple Maps is always offered - its URL scheme needs no declaration and is
/// always installed. Google Maps and Waze are offered only when actually
/// installed, which `canOpenURL` can only report truthfully once their
/// schemes are declared under `LSApplicationQueriesSchemes` in Info.plist.
enum MapApp: String, Identifiable, CaseIterable {
    case appleMaps
    case googleMaps
    case waze

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleMaps: return "Apple Maps"
        case .googleMaps: return "Google Maps"
        case .waze: return "Waze"
        }
    }

    /// Whether this app can actually be launched for `restaurant` - requires
    /// either an address or a coordinate to route to, and (for third-party
    /// apps) that the app is actually installed.
    func isAvailable(for restaurant: Restaurant) -> Bool {
        guard directionsURL(for: restaurant) != nil else { return false }
        return self == .appleMaps || isInstalled
    }

    func open(for restaurant: Restaurant) {
        guard let url = directionsURL(for: restaurant) else { return }
        UIApplication.shared.open(url)
    }

    private var isInstalled: Bool {
        guard let probeURL else { return false }
        return UIApplication.shared.canOpenURL(probeURL)
    }

    private var probeURL: URL? {
        switch self {
        case .appleMaps: return nil
        case .googleMaps: return URL(string: "comgooglemaps://")
        case .waze: return URL(string: "waze://")
        }
    }

    private func directionsURL(for restaurant: Restaurant) -> URL? {
        let coordinate = restaurant.coordinate
        let encodedAddress = restaurant.location?.display_address
            .joined(separator: " ")
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)

        switch self {
        case .appleMaps:
            if let encodedAddress {
                return URL(string: "http://maps.apple.com/?daddr=\(encodedAddress)")
            } else if let coordinate {
                return URL(string: "http://maps.apple.com/?daddr=\(coordinate.latitude),\(coordinate.longitude)")
            }
            return nil
        case .googleMaps:
            if let coordinate {
                return URL(string: "comgooglemaps://?daddr=\(coordinate.latitude),\(coordinate.longitude)&directionsmode=driving")
            } else if let encodedAddress {
                return URL(string: "comgooglemaps://?daddr=\(encodedAddress)&directionsmode=driving")
            }
            return nil
        case .waze:
            guard let coordinate else { return nil }
            return URL(string: "waze://?ll=\(coordinate.latitude),\(coordinate.longitude)&navigate=yes")
        }
    }
}
