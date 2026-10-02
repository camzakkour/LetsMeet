//
//  HomeViewModel.swift
//  LetsMeet
//

import Foundation
import CoreLocation
import MapKit
import SwiftUI
import os.log

/// Holds only transient UI state for the SwiftUI home screen. The actual
/// location/midpoint/search state continues to live in YelpManager.shared,
/// so this view model does not introduce a second source of truth.
final class HomeViewModel: ObservableObject {

    #if DEBUG
    private static let logger = Logger(subsystem: "com.letsmeet.app", category: "Session9")

    private static func describe(_ outcome: MeetingPlaceOutcome) -> String {
        switch outcome {
        case .success(let restaurants):
            return "success (\(restaurants.count) restaurants)"
        case .limitedFairOptions(let restaurants):
            return "limitedFairOptions (\(restaurants.count) restaurants)"
        case .noFairRestaurants:
            return "noFairRestaurants"
        case .noRestaurantsNearby:
            return "noRestaurantsNearby"
        case .searchFailed(let error):
            return "searchFailed (\(error))"
        case .etaVerificationUnavailable:
            return "etaVerificationUnavailable"
        }
    }
    #endif

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

    /// The searchID of the most recently started `findAPlace()` call. Every
    /// async callback (geocoding, progressive batch updates, the terminal
    /// outcome) captures its own `searchID` and must compare it against this
    /// property before mutating any `@Published` state - a callback whose
    /// searchID no longer matches belongs to a superseded search and is
    /// ignored. This is a plain staleness check, not cancellation: a stale
    /// search is left to finish its work (MapKit requests already in flight
    /// aren't aborted), its late result is just never applied to the UI.
    private var activeSearchID: String?

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

    /// Clears everything a search produces on the map/results side - pins,
    /// routes, midpoint/radius, and the result list itself - without
    /// touching location/permission state or the in-progress search flag.
    /// Shared by `findAPlace()` (clearing the prior search before starting a
    /// new one) and `resetToHome()` (clearing it with nothing replacing it).
    private func clearSearchResultState() {
        suggestions = []
        friendCoordinate = nil
        meetingPointCoordinate = nil
        searchRadiusMeters = nil
        route = nil
        restaurants = []
    }

    /// Returns the home screen to its original, pre-search state: dismisses
    /// results, clears the map's search-derived state, and resets the
    /// friend-address field so the next search starts clean. Invalidates
    /// `activeSearchID` so a late progress/terminal callback from a search
    /// still in flight is treated as stale (same staleness check `findAPlace`
    /// already relies on) and can't repopulate state after the reset.
    /// Deliberately leaves location/permission state untouched.
    func resetToHome() {
        activeSearchID = nil
        isSearching = false
        isShowingResults = false
        errorMessage = nil
        clearSearchResultState()
        addressText = ""
    }

    func findAPlace() {
        let searchID = String(UUID().uuidString.prefix(8))
        activeSearchID = searchID
        let wasAlreadySearching = isSearching
        // Cheap, always available (not gated behind #if DEBUG) purely so it
        // can be threaded through as a plain parameter below without
        // conditional-compilation call-site gymnastics; only ever read
        // inside #if DEBUG timing blocks.
        let searchStartTime = CFAbsoluteTimeGetCurrent()

        let trimmedAddress = addressText.trimmingCharacters(in: .whitespacesAndNewlines)

        #if DEBUG
        Self.logger.log("""
        [S9][\(searchID)] findAPlace() invoked at \(Date()): wasAlreadySearching=\(wasAlreadySearching) \
        friendAddress=\(trimmedAddress) userCoordinate=\(String(describing: YelpManager.shared.currentUserLocation?.coordinate))
        """)
        if wasAlreadySearching {
            Self.logger.log("[S9][\(searchID)] OVERLAPPING SEARCH: a new findAPlace() began while isSearching was already true")
        }
        #endif

        guard !trimmedAddress.isEmpty else {
            errorTitle = "Missing Address"
            errorMessage = "Please enter a full address and try again"
            return
        }

        isSearching = true
        // Clean reset so a new search's progressive/terminal results can
        // never mix with whatever the previous search left displayed.
        clearSearchResultState()

        // A valid autocomplete selection already has a reliable coordinate -
        // skip geocoding the same text again.
        if let selected = selectedFriendLocation, selected.displayText == addressText {
            #if DEBUG
            let addressResolutionDuration = CFAbsoluteTimeGetCurrent() - searchStartTime
            Self.logger.log("""
            [S9][\(searchID)] friend coordinate resolved via AUTOCOMPLETE: \
            coordinate=\(String(describing: selected.location.coordinate))
            """)
            Self.logger.log("[Timing][S9][\(searchID)] address resolution (autocomplete, cached) took \(addressResolutionDuration)s")
            #endif
            resolveUserAndSearch(friendLocation: selected.location, searchID: searchID, searchStartTime: searchStartTime)
            return
        }

        CLGeocoder().geocodeAddressString(trimmedAddress) { [weak self] placemarks, error in
            guard let self = self else { return }

            DispatchQueue.main.async {
                guard self.activeSearchID == searchID else {
                    #if DEBUG
                    Self.logger.log("[S9][\(searchID)] STALE geocoding result ignored - a newer search is now active")
                    #endif
                    return
                }
                guard let friendLocation = placemarks?.first?.location else {
                    #if DEBUG
                    Self.logger.log("[S9][\(searchID)] geocoding FAILED for address=\(trimmedAddress): \(String(describing: error))")
                    #endif
                    self.isSearching = false
                    self.errorTitle = "Address Not Found"
                    self.errorMessage = "\(trimmedAddress) Invalid Address"
                    return
                }

                #if DEBUG
                let addressResolutionDuration = CFAbsoluteTimeGetCurrent() - searchStartTime
                Self.logger.log("""
                [S9][\(searchID)] friend coordinate resolved via GEOCODING: \
                coordinate=\(String(describing: friendLocation.coordinate))
                """)
                Self.logger.log("[Timing][S9][\(searchID)] address resolution (geocoding) took \(addressResolutionDuration)s")
                #endif

                self.resolveUserAndSearch(friendLocation: friendLocation, searchID: searchID, searchStartTime: searchStartTime)
            }
        }
    }

    /// Shared by the manual-geocoding and autocomplete-selection paths once a
    /// friend location is known.
    private func resolveUserAndSearch(friendLocation: CLLocation, searchID: String, searchStartTime: CFAbsoluteTime) {
        guard let userLocation = YelpManager.shared.currentUserLocation else {
            #if DEBUG
            Self.logger.log("[S9][\(searchID)] user location UNAVAILABLE - aborting search")
            #endif
            isSearching = false
            errorTitle = "Location Unavailable"
            errorMessage = "We couldn't determine your current location. Please try again."
            return
        }

        YelpManager.shared.friendLocation = friendLocation
        friendCoordinate = friendLocation.coordinate
        searchForRestaurants(userLocation: userLocation, friendLocation: friendLocation, searchID: searchID, searchStartTime: searchStartTime)
    }

    /// Runs the route-seeded, restaurant-first search (see
    /// MeetingPlaceFinder) rather than the plain geographic-midpoint search
    /// the legacy UIKit flow still uses. Every outcome case is handled
    /// explicitly so a limited or empty result is never silently presented
    /// as a normal, fully-fair success.
    private func searchForRestaurants(userLocation: CLLocation, friendLocation: CLLocation, searchID: String, searchStartTime: CFAbsoluteTime) {
        MeetingPlaceFinder.shared.findMeetingPlace(userLocation: userLocation, friendLocation: friendLocation, searchID: searchID, onProgress: { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self = self else { return }

                guard self.activeSearchID == searchID else {
                    #if DEBUG
                    Self.logger.log("[S9][\(searchID)] STALE progress snapshot ignored - a newer search is now active")
                    #endif
                    return
                }

                #if DEBUG
                Self.logger.log("[S9][\(searchID)] progressive snapshot: \(snapshot.count) restaurant(s)")
                #endif

                withAnimation {
                    self.restaurants = snapshot
                }
                if !self.isShowingResults {
                    self.isShowingResults = true
                    self.meetingPointCoordinate = YelpManager.shared.midPoint?.coordinate
                    self.searchRadiusMeters = YelpManager.shared.searchRadiusMeters
                    self.route = YelpManager.shared.route
                }
            }
        }) { [weak self] outcome in
            #if DEBUG
            let outcomeReceivedTime = CFAbsoluteTimeGetCurrent()
            #endif
            DispatchQueue.main.async {
                guard let self = self else { return }

                guard self.activeSearchID == searchID else {
                    #if DEBUG
                    Self.logger.log("[S9][\(searchID)] STALE terminal outcome ignored - a newer search is now active")
                    #endif
                    return
                }

                #if DEBUG
                Self.logger.log("""
                [S9][\(searchID)] outcome received: \(Self.describe(outcome)) isMainThread=\(Thread.isMainThread) \
                isSearching(before)=\(self.isSearching) isShowingResults(before)=\(self.isShowingResults) \
                errorMessage(before)IsNil=\(self.errorMessage == nil)
                """)
                #endif

                self.isSearching = false

                // Progressive delivery may have already shown trustworthy,
                // ETA-verified restaurants from an earlier batch/round. A
                // terminal outcome that would otherwise read as a failure
                // (sparse results, a fairness dead end, a MapKit outage) is
                // not grounds to discard what's already on screen - only an
                // empty sheet falls back to the existing alert behavior.
                let hadDisplayableResultsAlready = !self.restaurants.isEmpty

                switch outcome {
                case .success(let restaurants):
                    YelpManager.shared.restaurants = restaurants
                    withAnimation {
                        self.restaurants = restaurants
                    }
                    self.errorMessage = nil
                    self.isShowingResults = true
                    self.meetingPointCoordinate = YelpManager.shared.midPoint?.coordinate
                    self.searchRadiusMeters = YelpManager.shared.searchRadiusMeters
                    self.route = YelpManager.shared.route

                case .limitedFairOptions(let restaurants):
                    // A usable successful result, not an error - populate
                    // and present the results sheet exactly like `.success`.
                    // Previously this ALSO set a non-nil errorMessage in the
                    // same update, which made the alert and the results
                    // sheet compete for presentation (SwiftUI can't reliably
                    // show both `.alert` and `.sheet` at once) and the sheet
                    // would frequently lose, even though fair restaurants
                    // had genuinely been found.
                    YelpManager.shared.restaurants = restaurants
                    withAnimation {
                        self.restaurants = restaurants
                    }
                    self.errorMessage = nil
                    self.isShowingResults = true
                    self.meetingPointCoordinate = YelpManager.shared.midPoint?.coordinate
                    self.searchRadiusMeters = YelpManager.shared.searchRadiusMeters
                    self.route = YelpManager.shared.route

                case .noFairRestaurants:
                    guard !hadDisplayableResultsAlready else { break }
                    self.isShowingResults = false
                    self.restaurants = []
                    self.errorTitle = "No Fair Options"
                    self.errorMessage = "We found restaurants nearby, but none had fair travel times for both of you. Please try a different address."

                case .noRestaurantsNearby:
                    guard !hadDisplayableResultsAlready else { break }
                    self.isShowingResults = false
                    self.restaurants = []
                    self.errorTitle = "No Restaurants Nearby"
                    self.errorMessage = "We couldn't find restaurants near a fair meeting point. Please try a different address."

                case .etaVerificationUnavailable:
                    // Distinct from `.noFairRestaurants`: this means travel
                    // times couldn't be reliably checked (most likely a
                    // transient MapKit outage), not that the restaurants
                    // found were unfair. Zero-verified-restaurants-and-
                    // unavailable still falls through to this Search Problem
                    // alert unchanged, per `hadDisplayableResultsAlready`.
                    guard !hadDisplayableResultsAlready else { break }
                    self.isShowingResults = false
                    self.restaurants = []
                    self.errorTitle = "Search Problem"
                    self.errorMessage = "We couldn't verify travel times right now. Please try again in a moment."

                case .searchFailed:
                    guard !hadDisplayableResultsAlready else { break }
                    self.isShowingResults = false
                    self.restaurants = []
                    self.errorTitle = "Search Problem"
                    self.errorMessage = "We couldn't find restaurants near your midpoint. Please try again."
                }

                #if DEBUG
                let presentedTime = CFAbsoluteTimeGetCurrent()
                let uiPresentationDuration = presentedTime - outcomeReceivedTime
                let totalDuration = presentedTime - searchStartTime
                Self.logger.log("""
                [S9][\(searchID)] outcome handled: restaurantCount=\(self.restaurants.count) \
                isShowingResults(after)=\(self.isShowingResults) errorMessage(after)IsNil=\(self.errorMessage == nil)
                """)
                Self.logger.log("""
                [Timing][S9][\(searchID)] uiPresentation=\(uiPresentationDuration)s total=\(totalDuration)s
                """)
                #endif
            }
        }
    }
}
