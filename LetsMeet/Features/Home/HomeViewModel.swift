//
//  HomeViewModel.swift
//  LetsMeet
//

import Foundation
import CoreLocation
import MapKit
import SwiftUI
import os.log

/// A street-level manual-geocoding result the user hasn't confirmed yet.
/// `revision` ties it to the text it was resolved from.
struct ConfirmableAddress {
    let revision: Int
    let street: String
    let region: String
    let displayText: String
    let location: CLLocation
}

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
    /// ignored. This is a plain staleness check: a stale search's late result
    /// is never applied to the UI. Stopping its further work is the job of
    /// `activeSearchToken` below (requests already in flight still finish).
    private var activeSearchID: String?

    /// Cooperative-cancellation token for the search `activeSearchID` names,
    /// installed and retired in lockstep with it: `findAPlace()` cancels the
    /// previous token before installing its own, and `resetToHome()` cancels
    /// it. Cancelling only stops that search from scheduling further work
    /// (see `SearchCancellationToken`); `activeSearchID` still independently
    /// guards every UI mutation. Each search captures its own token, so
    /// cancelling one never affects another.
    private var activeSearchToken: SearchCancellationToken?

    /// A street-level manual-geocoding result waiting for the user's "Use This
    /// Address" before any search starts. Set only by the manual fallback;
    /// cleared by any edit or reset.
    @Published var addressToConfirm: ConfirmableAddress?

    /// True after Find found several suggestions that equally fit the typed
    /// text: the card asks the user to pick one instead of guessing.
    @Published private(set) var needsSuggestionChoice = false
    /// Bumped every time that prompt is (re)issued so the view can refocus the
    /// field even when `needsSuggestionChoice` was already true.
    @Published private(set) var suggestionChoiceRequest = 0

    /// The autocompleter query the current `suggestions` were delivered for,
    /// and the last query handed to it. A list only counts for a decision when
    /// it was delivered for the text now in the field.
    private var suggestionsQuery = ""
    private var requestedQuery: String?

    /// Staleness token for everything that resolves the typed address (a
    /// suggestion lookup, the bounded wait for suggestions, the manual
    /// geocode, a pending confirmation). Anything that makes that work stale -
    /// an edit, a reset, a newer selection - bumps it; each async completion
    /// captures the value it started under and is dropped if it no longer
    /// matches. Same idea as `activeSearchID`, for the pre-search phase.
    private var addressRevision = 0
    /// Non-nil while a suggestion lookup is in flight: the revision it runs under.
    private var pendingSelectionRevision: Int?
    /// Find was tapped while a lookup was in flight; the search starts once it lands.
    private var searchAfterResolve = false
    /// The revision of an active bounded wait for the current text's suggestions.
    private var suggestionWaitRevision: Int?
    /// `isSearching` is currently held by the pre-search address phase (the
    /// lookup, the wait, or the manual geocode), not by the restaurant search -
    /// so an edit may release it, while an edit during the real search may not.
    private var isResolvingAddress = false
    /// Set while this view model writes `addressText` itself, so the write
    /// isn't treated as a user edit.
    private var isApplyingResolvedText = false

    private static let minimumQueryLength = 3
    /// Longest Find waits for suggestions of the text just typed before
    /// falling back to manual geocoding.
    private static let suggestionWaitSeconds: TimeInterval = 0.6
    private let autocompleter = AddressAutocompleter()

    init() {
        autocompleter.onSuggestionsChanged = { [weak self] suggestions, query in
            guard let self = self else { return }
            // Late results after a selection (or after the text got too short)
            // must not reopen the list.
            self.suggestions = self.isAutocompleteEligible ? suggestions : []
            self.suggestionsQuery = query

            if self.suggestionWaitRevision != nil, self.isCurrentQuery(query) {
                self.finishSuggestionWait()
            }
        }
    }

    private var trimmedAddress: String {
        addressText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isAutocompleteEligible: Bool {
        selectedFriendLocation == nil
            && pendingSelectionRevision == nil
            && trimmedAddress.count >= Self.minimumQueryLength
    }

    private func isCurrentQuery(_ query: String) -> Bool {
        FriendAddressRules.normalize(query) == FriendAddressRules.normalize(trimmedAddress)
    }

    /// A suggestion request for the text now in the field has been made and
    /// its answer hasn't arrived.
    private var isAwaitingCurrentSuggestions: Bool {
        guard isAutocompleteEligible, let requested = requestedQuery else { return false }
        return isCurrentQuery(requested) && !isCurrentQuery(suggestionsQuery)
    }

    private func addressTextDidChange(from oldValue: String) {
        guard addressText != oldValue else { return }

        if !isApplyingResolvedText {
            invalidateAddressWork()
        }

        // Any edit that no longer matches the resolved selection invalidates
        // its coordinate so it can't be attached to different text.
        if let selected = selectedFriendLocation, selected.displayText != addressText {
            selectedFriendLocation = nil
        }

        if isAutocompleteEligible {
            requestedQuery = trimmedAddress
            autocompleter.update(query: trimmedAddress)
        } else {
            requestedQuery = nil
            autocompleter.cancel()
            suggestions = []
        }
    }

    /// Makes every in-flight piece of address resolution stale: a pending
    /// lookup can no longer apply, a bounded wait or manual geocode can no
    /// longer continue, a Find queued behind a lookup is dropped, and a
    /// confirmation or "pick one" prompt for the old text goes away. Releases
    /// `isSearching` only when the pre-search address phase was holding it.
    private func invalidateAddressWork() {
        addressRevision += 1
        pendingSelectionRevision = nil
        searchAfterResolve = false
        suggestionWaitRevision = nil
        if needsSuggestionChoice { needsSuggestionChoice = false }
        if addressToConfirm != nil { addressToConfirm = nil }
        if isResolvingAddress {
            isResolvingAddress = false
            isSearching = false
        }
    }

    /// Resolves a tapped suggestion to a coordinate via `MKLocalSearch`. On
    /// failure the field is left as typed so manual entry still works.
    func selectSuggestion(_ suggestion: AddressSuggestion) {
        startResolution(of: suggestion, thenSearch: false)
    }

    /// Resolves `suggestion` under a fresh revision, so a newer selection, an
    /// edit or a reset makes this lookup's result stale. With `thenSearch`
    /// the restaurant search starts as soon as it lands (Find was tapped, or
    /// the typed text matched exactly this one suggestion).
    private func startResolution(of suggestion: AddressSuggestion, thenSearch: Bool) {
        let previousSuggestions = suggestions
        let previousQuery = suggestionsQuery

        invalidateAddressWork()
        let revision = addressRevision
        pendingSelectionRevision = revision
        if thenSearch {
            searchAfterResolve = true
            isSearching = true
            isResolvingAddress = true
        }

        suggestions = []
        requestedQuery = nil
        autocompleter.cancel()

        #if DEBUG
        Self.logger.log("[S12] resolving suggestion '\(suggestion.title)' revision=\(revision) thenSearch=\(thenSearch)")
        #endif

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let resolved = try? await self.autocompleter.resolve(suggestion)

            // An edit, reset or newer selection already took over.
            guard self.pendingSelectionRevision == revision else {
                #if DEBUG
                Self.logger.log("[S12] STALE suggestion resolution ignored revision=\(revision)")
                #endif
                return
            }
            self.pendingSelectionRevision = nil
            let searchAfter = self.searchAfterResolve
            self.searchAfterResolve = false

            guard let resolved = resolved else {
                // The text is untouched (an edit would have invalidated this),
                // so put its suggestions back and say why nothing happened.
                if self.isResolvingAddress {
                    self.isResolvingAddress = false
                    self.isSearching = false
                }
                self.suggestions = previousSuggestions
                self.suggestionsQuery = previousQuery
                self.errorTitle = "Couldn't Use That Address"
                self.errorMessage = "Please pick another suggestion or edit the address."
                return
            }

            self.apply(resolved)
            if searchAfter {
                self.isResolvingAddress = false
                self.findAPlace()
            }
        }
    }

    /// Makes `resolved` the trusted friend location and shows its text in the
    /// field. The selection is set before the text so the text change is seen
    /// as matching it rather than invalidating it.
    private func apply(_ resolved: ResolvedFriendLocation) {
        isApplyingResolvedText = true
        selectedFriendLocation = resolved
        addressText = resolved.displayText
        isApplyingResolvedText = false
    }

    /// "Use This Address": the user confirmed a manual result, so it becomes
    /// the trusted selection and the search runs without geocoding again.
    func confirmAddress(_ candidate: ConfirmableAddress) {
        // The text was edited or reset since this was offered.
        guard candidate.revision == addressRevision else { return }
        addressToConfirm = nil
        apply(ResolvedFriendLocation(displayText: candidate.displayText, location: candidate.location))
        findAPlace()
    }

    /// "Edit": drop the confirmation and leave the text as typed.
    func editAddress() {
        addressToConfirm = nil
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
        activeSearchToken?.cancel()
        activeSearchToken = nil
        invalidateAddressWork()
        isSearching = false
        isShowingResults = false
        errorMessage = nil
        clearSearchResultState()
        addressText = ""
    }

    func findAPlace() {
        let searchID = String(UUID().uuidString.prefix(8))
        activeSearchID = searchID
        activeSearchToken?.cancel()
        let searchToken = SearchCancellationToken()
        activeSearchToken = searchToken
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

        // Only a coordinate the user explicitly chose (or confirmed) goes
        // straight to the search; typed text is resolved first.
        guard let selected = selectedFriendLocation, selected.displayText == addressText else {
            resolveTypedAddress()
            return
        }

        isSearching = true
        // Clean reset so a new search's progressive/terminal results can
        // never mix with whatever the previous search left displayed.
        clearSearchResultState()

        // The selection already has a reliable coordinate - never geocode the
        // same text again.
        #if DEBUG
        let addressResolutionDuration = CFAbsoluteTimeGetCurrent() - searchStartTime
        Self.logger.log("""
        [S9][\(searchID)] friend coordinate resolved via AUTOCOMPLETE: \
        coordinate=\(String(describing: selected.location.coordinate))
        """)
        Self.logger.log("[Timing][S9][\(searchID)] address resolution (autocomplete, cached) took \(addressResolutionDuration)s")
        #endif
        resolveUserAndSearch(friendLocation: selected.location, searchID: searchID, cancellationToken: searchToken, searchStartTime: searchStartTime)
    }

    // MARK: - Resolving typed text (Find without a trusted selection)

    /// Find was tapped with text that isn't a resolved selection. In order of
    /// preference: wait for a suggestion lookup already in flight; briefly
    /// wait for the current text's suggestions; use them if exactly one
    /// clearly fits; ask the user to choose if several do; otherwise fall back
    /// to manual geocoding with a confirmation. Nothing here ever searches on
    /// an unconfirmed guess.
    private func resolveTypedAddress() {
        if pendingSelectionRevision != nil {
            // The lookup's completion re-runs Find once it lands.
            searchAfterResolve = true
            isSearching = true
            isResolvingAddress = true
            return
        }

        if isAwaitingCurrentSuggestions {
            beginSuggestionWait()
            return
        }

        decideFromSuggestions()
    }

    private func beginSuggestionWait() {
        let revision = addressRevision
        suggestionWaitRevision = revision
        isSearching = true
        isResolvingAddress = true

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.suggestionWaitSeconds) { [weak self] in
            guard let self = self, self.suggestionWaitRevision == revision else { return }
            #if DEBUG
            Self.logger.log("[S12] suggestion wait TIMED OUT revision=\(revision)")
            #endif
            self.finishSuggestionWait()
        }
    }

    /// Ends the wait (suggestions arrived, or the time ran out) and decides
    /// with whatever list is current. A no-op if the wait was invalidated.
    private func finishSuggestionWait() {
        guard suggestionWaitRevision != nil else { return }
        suggestionWaitRevision = nil
        isResolvingAddress = false
        isSearching = false
        decideFromSuggestions()
    }

    /// Zero / one / many suggestions clearly corresponding to the typed text.
    /// A list delivered for different text counts as no candidates.
    private func decideFromSuggestions() {
        let typed = trimmedAddress
        let matches = isCurrentQuery(suggestionsQuery)
            ? suggestions.filter { FriendAddressRules.suggestionMatches(typed: typed, title: $0.title, subtitle: $0.subtitle) }
            : []

        #if DEBUG
        Self.logger.log("[S12] typed address '\(typed)': \(matches.count) matching suggestion(s) of \(self.suggestions.count)")
        #endif

        switch matches.count {
        case 0:
            geocodeTypedAddress(typed)
        case 1:
            startResolution(of: matches[0], thenSearch: true)
        default:
            // Don't pick one for the user: reopen the existing dropdown.
            needsSuggestionChoice = true
            suggestionChoiceRequest += 1
        }
    }

    /// Manual fallback for text that matches no suggestion. Only a street-level
    /// result is usable, and even then it goes through a confirmation - nothing
    /// proves the user chose that address.
    private func geocodeTypedAddress(_ typed: String) {
        let revision = addressRevision
        isSearching = true
        isResolvingAddress = true

        CLGeocoder().geocodeAddressString(typed) { [weak self] placemarks, error in
            guard let self = self else { return }

            DispatchQueue.main.async {
                guard self.addressRevision == revision else {
                    #if DEBUG
                    Self.logger.log("[S12] STALE geocoding result ignored revision=\(revision)")
                    #endif
                    return
                }
                self.isResolvingAddress = false
                self.isSearching = false

                guard let placemark = placemarks?.first,
                      let location = placemark.location,
                      FriendAddressRules.isStreetLevel(thoroughfare: placemark.thoroughfare) else {
                    #if DEBUG
                    Self.logger.log("[S12] geocoding REJECTED for address=\(typed): \(String(describing: error)) placemark=\(String(describing: placemarks?.first))")
                    #endif
                    self.errorTitle = "Address Not Found"
                    self.errorMessage = "We couldn't find a street address for \"\(typed)\". Enter a full street address (number, street and city) or select a suggestion."
                    return
                }

                let street = FriendAddressRules.streetLine(subThoroughfare: placemark.subThoroughfare, thoroughfare: placemark.thoroughfare)
                let cityState = FriendAddressRules.cityState(locality: placemark.locality, administrativeArea: placemark.administrativeArea)
                #if DEBUG
                Self.logger.log("[S12] geocoding street-level result awaiting confirmation: \(street), \(cityState)")
                #endif
                self.addressToConfirm = ConfirmableAddress(
                    revision: revision,
                    street: street,
                    region: FriendAddressRules.confirmationRegion(
                        locality: placemark.locality,
                        administrativeArea: placemark.administrativeArea,
                        postalCode: placemark.postalCode,
                        countryName: placemark.country,
                        isoCountryCode: placemark.isoCountryCode,
                        deviceRegionCode: Locale.current.region?.identifier
                    ),
                    displayText: [street, cityState].filter { !$0.isEmpty }.joined(separator: ", "),
                    location: location
                )
            }
        }
    }

    /// Shared by the manual-geocoding and autocomplete-selection paths once a
    /// friend location is known.
    private func resolveUserAndSearch(friendLocation: CLLocation, searchID: String, cancellationToken: SearchCancellationToken, searchStartTime: CFAbsoluteTime) {
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
        searchForRestaurants(userLocation: userLocation, friendLocation: friendLocation, searchID: searchID, cancellationToken: cancellationToken, searchStartTime: searchStartTime)
    }

    /// Runs the route-seeded, restaurant-first search (see
    /// MeetingPlaceFinder) rather than the plain geographic-midpoint search
    /// the legacy UIKit flow still uses. Every outcome case is handled
    /// explicitly so a limited or empty result is never silently presented
    /// as a normal, fully-fair success.
    private func searchForRestaurants(userLocation: CLLocation, friendLocation: CLLocation, searchID: String, cancellationToken: SearchCancellationToken, searchStartTime: CFAbsoluteTime) {
        MeetingPlaceFinder.shared.findMeetingPlace(userLocation: userLocation, friendLocation: friendLocation, searchID: searchID, cancellationToken: cancellationToken, onProgress: { [weak self] snapshot in
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
                    // Yelp returned restaurants but none could be verified and
                    // displayed. Restaurants that were verified but less
                    // balanced are shown via `.limitedFairOptions`, so this
                    // must not claim they failed a fairness check.
                    self.errorTitle = "No Results to Show"
                    self.errorMessage = "We found restaurants nearby, but couldn't confirm travel times for any of them. Please try a different address."

                case .noRestaurantsNearby:
                    guard !hadDisplayableResultsAlready else { break }
                    self.isShowingResults = false
                    self.restaurants = []
                    self.errorTitle = "No Restaurants Nearby"
                    self.errorMessage = "We couldn't find restaurants near a fair meeting point. Please try a different address."

                case .etaVerificationUnavailable:
                    // Distinct from `.noFairRestaurants`: this means travel
                    // times couldn't be reliably checked (most likely a
                    // transient MapKit outage). Zero-verified-restaurants-and-
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
