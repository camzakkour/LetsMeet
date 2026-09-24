//
//  HomeMapView.swift
//  LetsMeet
//

import SwiftUI
import MapKit

struct HomeMapView: View {

    @ObservedObject var viewModel: HomeViewModel
    @StateObject private var locationProvider = LocationProvider()

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
    )
    @State private var hasCenteredOnUser = false
    @State private var resultsDetent: PresentationDetent = .large

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
            .ignoresSafeArea()

            brandingBadge
                .padding(.top, 8)

            if !viewModel.isShowingResults {
                VStack {
                    Spacer()
                    bottomCard
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: viewModel.isShowingResults)
        .onAppear { locationProvider.requestLocation() }
        .onChange(of: locationProvider.currentCoordinate?.latitude) { _ in
            recenterOnUserIfNeeded()
        }
        .onChange(of: viewModel.restaurants) { _ in
            fitMapToRestaurants()
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
        .sheet(isPresented: $viewModel.isShowingResults) {
            RestaurantResultsSheet(restaurants: viewModel.restaurants, isExpanded: resultsDetent == .large)
                .presentationDetents([HomeMapView.peekResultsDetent, .large], selection: $resultsDetent)
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: HomeMapView.peekResultsDetent))
        }
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

    private func recenterOnUserIfNeeded() {
        guard !hasCenteredOnUser, let coordinate = locationProvider.currentCoordinate else { return }
        hasCenteredOnUser = true
        cameraPosition = .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        )
    }

    private var brandingBadge: some View {
        Text("Let's Meet")
            .font(.headline)
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(LetsMeetColor.lightBlue)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
    }

    private var bottomCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Who are you meeting?")
                    .font(.title3.bold())
                Text("Add your friend's address or location.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundColor(LetsMeetColor.orange)
                TextField("Friend's address", text: $viewModel.addressText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
            }
            .padding(12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 8) {
                Image(systemName: "location.fill")
                    .foregroundColor(LetsMeetColor.lightBlue)
                Text("Your location: Current Location")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
            }

            Button(action: viewModel.findAPlace) {
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
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
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
