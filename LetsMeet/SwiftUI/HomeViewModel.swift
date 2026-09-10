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
    @Published var errorMessage: String?
    @Published var restaurants: [Restaurant] = []
    @Published var isShowingResults: Bool = false

    weak var navigator: HomeNavigating?

    func findAPlace() {
        let trimmedAddress = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else {
            errorMessage = "Please enter a full address and try again"
            return
        }

        isSearching = true

        CLGeocoder().geocodeAddressString(trimmedAddress) { [weak self] placemarks, error in
            guard let self = self else { return }

            DispatchQueue.main.async {
                guard let location = placemarks?.first?.location else {
                    self.isSearching = false
                    self.errorMessage = "\(trimmedAddress) Invalid Address"
                    return
                }

                YelpManager.shared.didCaptureFriendsLocation(location: location)
                self.searchForRestaurants()
            }
        }
    }

    private func searchForRestaurants() {
        YelpManager.shared.searchBusiness { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isSearching = false

                switch result {
                case .success:
                    self.restaurants = YelpManager.shared.restaurants
                    self.isShowingResults = true
                case .failure:
                    self.errorMessage = "We couldn't find restaurants near your midpoint. Please try again."
                }
            }
        }
    }
}
