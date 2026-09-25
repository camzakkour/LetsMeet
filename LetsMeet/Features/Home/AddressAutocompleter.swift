//
//  AddressAutocompleter.swift
//  LetsMeet
//

import Foundation
import CoreLocation
import MapKit

/// One autocomplete row, decoupled from `MKLocalSearchCompletion` for display
/// while keeping the completion around so it can be resolved on selection.
struct AddressSuggestion: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let completion: MKLocalSearchCompletion
}

/// A friend location the user picked from autocomplete and that was resolved
/// via `MKLocalSearch`, so the search flow can use its coordinate directly
/// instead of geocoding the display text again.
struct ResolvedFriendLocation {
    let displayText: String
    let location: CLLocation
}

/// Thin wrapper around `MKLocalSearchCompleter` for friend-address entry.
/// Deliberately does not set a region, so suggestions aren't biased away from
/// friends who live far from the user. Failures are swallowed into an empty
/// suggestion list - manual entry always keeps working.
final class AddressAutocompleter: NSObject, MKLocalSearchCompleterDelegate {

    /// Called on the main thread whenever the suggestion list changes.
    var onSuggestionsChanged: (([AddressSuggestion]) -> Void)?

    private let completer = MKLocalSearchCompleter()
    private static let maxSuggestions = 8

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        completer.queryFragment = query
    }

    /// Stops any in-flight query and clears the list.
    func cancel() {
        completer.cancel()
        completer.queryFragment = ""
        onSuggestionsChanged?([])
    }

    /// Resolves a completion to a coordinate and a readable address string.
    func resolve(_ suggestion: AddressSuggestion) async throws -> ResolvedFriendLocation {
        let request = MKLocalSearch.Request(completion: suggestion.completion)
        request.resultTypes = [.address, .pointOfInterest]
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else { throw MKError(.placemarkNotFound) }

        let coordinate = item.placemark.coordinate
        return ResolvedFriendLocation(
            displayText: Self.displayText(for: item, fallback: suggestion),
            location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        )
    }

    private static func displayText(for item: MKMapItem, fallback suggestion: AddressSuggestion) -> String {
        let placemark = item.placemark
        let street = [placemark.subThoroughfare, placemark.thoroughfare]
            .compactMap { $0 }
            .joined(separator: " ")
        let region = [placemark.locality, placemark.administrativeArea]
            .compactMap { $0 }
            .joined(separator: ", ")

        // Named places (businesses, landmarks) lead with their name.
        let lead = item.pointOfInterestCategory != nil ? (item.name ?? street) : street
        let parts = [lead, region].filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: ", ") }

        return [suggestion.title, suggestion.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: MKLocalSearchCompleterDelegate

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let suggestions = completer.results
            .filter { !$0.title.isEmpty }
            .prefix(Self.maxSuggestions)
            .map { AddressSuggestion(title: $0.title, subtitle: $0.subtitle, completion: $0) }
        onSuggestionsChanged?(Array(suggestions))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        onSuggestionsChanged?([])
    }
}
