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
                self.isSearching = false

                guard let location = placemarks?.first?.location else {
                    self.errorMessage = "\(trimmedAddress) Invalid Address"
                    return
                }

                YelpManager.shared.didCaptureFriendsLocation(location: location)
                self.navigator?.showResults()
            }
        }
    }
}
