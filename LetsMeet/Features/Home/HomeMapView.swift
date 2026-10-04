//
//  HomeMapView.swift
//  LetsMeet
//

import SwiftUI
import MapKit

struct HomeMapView: View {

    @ObservedObject var viewModel: HomeViewModel
    @StateObject private var locationProvider = LocationProvider()
    @AppStorage("appMapStyle") private var mapStylePreference: AppMapStyle = .standard
    @Environment(\.openURL) private var openURL

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
    )
    @State private var hasCenteredOnUser = false
    /// Which presentation context is showing Settings, or nil when it isn't.
    /// Chosen when the gear is tapped and never moved afterwards, so the
    /// sheet stays where it opened even if results appear or disappear.
    @State private var settingsPresenter: SettingsPresenter?
    @FocusState private var isAddressFieldFocused: Bool
    /// Top edge of the on-screen keyboard in screen coordinates, or nil when
    /// no keyboard is showing. Only used to cap the suggestion dropdown's
    /// height - the card itself is laid out exactly as before.
    @State private var keyboardTopY: CGFloat?
    @State private var resultsDetent: PresentationDetent = .large
    /// The location state to explain in an alert after a blocked "Find a
    /// place" tap; nil when no location alert is showing.
    @State private var locationAlertState: LocationAvailability?

    /// Tall enough to show the full "Restaurants near your midpoint" header
    /// (~67pt: 12pt top padding + title3 line + 2pt spacing + subheadline
    /// line + 8pt bottom padding) plus the native drag indicator (~24pt)
    /// plus roughly the top half of the first RestaurantCardView's 180pt
    /// photo gallery (~115pt after its own 14pt top padding), so the list
    /// visibly continues past the bottom edge rather than showing a full
    /// or empty-looking card.
    private static let peekResultsDetent: PresentationDetent = .height(220)

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $cameraPosition) {
                if let meetingPoint = viewModel.meetingPointCoordinate, let radius = viewModel.searchRadiusMeters {
                    MapCircle(center: meetingPoint, radius: radius)
                        .foregroundStyle(Color.red.opacity(0.15))
                        .stroke(Color.red.opacity(0.5), lineWidth: 1.5)
                }

                if let segments = routeSegments {
                    MapPolyline(segments.userLeg)
                        .stroke(LetsMeetColor.lightBlue, lineWidth: 4)
                    MapPolyline(segments.friendLeg)
                        .stroke(LetsMeetColor.orange, lineWidth: 4)
                }

                ForEach(mappableRestaurants) { restaurant in
                    Annotation("", coordinate: restaurant.coordinate!) {
                        RestaurantMapPin()
                    }
                }

                if let friend = viewModel.friendCoordinate {
                    Annotation("", coordinate: friend) {
                        FriendMapPin()
                    }
                }

                if let meetingPoint = viewModel.meetingPointCoordinate {
                    Annotation("", coordinate: meetingPoint, anchor: .bottom) {
                        MeetingPointMapPin()
                    }
                }

                UserAnnotation()
            }
            .mapStyle(mapStylePreference.mapStyle)
            .ignoresSafeArea()

            brandingBadge
                .padding(.top, 8)

            settingsButton
                .padding(.top, 8)

            if !viewModel.isShowingResults {
                VStack {
                    Spacer()
                    bottomCard
                        // Its own node, so it can't collide with the alerts
                        // on the root view or on the stack around it.
                        .alert(
                            "Confirm Address",
                            isPresented: Binding(
                                get: { viewModel.addressToConfirm != nil },
                                set: { isPresented in
                                    if !isPresented && viewModel.addressToConfirm != nil { viewModel.editAddress() }
                                }
                            ),
                            presenting: viewModel.addressToConfirm
                        ) { candidate in
                            Button("Use This Address") { viewModel.confirmAddress(candidate) }
                            Button("Edit") {
                                viewModel.editAddress()
                                isAddressFieldFocused = true
                            }
                        } message: { candidate in
                            Text("\(candidate.street)\n\(candidate.region)")
                        }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                // Attached to this node rather than the root so it can't
                // collide with the existing error alert on the root view.
                .alert(
                    locationAlertTitle,
                    isPresented: Binding(
                        get: { locationAlertState != nil },
                        set: { isPresented in if !isPresented { locationAlertState = nil } }
                    )
                ) {
                    if locationAlertState == .denied {
                        Button("Open Settings") { openAppSettings() }
                        Button("Cancel", role: .cancel) { }
                    } else {
                        Button("OK", role: .cancel) { }
                    }
                } message: {
                    Text(locationAlertMessage)
                }
            }
        }
        .animation(.easeInOut, value: viewModel.isShowingResults)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardTopY = frame.minY
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardTopY = nil
        }
        .onAppear { locationProvider.start() }
        // Picks up a change made while the app was away (permission granted
        // in Settings, Location Services turned back on). Notification-based
        // rather than `scenePhase`, which isn't reliably driven when SwiftUI
        // is hosted by a UIHostingController under a UIKit scene delegate.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            locationProvider.start()
        }
        .onChange(of: locationProvider.currentCoordinate?.latitude) { _ in
            recenterOnUserIfNeeded()
        }
        .onChange(of: viewModel.restaurants) { _ in
            fitMapToRestaurants()
        }
        // Find found several equally good suggestions: bring the field (and
        // with it the existing dropdown) back so the user can pick one.
        .onChange(of: viewModel.suggestionChoiceRequest) { _ in
            isAddressFieldFocused = true
        }
        .onChange(of: resultsDetent) { _, detent in
            if detent == HomeMapView.peekResultsDetent {
                frameMeetingArea()
            }
        }
        .onChange(of: viewModel.isShowingResults) { isShowingResults in
            if isShowingResults {
                // Every newly presented search opens fully expanded, even if a
                // prior search's sheet was left at the peek detent.
                resultsDetent = .large
            } else if settingsPresenter == .results {
                // Settings was hosted by the results sheet, which is gone;
                // don't let the stale request present on the next results.
                settingsPresenter = nil
            }
        }
        .alert(
            viewModel.errorTitle,
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { isPresented in if !isPresented { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .sheet(isPresented: resultsSheetBinding) {
            RestaurantResultsSheet(restaurants: viewModel.restaurants, isExpanded: resultsDetent == .large, isSearchInProgress: viewModel.isSearching)
                // Settings opened while results are showing is presented from
                // here: a second `.sheet` on the root view can't present while
                // the results sheet is up.
                .sheet(isPresented: settingsBinding(for: .results)) {
                    settingsSheet
                }
                .presentationDetents([HomeMapView.peekResultsDetent, .large], selection: $resultsDetent)
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: HomeMapView.peekResultsDetent))
                // Peek is the lowest the sheet goes. Swiping it fully away
                // would flip `isShowingResults` and bring back the Home card
                // while the results are still on the map; the Let's Meet
                // badge (`resetToHome()`) is the way to leave results, and it
                // still dismisses the sheet programmatically.
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: settingsBinding(for: .home)) {
            settingsSheet
        }
    }

    private enum SettingsPresenter {
        case home
        case results
    }

    private var settingsSheet: some View {
        SettingsView()
            .presentationDetents([.medium])
    }

    /// Results that arrive while Settings is open from Home wait for it to
    /// close; presenting them would displace Settings, which would then
    /// reappear once the results are dismissed.
    private var resultsSheetBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isShowingResults && settingsPresenter != .home },
            set: { viewModel.isShowingResults = $0 }
        )
    }

    private func settingsBinding(for presenter: SettingsPresenter) -> Binding<Bool> {
        Binding(
            get: { settingsPresenter == presenter },
            set: { isPresented in
                if !isPresented && settingsPresenter == presenter { settingsPresenter = nil }
            }
        )
    }

    /// Restaurants Yelp returned coordinates for - annotationItems/MapAnnotation
    /// both need a concrete, non-optional coordinate per item.
    private var mappableRestaurants: [Restaurant] {
        viewModel.restaurants.filter { $0.coordinate != nil }
    }

    /// Splits the already-fetched A(user)->B(friend) route at the final
    /// meeting point into two legs for visualization, issuing zero
    /// additional MKDirections requests. A computed property (not cached
    /// `@State`) since `MKRoute` isn't `Equatable` and can't drive
    /// `.onChange`; it's cheap to recompute per render. Nil in the
    /// geographic-fallback case (no route available), per which route
    /// lines are intentionally omitted rather than fetched just for display.
    private var routeSegments: (userLeg: MKPolyline, friendLeg: MKPolyline)? {
        guard let route = viewModel.route, let meetingPoint = viewModel.meetingPointCoordinate else { return nil }
        let split = RoutePolylineMath.split(route.polyline, at: meetingPoint)
        return (userLeg: split.prefix, friendLeg: split.suffix)
    }

    /// Frames the map around the recommended restaurants (plus the midpoint and
    /// the user's own location, when available) using MapKit's own coordinate/
    /// region types rather than a hard-coded zoom level. The center is nudged
    /// south by a small amount so the fitted area isn't crowded against the
    /// top edge above the peek results sheet, which only covers a small strip
    /// at the bottom of the screen. Scaled up proportionally from the prior
    /// 0.09 value to match the peek detent's taller 220pt height (was 180pt).
    private func fitMapToRestaurants() {
        let coordinates = mappableRestaurants.map(\.coordinate!)
        guard !coordinates.isEmpty else { return }

        var mapRect = MKMapRect.null
        for coordinate in coordinates {
            let point = MKMapPoint(coordinate)
            mapRect = mapRect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        if let midpoint = YelpManager.shared.midPoint?.coordinate {
            let point = MKMapPoint(midpoint)
            mapRect = mapRect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        // Include the user's own location so the blue location indicator stays
        // visible on screen once the camera reframes to the restaurant area.
        if let userCoordinate = locationProvider.currentCoordinate {
            let point = MKMapPoint(userCoordinate)
            mapRect = mapRect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }

        var fitted = MKCoordinateRegion(mapRect)
        fitted.span.latitudeDelta = max(fitted.span.latitudeDelta * 1.5, 0.01)
        fitted.span.longitudeDelta = max(fitted.span.longitudeDelta * 1.5, 0.01)
        fitted.center.latitude -= fitted.span.latitudeDelta * 0.11

        cameraPosition = .region(fitted)
    }

    /// Reframes the camera around the meeting/search area (search-radius
    /// circle plus any restaurants around it), deliberately ignoring the
    /// full user-friend route so long trips don't zoom the map out. Runs
    /// only when the results sheet transitions into PEEK; afterwards the
    /// user can pan/zoom freely.
    private func frameMeetingArea() {
        guard viewModel.isShowingResults,
              let center = viewModel.meetingPointCoordinate,
              let radius = viewModel.searchRadiusMeters else { return }

        let centerPoint = MKMapPoint(center)
        let radiusPoints = radius * MKMapPointsPerMeterAtLatitude(center.latitude)
        var mapRect = MKMapRect(
            x: centerPoint.x - radiusPoints,
            y: centerPoint.y - radiusPoints,
            width: radiusPoints * 2,
            height: radiusPoints * 2
        )
        for restaurant in mappableRestaurants {
            let point = MKMapPoint(restaurant.coordinate!)
            mapRect = mapRect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }

        var fitted = MKCoordinateRegion(mapRect)
        fitted.span.latitudeDelta *= 1.4
        fitted.span.longitudeDelta *= 1.4
        // Shifts the center south so the meeting area sits in the map area
        // visible above the peek sheet rather than behind it.
        fitted.center.latitude -= fitted.span.latitudeDelta * 0.25

        cameraPosition = .region(fitted)
    }

    /// The standard close-in framing used whenever the map recenters on the
    /// user's own location - on first launch (`recenterOnUserIfNeeded`) and
    /// when the Home badge resets the search. Kept in one place so both
    /// spots share the same span instead of two independently hard-coded
    /// copies.
    private func regionCenteredOnUser(_ coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))
    }

    private func recenterOnUserIfNeeded() {
        guard !hasCenteredOnUser, let coordinate = locationProvider.currentCoordinate else { return }
        hasCenteredOnUser = true
        cameraPosition = .region(regionCenteredOnUser(coordinate))
    }

    /// Returns the home screen to its original, pre-search state: resets the
    /// view model's search/results state, dismisses the address field's
    /// keyboard/focus, and recenters the map on the user's already-known
    /// location (no new location request) - mirroring the framing used on
    /// first launch.
    private func resetToHome() {
        viewModel.resetToHome()
        isAddressFieldFocused = false
        if let coordinate = locationProvider.currentCoordinate {
            cameraPosition = .region(regionCenteredOnUser(coordinate))
        }
    }

    private var brandingBadge: some View {
        Button(action: resetToHome) {
            Text("Let's Meet")
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(LetsMeetColor.lightBlue)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
        }
    }

    /// Occupies the full width of the map (matching `brandingBadge`'s own
    /// ZStack layer) and uses an internal `Spacer` to push the gear to the
    /// trailing edge - kept as its own ZStack sibling, never wrapping
    /// `brandingBadge` in a shared HStack, so the "Let's Meet" badge stays
    /// exactly centered regardless of this button's presence.
    private var settingsButton: some View {
        HStack {
            Spacer()
            Button(action: { settingsPresenter = viewModel.isShowingResults ? .results : .home }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(LetsMeetColor.lightBlue)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.trailing, 16)
    }

    private static let suggestionRowHeight: CGFloat = 52
    private static let visibleSuggestionRows = 3

    /// Tight top corners where the dropdown meets the field above it, softer
    /// bottom corners at its free end. Shared by the background, clip and
    /// border so they always match.
    private static let dropdownShape = UnevenRoundedRectangle(
        topLeadingRadius: 9,
        bottomLeadingRadius: 20,
        bottomTrailingRadius: 20,
        topTrailingRadius: 9,
        style: .continuous
    )

    /// Dropdown height: the usual up-to-3 rows, reduced only when the keyboard
    /// leaves less room below the field. Snaps to whole rows, allowing a small
    /// peek of the next row as a scroll hint, so no row is left half-hidden
    /// behind the keyboard.
    private func dropdownHeight(fieldBottom: CGFloat) -> CGFloat {
        let row = HomeMapView.suggestionRowHeight
        let natural = CGFloat(min(viewModel.suggestions.count, HomeMapView.visibleSuggestionRows)) * row
        guard let keyboardTop = keyboardTopY else { return natural }

        let available = keyboardTop - fieldBottom - 4 - 8
        if available >= natural { return natural }

        let fullRows = max((available / row).rounded(.down), 1)
        var height = min(natural, max(available, row))
        if height - fullRows * row < 14 {
            height = fullRows * row
        }
        return height
    }

    /// Scrollable dropdown attached under the address field. Height is fixed
    /// per row (capped at 3 rows) so it doesn't resize with every result
    /// change once full; extra suggestions scroll.
    private func suggestionDropdown(height: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(viewModel.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    Button {
                        isAddressFieldFocused = false
                        viewModel.selectSuggestion(suggestion)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.circle.fill")
                                .foregroundColor(LetsMeetColor.orange)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle)
                                        .font(.caption)
                                        .foregroundColor(Color(.secondaryLabel))
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: HomeMapView.suggestionRowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
            }
        }
        .frame(height: height)
        .background(Color(.secondarySystemBackground), in: HomeMapView.dropdownShape)
        .clipShape(HomeMapView.dropdownShape)
        .overlay(
            HomeMapView.dropdownShape
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
    }

    /// The "Find a place" entry point. Location availability is checked first,
    /// before address validation or geocoding, because without a usable
    /// location no search can succeed.
    private func findTapped() {
        let availability = locationProvider.availability
        guard availability == .available else {
            if availability == .notDetermined || availability == .acquiring || availability == .failed {
                locationProvider.start()
            }
            locationAlertState = availability
            return
        }
        viewModel.findAPlace()
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private var locationAlertTitle: String {
        switch locationAlertState {
        case .denied: return "Location Access Is Off"
        case .servicesDisabled: return "Location Services Are Off"
        case .restricted: return "Location Is Restricted"
        case .failed: return "Couldn't Get Your Location"
        default: return "Finding Your Location"
        }
    }

    private var locationAlertMessage: String {
        switch locationAlertState {
        case .denied:
            return "Let's Meet needs your location to find a fair meeting spot. Turn on Location for Let's Meet in Settings."
        case .servicesDisabled:
            return "Turn on Location Services in Settings \u{203A} Privacy & Security \u{203A} Location Services."
        case .restricted:
            return "Location access is restricted on this device (for example by Screen Time or device management), so Let's Meet can't find your location."
        case .failed:
            return "Let's Meet couldn't determine your location. Please try again."
        default:
            return "Let's Meet is still getting your location. Try again in a moment."
        }
    }

    private var locationStatusText: String {
        switch locationProvider.availability {
        case .available: return "Your location: Current Location"
        case .notDetermined, .acquiring: return "Finding your location\u{2026}"
        case .denied, .servicesDisabled: return "Location is off"
        case .restricted: return "Location is restricted"
        case .failed: return "Can't get your location"
        }
    }

    private var bottomCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Who are you meeting?")
                    .font(.title3.bold())
                Text(viewModel.needsSuggestionChoice ? "Select the correct address below." : "Add your friend's address or location.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundColor(LetsMeetColor.orange)
                TextField("Friend's address", text: $viewModel.addressText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .focused($isAddressFieldFocused)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topLeading) {
                // Overlays the content below the field instead of adding to
                // the card's layout, so the card never changes height. The
                // dropdown's top edge is offset by the field's own measured
                // height, so it starts just below the field at any size.
                GeometryReader { field in
                    if isAddressFieldFocused && !viewModel.suggestions.isEmpty {
                        suggestionDropdown(height: dropdownHeight(fieldBottom: field.frame(in: .global).maxY))
                            .offset(y: field.size.height + 4)
                            .transition(.opacity)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isAddressFieldFocused && !viewModel.suggestions.isEmpty)
            // Keeps the dropdown (and its taps) above the sibling views below.
            .zIndex(1)

            HStack(spacing: 8) {
                Image(systemName: "location.fill")
                    .foregroundColor(LetsMeetColor.lightBlue)
                Text(locationStatusText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
            }

            Button(action: findTapped) {
                HStack(spacing: 8) {
                    if viewModel.isSearching {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "fork.knife.circle.fill")
                        Text("Find a place")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .background(LetsMeetColor.lightBlue)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(LetsMeetColor.orange, lineWidth: 2)
            )
            .disabled(viewModel.isSearching)
        }
        .padding(20)
        // Background-in-shape rather than clipShape so the suggestion
        // dropdown isn't clipped where it extends past the card.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }
}

/// A simple, brand-colored pin marking one recommended restaurant on the map.
/// All restaurant pins share this same design for this pass.
private struct RestaurantMapPin: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: 30, height: 30)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            Image(systemName: "fork.knife.circle.fill")
                .font(.system(size: 26))
                .foregroundColor(LetsMeetColor.orange)
        }
    }
}

/// Marks the friend's geocoded location on the map, in the app's orange
/// friend color.
private struct FriendMapPin: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: 30, height: 30)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            Image(systemName: "figure.wave.circle.fill")
                .font(.system(size: 26))
                .foregroundColor(LetsMeetColor.orange)
        }
    }
}

/// Classic teardrop map-pin outline: round head with a point at the bottom
/// center. Built from explicit trig points to avoid arc-direction ambiguity.
private struct TeardropPinShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = rect.width / 2
        let center = CGPoint(x: rect.midX, y: rect.minY + radius)
        func point(_ degrees: Double) -> CGPoint {
            let radians = degrees * .pi / 180
            return CGPoint(x: center.x + radius * cos(radians), y: center.y + radius * sin(radians))
        }

        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: point(45))
        for degrees in stride(from: 45.0, through: -225.0, by: -3.0) {
            path.addLine(to: point(degrees))
        }
        path.closeSubpath()
        return path
    }
}

/// Marks the final meeting/search center: a larger red teardrop pin with a
/// white center dot, anchored by its tip at the exact coordinate. Uses
/// SwiftUI's built-in `Color.red` directly rather than a new
/// `Color+LetsMeet.swift` token.
private struct MeetingPointMapPin: View {
    var body: some View {
        ZStack(alignment: .top) {
            TeardropPinShape()
                .fill(Color.red)
            TeardropPinShape()
                .stroke(Color.white, lineWidth: 1.5)
            Circle()
                .fill(Color.white)
                .frame(width: 10, height: 10)
                .padding(.top, 8)
        }
        .frame(width: 26, height: 34)
        .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
    }
}
