//
//  HomeViewModel.swift
//  LetsMeet
//

import Foundation
import CoreLocation

/// Holds only transient UI state for the SwiftUI home screen. The actual
/// location/midpoint/search state continues to live in YelpManager.shared,
/// exactly as it did for WelcomeViewController - this does not introduce a
/// second source of truth.
final class HomeViewModel: ObservableObject {

    @Published var addressText: String = ""
    @Published var isSearching: Bool = false
    @Published var errorTitle: String = "Error"
    @Published var errorMessage: String?
    @Published var restaurants: [Restaurant] = []
    @Published var isShowingResults: Bool = false

    weak var navigator: HomeNavigating?

    func findAPlace() {
        let trimmedAddress = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else {
            errorTitle = "Missing Address"
            errorMessage = "Please enter a full address and try again"
            return
        }

        isSearching = true

        CLGeocoder().geocodeAddressString(trimmedAddress) { [weak self] placemarks, error in
            guard let self = self else { return }

            DispatchQueue.main.async {
                guard let friendLocation = placemarks?.first?.location else {
                    self.isSearching = false
                    self.errorTitle = "Address Not Found"
                    self.errorMessage = "\(trimmedAddress) Invalid Address"
                    return
                }

                guard let userLocation = YelpManager.shared.currentUserLocation else {
                    self.isSearching = false
                    self.errorTitle = "Location Unavailable"
                    self.errorMessage = "We couldn't determine your current location. Please try again."
                    return
                }

                YelpManager.shared.friendLocation = friendLocation
                self.searchForRestaurants(userLocation: userLocation, friendLocation: friendLocation)
            }
        }
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

                case .limitedFairOptions(let restaurants):
                    YelpManager.shared.restaurants = restaurants
                    self.restaurants = restaurants
                    self.isShowingResults = true
                    self.errorTitle = "Limited Options"
                    self.errorMessage = "We only found a couple of restaurants with fair travel times for both of you."

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
