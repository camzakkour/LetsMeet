//
//  HomeViewModel.swift
//  LetsMeet
//

import Foundation
import CoreLocation
import MapKit

/// Holds only transient UI state for the SwiftUI home screen. The actual
/// location/midpoint/search state continues to live in YelpManager.shared,
/// so this view model does not introduce a second source of truth.
final class HomeViewModel: ObservableObject {

    @Published var addressText: String = "" {
        didSet { addressTextDidChange(from: oldValue) }
    }
    @Published var isSearching: Bool = false
    @Published var errorTitle: String = "Error"
    @Published var errorMessage: String?
    @Published var restaurants: [Restaurant] = []
    @Published var isShowingResults: Bool = false

    /// Map visualization state, read from `YelpManager.shared` once a
    /// search resolves. Reset to nil at the start of every new search so a
    /// prior search's pin/route/circle can never linger into a new one.
    @Published var friendCoordinate: CLLocationCoordinate2D?
    @Published var meetingPointCoordinate: CLLocationCoordinate2D?
    @Published var searchRadiusMeters: Double?
    @Published var route: MKRoute?

    /// Autocomplete suggestions for the friend-address field. Empty whenever
    /// there's nothing useful to show (short text, a resolved selection, or
    /// an autocomplete failure).
    @Published private(set) var suggestions: [AddressSuggestion] = []

    /// The friend location resolved from a tapped suggestion. Only valid while
    /// `addressText` still equals its `displayText`; any edit clears it.
    private(set) var selectedFriendLocation: ResolvedFriendLocation?

    private static let minimumQueryLength = 3
    private let autocompleter = AddressAutocompleter()

    init() {
        autocompleter.onSuggestionsChanged = { [weak self] suggestions in
            guard let self = self else { return }
            // Late results after a selection (or after the text got too short)
            // must not reopen the list.
            self.suggestions = self.isAutocompleteEligible ? suggestions : []
        }
    }

    private var trimmedAddress: String {
        addressText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isAutocompleteEligible: Bool {
        selectedFriendLocation == nil && trimmedAddress.count >= Self.minimumQueryLength
    }

    private func addressTextDidChange(from oldValue: String) {
        guard addressText != oldValue else { return }

        // Any edit that no longer matches the resolved selection invalidates
        // its coordinate so it can't be attached to different text.
        if let selected = selectedFriendLocation, selected.displayText != addressText {
            selectedFriendLocation = nil
        }

        if isAutocompleteEligible {
            autocompleter.update(query: trimmedAddress)
        } else {
            autocompleter.cancel()
            suggestions = []
        }
    }

    /// Resolves a tapped suggestion to a coordinate via `MKLocalSearch`. On
    /// failure the field is left as typed so manual entry still works.
    func selectSuggestion(_ suggestion: AddressSuggestion) {
        suggestions = []
        autocompleter.cancel()

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard let resolved = try? await self.autocompleter.resolve(suggestion) else { return }
            // Set the selection before the text so the text change is seen as
            // matching it rather than invalidating it.
            self.selectedFriendLocation = resolved
            self.addressText = resolved.displayText
        }
    }

    func findAPlace() {
        let trimmedAddress = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else {
            errorTitle = "Missing Address"
            errorMessage = "Please enter a full address and try again"
            return
        }

        isSearching = true
        suggestions = []
        friendCoordinate = nil
        meetingPointCoordinate = nil
        searchRadiusMeters = nil
        route = nil

        // A valid autocomplete selection already has a reliable coordinate -
        // skip geocoding the same text again.
        if let selected = selectedFriendLocation, selected.displayText == addressText {
            resolveUserAndSearch(friendLocation: selected.location)
            return
        }

        CLGeocoder().geocodeAddressString(trimmedAddress) { [weak self] placemarks, error in
            guard let self = self else { return }

            DispatchQueue.main.async {
                guard let friendLocation = placemarks?.first?.location else {
                    self.isSearching = false
                    self.errorTitle = "Address Not Found"
                    self.errorMessage = "\(trimmedAddress) Invalid Address"
                    return
                }

                self.resolveUserAndSearch(friendLocation: friendLocation)
            }
        }
    }

    /// Shared by the manual-geocoding and autocomplete-selection paths once a
    /// friend location is known.
    private func resolveUserAndSearch(friendLocation: CLLocation) {
        guard let userLocation = YelpManager.shared.currentUserLocation else {
            isSearching = false
            errorTitle = "Location Unavailable"
            errorMessage = "We couldn't determine your current location. Please try again."
            return
        }

        YelpManager.shared.friendLocation = friendLocation
        friendCoordinate = friendLocation.coordinate
        searchForRestaurants(userLocation: userLocation, friendLocation: friendLocation)
    }

    /// Runs the route-seeded, restaurant-first search (see
    /// MeetingPlaceFinder) rather than the plain geographic-midpoint search
    /// the legacy UIKit flow still uses. Every outcome case is handled
    /// explicitly so a limited or empty result is never silently presented
    /// as a normal, fully-fair success.
    private func searchForRestaurants(userLocation: CLLocation, friendLocation: CLLocation) {
        MeetingPlaceFinder.shared.findMeetingPlace(userLocation: userLocation, friendLocation: friendLocation) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isSearching = false

                switch outcome {
                case .success(let restaurants):
                    YelpManager.shared.restaurants = restaurants
                    self.restaurants = restaurants
                    self.isShowingResults = true
                    self.meetingPointCoordinate = YelpManager.shared.midPoint?.coordinate
                    self.searchRadiusMeters = YelpManager.shared.searchRadiusMeters
                    self.route = YelpManager.shared.route

                case .limitedFairOptions(let restaurants):
                    YelpManager.shared.restaurants = restaurants
                    self.restaurants = restaurants
                    self.isShowingResults = true
                    self.errorTitle = "Limited Options"
                    self.errorMessage = "We only found a couple of restaurants with fair travel times for both of you."
                    self.meetingPointCoordinate = YelpManager.shared.midPoint?.coordinate
                    self.searchRadiusMeters = YelpManager.shared.searchRadiusMeters
                    self.route = YelpManager.shared.route

                case .noFairRestaurants:
                    self.errorTitle = "No Fair Options"
                    self.errorMessage = "We found restaurants nearby, but none had fair travel times for both of you. Please try a different address."

                case .noRestaurantsNearby:
                    self.errorTitle = "No Restaurants Nearby"
                    self.errorMessage = "We couldn't find restaurants near a fair meeting point. Please try a different address."

                case .searchFailed:
                    self.errorTitle = "Search Problem"
                    self.errorMessage = "We couldn't find restaurants near your midpoint. Please try again."
                }
            }
        }
    }
}
